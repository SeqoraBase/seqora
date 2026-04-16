// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";

import { ProvenanceRegistry } from "../../src/ProvenanceRegistry.sol";
import { SeqoraTypes } from "../../src/libraries/SeqoraTypes.sol";

/// @title ProvenanceSigning
/// @notice Shared EIP-712 signing helpers for ProvenanceRegistry tests.
/// @dev Duplicates the struct-hash encoding used inside `ProvenanceRegistry.recordModelCard` /
///      `recordWetLabAttestation` so tests can construct valid signatures for any tokenId,
///      any contributor/oracle key, and any struct payload.
library ProvenanceSigning {
    /// @dev forge-std Vm cheatcode handle (vm.sign lives here).
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Compute the EIP-712 digest of a `ModelCard` for `registry`'s domain separator.
    function modelCardDigest(ProvenanceRegistry registry, SeqoraTypes.ModelCard memory card)
        internal
        view
        returns (bytes32 digest)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.MODEL_CARD_TYPEHASH(),
                card.weightsHash,
                card.promptHash,
                card.seed,
                keccak256(bytes(card.toolName)),
                keccak256(bytes(card.toolVersion)),
                card.contributor,
                card.createdAt
            )
        );
        digest = keccak256(abi.encodePacked("\x19\x01", registry.domainSeparator(), structHash));
    }

    /// @notice Compute the EIP-712 digest of a `WetLabAttestation` for `registry`'s domain separator.
    function wetLabDigest(ProvenanceRegistry registry, SeqoraTypes.WetLabAttestation memory att)
        internal
        view
        returns (bytes32 digest)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.WET_LAB_ATTESTATION_TYPEHASH(),
                att.tokenId,
                att.oracle,
                keccak256(bytes(att.vendor)),
                keccak256(bytes(att.orderRef)),
                att.synthesizedAt,
                att.payloadHash
            )
        );
        digest = keccak256(abi.encodePacked("\x19\x01", registry.domainSeparator(), structHash));
    }

    /// @notice Sign a `ModelCard` digest with `pk` under `registry`'s EIP-712 domain.
    /// @param pk Private key to sign with.
    /// @param card ModelCard payload.
    /// @param registry Target ProvenanceRegistry instance (domain separator source).
    /// @return sig 65-byte `(r, s, v)` signature.
    function signModelCard(uint256 pk, SeqoraTypes.ModelCard memory card, ProvenanceRegistry registry)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 digest = modelCardDigest(registry, card);
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice Sign a `WetLabAttestation` digest with `pk` under `registry`'s EIP-712 domain.
    /// @param pk Private key to sign with.
    /// @param att WetLabAttestation payload.
    /// @param registry Target ProvenanceRegistry instance (domain separator source).
    /// @return sig 65-byte `(r, s, v)` signature.
    function signWetLabAttestation(uint256 pk, SeqoraTypes.WetLabAttestation memory att, ProvenanceRegistry registry)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 digest = wetLabDigest(registry, att);
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice Sign an arbitrary pre-computed digest. Convenience for raw-hash tests (e.g. wrong
    ///         typehash rejection).
    function signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }
}
