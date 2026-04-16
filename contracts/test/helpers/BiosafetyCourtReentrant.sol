// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BiosafetyCourt } from "../../src/BiosafetyCourt.sol";
import { SeqoraTypes } from "../../src/libraries/SeqoraTypes.sol";

/// @notice Malicious reviewer contract whose `receive()` re-enters the BiosafetyCourt on ETH
///         egress. Used to prove `nonReentrant` + CEI block cross-function reentrancy into
///         `unstakeReviewer`, `withdrawDeposit`, `withdrawTreasury`, and `withdrawReviewerCut`.
/// @dev The contract can be armed for a specific target function; the receive callback tries that
///      target exactly once. The expected behavior is:
///        - If target is ANY state-mutating path on the court, the re-entry reverts with
///          `ReentrancyGuardReentrantCall`. The outer call then surfaces `TransferFailed` from
///          `_safeSendETH`.
///        - If armed but target is a view-only getter (e.g. `isFrozen`), the re-entry succeeds
///          silently — we use this to confirm the attacker can observe state but not mutate it.
///      Storage is intentionally minimal — behavior is controlled by `mode`.
contract BiosafetyCourtReentrant {
    enum Mode {
        Off, // receive does nothing
        Unstake, // receive → unstakeReviewer
        WithdrawDeposit, // receive → withdrawDeposit
        WithdrawTreasury, // receive → withdrawTreasury
        WithdrawReviewerCut, // receive → withdrawReviewerCut
        RaiseDispute, // receive → raiseDispute
        ResolveDispute, // receive → resolveDispute
        StakeAsReviewer // receive → stakeAsReviewer
    }

    BiosafetyCourt public immutable COURT;
    Mode public mode;
    uint256 public tokenId;
    uint256 public caseId;
    uint128 public bondAmount;

    // Re-entry attempt bookkeeping so tests can prove the attacker's callback was actually
    // invoked (otherwise a silently-skipped receive would pass the test vacuously).
    uint256 public reenterAttempts;
    bytes public lastReentryRevertData;

    constructor(BiosafetyCourt court_) {
        COURT = court_;
    }

    // -------------------------------------------------------------------------
    // Arming
    // -------------------------------------------------------------------------

    function armUnstake() external {
        mode = Mode.Unstake;
    }

    function armWithdrawDeposit() external {
        mode = Mode.WithdrawDeposit;
    }

    function armWithdrawTreasury() external {
        mode = Mode.WithdrawTreasury;
    }

    function armWithdrawReviewerCut() external {
        mode = Mode.WithdrawReviewerCut;
    }

    function armRaiseDispute(uint256 tokenId_) external {
        mode = Mode.RaiseDispute;
        tokenId = tokenId_;
    }

    function armResolveDispute(uint256 caseId_) external {
        mode = Mode.ResolveDispute;
        caseId = caseId_;
    }

    function armStake(uint128 bondAmount_) external {
        mode = Mode.StakeAsReviewer;
        bondAmount = bondAmount_;
    }

    function disarm() external {
        mode = Mode.Off;
    }

    // -------------------------------------------------------------------------
    // Proxy methods so the attacker can interact with the court as a reviewer.
    // -------------------------------------------------------------------------

    /// @notice Deposit ETH into the court from this contract. Attacker must be funded.
    function depositToCourt(uint256 amount) external {
        (bool ok,) = address(COURT).call{ value: amount }("");
        require(ok, "deposit failed");
    }

    /// @notice Call `stakeAsReviewer` from this contract so the attacker's stake is keyed to
    ///         `address(this)` (which is also what `msg.sender` inside `receive()` will be).
    function stakeAsReviewer(uint128 bondAmount_) external {
        COURT.stakeAsReviewer(bondAmount_);
    }

    /// @notice Call `requestUnstake`.
    function requestUnstake() external {
        COURT.requestUnstake();
    }

    /// @notice Call `unstakeReviewer` — this triggers ETH send back, which fires `receive()`.
    function unstakeReviewer() external returns (uint128) {
        return COURT.unstakeReviewer();
    }

    /// @notice Call `withdrawDeposit`.
    function withdrawDeposit() external {
        COURT.withdrawDeposit();
    }

    /// @notice Call `raiseDispute` from this contract.
    function raiseDispute(uint256 tokenId_, bytes32 evidenceHash, string calldata reason) external returns (uint256) {
        return COURT.raiseDispute(tokenId_, evidenceHash, reason);
    }

    // -------------------------------------------------------------------------
    // Funds receiver — the reentry vector.
    // -------------------------------------------------------------------------

    receive() external payable {
        if (mode == Mode.Off) return;

        reenterAttempts++;
        Mode m = mode;
        // Single-shot: disarm before re-entering so the nested call's inner receive() does NOT
        // recurse infinitely. Tests care about the outer call's revert, not depth.
        mode = Mode.Off;

        if (m == Mode.Unstake) {
            try COURT.unstakeReviewer() returns (uint128) { }
            catch (bytes memory reason) {
                lastReentryRevertData = reason;
            }
        } else if (m == Mode.WithdrawDeposit) {
            try COURT.withdrawDeposit() { }
            catch (bytes memory reason) {
                lastReentryRevertData = reason;
            }
        } else if (m == Mode.WithdrawTreasury) {
            try COURT.withdrawTreasury() { }
            catch (bytes memory reason) {
                lastReentryRevertData = reason;
            }
        } else if (m == Mode.WithdrawReviewerCut) {
            try COURT.withdrawReviewerCut() { }
            catch (bytes memory reason) {
                lastReentryRevertData = reason;
            }
        } else if (m == Mode.RaiseDispute) {
            try COURT.raiseDispute(tokenId, keccak256("reentry"), "reentry") returns (uint256) { }
            catch (bytes memory reason) {
                lastReentryRevertData = reason;
            }
        } else if (m == Mode.ResolveDispute) {
            try COURT.resolveDispute(caseId, SeqoraTypes.DisputeOutcome.Dismissed) { }
            catch (bytes memory reason) {
                lastReentryRevertData = reason;
            }
        } else if (m == Mode.StakeAsReviewer) {
            try COURT.stakeAsReviewer(bondAmount) { }
            catch (bytes memory reason) {
                lastReentryRevertData = reason;
            }
        }
    }

    /// @notice Allow ERC20-like 721/1155 hooks to resolve in tests that incidentally transfer
    ///         tokens to this contract (not used in BiosafetyCourt tests, but cheap insurance).
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
}

/// @notice A receiver that always rejects ETH (no receive/fallback). Used to force `_safeSendETH`
///         to bubble up `TransferFailed` for coverage of that error path.
contract RejectingReceiver {
    // Deliberately no receive() and no fallback() — any ETH transfer reverts.

    }
