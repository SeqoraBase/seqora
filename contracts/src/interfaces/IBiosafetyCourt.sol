// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SeqoraTypes } from "../libraries/SeqoraTypes.sol";

/// @title IBiosafetyCourt
/// @notice Reviewer staking + dispute arbitration + Safety Council emergency takedown.
/// @dev Per plan §4 + §6 #4: Kleros-style slashable reviewer bonds, plus a 5-of-9 Safety
///      Council multisig that can freeze a tokenId for 48h. Freezes must be ratified by the
///      DAO within 30 days or they auto-lift. UUPS-upgradable.
interface IBiosafetyCourt {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a reviewer posts (or tops up) a stake.
    /// @param reviewer Address that staked.
    /// @param bond Total bond after this call.
    event ReviewerStaked(address indexed reviewer, uint128 bond);

    /// @notice Emitted when a reviewer requests an unstake (cooldown begins).
    /// @param reviewer Address that requested unstake.
    /// @param unstakeRequestedAt Timestamp the cooldown started.
    event ReviewerUnstakeRequested(address indexed reviewer, uint64 unstakeRequestedAt);

    /// @notice Emitted when a reviewer's bond is returned after cooldown.
    /// @param reviewer Address that withdrew.
    /// @param amount Amount returned.
    event ReviewerUnstaked(address indexed reviewer, uint128 amount);

    /// @notice Emitted when a reviewer's bond is slashed by an upheld dispute.
    /// @param reviewer Address slashed.
    /// @param amount Amount slashed.
    /// @param caseId Dispute case responsible.
    event ReviewerSlashed(address indexed reviewer, uint128 amount, uint256 indexed caseId);

    /// @notice Emitted when a dispute is opened.
    /// @param caseId New dispute id.
    /// @param tokenId Design under dispute.
    /// @param raiser Reviewer who opened the case.
    /// @param evidenceHash Hash of off-chain evidence bundle.
    event DisputeRaised(uint256 indexed caseId, uint256 indexed tokenId, address indexed raiser, bytes32 evidenceHash);

    /// @notice Emitted when a dispute is resolved.
    /// @param caseId Dispute id.
    /// @param outcome Final outcome.
    event DisputeResolved(uint256 indexed caseId, SeqoraTypes.DisputeOutcome outcome);

    /// @notice Emitted when the Safety Council applies a 48h emergency freeze.
    /// @param tokenId Design frozen.
    /// @param reason Free-form short reason.
    /// @param expiresAt Timestamp the freeze auto-lifts if not ratified.
    event SafetyFreezeApplied(uint256 indexed tokenId, string reason, uint64 expiresAt);

    /// @notice Emitted when the DAO ratifies a freeze.
    /// @param tokenId Design id.
    event FreezeRatified(uint256 indexed tokenId);

    /// @notice Emitted when the DAO rejects a freeze.
    /// @param tokenId Design id.
    event FreezeRejected(uint256 indexed tokenId);

    /// @notice Emitted when a freeze auto-lifts because the 30-day window passed without ratification.
    /// @param tokenId Design id.
    event FreezeAutoLifted(uint256 indexed tokenId);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a reviewer's bond is below the minimum required.
    /// @param required Minimum bond.
    /// @param supplied Bond actually supplied.
    error InsufficientBond(uint128 required, uint128 supplied);

    /// @notice Thrown when an unstake withdrawal is attempted before the cooldown elapses.
    /// @param availableAt Timestamp at which withdrawal becomes possible.
    error CooldownNotElapsed(uint64 availableAt);

    /// @notice Thrown when a dispute is opened against a tokenId that already has an open case.
    /// @param tokenId Design id.
    /// @param existingCaseId The dispute already open.
    error DisputeAlreadyOpen(uint256 tokenId, uint256 existingCaseId);

    /// @notice Thrown when caller is not a Safety Council member for a council-only action.
    /// @param caller msg.sender.
    error NotSafetyCouncil(address caller);

    /// @notice Thrown when ratify/reject is called after the 30-day freeze window has passed.
    /// @param tokenId Design id.
    error FreezeWindowExpired(uint256 tokenId);

    // -------------------------------------------------------------------------
    // Reviewer staking
    // -------------------------------------------------------------------------

    /// @notice Stake (or top up) as a biosafety reviewer.
    /// @param bondAmount Additional bond to post.
    function stakeAsReviewer(uint128 bondAmount) external;

    /// @notice Begin the unstake cooldown. Withdrawal must be claimed via `unstakeReviewer` after the cooldown.
    function requestUnstake() external;

    /// @notice Withdraw bond after the cooldown elapses.
    /// @return amount Amount withdrawn.
    function unstakeReviewer() external returns (uint128 amount);

    /// @notice Read a reviewer's current stake state.
    /// @param reviewer Address to query.
    /// @return stake Stored ReviewerStake.
    function getReviewerStake(address reviewer) external view returns (SeqoraTypes.ReviewerStake memory stake);

    // -------------------------------------------------------------------------
    // Disputes
    // -------------------------------------------------------------------------

    /// @notice Open a dispute against a registered design. Requires reviewer stake.
    /// @param tokenId Design id under dispute.
    /// @param evidenceHash Hash of the off-chain evidence bundle.
    /// @param reason Free-form short reason recorded with the case.
    /// @return caseId New dispute id.
    function raiseDispute(uint256 tokenId, bytes32 evidenceHash, string calldata reason)
        external
        returns (uint256 caseId);

    /// @notice Resolve an open dispute. Kleros-style: slashes losing side. Arbitrator-only.
    /// @param caseId Dispute id.
    /// @param outcome Final outcome.
    function resolveDispute(uint256 caseId, SeqoraTypes.DisputeOutcome outcome) external;

    /// @notice Read a dispute case.
    /// @param caseId Dispute id.
    /// @return dispute Stored Dispute struct.
    function getDispute(uint256 caseId) external view returns (SeqoraTypes.Dispute memory dispute);

    // -------------------------------------------------------------------------
    // Safety Council emergency freeze
    // -------------------------------------------------------------------------

    /// @notice Apply a 48h emergency freeze on a tokenId. Safety Council multisig only.
    /// @dev Sets a 30-day auto-lift expiry. DAO must ratify within the 30-day window.
    /// @param tokenId Design id to freeze.
    /// @param reason Free-form short reason.
    function safetyCouncilFreeze(uint256 tokenId, string calldata reason) external;

    /// @notice DAO ratifies an active freeze. Must be called within the 30-day window.
    /// @param tokenId Design id.
    function ratifyFreeze(uint256 tokenId) external;

    /// @notice DAO rejects an active freeze, lifting it immediately. Must be within the 30-day window.
    /// @param tokenId Design id.
    function rejectFreeze(uint256 tokenId) external;

    /// @notice Whether a tokenId is currently frozen and when it auto-lifts.
    /// @param tokenId Design id.
    /// @return frozen True iff currently in Active or Ratified state.
    /// @return expiresAt Timestamp at which the freeze auto-lifts (0 if Ratified-permanent or not frozen).
    function isFrozen(uint256 tokenId) external view returns (bool frozen, uint64 expiresAt);

    /// @notice Read the full freeze record for a tokenId.
    /// @param tokenId Design id.
    /// @return freeze Stored SafetyFreeze struct.
    function getFreeze(uint256 tokenId) external view returns (SeqoraTypes.SafetyFreeze memory freeze);
}
