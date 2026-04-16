// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { BiosafetyCourt } from "../../src/BiosafetyCourt.sol";
import { DesignRegistry } from "../../src/DesignRegistry.sol";
import { SeqoraTypes } from "../../src/libraries/SeqoraTypes.sol";

/// @notice Invariant-test handler for BiosafetyCourt. Bounds fuzzed inputs to a small actor pool
///         and a small tokenId pool so every call lands on a meaningful code path. Uses deterministic
///         `vm.prank`s so `msg.sender` visible to the court is always one of the bounded actors
///         (never the fuzzer's junk address).
/// @dev The central accounting invariant requires that all actors with ETH egress from the court
///      are tracked. This handler uses EOAs for reviewers/disputers and captures:
///        - every staked reviewer (to sum bonds)
///        - every address that has ever deposited (to sum pendingDeposits)
///        - every caseId opened (to walk disputes)
///        - every tokenId under active action (to check freeze states)
contract BiosafetyCourtHandler is CommonBase, StdCheats, StdUtils {
    BiosafetyCourt public immutable court;
    DesignRegistry public immutable designs;
    address public immutable GOVERNANCE;
    address public immutable COUNCIL;

    // -------- Actor bank (EOAs that can receive ETH) --------
    address[] internal _actors;
    mapping(address => bool) internal _isActor;

    // -------- TokenId bank --------
    uint256[] internal _tokenIds;
    mapping(uint256 => bool) internal _isKnownToken;

    // -------- Dispute tracking --------
    uint256[] internal _caseIds;
    mapping(uint256 => bool) internal _isKnownCase;
    uint256 public lastCaseId; // monotonicity tracker

    // -------- Counters / run summary --------
    uint256 public depositAttempts;
    uint256 public stakeAttempts;
    uint256 public stakeSuccesses;
    uint256 public requestUnstakeAttempts;
    uint256 public unstakeAttempts;
    uint256 public unstakeSuccesses;
    uint256 public withdrawDepositAttempts;
    uint256 public withdrawDepositSuccesses;
    uint256 public raiseAttempts;
    uint256 public raiseSuccesses;
    uint256 public resolveAttempts;
    uint256 public resolveSuccesses;
    uint256 public freezeAttempts;
    uint256 public freezeSuccesses;
    uint256 public ratifyAttempts;
    uint256 public rejectAttempts;
    uint256 public expireAttempts;
    uint256 public withdrawTreasuryCalls;
    uint256 public withdrawReviewerCutCalls;
    uint256 public pauseCalls;
    uint256 public unpauseCalls;

    constructor(BiosafetyCourt court_, DesignRegistry designs_, address governance_, address council_) {
        court = court_;
        designs = designs_;
        GOVERNANCE = governance_;
        COUNCIL = council_;

        // Fixed EOA pool — uses low-numbered addresses so they can hold balances and receive
        // ETH without requiring contract code.
        _addActor(address(0xA11CE));
        _addActor(address(0xB0B));
        _addActor(address(0xCA401));
        _addActor(address(0xDA4E));

        // Pre-register a handful of tokenIds so raiseDispute / freeze have valid targets.
        _seedDesign(_actors[0], keccak256("seed-1"));
        _seedDesign(_actors[1], keccak256("seed-2"));
        _seedDesign(_actors[2], keccak256("seed-3"));
    }

    // -------------------------------------------------------------------------
    // View helpers for invariant iteration
    // -------------------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return _actors[i % _actors.length];
    }

    function tokenCount() external view returns (uint256) {
        return _tokenIds.length;
    }

    function tokenAt(uint256 i) external view returns (uint256) {
        return _tokenIds[i % _tokenIds.length];
    }

    function caseCount() external view returns (uint256) {
        return _caseIds.length;
    }

    function caseAt(uint256 i) external view returns (uint256) {
        return _caseIds[i % _caseIds.length];
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    /// @notice Fund and deposit ETH into the court as `actor`. Bounded amount keeps the total
    ///         contract balance within sensible range and avoids bond-overflow edge cases.
    function deposit(uint256 actorIdx, uint128 amount) external {
        depositAttempts++;
        address actor = _actors[actorIdx % _actors.length];
        amount = uint128(bound(amount, 0.1 ether, 10 ether));
        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        (bool ok,) = address(court).call{ value: amount }("");
        require(ok, "handler deposit failed");
    }

    function stake(uint256 actorIdx, uint128 bondAmount) external {
        stakeAttempts++;
        address actor = _actors[actorIdx % _actors.length];
        uint128 deposited = court.pendingDeposits(actor);
        if (deposited == 0) return;
        // Bound the stake to existing deposit.
        uint128 max = deposited;
        bondAmount = uint128(bound(bondAmount, 0, max));
        if (bondAmount == 0) return;

        vm.prank(actor);
        try court.stakeAsReviewer(bondAmount) {
            stakeSuccesses++;
        } catch {
            // StakeTooLow (below MIN) / paused — expected in many runs
        }
    }

    function requestUnstake(uint256 actorIdx) external {
        requestUnstakeAttempts++;
        address actor = _actors[actorIdx % _actors.length];
        if (court.getReviewerStake(actor).bond == 0) return;
        vm.prank(actor);
        try court.requestUnstake() { } catch { }
    }

    function unstake(uint256 actorIdx) external {
        unstakeAttempts++;
        address actor = _actors[actorIdx % _actors.length];
        vm.prank(actor);
        try court.unstakeReviewer() {
            unstakeSuccesses++;
        } catch { }
    }

    function withdrawDeposit(uint256 actorIdx) external {
        withdrawDepositAttempts++;
        address actor = _actors[actorIdx % _actors.length];
        vm.prank(actor);
        try court.withdrawDeposit() {
            withdrawDepositSuccesses++;
        } catch { }
    }

    function raiseDispute(uint256 actorIdx, uint256 tokenIdx, bytes32 evidence) external {
        raiseAttempts++;
        address actor = _actors[actorIdx % _actors.length];
        uint256 tokenId = _tokenIds[tokenIdx % _tokenIds.length];

        vm.prank(actor);
        try court.raiseDispute(tokenId, evidence, "handler") returns (uint256 caseId) {
            if (!_isKnownCase[caseId]) {
                _isKnownCase[caseId] = true;
                _caseIds.push(caseId);
            }
            if (caseId > lastCaseId) lastCaseId = caseId;
            raiseSuccesses++;
        } catch { }
    }

    /// @param outcomeIdx 0..2 mapped onto UpheldTakedown(1) / Dismissed(2) / Settled(3) —
    ///        Pending(0) is skipped (always invalid).
    function resolveDispute(uint256 caseIdx, uint8 outcomeIdx) external {
        resolveAttempts++;
        if (_caseIds.length == 0) return;
        uint256 caseId = _caseIds[caseIdx % _caseIds.length];
        SeqoraTypes.DisputeOutcome outcome = SeqoraTypes.DisputeOutcome(uint8(bound(outcomeIdx, 1, 3)));

        // Time travel to a point at-or-past review window so resolve can actually land.
        vm.warp(block.timestamp + SeqoraTypes.MIN_DISPUTE_REVIEW_WINDOW + 1);

        vm.prank(GOVERNANCE);
        try court.resolveDispute(caseId, outcome) {
            resolveSuccesses++;
        } catch { }
    }

    function councilFreeze(uint256 tokenIdx) external {
        freezeAttempts++;
        uint256 tokenId = _tokenIds[tokenIdx % _tokenIds.length];
        vm.prank(COUNCIL);
        try court.safetyCouncilFreeze(tokenId, "h") {
            freezeSuccesses++;
        } catch { }
    }

    function ratifyFreeze(uint256 tokenIdx) external {
        ratifyAttempts++;
        uint256 tokenId = _tokenIds[tokenIdx % _tokenIds.length];
        vm.prank(GOVERNANCE);
        try court.ratifyFreeze(tokenId) { } catch { }
    }

    function rejectFreeze(uint256 tokenIdx) external {
        rejectAttempts++;
        uint256 tokenId = _tokenIds[tokenIdx % _tokenIds.length];
        vm.prank(GOVERNANCE);
        try court.rejectFreeze(tokenId) { } catch { }
    }

    function expireFreeze(uint256 tokenIdx) external {
        expireAttempts++;
        uint256 tokenId = _tokenIds[tokenIdx % _tokenIds.length];
        // Warp past the safety-council freeze window so expire can fire.
        vm.warp(block.timestamp + SeqoraTypes.SAFETY_COUNCIL_FREEZE_WINDOW + 1);
        try court.expireFreeze(tokenId) { } catch { }
    }

    function withdrawTreasury() external {
        withdrawTreasuryCalls++;
        try court.withdrawTreasury() { } catch { }
    }

    function withdrawReviewerCut() external {
        withdrawReviewerCutCalls++;
        vm.prank(GOVERNANCE);
        try court.withdrawReviewerCut() { } catch { }
    }

    function pauseToggle(bool p) external {
        if (p) {
            pauseCalls++;
            vm.prank(GOVERNANCE);
            try court.pause() { } catch { }
        } else {
            unpauseCalls++;
            vm.prank(GOVERNANCE);
            try court.unpause() { } catch { }
        }
    }

    /// @notice Advance time by a bounded amount so cooldowns / review windows / freeze windows
    ///         become reachable over an invariant run.
    function timeWarp(uint64 delta) external {
        delta = uint64(bound(uint256(delta), 1, uint256(SeqoraTypes.REVIEWER_UNSTAKE_COOLDOWN)));
        vm.warp(block.timestamp + delta);
    }

    // -------------------------------------------------------------------------
    // Seeding
    // -------------------------------------------------------------------------

    function _addActor(address a) internal {
        if (_isActor[a]) return;
        _isActor[a] = true;
        _actors.push(a);
    }

    function _seedDesign(address registrant, bytes32 canonical) internal {
        SeqoraTypes.RoyaltyRule memory royalty =
            SeqoraTypes.RoyaltyRule({ recipient: address(0xEEEE), bps: 500, parentSplitBps: 0 });
        vm.prank(registrant);
        uint256 tokenId = designs.register(
            registrant, canonical, bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0)
        );
        _tokenIds.push(tokenId);
        _isKnownToken[tokenId] = true;
    }
}
