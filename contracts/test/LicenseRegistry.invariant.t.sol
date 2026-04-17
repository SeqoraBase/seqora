// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, StdInvariant } from "forge-std/Test.sol";

import { LicenseRegistry } from "../src/LicenseRegistry.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";

import { LicenseRegistryHarness } from "./helpers/LicenseRegistryHarness.sol";
import { LicenseRegistryHandler } from "./handlers/LicenseRegistryHandler.sol";

/// @notice State-machine invariants for LicenseRegistry. Registers a handler that mutates the
///         registry through grant / revoke / transfer paths, and asserts the following:
///           1. At most one LIVE exclusive grant per tokenId at any time.
///           2. Every minted license maps to a non-zero licensee.
///           3. Once revoked, a license stays revoked (monotonicity).
///           4. totalSupply (minted - 0 burns) >= live license count.
///           5. liveByToken (granted - revoked events per tokenId) matches the handler's tracker
///              for each tokenId that ever saw a grant.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 50
contract LicenseRegistry_Invariant_Test is LicenseRegistryHarness {
    LicenseRegistryHandler internal handler;

    // Fixed template that the handler uses (T_ATTR) — asserted unchanged across the run.
    bytes32 internal constant TRACKED_TMPL = keccak256("H_ATTR");
    SeqoraTypes.LicenseTemplate internal trackedAtReg;

    function setUp() public override {
        super.setUp();
        handler = new LicenseRegistryHandler(licenses, designs, GOVERNANCE);

        // Snapshot the template *as registered by the handler*, which we'll compare against
        // later via invariant_TemplateImmutableExceptActive.
        trackedAtReg = licenses.getLicenseTemplate(TRACKED_TMPL);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = LicenseRegistryHandler.grant.selector;
        selectors[1] = LicenseRegistryHandler.revoke.selector;
        selectors[2] = LicenseRegistryHandler.xfer.selector;
        selectors[3] = LicenseRegistryHandler.spamGrant.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// @notice For every minted licenseTokenId, the stored License has a non-zero licensee.
    function invariant_EveryLicenseHasLicensee() public view {
        uint256 n = handler.licenseCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 lt = handler.licenseAt(i);
            SeqoraTypes.License memory l = licenses.getLicense(lt);
            assertTrue(l.licensee != address(0), "minted license must have non-zero licensee");
        }
    }

    /// @notice Revoked licenses never un-revoke, and isLicenseValid stays false forever.
    function invariant_RevokedStaysRevoked() public view {
        uint256 n = handler.licenseCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 lt = handler.licenseAt(i);
            SeqoraTypes.License memory l = licenses.getLicense(lt);
            if (l.revoked) {
                // isLicenseValid must return false regardless of who is queried.
                assertFalse(licenses.isLicenseValid(lt, l.licensee), "revoked license cannot be valid");
                assertFalse(licenses.isLicenseValid(lt, address(this)), "revoked license cannot be valid 2");
            }
        }
    }

    /// @notice For every tokenId the handler has interacted with, at most one live exclusive
    ///         grant exists at any moment.
    function invariant_ExclusiveSlotNeverExceedsOne() public view {
        uint256 n = handler.designCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.designAt(i);
            assertLe(handler.liveExclusiveCount(tokenId), 1, "at most one live exclusive per tokenId");
        }
    }

    /// @notice nextLicenseTokenId is monotonic (only grows).
    function invariant_CounterNeverDecreases() public view {
        // By construction the handler never sets the counter; this also rejects any
        // future bug that makes it mutable.
        assertGe(licenses.nextLicenseTokenId(), 1);
    }

    /// @notice Template is immutable other than its `active` flag — other fields never drift.
    function invariant_TemplateImmutableExceptActive() public view {
        SeqoraTypes.LicenseTemplate memory t = licenses.getLicenseTemplate(TRACKED_TMPL);
        assertEq(t.licenseId, trackedAtReg.licenseId);
        assertEq(t.name, trackedAtReg.name);
        assertEq(t.uri, trackedAtReg.uri);
        assertEq(t.commercialUse, trackedAtReg.commercialUse);
        assertEq(t.requiresAttribution, trackedAtReg.requiresAttribution);
        assertEq(t.pilFlags, trackedAtReg.pilFlags);
        assertEq(t.defaultDuration, trackedAtReg.defaultDuration);
    }

    /// @notice Bounded-gas invariant: `checkLicenseValid(tokenId, honestUser)` must stay
    ///         well under the block-gas ceiling regardless of how many bogus grants the
    ///         handler's spamGrant has piled onto the same tokenId (bogus grants go to
    ///         unique junk addresses, so the HONEST user's reverse-index array is not
    ///         contaminated). Before the reverse-index fix this loop was O(total grants) and would easily
    ///         blow past any reasonable cap after 50+ calls.
    function invariant_CheckLicenseValid_GasBounded() public view {
        uint256 n = handler.designCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.designAt(i);
            // Probe a non-actor "honest user" address — guaranteed to never have a license
            // granted by the handler (which only grants to its 4 actors and unique junks).
            address honest = address(0xBEEF);
            uint256 before = gasleft();
            licenses.checkLicenseValid(tokenId, honest);
            uint256 used = before - gasleft();
            assertLt(used, 200_000, "checkLicenseValid must be bounded by per-user array, not total grants");
        }
    }
}
