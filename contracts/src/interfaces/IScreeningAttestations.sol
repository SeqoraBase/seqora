// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SeqoraTypes } from "../libraries/SeqoraTypes.sol";

/// @title IScreeningAttestations
/// @notice Wraps EAS attestations from governance-approved biosafety screeners.
/// @dev Per plan §6 #1: pre-listing screening is enforced at the contract level. This interface
///      defines the validity check used by DesignRegistry plus governance management of the
///      attester set. Attester removal is dual-gated (governance + Safety Council).
interface IScreeningAttestations {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a new attester is registered.
    /// @param attester Wallet authorized to issue attestations.
    /// @param kind Origin classification (IGSC / IBBIS / SecureDNA / Other).
    event AttesterRegistered(address indexed attester, SeqoraTypes.ScreenerKind kind);

    /// @notice Emitted when an attester is revoked.
    /// @param attester Wallet revoked.
    /// @param reason Free-form short reason.
    event AttesterRevoked(address indexed attester, string reason);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when an attester is not in the governance-approved set.
    /// @param attester Address that was checked.
    error AttesterNotApproved(address attester);

    /// @notice Thrown when the EAS attestation has been revoked.
    /// @param attestationUID The revoked UID.
    error AttestationRevoked(bytes32 attestationUID);

    /// @notice Thrown when an attestation does not reference the expected canonical hash.
    /// @param attestationUID The mismatched UID.
    /// @param expected Canonical hash the design supplied.
    /// @param actual Canonical hash the attestation references.
    error AttestationMismatch(bytes32 attestationUID, bytes32 expected, bytes32 actual);

    /// @notice Thrown when the supplied screener kind is `Unknown`.
    error UnknownScreenerKind();

    // -------------------------------------------------------------------------
    // Validity
    // -------------------------------------------------------------------------

    /// @notice Whether `attestationUID` is a valid screening attestation for
    ///         `(canonicalHash, registrant)`.
    /// @dev Wraps EAS `getAttestation`. Verifies: schema matches the Seqora screening schema,
    ///      attestation is not revoked (on EAS or locally), not expired, attester is in the
    ///      approved set, the attested `canonicalHash` field equals `canonicalHash`, and the
    ///      attested `registrant` field equals `registrant`. The `registrant` binding is the
    ///      Registrant-binding fix: prevents a mempool observer from replaying Alice's genesis-registration
    ///      calldata under their own address.
    ///
    ///      Off-chain UX SHOULD set `registrant = msg.sender` for direct EOA flows; relayers /
    ///      Safes / smart accounts MAY set it to the end-user address provided the EAS
    ///      attestation was issued for that address.
    /// @param attestationUID EAS attestation UID.
    /// @param canonicalHash Expected canonical SBOL3 hash.
    /// @param registrant Address that will own the minted tokenId; MUST match the
    ///                   `registrant` field committed by the attester in the EAS schema payload.
    /// @return valid True iff all checks pass. Implementations MAY return false (rather than
    ///               revert) for invalid attestations so callers can emit structured errors;
    ///               they MUST NOT leak EAS schema details on failure.
    function isValid(bytes32 attestationUID, bytes32 canonicalHash, address registrant)
        external
        view
        returns (bool valid);

    // -------------------------------------------------------------------------
    // Attester governance
    // -------------------------------------------------------------------------

    /// @notice Register a new attester. Governance-only.
    /// @param attester Wallet to authorize.
    /// @param kind Origin classification (must not be Unknown).
    function registerAttester(address attester, SeqoraTypes.ScreenerKind kind) external;

    /// @notice Revoke an existing attester. Governance + Safety Council gated.
    /// @param attester Wallet to revoke.
    /// @param reason Free-form short reason recorded in the event.
    function revokeAttester(address attester, string calldata reason) external;

    /// @notice Read the screener kind for an attester.
    /// @param attester Address to inspect.
    /// @return kind Stored ScreenerKind (Unknown if not registered or revoked).
    function getScreenerKind(address attester) external view returns (SeqoraTypes.ScreenerKind kind);

    /// @notice Whether `attester` is currently in the approved set.
    /// @param attester Address to check.
    /// @return approved True iff registered and not revoked.
    function isApproved(address attester) external view returns (bool approved);
}
