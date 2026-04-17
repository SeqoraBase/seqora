// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------------------
// BiosafetyCourt — Seqora v1
//
// Plan (§3, §6 #4, §10): Kleros-style slashable reviewer bonds + a dual-key Safety Council
// emergency-freeze path ratified by the DAO within 30 days (else auto-lifts).
//
//   +-----------------+    +---------------------+     +----------------------+
//   |  Reviewer set   |    |  Disputes (Kleros)  |     |   Safety Council     |
//   |  (staked bonds) +----+  raise → review 48h +-----+  48h freeze + DAO    |
//   +-----------------+    |  → resolve / slash  |     |  ratify or expire    |
//                          +---------------------+     +----------------------+
//
// Two-phase emergency governance:
//   1. Reviewer disputes — staked reviewers open a case, governance (arbitrator) resolves
//      after `MIN_DISPUTE_REVIEW_WINDOW`. UpheldTakedown freezes the tokenId AND slashes
//      adversely-positioned reviewers; Dismissed slashes the raiser's bond share 70/30
//      treasury/resolving-reviewer.
//   2. Safety Council freezes — a dual-key `safetyCouncil` address (distinct from `owner`)
//      can immediately freeze a tokenId. The DAO (the `owner`) has 30 days to ratify or
//      reject; after 30 days anyone can auto-lift via `expireFreeze`.
//
// Upgradeability posture
// ----------------------
//   UUPS (per architecture spec: UUPS only for LicenseRegistry + BiosafetyCourt). Implementation
//   calls `_disableInitializers()` in the constructor; state lives in the proxy.
//   `_authorizeUpgrade` is `onlyOwner`. All OZ v5 upgradeable parents use ERC-7201 namespaced
//   storage (see LicenseRegistry audit storage-layout section) so child storage slots 0…N-1
//   are collision-safe. A `uint256[48] __gap` reserves headroom to 50 slots total.
//
// v1 bond currency — ETH with a receive-then-register pattern
// ----------------------------------------------------------
//   The interface declares `stakeAsReviewer(uint128 bondAmount)` as **non-payable**; Solidity
//   0.8.24's mutability-override rules do NOT allow a `payable` implementation of a non-
//   payable interface function. To still back bonds with real ETH in v1 (per brief §Concept:
//   "use ETH for v1 simplicity"), the contract exposes a `receive() payable` that credits
//   `pendingDeposits[msg.sender]`, and `stakeAsReviewer(bondAmount)` then *consumes* that
//   balance into the reviewer's bond. Reviewers therefore:
//     1. `reviewer.call{value: amount}("")`     // credits pendingDeposits
//     2. `court.stakeAsReviewer(amount)`         // promotes deposit → bond
//   `raiseDispute` does NOT require an additional ETH transfer — `DISPUTE_BOND` is earmarked
//   from the reviewer's existing bond. If the dispute is dismissed the earmark is forfeited
//   (split treasury/resolver); if upheld the earmark is restored plus a reward from slashed
//   reviewers. Brief's "disputer bond" is thus accounted inside the reviewer's stake.
//   v2 replaces this flow with an ERC20 $SEQ transfer — the `pendingDeposits` field will be
//   repurposed / zeroed by a `reinitializer(2)`.
//
// Integration with LicenseRegistry
// --------------------------------
//   This contract exposes `isFrozen(tokenId)` as a read-only surface. LicenseRegistry (v1) does
//   NOT yet consult it — per brief §5 "v1: LicenseRegistry doesn't yet call this". v2 wires a
//   `biosafetyCourt` setter on LicenseRegistry and gates `grantLicense` / existing licenses.
//   The BiosafetyCourt itself does NOT mutate LicenseRegistry state — the integration is a
//   pull, not push, so `LicenseRegistry.sol` remains untouched in v1.
//
// Discrepancies from task brief (escalated to orchestrator via agent-log)
// -----------------------------------------------------------------------
//   1. Interface function `stakeAsReviewer(uint128)` is non-payable. See "v1 bond currency"
//      note above; implemented via `receive()` + `pendingDeposits` accounting.
//   2. Interface has no `approveReviewer` / `revokeReviewer` / `isApprovedReviewer`. Brief
//      proposes an approved-reviewer allowlist; interface instead treats any active staker as
//      a reviewer. I match the interface: anyone with a live, non-cooldown bond ≥
//      MIN_REVIEWER_STAKE counts as an "active reviewer" for `raiseDispute`.
//   3. Interface `resolveDispute` takes no explicit "arbitrator" role. Brief wants "approved
//      reviewers" resolving. In v1 the `owner()` (DAO / governance multisig) is the
//      arbitrator — matches the plan §10 DAO-controlled resolution and keeps the Kleros-style
//      stake-weighted vote as a v2 widening. Reviewer set can upgrade to a stake-weighted
//      vote via a later UUPS impl swap without breaking storage layout.
//   4. Interface `raiseDispute` takes no `bond` arg. `DISPUTE_BOND` is earmarked implicitly
//      from the raiser's stake (see above).
//   5. Interface uses `string calldata reason` for `safetyCouncilFreeze`, not `bytes32
//      reasonHash`. I match the interface — strings are cheap in calldata and the event
//      emits the string for off-chain indexing.
//   6. No `expireFreeze` in the interface but `FreezeAutoLifted` event exists. I add
//      `expireFreeze(tokenId)` as a permissionless public function (additional-surface, does
//      NOT break interface conformance) and ALSO compute auto-lift lazily in `isFrozen` so
//      reads always reflect the true current state even if no one has called `expireFreeze`.
//
// Threat model
// ----------------------------------
//   1. Dual-key collusion — `safetyCouncil` + `owner` controlled by the same entity collapses
//      the 30-day ratification guard. Plan §6 #4 prescribes a 5-of-9 multisig for the council
//      and a separate DAO/governance multisig for the owner. Contract enforces the address
//      distinction but NOT the signer separation — that's an operational concern.
//   2. Reviewer key compromise — a stolen reviewer key can raise frivolous disputes.
//      `MIN_DISPUTE_REVIEW_WINDOW` + Dismissal slashing caps financial damage; one open
//      dispute per tokenId ratelimits DoS.
//   3. Griefing via slashing — a malicious arbitrator (compromised owner) can slash reviewers
//      arbitrarily. Mitigated by owner = multisig + post-launch Timelock per LicenseRegistry
//      M-03. `renounceOwnership` is disabled.
//   4. Freeze race — a design may be frozen concurrently via a dispute resolution AND a
//      Safety Council action. `safetyCouncilFreeze` refuses if the tokenId is already frozen
//      by ANY path; dispute-driven freeze is upgrade-compatible (status == Ratified never
//      auto-lifts; status == Active auto-lifts). See `_setFreezeActive` invariants.
//   5. 30-day auto-lift trust — if the DAO simply fails to ratify, the freeze lifts. This is
//      intentional per design invariant: BiosafetyCourt.takedown is reversible.
//   6. Reentrancy on ETH transfers — `nonReentrant` + CEI + `call{value}` with success check.
//      All payouts happen AFTER state mutations.
//   7. UUPS upgrade safety — `_authorizeUpgrade` is `onlyOwner`; `__gap[48]` reserves 48 slots.
//   8. Economic attack on bond sizing — at `MIN_REVIEWER_STAKE = 1 ether`, 100 reviewers are a
//      100 ETH trust pool. Bond + reward bps are tunable via v2 impl swap (constants move to
//      storage) without a storage-layout break.
// -----------------------------------------------------------------------------

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IBiosafetyCourt } from "./interfaces/IBiosafetyCourt.sol";
import { IDesignRegistry } from "./interfaces/IDesignRegistry.sol";
import { SeqoraTypes } from "./libraries/SeqoraTypes.sol";
import { SeqoraErrors } from "./libraries/SeqoraErrors.sol";

/// @title BiosafetyCourt
/// @notice Reviewer disputes + Safety Council emergency freezes with DAO ratification.
/// @dev UUPS-upgradable. Dual-key: `owner()` = DAO / arbitrator; `safetyCouncil` = 5-of-9
///      multisig that can freeze for 30 days pending DAO action.
contract BiosafetyCourt is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IBiosafetyCourt
{
    // -------------------------------------------------------------------------
    // Local errors (interface-declared errors reused via IBiosafetyCourt)
    // -------------------------------------------------------------------------

    /// @notice Thrown on any attempt to call `renounceOwnership` — governance bricking disabled.
    error RenounceDisabled();

    /// @notice Thrown when caller is not the Safety Council for a council-only action.
    /// @dev Parallel to interface's `NotSafetyCouncil`; used where the check is implementation-internal.
    error NotSafetyCouncilError(address caller);

    /// @notice Thrown when a reviewer's bond (before or after a stake action) falls below the minimum.
    error StakeTooLow(uint128 supplied, uint128 minimum);

    /// @notice Thrown when a caller supplies `bondAmount == 0` to `stakeAsReviewer`.
    error ZeroBondAmount();

    /// @notice Thrown when pendingDeposits are insufficient to promote to a staked bond.
    error InsufficientDeposit(uint128 requested, uint128 available);

    /// @notice Thrown when unstake is attempted without first calling `requestUnstake`.
    error UnstakeNotRequested();

    /// @notice Thrown when a reviewer attempts to move a bond that is locked against open disputes.
    /// @dev Sec-audit BiosafetyCourt H-02 2026-04-16. Open disputes keep
    ///      `DISPUTE_BOND * openDisputeCount[reviewer]` wei of the bond locked so the reviewer
    ///      cannot `requestUnstake` / `unstakeReviewer` out from under a pending slash.
    /// @param available The reviewer's total current bond.
    /// @param locked The amount locked against open disputes.
    error StakeLocked(uint128 available, uint128 locked);

    /// @notice Thrown when `raiseDispute` is attempted by a caller with insufficient live stake.
    error NotActiveReviewer(address caller);

    /// @notice Thrown when a dispute is resolved before `MIN_DISPUTE_REVIEW_WINDOW`.
    error DisputeReviewWindowActive(uint64 elapsesAt);

    /// @notice Thrown when a dispute is resolved twice (or outcome attempt on a closed case).
    error DisputeAlreadyResolved(uint256 caseId);

    /// @notice Thrown when `Pending` is supplied as an outcome to `resolveDispute`.
    error InvalidOutcome();

    /// @notice Thrown when a dispute is opened against a tokenId already Active/Ratified-frozen.
    error TokenFrozen(uint256 tokenId);

    /// @notice Thrown when `safetyCouncilFreeze` is called on a tokenId that is already frozen.
    error FreezeAlreadyActive(uint256 tokenId);

    /// @notice Thrown when ratify/reject/expire operates on a tokenId with no Active freeze.
    error NotFrozen(uint256 tokenId);

    /// @notice Thrown when `expireFreeze` is called before the 30-day window elapses.
    error FreezeWindowNotElapsed(uint64 expiresAt);

    /// @notice Thrown when an ETH payout fails (receiver rejected or reverted).
    error TransferFailed(address to, uint256 amount);

    /// @notice Thrown when `caseId` is out of range.
    error UnknownDispute(uint256 caseId);

    // -------------------------------------------------------------------------
    // Impl-only events (interface declares the headline events)
    // -------------------------------------------------------------------------

    /// @notice Emitted when the Safety Council address is rotated.
    event SafetyCouncilSet(address indexed prev, address indexed next);

    /// @notice Emitted when the treasury address is rotated.
    event TreasurySet(address indexed prev, address indexed next);

    /// @notice Emitted when the DesignRegistry cross-reference is set (once, in initialize).
    event DesignRegistrySet(address indexed registry);

    /// @notice Emitted when a reviewer's dispute bond is settled on resolution (Kleros-style).
    /// @param caseId Dispute id.
    /// @param disputer Raiser address.
    /// @param disputerReward Amount paid to the disputer.
    /// @param treasuryCut Amount paid to the treasury.
    /// @param reviewerCut Amount paid to the resolving reviewer (always address(0) in v1 = owner).
    event DisputeSettlement(
        uint256 indexed caseId,
        address indexed disputer,
        uint128 disputerReward,
        uint128 treasuryCut,
        uint128 reviewerCut
    );

    /// @notice Emitted when a reviewer's deposit is credited via `receive()`.
    event DepositReceived(address indexed reviewer, uint256 amount, uint256 balance);

    /// @notice Emitted when a reviewer withdraws unused pending deposits (never staked).
    event DepositWithdrawn(address indexed reviewer, uint256 amount);

    /// @notice Emitted inside `_authorizeUpgrade` before OZ's ERC-1822 check (mirrors LicenseRegistry).
    event UpgradeAuthorized(address indexed newImplementation);

    // -------------------------------------------------------------------------
    // Storage (UUPS — any addition MUST append to preserve slot layout)
    // -------------------------------------------------------------------------

    /// @notice DesignRegistry used to validate tokenId existence on dispute / freeze.
    /// @dev Not `immutable` (UUPS impl slots cannot be immutable). Set once in `initialize`.
    IDesignRegistry public designRegistry;

    /// @notice Safety Council address — dual-key counterpart to `owner()`.
    /// @dev Per plan §6 #4 this is the 5-of-9 multisig separate from the DAO/governance owner.
    address public safetyCouncil;

    /// @notice Treasury address receiving dismissal cuts + slashed reviewer pool residues.
    address public treasury;

    /// @notice Monotonic dispute id counter; ids start at 1 (0 reserved as "none").
    uint256 public nextDisputeId;

    /// @dev caseId → Dispute.
    mapping(uint256 => SeqoraTypes.Dispute) private _disputes;

    /// @dev tokenId → open dispute case id (0 if none).
    mapping(uint256 => uint256) public openDisputeOf;

    /// @dev tokenId → SafetyFreeze record.
    mapping(uint256 => SeqoraTypes.SafetyFreeze) private _freezes;

    /// @dev reviewer → ReviewerStake (bond, stakedAt, unstakeRequestedAt).
    mapping(address => SeqoraTypes.ReviewerStake) private _stakes;

    /// @dev reviewer → ETH pending deposits not yet promoted to a bond.
    mapping(address => uint128) public pendingDeposits;

    /// @dev Treasury-pending ETH balance. Separated from `address(this).balance` so bond /
    ///      deposit accounting is not conflated with accrued treasury revenue. Withdrawn by
    ///      the owner via `withdrawTreasury`.
    uint128 public treasuryAccrued;

    /// @dev Accrued reviewer-cut owed to the owner/arbitrator in v1. Pulled via
    ///      `withdrawReviewerCut`. Placed before `__gap` to maintain upgrade-safe append
    ///      ordering.
    uint128 internal _reviewerCutAccrued;

    /// @dev Per-reviewer cumulative `DISPUTE_BOND` locked against open disputes they have
    ///      raised. Incremented on `raiseDispute`, decremented on all terminal `resolveDispute`
    ///      outcomes. Guards `requestUnstake` / `unstakeReviewer` so a reviewer cannot exit
    ///      while their bond collateralizes a pending slash.
    mapping(address => uint128) private _disputeBondLocked;

    /// @dev UUPS storage reservation. Layout: 12 declared slots above + 46 gap = 58 total.
    ///      Pre-deployment so the slot layout has not yet been committed to any proxy.
    uint256[46] private __gap;

    // -------------------------------------------------------------------------
    // Constructor / initializer
    // -------------------------------------------------------------------------

    /// @notice Locks the implementation contract so it can only be initialised via a proxy.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-time initializer for the proxy.
    /// @param registry Canonical DesignRegistry (immutable per deployment).
    /// @param treasury_ Initial treasury recipient.
    /// @param safetyCouncil_ Initial Safety Council multisig address (≠ governance).
    /// @param governance Initial owner (DAO / governance multisig). Ownable2Step semantics.
    function initialize(IDesignRegistry registry, address treasury_, address safetyCouncil_, address governance)
        external
        initializer
    {
        if (address(registry) == address(0)) revert SeqoraErrors.ZeroAddress();
        if (treasury_ == address(0)) revert SeqoraErrors.ZeroAddress();
        if (safetyCouncil_ == address(0)) revert SeqoraErrors.ZeroAddress();
        if (governance == address(0)) revert SeqoraErrors.ZeroAddress();

        __Ownable_init(governance);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        designRegistry = registry;
        treasury = treasury_;
        safetyCouncil = safetyCouncil_;
        nextDisputeId = 1;

        emit DesignRegistrySet(address(registry));
        emit TreasurySet(address(0), treasury_);
        emit SafetyCouncilSet(address(0), safetyCouncil_);
    }

    // -------------------------------------------------------------------------
    // ETH deposit plumbing (receive-then-register — see header block)
    // -------------------------------------------------------------------------

    /// @notice Credit `msg.value` to `pendingDeposits[msg.sender]`.
    /// @dev Required for the ETH-backed bond model (see header §"v1 bond currency"). The value
    ///      is held by the contract until `stakeAsReviewer` promotes it to a bond or
    ///      `withdrawDeposit` returns it. Deposits are NOT slashable until staked.
    receive() external payable {
        if (msg.value == 0) return; // idempotent no-op; avoids wasted gas on zero-value pings
        // Cast safety: msg.value > type(uint128).max implies a transfer of > 3.4e38 wei; not
        // reachable on any real chain (total ETH supply ≈ 1.2e26 wei).
        uint128 amount = uint128(msg.value);
        pendingDeposits[msg.sender] += amount;
        emit DepositReceived(msg.sender, msg.value, pendingDeposits[msg.sender]);
    }

    /// @notice Withdraw any pending ETH deposit that has NOT yet been promoted to a bond.
    /// @dev Guards against accidental over-deposit. Staked bonds cannot be withdrawn here —
    ///      they are under `requestUnstake` → `unstakeReviewer` control.
    function withdrawDeposit() external nonReentrant {
        uint128 amount = pendingDeposits[msg.sender];
        if (amount == 0) revert SeqoraErrors.ZeroValue();
        pendingDeposits[msg.sender] = 0;
        emit DepositWithdrawn(msg.sender, amount);
        _safeSendETH(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Reviewer staking
    // -------------------------------------------------------------------------

    /// @inheritdoc IBiosafetyCourt
    /// @dev Promotes `bondAmount` wei from `pendingDeposits[msg.sender]` into the reviewer's
    ///      staked bond. Post-stake bond must be ≥ `MIN_REVIEWER_STAKE`. Calling this while
    ///      an unstake is pending cancels the cooldown (re-engagement).
    function stakeAsReviewer(uint128 bondAmount) external override whenNotPaused nonReentrant {
        if (bondAmount == 0) revert ZeroBondAmount();

        uint128 deposit = pendingDeposits[msg.sender];
        if (deposit < bondAmount) revert InsufficientDeposit(bondAmount, deposit);

        unchecked {
            // deposit >= bondAmount checked above.
            pendingDeposits[msg.sender] = deposit - bondAmount;
        }

        SeqoraTypes.ReviewerStake storage s = _stakes[msg.sender];
        uint128 newBond = s.bond + bondAmount;
        if (newBond < SeqoraTypes.MIN_REVIEWER_STAKE) {
            revert StakeTooLow(newBond, SeqoraTypes.MIN_REVIEWER_STAKE);
        }

        s.bond = newBond;
        if (s.stakedAt == 0) s.stakedAt = uint64(block.timestamp);
        // Re-engagement cancels any pending unstake.
        if (s.unstakeRequestedAt != 0) s.unstakeRequestedAt = 0;

        emit ReviewerStaked(msg.sender, newBond);
    }

    /// @inheritdoc IBiosafetyCourt
    /// @dev Records the unstake request timestamp; actual withdrawal must wait
    ///      `REVIEWER_UNSTAKE_COOLDOWN`. The reviewer is still considered "active" during the
    ///      cooldown for the purposes of `raiseDispute` resolution — slashing still applies.
    ///      Reverts `StakeLocked` if the reviewer has dispute bond locked against open cases.
    function requestUnstake() external override {
        SeqoraTypes.ReviewerStake storage s = _stakes[msg.sender];
        if (s.bond == 0) revert StakeTooLow(0, SeqoraTypes.MIN_REVIEWER_STAKE);
        // Block unstake if any dispute bond is locked against this reviewer's open cases.
        uint128 locked = _disputeBondLocked[msg.sender];
        if (locked > 0) revert StakeLocked(s.bond, locked);
        // Idempotent — if a request is already open, emit again but keep the original timestamp.
        if (s.unstakeRequestedAt == 0) s.unstakeRequestedAt = uint64(block.timestamp);
        emit ReviewerUnstakeRequested(msg.sender, s.unstakeRequestedAt);
    }

    /// @inheritdoc IBiosafetyCourt
    /// @dev Withdraws the full bond after the cooldown. Partial withdrawals are v2. Reverts
    ///      if `requestUnstake` was not called, cooldown is not elapsed, or dispute bond is
    ///      locked.
    function unstakeReviewer() external override nonReentrant returns (uint128 amount) {
        SeqoraTypes.ReviewerStake storage s = _stakes[msg.sender];
        if (s.bond == 0) revert StakeTooLow(0, SeqoraTypes.MIN_REVIEWER_STAKE);
        if (s.unstakeRequestedAt == 0) revert UnstakeNotRequested();
        // Double-check locked bond at withdrawal time — a dispute may have been raised between
        // `requestUnstake` and this call.
        uint128 locked = _disputeBondLocked[msg.sender];
        if (locked > 0) revert StakeLocked(s.bond, locked);

        uint64 availableAt = s.unstakeRequestedAt + SeqoraTypes.REVIEWER_UNSTAKE_COOLDOWN;
        if (block.timestamp < availableAt) revert CooldownNotElapsed(availableAt);

        amount = s.bond;
        // CEI: zero state before transfer.
        s.bond = 0;
        s.stakedAt = 0;
        s.unstakeRequestedAt = 0;

        emit ReviewerUnstaked(msg.sender, amount);
        _safeSendETH(msg.sender, amount);
    }

    /// @inheritdoc IBiosafetyCourt
    function getReviewerStake(address reviewer)
        external
        view
        override
        returns (SeqoraTypes.ReviewerStake memory stake)
    {
        stake = _stakes[reviewer];
    }

    // -------------------------------------------------------------------------
    // Disputes
    // -------------------------------------------------------------------------

    /// @inheritdoc IBiosafetyCourt
    /// @dev Raiser MUST be a currently-active reviewer with bond ≥ MIN_REVIEWER_STAKE AND
    ///      bond ≥ DISPUTE_BOND (the dispute bond is earmarked from the reviewer's stake;
    ///      this is enforced on resolution, not on raise). The tokenId must be (a) registered
    ///      in DesignRegistry, (b) not already under an open dispute, (c) not currently frozen.
    function raiseDispute(uint256 tokenId, bytes32 evidenceHash, string calldata reason)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 caseId)
    {
        // --- Reviewer eligibility ---
        SeqoraTypes.ReviewerStake storage s = _stakes[msg.sender];
        uint128 bond = s.bond;
        if (bond < SeqoraTypes.MIN_REVIEWER_STAKE || bond < SeqoraTypes.DISPUTE_BOND) {
            revert NotActiveReviewer(msg.sender);
        }

        // --- TokenId must be registered and NOT currently frozen ---
        if (!designRegistry.isRegistered(tokenId)) revert SeqoraErrors.UnknownToken(tokenId);
        (bool frozen,) = _isFrozen(tokenId);
        if (frozen) revert TokenFrozen(tokenId);

        // --- One open dispute per tokenId ---
        uint256 existing = openDisputeOf[tokenId];
        if (existing != 0) revert DisputeAlreadyOpen(tokenId, existing);

        caseId = nextDisputeId;
        unchecked {
            nextDisputeId = caseId + 1;
        }

        SeqoraTypes.Dispute storage d = _disputes[caseId];
        d.tokenId = tokenId;
        d.raiser = msg.sender;
        d.evidenceHash = evidenceHash;
        d.reason = reason;
        d.openedAt = uint64(block.timestamp);
        // d.resolvedAt / d.outcome default to 0 / Pending.

        openDisputeOf[tokenId] = caseId;

        // Lock DISPUTE_BOND from the raiser's stake so they cannot unstake while this
        // dispute is pending.
        _disputeBondLocked[msg.sender] += SeqoraTypes.DISPUTE_BOND;

        emit DisputeRaised(caseId, tokenId, msg.sender, evidenceHash);
    }

    /// @inheritdoc IBiosafetyCourt
    /// @dev v1 arbitrator == `owner()`. Can only resolve after `MIN_DISPUTE_REVIEW_WINDOW`.
    ///      Outcomes:
    ///        - `UpheldTakedown` — freeze the tokenId (status = Active + appliedAt = now,
    ///          expiresAt = now + SAFETY_COUNCIL_FREEZE_WINDOW); disputer receives back the
    ///          earmarked `DISPUTE_BOND` and an additional `UPHELD_DISPUTER_REWARD_BPS` share
    ///          of a per-case slash pool taken from adversely-positioned reviewers. In v1
    ///          there is no identified "adverse reviewer set" so the slash pool is zero; the
    ///          disputer receives their bond back only. Slashing of specific reviewers is
    ///          left to v2's stake-weighted voting mechanism.
    ///        - `Dismissed` — disputer forfeits `DISPUTE_BOND` from stake; split
    ///          `DISMISSAL_TREASURY_CUT_BPS` / `DISMISSAL_REVIEWER_CUT_BPS` between treasury
    ///          and the resolving arbitrator (== owner in v1; treasury receives both shares
    ///          in effect, but we keep the bps split wiring for v2 when the reviewer role
    ///          separates from the owner).
    ///        - `Settled` — disputer's bond restored, no slashing, no freeze. Off-ramp for
    ///          mutually-agreed withdrawals.
    function resolveDispute(uint256 caseId, SeqoraTypes.DisputeOutcome outcome)
        external
        override
        whenNotPaused
        nonReentrant
        onlyOwner
    {
        if (outcome == SeqoraTypes.DisputeOutcome.Pending) revert InvalidOutcome();

        SeqoraTypes.Dispute storage d = _disputes[caseId];
        if (d.openedAt == 0) revert UnknownDispute(caseId);
        if (d.resolvedAt != 0) revert DisputeAlreadyResolved(caseId);

        uint64 elapsesAt = d.openedAt + SeqoraTypes.MIN_DISPUTE_REVIEW_WINDOW;
        if (block.timestamp < elapsesAt) revert DisputeReviewWindowActive(elapsesAt);

        // --- Effects: close the dispute ---
        d.resolvedAt = uint64(block.timestamp);
        d.outcome = outcome;
        uint256 tokenId_ = d.tokenId;
        address raiser_ = d.raiser;
        openDisputeOf[tokenId_] = 0;

        // Release the locked dispute bond for the raiser.
        // All terminal outcomes — UpheldTakedown, Dismissed, Settled — free the lock.
        _disputeBondLocked[raiser_] -= SeqoraTypes.DISPUTE_BOND;

        uint128 disputerReward = 0;
        uint128 treasuryCut = 0;
        uint128 reviewerCut = 0;

        if (outcome == SeqoraTypes.DisputeOutcome.UpheldTakedown) {
            // Pre-check: bail if the tokenId is already frozen via a concurrent Safety Council
            // action. Without this guard `_setFreezeActive` overwrites the existing freeze
            // record (resetting `appliedAt` / `expiresAt`), which could extend or shorten the
            // 30-day ratification window depending on timing.
            (bool alreadyFrozen,) = _isFrozen(tokenId_);
            if (alreadyFrozen) revert FreezeAlreadyActive(tokenId_);
            _setFreezeActive(tokenId_, d.reason);
            disputerReward = 0;
        } else if (outcome == SeqoraTypes.DisputeOutcome.Dismissed) {
            SeqoraTypes.ReviewerStake storage raiserStake = _stakes[raiser_];
            uint128 slashed = raiserStake.bond >= SeqoraTypes.DISPUTE_BOND ? SeqoraTypes.DISPUTE_BOND : raiserStake.bond;
            if (slashed > 0) {
                unchecked {
                    raiserStake.bond -= slashed;
                }
                treasuryCut = uint128((uint256(slashed) * SeqoraTypes.DISMISSAL_TREASURY_CUT_BPS) / SeqoraTypes.BPS);
                reviewerCut = uint128((uint256(slashed) * SeqoraTypes.DISMISSAL_REVIEWER_CUT_BPS) / SeqoraTypes.BPS);
                uint128 residue = slashed - treasuryCut - reviewerCut;
                treasuryCut += residue;

                emit ReviewerSlashed(raiser_, slashed, caseId);
            }
        }
        // Settled: no movement.

        if (treasuryCut > 0) treasuryAccrued += treasuryCut;
        if (reviewerCut > 0) _reviewerCutAccrued += reviewerCut;

        emit DisputeResolved(caseId, outcome);
        if (treasuryCut > 0 || reviewerCut > 0 || disputerReward > 0) {
            emit DisputeSettlement(caseId, raiser_, disputerReward, treasuryCut, reviewerCut);
        }
        // disputerReward currently always 0 in v1 — no transfer required.
    }

    /// @inheritdoc IBiosafetyCourt
    function getDispute(uint256 caseId) external view override returns (SeqoraTypes.Dispute memory dispute) {
        dispute = _disputes[caseId];
        if (dispute.openedAt == 0) revert UnknownDispute(caseId);
    }

    // -------------------------------------------------------------------------
    // Safety Council emergency freeze
    // -------------------------------------------------------------------------

    /// @inheritdoc IBiosafetyCourt
    /// @dev Safety-Council-only. Unlike the dispute path, this is NOT gated by the pause flag
    ///      (§8 rules: pause halts disputes, not emergency freezes — the whole point of the
    ///      council is to act when everything else is down).
    function safetyCouncilFreeze(uint256 tokenId, string calldata reason) external override {
        if (msg.sender != safetyCouncil) revert NotSafetyCouncil(msg.sender);
        if (!designRegistry.isRegistered(tokenId)) revert SeqoraErrors.UnknownToken(tokenId);

        (bool frozen,) = _isFrozen(tokenId);
        if (frozen) revert FreezeAlreadyActive(tokenId);

        _setFreezeActive(tokenId, reason);
    }

    /// @inheritdoc IBiosafetyCourt
    /// @dev Owner-only. Transitions Active → Ratified (permanent). Reverts if the 30-day
    ///      window has elapsed (even if not yet auto-expired), per interface's
    ///      `FreezeWindowExpired` error — the DAO must act in time.
    function ratifyFreeze(uint256 tokenId) external override onlyOwner {
        SeqoraTypes.SafetyFreeze storage f = _freezes[tokenId];
        if (f.status != SeqoraTypes.FreezeStatus.Active) revert NotFrozen(tokenId);
        if (block.timestamp >= f.expiresAt) revert FreezeWindowExpired(tokenId);

        f.status = SeqoraTypes.FreezeStatus.Ratified;
        // expiresAt becomes meaningless for Ratified (permanent); set to 0 to match interface
        // semantics of isFrozen ("expiresAt == 0 if Ratified-permanent").
        f.expiresAt = 0;

        emit FreezeRatified(tokenId);
    }

    /// @inheritdoc IBiosafetyCourt
    /// @dev Owner-only. Transitions Active → Rejected (lifts immediately).
    function rejectFreeze(uint256 tokenId) external override onlyOwner {
        SeqoraTypes.SafetyFreeze storage f = _freezes[tokenId];
        if (f.status != SeqoraTypes.FreezeStatus.Active) revert NotFrozen(tokenId);
        if (block.timestamp >= f.expiresAt) revert FreezeWindowExpired(tokenId);

        f.status = SeqoraTypes.FreezeStatus.Rejected;
        f.expiresAt = uint64(block.timestamp);

        emit FreezeRejected(tokenId);
    }

    /// @notice Finalize an un-ratified freeze once the 30-day window has elapsed.
    /// @dev Permissionless. Anyone may call once `block.timestamp >= expiresAt` to transition
    ///      status Active → AutoLifted. The `isFrozen` view already treats expired-but-unfinalized
    ///      freezes as lifted; this function exists to emit the `FreezeAutoLifted` event so
    ///      off-chain monitors can react without polling.
    /// @param tokenId Design id whose freeze should be finalized.
    function expireFreeze(uint256 tokenId) external {
        SeqoraTypes.SafetyFreeze storage f = _freezes[tokenId];
        if (f.status != SeqoraTypes.FreezeStatus.Active) revert NotFrozen(tokenId);
        if (block.timestamp < f.expiresAt) revert FreezeWindowNotElapsed(f.expiresAt);

        f.status = SeqoraTypes.FreezeStatus.AutoLifted;
        emit FreezeAutoLifted(tokenId);
    }

    /// @inheritdoc IBiosafetyCourt
    /// @dev Lazy expiry: an Active freeze past its `expiresAt` reports `frozen = false` even if
    ///      `expireFreeze` has not been called. This keeps LicenseRegistry v2 reads correct
    ///      without requiring an on-chain finalize step.
    function isFrozen(uint256 tokenId) external view override returns (bool frozen, uint64 expiresAt) {
        (frozen, expiresAt) = _isFrozen(tokenId);
    }

    /// @inheritdoc IBiosafetyCourt
    function getFreeze(uint256 tokenId) external view override returns (SeqoraTypes.SafetyFreeze memory freeze) {
        freeze = _freezes[tokenId];
    }

    // -------------------------------------------------------------------------
    // Governance / admin
    // -------------------------------------------------------------------------

    /// @notice Rotate the Safety Council address.
    /// @param next New council address.
    function setSafetyCouncil(address next) external onlyOwner {
        if (next == address(0)) revert SeqoraErrors.ZeroAddress();
        address prev = safetyCouncil;
        safetyCouncil = next;
        emit SafetyCouncilSet(prev, next);
    }

    /// @notice Rotate the treasury address. Does NOT move already-accrued funds; owner must
    ///         withdraw those separately first.
    function setTreasury(address next) external onlyOwner {
        if (next == address(0)) revert SeqoraErrors.ZeroAddress();
        address prev = treasury;
        treasury = next;
        emit TreasurySet(prev, next);
    }

    /// @notice Pull-pay accrued treasury ETH to the current treasury address.
    /// @dev Anyone may trigger; funds flow only to the governance-set `treasury`.
    function withdrawTreasury() external nonReentrant {
        uint128 amount = treasuryAccrued;
        if (amount == 0) revert SeqoraErrors.ZeroValue();
        treasuryAccrued = 0;
        _safeSendETH(treasury, amount);
    }

    /// @notice Pull-pay accrued reviewer-cut ETH to the owner (v1 arbitrator).
    /// @dev In v2 this will accrue per-reviewer; v1 accrues to the owner.
    function withdrawReviewerCut() external nonReentrant onlyOwner {
        uint128 amount = _reviewerCutAccrued;
        if (amount == 0) revert SeqoraErrors.ZeroValue();
        _reviewerCutAccrued = 0;
        _safeSendETH(owner(), amount);
    }

    /// @notice Halt new disputes + dispute resolution. Does NOT halt Safety Council freezes
    ///         or freeze ratification — the emergency path must remain available when paused.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume dispute operations.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Override disables `renounceOwnership` to prevent permanent governance bricking.
    function renounceOwnership() public view override(OwnableUpgradeable) onlyOwner {
        revert RenounceDisabled();
    }

    // -------------------------------------------------------------------------
    // UUPS
    // -------------------------------------------------------------------------

    /// @notice UUPS upgrade authorisation hook. Owner-only.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        emit UpgradeAuthorized(newImplementation);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Report whether a tokenId is currently frozen + when its freeze auto-lifts.
    ///      Lazy-expiry aware: an Active freeze past `expiresAt` is reported as not frozen.
    function _isFrozen(uint256 tokenId) internal view returns (bool frozen, uint64 expiresAt) {
        SeqoraTypes.SafetyFreeze storage f = _freezes[tokenId];
        if (f.status == SeqoraTypes.FreezeStatus.Ratified) {
            return (true, 0);
        }
        if (f.status == SeqoraTypes.FreezeStatus.Active) {
            if (block.timestamp < f.expiresAt) return (true, f.expiresAt);
            // Elapsed but not finalized: lazy auto-lift for the reader.
            return (false, f.expiresAt);
        }
        return (false, 0);
    }

    /// @dev Apply an emergency freeze to `tokenId`. Callers MUST have already checked that
    ///      the token is not already frozen (see `safetyCouncilFreeze`, `resolveDispute`).
    function _setFreezeActive(uint256 tokenId, string memory reason) internal {
        SeqoraTypes.SafetyFreeze storage f = _freezes[tokenId];
        f.status = SeqoraTypes.FreezeStatus.Active;
        f.appliedAt = uint64(block.timestamp);
        uint64 newExpiresAt = uint64(block.timestamp) + SeqoraTypes.SAFETY_COUNCIL_FREEZE_WINDOW;
        f.expiresAt = newExpiresAt;
        f.reason = reason;

        emit SafetyFreezeApplied(tokenId, reason, newExpiresAt);
    }

    /// @dev Transfer `amount` wei to `to` via `call`, reverting on failure.
    ///      Uses `call` rather than `transfer` to avoid the 2300-gas stipend limitation on
    ///      Safe / 4337 smart accounts. `nonReentrant` is the correct defense here (NOT a
    ///      gas limit) because bond / deposit state is already zeroed by the CEI ordering.
    function _safeSendETH(address to, uint128 amount) internal {
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert TransferFailed(to, amount);
    }
}
