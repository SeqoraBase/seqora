// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SeqoraTypes
/// @notice Shared structs, enums, and constants used across Seqora v1 contracts.
/// @dev Pure type library. No state, no logic. Imported by interfaces and implementations.
library SeqoraTypes {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Basis-point denominator. All bps values are out of 10_000.
    uint16 internal constant BPS = 10_000;

    /// @notice Maximum total royalty bps allowed for a single design (25%).
    /// @dev Defensive cap. Plan does not pin a number; chosen to keep markets liquid.
    uint16 internal constant MAX_ROYALTY_BPS = 2500;

    /// @notice Protocol fee taken by the v4 hook on license payments (3%).
    uint16 internal constant PROTOCOL_FEE_BPS = 300;

    /// @notice Maximum number of parents (primary + additional) a fork may declare.
    /// @dev Per audit finding M-01. Bounds on-chain storage and the O(n^2) dup check in
    ///      `DesignRegistry.forkRegister`, and prevents landmine reads via `parentsOf`.
    ///      16 is a comfortable headroom over the empirical synbio upper bound (~10).
    uint256 internal constant MAX_PARENTS = 16;

    /// @notice Maximum license duration enforceable via `LicenseTemplate.defaultDuration`
    ///         or per-grant `expiry` overrides (~100 years in seconds).
    /// @dev Per LicenseRegistry audit finding M-04. Caps runaway or misconfigured templates
    ///      that could otherwise set ~11M-year expiries indistinguishable from perpetual.
    ///      `0` always means "no expiry / perpetual" — unaffected by this cap.
    ///      100 * 365 days = 3_153_600_000 seconds — comfortably fits uint32/uint64.
    uint256 internal constant MAX_LICENSE_DURATION = 100 * 365 days;

    // -------------------------------------------------------------------------
    // BiosafetyCourt constants (plan §3, §6 #4)
    // -------------------------------------------------------------------------

    /// @notice Minimum ETH bond a reviewer must post to participate in dispute resolution.
    /// @dev v1 denominates reviewer bonds in ETH for simplicity; v2 migrates to $SEQ once the
    ///      token is live. 1 ether matches a "skin in the game" tier large enough to punish
    ///      griefers but small enough not to gate academic reviewers out.
    uint128 internal constant MIN_REVIEWER_STAKE = 1 ether;

    /// @notice Cooldown between `requestUnstake` and `unstakeReviewer` (seven days).
    /// @dev Prevents a reviewer from rage-withdrawing the moment a dispute they hold a stake
    ///      in starts going against them. Long enough to cover the `MIN_DISPUTE_REVIEW_WINDOW`
    ///      plus a cushion for governance to slash.
    uint64 internal constant REVIEWER_UNSTAKE_COOLDOWN = 7 days;

    /// @notice Bond required from the party raising a dispute (0.5 ETH).
    /// @dev Smaller than `MIN_REVIEWER_STAKE` so active reviewers, who already have skin in the
    ///      game, can open disputes without re-bonding. Dismissal slashes the bond; upheld
    ///      returns it plus a reward from the slashed reviewer pool.
    uint128 internal constant DISPUTE_BOND = 0.5 ether;

    /// @notice Minimum time a dispute must be open before it can be resolved (48 hours).
    /// @dev Per plan §3 ("48h Safety Council takedown"). Applied here as a bound on reviewer
    ///      resolution so a collusive set of reviewers cannot rubber-stamp a freeze inside the
    ///      same block the raise lands.
    uint64 internal constant MIN_DISPUTE_REVIEW_WINDOW = 48 hours;

    /// @notice Window the DAO has to ratify or reject a Safety Council freeze (30 days).
    /// @dev Per plan §3 + §6 #4. Lapsing without ratification auto-lifts via
    ///      `expireFreeze`, enforcing the "reversible by default" invariant from CLAUDE.md.
    uint64 internal constant SAFETY_COUNCIL_FREEZE_WINDOW = 30 days;

    /// @notice Share of a dismissed disputer's bond paid to the resolving reviewer (30%).
    uint16 internal constant DISMISSAL_REVIEWER_CUT_BPS = 3000;

    /// @notice Share of a dismissed disputer's bond sent to the treasury (70%).
    uint16 internal constant DISMISSAL_TREASURY_CUT_BPS = 7000;

    /// @notice Share of the slashed-reviewer pool paid to the disputer on upheld outcomes (10%).
    uint16 internal constant UPHELD_DISPUTER_REWARD_BPS = 1000;

    // -------------------------------------------------------------------------
    // PIL flag bits (Story Protocol PIL semantics — re-implemented natively on Base)
    // -------------------------------------------------------------------------
    //
    // Each `LicenseTemplate.pilFlags` is a uint16 bitfield. 5 flags land in v1, 11 bits reserved
    // for v2 expansion (royalty-share, sublicensing, commercial-attribution, etc.). Validation
    // rules encoded in `LicenseRegistry.createTemplate`:
    //   - PIL_DERIVATIVE requires PIL_ATTRIBUTION (downstream must credit).
    //   - PIL_EXCLUSIVE + PIL_TRANSFERABLE is ALLOWED (transferable exclusive licenses are a
    //     legitimate market primitive).
    //   - PIL_EXCLUSIVE with a non-whitelist template (openGrant) is ALLOWED but semantics
    //     are enforced at grant time: only ONE outstanding exclusive grant per tokenId.

    /// @notice PIL flag: licensee may commercialise the design.
    uint16 internal constant PIL_COMMERCIAL = 0x01;

    /// @notice PIL flag: licensee may create derivative works.
    uint16 internal constant PIL_DERIVATIVE = 0x02;

    /// @notice PIL flag: licensee must attribute upstream designer / registrant.
    uint16 internal constant PIL_ATTRIBUTION = 0x04;

    /// @notice PIL flag: exclusive license. Only one active `PIL_EXCLUSIVE` grant may exist per tokenId.
    uint16 internal constant PIL_EXCLUSIVE = 0x08;

    /// @notice PIL flag: the license token may be transferred to a third party.
    uint16 internal constant PIL_TRANSFERABLE = 0x10;

    /// @notice Bitmask of all PIL flag bits defined in v1. Bits outside this mask are reserved.
    uint16 internal constant PIL_V1_MASK =
        PIL_COMMERCIAL | PIL_DERIVATIVE | PIL_ATTRIBUTION | PIL_EXCLUSIVE | PIL_TRANSFERABLE;

    // -------------------------------------------------------------------------
    // Enums
    // -------------------------------------------------------------------------

    /// @notice Origin classification for a screening attester.
    /// @dev Mirrors the IGSC / IBBIS / SecureDNA framework called out in plan §6.
    enum ScreenerKind {
        Unknown,
        IGSC,
        IBBIS,
        SecureDNA,
        Other
    }

    /// @notice Outcome of a BiosafetyCourt dispute.
    enum DisputeOutcome {
        Pending,
        UpheldTakedown,
        Dismissed,
        Settled
    }

    /// @notice Lifecycle state of a safety freeze.
    enum FreezeStatus {
        None,
        Active, // 48h emergency freeze applied by Safety Council
        Ratified, // DAO confirmed within 30 days
        Rejected, // DAO rejected
        AutoLifted // 30d window elapsed without ratification
    }

    /// @notice Kind of provenance record stored against a tokenId.
    enum ProvenanceKind {
        ModelCard,
        WetLab
    }

    // -------------------------------------------------------------------------
    // Structs — Royalty
    // -------------------------------------------------------------------------

    /// @notice Royalty rule attached to a design at registration. Immutable post-mint.
    /// @param recipient EIP-2981 receiver — usually a 0xSplits contract address.
    /// @param bps Royalty in basis points; must be <= MAX_ROYALTY_BPS.
    /// @param parentSplitBps Portion (in bps of `bps`) routed back to parent design splits on a fork. 0 if no parents.
    struct RoyaltyRule {
        address recipient;
        uint16 bps;
        uint16 parentSplitBps;
    }

    // -------------------------------------------------------------------------
    // Structs — Design
    // -------------------------------------------------------------------------

    /// @notice On-chain header for a registered design.
    /// @param canonicalHash keccak256 of URDNA2015-canonicalized SBOL3. tokenId == uint256(canonicalHash).
    /// @param ga4ghSeqhash GA4GH VRS seqhash for the underlying raw sequence (0x0 if multi-sequence).
    /// @param arweaveTx Arweave tx id holding the canonical SBOL3 JSON-LD payload.
    /// @param ceramicStreamId Ceramic stream id holding mutable metadata owned by tokenId.
    /// @param royalty Royalty rule frozen at registration.
    /// @param screeningAttestationUID EAS attestation UID proving pre-listing screening.
    /// @param parentTokenIds Parents in the fork graph (empty for genesis designs).
    /// @param registrant Address that called `register` / `forkRegister`.
    /// @param registeredAt Block timestamp at registration.
    struct Design {
        bytes32 canonicalHash;
        bytes32 ga4ghSeqhash;
        string arweaveTx;
        string ceramicStreamId;
        RoyaltyRule royalty;
        bytes32 screeningAttestationUID;
        bytes32[] parentTokenIds;
        address registrant;
        uint64 registeredAt;
    }

    // -------------------------------------------------------------------------
    // Structs — Fork registration params
    // -------------------------------------------------------------------------

    /// @notice Packed parameter bundle for `IDesignRegistry.forkRegister`.
    /// @dev Collapses what would otherwise be an 8-argument external call to keep the caller
    ///      stack within solc's limits under `via_ir=false` coverage runs (tester P1).
    /// @param registrant Address that will own the minted tokenId and the royalty stream.
    ///                   Off-chain UX SHOULD set `registrant = msg.sender` for direct EOA flows;
    ///                   relayers MAY set it to the end-user address provided the EAS
    ///                   attestation was issued for that address (see H-01 binding in
    ///                   `IScreeningAttestations`).
    /// @param primaryParentTokenId Primary parent (root of fork chain). Must already be registered.
    /// @param additionalParentTokenIds Extra parents beyond the primary. Total parent count
    ///                                 (1 + additional) must not exceed `MAX_PARENTS`.
    /// @param canonicalHash keccak256 of the new canonicalized SBOL3 doc.
    /// @param ga4ghSeqhash GA4GH VRS seqhash for the forked sequence (0x0 if multi-sequence).
    /// @param arweaveTx Arweave transaction id for the new canonical payload.
    /// @param ceramicStreamId Ceramic stream id for the new mutable metadata.
    /// @param royaltyRule Royalty rule for the new tokenId.
    /// @param screeningAttestationUID EAS UID screening the new design, bound to `registrant`.
    /// @param metadataURI Optional per-token metadata URI pointer (empty string = use base URI).
    struct ForkParams {
        address registrant;
        uint256 primaryParentTokenId;
        bytes32[] additionalParentTokenIds;
        bytes32 canonicalHash;
        bytes32 ga4ghSeqhash;
        string arweaveTx;
        string ceramicStreamId;
        RoyaltyRule royaltyRule;
        bytes32 screeningAttestationUID;
        string metadataURI;
    }

    // -------------------------------------------------------------------------
    // Structs — Licensing
    // -------------------------------------------------------------------------

    /// @notice On-chain SPDX-style license template addressable by `licenseId`.
    /// @dev `pilFlags` + `defaultDuration` were added alongside LicenseRegistry v1 to encode
    ///      Story-PIL semantics natively on Base (research 2026-04-16 report §2). The legacy
    ///      `commercialUse` / `requiresAttribution` booleans are retained for backwards
    ///      compatibility but are treated as *informational metadata*: the canonical permission
    ///      set is `pilFlags`. Governance SHOULD set the booleans consistent with the flag
    ///      bits (commercialUse == (pilFlags & PIL_COMMERCIAL != 0)).
    /// @param licenseId keccak256 identifier (e.g. keccak256("OpenMTA")).
    /// @param name Human-readable label (e.g. "OpenMTA-NC").
    /// @param uri Off-chain URI (Arweave/IPFS) holding the legal text.
    /// @param commercialUse Legacy flag; see `pilFlags & PIL_COMMERCIAL` for canonical truth.
    /// @param requiresAttribution Legacy flag; see `pilFlags & PIL_ATTRIBUTION` for canonical truth.
    /// @param active False if governance has retired this template.
    /// @param pilFlags uint16 bitfield of PIL_* constants; canonical permission set.
    /// @param defaultDuration Default license duration in DAYS applied at grant time when the
    ///                        caller passes `expiry == 0`. `0` here ⇒ perpetual by default.
    struct LicenseTemplate {
        bytes32 licenseId;
        string name;
        string uri;
        bool commercialUse;
        bool requiresAttribution;
        bool active;
        uint16 pilFlags;
        uint32 defaultDuration;
    }

    /// @notice On-chain record minted as an ERC-721 License Token by LicenseRegistry.
    /// @param tokenId Design tokenId being licensed.
    /// @param licenseId Template id used for this grant.
    /// @param licensee Address granted the license.
    /// @param grantedAt Timestamp granted.
    /// @param expiry Unix seconds; 0 = perpetual.
    /// @param feePaid Amount paid in the registry's accounting currency.
    /// @param revoked True after governance revocation.
    struct License {
        uint256 tokenId;
        bytes32 licenseId;
        address licensee;
        uint64 grantedAt;
        uint64 expiry;
        uint128 feePaid;
        bool revoked;
    }

    // -------------------------------------------------------------------------
    // Structs — Provenance
    // -------------------------------------------------------------------------

    /// @notice ModelCard captures AI tooling used to design a sequence.
    /// @dev Required input to settle the human-contribution / AI-inventorship question (plan §2 #6, §6 #3).
    /// @param weightsHash Hash of the model weights snapshot (e.g. ESM3, RFdiffusion).
    /// @param promptHash Hash of the prompt or task spec used.
    /// @param seed RNG seed for reproducibility.
    /// @param toolName Free-form name (e.g. "RFdiffusion-1.2").
    /// @param toolVersion Free-form version string.
    /// @param contributor Wallet of the human author claiming contribution.
    /// @param createdAt Timestamp the inference was run.
    struct ModelCard {
        bytes32 weightsHash;
        bytes32 promptHash;
        bytes32 seed;
        string toolName;
        string toolVersion;
        address contributor;
        uint64 createdAt;
    }

    /// @notice Wet-lab synthesis attestation from a governance-approved oracle.
    /// @dev v1 = signed synthesis receipt (Twist/IDT/Ansa). v2 will accept TEE proofs.
    /// @param oracle Address of the approved oracle that signed.
    /// @param vendor Free-form vendor name (e.g. "Twist Bioscience").
    /// @param orderRef Vendor order reference / receipt id.
    /// @param synthesizedAt Timestamp synthesis was completed.
    /// @param payloadHash Hash of the off-chain receipt blob.
    struct WetLabAttestation {
        address oracle;
        string vendor;
        string orderRef;
        uint64 synthesizedAt;
        bytes32 payloadHash;
    }

    /// @notice Unified provenance entry returned by `getProvenance`.
    /// @param kind ModelCard or WetLab.
    /// @param recordHash Hash of the canonical record blob (ModelCard or WetLabAttestation EIP-712 digest).
    /// @param submitter Address that submitted (registrant or oracle).
    /// @param recordedAt Timestamp recorded on-chain.
    struct ProvenanceRecord {
        ProvenanceKind kind;
        bytes32 recordHash;
        address submitter;
        uint64 recordedAt;
    }

    // -------------------------------------------------------------------------
    // Structs — BiosafetyCourt
    // -------------------------------------------------------------------------

    /// @notice State for a reviewer staking position.
    /// @param bond Amount of $SEQ (or USDC, governance-set) bonded.
    /// @param stakedAt Timestamp the bond was posted.
    /// @param unstakeRequestedAt 0 if no unstake pending; else timestamp of the request.
    struct ReviewerStake {
        uint128 bond;
        uint64 stakedAt;
        uint64 unstakeRequestedAt;
    }

    /// @notice A dispute case raised against a registered design.
    /// @param tokenId Design under dispute.
    /// @param raiser Reviewer who opened the case.
    /// @param evidenceHash Hash of off-chain evidence bundle.
    /// @param reason Free-form short reason (DURC, IP, export-control, etc.).
    /// @param openedAt Timestamp opened.
    /// @param resolvedAt 0 if still open.
    /// @param outcome Result of arbitration.
    struct Dispute {
        uint256 tokenId;
        address raiser;
        bytes32 evidenceHash;
        string reason;
        uint64 openedAt;
        uint64 resolvedAt;
        DisputeOutcome outcome;
    }

    /// @notice Safety freeze record for a tokenId.
    /// @param status Lifecycle state.
    /// @param appliedAt Timestamp the 48h freeze was applied.
    /// @param expiresAt Timestamp the freeze auto-lifts if not ratified (appliedAt + 30d).
    /// @param reason Free-form short reason.
    struct SafetyFreeze {
        FreezeStatus status;
        uint64 appliedAt;
        uint64 expiresAt;
        string reason;
    }
}
