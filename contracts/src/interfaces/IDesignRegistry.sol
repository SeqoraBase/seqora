// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SeqoraTypes } from "../libraries/SeqoraTypes.sol";

/// @title IDesignRegistry
/// @notice ERC-1155 registry of canonical SBOL3 designs. tokenId == uint256(canonicalHash).
/// @dev Per plan §4: immutable contract. Once a tokenId is registered it can never be re-minted,
///      mutated, or upgraded. Forking creates a *new* tokenId that points back to its parents.
///      Listing requires a valid screening attestation (plan §6 #1) — enforced on `register`.
interface IDesignRegistry {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a new genesis design is registered.
    /// @param tokenId Canonical token id (== uint256(canonicalHash)).
    /// @param registrant The address recorded as the registrant; receives the ERC-1155 mint
    ///                   and the royalty stream. MAY differ from `msg.sender` on relayer flows.
    /// @param canonicalHash keccak256 of URDNA2015(SBOL3).
    /// @param ga4ghSeqhash GA4GH VRS seqhash, or 0x0 for multi-sequence designs.
    /// @param screeningAttestationUID EAS UID proving pre-listing screening, bound to `registrant`.
    event DesignRegistered(
        uint256 indexed tokenId,
        address indexed registrant,
        bytes32 canonicalHash,
        bytes32 ga4ghSeqhash,
        bytes32 screeningAttestationUID
    );

    /// @notice Emitted when a fork-of-existing-design is registered.
    /// @param tokenId New child tokenId.
    /// @param parentTokenIds Parents that contributed (1 or more). First element is the primary parent.
    /// @param registrant The address recorded as the registrant; receives the ERC-1155 mint
    ///                   and the royalty stream. MAY differ from `msg.sender` on relayer flows.
    event DesignForked(uint256 indexed tokenId, bytes32[] parentTokenIds, address indexed registrant);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when supplied canonicalHash does not match the on-chain commitment rules.
    /// @param expected The hash derived from inputs.
    /// @param actual The hash supplied by the caller.
    error CanonicalHashMismatch(bytes32 expected, bytes32 actual);

    /// @notice Thrown when the supplied screening attestation fails ScreeningAttestations.isValid.
    /// @param attestationUID The EAS UID that failed validation.
    error AttestationInvalid(bytes32 attestationUID);

    /// @notice Thrown when a tokenId has already been registered.
    /// @param tokenId The duplicate tokenId.
    error AlreadyRegistered(uint256 tokenId);

    /// @notice Thrown when a parent tokenId in a fork is not itself a registered design.
    /// @param parentTokenId The unknown parent.
    error InvalidParent(bytes32 parentTokenId);

    /// @notice Thrown when a fork declares more parents than `SeqoraTypes.MAX_PARENTS` allows.
    /// @param supplied Total parents supplied (primary + additional).
    /// @param max The configured upper bound.
    error TooManyParents(uint256 supplied, uint256 max);

    // -------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------

    /// @notice Register a new genesis design on behalf of `registrant`.
    /// @dev The ERC-1155 mint target and the stored `registrant` field are both set to the
    ///      `registrant` argument, NOT `msg.sender`. This enables relayer, Safe, and 4337
    ///      smart-account flows while preserving the H-01 binding: `IScreeningAttestations.isValid`
    ///      is called with `(attestationUID, canonicalHash, registrant)`, so the attester must
    ///      have explicitly signed an attestation for this registrant.
    ///
    ///      Off-chain UX SHOULD set `registrant = msg.sender` for direct EOA flows; relayers MAY
    ///      set it to the end-user address provided the EAS attestation was issued for that
    ///      address.
    ///
    ///      Reverts with `AttestationInvalid` if the screening attestation does not validate
    ///      for the supplied `(canonicalHash, registrant)` pair, `AlreadyRegistered` if the
    ///      tokenId is taken, `UseForkRegister` if parents are supplied (use `forkRegister`),
    ///      and `ZeroAddress` if `registrant == address(0)`.
    /// @param registrant Address that will own the minted tokenId and the royalty stream.
    /// @param canonicalHash keccak256 of URDNA2015-canonicalized SBOL3 JSON-LD.
    /// @param ga4ghSeqhash GA4GH VRS seqhash (0x0 if not applicable).
    /// @param arweaveTx Arweave transaction id for the canonical payload.
    /// @param ceramicStreamId Ceramic stream id for mutable metadata.
    /// @param royalty Royalty rule frozen at mint.
    /// @param screeningAttestationUID EAS UID from a governance-approved attester, bound to
    ///                                `registrant`.
    /// @param parentTokenIds Empty for genesis registrations; use `forkRegister` for forks.
    /// @return tokenId The minted tokenId (always == uint256(canonicalHash)).
    function register(
        address registrant,
        bytes32 canonicalHash,
        bytes32 ga4ghSeqhash,
        string calldata arweaveTx,
        string calldata ceramicStreamId,
        SeqoraTypes.RoyaltyRule calldata royalty,
        bytes32 screeningAttestationUID,
        bytes32[] calldata parentTokenIds
    ) external returns (uint256 tokenId);

    /// @notice Register a fork on behalf of `params.registrant` using a packed param struct.
    /// @dev Parameters are packed into `SeqoraTypes.ForkParams` to collapse stack pressure (tester
    ///      P1). The ERC-1155 mint target and stored `registrant` are both `params.registrant`;
    ///      see `register` natspec for the relayer/Safe rationale. `isValid` is called with
    ///      `(screeningAttestationUID, canonicalHash, registrant)` per H-01.
    ///
    ///      Auto-splits the new royalty stream so that `parentSplitBps` flows back to parents'
    ///      0xSplits contracts (see plan §4 — Story PIL semantics). The actual per-parent split
    ///      percentages are deployed off-chain from `parentsOf` + `parentSplitBps`; the registry
    ///      only stores the graph + scalar.
    ///
    ///      Reverts with `TooManyParents` if `1 + additionalParentTokenIds.length > MAX_PARENTS`,
    ///      plus the usual `InvalidParent`, `SelfParent`, `AlreadyRegistered`, `AttestationInvalid`,
    ///      `BpsOutOfRange`, `InvalidRoyaltyRecipient`, and `ZeroAddress` conditions.
    /// @param params Packed fork parameters.
    /// @return tokenId The new child tokenId.
    function forkRegister(SeqoraTypes.ForkParams calldata params) external returns (uint256 tokenId);

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Read the on-chain header for a registered design.
    /// @param tokenId Design id.
    /// @return design The full Design struct.
    function getDesign(uint256 tokenId) external view returns (SeqoraTypes.Design memory design);

    /// @notice Whether `tokenId` has been registered.
    /// @param tokenId Design id to check.
    /// @return registered True if a design header exists for this id.
    function isRegistered(uint256 tokenId) external view returns (bool registered);

    /// @notice The parents of a registered design.
    /// @param tokenId Design id.
    /// @return parents Parent canonical hashes (empty for genesis).
    function parentsOf(uint256 tokenId) external view returns (bytes32[] memory parents);
}
