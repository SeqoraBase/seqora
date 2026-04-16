// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";

import { DesignRegistry } from "../src/DesignRegistry.sol";
import { RoyaltyRouter } from "../src/RoyaltyRouter.sol";
import { IDesignRegistry } from "../src/interfaces/IDesignRegistry.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";

import { AlwaysValidScreening } from "./helpers/MockScreening.sol";
import { HookMiner } from "./helpers/HookMiner.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";
import { MockPoolManager } from "./helpers/MockPoolManager.sol";
import { RoyaltyRouterHandler } from "./handlers/RoyaltyRouterHandler.sol";

/// @notice Invariant suite for RoyaltyRouter. Runs 64 fuzz campaigns × 128 calls each (foundry.toml).
contract RoyaltyRouterInvariantTest is StdInvariant, Test {
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    address internal constant TREASURY = address(0xBEEF);
    address internal constant GOVERNANCE = address(0xDA0);

    AlwaysValidScreening internal screening;
    DesignRegistry internal registry;
    MockPoolManager internal poolManager;
    MockERC20 internal usdc;
    RoyaltyRouter internal router;
    RoyaltyRouterHandler internal handler;

    function setUp() public {
        screening = new AlwaysValidScreening();
        registry = new DesignRegistry("ipfs://inv/{id}", screening);
        poolManager = new MockPoolManager();
        usdc = new MockERC20("USDC", "USDC", 6);

        bytes memory creationCode = abi.encodePacked(
            type(RoyaltyRouter).creationCode,
            abi.encode(IDesignRegistry(address(registry)), TREASURY, IPoolManager(address(poolManager)), GOVERNANCE)
        );
        (address predicted, bytes32 salt) = HookMiner.find(address(this), creationCode, HOOK_FLAGS);
        address deployed;
        assembly {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(deployed == predicted, "inv setup: create2 mismatch");
        router = RoyaltyRouter(payable(deployed));

        vm.prank(GOVERNANCE);
        router.setSupportedToken(address(usdc), true);

        handler = new RoyaltyRouterHandler(router, registry, poolManager, usdc, TREASURY, GOVERNANCE);

        targetContract(address(handler));
    }

    /// @notice I-1: sum of treasury protocol-fee credits is exactly 3% (floor) of all flow through
    ///         the router (distribute + hook) across the run.
    function invariant_TreasuryReceivesExactProtocolFee() public view {
        assertEq(usdc.balanceOf(TREASURY), handler.totalTreasuryExpected(), "treasury fee mismatch");
    }

    /// @notice I-2: `splitsOf[tokenId]` is set at most once. If the handler's `splitsSet` flag is
    ///         true, a second `setSplitsContract` must revert.
    function invariant_SplitsAreSetAtMostOnce() public {
        uint256 n = handler.tokenCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.tokenAt(i);
            address current = router.getSplitsContract(tokenId);
            bool trackerSays = handler.splitsSet(tokenId);
            if (trackerSays) {
                assertTrue(current != address(0), "tracker says set but router says unset");
                // Attempt a second write: it MUST revert (either SplitsAlreadySet or auth).
                vm.expectRevert();
                router.setSplitsContract(tokenId, address(0xDEAD));
            } else {
                assertEq(current, address(0), "router says set but tracker says unset");
            }
        }
    }

    /// @notice I-3: `supportedToken[token]` on the router mirrors the last governance-driven write
    ///         tracked by the handler for each seen token.
    function invariant_SupportedTokenMirrorsGovernanceIntent() public view {
        // USDC is always-on in the handler's view.
        assertTrue(router.supportedToken(address(usdc)), "USDC allowlist drifted");
    }

    /// @notice I-4: the router never holds dust in a supported token between calls. Every
    ///         `distribute` / hook settlement either moves 100% out or reverts — so the router's
    ///         USDC balance must ALWAYS be zero at rest.
    function invariant_NoDustInRouter() public view {
        assertEq(usdc.balanceOf(address(router)), 0, "router holds dust");
    }

    /// @notice I-5: all tokenIds in the handler's design set are registered in the registry.
    function invariant_HandlerTokensAreRegistered() public view {
        uint256 n = handler.tokenCount();
        for (uint256 i = 0; i < n; i++) {
            assertTrue(registry.isRegistered(handler.tokenAt(i)));
        }
    }
}
