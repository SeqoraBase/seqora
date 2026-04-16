// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------------------
// DesignRegistry — Seqora v1
//
// Plan (§4): canonical, immutable ERC-1155 registry of SBOL3 designs.
//   tokenId == uint256(canonicalHash) where canonicalHash = keccak256(URDNA2015(SBOL3))
//
// State variables
// ---------------
//   _designs      tokenId -> Design struct (on-chain header)
//   SCREENING     IScreeningAttestations immutable
//
// Functions (external)
// --------------------
//   constructor(baseUri, screeningContract)
//   register(registrant, canonicalHash, ga4ghSeqhash, arweaveTx, ceramicStreamId,
//            royalty, attUID, parents)
//   forkRegister(ForkParams)
//   getDesign(tokenId) view
//   isRegistered(tokenId) view
//   parentsOf(tokenId) view
//
// Events / errors: see IDesignRegistry. Local errors declared below for impl-only conditions.
//
// Immutability posture
// --------------------
//   No Ownable, no Pausable, no upgrade hooks. The screening contract is set once in the
//   constructor and cannot be rotated. This contract is the canonical registration primitive
//   — swapping screeners post-deployment would break the trust model. If the screening
//   contract needs to be upgraded, deploy a *new* DesignRegistry (tokenIds remain stable
//   because they are hash-derived).
//
// Audit fixes (2026-04-16)
// ------------------------
//   H-01 — `registrant` is an explicit parameter (not `msg.sender`). `SCREENING.isValid` is
//          called with `(uid, canonicalHash, registrant)` so a mempool replay fails screening.
//   M-01 — `MAX_PARENTS = 16` hard cap on forkRegister parent count; `TooManyParents` error.
//   M-02 — Resolved by H-01; mint target == registrant; relayer/Safe flows are first-class.
//   L-01 — Dead `msg.sender == 0` check removed; `registrant == 0` check retained + strengthened.
//   L-02 — `arweaveTx` / `ceramicStreamId` capped at 128 bytes each.
// -----------------------------------------------------------------------------

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IDesignRegistry } from "./interfaces/IDesignRegistry.sol";
import { IScreeningAttestations } from "./interfaces/IScreeningAttestations.sol";
import { SeqoraTypes } from "./libraries/SeqoraTypes.sol";
import { SeqoraErrors } from "./libraries/SeqoraErrors.sol";

/// @title DesignRegistry
/// @notice Canonical on-chain registry of SBOL3 designs. tokenId == uint256(keccak256(URDNA2015(SBOL3))).
/// @dev Immutable by design. No upgrade path, no owner-controlled mutations of registered headers.
contract DesignRegistry is ERC1155, ReentrancyGuard, IDesignRegistry {
    using SeqoraTypes for SeqoraTypes.RoyaltyRule;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Hard cap on the byte length of `arweaveTx` and `ceramicStreamId` strings.
    /// @dev Arweave tx ids are 43 base64 chars; Ceramic stream ids are ~63 chars. 128 is comfortable
    ///      headroom while still blocking storage-bloat griefing (L-02).
    uint256 internal constant MAX_STRING_BYTES = 128;

    // -------------------------------------------------------------------------
    // Local errors (conditions only meaningful to this impl)
    // -------------------------------------------------------------------------

    /// @notice Thrown when `forkRegister` is called with no parents at all.
    /// @dev Genesis registrations must use `register`.
    error NoParentsForFork();

    /// @notice Thrown when a fork names itself as a parent.
    /// @param tokenId The self-referential tokenId.
    error SelfParent(uint256 tokenId);

    /// @notice Thrown when `register` is called with a non-empty `parentTokenIds` array.
    /// @dev Callers wanting to register a fork must use `forkRegister`.
    error UseForkRegister();

    /// @notice Thrown when the royalty recipient is the zero address while bps > 0.
    error InvalidRoyaltyRecipient();

    /// @notice Thrown when `arweaveTx` or `ceramicStreamId` exceeds `MAX_STRING_BYTES`.
    /// @param supplied Length of the offending string in bytes.
    /// @param max The configured upper bound (`MAX_STRING_BYTES`).
    error StringTooLong(uint256 supplied, uint256 max);

    // -------------------------------------------------------------------------
    // Immutable state
    // -------------------------------------------------------------------------

    /// @notice Screening attestation contract. Bound for the lifetime of this registry.
    IScreeningAttestations public immutable SCREENING;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @dev tokenId -> full Design header. `registeredAt != 0` iff registered.
    mapping(uint256 => SeqoraTypes.Design) private _designs;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploy the registry.
    /// @param baseUri_ ERC-1155 metadata URI template (supports `{id}` substitution).
    /// @param screening_ Governance-approved screening attestation contract.
    constructor(string memory baseUri_, IScreeningAttestations screening_) ERC1155(baseUri_) {
        if (address(screening_) == address(0)) revert SeqoraErrors.ZeroAddress();
        SCREENING = screening_;
    }

    // -------------------------------------------------------------------------
    // Registration — genesis
    // -------------------------------------------------------------------------

    /// @inheritdoc IDesignRegistry
    function register(
        address registrant,
        bytes32 canonicalHash,
        bytes32 ga4ghSeqhash,
        string calldata arweaveTx,
        string calldata ceramicStreamId,
        SeqoraTypes.RoyaltyRule calldata royalty,
        bytes32 screeningAttestationUID,
        bytes32[] calldata parentTokenIds
    ) external nonReentrant returns (uint256 tokenId) {
        // Genesis path only — forks go through forkRegister so the graph is tracked explicitly.
        if (parentTokenIds.length != 0) revert UseForkRegister();

        tokenId = _mintDesign(
            registrant,
            canonicalHash,
            ga4ghSeqhash,
            arweaveTx,
            ceramicStreamId,
            royalty,
            screeningAttestationUID,
            new bytes32[](0)
        );

        emit DesignRegistered(tokenId, registrant, canonicalHash, ga4ghSeqhash, screeningAttestationUID);
    }

    // -------------------------------------------------------------------------
    // Registration — fork
    // -------------------------------------------------------------------------

    /// @inheritdoc IDesignRegistry
    function forkRegister(SeqoraTypes.ForkParams calldata params) external nonReentrant returns (uint256 tokenId) {
        // Primary parent must exist. Zero primary parent is illegal (use `register`).
        if (params.primaryParentTokenId == 0) revert NoParentsForFork();
        if (_designs[params.primaryParentTokenId].registeredAt == 0) {
            revert InvalidParent(bytes32(params.primaryParentTokenId));
        }

        // M-01: bound the parent graph to keep downstream `parentsOf` reads cheap forever.
        uint256 totalParents = params.additionalParentTokenIds.length + 1;
        if (totalParents > SeqoraTypes.MAX_PARENTS) {
            revert TooManyParents(totalParents, SeqoraTypes.MAX_PARENTS);
        }

        // Compose parent array: [primary, ...additional]. We store canonical hashes (== bytes32(tokenId))
        // because the Design struct's `parentTokenIds` field is typed bytes32[] per interface.
        bytes32[] memory parents = new bytes32[](totalParents);
        parents[0] = bytes32(params.primaryParentTokenId);

        // Candidate child tokenId (early compute so self-parent check is cheap).
        uint256 childTokenId = uint256(params.canonicalHash);
        if (childTokenId == params.primaryParentTokenId) revert SelfParent(params.primaryParentTokenId);

        uint256 addlLen = params.additionalParentTokenIds.length;
        for (uint256 i = 0; i < addlLen;) {
            bytes32 p = params.additionalParentTokenIds[i];
            uint256 pId = uint256(p);

            // Defensive checks per parent.
            if (pId == 0) revert InvalidParent(p);
            if (pId == childTokenId) revert SelfParent(pId);
            if (pId == params.primaryParentTokenId) revert InvalidParent(p); // duplicate of primary
            if (_designs[pId].registeredAt == 0) revert InvalidParent(p);

            // Also reject duplicates within additionalParents. Bounded by MAX_PARENTS (16), so the
            // O(n^2) cost is ≤ 256 comparisons — trivial.
            for (uint256 j = 0; j < i;) {
                if (params.additionalParentTokenIds[j] == p) revert InvalidParent(p);
                unchecked {
                    ++j;
                }
            }

            parents[i + 1] = p;
            unchecked {
                ++i;
            }
        }

        tokenId = _mintDesign(
            params.registrant,
            params.canonicalHash,
            params.ga4ghSeqhash,
            params.arweaveTx,
            params.ceramicStreamId,
            params.royaltyRule,
            params.screeningAttestationUID,
            parents
        );

        // NOTE: royalty auto-split among parents is enforced off-chain at 0xSplits deploy time
        // using RoyaltyRule.parentSplitBps plus `parents` (equal weight per 13:30 log entry #7).
        // The registry stores the graph + the parentSplitBps scalar; RoyaltyRouter is the actor
        // that actually wires the per-parent split percentages. Cycle prevention is unnecessary:
        // tokenId == uint256(canonicalHash), so a cycle would require keccak256 preimage collision.

        emit DesignForked(tokenId, parents, params.registrant);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IDesignRegistry
    function getDesign(uint256 tokenId) external view returns (SeqoraTypes.Design memory design) {
        design = _designs[tokenId];
        if (design.registeredAt == 0) revert SeqoraErrors.UnknownToken(tokenId);
    }

    /// @inheritdoc IDesignRegistry
    function isRegistered(uint256 tokenId) external view returns (bool registered) {
        registered = _designs[tokenId].registeredAt != 0;
    }

    /// @inheritdoc IDesignRegistry
    function parentsOf(uint256 tokenId) external view returns (bytes32[] memory parents) {
        if (_designs[tokenId].registeredAt == 0) revert SeqoraErrors.UnknownToken(tokenId);
        parents = _designs[tokenId].parentTokenIds;
    }

    // -------------------------------------------------------------------------
    // ERC-165
    // -------------------------------------------------------------------------

    /// @notice ERC-165 interface support. Declares IDesignRegistry alongside base ERC-1155 surfaces.
    /// @param interfaceId Interface id to check.
    /// @return supported True if this contract implements `interfaceId`.
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC1155) returns (bool supported) {
        supported = interfaceId == type(IDesignRegistry).interfaceId || super.supportsInterface(interfaceId);
    }

    // -------------------------------------------------------------------------
    // Internal — shared mint path
    // -------------------------------------------------------------------------

    /// @dev Shared validation + storage + mint logic for both `register` and `forkRegister`.
    ///      Reverts with the interface-level errors on failure. Follows checks-effects-interactions:
    ///      (1) validate inputs, (2) external (static) call to screening, (3) storage write,
    ///      (4) `_mint` — whose ERC-1155 receiver hook is the only state-mutating external call.
    ///      The external call ordering is safe because the Design struct is fully written before
    ///      the receiver hook fires, so any re-entering read sees a consistent world; the
    ///      `nonReentrant` guard on `register`/`forkRegister` additionally blocks recursion
    ///      through the receiver hook (P3 — the reentrancy vector the guard defends is
    ///      `_mint` → `onERC1155Received` → hostile contract, *not* the screener, which is `view`
    ///      and therefore invoked via STATICCALL).
    function _mintDesign(
        address registrant,
        bytes32 canonicalHash,
        bytes32 ga4ghSeqhash,
        string calldata arweaveTx,
        string calldata ceramicStreamId,
        SeqoraTypes.RoyaltyRule calldata royalty,
        bytes32 screeningAttestationUID,
        bytes32[] memory parents
    ) internal returns (uint256 tokenId) {
        // --- Checks ---

        // H-01: registrant cannot be the zero address. This is the real (reachable) check; the
        // previous `msg.sender == 0` check (L-01) was dead code and has been removed.
        if (registrant == address(0)) revert SeqoraErrors.ZeroAddress();

        if (canonicalHash == bytes32(0)) revert SeqoraErrors.ZeroValue();

        // L-02: bound unbounded-string griefing. Self-paid but still worth capping.
        if (bytes(arweaveTx).length > MAX_STRING_BYTES) {
            revert StringTooLong(bytes(arweaveTx).length, MAX_STRING_BYTES);
        }
        if (bytes(ceramicStreamId).length > MAX_STRING_BYTES) {
            revert StringTooLong(bytes(ceramicStreamId).length, MAX_STRING_BYTES);
        }

        tokenId = uint256(canonicalHash);

        // tokenId derivation lock: the interface contract is `tokenId == uint256(canonicalHash)`.
        // We enforce it by *computing* tokenId ourselves rather than trusting caller input, so
        // CanonicalHashMismatch is structurally unreachable from this entrypoint. It is declared
        // in the interface and kept for future variants (e.g. if the derivation changes).
        if (_designs[tokenId].registeredAt != 0) revert AlreadyRegistered(tokenId);

        // Royalty validation.
        if (royalty.bps > SeqoraTypes.MAX_ROYALTY_BPS) revert SeqoraErrors.BpsOutOfRange(royalty.bps);
        if (royalty.parentSplitBps > SeqoraTypes.BPS) revert SeqoraErrors.BpsOutOfRange(royalty.parentSplitBps);
        if (royalty.bps > 0 && royalty.recipient == address(0)) revert InvalidRoyaltyRecipient();
        // parentSplitBps only meaningful on forks; hard-reject nonzero for genesis.
        if (parents.length == 0 && royalty.parentSplitBps != 0) {
            revert SeqoraErrors.BpsOutOfRange(royalty.parentSplitBps);
        }

        // --- Interaction: screening validity (STATICCALL — `isValid` is `view`) ---
        // H-01: attestation is bound to `registrant`. A mempool replay that preserves
        // (canonicalHash, uid) but substitutes a different registrant fails here.
        if (!SCREENING.isValid(screeningAttestationUID, canonicalHash, registrant)) {
            revert AttestationInvalid(screeningAttestationUID);
        }

        // --- Effects ---
        SeqoraTypes.Design storage d = _designs[tokenId];
        d.canonicalHash = canonicalHash;
        d.ga4ghSeqhash = ga4ghSeqhash;
        d.arweaveTx = arweaveTx;
        d.ceramicStreamId = ceramicStreamId;
        d.royalty = royalty;
        d.screeningAttestationUID = screeningAttestationUID;
        d.registrant = registrant;
        d.registeredAt = uint64(block.timestamp);
        uint256 plen = parents.length;
        for (uint256 i = 0; i < plen;) {
            d.parentTokenIds.push(parents[i]);
            unchecked {
                ++i;
            }
        }

        // --- Mint ---
        // Supply = 1. Designs are not fungible; ERC-1155 is used for batch transfer / ops ergonomics.
        // The receiver hook fires AFTER state writes — a hostile `registrant` contract cannot read
        // a half-written Design struct, and `nonReentrant` blocks recursion back into this path.
        _mint(registrant, tokenId, 1, "");
    }
}
