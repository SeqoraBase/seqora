// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SeqoraTypes } from "../libraries/SeqoraTypes.sol";

/// @title IProvenanceRegistry
/// @notice Append-only provenance log per design: AI ModelCards + wet-lab synthesis attestations.
/// @dev Per plan §4 + §6 #3: ModelCards are caller-signed (EIP-712) by the human contributor.
///      Wet-lab attestations are signed by governance-approved oracles (v1 = Twist/IDT/Ansa
///      receipt bridge; v2 will accept TEE attestations from a Nanopore + DeepSME pipeline).
interface IProvenanceRegistry {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a ModelCard is recorded against a design.
    /// @param tokenId Design id.
    /// @param recordHash EIP-712 digest of the ModelCard struct.
    /// @param contributor Human author who signed.
    event ModelCardRecorded(uint256 indexed tokenId, bytes32 indexed recordHash, address indexed contributor);

    /// @notice Emitted when a wet-lab attestation is recorded.
    /// @param tokenId Design id.
    /// @param recordHash EIP-712 digest of the WetLabAttestation struct.
    /// @param oracle Oracle wallet that signed.
    event WetLabRecorded(uint256 indexed tokenId, bytes32 indexed recordHash, address indexed oracle);

    /// @notice Emitted when the approved-oracle set changes.
    /// @param oracle Wallet whose status changed.
    /// @param approved New approval status.
    event OracleApprovalChanged(address indexed oracle, bool approved);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when an EIP-712 signature does not recover to the expected signer.
    error InvalidSignature();

    /// @notice Thrown when a wet-lab attestation is signed by an oracle not in the approved set.
    /// @param oracle Wallet that signed.
    error OracleNotApproved(address oracle);

    /// @notice Thrown when an identical record (by recordHash) has already been logged for a tokenId.
    /// @param tokenId Design id.
    /// @param recordHash The duplicated record hash.
    error DuplicateProvenance(uint256 tokenId, bytes32 recordHash);

    // -------------------------------------------------------------------------
    // Submissions
    // -------------------------------------------------------------------------

    /// @notice Append a ModelCard to a design's provenance log.
    /// @dev `signature` must be the EIP-712 signature of `card` by `card.contributor`.
    ///      Reverts on InvalidSignature or DuplicateProvenance.
    /// @param tokenId Design id.
    /// @param card ModelCard payload.
    /// @param signature EIP-712 signature over the canonical encoding.
    function recordModelCard(uint256 tokenId, SeqoraTypes.ModelCard calldata card, bytes calldata signature) external;

    /// @notice Append a wet-lab synthesis attestation to a design's provenance log.
    /// @dev `signature` must be the EIP-712 signature of `attestation` by `attestation.oracle`,
    ///      and `attestation.oracle` must be in the governance-approved oracle set.
    /// @param tokenId Design id.
    /// @param attestation WetLabAttestation payload.
    /// @param signature EIP-712 signature over the canonical encoding.
    function recordWetLabAttestation(
        uint256 tokenId,
        SeqoraTypes.WetLabAttestation calldata attestation,
        bytes calldata signature
    ) external;

    // -------------------------------------------------------------------------
    // Oracle governance
    // -------------------------------------------------------------------------

    /// @notice Add or remove a wet-lab oracle from the approved set. Governance-only.
    /// @param oracle Wallet whose status to set.
    /// @param approved New approval status.
    function setOracleApproved(address oracle, bool approved) external;

    /// @notice Whether `oracle` is currently approved to sign wet-lab attestations.
    /// @param oracle Address to check.
    /// @return approved True iff in the approved set.
    function isOracleApproved(address oracle) external view returns (bool approved);

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Read all provenance records for a design.
    /// @param tokenId Design id.
    /// @return records Provenance entries in append order.
    function getProvenance(uint256 tokenId) external view returns (SeqoraTypes.ProvenanceRecord[] memory records);

    /// @notice Number of provenance records for a design.
    /// @param tokenId Design id.
    /// @return count Number of recorded entries.
    function provenanceCount(uint256 tokenId) external view returns (uint256 count);
}
