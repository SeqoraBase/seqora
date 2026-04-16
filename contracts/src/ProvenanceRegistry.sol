// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------------------
// ProvenanceRegistry — Seqora v1
//
// Plan (§3, §4, §6 #3): append-only provenance log per registered design. Two record kinds
// per `SeqoraTypes.ProvenanceKind`:
//
//   1. ModelCard      — AI/ML lineage (weights hash, prompt hash, seed, tool name/version,
//                       human contributor). Signed EIP-712 by the contributor — enables
//                       relayer flows while binding authorship to a key the human controls.
//   2. WetLabAttestation — governance-approved oracle says "this design was synthesized /
//                       validated, here is the off-chain receipt hash". Signed EIP-712 by
//                       `attestation.oracle` (must be in the approved oracle set).
//
// Only the 32-byte EIP-712 digest (`recordHash`) is stored on-chain; full struct payloads
// travel via calldata (cheap to index off-chain from the transaction input). This keeps the
// on-chain footprint O(records × 1 slot + overhead), not O(records × bytelength-of-payload).
//
// Immutability posture
// --------------------
//   Not upgradeable. Per CLAUDE.md only LicenseRegistry + BiosafetyCourt are UUPS. Oracle
//   set is mutable via the owner (Seqora multisig); local record revocation likewise.
//
// Threat model notes for sec-auditor
// ----------------------------------
//   1. EIP-712 replay across tokenIds —
//      (a) ModelCard: a payload CAN be recorded against different tokenIds by design (the
//          same ModelCard may author multiple derivative sequences). Per-tokenId
//          `_seenRecord[tokenId][recordHash]` dedup prevents replay of the same payload
//          against the same tokenId; off-chain consumers index by `(tokenId, recordHash)`.
//      (b) WetLabAttestation: cross-tokenId replay is CLOSED. `WetLabAttestation.tokenId`
//          is the FIRST signed field of the EIP-712 payload and MUST equal the on-chain
//          `tokenId` argument — a mismatch reverts `TokenIdMismatch(expected, actual)`.
//          A signature captured for design A cannot be submitted against design B
//          because the oracle signed exactly one tokenId (sec-audit H-01 2026-04-16).
//   2. EIP-712 replay across chains — domain separator bakes in `block.chainid` + this
//      contract's address via OZ `EIP712`. A signature for Base mainnet will not verify on
//      Base Sepolia or any fork.
//   3. Malicious oracle — a compromised approved oracle can fabricate attestations for any
//      tokenId. Mitigations: (a) `setOracleApproved(oracle, false)` revokes prospectively;
//      (b) `localRevoke(recordHash)` retroactively invalidates specific records.
//   4. DesignRegistry trust — we call `registry.isRegistered(tokenId)` as the only cross-
//      contract dependency. DesignRegistry is immutable and in-repo; trust boundary is tight.
//   5. Records-array DoS — `getProvenance(tokenId)` (unpaginated view, required by the
//      interface) can return an arbitrarily long array. Off-chain callers SHOULD prefer
//      `getRecordsByTokenId(tokenId, offset, limit)` which caps `limit` at `MAX_PAGE_LIMIT`.
//   6. Signature malleability — OZ `ECDSA.recover` rejects non-canonical `s` values.
//   7. Paused state — halts new record submissions but does NOT halt reads or governance
//      (oracle set management, local revocation). Reads remain available for indexers.
// -----------------------------------------------------------------------------

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { IProvenanceRegistry } from "./interfaces/IProvenanceRegistry.sol";
import { IDesignRegistry } from "./interfaces/IDesignRegistry.sol";
import { SeqoraTypes } from "./libraries/SeqoraTypes.sol";
import { SeqoraErrors } from "./libraries/SeqoraErrors.sol";

/// @title ProvenanceRegistry
/// @notice Append-only ModelCard + wet-lab attestation log per registered design.
/// @dev Immutable (non-upgradeable). EIP-712 signatures bind records to their authors.
///      Owner (Seqora multisig) curates the wet-lab oracle set and can locally revoke
///      individual records. Per-tokenId duplicate detection prevents EIP-712 replay.
contract ProvenanceRegistry is IProvenanceRegistry, Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
    // -------------------------------------------------------------------------
    // Errors (contract-local — interface-declared errors reused via IProvenanceRegistry)
    // -------------------------------------------------------------------------

    /// @notice Thrown when `renounceOwnership` is invoked. Disabled to prevent governance bricking.
    error RenounceDisabled();

    /// @notice Thrown when a `localRevoke` targets a `(tokenId, recordHash)` that was never recorded.
    /// @param tokenId Design id whose records were searched.
    /// @param recordHash The record hash not found under `tokenId`.
    error UnknownRecord(uint256 tokenId, bytes32 recordHash);

    // `TokenIdMismatch(uint256 expected, uint256 actual)` — declared on `IProvenanceRegistry`;
    // inherited here. Used by `recordWetLabAttestation` to close cross-tokenId replay on
    // WetLab oracle signatures (sec-audit H-01 2026-04-16).

    // -------------------------------------------------------------------------
    // Events (contract-local — submission + oracle events are declared on IProvenanceRegistry)
    // -------------------------------------------------------------------------

    /// @notice Emitted when a specific record is locally revoked by governance.
    /// @param tokenId Design id the record belongs to.
    /// @param recordHash Canonical record hash revoked.
    /// @param by Address that executed the revocation (always owner).
    event LocalRecordRevocation(uint256 indexed tokenId, bytes32 indexed recordHash, address indexed by);

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice EIP-712 type hash for `SeqoraTypes.ModelCard` — field order MUST match the struct.
    bytes32 public constant MODEL_CARD_TYPEHASH = keccak256(
        "ModelCard(bytes32 weightsHash,bytes32 promptHash,bytes32 seed,string toolName,string toolVersion,address contributor,uint64 createdAt)"
    );

    /// @notice EIP-712 type hash for `SeqoraTypes.WetLabAttestation` — field order MUST match the struct.
    /// @dev Note `tokenId` is the first signed field. The on-chain call then asserts that the
    ///      signed tokenId matches the `tokenId` argument (sec-audit H-01 2026-04-16).
    bytes32 public constant WET_LAB_ATTESTATION_TYPEHASH = keccak256(
        "WetLabAttestation(uint256 tokenId,address oracle,string vendor,string orderRef,uint64 synthesizedAt,bytes32 payloadHash)"
    );

    /// @notice Pagination cap on `getRecordsByTokenId`. Callers requesting a larger `limit` are
    ///         silently truncated to this value.
    uint256 public constant MAX_PAGE_LIMIT = 100;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice DesignRegistry used to check `isRegistered(tokenId)` before accepting a record.
    IDesignRegistry public immutable designRegistry;

    /// @dev tokenId → append-ordered ProvenanceRecord list.
    mapping(uint256 => SeqoraTypes.ProvenanceRecord[]) private _records;

    /// @dev tokenId → recordHash → seen flag. Prevents EIP-712 replay per-tokenId and backs
    ///      `DuplicateProvenance`.
    mapping(uint256 => mapping(bytes32 => bool)) private _seenRecord;

    /// @dev Oracle approval set for `recordWetLabAttestation`.
    mapping(address => bool) private _approvedOracle;

    /// @notice Records marked locally revoked by governance. Keyed by `recordHash` (global scope).
    /// @dev A recordHash revoked here is invalid under EVERY tokenId it was recorded against; this
    ///      matches the semantics of "the underlying payload turned out to be wrong".
    mapping(bytes32 => bool) public locallyRevoked;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploy the provenance registry.
    /// @param designRegistry_ Canonical DesignRegistry instance (immutable).
    /// @param owner_ Initial owner (Seqora multisig). Ownable2Step requires a separate
    ///               `transferOwnership` + `acceptOwnership` to rotate.
    constructor(IDesignRegistry designRegistry_, address owner_)
        Ownable(owner_)
        EIP712("Seqora ProvenanceRegistry", "1")
    {
        if (address(designRegistry_) == address(0)) revert SeqoraErrors.ZeroAddress();
        designRegistry = designRegistry_;
    }

    // -------------------------------------------------------------------------
    // Submissions
    // -------------------------------------------------------------------------

    /// @inheritdoc IProvenanceRegistry
    /// @dev Verifies EIP-712 signature by `card.contributor`. `msg.sender` is not restricted
    ///      (relayer-friendly); authorship is anchored in the signature. Reverts on invalid
    ///      signature, duplicate record, unknown tokenId, pause, or zero contributor.
    function recordModelCard(uint256 tokenId, SeqoraTypes.ModelCard calldata card, bytes calldata signature)
        external
        whenNotPaused
        nonReentrant
    {
        if (card.contributor == address(0)) revert SeqoraErrors.ZeroAddress();
        _requireRegistered(tokenId);

        bytes32 structHash = keccak256(
            abi.encode(
                MODEL_CARD_TYPEHASH,
                card.weightsHash,
                card.promptHash,
                card.seed,
                keccak256(bytes(card.toolName)),
                keccak256(bytes(card.toolVersion)),
                card.contributor,
                card.createdAt
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        address recovered = ECDSA.recover(digest, signature);
        if (recovered != card.contributor) revert InvalidSignature();

        _append(tokenId, SeqoraTypes.ProvenanceKind.ModelCard, digest, card.contributor);

        emit ModelCardRecorded(tokenId, digest, card.contributor);
    }

    /// @inheritdoc IProvenanceRegistry
    /// @dev Verifies EIP-712 signature by `attestation.oracle` and that the oracle is in the
    ///      approved set. `msg.sender` is not restricted (relayer-friendly). Reverts on invalid
    ///      signature, unapproved oracle, duplicate record, unknown tokenId, pause, zero
    ///      oracle, or `attestation.tokenId != tokenId` (cross-tokenId replay; sec-audit
    ///      H-01 2026-04-16).
    function recordWetLabAttestation(
        uint256 tokenId,
        SeqoraTypes.WetLabAttestation calldata attestation,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        if (attestation.oracle == address(0)) revert SeqoraErrors.ZeroAddress();
        // Bind the signed payload to THIS tokenId. The oracle signs exactly one tokenId; a
        // signature captured for design A cannot be replayed against design B.
        if (attestation.tokenId != tokenId) revert TokenIdMismatch(tokenId, attestation.tokenId);
        if (!_approvedOracle[attestation.oracle]) revert OracleNotApproved(attestation.oracle);
        _requireRegistered(tokenId);

        bytes32 structHash = keccak256(
            abi.encode(
                WET_LAB_ATTESTATION_TYPEHASH,
                attestation.tokenId,
                attestation.oracle,
                keccak256(bytes(attestation.vendor)),
                keccak256(bytes(attestation.orderRef)),
                attestation.synthesizedAt,
                attestation.payloadHash
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        address recovered = ECDSA.recover(digest, signature);
        if (recovered != attestation.oracle) revert InvalidSignature();

        _append(tokenId, SeqoraTypes.ProvenanceKind.WetLab, digest, attestation.oracle);

        emit WetLabRecorded(tokenId, digest, attestation.oracle);
    }

    // -------------------------------------------------------------------------
    // Oracle governance (Ownable2Step)
    // -------------------------------------------------------------------------

    /// @inheritdoc IProvenanceRegistry
    /// @dev Owner-only. Idempotent: setting the current value re-emits the event. Use
    ///      `registerOracle` / `revokeOracle` as self-documenting aliases.
    function setOracleApproved(address oracle, bool approved) external onlyOwner {
        if (oracle == address(0)) revert SeqoraErrors.ZeroAddress();
        _approvedOracle[oracle] = approved;
        emit OracleApprovalChanged(oracle, approved);
    }

    /// @notice Convenience wrapper for `setOracleApproved(oracle, true)`.
    /// @param oracle Oracle wallet to approve.
    function registerOracle(address oracle) external onlyOwner {
        if (oracle == address(0)) revert SeqoraErrors.ZeroAddress();
        _approvedOracle[oracle] = true;
        emit OracleApprovalChanged(oracle, true);
    }

    /// @notice Convenience wrapper for `setOracleApproved(oracle, false)`.
    /// @param oracle Oracle wallet to revoke.
    function revokeOracle(address oracle) external onlyOwner {
        if (oracle == address(0)) revert SeqoraErrors.ZeroAddress();
        _approvedOracle[oracle] = false;
        emit OracleApprovalChanged(oracle, false);
    }

    /// @inheritdoc IProvenanceRegistry
    function isOracleApproved(address oracle) external view returns (bool approved) {
        approved = _approvedOracle[oracle];
    }

    /// @notice Alias matching the brief's `isApprovedOracle` naming.
    /// @param oracle Address to check.
    /// @return approved True iff `oracle` is in the approved set.
    function isApprovedOracle(address oracle) external view returns (bool approved) {
        approved = _approvedOracle[oracle];
    }

    // -------------------------------------------------------------------------
    // Local revocation (defence in depth)
    // -------------------------------------------------------------------------

    /// @notice Locally revoke a specific record hash. Owner-only.
    /// @dev Used when a wet-lab attestation is later disproven or a ModelCard is shown to be
    ///      fraudulent. Irreversible: a revoked hash cannot be un-revoked (prevents silent
    ///      re-validation). The `tokenId` argument is used only to prove the record exists
    ///      under that tokenId — a single `recordHash` may validly appear under multiple
    ///      tokenIds, but the revocation scope is global (the underlying payload is bad).
    /// @param tokenId Design id under which the record was recorded (presence check only).
    /// @param recordHash Canonical EIP-712 digest of the record to revoke.
    function localRevoke(uint256 tokenId, bytes32 recordHash) external onlyOwner {
        if (recordHash == bytes32(0)) revert SeqoraErrors.ZeroValue();
        if (!_seenRecord[tokenId][recordHash]) revert UnknownRecord(tokenId, recordHash);
        if (locallyRevoked[recordHash]) return; // idempotent
        locallyRevoked[recordHash] = true;
        emit LocalRecordRevocation(tokenId, recordHash, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IProvenanceRegistry
    /// @dev Unpaginated: returns the full array. Prefer `getRecordsByTokenId(tokenId, offset,
    ///      limit)` for large logs to avoid RPC-timeout / OOG on downstream consumers.
    function getProvenance(uint256 tokenId) external view returns (SeqoraTypes.ProvenanceRecord[] memory records) {
        records = _records[tokenId];
    }

    /// @inheritdoc IProvenanceRegistry
    function provenanceCount(uint256 tokenId) external view returns (uint256 count) {
        count = _records[tokenId].length;
    }

    /// @notice O(1) record count for a tokenId. Alias for `provenanceCount`.
    /// @param tokenId Design id.
    /// @return count Length of the records array.
    function getRecordCount(uint256 tokenId) external view returns (uint256 count) {
        count = _records[tokenId].length;
    }

    /// @notice Paginated records reader. Caps `limit` at `MAX_PAGE_LIMIT`.
    /// @dev Returns the slice `_records[tokenId][offset .. min(offset+limit, total)]` plus the
    ///      total count so callers can drive subsequent page requests. `offset >= total`
    ///      returns an empty array and the total.
    /// @param tokenId Design id.
    /// @param offset Starting index (0-based).
    /// @param limit Desired page size; silently capped at `MAX_PAGE_LIMIT`.
    /// @return page Sliced records in append order.
    /// @return total Total records for this tokenId.
    function getRecordsByTokenId(uint256 tokenId, uint256 offset, uint256 limit)
        external
        view
        returns (SeqoraTypes.ProvenanceRecord[] memory page, uint256 total)
    {
        SeqoraTypes.ProvenanceRecord[] storage list = _records[tokenId];
        total = list.length;

        if (offset >= total) {
            page = new SeqoraTypes.ProvenanceRecord[](0);
            return (page, total);
        }

        uint256 effectiveLimit = limit > MAX_PAGE_LIMIT ? MAX_PAGE_LIMIT : limit;
        uint256 end = offset + effectiveLimit;
        if (end > total) end = total;
        uint256 pageSize = end - offset;

        page = new SeqoraTypes.ProvenanceRecord[](pageSize);
        for (uint256 i = 0; i < pageSize; ++i) {
            page[i] = list[offset + i];
        }
    }

    /// @notice Whether a record hash is still considered valid.
    /// @dev True iff the hash has been recorded against `tokenId` AND is not locally revoked.
    ///      Returns false for non-existent records (no separate error path — a stale indexer
    ///      can distinguish via `getRecordCount` if needed).
    /// @param tokenId Design id to check against.
    /// @param recordHash Canonical record hash.
    /// @return valid True iff recorded and not revoked.
    function isRecordValid(uint256 tokenId, bytes32 recordHash) external view returns (bool valid) {
        valid = _seenRecord[tokenId][recordHash] && !locallyRevoked[recordHash];
    }

    /// @notice Expose the EIP-712 domain separator for off-chain signers.
    /// @return separator Current domain separator (rebuilt on chainid changes).
    function domainSeparator() external view returns (bytes32 separator) {
        separator = _domainSeparatorV4();
    }

    // -------------------------------------------------------------------------
    // Pausable
    // -------------------------------------------------------------------------

    /// @notice Halt new record submissions. Reads + governance remain live.
    /// @dev Owner-only hard-stop for biosafety / IP emergencies.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume record submissions.
    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Governance-bricking guard
    // -------------------------------------------------------------------------

    /// @notice Disabled — renouncing ownership would permanently lock oracle set, local
    ///         revocation, and pause controls.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Reverts `UnknownToken(tokenId)` if the DesignRegistry does not have `tokenId`.
    function _requireRegistered(uint256 tokenId) internal view {
        if (!designRegistry.isRegistered(tokenId)) revert SeqoraErrors.UnknownToken(tokenId);
    }

    /// @dev Common append path for both ModelCard and WetLab submissions. Enforces per-tokenId
    ///      dedup before writing — any duplicate reverts `DuplicateProvenance(tokenId, recordHash)`.
    function _append(uint256 tokenId, SeqoraTypes.ProvenanceKind kind, bytes32 recordHash, address submitter) internal {
        if (_seenRecord[tokenId][recordHash]) revert DuplicateProvenance(tokenId, recordHash);
        _seenRecord[tokenId][recordHash] = true;

        _records[tokenId].push(
            SeqoraTypes.ProvenanceRecord({
                kind: kind, recordHash: recordHash, submitter: submitter, recordedAt: uint64(block.timestamp)
            })
        );
    }
}
