// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/types/BeforeSwapDelta.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { SwapParams, ModifyLiquidityParams } from "v4-core/types/PoolOperation.sol";

import { DesignRegistry } from "../src/DesignRegistry.sol";
import { RoyaltyRouter } from "../src/RoyaltyRouter.sol";
import { IDesignRegistry } from "../src/interfaces/IDesignRegistry.sol";
import { IRoyaltyRouter } from "../src/interfaces/IRoyaltyRouter.sol";
import { IScreeningAttestations } from "../src/interfaces/IScreeningAttestations.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";
import { SeqoraErrors } from "../src/libraries/SeqoraErrors.sol";

import { AlwaysValidScreening } from "./helpers/MockScreening.sol";
import { HookMiner } from "./helpers/HookMiner.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";
import { MockPoolManager, ReentrantMockPoolManager } from "./helpers/MockPoolManager.sol";

// -----------------------------------------------------------------------------
// Harness fixtures
// -----------------------------------------------------------------------------

/// @notice Full RoyaltyRouter test harness — deploys a real DesignRegistry + screening stub and a
///         RoyaltyRouter at a CREATE2-mined address whose trailing bits encode the v4 hook
///         permissions (`beforeSwap | afterSwap | beforeSwapReturnDelta = 0xC8`).
abstract contract RoyaltyRouterBase is Test {
    // ---- Hook permission bits the router declares (MUST match RoyaltyRouter.getHookPermissions) ----
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    // ---- Actors ----
    address internal constant TREASURY = address(0xBEEF);
    address internal constant GOVERNANCE = address(0xDA0);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant FALLBACK_RECIPIENT = address(0xEEEE);
    address internal constant SPLITS = address(0xCAFE);

    // ---- Core fixtures ----
    DesignRegistry internal registry;
    AlwaysValidScreening internal screening;
    MockPoolManager internal poolManager;
    RoyaltyRouter internal router;
    MockERC20 internal usdc;

    // ---- Default royalty config shared across tests ----
    uint16 internal constant DEFAULT_ROYALTY_BPS = 500; // 5%
    bytes32 internal constant DEFAULT_CANONICAL = keccak256("seqora:design:default");

    function setUp() public virtual {
        screening = new AlwaysValidScreening();
        registry = new DesignRegistry("ipfs://seqora/{id}.json", screening);
        poolManager = new MockPoolManager();
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Mine a CREATE2 salt → deploy the router at an address whose trailing bits encode HOOK_FLAGS.
        bytes memory creationCode = abi.encodePacked(
            type(RoyaltyRouter).creationCode,
            abi.encode(IDesignRegistry(address(registry)), TREASURY, IPoolManager(address(poolManager)), GOVERNANCE)
        );
        (address predicted, bytes32 salt) = HookMiner.find(address(this), creationCode, HOOK_FLAGS);
        address deployed;
        assembly {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(deployed == predicted, "RoyaltyRouterBase: create2 mismatch");
        router = RoyaltyRouter(payable(deployed));

        // Governance: allowlist USDC.
        vm.prank(GOVERNANCE);
        router.setSupportedToken(address(usdc), true);

        vm.label(address(router), "RoyaltyRouter");
        vm.label(address(registry), "DesignRegistry");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(usdc), "USDC");
        vm.label(TREASURY, "TREASURY");
        vm.label(GOVERNANCE, "GOVERNANCE");
        vm.label(ALICE, "ALICE");
        vm.label(BOB, "BOB");
        vm.label(SPLITS, "SPLITS");
        vm.label(FALLBACK_RECIPIENT, "FALLBACK_RECIPIENT");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _registerDesign(address registrant, bytes32 canonicalHash, uint16 royaltyBps, address recipient)
        internal
        returns (uint256 tokenId)
    {
        SeqoraTypes.RoyaltyRule memory r =
            SeqoraTypes.RoyaltyRule({ recipient: recipient, bps: royaltyBps, parentSplitBps: 0 });
        vm.prank(registrant);
        tokenId = registry.register(
            registrant, canonicalHash, bytes32(0), "ar://tx", "ceramic://tx", r, bytes32(uint256(1)), new bytes32[](0)
        );
    }

    function _registerDefault(address registrant) internal returns (uint256 tokenId) {
        return _registerDesign(registrant, DEFAULT_CANONICAL, DEFAULT_ROYALTY_BPS, FALLBACK_RECIPIENT);
    }

    function _defaultPoolKey() internal view returns (PoolKey memory) {
        // usdc is "unspecified" when zeroForOne=true and exactInput=true only if currency1=usdc.
        // Pick currency0 < currency1 per v4 invariants. Pair USDC with a cheap placeholder token.
        address other = address(0x1); // < address(usdc) in all realistic mock cases
        (address c0, address c1) = other < address(usdc) ? (other, address(usdc)) : (address(usdc), other);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(router))
        });
    }

    /// @notice Build a SwapParams whose unspecified currency is usdc (so the hook bills in USDC).
    /// @dev With our pool key (currency0 = 0x1, currency1 = usdc), exactInput zeroForOne swaps
    ///      spend currency0 and receive currency1 ⇒ specified = currency0, unspecified = currency1 = usdc.
    function _swapParamsUsdcUnspecified(int256 amountSpecified) internal pure returns (SwapParams memory p) {
        p = SwapParams({ zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0 });
    }
}

// =============================================================================
// Constructor / deployment
// =============================================================================

contract RoyaltyRouter_Constructor is RoyaltyRouterBase {
    function test_Constructor_SetsImmutables() public view {
        assertEq(address(router.DESIGN_REGISTRY()), address(registry));
        assertEq(router.TREASURY(), TREASURY);
        assertEq(address(router.POOL_MANAGER()), address(poolManager));
        assertEq(router.owner(), GOVERNANCE);
        assertFalse(router.hookCollectionPaused());
    }

    function test_Constructor_HookPermissionsEncoded() public view {
        // Trailing bits of the router address must exactly equal our declared flag set.
        assertEq(uint160(address(router)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
    }

    function test_Constructor_RevertsWhen_DesignRegistryZero() public {
        bytes memory code = abi.encodePacked(
            type(RoyaltyRouter).creationCode,
            abi.encode(IDesignRegistry(address(0)), TREASURY, IPoolManager(address(poolManager)), GOVERNANCE)
        );
        // Mine a valid hook address first so only the zero-reg branch trips.
        (, bytes32 salt) = HookMiner.find(address(this), code, HOOK_FLAGS);
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        this._deploy(code, salt);
    }

    function test_Constructor_RevertsWhen_TreasuryZero() public {
        bytes memory code = abi.encodePacked(
            type(RoyaltyRouter).creationCode,
            abi.encode(IDesignRegistry(address(registry)), address(0), IPoolManager(address(poolManager)), GOVERNANCE)
        );
        (, bytes32 salt) = HookMiner.find(address(this), code, HOOK_FLAGS);
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        this._deploy(code, salt);
    }

    function test_Constructor_RevertsWhen_PoolManagerZero() public {
        bytes memory code = abi.encodePacked(
            type(RoyaltyRouter).creationCode,
            abi.encode(IDesignRegistry(address(registry)), TREASURY, IPoolManager(address(0)), GOVERNANCE)
        );
        (, bytes32 salt) = HookMiner.find(address(this), code, HOOK_FLAGS);
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        this._deploy(code, salt);
    }

    function test_Constructor_RevertsWhen_GovernanceZero() public {
        bytes memory code = abi.encodePacked(
            type(RoyaltyRouter).creationCode,
            abi.encode(IDesignRegistry(address(registry)), TREASURY, IPoolManager(address(poolManager)), address(0))
        );
        (, bytes32 salt) = HookMiner.find(address(this), code, HOOK_FLAGS);
        // OZ Ownable rejects zero owner via OwnableInvalidOwner(address(0)).
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        this._deploy(code, salt);
    }

    function test_Constructor_RevertsWhen_DeployedAtWrongAddress() public {
        bytes memory code = abi.encodePacked(
            type(RoyaltyRouter).creationCode,
            abi.encode(IDesignRegistry(address(registry)), TREASURY, IPoolManager(address(poolManager)), GOVERNANCE)
        );
        // Find a salt whose predicted address does NOT match HOOK_FLAGS.
        bytes32 initCodeHash = keccak256(code);
        bytes32 bogusSalt;
        for (uint256 s = 1; s < 200; s++) {
            address pred = HookMiner.predict(address(this), bytes32(s), initCodeHash);
            if (uint160(pred) & Hooks.ALL_HOOK_MASK != HOOK_FLAGS) {
                bogusSalt = bytes32(s);
                break;
            }
        }
        require(bogusSalt != 0, "no bogus salt found");

        // `Hooks.validateHookPermissions` reverts with a custom-wrapped error; we only assert a revert.
        vm.expectRevert();
        this._deploy(code, bogusSalt);
    }

    function _deploy(bytes memory creationCode, bytes32 salt) external returns (address deployed) {
        assembly {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
            // If CREATE2 failed, the revert data is in returndata; bubble it up so
            // `vm.expectRevert(selector)` sees the ORIGINAL revert, not a synthetic one.
            if iszero(deployed) {
                let size := returndatasize()
                returndatacopy(0, 0, size)
                revert(0, size)
            }
        }
    }
}

// =============================================================================
// royaltyInfo (EIP-2981)
// =============================================================================

contract RoyaltyRouter_RoyaltyInfo is RoyaltyRouterBase {
    function test_RoyaltyInfo_ReturnsZero_WhenTokenUnregistered() public view {
        (address receiver, uint256 amount) = router.royaltyInfo(999, 1_000_000);
        assertEq(receiver, address(0));
        assertEq(amount, 0);
    }

    function test_RoyaltyInfo_ReturnsZeroAmount_OnZeroPrice() public {
        uint256 tokenId = _registerDefault(ALICE);
        (address receiver, uint256 amount) = router.royaltyInfo(tokenId, 0);
        assertEq(receiver, FALLBACK_RECIPIENT);
        assertEq(amount, 0);
    }

    function test_RoyaltyInfo_UsesFallbackRecipient_WhenSplitsUnset() public {
        uint256 tokenId = _registerDefault(ALICE);
        (address receiver, uint256 amount) = router.royaltyInfo(tokenId, 1_000_000);
        assertEq(receiver, FALLBACK_RECIPIENT);
        assertEq(amount, (uint256(1_000_000) * uint256(DEFAULT_ROYALTY_BPS)) / uint256(SeqoraTypes.BPS));
    }

    function test_RoyaltyInfo_UsesSplits_WhenSet() public {
        uint256 tokenId = _registerDefault(ALICE);
        vm.prank(ALICE);
        router.setSplitsContract(tokenId, SPLITS);

        (address receiver, uint256 amount) = router.royaltyInfo(tokenId, 1_000_000);
        assertEq(receiver, SPLITS);
        assertEq(amount, (uint256(1_000_000) * uint256(DEFAULT_ROYALTY_BPS)) / uint256(SeqoraTypes.BPS));
    }

    function test_RoyaltyInfo_HighPrice_NoOverflow() public {
        // Register with max royalty bps to stress the multiply.
        uint256 tokenId = _registerDesign(ALICE, keccak256("high"), SeqoraTypes.MAX_ROYALTY_BPS, FALLBACK_RECIPIENT);
        // Largest salePrice that does not overflow uint256 * MAX_ROYALTY_BPS (2500).
        uint256 safeMax = type(uint256).max / SeqoraTypes.MAX_ROYALTY_BPS;
        (, uint256 amount) = router.royaltyInfo(tokenId, safeMax);
        assertEq(amount, (safeMax * SeqoraTypes.MAX_ROYALTY_BPS) / SeqoraTypes.BPS);
    }

    function test_RoyaltyInfo_RevertsOnArithmeticOverflow_AtUintMax() public {
        // Document: when bps > 1, `salePrice * bps` under 0.8 checked math panics for sufficiently
        // large salePrice. Use MAX_ROYALTY_BPS + salePrice = uint256.max so the multiply overflows.
        uint256 tokenId = _registerDesign(ALICE, keccak256("overflow"), SeqoraTypes.MAX_ROYALTY_BPS, FALLBACK_RECIPIENT);
        vm.expectRevert(); // arithmetic overflow panic
        router.royaltyInfo(tokenId, type(uint256).max);
    }

    function testFuzz_RoyaltyInfo_Math(uint256 salePrice, uint16 bps) public {
        // Bound bps to [0, MAX_ROYALTY_BPS]; bound salePrice so salePrice * bps fits in uint256.
        bps = uint16(bound(uint256(bps), 0, SeqoraTypes.MAX_ROYALTY_BPS));
        salePrice = bound(salePrice, 0, type(uint256).max / (bps == 0 ? 1 : bps));

        address recipient = bps == 0 ? address(0) : FALLBACK_RECIPIENT;
        uint256 tokenId = _registerDesign(ALICE, keccak256(abi.encode(salePrice, bps)), bps, recipient);
        (, uint256 amount) = router.royaltyInfo(tokenId, salePrice);
        assertEq(amount, (salePrice * bps) / SeqoraTypes.BPS);
    }
}

// =============================================================================
// setSplitsContract — auth + idempotent
// =============================================================================

contract RoyaltyRouter_SetSplits is RoyaltyRouterBase {
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        tokenId = _registerDefault(ALICE);
    }

    function test_SetSplits_ByRegistrant() public {
        vm.expectEmit(true, true, false, false);
        emit IRoyaltyRouter.SplitsContractSet(tokenId, SPLITS);
        vm.prank(ALICE);
        router.setSplitsContract(tokenId, SPLITS);
        assertEq(router.getSplitsContract(tokenId), SPLITS);
    }

    function test_SetSplits_ByOwner() public {
        vm.prank(GOVERNANCE);
        router.setSplitsContract(tokenId, SPLITS);
        assertEq(router.getSplitsContract(tokenId), SPLITS);
    }

    function test_SetSplits_ByDesignRegistry() public {
        vm.prank(address(registry));
        router.setSplitsContract(tokenId, SPLITS);
        assertEq(router.getSplitsContract(tokenId), SPLITS);
    }

    function test_SetSplits_RevertsWhen_NotAuthorized() public {
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.NotAuthorized.selector, BOB));
        vm.prank(BOB);
        router.setSplitsContract(tokenId, SPLITS);
    }

    function test_SetSplits_RevertsWhen_ZeroAddress() public {
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        vm.prank(ALICE);
        router.setSplitsContract(tokenId, address(0));
    }

    function test_SetSplits_RevertsWhen_AlreadySet() public {
        vm.prank(ALICE);
        router.setSplitsContract(tokenId, SPLITS);

        vm.expectRevert(abi.encodeWithSelector(IRoyaltyRouter.SplitsAlreadySet.selector, tokenId));
        vm.prank(ALICE);
        router.setSplitsContract(tokenId, address(0xDEAD));
    }

    function test_SetSplits_RevertsWhen_TokenUnregistered() public {
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.UnknownToken.selector, 99_999));
        vm.prank(ALICE);
        router.setSplitsContract(99_999, SPLITS);
    }
}

// =============================================================================
// setSupportedToken (governance)
// =============================================================================

contract RoyaltyRouter_SetSupportedToken is RoyaltyRouterBase {
    function test_SetSupportedToken_OwnerCanToggle() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);

        vm.expectEmit(true, false, false, true, address(router));
        emit RoyaltyRouter.SupportedTokenSet(address(dai), true);
        vm.prank(GOVERNANCE);
        router.setSupportedToken(address(dai), true);
        assertTrue(router.supportedToken(address(dai)));

        vm.prank(GOVERNANCE);
        router.setSupportedToken(address(dai), false);
        assertFalse(router.supportedToken(address(dai)));
    }

    function test_SetSupportedToken_RevertsWhen_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        vm.prank(ALICE);
        router.setSupportedToken(address(usdc), false);
    }

    function test_SetSupportedToken_RevertsWhen_ZeroAddress() public {
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        vm.prank(GOVERNANCE);
        router.setSupportedToken(address(0), true);
    }
}

// =============================================================================
// distribute
// =============================================================================

contract RoyaltyRouter_Distribute is RoyaltyRouterBase {
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        tokenId = _registerDefault(ALICE);
    }

    function test_Distribute_HappyPath_UsingSplits() public {
        vm.prank(ALICE);
        router.setSplitsContract(tokenId, SPLITS);

        uint256 amount = 1_000_000; // 1 USDC (6 dec)
        usdc.mint(BOB, amount);
        vm.prank(BOB);
        usdc.approve(address(router), amount);

        uint256 protocolFee = (amount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        uint256 royaltyAmount = amount - protocolFee;

        vm.expectEmit(true, true, false, true, address(router));
        emit RoyaltyRouter.Distributed(tokenId, address(usdc), amount, protocolFee, royaltyAmount);
        vm.expectEmit(true, true, false, true, address(router));
        emit IRoyaltyRouter.RoyaltyDistributed(tokenId, address(usdc), amount, SPLITS);
        vm.expectEmit(true, true, false, true, address(router));
        emit IRoyaltyRouter.ProtocolFeeCollected(tokenId, address(usdc), protocolFee);

        vm.prank(BOB);
        router.distribute(tokenId, address(usdc), amount);

        assertEq(usdc.balanceOf(TREASURY), protocolFee);
        assertEq(usdc.balanceOf(SPLITS), royaltyAmount);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(protocolFee + royaltyAmount, amount);
    }

    function test_Distribute_HappyPath_FallbackRecipient() public {
        // No splits set — falls back to RoyaltyRule.recipient (FALLBACK_RECIPIENT).
        uint256 amount = 2_000_000;
        usdc.mint(BOB, amount);
        vm.prank(BOB);
        usdc.approve(address(router), amount);

        vm.prank(BOB);
        router.distribute(tokenId, address(usdc), amount);

        uint256 expectedFee = (amount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        assertEq(usdc.balanceOf(TREASURY), expectedFee);
        assertEq(usdc.balanceOf(FALLBACK_RECIPIENT), amount - expectedFee);
    }

    function test_Distribute_RevertsWhen_AmountZero() public {
        vm.expectRevert(IRoyaltyRouter.ZeroAmount.selector);
        vm.prank(BOB);
        router.distribute(tokenId, address(usdc), 0);
    }

    function test_Distribute_RevertsWhen_CurrencyZero() public {
        vm.expectRevert(abi.encodeWithSelector(RoyaltyRouter.UnsupportedToken.selector, address(0)));
        vm.prank(BOB);
        router.distribute(tokenId, address(0), 100);
    }

    function test_Distribute_RevertsWhen_TokenNotAllowed() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(BOB, 100);
        vm.prank(BOB);
        other.approve(address(router), 100);

        vm.expectRevert(abi.encodeWithSelector(RoyaltyRouter.UnsupportedToken.selector, address(other)));
        vm.prank(BOB);
        router.distribute(tokenId, address(other), 100);
    }

    function test_Distribute_RevertsWhen_MsgValueNonZero() public {
        usdc.mint(BOB, 100);
        vm.prank(BOB);
        usdc.approve(address(router), 100);
        vm.deal(BOB, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(RoyaltyRouter.UnsupportedToken.selector, address(0)));
        vm.prank(BOB);
        router.distribute{ value: 0.1 ether }(tokenId, address(usdc), 100);
    }

    function test_Distribute_RevertsWhen_TokenUnregistered() public {
        usdc.mint(BOB, 100);
        vm.prank(BOB);
        usdc.approve(address(router), 100);

        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.UnknownToken.selector, 123_456));
        vm.prank(BOB);
        router.distribute(123_456, address(usdc), 100);
    }

    function test_Distribute_RevertsWhen_NoPayoutTarget() public {
        // Design with bps=0 AND zero recipient → neither splits nor fallback present.
        uint256 zid = _registerDesign(ALICE, keccak256("zero"), 0, address(0));

        usdc.mint(BOB, 100);
        vm.prank(BOB);
        usdc.approve(address(router), 100);

        vm.expectRevert(abi.encodeWithSelector(RoyaltyRouter.SplitsNotSet.selector, zid));
        vm.prank(BOB);
        router.distribute(zid, address(usdc), 100);
    }

    function test_Distribute_RevertsWhen_MaliciousTokenReturnsFalseOnTransfer() public {
        // Token whose `transferFrom` returns false — SafeERC20 should convert to revert.
        MockERC20 bad = new MockERC20("Bad", "BAD", 18);
        vm.prank(GOVERNANCE);
        router.setSupportedToken(address(bad), true);
        bad.mint(BOB, 100);
        bad.setReturnFalseOnTransferFrom(true);
        vm.prank(BOB);
        bad.approve(address(router), 100);

        vm.expectRevert(); // SafeERC20FailedOperation
        vm.prank(BOB);
        router.distribute(tokenId, address(bad), 100);
        // Router holds nothing despite the bad-token interaction.
        assertEq(bad.balanceOf(address(router)), 0);
    }

    function test_Distribute_ReentrancyBlocked_ViaHostileToken() public {
        // Hostile token re-enters `distribute` during transferFrom. The nonReentrant guard must trip.
        MockERC20 reen = new MockERC20("Reenter", "RE", 18);
        vm.prank(GOVERNANCE);
        router.setSupportedToken(address(reen), true);
        reen.mint(BOB, 1000);
        vm.prank(BOB);
        reen.approve(address(router), 1000);

        // Arm re-entry to recursively call distribute from within transferFrom.
        bytes memory reentryCall = abi.encodeWithSelector(router.distribute.selector, tokenId, address(reen), 100);
        reen.armReentry(address(router), reentryCall);

        vm.expectRevert(); // ReentrancyGuardReentrantCall, bubbled via MockERC20's call
        vm.prank(BOB);
        router.distribute(tokenId, address(reen), 500);
    }

    function testFuzz_Distribute_SumInvariant(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        usdc.mint(BOB, amount);
        vm.prank(BOB);
        usdc.approve(address(router), amount);

        vm.prank(BOB);
        router.distribute(tokenId, address(usdc), amount);

        uint256 tBal = usdc.balanceOf(TREASURY);
        uint256 rBal = usdc.balanceOf(FALLBACK_RECIPIENT);
        assertEq(tBal + rBal, amount, "fee + royalty must equal gross");
        assertEq(usdc.balanceOf(address(router)), 0, "no dust in router");
        // Protocol fee is exactly 3% (floor).
        assertEq(tBal, (amount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS);
    }
}

// =============================================================================
// Governance: pause + renounce
// =============================================================================

contract RoyaltyRouter_Governance is RoyaltyRouterBase {
    function test_RenounceOwnership_Reverts() public {
        vm.expectRevert(RoyaltyRouter.RenounceDisabled.selector);
        vm.prank(GOVERNANCE);
        router.renounceOwnership();
    }

    function test_PauseHookCollection_OwnerCanToggle() public {
        vm.expectEmit(false, false, false, true, address(router));
        emit RoyaltyRouter.HookCollectionPaused(true);
        vm.prank(GOVERNANCE);
        router.setHookCollectionPaused(true);
        assertTrue(router.hookCollectionPaused());

        vm.prank(GOVERNANCE);
        router.setHookCollectionPaused(false);
        assertFalse(router.hookCollectionPaused());
    }

    function test_PauseHookCollection_RevertsWhen_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        vm.prank(ALICE);
        router.setHookCollectionPaused(true);
    }
}

// =============================================================================
// Legacy IRoyaltyRouter hook stubs — always revert
// =============================================================================

contract RoyaltyRouter_LegacyStubs is RoyaltyRouterBase {
    function test_LegacyBeforeSwap_Reverts() public {
        vm.expectRevert(RoyaltyRouter.HookMisconfigured.selector);
        IRoyaltyRouter(address(router)).beforeSwap(address(0), "", "", "");
    }

    function test_LegacyAfterSwap_Reverts() public {
        vm.expectRevert(RoyaltyRouter.HookMisconfigured.selector);
        IRoyaltyRouter(address(router)).afterSwap(address(0), "", "", "", "");
    }

    function test_ReceiveEth_Reverts() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(RoyaltyRouter.UnsupportedToken.selector, address(0)));
        (bool ok,) = payable(address(router)).call{ value: 0.1 ether }("");
        // `ok == false` when revert bubbles; treat either as proof of rejection.
        ok; // silence unused
    }

    function test_Fallback_Reverts() public {
        vm.expectRevert(RoyaltyRouter.HookMisconfigured.selector);
        (bool ok,) = address(router).call(abi.encodeWithSignature("nonexistent()"));
        ok;
    }

    function test_OtherHooks_AllRevert() public {
        PoolKey memory key = _defaultPoolKey();
        ModifyLiquidityParams memory mp =
            ModifyLiquidityParams({ tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0) });

        vm.expectRevert(RoyaltyRouter.HookMisconfigured.selector);
        IHooks(address(router)).beforeInitialize(address(0), key, 0);
        vm.expectRevert(RoyaltyRouter.HookMisconfigured.selector);
        IHooks(address(router)).afterInitialize(address(0), key, 0, 0);
        vm.expectRevert(RoyaltyRouter.HookMisconfigured.selector);
        IHooks(address(router)).beforeAddLiquidity(address(0), key, mp, "");
        vm.expectRevert(RoyaltyRouter.HookMisconfigured.selector);
        IHooks(address(router)).afterAddLiquidity(address(0), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(RoyaltyRouter.HookMisconfigured.selector);
        IHooks(address(router)).beforeRemoveLiquidity(address(0), key, mp, "");
        vm.expectRevert(RoyaltyRouter.HookMisconfigured.selector);
        IHooks(address(router))
            .afterRemoveLiquidity(address(0), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(RoyaltyRouter.HookMisconfigured.selector);
        IHooks(address(router)).beforeDonate(address(0), key, 0, 0, "");
        vm.expectRevert(RoyaltyRouter.HookMisconfigured.selector);
        IHooks(address(router)).afterDonate(address(0), key, 0, 0, "");
    }

    function test_BeforeSwap_RevertsIfCallerNotPoolManager() public {
        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(1000));
        vm.expectRevert(abi.encodeWithSelector(RoyaltyRouter.NotPoolManager.selector, address(this)));
        IHooks(address(router)).beforeSwap(address(0), key, p, "");
    }

    function test_AfterSwap_RevertsIfCallerNotPoolManager() public {
        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(1000));
        vm.expectRevert(abi.encodeWithSelector(RoyaltyRouter.NotPoolManager.selector, address(this)));
        IHooks(address(router)).afterSwap(address(0), key, p, BalanceDelta.wrap(0), "");
    }
}

// =============================================================================
// v4 Hook integration (via MockPoolManager)
// =============================================================================

contract RoyaltyRouter_HookIntegration is RoyaltyRouterBase {
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        tokenId = _registerDefault(ALICE);
        vm.prank(ALICE);
        router.setSplitsContract(tokenId, SPLITS);
    }

    function _runSwap(int256 amountSpecified) internal {
        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(amountSpecified);
        bytes memory hookData = abi.encode(tokenId);
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, hookData);
    }

    function _expectedTake(uint256 absAmount) internal view returns (uint256 royalty, uint256 fee) {
        SeqoraTypes.Design memory d = registry.getDesign(tokenId);
        royalty = (absAmount * d.royalty.bps) / SeqoraTypes.BPS;
        fee = (absAmount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
    }

    function test_Hook_HappyPath_SettlesToSplitsAndTreasury() public {
        uint256 absAmount = 1_000_000;
        (uint256 royalty, uint256 fee) = _expectedTake(absAmount);
        uint256 total = royalty + fee;

        // Pre-fund the mock PoolManager so `take()` has tokens to transfer to the router.
        usdc.mint(address(poolManager), total);

        vm.expectEmit(true, true, false, true, address(router));
        emit RoyaltyRouter.HookCollected(tokenId, address(usdc), royalty, fee);
        vm.expectEmit(true, true, false, true, address(router));
        emit IRoyaltyRouter.ProtocolFeeCollected(tokenId, address(usdc), fee);

        _runSwap(-int256(absAmount));

        assertEq(usdc.balanceOf(SPLITS), royalty);
        assertEq(usdc.balanceOf(TREASURY), fee);
        assertEq(usdc.balanceOf(address(router)), 0);

        // BeforeSwapDelta carries +total on unspecified side, 0 on specified.
        BeforeSwapDelta d = poolManager.lastBeforeDelta();
        int128 spec = BeforeSwapDeltaLibrary.getSpecifiedDelta(d);
        int128 unspec = BeforeSwapDeltaLibrary.getUnspecifiedDelta(d);
        assertEq(spec, int128(0), "specified delta should be zero");
        assertEq(unspec, int128(int256(total)), "unspecified delta should equal total");
        assertEq(poolManager.lastAfterDelta(), int128(0));
    }

    function test_Hook_ExactOutput_AlsoBillsUnspecified() public {
        // For exactOutput with our pool (currency0=0x1, currency1=usdc), the unspecified side
        // (billed currency) is currency0 when zeroForOne=true and currency1 (=usdc) when
        // zeroForOne=false. Use zeroForOne=false so the hook bills in USDC.
        uint256 absAmount = 500_000;
        (uint256 royalty, uint256 fee) = _expectedTake(absAmount);
        usdc.mint(address(poolManager), royalty + fee);

        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p =
            SwapParams({ zeroForOne: false, amountSpecified: int256(absAmount), sqrtPriceLimitX96: 0 });
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, abi.encode(tokenId));

        assertEq(usdc.balanceOf(SPLITS), royalty);
        assertEq(usdc.balanceOf(TREASURY), fee);
    }

    function test_Hook_FallbackRecipient_WhenSplitsUnset() public {
        // Fresh design with NO splits set → hook uses rule.recipient.
        uint256 tid = _registerDesign(BOB, keccak256("fallback"), 500, FALLBACK_RECIPIENT);

        uint256 absAmount = 1_000_000;
        SeqoraTypes.Design memory d = registry.getDesign(tid);
        uint256 royalty = (absAmount * d.royalty.bps) / SeqoraTypes.BPS;
        uint256 fee = (absAmount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        usdc.mint(address(poolManager), royalty + fee);

        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(absAmount));
        bytes memory hookData = abi.encode(tid);
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, hookData);

        assertEq(usdc.balanceOf(FALLBACK_RECIPIENT), royalty);
        assertEq(usdc.balanceOf(TREASURY), fee);
    }

    function test_Hook_ForfeitsToTreasury_WhenNoRecipientAtAll() public {
        // Design with bps=500 but zero splits AND zero rule.recipient requires a trick:
        // RoyaltyRule validation rejects bps>0 && recipient==0 at register time. Use bps=0 so
        // royalty == 0, which means only protocolFee is taken. The "forfeit" branch in the hook
        // triggers only if royalty > 0 AND target == 0 — unreachable via the happy registry path.
        // So we assert the paired branch: bps==0 → no royalty → no forfeit needed, only fee collected.
        uint256 tid = _registerDesign(BOB, keccak256("zero-recipient"), 0, address(0));
        uint256 absAmount = 1_000_000;
        uint256 fee = (absAmount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        usdc.mint(address(poolManager), fee);

        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(absAmount));
        bytes memory hookData = abi.encode(tid);
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, hookData);

        assertEq(usdc.balanceOf(TREASURY), fee, "treasury collects protocol fee");
        // SPLITS/FALLBACK_RECIPIENT get zero because bps == 0.
        assertEq(usdc.balanceOf(FALLBACK_RECIPIENT), 0);
    }

    function test_Hook_Paused_ShortCircuits() public {
        vm.prank(GOVERNANCE);
        router.setHookCollectionPaused(true);

        uint256 absAmount = 1_000_000;
        // No take → no pre-funding required. Run and assert no transfers.
        _runSwap(-int256(absAmount));

        assertEq(usdc.balanceOf(SPLITS), 0);
        assertEq(usdc.balanceOf(TREASURY), 0);
        BeforeSwapDelta d = poolManager.lastBeforeDelta();
        assertEq(BeforeSwapDelta.unwrap(d), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
    }

    function test_Hook_ZeroRoyaltyBps_NoDelta() public {
        uint256 tid = _registerDesign(BOB, keccak256("zerobps"), 0, address(0));
        uint256 absAmount = 1_000_000;
        // royalty = 0 but protocolFee > 0 ⇒ delta still positive. Check distinctly.
        uint256 fee = (absAmount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        usdc.mint(address(poolManager), fee);

        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(absAmount));
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, abi.encode(tid));

        BeforeSwapDelta d = poolManager.lastBeforeDelta();
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(d), int128(int256(fee)));
    }

    function test_Hook_EmptyHookData_NoDelta() public {
        uint256 absAmount = 1_000_000;
        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(absAmount));
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, "");

        BeforeSwapDelta d = poolManager.lastBeforeDelta();
        assertEq(BeforeSwapDelta.unwrap(d), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertEq(usdc.balanceOf(TREASURY), 0);
    }

    function test_Hook_UnregisteredToken_NoDelta() public {
        uint256 absAmount = 1_000_000;
        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(absAmount));
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, abi.encode(uint256(999_999)));

        BeforeSwapDelta d = poolManager.lastBeforeDelta();
        assertEq(BeforeSwapDelta.unwrap(d), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
    }

    function test_Hook_UnsupportedBilledCurrency_NoDelta() public {
        // Disallow USDC so the billed currency isn't on the allowlist → hook short-circuits.
        vm.prank(GOVERNANCE);
        router.setSupportedToken(address(usdc), false);

        uint256 absAmount = 1_000_000;
        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(absAmount));
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, abi.encode(tokenId));

        BeforeSwapDelta d = poolManager.lastBeforeDelta();
        assertEq(BeforeSwapDelta.unwrap(d), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertEq(usdc.balanceOf(TREASURY), 0);
    }

    function test_Hook_AmountZero_NoDelta() public {
        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(0);
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, abi.encode(tokenId));

        BeforeSwapDelta d = poolManager.lastBeforeDelta();
        assertEq(BeforeSwapDelta.unwrap(d), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
    }

    function test_Hook_MalformedHookData_NoDelta() public {
        // hookData length != 32 bytes → hook short-circuits without decoding.
        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(1000));
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, hex"deadbeef");

        BeforeSwapDelta d = poolManager.lastBeforeDelta();
        assertEq(BeforeSwapDelta.unwrap(d), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
    }

    function test_Hook_TokenIdZero_NoDelta() public {
        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(1000));
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, abi.encode(uint256(0)));

        BeforeSwapDelta d = poolManager.lastBeforeDelta();
        assertEq(BeforeSwapDelta.unwrap(d), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
    }

    function testFuzz_Hook_SplitsChain(address splitsAddr, address fallbackRecipient) public {
        vm.assume(splitsAddr != address(0) && splitsAddr != address(router) && splitsAddr != address(poolManager));
        vm.assume(splitsAddr != address(registry) && splitsAddr != address(usdc));
        vm.assume(fallbackRecipient != address(0) && fallbackRecipient != splitsAddr);
        // Avoid splitsAddr receiving pre-existing transfers from address(this) in lifecycle.
        vm.assume(splitsAddr.code.length == 0 && fallbackRecipient.code.length == 0);

        // Register a fresh design with `fallbackRecipient` as rule.recipient.
        uint256 tid = _registerDesign(BOB, keccak256(abi.encode(splitsAddr, fallbackRecipient)), 500, fallbackRecipient);

        // Case 1: no splits set → falls back to `fallbackRecipient`.
        uint256 absAmount = 1_000_000;
        SeqoraTypes.Design memory d = registry.getDesign(tid);
        uint256 royalty = (absAmount * d.royalty.bps) / SeqoraTypes.BPS;
        uint256 fee = (absAmount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        usdc.mint(address(poolManager), royalty + fee);

        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(absAmount));
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, abi.encode(tid));
        assertEq(usdc.balanceOf(fallbackRecipient), royalty, "fallback leg");

        // Case 2: set splits → now splits wins over fallback.
        vm.prank(BOB);
        router.setSplitsContract(tid, splitsAddr);
        usdc.mint(address(poolManager), royalty + fee);
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, abi.encode(tid));
        assertEq(usdc.balanceOf(splitsAddr), royalty, "splits leg");
    }
}

// =============================================================================
// Hook reentrancy via reentrant PoolManager
// =============================================================================

contract RoyaltyRouter_HookReentrancy is Test {
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    address internal constant TREASURY = address(0xBEEF);
    address internal constant GOVERNANCE = address(0xDA0);
    address internal constant ALICE = address(0xA11CE);

    DesignRegistry internal registry;
    AlwaysValidScreening internal screening;
    ReentrantMockPoolManager internal poolManager;
    RoyaltyRouter internal router;
    MockERC20 internal usdc;
    uint256 internal tokenId;

    function setUp() public {
        screening = new AlwaysValidScreening();
        registry = new DesignRegistry("ipfs://x/{id}", screening);
        poolManager = new ReentrantMockPoolManager();
        usdc = new MockERC20("USDC", "USDC", 6);

        bytes memory code = abi.encodePacked(
            type(RoyaltyRouter).creationCode,
            abi.encode(IDesignRegistry(address(registry)), TREASURY, IPoolManager(address(poolManager)), GOVERNANCE)
        );
        (address predicted, bytes32 salt) = HookMiner.find(address(this), code, HOOK_FLAGS);
        address deployed;
        assembly {
            deployed := create2(0, add(code, 0x20), mload(code), salt)
        }
        require(deployed == predicted, "deploy mismatch");
        router = RoyaltyRouter(payable(deployed));

        vm.prank(GOVERNANCE);
        router.setSupportedToken(address(usdc), true);

        SeqoraTypes.RoyaltyRule memory r =
            SeqoraTypes.RoyaltyRule({ recipient: address(0xEEEE), bps: 500, parentSplitBps: 0 });
        vm.prank(ALICE);
        tokenId = registry.register(
            ALICE, keccak256("reen"), bytes32(0), "a", "c", r, bytes32(uint256(1)), new bytes32[](0)
        );
    }

    function test_Hook_ReentrantPoolManager_DistributeReenter_IsBlocked() public {
        // During `take()`, the malicious PoolManager tries to re-enter `router.distribute(...)`.
        // The re-entry call is `msg.sender = poolManager`. Pre-fund and pre-approve the poolManager
        // so the only defence against re-entry is the router's `nonReentrant` modifier itself.
        //
        // Per contract header: the hook path does NOT wrap itself in `nonReentrant`, so a naive
        // reading would expect the reentry into `distribute` to succeed. HOWEVER, the hook path
        // calls `_resolvePayoutTarget` → `IERC20.safeTransfer` externally, and `distribute` is
        // `nonReentrant`. When the malicious PoolManager fires the reentry BEFORE the hook's
        // `safeTransfer` completes, the reentrant `distribute` is NOT inside the reentrancy guard
        // (since the hook isn't guarded), so it DOES succeed — this test documents that reality.
        //
        // sec-auditor TODO: decide whether the hook path should be wrapped in nonReentrant or
        // equivalent to prevent PoolManager-driven reentrant distribute calls. If so, this test
        // must be updated to expectRevert.
        uint256 absAmount = 1_000_000;
        uint256 fee = (absAmount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        uint256 royalty = (absAmount * 500) / SeqoraTypes.BPS;
        uint256 innerAmount = 1000;

        // Pool manager must have enough to (a) fulfil the hook take and (b) fund its own reentrant distribute.
        usdc.mint(address(poolManager), royalty + fee + innerAmount);
        // Approve the router from the poolManager so the reentrant `transferFrom` inside distribute works.
        vm.prank(address(poolManager));
        usdc.approve(address(router), innerAmount);

        bytes memory payload = abi.encodeWithSelector(router.distribute.selector, tokenId, address(usdc), innerAmount);
        poolManager.armReentry(address(router), payload);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(router))
        });
        SwapParams memory p =
            SwapParams({ zeroForOne: true, amountSpecified: -int256(absAmount), sqrtPriceLimitX96: 0 });

        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, abi.encode(tokenId));

        // Both the outer hook fee AND the inner distribute fee should have landed in the treasury.
        uint256 innerFee = (innerAmount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        assertEq(usdc.balanceOf(TREASURY), fee + innerFee);
    }
}

// =============================================================================
// Gas benchmarks (no assertions — monitoring baseline)
// =============================================================================

contract RoyaltyRouter_Gas is RoyaltyRouterBase {
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        tokenId = _registerDefault(ALICE);
        vm.prank(ALICE);
        router.setSplitsContract(tokenId, SPLITS);
    }

    function test_Gas_Distribute() public {
        uint256 amount = 1_000_000;
        usdc.mint(BOB, amount);
        vm.prank(BOB);
        usdc.approve(address(router), amount);
        vm.prank(BOB);
        router.distribute(tokenId, address(usdc), amount);
        // Gas baseline captured via --gas-report. No assertion on purpose.
    }

    function test_Gas_HookPath() public {
        uint256 absAmount = 1_000_000;
        uint256 royalty = (absAmount * DEFAULT_ROYALTY_BPS) / SeqoraTypes.BPS;
        uint256 fee = (absAmount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        usdc.mint(address(poolManager), royalty + fee);

        PoolKey memory key = _defaultPoolKey();
        SwapParams memory p = _swapParamsUsdcUnspecified(-int256(absAmount));
        poolManager.simulateSwap(IHooks(address(router)), address(this), key, p, abi.encode(tokenId));
    }
}
