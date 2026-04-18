// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------------------
// ScreeningAttestations — Seqora v1
//
// Plan (§4, §6 #1): governance-gated wrapper around Ethereum Attestation Service (EAS).
// Enforces that every DesignRegistry listing carries a screening attestation issued by an
// approved attester against the Seqora screening schema.
//
// Responsibilities
// ----------------
//   - `isValid(uid, canonicalHash, registrant)` — single read the DesignRegistry uses as its
//     listing gate. Checks: schema match, EAS revocation, local revocation, expiry, attester
//     approval, canonicalHash field match, registrant field match, and pause state.
//   - Attester registry — `registerAttester` / `revokeAttester` / `isApproved` / `getScreenerKind`,
//     Ownable2Step-gated with the Seqora multisig as owner. v1 launch set is ~1–3 Seqora-operated
//     relayer signers per research-scout 16:00 report (SecureDNA + IBBIS Commec do not yet emit
//     EAS-native attestations, so Seqora wraps their JSON outputs under its own signer).
//   - Local revocation — `localRevoke(uid)` immediately blacklists a specific attestation UID
//     even if the EAS-level revocation lags. Defence-in-depth for known-bad attestations.
//   - Pausable — emergency hard-stop; while paused `isValid` returns false (no revert) so the
//     registry surfaces a clean `AttestationInvalid` at its boundary.
//
// Immutability posture
// --------------------
//   No upgrade hooks. v2 may deploy a fresh contract + coordinator if the schema evolves.
//   The constructor locks in (EAS address, schemaUID); both have a setter restricted to the
//   owner so the multisig can migrate if EAS itself is redeployed (extremely unlikely on Base).
//
// Threat model
// ----------------------------------
//   1. Schema-decode tampering — `abi.decode(attestation.data, (bytes32, address, uint8, uint64,
//      bytes32))` MUST match the off-chain schema definition exactly. Any drift here silently
//      accepts malformed attestations.
//   2. EAS contract trust — we trust `eas.getAttestation` not to lie. On Base mainnet this is
//      the canonical Coinbase-deployed instance.
//   3. Attester compromise — a compromised approved attester can sign an attestation for any
//      (canonicalHash, registrant). `localRevoke` + `revokeAttester` provide mitigation paths.
//   4. Local revocation race — an attestation marked valid in block N can become invalid in
//      block N+1 via `localRevoke`. Consumers (DesignRegistry) tolerate this: they read fresh.
//   5. Pausing while in-flight — if the contract is paused mid-tx, `isValid` returns false,
//      the DesignRegistry reverts `AttestationInvalid`. No state is partially written.
// -----------------------------------------------------------------------------

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { IEAS } from "eas-contracts/IEAS.sol";
import { Attestation } from "eas-contracts/Common.sol";

import { IScreeningAttestations } from "./interfaces/IScreeningAttestations.sol";
import { SeqoraTypes } from "./libraries/SeqoraTypes.sol";
import { SeqoraErrors } from "./libraries/SeqoraErrors.sol";

/// @title ScreeningAttestations
/// @notice Governance-gated wrapper over EAS enforcing pre-listing biosafety screening.
/// @dev Owner (Seqora Safety Council multisig) manages the attester set and can pause the
///      `isValid` check in emergencies. Not upgradeable; redeploy for v2.
contract ScreeningAttestations is IScreeningAttestations, Ownable2Step, Pausable {
    // -------------------------------------------------------------------------
    // Errors (custom, per plan style rule — no revert strings)
    // -------------------------------------------------------------------------

    /// @notice Thrown when the on-chain attestation's schema does not match the Seqora schema.
    error InvalidSchema();

    /// @notice Thrown when the attestation has a set, elapsed `expirationTime`.
    error Expired();

    /// @notice Thrown when the EAS attestation has a non-zero `revocationTime`.
    error Revoked();

    /// @notice Thrown when the attestation UID has been locally blacklisted.
    error LocallyRevoked();

    /// @notice Thrown when the attester address is not in the approved set.
    /// @param attester The rejected attester.
    error UnknownAttester(address attester);

    /// @notice Thrown when the attestation's embedded `registrant` does not match the call arg.
    error RegistrantMismatch();

    /// @notice Thrown when the decoded payload is shorter than the expected schema length.
    error MalformedAttestationData();

    /// @notice Thrown when `renounceOwnership` is invoked. Governance bricking disabled.
    error RenounceDisabled();

    // -------------------------------------------------------------------------
    // Impl-only events (interface declares the two public-surface events)
    // -------------------------------------------------------------------------

    /// @notice Emitted when a UID is locally blacklisted.
    /// @param uid The attestation UID.
    /// @param by Address that executed the local revocation (always owner).
    event LocalRevocation(bytes32 indexed uid, address indexed by);

    /// @notice Emitted when the EAS contract address is changed by governance.
    /// @param prev Previous EAS address.
    /// @param next New EAS address.
    event EASContractSet(address indexed prev, address indexed next);

    /// @notice Emitted when the schema UID is changed by governance.
    /// @param prev Previous schema UID.
    /// @param next New schema UID.
    event SchemaUIDSet(bytes32 prev, bytes32 next);

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Canonical EAS instance (Base mainnet: 0x4200000000000000000000000000000000000021).
    IEAS public eas;

    /// @notice Seqora screening schema UID (registered once via deployment script).
    bytes32 public schemaUID;

    /// @dev attester -> ScreenerKind. `Unknown` means not registered / revoked.
    mapping(address => SeqoraTypes.ScreenerKind) private _attesterKind;

    /// @notice Locally-blacklisted attestation UIDs. Orthogonal to EAS-level revocation.
    mapping(bytes32 => bool) public locallyRevoked;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploy the screening attestations wrapper.
    /// @param eas_ EAS contract. Base mainnet canonical: `0x4200000000000000000000000000000000000021`.
    /// @param schemaUID_ Registered Seqora screening schema UID.
    ///                   Off-chain schema string (per plan §6 #1, registrant-binding):
    ///                   `bytes32 canonicalHash, address registrant, uint8 screenerKind,
    ///                    uint64 screenedAt, bytes32 reportHash`.
    /// @param owner_ Initial owner (Seqora Safety Council multisig). Ownable2Step requires
    ///               a separate `transferOwnership` + `acceptOwnership` to rotate.
    constructor(IEAS eas_, bytes32 schemaUID_, address owner_) Ownable(owner_) {
        if (address(eas_) == address(0)) revert SeqoraErrors.ZeroAddress();
        if (schemaUID_ == bytes32(0)) revert SeqoraErrors.ZeroValue();

        eas = eas_;
        schemaUID = schemaUID_;

        emit EASContractSet(address(0), address(eas_));
        emit SchemaUIDSet(bytes32(0), schemaUID_);
    }

    // -------------------------------------------------------------------------
    // Validity
    // -------------------------------------------------------------------------

    /// @inheritdoc IScreeningAttestations
    /// @dev Returns `false` (never reverts) for any failed validation so the registry boundary
    ///      surfaces a single structured error (`AttestationInvalid`). The only revert paths are
    ///      (a) external EAS malfunction (propagated) and (b) schema-decode of a shorter-than-
    ///      expected payload (`MalformedAttestationData`) — a sign of a deeply malformed
    ///      attestation the attester produced in violation of the schema.
    function isValid(bytes32 attestationUID, bytes32 canonicalHash, address registrant)
        external
        view
        returns (bool valid)
    {
        // Emergency hard-stop.
        if (paused()) return false;

        // Local blacklist short-circuit.
        if (locallyRevoked[attestationUID]) return false;

        // Fetch the attestation from EAS.
        Attestation memory att = eas.getAttestation(attestationUID);

        // EAS returns a zero-initialized struct for unknown UIDs; `schema == 0` is a reliable
        // proxy for "not found" (schemas are registered non-zero).
        if (att.schema == bytes32(0)) return false;

        // Schema match.
        if (att.schema != schemaUID) return false;

        // EAS-level revocation.
        if (att.revocationTime != 0) return false;

        // Expiry (0 == non-expiring per EAS convention).
        if (att.expirationTime != 0 && att.expirationTime < block.timestamp) return false;

        // Attester approval.
        if (_attesterKind[att.attester] == SeqoraTypes.ScreenerKind.Unknown) return false;

        // Decode the data payload. Expected schema (45 bytes tightly packed under abi.encode):
        //   (bytes32 canonicalHash, address registrant, uint8 screenerKind,
        //    uint64 screenedAt, bytes32 reportHash)
        // Under standard abi.encode each element is padded to 32 bytes → 5 * 32 = 160 bytes.
        if (att.data.length < 160) return false;

        (bytes32 attCanonicalHash, address attRegistrant,,,) =
            abi.decode(att.data, (bytes32, address, uint8, uint64, bytes32));

        // Registrant-binding: both bindings are mandatory.
        if (attCanonicalHash != canonicalHash) return false;
        if (attRegistrant != registrant) return false;

        valid = true;
    }

    // -------------------------------------------------------------------------
    // Attester governance
    // -------------------------------------------------------------------------

    /// @inheritdoc IScreeningAttestations
    /// @dev Owner-only. v1 launch set is ~1–3 Seqora-operated relayer addresses; v2 widens
    ///      this to third-party screeners (IBBIS / SecureDNA / IGSC) once they ship signed
    ///      attestation outputs.
    function registerAttester(address attester, SeqoraTypes.ScreenerKind kind) external onlyOwner {
        if (attester == address(0)) revert SeqoraErrors.ZeroAddress();
        if (kind == SeqoraTypes.ScreenerKind.Unknown) revert UnknownScreenerKind();

        _attesterKind[attester] = kind;
        emit AttesterRegistered(attester, kind);
    }

    /// @inheritdoc IScreeningAttestations
    /// @dev Owner-only. Plan §6 #1 calls for dual-gating (governance + Safety Council); in v1
    ///      both roles are the same multisig. The interface's NatSpec mentions Safety Council
    ///      gating as a future refinement.
    function revokeAttester(address attester, string calldata reason) external onlyOwner {
        if (_attesterKind[attester] == SeqoraTypes.ScreenerKind.Unknown) revert UnknownAttester(attester);
        _attesterKind[attester] = SeqoraTypes.ScreenerKind.Unknown;
        emit AttesterRevoked(attester, reason);
    }

    /// @inheritdoc IScreeningAttestations
    function getScreenerKind(address attester) external view returns (SeqoraTypes.ScreenerKind kind) {
        kind = _attesterKind[attester];
    }

    /// @inheritdoc IScreeningAttestations
    /// @dev Canonical approval-query; {isApprovedAttester} is a naming-only alias.
    function isApproved(address attester) external view returns (bool approved) {
        approved = _attesterKind[attester] != SeqoraTypes.ScreenerKind.Unknown;
    }

    /// @notice Convenience alias matching the brief's `isApprovedAttester` naming.
    /// @dev Prefer {isApproved}.
    /// @param attester Address to check.
    /// @return approved True iff the attester is in the approved set.
    function isApprovedAttester(address attester) external view returns (bool approved) {
        approved = _attesterKind[attester] != SeqoraTypes.ScreenerKind.Unknown;
    }

    // -------------------------------------------------------------------------
    // Local revocation (defence in depth)
    // -------------------------------------------------------------------------

    /// @notice Locally blacklist a specific attestation UID.
    /// @dev Orthogonal to EAS-level revocation. Use when EAS propagation lags or the attester
    ///      refuses to revoke on EAS. Once set, cannot be reversed — deliberate: we never want
    ///      a previously-blacklisted attestation to silently re-activate.
    /// @param uid Attestation UID to blacklist.
    function localRevoke(bytes32 uid) external onlyOwner {
        if (uid == bytes32(0)) revert SeqoraErrors.ZeroValue();
        if (locallyRevoked[uid]) return; // idempotent
        locallyRevoked[uid] = true;
        emit LocalRevocation(uid, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Pausable
    // -------------------------------------------------------------------------

    /// @notice Halt all new listings by forcing `isValid` to return false.
    /// @dev Owner-only hard-stop for biosafety emergencies.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume the screening gate.
    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // EAS / schema migration (owner-only, immutable semantics otherwise)
    // -------------------------------------------------------------------------

    /// @notice Update the EAS contract address. Owner-only.
    /// @dev Intended for the edge case where EAS itself redeploys (e.g. OP-stack redeployment).
    ///      Not an upgrade hook for this contract. Emits `EASContractSet`.
    /// @param eas_ New EAS instance.
    function setEAS(IEAS eas_) external onlyOwner {
        if (address(eas_) == address(0)) revert SeqoraErrors.ZeroAddress();
        address prev = address(eas);
        eas = eas_;
        emit EASContractSet(prev, address(eas_));
    }

    /// @notice Override disables `renounceOwnership` to prevent permanent governance bricking.
    /// @dev A renounced owner cannot register attesters, revoke, pause, rotate EAS, or set schema — every
    ///      safety lever collapses. Always reverts with `RenounceDisabled`.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Update the Seqora screening schema UID. Owner-only.
    /// @dev Use when governance rotates the off-chain schema definition (rare; would invalidate
    ///      all prior attestations, so typically paired with deploying a new DesignRegistry).
    /// @param schemaUID_ New schema UID.
    function setSchemaUID(bytes32 schemaUID_) external onlyOwner {
        if (schemaUID_ == bytes32(0)) revert SeqoraErrors.ZeroValue();
        bytes32 prev = schemaUID;
        schemaUID = schemaUID_;
        emit SchemaUIDSet(prev, schemaUID_);
    }
}
