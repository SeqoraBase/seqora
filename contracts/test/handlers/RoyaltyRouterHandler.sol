// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";

import { DesignRegistry } from "../../src/DesignRegistry.sol";
import { RoyaltyRouter } from "../../src/RoyaltyRouter.sol";
import { SeqoraTypes } from "../../src/libraries/SeqoraTypes.sol";

import { MockERC20 } from "../helpers/MockERC20.sol";
import { MockPoolManager } from "../helpers/MockPoolManager.sol";

/// @notice Invariant handler for RoyaltyRouter.
/// @dev Bounds every input, tracks per-call accumulators, and exposes them as public state so the
///      invariant suite can reason about aggregate properties (fee-proportionality, dust-freedom,
///      token-allowlist consistency, splits-single-write).
contract RoyaltyRouterHandler is CommonBase, StdCheats, StdUtils {
    RoyaltyRouter public immutable router;
    DesignRegistry public immutable registry;
    MockPoolManager public immutable poolManager;
    MockERC20 public immutable usdc;
    address public immutable treasury;
    address public immutable governance;

    // Pool layout so the billed (input) currency is usdc on zeroForOne=false exactInput.
    address internal constant LOW_CURRENCY = address(0x1);

    address[] internal _actors;
    uint256[] internal _tokenIds;
    mapping(uint256 => address) internal _registrants;
    mapping(uint256 => bool) public splitsSet; // tracks each one-time splitSet
    mapping(address => bool) public tokenAllowed; // expected allowlist mirror

    // Aggregates for invariants
    uint256 public totalGrossDistributed; // sum of `amount` across all distribute successes
    uint256 public totalGrossHookCollected; // sum of absAmount * (royaltyBps + 300) / 10000 on hook successes
    uint256 public totalTreasuryExpected; // 3% of the two above combined (floor)
    uint256 public setSplitsAttempts;
    uint256 public setSplitsSuccesses;
    uint256 public distributeAttempts;
    uint256 public distributeSuccesses;
    uint256 public hookAttempts;
    uint256 public hookSuccesses;

    constructor(
        RoyaltyRouter r,
        DesignRegistry d,
        MockPoolManager pm,
        MockERC20 token,
        address treasury_,
        address governance_
    ) {
        router = r;
        registry = d;
        poolManager = pm;
        usdc = token;
        treasury = treasury_;
        governance = governance_;
        tokenAllowed[address(token)] = true;

        _actors.push(address(0xA11CE));
        _actors.push(address(0xB0B));
        _actors.push(address(0xCA401));
        _actors.push(address(0xDA4E));

        // Seed designs so the router has something to distribute against.
        for (uint256 i = 0; i < 3; i++) {
            _seedDesign(_actors[i], 500);
        }
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    function tokenCount() external view returns (uint256) {
        return _tokenIds.length;
    }

    function tokenAt(uint256 i) external view returns (uint256) {
        return _tokenIds[i];
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    function distribute(uint8 actorIdx, uint8 tokenIdx, uint128 amount) external {
        distributeAttempts++;
        if (_tokenIds.length == 0) return;
        uint256 amt = bound(uint256(amount), 1, 10_000_000);
        address payer = _actors[actorIdx % _actors.length];
        uint256 tokenId = _tokenIds[tokenIdx % _tokenIds.length];

        usdc.mint(payer, amt);
        vm.prank(payer);
        usdc.approve(address(router), amt);

        vm.prank(payer);
        try router.distribute(tokenId, address(usdc), amt) {
            distributeSuccesses++;
            totalGrossDistributed += amt;
            totalTreasuryExpected += (amt * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        } catch { }
    }

    function setSplits(uint8 tokenIdx, uint8 splitsSeed) external {
        setSplitsAttempts++;
        if (_tokenIds.length == 0) return;
        uint256 tokenId = _tokenIds[tokenIdx % _tokenIds.length];
        if (splitsSet[tokenId]) return;

        address splits = address(uint160(0xCAFE00 + uint256(splitsSeed)));
        address registrant = _registrants[tokenId];
        vm.prank(registrant);
        try router.setSplitsContract(tokenId, splits) {
            splitsSet[tokenId] = true;
            setSplitsSuccesses++;
        } catch { }
    }

    function toggleSupported(uint8 tokenSeed, bool on) external {
        // Toggle on a secondary token only (leave USDC always-on to keep distribute/hook paths live).
        address token = address(uint160(0xABCD000 + uint256(tokenSeed)));
        vm.prank(governance);
        try router.setSupportedToken(token, on) {
            tokenAllowed[token] = on;
        } catch { }
    }

    function hookSwap(uint8 actorIdx, uint8 tokenIdx, uint128 absAmount) external {
        hookAttempts++;
        if (_tokenIds.length == 0) return;
        uint256 amt = bound(uint256(absAmount), 1, 1_000_000);
        uint256 tokenId = _tokenIds[tokenIdx % _tokenIds.length];
        address sender = _actors[actorIdx % _actors.length];

        SeqoraTypes.Design memory d = registry.getDesign(tokenId);
        uint256 royalty = (amt * d.royalty.bps) / SeqoraTypes.BPS;
        uint256 fee = (amt * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        usdc.mint(address(poolManager), royalty + fee);

        (address c0, address c1) =
            LOW_CURRENCY < address(usdc) ? (LOW_CURRENCY, address(usdc)) : (address(usdc), LOW_CURRENCY);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(router))
        });
        // Post H-01 fix: zeroForOne=false so usdc (currency1) is the input (billed) currency.
        SwapParams memory p = SwapParams({ zeroForOne: false, amountSpecified: -int256(amt), sqrtPriceLimitX96: 0 });

        try poolManager.simulateSwap(IHooks(address(router)), sender, key, p, abi.encode(tokenId)) {
            hookSuccesses++;
            totalGrossHookCollected += royalty + fee;
            totalTreasuryExpected += fee;
        } catch { }
    }

    // -------------------------------------------------------------------------
    // Seeding
    // -------------------------------------------------------------------------

    function _seedDesign(address registrant, uint16 bps) internal {
        bytes32 canonical = keccak256(abi.encode("RR-H", registrant, _tokenIds.length));
        SeqoraTypes.RoyaltyRule memory r =
            SeqoraTypes.RoyaltyRule({ recipient: address(0xEEEE), bps: bps, parentSplitBps: 0 });
        vm.prank(registrant);
        uint256 tokenId =
            registry.register(registrant, canonical, bytes32(0), "a", "c", r, bytes32(uint256(1)), new bytes32[](0));
        _tokenIds.push(tokenId);
        _registrants[tokenId] = registrant;
    }
}
