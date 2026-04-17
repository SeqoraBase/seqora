// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IEAS } from "eas-contracts/IEAS.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";

import { ScreeningAttestations } from "../src/ScreeningAttestations.sol";
import { IScreeningAttestations } from "../src/interfaces/IScreeningAttestations.sol";
import { DesignRegistry } from "../src/DesignRegistry.sol";
import { IDesignRegistry } from "../src/interfaces/IDesignRegistry.sol";
import { LicenseRegistry } from "../src/LicenseRegistry.sol";
import { RoyaltyRouter } from "../src/RoyaltyRouter.sol";
import { ProvenanceRegistry } from "../src/ProvenanceRegistry.sol";
import { BiosafetyCourt } from "../src/BiosafetyCourt.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";

import { MockEAS } from "./helpers/MockEAS.sol";
import { MockPoolManager } from "./helpers/MockPoolManager.sol";
import { HookMiner } from "./helpers/HookMiner.sol";

/// @title TimelockGovernance integration test
/// @notice End-to-end verification that a TimelockController can own all 5 owner-gated Seqora
///         contracts and that governance flows through the schedule → wait → execute lifecycle.
contract TimelockGovernanceTest is Test {
    uint256 internal constant MIN_DELAY = 48 hours;

    address internal constant DEPLOYER = address(0xDEADBEEF);
    address internal constant TREASURY = address(0xBEEF);
    address internal constant SAFETY_COUNCIL = address(0xCAFE);
    address internal constant ATTACKER = address(0xBAD);

    // v4 hook flags for RoyaltyRouter
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    TimelockController internal timelock;
    ScreeningAttestations internal screening;
    DesignRegistry internal designRegistry;
    LicenseRegistry internal licenseRegistry;
    RoyaltyRouter internal royaltyRouter;
    ProvenanceRegistry internal provenance;
    BiosafetyCourt internal court;

    MockEAS internal eas;
    MockPoolManager internal poolManager;

    function setUp() public {
        // --- Deploy Seqora stack, owner = DEPLOYER ---
        vm.startPrank(DEPLOYER);
        eas = new MockEAS();
        bytes32 schemaUid = bytes32(uint256(1));
        screening = new ScreeningAttestations(IEAS(address(eas)), schemaUid, DEPLOYER);

        designRegistry = new DesignRegistry("ipfs://{id}", IScreeningAttestations(address(screening)));

        LicenseRegistry licenseImpl = new LicenseRegistry();
        bytes memory licenseInit =
            abi.encodeCall(LicenseRegistry.initialize, (IDesignRegistry(address(designRegistry)), DEPLOYER));
        ERC1967Proxy licenseProxy = new ERC1967Proxy(address(licenseImpl), licenseInit);
        licenseRegistry = LicenseRegistry(address(licenseProxy));

        poolManager = new MockPoolManager();
        bytes memory routerCreationCode = abi.encodePacked(
            type(RoyaltyRouter).creationCode,
            abi.encode(IDesignRegistry(address(designRegistry)), TREASURY, IPoolManager(address(poolManager)), DEPLOYER)
        );
        (address predicted, bytes32 salt) = HookMiner.find(DEPLOYER, routerCreationCode, HOOK_FLAGS);
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(routerCreationCode, 0x20), mload(routerCreationCode), salt)
        }
        require(deployed == predicted, "router create2 mismatch");
        royaltyRouter = RoyaltyRouter(payable(deployed));

        provenance = new ProvenanceRegistry(IDesignRegistry(address(designRegistry)), DEPLOYER);

        BiosafetyCourt courtImpl = new BiosafetyCourt();
        bytes memory courtInit = abi.encodeCall(
            BiosafetyCourt.initialize, (IDesignRegistry(address(designRegistry)), TREASURY, SAFETY_COUNCIL, DEPLOYER)
        );
        ERC1967Proxy courtProxy = new ERC1967Proxy(address(courtImpl), courtInit);
        court = BiosafetyCourt(payable(address(courtProxy)));

        // --- Deploy Timelock with DEPLOYER as proposer, open execution, self-admin ---
        address[] memory proposers = new address[](1);
        proposers[0] = DEPLOYER;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        // --- Phase 1: transferOwnership → makes timelock the pending owner of each contract ---
        Ownable(address(screening)).transferOwnership(address(timelock));
        Ownable(address(licenseRegistry)).transferOwnership(address(timelock));
        Ownable(address(royaltyRouter)).transferOwnership(address(timelock));
        Ownable(address(provenance)).transferOwnership(address(timelock));
        Ownable(address(court)).transferOwnership(address(timelock));

        // --- Phase 2: schedule a batched acceptOwnership op on the Timelock, wait, execute ---
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _acceptOwnershipBatch();
        bytes32 handoverSalt = keccak256("handover");
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), handoverSalt, MIN_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);
        timelock.executeBatch(targets, values, payloads, bytes32(0), handoverSalt);
    }

    function _acceptOwnershipBatch()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](5);
        values = new uint256[](5);
        payloads = new bytes[](5);
        targets[0] = address(screening);
        targets[1] = address(licenseRegistry);
        targets[2] = address(royaltyRouter);
        targets[3] = address(provenance);
        targets[4] = address(court);
        for (uint256 i = 0; i < 5; i++) {
            payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        }
    }

    // -------------------------------------------------------------------------
    // setUp invariants
    // -------------------------------------------------------------------------

    function test_SetUp_AllOwnerGatedContractsOwnedByTimelock() public view {
        assertEq(Ownable(address(screening)).owner(), address(timelock), "screening owner");
        assertEq(Ownable(address(licenseRegistry)).owner(), address(timelock), "license owner");
        assertEq(Ownable(address(royaltyRouter)).owner(), address(timelock), "router owner");
        assertEq(Ownable(address(provenance)).owner(), address(timelock), "provenance owner");
        assertEq(Ownable(address(court)).owner(), address(timelock), "court owner");
    }

    function test_SetUp_TimelockRolesMatchExpectedLayout() public view {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        assertTrue(timelock.hasRole(proposerRole, DEPLOYER), "proposer has role");
        assertTrue(timelock.hasRole(cancellerRole, DEPLOYER), "proposer is also canceller");
        assertTrue(timelock.hasRole(executorRole, address(0)), "executor is open");

        // Admin = timelock itself (self-administering). DEPLOYER should NOT be admin.
        assertTrue(timelock.hasRole(adminRole, address(timelock)), "timelock self-admins");
        assertFalse(timelock.hasRole(adminRole, DEPLOYER), "deployer is not admin");

        assertEq(timelock.getMinDelay(), MIN_DELAY, "min delay matches");
    }

    // -------------------------------------------------------------------------
    // Direct owner-gated calls by the old EOA must now revert
    // -------------------------------------------------------------------------

    function test_DirectOwnerCall_RevertsAfterTransfer() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEPLOYER));
        RoyaltyRouter(payable(address(royaltyRouter))).setSupportedToken(address(0x1234), true);
    }

    function test_DirectOwnerCall_RevertsFor_Screening() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEPLOYER));
        screening.registerAttester(address(0x1234), SeqoraTypes.ScreenerKind.Other);
    }

    // -------------------------------------------------------------------------
    // Schedule → wait → execute happy path
    // -------------------------------------------------------------------------

    function test_Timelock_ScheduleThenExecute_SettsSupportedToken() public {
        address mockToken = address(0x1234);
        bytes memory payload = abi.encodeCall(RoyaltyRouter.setSupportedToken, (mockToken, true));
        bytes32 salt = keccak256("test-schedule");

        vm.prank(DEPLOYER);
        timelock.schedule(address(royaltyRouter), 0, payload, bytes32(0), salt, MIN_DELAY);

        // Premature execute must revert — operation not ready.
        vm.warp(block.timestamp + MIN_DELAY - 1);
        vm.expectRevert();
        timelock.execute(address(royaltyRouter), 0, payload, bytes32(0), salt);

        // At MIN_DELAY, execution succeeds. Open executor role → any address can call execute.
        vm.warp(block.timestamp + 1);
        vm.prank(ATTACKER); // any address works — execution is open after delay
        timelock.execute(address(royaltyRouter), 0, payload, bytes32(0), salt);

        assertTrue(royaltyRouter.supportedToken(mockToken), "token is now supported");
    }

    // -------------------------------------------------------------------------
    // Non-proposer cannot schedule
    // -------------------------------------------------------------------------

    function test_Timelock_Schedule_RevertsFromNonProposer() public {
        bytes memory payload = abi.encodeCall(RoyaltyRouter.setSupportedToken, (address(0x1234), true));
        vm.startPrank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, ATTACKER, timelock.PROPOSER_ROLE()
            )
        );
        timelock.schedule(address(royaltyRouter), 0, payload, bytes32(0), keccak256("x"), MIN_DELAY);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Delay cannot be shortened below minDelay in a scheduled call
    // -------------------------------------------------------------------------

    function test_Timelock_Schedule_RevertsOnTooShortDelay() public {
        bytes memory payload = abi.encodeCall(RoyaltyRouter.setSupportedToken, (address(0x1234), true));
        vm.prank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, MIN_DELAY - 1, MIN_DELAY)
        );
        timelock.schedule(address(royaltyRouter), 0, payload, bytes32(0), keccak256("y"), MIN_DELAY - 1);
    }

    // -------------------------------------------------------------------------
    // Cancel path: proposer has CANCELLER_ROLE
    // -------------------------------------------------------------------------

    function test_Timelock_Cancel_ByProposer_RemovesScheduledOp() public {
        bytes memory payload = abi.encodeCall(RoyaltyRouter.setSupportedToken, (address(0x1234), true));
        bytes32 salt = keccak256("cancel-test");

        vm.prank(DEPLOYER);
        timelock.schedule(address(royaltyRouter), 0, payload, bytes32(0), salt, MIN_DELAY);
        bytes32 opId = timelock.hashOperation(address(royaltyRouter), 0, payload, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(opId), "op pending before cancel");

        vm.prank(DEPLOYER);
        timelock.cancel(opId);
        assertFalse(timelock.isOperation(opId), "op cleared after cancel");

        // After cancel, execute fails because the op is not ready.
        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.expectRevert();
        timelock.execute(address(royaltyRouter), 0, payload, bytes32(0), salt);
    }

    // -------------------------------------------------------------------------
    // Role mutation requires a Timelock'd proposal
    // -------------------------------------------------------------------------

    function test_Timelock_GrantProposerRole_RequiresTimelockedCall() public {
        address newProposer = address(0xC0FFEE);
        bytes32 proposerRole = timelock.PROPOSER_ROLE();

        // Direct grantRole from DEPLOYER fails — only the timelock itself has DEFAULT_ADMIN_ROLE.
        vm.startPrank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, DEPLOYER, timelock.DEFAULT_ADMIN_ROLE()
            )
        );
        timelock.grantRole(proposerRole, newProposer);
        vm.stopPrank();

        // The canonical path: proposer schedules a grantRole call targeting the timelock itself.
        bytes memory grantPayload = abi.encodeCall(IAccessControl.grantRole, (proposerRole, newProposer));
        bytes32 salt = keccak256("grant-role");

        vm.prank(DEPLOYER);
        timelock.schedule(address(timelock), 0, grantPayload, bytes32(0), salt, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);
        timelock.execute(address(timelock), 0, grantPayload, bytes32(0), salt);

        assertTrue(timelock.hasRole(proposerRole, newProposer), "new proposer got role via timelock");
    }
}
