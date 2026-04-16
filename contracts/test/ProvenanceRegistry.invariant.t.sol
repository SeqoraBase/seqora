// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { DesignRegistry } from "../src/DesignRegistry.sol";
import { ProvenanceRegistry } from "../src/ProvenanceRegistry.sol";
import { IProvenanceRegistry } from "../src/interfaces/IProvenanceRegistry.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";

import { AlwaysValidScreening } from "./helpers/MockScreening.sol";
import { ProvenanceRegistryHandler } from "./handlers/ProvenanceRegistryHandler.sol";
import { ProvenanceSigning } from "./helpers/ProvenanceSigning.sol";

/// @notice State-machine invariants for ProvenanceRegistry.
///         64 runs × 50 calls per run (per brief).
contract ProvenanceRegistry_Invariant_Test is Test {
    AlwaysValidScreening internal screening;
    DesignRegistry internal designs;
    ProvenanceRegistry internal provenance;
    ProvenanceRegistryHandler internal handler;

    address internal constant OWNER = address(0x0AFE);

    // Last-observed counts per tokenId, for monotonicity check.
    mapping(uint256 => uint256) internal _lastCount;

    function setUp() public {
        screening = new AlwaysValidScreening();
        designs = new DesignRegistry("ipfs://seqora/{id}.json", screening);
        provenance = new ProvenanceRegistry(designs, OWNER);
        handler = new ProvenanceRegistryHandler(designs, provenance, OWNER);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ProvenanceRegistryHandler.recordModelCard.selector;
        selectors[1] = ProvenanceRegistryHandler.recordWetLab.selector;
        selectors[2] = ProvenanceRegistryHandler.toggleOracle.selector;
        selectors[3] = ProvenanceRegistryHandler.localRevoke.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_RecordCountIsMonotone() public {
        uint256 n = handler.tokenIdsLength();
        for (uint256 i = 0; i < n; i++) {
            uint256 tid = handler.tokenIdAt(i);
            uint256 current = provenance.getRecordCount(tid);
            assertGe(current, _lastCount[tid], "record count must only grow");
            _lastCount[tid] = current;
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_DuplicateHashNeverStoredTwice() public view {
        uint256 n = handler.tokenIdsLength();
        for (uint256 i = 0; i < n; i++) {
            uint256 tid = handler.tokenIdAt(i);
            SeqoraTypes.ProvenanceRecord[] memory list = provenance.getProvenance(tid);
            // Bounded quadratic dup check. Handler call budget caps list size to ~50.
            for (uint256 a = 0; a < list.length; a++) {
                for (uint256 b = a + 1; b < list.length; b++) {
                    assertTrue(list[a].recordHash != list[b].recordHash, "duplicate recordHash within tokenId");
                }
            }
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_LocallyRevokedStaysRevoked() public view {
        uint256 n = handler.recordsLength();
        for (uint256 i = 0; i < n; i++) {
            (uint256 tid, bytes32 h) = handler.recordAt(i);
            if (handler.isLocallyRevoked(h)) {
                assertFalse(provenance.isRecordValid(tid, h), "revoked record must not be valid");
                assertTrue(provenance.locallyRevoked(h), "locallyRevoked flag must persist");
            }
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_PaginationTotalMatchesCount() public view {
        uint256 n = handler.tokenIdsLength();
        for (uint256 i = 0; i < n; i++) {
            uint256 tid = handler.tokenIdAt(i);
            (, uint256 total) = provenance.getRecordsByTokenId(tid, 0, provenance.MAX_PAGE_LIMIT());
            assertEq(total, provenance.getRecordCount(tid), "pagination total == recordCount");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_OnlyApprovedOracleCanAttest() public {
        // Build a fresh attestation with a currently NON-approved oracle. Attempt a submission
        // and assert it reverts. Do not persist the attempt (we expect revert).
        uint256 oCount = handler.oraclesLength();
        for (uint256 i = 0; i < oCount; i++) {
            (address orc, uint256 pk) = handler.oracleAt(i);
            if (provenance.isOracleApproved(orc)) continue;
            if (handler.tokenIdsLength() == 0) return;
            uint256 tid = handler.tokenIdAt(0);

            SeqoraTypes.WetLabAttestation memory att = SeqoraTypes.WetLabAttestation({
                tokenId: tid,
                oracle: orc,
                vendor: "inv",
                orderRef: "inv",
                synthesizedAt: uint64(block.timestamp),
                payloadHash: keccak256(abi.encode("inv-att", i, block.number))
            });
            bytes memory sig = ProvenanceSigning.signWetLabAttestation(pk, att, provenance);
            vm.expectRevert(abi.encodeWithSelector(IProvenanceRegistry.OracleNotApproved.selector, orc));
            provenance.recordWetLabAttestation(tid, att, sig);
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_CallSummary() public view {
        // Non-assertive log so the suite surfaces handler coverage.
        assertGe(
            handler.modelCardAttempts() + handler.wetLabAttempts() + handler.oracleToggleAttempts()
                + handler.revokeAttempts(),
            0
        );
    }
}
