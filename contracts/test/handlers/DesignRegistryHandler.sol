// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { DesignRegistry } from "../../src/DesignRegistry.sol";
import { SeqoraTypes } from "../../src/libraries/SeqoraTypes.sol";

/// @notice Invariant-test handler. Bounds inputs so calls land on meaningful code paths.
/// @dev Exposes `register` and `forkRegister` wrappers with sane bounds; tracks every successful
///      registration so the invariant suite can iterate over live tokenIds.
contract DesignRegistryHandler is CommonBase, StdCheats, StdUtils {
    DesignRegistry public immutable registry;

    // Successful registrations tracked for invariant iteration.
    uint256[] internal _registered;

    // Actor bank — bounded so fuzzing reuses the same addresses.
    address[] internal _actors;

    // Counters for handler call metrics.
    uint256 public registerAttempts;
    uint256 public registerSuccesses;
    uint256 public forkAttempts;
    uint256 public forkSuccesses;

    constructor(DesignRegistry registry_) {
        registry = registry_;
        _actors.push(address(0xA11CE));
        _actors.push(address(0xB0B));
        _actors.push(address(0xCA401));
        _actors.push(address(0xD00D));
    }

    // -------------------------------------------------------------------------
    // View helpers for invariant assertions
    // -------------------------------------------------------------------------

    function registeredCount() external view returns (uint256) {
        return _registered.length;
    }

    function registeredAt(uint256 i) external view returns (uint256) {
        return _registered[i];
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    function register(uint256 seed, uint8 actorIdx, uint16 bpsSeed) external {
        registerAttempts++;
        address actor = _actors[actorIdx % _actors.length];

        // Canonical hash bounded to a 64-bit space to encourage collisions (→ exercises the
        // AlreadyRegistered path) while leaving plenty of room for misses.
        bytes32 canonicalHash = bytes32(uint256(keccak256(abi.encode("g", seed))) & type(uint64).max);
        if (canonicalHash == bytes32(0)) return;

        uint16 bps = uint16(bound(bpsSeed, 0, SeqoraTypes.MAX_ROYALTY_BPS));
        address recipient = bps == 0 ? address(0) : address(0xEEEE);
        SeqoraTypes.RoyaltyRule memory royalty =
            SeqoraTypes.RoyaltyRule({ recipient: recipient, bps: bps, parentSplitBps: 0 });

        vm.prank(actor);
        try registry.register(
            actor, canonicalHash, bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0)
        ) returns (
            uint256 tokenId
        ) {
            _registered.push(tokenId);
            registerSuccesses++;
        } catch {
            // Expected paths: AlreadyRegistered. Ignore.
        }
    }

    function forkRegister(
        uint256 seed,
        uint8 actorIdx,
        uint16 bpsSeed,
        uint16 parentSplitSeed,
        uint256 parentIdx,
        uint8 additionalCount
    ) external {
        forkAttempts++;
        if (_registered.length == 0) return;

        address actor = _actors[actorIdx % _actors.length];
        // Pre-bound parentIdx to the registered pool so later additions can't overflow.
        uint256 parentCursor = parentIdx % _registered.length;
        uint256 parentTokenId = _registered[parentCursor];

        bytes32 canonicalHash =
            bytes32(uint256(keccak256(abi.encode("f", seed, _registered.length))) & type(uint64).max);
        if (canonicalHash == bytes32(0)) return;
        if (uint256(canonicalHash) == parentTokenId) return; // avoid guaranteed SelfParent

        uint16 bps = uint16(bound(bpsSeed, 0, SeqoraTypes.MAX_ROYALTY_BPS));
        uint16 ps = uint16(bound(parentSplitSeed, 0, SeqoraTypes.BPS));
        address recipient = bps == 0 ? address(0) : address(0xEEEE);
        SeqoraTypes.RoyaltyRule memory royalty =
            SeqoraTypes.RoyaltyRule({ recipient: recipient, bps: bps, parentSplitBps: ps });

        // Bound additional parents to [0, MAX_PARENTS - 1] to exercise both sides of the cap:
        // total = 1 + n, so max allowed is MAX_PARENTS; we clamp to max-1 here so the handler
        // never exercises the `TooManyParents` path (separately unit-tested).
        uint256 n = uint256(additionalCount) % (SeqoraTypes.MAX_PARENTS);
        // Cap further by the number of registered tokens we can pull from.
        if (n > _registered.length) n = _registered.length;
        bytes32[] memory additional = new bytes32[](n);
        uint256 filled;
        for (uint256 i = 0; i < n; i++) {
            uint256 pid = _registered[(parentCursor + i + 1) % _registered.length];
            if (pid == parentTokenId) continue;
            if (uint256(canonicalHash) == pid) continue;
            // Avoid duplicates within additional
            bool dup = false;
            for (uint256 j = 0; j < filled; j++) {
                if (additional[j] == bytes32(pid)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            additional[filled] = bytes32(pid);
            filled++;
        }
        // Shrink to actually-filled length.
        bytes32[] memory trimmed = new bytes32[](filled);
        for (uint256 i = 0; i < filled; i++) {
            trimmed[i] = additional[i];
        }

        SeqoraTypes.ForkParams memory params = SeqoraTypes.ForkParams({
            registrant: actor,
            primaryParentTokenId: parentTokenId,
            additionalParentTokenIds: trimmed,
            canonicalHash: canonicalHash,
            ga4ghSeqhash: bytes32(0),
            arweaveTx: "a",
            ceramicStreamId: "c",
            royaltyRule: royalty,
            screeningAttestationUID: bytes32(uint256(1)),
            metadataURI: ""
        });

        vm.prank(actor);
        try registry.forkRegister(params) returns (uint256 tokenId) {
            _registered.push(tokenId);
            forkSuccesses++;
        } catch {
            // AlreadyRegistered or edge case — ignore.
        }
    }
}
