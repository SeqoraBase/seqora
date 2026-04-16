// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { DesignRegistry } from "../../src/DesignRegistry.sol";
import { BiosafetyCourt } from "../../src/BiosafetyCourt.sol";
import { IBiosafetyCourt } from "../../src/interfaces/IBiosafetyCourt.sol";
import { IDesignRegistry } from "../../src/interfaces/IDesignRegistry.sol";
import { IScreeningAttestations } from "../../src/interfaces/IScreeningAttestations.sol";
import { SeqoraTypes } from "../../src/libraries/SeqoraTypes.sol";

import { AlwaysValidScreening } from "./MockScreening.sol";

/// @notice Upgradeable v2 mock used by the UUPS upgrade test. Adds a v2-only getter while keeping
///         storage layout compatible with v1 — layout-compat is asserted by reading v1 state
///         through the proxy post-upgrade.
contract BiosafetyCourtV2Mock is BiosafetyCourt {
    /// @notice Constant bumped in v2 so tests can observe the upgrade took effect.
    string public constant VERSION = "bsc-v2-mock";

    /// @notice A v2-only function that does NOT exist in v1.
    function v2Only() external pure returns (uint256) {
        return 8484;
    }
}

/// @notice Harness that stands up a fresh DesignRegistry + AlwaysValidScreening + BiosafetyCourt
///         UUPS proxy stack for every test. Mirrors the `LicenseRegistryHarness` pattern so the
///         suite is uniform across v1 UUPS contracts.
abstract contract BiosafetyCourtHarness is Test {
    // -------------------------------------------------------------------------
    // Actors (dual-key: GOVERNANCE != COUNCIL)
    // -------------------------------------------------------------------------

    address internal constant GOVERNANCE = address(0x6060);
    address internal constant COUNCIL = address(0xC0DE);
    address internal constant TREASURY = address(0xFEED);

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant DAVE = address(0xDA4E);
    address internal constant EVE = address(0xE5E);
    address internal constant STRANGER = address(0xDEAD);

    string internal constant DESIGN_BASE_URI = "ipfs://seqora/{id}.json";

    // -------------------------------------------------------------------------
    // Deployed contracts
    // -------------------------------------------------------------------------

    IScreeningAttestations internal screening;
    DesignRegistry internal designs;
    BiosafetyCourt internal impl;
    BiosafetyCourt internal court; // proxy cast to BiosafetyCourt for ergonomic calls
    ERC1967Proxy internal proxy;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public virtual {
        screening = _deployScreening();
        designs = new DesignRegistry(DESIGN_BASE_URI, screening);

        impl = new BiosafetyCourt();
        bytes memory initCalldata = abi.encodeCall(
            BiosafetyCourt.initialize, (IDesignRegistry(address(designs)), TREASURY, COUNCIL, GOVERNANCE)
        );
        proxy = new ERC1967Proxy(address(impl), initCalldata);
        court = BiosafetyCourt(payable(address(proxy)));

        vm.label(address(screening), "Screening");
        vm.label(address(designs), "DesignRegistry");
        vm.label(address(impl), "BiosafetyCourt.impl");
        vm.label(address(proxy), "BiosafetyCourt.proxy");
        vm.label(GOVERNANCE, "GOVERNANCE");
        vm.label(COUNCIL, "COUNCIL");
        vm.label(TREASURY, "TREASURY");
        vm.label(ALICE, "ALICE");
        vm.label(BOB, "BOB");
        vm.label(CAROL, "CAROL");
        vm.label(DAVE, "DAVE");
        vm.label(EVE, "EVE");
        vm.label(STRANGER, "STRANGER");
    }

    function _deployScreening() internal virtual returns (IScreeningAttestations) {
        return new AlwaysValidScreening();
    }

    // -------------------------------------------------------------------------
    // Design helpers
    // -------------------------------------------------------------------------

    function _defaultRoyalty() internal pure returns (SeqoraTypes.RoyaltyRule memory) {
        return SeqoraTypes.RoyaltyRule({ recipient: address(0xEEEE), bps: 500, parentSplitBps: 0 });
    }

    /// @notice Register a genesis design in the underlying DesignRegistry.
    function _registerDesign(address registrant, bytes32 canonicalHash) internal returns (uint256 tokenId) {
        vm.prank(registrant);
        tokenId = designs.register(
            registrant,
            canonicalHash,
            bytes32(0),
            "ar://tx",
            "ceramic://s",
            _defaultRoyalty(),
            bytes32(uint256(1)),
            new bytes32[](0)
        );
    }

    function _registerDesign(address registrant) internal returns (uint256 tokenId) {
        bytes32 canonical = keccak256(abi.encode(registrant, block.number, block.timestamp, gasleft()));
        return _registerDesign(registrant, canonical);
    }

    // -------------------------------------------------------------------------
    // Staking helpers
    // -------------------------------------------------------------------------

    /// @notice Deposit `amount` wei via receive() as `reviewer`.
    function _deposit(address reviewer, uint256 amount) internal {
        vm.deal(reviewer, reviewer.balance + amount);
        vm.prank(reviewer);
        (bool ok,) = address(court).call{ value: amount }("");
        require(ok, "deposit failed");
    }

    /// @notice Two-tx stake: deposit ETH then promote `bondAmount` to bond.
    function _stake(address reviewer, uint128 bondAmount) internal {
        _deposit(reviewer, bondAmount);
        vm.prank(reviewer);
        court.stakeAsReviewer(bondAmount);
    }

    /// @notice Deposit more than bondAmount + stake bondAmount. Leaves `extra` in pendingDeposits.
    function _stakeWithExtraDeposit(address reviewer, uint128 bondAmount, uint128 extra) internal {
        _deposit(reviewer, uint256(bondAmount) + uint256(extra));
        vm.prank(reviewer);
        court.stakeAsReviewer(bondAmount);
    }
}
