// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BalanceDelta, toBalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @title MockPoolManager
/// @notice Minimal v4 PoolManager stub for exercising hook callbacks. NO real pool math.
/// @dev Implements only the surface the `RoyaltyRouter` hook actually calls:
///        - `take(currency, to, amount)` is invoked from `afterSwap` and transfers ERC-20 balance
///          that tests pre-fund into this mock out to the requested recipient.
///        - `simulateSwap` is a test entrypoint that fires `beforeSwap` then `afterSwap` on the
///          hook with the given `key`/`params`/`hookData`, mimicking the real PoolManager's
///          single-unlock lifecycle.
///        Everything else on IPoolManager is left unimplemented — tests only need these.
contract MockPoolManager {
    /// @notice Last `BeforeSwapDelta` returned by the hook, captured for assertions.
    BeforeSwapDelta public lastBeforeDelta;
    /// @notice Last `int128` afterSwap delta returned by the hook, captured for assertions.
    int128 public lastAfterDelta;
    /// @notice Last selector returned from beforeSwap (sanity).
    bytes4 public lastBeforeSelector;
    /// @notice Last selector returned from afterSwap (sanity).
    bytes4 public lastAfterSelector;

    /// @notice Drive a mock swap through `hook`, firing beforeSwap then afterSwap sequentially.
    /// @dev BalanceDelta passed to afterSwap is synthesised as zero — the RoyaltyRouter hook does
    ///      not read it. `sender` is forwarded as `msg.sender` of the simulated caller.
    function simulateSwap(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external {
        (bytes4 sel0, BeforeSwapDelta delta0, uint24 feeOverride) = hook.beforeSwap(sender, key, params, hookData);
        lastBeforeSelector = sel0;
        lastBeforeDelta = delta0;
        feeOverride; // silence unused-var notice

        BalanceDelta zero = toBalanceDelta(0, 0);
        (bytes4 sel1, int128 unspec) = hook.afterSwap(sender, key, params, zero, hookData);
        lastAfterSelector = sel1;
        lastAfterDelta = unspec;
    }

    /// @notice PoolManager.take stub — transfers `amount` of `currency` out of this mock to `to`.
    /// @dev Tests must pre-fund this mock with enough of the currency via MockERC20.mint(...).
    function take(Currency currency, address to, uint256 amount) external {
        address token = Currency.unwrap(currency);
        require(token != address(0), "MockPoolManager: native unsupported");
        require(IERC20(token).transfer(to, amount), "MockPoolManager: take transfer failed");
    }

    /// @notice Accept ETH for parity with the real PoolManager (not used in Seqora v1).
    receive() external payable { }
}

/// @notice Variant of MockPoolManager that reenters the hook target during `take`.
/// @dev Used to assert the hook's defences. `take` calls `reentryTarget` with `reentryData`
///      BEFORE transferring tokens so the re-entry happens mid-callback — if the target's
///      `distribute` (or any `nonReentrant` path) is reachable this way, the guard must stop it.
contract ReentrantMockPoolManager {
    address public reentryTarget;
    bytes public reentryData;

    function armReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function simulateSwap(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external {
        (bytes4 s,, uint24 f) = hook.beforeSwap(sender, key, params, hookData);
        s;
        f;
        BalanceDelta zero = toBalanceDelta(0, 0);
        hook.afterSwap(sender, key, params, zero, hookData);
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (reentryTarget != address(0)) {
            address t = reentryTarget;
            bytes memory d = reentryData;
            reentryTarget = address(0);
            delete reentryData;
            (bool ok, bytes memory ret) = t.call(d);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        address token = Currency.unwrap(currency);
        require(token != address(0), "ReentrantMockPoolManager: native unsupported");
        require(IERC20(token).transfer(to, amount), "ReentrantMockPoolManager: take transfer failed");
    }

    receive() external payable { }
}
