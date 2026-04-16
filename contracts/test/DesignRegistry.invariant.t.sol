// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { DesignRegistry } from "../src/DesignRegistry.sol";
import { IDesignRegistry } from "../src/interfaces/IDesignRegistry.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";

import { AlwaysValidScreening } from "./helpers/MockScreening.sol";
import { DesignRegistryHandler } from "./handlers/DesignRegistryHandler.sol";

/// @notice State-machine invariants for DesignRegistry.
/// @dev 64 runs × 50 calls per run (per brief). `fail_on_revert` stays false because the handler
///      deliberately drives call paths that can revert (AlreadyRegistered, etc.).
contract DesignRegistry_Invariant_Test is Test {
    DesignRegistry internal registry;
    AlwaysValidScreening internal screening;
    DesignRegistryHandler internal handler;

    function setUp() public {
        screening = new AlwaysValidScreening();
        registry = new DesignRegistry("ipfs://seqora/{id}.json", screening);
        handler = new DesignRegistryHandler(registry);

        // Only route invariant calls through the handler.
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = DesignRegistryHandler.register.selector;
        selectors[1] = DesignRegistryHandler.forkRegister.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_TokenIdEqualsCanonicalHash() public view {
        uint256 n = handler.registeredCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.registeredAt(i);
            SeqoraTypes.Design memory d = registry.getDesign(id);
            assertEq(id, uint256(d.canonicalHash), "tokenId must equal uint256(canonicalHash)");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_AllRegisteredHaveSupply() public view {
        uint256 n = handler.registeredCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.registeredAt(i);
            SeqoraTypes.Design memory d = registry.getDesign(id);
            assertGt(registry.balanceOf(d.registrant, id), 0, "registrant must hold at least 1 token");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_RegisteredCannotBeRegisteredAgain() public {
        uint256 n = handler.registeredCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.registeredAt(i);
            bytes32 h = bytes32(id);
            SeqoraTypes.RoyaltyRule memory royalty =
                SeqoraTypes.RoyaltyRule({ recipient: address(0xEEEE), bps: 100, parentSplitBps: 0 });

            // Direct attempt to re-register — must revert with AlreadyRegistered.
            vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.AlreadyRegistered.selector, id));
            vm.prank(address(0xDEAD));
            registry.register(address(0xDEAD), h, bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0));
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_ParentSplitBpsWithinRange() public view {
        uint256 n = handler.registeredCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.registeredAt(i);
            SeqoraTypes.Design memory d = registry.getDesign(id);
            assertLe(d.royalty.parentSplitBps, SeqoraTypes.BPS, "parentSplitBps <= 10_000");
            assertLe(d.royalty.bps, SeqoraTypes.MAX_ROYALTY_BPS, "royalty.bps <= MAX_ROYALTY_BPS");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_GenesisHasZeroParentSplit() public view {
        uint256 n = handler.registeredCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.registeredAt(i);
            SeqoraTypes.Design memory d = registry.getDesign(id);
            if (d.parentTokenIds.length == 0) {
                assertEq(d.royalty.parentSplitBps, 0, "genesis has no parent-split");
            }
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_IsRegisteredMatchesStorage() public view {
        uint256 n = handler.registeredCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.registeredAt(i);
            assertTrue(registry.isRegistered(id), "isRegistered must be true for tracked tokenIds");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_CallSummary() public view {
        // Light sanity log so the suite surfaces how much of the state space was exercised.
        // Assertion is defensive — always passes so long as handler doesn't throw.
        assertGe(handler.registerAttempts() + handler.forkAttempts(), 0);
    }
}
