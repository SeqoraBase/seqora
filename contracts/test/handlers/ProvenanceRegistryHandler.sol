// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { DesignRegistry } from "../../src/DesignRegistry.sol";
import { ProvenanceRegistry } from "../../src/ProvenanceRegistry.sol";
import { SeqoraTypes } from "../../src/libraries/SeqoraTypes.sol";

import { ProvenanceSigning } from "../helpers/ProvenanceSigning.sol";

/// @notice Handler for ProvenanceRegistry invariant tests.
/// @dev Bounds:
///      - A tiny fixed pool of tokenIds (pre-registered genesis designs on the DesignRegistry).
///      - A fixed oracle private-key bank with known addresses that may be added/removed.
///      - Every fuzz seed is bounded to actor/oracle indices or tokenId indices.
///
///      The handler tracks:
///      - All (tokenId, recordHash) pairs ever attempted.
///      - All recordHashes locally revoked.
///      - Whether each oracle key is currently approved.
contract ProvenanceRegistryHandler is CommonBase, StdCheats, StdUtils {
    DesignRegistry public immutable designRegistry;
    ProvenanceRegistry public immutable provenance;
    address public immutable OWNER;

    // -------- Token ids --------
    uint256[] internal _tokenIds;

    // -------- Oracle bank --------
    uint256[] internal _oraclePks;
    address[] internal _oracles;

    // -------- Contributor bank for ModelCards --------
    uint256[] internal _contribPks;
    address[] internal _contribs;

    // -------- Record tracking --------
    struct RecordSeen {
        uint256 tokenId;
        bytes32 recordHash;
    }

    RecordSeen[] internal _allRecords;
    mapping(uint256 => mapping(bytes32 => bool)) internal _seen;
    mapping(bytes32 => bool) public revoked;

    // -------- Counters for run summary --------
    uint256 public modelCardAttempts;
    uint256 public modelCardSuccesses;
    uint256 public wetLabAttempts;
    uint256 public wetLabSuccesses;
    uint256 public revokeAttempts;
    uint256 public revokeSuccesses;
    uint256 public oracleToggleAttempts;

    // Salt counter to ensure unique struct payloads across handler calls.
    uint256 internal _saltCounter;

    constructor(DesignRegistry designRegistry_, ProvenanceRegistry provenance_, address owner_) {
        designRegistry = designRegistry_;
        provenance = provenance_;
        OWNER = owner_;

        // Pre-register a handful of genesis tokenIds so record submissions can land somewhere.
        address[3] memory regs = [address(0xA11CE), address(0xB0B), address(0xCA401)];
        for (uint256 i = 0; i < regs.length; i++) {
            bytes32 canonical = bytes32(uint256(keccak256(abi.encode("h-gen", i))) & type(uint64).max);
            SeqoraTypes.RoyaltyRule memory royalty =
                SeqoraTypes.RoyaltyRule({ recipient: address(0xEEEE), bps: 100, parentSplitBps: 0 });
            vm.prank(regs[i]);
            uint256 id = designRegistry.register(
                regs[i], canonical, bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0)
            );
            _tokenIds.push(id);
        }

        // Build a fixed oracle bank and approve the first two by default.
        uint256[4] memory pks = [uint256(0x1001), uint256(0x1002), uint256(0x1003), uint256(0x1004)];
        for (uint256 i = 0; i < pks.length; i++) {
            _oraclePks.push(pks[i]);
            _oracles.push(vm.addr(pks[i]));
        }
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(OWNER);
            provenance.registerOracle(_oracles[i]);
        }

        uint256[3] memory cpks = [uint256(0x2001), uint256(0x2002), uint256(0x2003)];
        for (uint256 i = 0; i < cpks.length; i++) {
            _contribPks.push(cpks[i]);
            _contribs.push(vm.addr(cpks[i]));
        }
    }

    // -------------------------------------------------------------------------
    // View helpers for invariant iteration
    // -------------------------------------------------------------------------

    function tokenIdsLength() external view returns (uint256) {
        return _tokenIds.length;
    }

    function tokenIdAt(uint256 i) external view returns (uint256) {
        return _tokenIds[i];
    }

    function recordsLength() external view returns (uint256) {
        return _allRecords.length;
    }

    function recordAt(uint256 i) external view returns (uint256 tokenId, bytes32 recordHash) {
        RecordSeen memory r = _allRecords[i];
        return (r.tokenId, r.recordHash);
    }

    function oraclesLength() external view returns (uint256) {
        return _oracles.length;
    }

    function oracleAt(uint256 i) external view returns (address, uint256) {
        return (_oracles[i], _oraclePks[i]);
    }

    function isLocallyRevoked(bytes32 h) external view returns (bool) {
        return revoked[h];
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    function recordModelCard(uint256 tIdx, uint256 cIdx) external {
        modelCardAttempts++;
        uint256 tokenId = _tokenIds[tIdx % _tokenIds.length];
        uint256 pk = _contribPks[cIdx % _contribPks.length];
        address signer = _contribs[cIdx % _contribs.length];

        _saltCounter++;
        SeqoraTypes.ModelCard memory card = SeqoraTypes.ModelCard({
            weightsHash: keccak256(abi.encode("w", _saltCounter)),
            promptHash: keccak256(abi.encode("p", _saltCounter)),
            seed: bytes32(_saltCounter),
            toolName: "T",
            toolVersion: "v",
            contributor: signer,
            createdAt: uint64(block.timestamp)
        });
        bytes memory sig = ProvenanceSigning.signModelCard(pk, card, provenance);
        bytes32 digest = ProvenanceSigning.modelCardDigest(provenance, card);

        try provenance.recordModelCard(tokenId, card, sig) {
            if (!_seen[tokenId][digest]) {
                _allRecords.push(RecordSeen({ tokenId: tokenId, recordHash: digest }));
                _seen[tokenId][digest] = true;
            }
            modelCardSuccesses++;
        } catch {
            // paused/duplicate/etc. — swallow.
        }
    }

    function recordWetLab(uint256 tIdx, uint256 oIdx) external {
        wetLabAttempts++;
        uint256 tokenId = _tokenIds[tIdx % _tokenIds.length];
        uint256 pk = _oraclePks[oIdx % _oraclePks.length];
        address orc = _oracles[oIdx % _oraclePks.length];

        _saltCounter++;
        SeqoraTypes.WetLabAttestation memory att = SeqoraTypes.WetLabAttestation({
            oracle: orc,
            vendor: "V",
            orderRef: "O",
            synthesizedAt: uint64(block.timestamp),
            payloadHash: keccak256(abi.encode("hl", _saltCounter))
        });
        bytes memory sig = ProvenanceSigning.signWetLabAttestation(pk, att, provenance);
        bytes32 digest = ProvenanceSigning.wetLabDigest(provenance, att);

        try provenance.recordWetLabAttestation(tokenId, att, sig) {
            if (!_seen[tokenId][digest]) {
                _allRecords.push(RecordSeen({ tokenId: tokenId, recordHash: digest }));
                _seen[tokenId][digest] = true;
            }
            wetLabSuccesses++;
        } catch {
            // revoked oracle / paused / duplicate — swallow.
        }
    }

    function toggleOracle(uint256 oIdx, bool approved) external {
        oracleToggleAttempts++;
        address orc = _oracles[oIdx % _oraclePks.length];
        vm.prank(OWNER);
        try provenance.setOracleApproved(orc, approved) { } catch { }
    }

    function localRevoke(uint256 rIdx) external {
        revokeAttempts++;
        if (_allRecords.length == 0) return;
        RecordSeen memory r = _allRecords[rIdx % _allRecords.length];
        vm.prank(OWNER);
        try provenance.localRevoke(r.tokenId, r.recordHash) {
            revoked[r.recordHash] = true;
            revokeSuccesses++;
        } catch {
            // already revoked under a different tokenId? — idempotent path covers identical call
        }
    }

    /// @notice Expose the current approval status of an oracle index (mirror of contract view).
    function isOracleApproved(uint256 oIdx) external view returns (bool) {
        return provenance.isOracleApproved(_oracles[oIdx % _oraclePks.length]);
    }
}
