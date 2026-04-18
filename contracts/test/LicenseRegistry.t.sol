// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { LicenseRegistry } from "../src/LicenseRegistry.sol";
import { ILicenseRegistry } from "../src/interfaces/ILicenseRegistry.sol";
import { IDesignRegistry } from "../src/interfaces/IDesignRegistry.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";
import { SeqoraErrors } from "../src/libraries/SeqoraErrors.sol";

import { LicenseRegistryHarness, LicenseRegistryV2Mock } from "./helpers/LicenseRegistryHarness.sol";

// ============================================================================
// Shared canonical template ids used across suites
// ============================================================================

library Tmpl {
    bytes32 internal constant OPEN_MTA = keccak256("OpenMTA");
    bytes32 internal constant COMMERCIAL = keccak256("Commercial");
    bytes32 internal constant COMMERCIAL_TRANSFERABLE = keccak256("CommercialTransferable");
    bytes32 internal constant EXCLUSIVE = keccak256("Exclusive");
    bytes32 internal constant EXCLUSIVE_TRANSFERABLE = keccak256("ExclusiveTransferable");
    bytes32 internal constant NON_TRANSFERABLE = keccak256("NonTransferable");
    bytes32 internal constant PERPETUAL = keccak256("Perpetual");
}

// ============================================================================
// INITIALIZATION / CONSTRUCTOR
// ============================================================================

contract LicenseRegistry_Init_Test is LicenseRegistryHarness {
    function test_Initialize_SetsState() public view {
        assertEq(address(licenses.designRegistry()), address(designs), "designRegistry stored");
        assertEq(licenses.owner(), GOVERNANCE, "owner = governance");
        assertEq(licenses.nextLicenseTokenId(), 1, "tokenId counter starts at 1");
        assertEq(licenses.feeRouter(), address(0), "feeRouter defaults to zero");
        assertFalse(licenses.paused(), "not paused on deploy");
        assertEq(licenses.name(), "Seqora License");
        assertEq(licenses.symbol(), "SEQ-LIC");
    }

    function test_Initialize_RevertsWhen_CalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        licenses.initialize(IDesignRegistry(address(designs)), GOVERNANCE);
    }

    function test_Initialize_RevertsWhen_ImplCalledDirectly() public {
        // _disableInitializers() in the constructor locks the impl so direct initialization fails.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(IDesignRegistry(address(designs)), GOVERNANCE);
    }

    function test_Initialize_RevertsWhen_ZeroRegistry() public {
        LicenseRegistry freshImpl = new LicenseRegistry();
        bytes memory data = abi.encodeCall(LicenseRegistry.initialize, (IDesignRegistry(address(0)), GOVERNANCE));
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        new ERC1967Proxy(address(freshImpl), data);
    }

    function test_Initialize_RevertsWhen_ZeroGovernance() public {
        LicenseRegistry freshImpl = new LicenseRegistry();
        bytes memory data = abi.encodeCall(LicenseRegistry.initialize, (IDesignRegistry(address(designs)), address(0)));
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        new ERC1967Proxy(address(freshImpl), data);
    }

    function test_SupportsInterface() public view {
        assertTrue(licenses.supportsInterface(type(ILicenseRegistry).interfaceId), "ILicenseRegistry");
        assertTrue(licenses.supportsInterface(type(IERC721).interfaceId), "IERC721");
        assertTrue(licenses.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(licenses.supportsInterface(bytes4(0xdeadbeef)), "random id");
    }
}

// ============================================================================
// TEMPLATES
// ============================================================================

contract LicenseRegistry_Templates_Test is LicenseRegistryHarness {
    function test_RegisterTemplate_Happy_EmitsAndStores() public {
        SeqoraTypes.LicenseTemplate memory t =
            _buildTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION | SeqoraTypes.PIL_DERIVATIVE, 30);

        vm.expectEmit(true, false, false, true);
        emit ILicenseRegistry.LicenseTemplateRegistered(Tmpl.OPEN_MTA, t.name, t.uri);
        vm.expectEmit(true, false, false, true);
        emit ILicenseRegistry.LicenseTemplateStatusChanged(Tmpl.OPEN_MTA, true);
        vm.prank(GOVERNANCE);
        licenses.registerLicenseTemplate(t);

        SeqoraTypes.LicenseTemplate memory stored = licenses.getLicenseTemplate(Tmpl.OPEN_MTA);
        assertEq(stored.licenseId, Tmpl.OPEN_MTA);
        assertEq(stored.name, t.name);
        assertEq(stored.pilFlags, t.pilFlags);
        assertEq(stored.defaultDuration, t.defaultDuration);
        assertTrue(stored.active);
    }

    function test_RegisterTemplate_AllFlagCombosAccepted() public {
        // Accept all 5 flag combos from the engineer's decision list.
        _createTemplate(keccak256("T_COMMERCIAL"), SeqoraTypes.PIL_COMMERCIAL, 0);
        _createTemplate(keccak256("T_ATTRIBUTION"), SeqoraTypes.PIL_ATTRIBUTION, 0);
        _createTemplate(keccak256("T_EXCLUSIVE"), SeqoraTypes.PIL_EXCLUSIVE, 0);
        _createTemplate(keccak256("T_TRANSFERABLE"), SeqoraTypes.PIL_TRANSFERABLE, 0);
        _createTemplate(
            keccak256("T_OPEN_PERMISSIVE"),
            SeqoraTypes.PIL_COMMERCIAL | SeqoraTypes.PIL_DERIVATIVE | SeqoraTypes.PIL_ATTRIBUTION,
            30
        );
        _createTemplate(
            keccak256("T_FULL"),
            SeqoraTypes.PIL_COMMERCIAL | SeqoraTypes.PIL_DERIVATIVE | SeqoraTypes.PIL_ATTRIBUTION
                | SeqoraTypes.PIL_EXCLUSIVE | SeqoraTypes.PIL_TRANSFERABLE,
            30
        );
        _createTemplate(keccak256("T_EXCLUSIVE_TRANSFER"), SeqoraTypes.PIL_EXCLUSIVE | SeqoraTypes.PIL_TRANSFERABLE, 0);
    }

    function test_RegisterTemplate_RevertsWhen_NotOwner() public {
        SeqoraTypes.LicenseTemplate memory t = _buildTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 0);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        licenses.registerLicenseTemplate(t);
    }

    function test_RegisterTemplate_RevertsWhen_ZeroLicenseId() public {
        SeqoraTypes.LicenseTemplate memory t = _buildTemplate(bytes32(0), SeqoraTypes.PIL_COMMERCIAL, 0);
        vm.prank(GOVERNANCE);
        vm.expectRevert(SeqoraErrors.ZeroValue.selector);
        licenses.registerLicenseTemplate(t);
    }

    function test_RegisterTemplate_RevertsWhen_Duplicate() public {
        _createTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 0);
        SeqoraTypes.LicenseTemplate memory t = _buildTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 0);
        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(ILicenseRegistry.LicenseTemplateAlreadyExists.selector, Tmpl.OPEN_MTA));
        licenses.registerLicenseTemplate(t);
    }

    function test_RegisterTemplate_RevertsWhen_DerivativeWithoutAttribution() public {
        SeqoraTypes.LicenseTemplate memory t = _buildTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_DERIVATIVE, 0);
        vm.prank(GOVERNANCE);
        vm.expectRevert(LicenseRegistry.DerivativeRequiresAttribution.selector);
        licenses.registerLicenseTemplate(t);
    }

    function test_RegisterTemplate_RevertsWhen_FlagsOutsideMask() public {
        uint16 bad = 0x0020; // first reserved bit
        SeqoraTypes.LicenseTemplate memory t = _buildTemplate(Tmpl.OPEN_MTA, bad, 0);
        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.InvalidPilFlags.selector, bad));
        licenses.registerLicenseTemplate(t);
    }

    function test_RegisterTemplate_RevertsWhen_HighBitOutsideMask() public {
        uint16 bad = 0x8000;
        SeqoraTypes.LicenseTemplate memory t = _buildTemplate(Tmpl.OPEN_MTA, bad, 0);
        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.InvalidPilFlags.selector, bad));
        licenses.registerLicenseTemplate(t);
    }

    function test_RegisterTemplate_RevertsWhen_CommercialBoolMismatch() public {
        SeqoraTypes.LicenseTemplate memory t = _buildTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_COMMERCIAL, 0);
        t.commercialUse = false; // mismatch w/ flag
        vm.prank(GOVERNANCE);
        vm.expectRevert(LicenseRegistry.PilFlagBooleanMismatch.selector);
        licenses.registerLicenseTemplate(t);
    }

    function test_RegisterTemplate_RevertsWhen_AttributionBoolMismatch() public {
        SeqoraTypes.LicenseTemplate memory t = _buildTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 0);
        t.requiresAttribution = false; // mismatch
        vm.prank(GOVERNANCE);
        vm.expectRevert(LicenseRegistry.PilFlagBooleanMismatch.selector);
        licenses.registerLicenseTemplate(t);
    }

    function test_GetLicenseTemplate_RevertsWhen_Unknown() public {
        vm.expectRevert(abi.encodeWithSelector(ILicenseRegistry.UnknownLicenseTemplate.selector, Tmpl.OPEN_MTA));
        licenses.getLicenseTemplate(Tmpl.OPEN_MTA);
    }

    function test_SetTemplateActive_Happy_Emits() public {
        _createTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 0);
        vm.expectEmit(true, false, false, true);
        emit ILicenseRegistry.LicenseTemplateStatusChanged(Tmpl.OPEN_MTA, false);
        vm.prank(GOVERNANCE);
        licenses.setLicenseTemplateActive(Tmpl.OPEN_MTA, false);
        assertFalse(licenses.getLicenseTemplate(Tmpl.OPEN_MTA).active);
    }

    function test_SetTemplateActive_Idempotent_NoEvent() public {
        _createTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 0);
        vm.recordLogs();
        vm.prank(GOVERNANCE);
        licenses.setLicenseTemplateActive(Tmpl.OPEN_MTA, true); // same value — no-op
        assertEq(vm.getRecordedLogs().length, 0, "idempotent toggle must not emit");
    }

    function test_SetTemplateActive_RevertsWhen_NotOwner() public {
        _createTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 0);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        licenses.setLicenseTemplateActive(Tmpl.OPEN_MTA, false);
    }

    function test_SetTemplateActive_RevertsWhen_Unknown() public {
        vm.expectRevert(abi.encodeWithSelector(ILicenseRegistry.UnknownLicenseTemplate.selector, Tmpl.OPEN_MTA));
        vm.prank(GOVERNANCE);
        licenses.setLicenseTemplateActive(Tmpl.OPEN_MTA, false);
    }
}

// ============================================================================
// GRANTS
// ============================================================================

contract LicenseRegistry_Grant_Test is LicenseRegistryHarness {
    uint256 internal designId;

    function setUp() public override {
        super.setUp();
        designId = _registerDesign(ALICE, keccak256("design-1"));
        _createTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION | SeqoraTypes.PIL_DERIVATIVE, 30);
        _createTemplate(Tmpl.EXCLUSIVE, SeqoraTypes.PIL_EXCLUSIVE, 0);
        _createTemplate(Tmpl.EXCLUSIVE_TRANSFERABLE, SeqoraTypes.PIL_EXCLUSIVE | SeqoraTypes.PIL_TRANSFERABLE, 0);
        _createTemplate(Tmpl.COMMERCIAL_TRANSFERABLE, SeqoraTypes.PIL_COMMERCIAL | SeqoraTypes.PIL_TRANSFERABLE, 0);
        _createTemplate(Tmpl.NON_TRANSFERABLE, SeqoraTypes.PIL_ATTRIBUTION, 0);
        _createTemplate(Tmpl.PERPETUAL, SeqoraTypes.PIL_ATTRIBUTION, 0);
    }

    function test_Grant_ByRegistrant_Happy() public {
        uint64 expiry = uint64(block.timestamp) + 3600;
        vm.expectEmit(true, true, true, true);
        emit IERC721.Transfer(address(0), BOB, 1);
        vm.expectEmit(true, true, true, true);
        emit ILicenseRegistry.LicenseGranted(1, designId, Tmpl.OPEN_MTA, BOB, expiry, 42);
        vm.prank(ALICE);
        uint256 lt = licenses.grantLicense(designId, Tmpl.OPEN_MTA, BOB, expiry, 42);

        assertEq(lt, 1, "first licenseTokenId == 1");
        assertEq(licenses.ownerOf(1), BOB, "ERC721 owner set");
        assertEq(licenses.balanceOf(BOB), 1);
        SeqoraTypes.License memory l = licenses.getLicense(1);
        assertEq(l.tokenId, designId);
        assertEq(l.licenseId, Tmpl.OPEN_MTA);
        assertEq(l.licensee, BOB);
        assertEq(l.expiry, expiry);
        assertEq(l.feePaid, 42);
        assertFalse(l.revoked);
        assertTrue(licenses.isLicenseValid(1, BOB));
    }

    function test_Grant_ByGovernance_Happy() public {
        vm.prank(GOVERNANCE);
        uint256 lt = licenses.grantLicense(designId, Tmpl.OPEN_MTA, BOB, 0, 0);
        assertEq(licenses.ownerOf(lt), BOB);
    }

    function test_Grant_TokenIdMonotonic() public {
        uint256 a = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
        uint256 b = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, CAROL);
        uint256 c = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, DAVE);
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(c, 3);
        assertEq(licenses.nextLicenseTokenId(), 4);
    }

    function test_Grant_RevertsWhen_ZeroLicensee() public {
        vm.prank(ALICE);
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        licenses.grantLicense(designId, Tmpl.OPEN_MTA, address(0), 0, 0);
    }

    function test_Grant_RevertsWhen_UnknownTemplate() public {
        bytes32 ghost = keccak256("ghost");
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ILicenseRegistry.UnknownLicenseTemplate.selector, ghost));
        licenses.grantLicense(designId, ghost, BOB, 0, 0);
    }

    function test_Grant_RevertsWhen_RetiredTemplate() public {
        vm.prank(GOVERNANCE);
        licenses.setLicenseTemplateActive(Tmpl.OPEN_MTA, false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.TemplateInactive.selector, Tmpl.OPEN_MTA));
        licenses.grantLicense(designId, Tmpl.OPEN_MTA, BOB, 0, 0);
    }

    function test_Grant_RevertsWhen_UnknownDesign() public {
        uint256 ghost = uint256(keccak256("ghost-design"));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.UnknownDesign.selector, ghost));
        licenses.grantLicense(ghost, Tmpl.OPEN_MTA, BOB, 0, 0);
    }

    function test_Grant_RevertsWhen_NotAuthorized() public {
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.NotAuthorized.selector, CAROL));
        licenses.grantLicense(designId, Tmpl.OPEN_MTA, BOB, 0, 0);
    }

    function test_Grant_RevertsWhen_Paused() public {
        vm.prank(GOVERNANCE);
        licenses.pause();
        vm.prank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        licenses.grantLicense(designId, Tmpl.OPEN_MTA, BOB, 0, 0);
    }

    function test_Grant_RevertsWhen_ExpiryInPast() public {
        vm.warp(1_000_000);
        vm.prank(ALICE);
        vm.expectRevert(SeqoraErrors.ZeroValue.selector);
        licenses.grantLicense(designId, Tmpl.OPEN_MTA, BOB, uint64(block.timestamp - 1), 0);
    }

    function test_Grant_ExpiryEqualsNow_Reverts() public {
        // expiry == block.timestamp must revert because `resolvedExpiry <= block.timestamp`.
        vm.warp(1_000_000);
        vm.prank(ALICE);
        vm.expectRevert(SeqoraErrors.ZeroValue.selector);
        licenses.grantLicense(designId, Tmpl.OPEN_MTA, BOB, uint64(block.timestamp), 0);
    }

    function test_Grant_DefaultDuration_Derives() public {
        vm.warp(1_000_000);
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
        SeqoraTypes.License memory l = licenses.getLicense(lt);
        assertEq(l.expiry, uint64(block.timestamp) + 30 * 86_400, "30-day default duration applied");
    }

    function test_Grant_PerpetualWhen_DurationAndExpiryZero() public {
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.PERPETUAL, BOB);
        assertEq(licenses.getLicense(lt).expiry, 0, "perpetual grant stored as 0");
    }

    function test_Grant_ExclusiveSlot_FirstSucceeds_SecondReverts() public {
        uint256 first = _grantLicense(ALICE, designId, Tmpl.EXCLUSIVE, BOB);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.ExclusiveAlreadyGranted.selector, designId, first));
        licenses.grantLicense(designId, Tmpl.EXCLUSIVE, CAROL, 0, 0);
    }

    function test_Grant_Exclusive_AfterRevoke_Succeeds() public {
        uint256 first = _grantLicense(ALICE, designId, Tmpl.EXCLUSIVE, BOB);
        vm.prank(ALICE);
        licenses.revokeLicense(first, "gone");
        uint256 second = _grantLicense(ALICE, designId, Tmpl.EXCLUSIVE, CAROL);
        assertEq(licenses.ownerOf(second), CAROL);
    }

    function test_Grant_Exclusive_AfterExpiry_Succeeds() public {
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp + 100);
        _grantLicenseWithExpiry(ALICE, designId, Tmpl.EXCLUSIVE, BOB, expiry, 0);
        vm.warp(expiry + 1);
        uint256 second = _grantLicense(ALICE, designId, Tmpl.EXCLUSIVE, CAROL);
        assertEq(licenses.ownerOf(second), CAROL);
    }

    function test_Grant_ReGrantNonExclusive_MintsSecond() public {
        uint256 a = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
        uint256 b = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
        assertEq(b, a + 1, "second licenseTokenId distinct");
        assertEq(licenses.balanceOf(BOB), 2);
    }

    function test_Grant_ToContractWithoutReceiver_Reverts() public {
        address noReceiver = address(designs); // DesignRegistry doesn't implement ERC721Receiver
        vm.prank(ALICE);
        vm.expectRevert(); // ERC721InvalidReceiver
        licenses.grantLicense(designId, Tmpl.OPEN_MTA, noReceiver, 0, 0);
    }
}

// ============================================================================
// REVOKE
// ============================================================================

contract LicenseRegistry_Revoke_Test is LicenseRegistryHarness {
    uint256 internal designId;
    uint256 internal lt;

    function setUp() public override {
        super.setUp();
        designId = _registerDesign(ALICE, keccak256("design-rev"));
        _createTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 0);
        _createTemplate(Tmpl.EXCLUSIVE, SeqoraTypes.PIL_EXCLUSIVE, 0);
        lt = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
    }

    function test_Revoke_ByRegistrant_Happy() public {
        vm.expectEmit(true, true, false, true);
        emit ILicenseRegistry.LicenseRevoked(lt, ALICE, "gone");
        vm.prank(ALICE);
        licenses.revokeLicense(lt, "gone");
        SeqoraTypes.License memory l = licenses.getLicense(lt);
        assertTrue(l.revoked);
        assertFalse(licenses.isLicenseValid(lt, BOB));
    }

    function test_Revoke_ByGovernance_Happy() public {
        vm.prank(GOVERNANCE);
        licenses.revokeLicense(lt, "gov-pulled");
        assertTrue(licenses.getLicense(lt).revoked);
    }

    function test_Revoke_RevertsWhen_UnauthorizedCaller() public {
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.NotAuthorized.selector, CAROL));
        licenses.revokeLicense(lt, "nope");
    }

    function test_Revoke_RevertsWhen_LicenseOwnerCalls() public {
        // License owner (BOB) is NOT authorized to self-revoke.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.NotAuthorized.selector, BOB));
        licenses.revokeLicense(lt, "no-self");
    }

    function test_Revoke_RevertsWhen_Unknown() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.UnknownToken.selector, 999));
        licenses.revokeLicense(999, "r");
    }

    function test_Revoke_RevertsWhen_AlreadyRevoked() public {
        vm.prank(ALICE);
        licenses.revokeLicense(lt, "once");
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.AlreadyRevoked.selector, lt));
        licenses.revokeLicense(lt, "twice");
    }

    function test_Revoke_Exclusive_ClearsSlot_AllowsRegrant() public {
        uint256 exclLt = _grantLicense(ALICE, designId, Tmpl.EXCLUSIVE, BOB);
        vm.prank(ALICE);
        licenses.revokeLicense(exclLt, "fresh-slot");
        uint256 second = _grantLicense(ALICE, designId, Tmpl.EXCLUSIVE, CAROL);
        assertEq(licenses.ownerOf(second), CAROL);
    }

    function test_Revoke_TokenStillReadableViaOwnerOf() public {
        vm.prank(ALICE);
        licenses.revokeLicense(lt, "rev");
        // Token is NOT burned — still owned by BOB.
        assertEq(licenses.ownerOf(lt), BOB, "revoked license not burned");
        SeqoraTypes.License memory l = licenses.getLicense(lt);
        assertTrue(l.revoked);
    }

    function test_Revoke_PauseDoesNotBlock() public {
        vm.prank(GOVERNANCE);
        licenses.pause();
        // Revoking must still work even when paused (brief §6 — pause only halts new grants).
        vm.prank(ALICE);
        licenses.revokeLicense(lt, "paused-but-revoke-ok");
        assertTrue(licenses.getLicense(lt).revoked);
    }
}

// ============================================================================
// VALIDITY
// ============================================================================

contract LicenseRegistry_Validity_Test is LicenseRegistryHarness {
    uint256 internal designId;

    function setUp() public override {
        super.setUp();
        designId = _registerDesign(ALICE, keccak256("design-valid"));
        _createTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 0);
        _createTemplate(Tmpl.COMMERCIAL_TRANSFERABLE, SeqoraTypes.PIL_COMMERCIAL | SeqoraTypes.PIL_TRANSFERABLE, 0);
    }

    function test_IsValid_True_Happy() public {
        uint256 lt = _grantLicenseWithExpiry(ALICE, designId, Tmpl.OPEN_MTA, BOB, uint64(block.timestamp + 100), 0);
        assertTrue(licenses.isLicenseValid(lt, BOB));
    }

    function test_IsValid_False_UnknownTokenId() public view {
        assertFalse(licenses.isLicenseValid(999, BOB));
    }

    function test_IsValid_False_Revoked() public {
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
        vm.prank(ALICE);
        licenses.revokeLicense(lt, "r");
        assertFalse(licenses.isLicenseValid(lt, BOB));
    }

    function test_IsValid_ExpiryBoundary_EqualToNow_ReturnsTrue() public {
        // Spec: `expiry < block.timestamp` means expired. expiry == now → still valid.
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp + 100);
        uint256 lt = _grantLicenseWithExpiry(ALICE, designId, Tmpl.OPEN_MTA, BOB, expiry, 0);
        vm.warp(expiry);
        assertTrue(licenses.isLicenseValid(lt, BOB), "expiry == now is not yet expired");
    }

    function test_IsValid_ExpiryBoundary_OneSecondPast_ReturnsFalse() public {
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp + 100);
        uint256 lt = _grantLicenseWithExpiry(ALICE, designId, Tmpl.OPEN_MTA, BOB, expiry, 0);
        vm.warp(uint256(expiry) + 1);
        assertFalse(licenses.isLicenseValid(lt, BOB));
    }

    function test_IsValid_False_WhenQueriedLicenseeIsNotCurrentOwner() public {
        // Post-transfer of a transferable license, isLicenseValid(licenseId, originalLicensee)
        // should return FALSE because _ownerOf now points at the new holder.
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.COMMERCIAL_TRANSFERABLE, BOB);
        vm.prank(BOB);
        licenses.safeTransferFrom(BOB, CAROL, lt);
        assertFalse(licenses.isLicenseValid(lt, BOB), "original licensee no longer valid after transfer");
        assertTrue(licenses.isLicenseValid(lt, CAROL), "new holder is valid");
    }

    function test_IsValid_Paused_StillReturnsTrue() public {
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
        vm.prank(GOVERNANCE);
        licenses.pause();
        assertTrue(licenses.isLicenseValid(lt, BOB), "pause does not invalidate existing grants");
    }

    function test_CheckLicenseValid_True() public {
        _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
        assertTrue(licenses.checkLicenseValid(designId, BOB));
    }

    function test_CheckLicenseValid_False_ZeroUser() public view {
        assertFalse(licenses.checkLicenseValid(designId, address(0)));
    }

    function test_CheckLicenseValid_False_NoGrants() public view {
        assertFalse(licenses.checkLicenseValid(designId, BOB));
    }

    function test_CheckLicenseValid_False_AllRevoked() public {
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
        vm.prank(ALICE);
        licenses.revokeLicense(lt, "r");
        assertFalse(licenses.checkLicenseValid(designId, BOB));
    }

    function test_CheckLicenseValid_False_AllExpired() public {
        vm.warp(1_000_000);
        _grantLicenseWithExpiry(ALICE, designId, Tmpl.OPEN_MTA, BOB, uint64(block.timestamp + 10), 0);
        vm.warp(block.timestamp + 100);
        assertFalse(licenses.checkLicenseValid(designId, BOB));
    }

    function test_CheckLicenseValid_MultipleGrants_OneValid() public {
        // Revoke the first, keep the second — still valid.
        uint256 lt1 = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
        _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
        vm.prank(ALICE);
        licenses.revokeLicense(lt1, "kill-one");
        assertTrue(licenses.checkLicenseValid(designId, BOB));
    }

    function test_GetLicense_RevertsWhen_Unknown() public {
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.UnknownToken.selector, 999));
        licenses.getLicense(999);
    }
}

// ============================================================================
// TRANSFERS
// ============================================================================

contract LicenseRegistry_Transfer_Test is LicenseRegistryHarness {
    uint256 internal designId;

    function setUp() public override {
        super.setUp();
        designId = _registerDesign(ALICE, keccak256("design-xfer"));
        _createTemplate(Tmpl.COMMERCIAL_TRANSFERABLE, SeqoraTypes.PIL_COMMERCIAL | SeqoraTypes.PIL_TRANSFERABLE, 0);
        _createTemplate(Tmpl.NON_TRANSFERABLE, SeqoraTypes.PIL_ATTRIBUTION, 0);
    }

    function test_Transferable_SafeTransferFrom_Succeeds() public {
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.COMMERCIAL_TRANSFERABLE, BOB);
        vm.prank(BOB);
        licenses.safeTransferFrom(BOB, CAROL, lt);
        assertEq(licenses.ownerOf(lt), CAROL);
        assertTrue(licenses.isLicenseValid(lt, CAROL));
    }

    function test_Transferable_ApproveAndTransferFrom_Succeeds() public {
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.COMMERCIAL_TRANSFERABLE, BOB);
        vm.prank(BOB);
        licenses.approve(DAVE, lt);
        vm.prank(DAVE);
        licenses.transferFrom(BOB, CAROL, lt);
        assertEq(licenses.ownerOf(lt), CAROL);
    }

    function test_NonTransferable_Reverts() public {
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.NON_TRANSFERABLE, BOB);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.LicenseNotTransferable.selector, lt));
        licenses.safeTransferFrom(BOB, CAROL, lt);
    }

    function test_Revoked_Transferable_Reverts() public {
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.COMMERCIAL_TRANSFERABLE, BOB);
        vm.prank(ALICE);
        licenses.revokeLicense(lt, "rev");
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ILicenseRegistry.LicenseRevokedError.selector, lt));
        licenses.safeTransferFrom(BOB, CAROL, lt);
    }

    function test_Transfer_WhilePaused_Succeeds() public {
        // Brief §6: pause halts new grants only; existing licenses keep working including transfers.
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.COMMERCIAL_TRANSFERABLE, BOB);
        vm.prank(GOVERNANCE);
        licenses.pause();
        vm.prank(BOB);
        licenses.safeTransferFrom(BOB, CAROL, lt);
        assertEq(licenses.ownerOf(lt), CAROL);
    }
}

// ============================================================================
// PAUSE
// ============================================================================

contract LicenseRegistry_Pause_Test is LicenseRegistryHarness {
    function test_Pause_OwnerHappy() public {
        vm.prank(GOVERNANCE);
        licenses.pause();
        assertTrue(licenses.paused());
        assertTrue(licenses.isPaused());
    }

    function test_Pause_RevertsWhen_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        licenses.pause();
    }

    function test_Unpause_OwnerHappy() public {
        vm.prank(GOVERNANCE);
        licenses.pause();
        vm.prank(GOVERNANCE);
        licenses.unpause();
        assertFalse(licenses.paused());
    }

    function test_Unpause_RevertsWhen_NotOwner() public {
        vm.prank(GOVERNANCE);
        licenses.pause();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        licenses.unpause();
    }
}

// ============================================================================
// RENOUNCE + FEE ROUTER + UUPS
// ============================================================================

contract LicenseRegistry_Governance_Test is LicenseRegistryHarness {
    event FeeRouterSet(address indexed prev, address indexed next);
    event UpgradeAuthorized(address indexed newImplementation);

    function test_RenounceOwnership_Reverts() public {
        vm.prank(GOVERNANCE);
        vm.expectRevert(LicenseRegistry.RenounceDisabled.selector);
        licenses.renounceOwnership();
        assertEq(licenses.owner(), GOVERNANCE, "owner unchanged");
    }

    function test_SetFeeRouter_Happy_EmitsAndStores() public {
        vm.expectEmit(true, true, false, false);
        emit FeeRouterSet(address(0), address(0xFEE));
        vm.prank(GOVERNANCE);
        licenses.setFeeRouter(address(0xFEE));
        assertEq(licenses.feeRouter(), address(0xFEE));
    }

    function test_SetFeeRouter_PrevTracked() public {
        vm.prank(GOVERNANCE);
        licenses.setFeeRouter(address(0xAAA));
        vm.expectEmit(true, true, false, false);
        emit FeeRouterSet(address(0xAAA), address(0xBBB));
        vm.prank(GOVERNANCE);
        licenses.setFeeRouter(address(0xBBB));
    }

    function test_SetFeeRouter_RevertsWhen_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        licenses.setFeeRouter(address(0xFEE));
    }

    function test_FeePaid_RecordedVerbatim_NoFundMovement() public {
        uint256 designId = _registerDesign(ALICE, keccak256("d-fee"));
        _createTemplate(Tmpl.COMMERCIAL, SeqoraTypes.PIL_COMMERCIAL, 0);

        // Set fee router; grantLicense still records fee without moving funds.
        vm.prank(GOVERNANCE);
        licenses.setFeeRouter(address(0xDEAD));

        uint256 before = address(licenses).balance;
        uint256 lt = _grantLicenseWithExpiry(ALICE, designId, Tmpl.COMMERCIAL, BOB, 0, 777);
        assertEq(licenses.getLicense(lt).feePaid, 777);
        assertEq(address(licenses).balance, before, "registry received no ETH (non-payable)");
        assertEq(address(0xDEAD).balance, 0, "feeRouter received no ETH");
    }

    function test_UpgradeToAndCall_OwnerHappy_PreservesState() public {
        // Seed pre-upgrade state.
        uint256 designId = _registerDesign(ALICE, keccak256("d-up"));
        _createTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 7);
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.OPEN_MTA, BOB);
        uint256 nextId = licenses.nextLicenseTokenId();

        LicenseRegistryV2Mock v2 = new LicenseRegistryV2Mock();
        vm.expectEmit(true, false, false, false);
        emit UpgradeAuthorized(address(v2));
        vm.prank(GOVERNANCE);
        licenses.upgradeToAndCall(address(v2), "");

        // State preserved.
        assertEq(licenses.owner(), GOVERNANCE, "owner survived");
        assertEq(licenses.ownerOf(lt), BOB, "license still owned by BOB");
        assertEq(licenses.nextLicenseTokenId(), nextId, "counter preserved");
        SeqoraTypes.LicenseTemplate memory t = licenses.getLicenseTemplate(Tmpl.OPEN_MTA);
        assertEq(t.defaultDuration, 7, "template defaults survived");

        // v2-only function now callable.
        assertEq(LicenseRegistryV2Mock(address(licenses)).v2Only(), 4242);
        assertEq(LicenseRegistryV2Mock(address(licenses)).VERSION(), "v2-mock");
    }

    function test_UpgradeToAndCall_RevertsWhen_NotOwner() public {
        LicenseRegistryV2Mock v2 = new LicenseRegistryV2Mock();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        licenses.upgradeToAndCall(address(v2), "");
    }
}

// ============================================================================
// FUZZ
// ============================================================================

contract LicenseRegistry_Fuzz_Test is LicenseRegistryHarness {
    uint256 internal designId;

    function setUp() public override {
        super.setUp();
        designId = _registerDesign(ALICE, keccak256("fuzz-design"));
        _createTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_RegisterTemplate_PilFlags(uint16 rawFlags) public {
        bytes32 id = keccak256(abi.encode("fuzz", rawFlags));
        uint16 flags = rawFlags;
        SeqoraTypes.LicenseTemplate memory t = SeqoraTypes.LicenseTemplate({
            licenseId: id,
            name: "F",
            uri: "u",
            commercialUse: (flags & SeqoraTypes.PIL_COMMERCIAL) != 0,
            requiresAttribution: (flags & SeqoraTypes.PIL_ATTRIBUTION) != 0,
            active: true,
            pilFlags: flags,
            defaultDuration: 0
        });

        bool outsideMask = (flags & ~SeqoraTypes.PIL_V1_MASK) != 0;
        bool derivWithoutAttribution =
            !outsideMask && (flags & SeqoraTypes.PIL_DERIVATIVE) != 0 && (flags & SeqoraTypes.PIL_ATTRIBUTION) == 0;

        vm.prank(GOVERNANCE);
        if (outsideMask) {
            vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.InvalidPilFlags.selector, flags));
            licenses.registerLicenseTemplate(t);
        } else if (derivWithoutAttribution) {
            vm.expectRevert(LicenseRegistry.DerivativeRequiresAttribution.selector);
            licenses.registerLicenseTemplate(t);
        } else {
            licenses.registerLicenseTemplate(t);
            assertEq(licenses.getLicenseTemplate(id).pilFlags, flags);
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_GrantLicense_AnyValidLicensee(address licensee) public {
        vm.assume(licensee != address(0));
        // Filter out precompiles/precalcs that would reject ERC721 receiver hook.
        // EOAs (no code) always accept; contracts without onERC721Received fail — assume EOA.
        vm.assume(licensee.code.length == 0);
        // Precompiles at low addresses can still break receiver hook check in weird ways — skip.
        vm.assume(uint160(licensee) > 0x1000);

        vm.prank(ALICE);
        uint256 lt = licenses.grantLicense(designId, Tmpl.OPEN_MTA, licensee, 0, 0);
        assertEq(licenses.ownerOf(lt), licensee);
        assertTrue(licenses.isLicenseValid(lt, licensee));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_LicenseLifecycle(uint64 offset, uint32 duration) public {
        // Bound inputs to sane ranges.
        uint64 grantTime = uint64(bound(offset, 1, 10 * 365 days));
        uint32 d = uint32(bound(duration, 1, 365 * 10));
        vm.warp(grantTime);

        bytes32 tid = keccak256(abi.encode("life", offset, duration));
        _createTemplate(tid, SeqoraTypes.PIL_ATTRIBUTION, d);
        uint256 lt = _grantLicense(ALICE, designId, tid, BOB);

        assertTrue(licenses.isLicenseValid(lt, BOB));
        uint64 expiry = uint64(block.timestamp) + uint64(d) * 86_400;

        // One second before expiry — still valid.
        vm.warp(uint256(expiry) - 1);
        assertTrue(licenses.isLicenseValid(lt, BOB));

        // One second after — invalid.
        vm.warp(uint256(expiry) + 1);
        assertFalse(licenses.isLicenseValid(lt, BOB));
    }
}

// ============================================================================
// checkLicenseValid reverse-index griefing resistance
// ============================================================================

contract LicenseRegistry_CheckLicenseValid_ReverseIndex_Test is LicenseRegistryHarness {
    uint256 internal victimDesign;
    uint256 internal otherDesign;

    function setUp() public override {
        super.setUp();
        victimDesign = _registerDesign(ALICE, keccak256("victim-design"));
        otherDesign = _registerDesign(CAROL, keccak256("other-design"));
        _createTemplate(Tmpl.OPEN_MTA, SeqoraTypes.PIL_ATTRIBUTION, 0);
        _createTemplate(Tmpl.COMMERCIAL_TRANSFERABLE, SeqoraTypes.PIL_COMMERCIAL | SeqoraTypes.PIL_TRANSFERABLE, 0);
    }

    /// @notice Reverse-index griefing scenario: mass-grant bogus licenses to throwaway addresses and
    ///         assert that `checkLicenseValid(victimTokenId, realUser)` remains cheap and
    ///         returns true. Pre-fix this scan was O(nextLicenseTokenId); post-fix it walks
    ///         only `_licensesOf[tokenId][realUser]`.
    function test_CheckLicenseValid_BoundedGas_UnderMassGrantGrief() public {
        // Grant the real user ONE license up front.
        uint256 realLt = _grantLicense(ALICE, victimDesign, Tmpl.OPEN_MTA, BOB);
        assertTrue(licenses.checkLicenseValid(victimDesign, BOB));

        // Griefer: 1,024 bogus grants on the same tokenId to junk addresses (enough to blow
        // gas under the old O(n) scan — a pre-fix run easily breaks the default test gas limit).
        for (uint256 i = 0; i < 1024; i++) {
            address junk = address(uint160(0x10000 + i));
            vm.prank(ALICE);
            licenses.grantLicense(victimDesign, Tmpl.OPEN_MTA, junk, 0, 0);
        }

        // Measure: single call should be well under 500k gas (walks a 1-element array for BOB).
        uint256 gasBefore = gasleft();
        bool ok = licenses.checkLicenseValid(victimDesign, BOB);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(ok, "real user remains valid");
        assertLt(gasUsed, 500_000, "checkLicenseValid must be O(per-user), not O(total)");

        // Also verify real user's license is the one known to the reverse index.
        assertEq(licenses.getLicense(realLt).licensee, BOB);
    }

    /// @notice Unrelated-tokenId griefing: bogus grants on a DIFFERENT tokenId must not affect
    ///         the victim tokenId's check for the real user.
    function test_CheckLicenseValid_IsolatedPerTokenId() public {
        _grantLicense(ALICE, victimDesign, Tmpl.OPEN_MTA, BOB);
        // 256 bogus grants on `otherDesign` to BOB himself — must not contaminate victim's query.
        for (uint256 i = 0; i < 256; i++) {
            vm.prank(CAROL);
            licenses.grantLicense(otherDesign, Tmpl.OPEN_MTA, BOB, 0, 0);
        }
        assertTrue(licenses.checkLicenseValid(victimDesign, BOB), "victim unaffected by other-design spam");
        assertTrue(licenses.checkLicenseValid(otherDesign, BOB), "other-design also valid");
    }

    /// @notice Reverse index must update on transfer so that the receiver's query returns true.
    function test_CheckLicenseValid_TransferReindexesHolder() public {
        uint256 lt = _grantLicense(ALICE, victimDesign, Tmpl.COMMERCIAL_TRANSFERABLE, BOB);

        assertTrue(licenses.checkLicenseValid(victimDesign, BOB), "BOB valid pre-transfer");
        assertFalse(licenses.checkLicenseValid(victimDesign, CAROL), "CAROL not yet");

        vm.prank(BOB);
        licenses.safeTransferFrom(BOB, CAROL, lt);

        // Post-transfer: CAROL is valid (reverse index populated via _update), BOB is not
        // (stale array entry is filtered by `_ownerOf(id) == user`).
        assertTrue(licenses.checkLicenseValid(victimDesign, CAROL), "CAROL valid post-transfer");
        assertFalse(licenses.checkLicenseValid(victimDesign, BOB), "BOB falls off via _ownerOf filter");
    }

    /// @notice Revoked and expired entries in the per-user reverse array are filtered, so the
    ///         function returns false once all entries die.
    function test_CheckLicenseValid_FiltersRevokedAndExpired() public {
        // Two grants, will revoke one and expire the other.
        uint256 a = _grantLicense(ALICE, victimDesign, Tmpl.OPEN_MTA, BOB);
        vm.warp(1_000_000);
        uint256 b = _grantLicenseWithExpiry(ALICE, victimDesign, Tmpl.OPEN_MTA, BOB, uint64(block.timestamp + 10), 0);

        assertTrue(licenses.checkLicenseValid(victimDesign, BOB));

        vm.prank(ALICE);
        licenses.revokeLicense(a, "r");
        assertTrue(licenses.checkLicenseValid(victimDesign, BOB), "still valid via b");

        vm.warp(block.timestamp + 100); // b expires
        assertFalse(licenses.checkLicenseValid(victimDesign, BOB), "both dead now");
        b; // silence unused-var lint
    }

    /// @notice Multiple grants to same user are all tracked; revoking one leaves the rest.
    function test_CheckLicenseValid_MultipleGrantsSameUser() public {
        _grantLicense(ALICE, victimDesign, Tmpl.OPEN_MTA, BOB);
        _grantLicense(ALICE, victimDesign, Tmpl.OPEN_MTA, BOB);
        uint256 third = _grantLicense(ALICE, victimDesign, Tmpl.OPEN_MTA, BOB);
        vm.prank(ALICE);
        licenses.revokeLicense(third, "only-one");
        assertTrue(licenses.checkLicenseValid(victimDesign, BOB), "remaining grants carry the bit");
    }

    /// @notice `checkLicenseValid(tokenId, 0)` must remain false — load-bearing guard.
    function test_CheckLicenseValid_ZeroUser_False() public {
        _grantLicense(ALICE, victimDesign, Tmpl.OPEN_MTA, BOB);
        assertFalse(licenses.checkLicenseValid(victimDesign, address(0)));
    }
}

// ============================================================================
// approve / setApprovalForAll on non-transferable licenses
// ============================================================================

contract LicenseRegistry_Approve_NonTransferable_Test is LicenseRegistryHarness {
    uint256 internal designId;

    function setUp() public override {
        super.setUp();
        designId = _registerDesign(ALICE, keccak256("approve-design"));
        _createTemplate(Tmpl.NON_TRANSFERABLE, SeqoraTypes.PIL_ATTRIBUTION, 0);
        _createTemplate(Tmpl.COMMERCIAL_TRANSFERABLE, SeqoraTypes.PIL_COMMERCIAL | SeqoraTypes.PIL_TRANSFERABLE, 0);
    }

    function test_Approve_NonTransferable_Reverts() public {
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.NON_TRANSFERABLE, BOB);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.LicenseNotTransferable.selector, lt));
        licenses.approve(CAROL, lt);
    }

    function test_Approve_Transferable_Succeeds() public {
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.COMMERCIAL_TRANSFERABLE, BOB);
        vm.prank(BOB);
        licenses.approve(CAROL, lt);
        assertEq(licenses.getApproved(lt), CAROL, "approval recorded for transferable license");
    }

    function test_Approve_ToZero_Succeeds_EvenOnNonTransferable() public {
        // Clearing the approval (to == 0) is always allowed so users can reset stale state.
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.NON_TRANSFERABLE, BOB);
        vm.prank(BOB);
        licenses.approve(address(0), lt);
        assertEq(licenses.getApproved(lt), address(0));
    }

    /// @notice `setApprovalForAll` is documented to NOT be overridden — it succeeds and is a
    ///         no-op for non-transferable licenses because the actual transfer still reverts
    ///         at the `_update` gate. This test pins the documented behaviour.
    function test_SetApprovalForAll_NotOverridden_TransferStillBlocked() public {
        uint256 lt = _grantLicense(ALICE, designId, Tmpl.NON_TRANSFERABLE, BOB);

        // operator-level approval succeeds (non-transferable approval passthrough behaviour).
        vm.prank(BOB);
        licenses.setApprovalForAll(CAROL, true);
        assertTrue(licenses.isApprovedForAll(BOB, CAROL));

        // But an attempted transfer still reverts at the _update seam.
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.LicenseNotTransferable.selector, lt));
        licenses.transferFrom(BOB, DAVE, lt);
    }
}

// ============================================================================
// defaultDuration cap + per-grant expiry cap
// ============================================================================

contract LicenseRegistry_DurationCap_Test is LicenseRegistryHarness {
    uint256 internal designId;

    uint32 internal constant MAX_DAYS = 100 * 365;

    function setUp() public override {
        super.setUp();
        designId = _registerDesign(ALICE, keccak256("duration-design"));
    }

    function test_RegisterTemplate_DurationAtMax_Succeeds() public {
        bytes32 id = keccak256("T_MAX");
        _createTemplate(id, SeqoraTypes.PIL_ATTRIBUTION, MAX_DAYS);
        assertEq(licenses.getLicenseTemplate(id).defaultDuration, MAX_DAYS);
    }

    function test_RegisterTemplate_DurationAboveMax_Reverts() public {
        uint32 bad = MAX_DAYS + 1;
        SeqoraTypes.LicenseTemplate memory t = _buildTemplate(keccak256("T_BAD"), SeqoraTypes.PIL_ATTRIBUTION, bad);
        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.DurationTooLong.selector, bad, MAX_DAYS));
        licenses.registerLicenseTemplate(t);
    }

    function test_RegisterTemplate_DurationZero_AllowedAsPerpetual() public {
        bytes32 id = keccak256("T_PERP");
        _createTemplate(id, SeqoraTypes.PIL_ATTRIBUTION, 0);
        assertEq(licenses.getLicenseTemplate(id).defaultDuration, 0);
    }

    function test_RegisterTemplate_DurationMaxUint32_Reverts() public {
        uint32 bad = type(uint32).max;
        SeqoraTypes.LicenseTemplate memory t = _buildTemplate(keccak256("T_INF"), SeqoraTypes.PIL_ATTRIBUTION, bad);
        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.DurationTooLong.selector, bad, MAX_DAYS));
        licenses.registerLicenseTemplate(t);
    }

    function test_Grant_PerpetualViaZeroDuration_Works() public {
        bytes32 id = keccak256("T_ZERODUR");
        _createTemplate(id, SeqoraTypes.PIL_ATTRIBUTION, 0);
        // expiry = 0 + defaultDuration = 0 → perpetual
        uint256 lt = _grantLicense(ALICE, designId, id, BOB);
        assertEq(licenses.getLicense(lt).expiry, 0, "perpetual grant");
        assertTrue(licenses.isLicenseValid(lt, BOB));
    }

    function test_Grant_ExpiryWithinMax_Succeeds() public {
        bytes32 id = keccak256("T_E_OK");
        _createTemplate(id, SeqoraTypes.PIL_ATTRIBUTION, 0);
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp) + uint64(SeqoraTypes.MAX_LICENSE_DURATION);
        uint256 lt = _grantLicenseWithExpiry(ALICE, designId, id, BOB, expiry, 0);
        assertEq(licenses.getLicense(lt).expiry, expiry);
    }

    function test_Grant_ExpiryOverMax_Reverts() public {
        bytes32 id = keccak256("T_E_BAD");
        _createTemplate(id, SeqoraTypes.PIL_ATTRIBUTION, 0);
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp) + uint64(SeqoraTypes.MAX_LICENSE_DURATION) + 1;
        vm.prank(ALICE);
        // Exact supplied days = MAX_DAYS (integer-floor of the 1-second overflow).
        vm.expectRevert(abi.encodeWithSelector(LicenseRegistry.DurationTooLong.selector, MAX_DAYS, MAX_DAYS));
        licenses.grantLicense(designId, id, BOB, expiry, 0);
    }
}
