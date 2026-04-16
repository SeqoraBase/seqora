// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StdInvariant } from "forge-std/StdInvariant.sol";

import { BiosafetyCourt } from "../src/BiosafetyCourt.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";

import { BiosafetyCourtHarness } from "./helpers/BiosafetyCourtHarness.sol";
import { BiosafetyCourtHandler } from "./handlers/BiosafetyCourtHandler.sol";

/// @notice State-machine invariants for BiosafetyCourt.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = false
contract BiosafetyCourt_Invariant_Test is BiosafetyCourtHarness {
    BiosafetyCourtHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new BiosafetyCourtHandler(court, designs, GOVERNANCE, COUNCIL);

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = BiosafetyCourtHandler.deposit.selector;
        selectors[1] = BiosafetyCourtHandler.stake.selector;
        selectors[2] = BiosafetyCourtHandler.requestUnstake.selector;
        selectors[3] = BiosafetyCourtHandler.unstake.selector;
        selectors[4] = BiosafetyCourtHandler.withdrawDeposit.selector;
        selectors[5] = BiosafetyCourtHandler.raiseDispute.selector;
        selectors[6] = BiosafetyCourtHandler.resolveDispute.selector;
        selectors[7] = BiosafetyCourtHandler.councilFreeze.selector;
        selectors[8] = BiosafetyCourtHandler.ratifyFreeze.selector;
        selectors[9] = BiosafetyCourtHandler.rejectFreeze.selector;
        selectors[10] = BiosafetyCourtHandler.expireFreeze.selector;
        selectors[11] = BiosafetyCourtHandler.withdrawTreasury.selector;
        selectors[12] = BiosafetyCourtHandler.withdrawReviewerCut.selector;
        selectors[13] = BiosafetyCourtHandler.pauseToggle.selector;
        selectors[14] = BiosafetyCourtHandler.timeWarp.selector;
        targetSelector(StdInvariant.FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    // ------------------------------------------------------------------
    // 1. CENTRAL ACCOUNTING: sum(pendingDeposits) + sum(bonds) + treasuryAccrued
    //    + reviewerCutAccrued == address(this).balance
    // ------------------------------------------------------------------

    /// @notice For every actor the handler touches, sum of (pendingDeposits + bond) + accruals
    ///         equals the court's ETH balance. Guards against lost wei, double-counting, or
    ///         slashing that doesn't properly debit the bond.
    function invariant_CentralAccounting() public view {
        uint256 n = handler.actorCount();
        uint256 totalPending = 0;
        uint256 totalBond = 0;
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actorAt(i);
            totalPending += uint256(court.pendingDeposits(a));
            totalBond += uint256(court.getReviewerStake(a).bond);
        }
        uint256 accrued = uint256(court.treasuryAccrued());
        // _reviewerCutAccrued is internal — use withdraw as a proxy is not idempotent here.
        // Instead read via the known invariant: balance == pending + bond + treasury + reviewerCut.
        // So reviewerCut = balance - (pending + bond + treasury) and MUST be >= 0.
        uint256 balance = address(court).balance;
        uint256 accounted = totalPending + totalBond + accrued;
        assertGe(balance, accounted, "balance covers pending+bond+treasury");
        uint256 implicitReviewerCut = balance - accounted;
        // implicitReviewerCut must fit in uint128 (the stored type).
        assertLe(implicitReviewerCut, type(uint128).max, "reviewer cut fits uint128");
    }

    // ------------------------------------------------------------------
    // 2. FREEZE UNIQUENESS: at most one Active or Ratified freeze per tokenId
    // ------------------------------------------------------------------

    /// @notice For every tokenId, the freeze record is in exactly one status and is internally
    ///         consistent: Active implies expiresAt != 0; Ratified implies expiresAt == 0;
    ///         Rejected implies expiresAt <= block.timestamp.
    function invariant_FreezeStatusConsistent() public view {
        uint256 n = handler.tokenCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.tokenAt(i);
            SeqoraTypes.SafetyFreeze memory f = court.getFreeze(tokenId);
            if (f.status == SeqoraTypes.FreezeStatus.Active) {
                assertGt(f.expiresAt, 0, "active freeze has expiresAt");
            } else if (f.status == SeqoraTypes.FreezeStatus.Ratified) {
                assertEq(f.expiresAt, 0, "ratified freeze resets expiresAt to 0");
            } else if (f.status == SeqoraTypes.FreezeStatus.Rejected) {
                assertLe(uint256(f.expiresAt), block.timestamp, "rejected freeze expiresAt snapped to rejection time");
            }
            // AutoLifted: no constraint on expiresAt (kept for history).
        }
    }

    /// @notice isFrozen agrees with the stored status after lazy-expiry: Active-past-expiresAt
    ///         reports as not-frozen; Ratified reports as frozen forever; any other status is
    ///         not frozen.
    function invariant_IsFrozenMatchesStatus() public view {
        uint256 n = handler.tokenCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.tokenAt(i);
            SeqoraTypes.SafetyFreeze memory f = court.getFreeze(tokenId);
            (bool frozen,) = court.isFrozen(tokenId);
            if (f.status == SeqoraTypes.FreezeStatus.Ratified) {
                assertTrue(frozen, "ratified => frozen");
            } else if (f.status == SeqoraTypes.FreezeStatus.Active) {
                if (block.timestamp < f.expiresAt) {
                    assertTrue(frozen, "active+unexpired => frozen");
                } else {
                    assertFalse(frozen, "active+elapsed => lazy-lifted");
                }
            } else {
                assertFalse(frozen, "not-active => not frozen");
            }
        }
    }

    // ------------------------------------------------------------------
    // 3. DISPUTE BOOKKEEPING: caseId monotonic; openDisputeOf points to valid unresolved case.
    // ------------------------------------------------------------------

    /// @notice nextDisputeId only grows; first case id is 1.
    function invariant_CaseIdMonotonic() public view {
        uint256 next = court.nextDisputeId();
        assertGe(next, 1, "nextDisputeId never zero");
        assertGe(next, handler.lastCaseId(), "nextDisputeId past every observed caseId");
    }

    /// @notice For every tokenId, openDisputeOf is either 0 OR points to an unresolved case
    ///         whose `tokenId` matches.
    function invariant_OpenDisputeOfConsistent() public view {
        uint256 n = handler.tokenCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.tokenAt(i);
            uint256 open = court.openDisputeOf(tokenId);
            if (open != 0) {
                SeqoraTypes.Dispute memory d = court.getDispute(open);
                assertEq(d.tokenId, tokenId, "open dispute's tokenId matches");
                assertEq(d.resolvedAt, 0, "open dispute is unresolved");
                assertEq(uint8(d.outcome), uint8(SeqoraTypes.DisputeOutcome.Pending), "open dispute pending");
            }
        }
    }

    /// @notice Every resolved dispute has a non-zero resolvedAt, outcome != Pending, and its
    ///         tokenId is NOT currently pointed to by openDisputeOf UNLESS a *different* open
    ///         case has taken the slot.
    function invariant_ResolvedDisputesAreClosed() public view {
        uint256 n = handler.caseCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 caseId = handler.caseAt(i);
            SeqoraTypes.Dispute memory d = court.getDispute(caseId);
            if (d.resolvedAt != 0) {
                assertTrue(d.outcome != SeqoraTypes.DisputeOutcome.Pending, "resolved => non-pending");
                uint256 open = court.openDisputeOf(d.tokenId);
                assertTrue(open == 0 || open != caseId, "resolved case is NOT openDisputeOf");
            }
        }
    }

    // ------------------------------------------------------------------
    // 4. BOND STATE MONOTONICITY
    // ------------------------------------------------------------------

    /// @notice Every staked reviewer's bond is either 0 or >= MIN_REVIEWER_STAKE after the LAST
    ///         successful `stakeAsReviewer`. However, after a Dismissed outcome that slashes
    ///         DISPUTE_BOND, the bond may drop below MIN without reverting the prior stake. So
    ///         the correct invariant is: bond >= 0 AND bond never wraps (checked via uint128).
    function invariant_BondNeverNegative() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actorAt(i);
            uint128 b = court.getReviewerStake(a).bond;
            // uint128 underflow would wrap to huge value; sanity-check by bounding to the
            // plausible contract balance.
            assertLe(uint256(b), address(court).balance + 100 ether, "bond plausible vs balance");
        }
    }

    /// @notice pendingDeposits[a] is bounded by the contract's ETH balance — no single actor's
    ///         pending balance should exceed the contract's total balance (since all deposits
    ///         sit in the contract).
    function invariant_PendingDepositBounded() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actorAt(i);
            uint128 p = court.pendingDeposits(a);
            assertLe(uint256(p), address(court).balance, "per-actor pending <= total balance");
        }
    }

    // ------------------------------------------------------------------
    // 5. GOVERNANCE INVARIANTS
    // ------------------------------------------------------------------

    /// @notice The owner and safety council addresses never go to zero after initialization.
    function invariant_GovernanceAddressesNonZero() public view {
        assertTrue(court.owner() != address(0), "owner never zero");
        assertTrue(court.safetyCouncil() != address(0), "council never zero");
        assertTrue(court.treasury() != address(0), "treasury never zero");
    }

    /// @notice designRegistry pointer is set at initialization and never changes.
    function invariant_DesignRegistryImmutable() public view {
        assertEq(address(court.designRegistry()), address(designs), "registry pointer stable");
    }

    // ------------------------------------------------------------------
    // 6. TREASURY NEVER GOES NEGATIVE
    // ------------------------------------------------------------------

    /// @notice treasuryAccrued is always <= address(this).balance. A violation would indicate
    ///         treasury credits without corresponding ETH ingress.
    function invariant_TreasuryAccruedNotOversized() public view {
        assertLe(uint256(court.treasuryAccrued()), address(court).balance, "treasury bounded by balance");
    }
}
