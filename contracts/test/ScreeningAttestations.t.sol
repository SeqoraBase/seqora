// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { IEAS } from "eas-contracts/IEAS.sol";
import { Attestation } from "eas-contracts/Common.sol";

import { ScreeningAttestations } from "../src/ScreeningAttestations.sol";
import { IScreeningAttestations } from "../src/interfaces/IScreeningAttestations.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";
import { SeqoraErrors } from "../src/libraries/SeqoraErrors.sol";

import { MockEAS } from "./helpers/MockEAS.sol";

// =============================================================================
// Shared harness
// =============================================================================

abstract contract ScreeningAttestationsBase is Test {
    address internal constant OWNER = address(0x01010101);
    address internal constant ATTESTER = address(0xAA11);
    address internal constant OTHER_ATTESTER = address(0xAA22);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant RELAYER = address(0xBEEF);

    bytes32 internal constant SCHEMA_UID = bytes32(uint256(0x5C4EEA));
    bytes32 internal constant OTHER_SCHEMA = bytes32(uint256(0xBAD5));

    MockEAS internal eas;
    ScreeningAttestations internal screening;

    function setUp() public virtual {
        eas = new MockEAS();
        screening = new ScreeningAttestations(IEAS(address(eas)), SCHEMA_UID, OWNER);
        vm.label(address(eas), "MockEAS");
        vm.label(address(screening), "ScreeningAttestations");
        vm.label(OWNER, "OWNER");
        vm.label(ATTESTER, "ATTESTER");
        vm.label(ALICE, "ALICE");
        vm.label(BOB, "BOB");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @notice Build a well-formed attestation that would pass all `isValid` checks.
    function _goodAttestation(bytes32 uid, bytes32 canonicalHash, address registrant, address attester)
        internal
        view
        returns (Attestation memory att)
    {
        att = Attestation({
            uid: uid,
            schema: SCHEMA_UID,
            time: uint64(block.timestamp),
            expirationTime: 0,
            revocationTime: 0,
            refUID: bytes32(0),
            recipient: registrant,
            attester: attester,
            revocable: true,
            data: abi.encode(
                canonicalHash,
                registrant,
                uint8(SeqoraTypes.ScreenerKind.IGSC),
                uint64(block.timestamp),
                bytes32(uint256(0xC0DE))
            )
        });
    }

    function _seedAttestation(bytes32 uid, bytes32 canonicalHash, address registrant, address attester)
        internal
        returns (Attestation memory att)
    {
        att = _goodAttestation(uid, canonicalHash, registrant, attester);
        eas.setAttestation(uid, att);
    }

    function _registerDefaultAttester() internal {
        vm.prank(OWNER);
        screening.registerAttester(ATTESTER, SeqoraTypes.ScreenerKind.IGSC);
    }
}

// =============================================================================
// UNIT — constructor
// =============================================================================

contract ScreeningAttestations_Constructor_Test is ScreeningAttestationsBase {
    function test_Constructor_SetsState() public view {
        assertEq(address(screening.eas()), address(eas), "eas stored");
        assertEq(screening.schemaUID(), SCHEMA_UID, "schema stored");
        assertEq(screening.owner(), OWNER, "owner stored");
        assertFalse(screening.paused(), "not paused on deploy");
    }

    function test_Constructor_EmitsEASContractSet() public {
        vm.expectEmit(true, true, false, false);
        emit ScreeningAttestations.EASContractSet(address(0), address(eas));
        // Re-emit via a fresh deploy to capture the event cleanly.
        // Note: second emit test covers SchemaUIDSet separately.
        new ScreeningAttestations(IEAS(address(eas)), SCHEMA_UID, OWNER);
    }

    function test_Constructor_EmitsSchemaUIDSet() public {
        vm.expectEmit(false, false, false, true);
        emit ScreeningAttestations.SchemaUIDSet(bytes32(0), SCHEMA_UID);
        new ScreeningAttestations(IEAS(address(eas)), SCHEMA_UID, OWNER);
    }

    function test_Constructor_RevertsWhen_EASZero() public {
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        new ScreeningAttestations(IEAS(address(0)), SCHEMA_UID, OWNER);
    }

    function test_Constructor_RevertsWhen_SchemaZero() public {
        vm.expectRevert(SeqoraErrors.ZeroValue.selector);
        new ScreeningAttestations(IEAS(address(eas)), bytes32(0), OWNER);
    }
}

// =============================================================================
// UNIT — registerAttester
// =============================================================================

contract ScreeningAttestations_RegisterAttester_Test is ScreeningAttestationsBase {
    function test_RegisterAttester_Happy_EmitsAndStores() public {
        vm.expectEmit(true, false, false, true);
        emit IScreeningAttestations.AttesterRegistered(ATTESTER, SeqoraTypes.ScreenerKind.IGSC);
        vm.prank(OWNER);
        screening.registerAttester(ATTESTER, SeqoraTypes.ScreenerKind.IGSC);

        assertTrue(screening.isApproved(ATTESTER), "approved after register");
        assertTrue(screening.isApprovedAttester(ATTESTER), "alias matches");
        assertEq(uint8(screening.getScreenerKind(ATTESTER)), uint8(SeqoraTypes.ScreenerKind.IGSC), "kind stored");
    }

    function test_RegisterAttester_RevertsWhen_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        screening.registerAttester(ATTESTER, SeqoraTypes.ScreenerKind.IGSC);
    }

    function test_RegisterAttester_RevertsWhen_ZeroAddress() public {
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        vm.prank(OWNER);
        screening.registerAttester(address(0), SeqoraTypes.ScreenerKind.IGSC);
    }

    function test_RegisterAttester_RevertsWhen_UnknownKind() public {
        vm.expectRevert(IScreeningAttestations.UnknownScreenerKind.selector);
        vm.prank(OWNER);
        screening.registerAttester(ATTESTER, SeqoraTypes.ScreenerKind.Unknown);
    }

    function test_RegisterAttester_DuplicateReregistrationOverwritesKind() public {
        // Current impl allows re-registration (no dedicated "already registered" guard). Document
        // the behavior: a second registerAttester call with a different kind simply overwrites.
        vm.prank(OWNER);
        screening.registerAttester(ATTESTER, SeqoraTypes.ScreenerKind.IGSC);
        vm.prank(OWNER);
        screening.registerAttester(ATTESTER, SeqoraTypes.ScreenerKind.IBBIS);
        assertEq(uint8(screening.getScreenerKind(ATTESTER)), uint8(SeqoraTypes.ScreenerKind.IBBIS));
    }
}

// =============================================================================
// UNIT — revokeAttester
// =============================================================================

contract ScreeningAttestations_RevokeAttester_Test is ScreeningAttestationsBase {
    function test_RevokeAttester_Happy_EmitsAndClears() public {
        _registerDefaultAttester();

        vm.expectEmit(true, false, false, true);
        emit IScreeningAttestations.AttesterRevoked(ATTESTER, "compromised");
        vm.prank(OWNER);
        screening.revokeAttester(ATTESTER, "compromised");

        assertFalse(screening.isApproved(ATTESTER), "no longer approved");
        assertEq(uint8(screening.getScreenerKind(ATTESTER)), uint8(SeqoraTypes.ScreenerKind.Unknown));
    }

    function test_RevokeAttester_RevertsWhen_NotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(ScreeningAttestations.UnknownAttester.selector, ATTESTER));
        vm.prank(OWNER);
        screening.revokeAttester(ATTESTER, "never registered");
    }

    function test_RevokeAttester_RevertsWhen_NotOwner() public {
        _registerDefaultAttester();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        screening.revokeAttester(ATTESTER, "r");
    }
}

// =============================================================================
// UNIT — localRevoke
// =============================================================================

contract ScreeningAttestations_LocalRevoke_Test is ScreeningAttestationsBase {
    bytes32 internal constant UID = bytes32(uint256(0x4E5D));

    function test_LocalRevoke_Happy_EmitsAndMarks() public {
        vm.expectEmit(true, true, false, false);
        emit ScreeningAttestations.LocalRevocation(UID, OWNER);
        vm.prank(OWNER);
        screening.localRevoke(UID);
        assertTrue(screening.locallyRevoked(UID));
    }

    function test_LocalRevoke_IsIdempotent() public {
        vm.prank(OWNER);
        screening.localRevoke(UID);
        // Second call is a no-op — no revert, no event.
        vm.prank(OWNER);
        screening.localRevoke(UID);
        assertTrue(screening.locallyRevoked(UID));
    }

    function test_LocalRevoke_RevertsWhen_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        screening.localRevoke(UID);
    }

    function test_LocalRevoke_RevertsWhen_ZeroUID() public {
        vm.expectRevert(SeqoraErrors.ZeroValue.selector);
        vm.prank(OWNER);
        screening.localRevoke(bytes32(0));
    }

    function test_LocalRevoke_OnceRevoked_IsValidReturnsFalseForever() public {
        _registerDefaultAttester();
        bytes32 uid = bytes32(uint256(0x0BE5));
        bytes32 canonicalHash = keccak256("ch");
        _seedAttestation(uid, canonicalHash, ALICE, ATTESTER);
        assertTrue(screening.isValid(uid, canonicalHash, ALICE), "sanity: valid before revoke");

        vm.prank(OWNER);
        screening.localRevoke(uid);
        assertFalse(screening.isValid(uid, canonicalHash, ALICE), "invalid after local revoke");
    }
}

// =============================================================================
// UNIT — setEAS / setSchemaUID
// =============================================================================

contract ScreeningAttestations_Setters_Test is ScreeningAttestationsBase {
    function test_SetEAS_Happy_EmitsAndUpdates() public {
        MockEAS other = new MockEAS();
        vm.expectEmit(true, true, false, false);
        emit ScreeningAttestations.EASContractSet(address(eas), address(other));
        vm.prank(OWNER);
        screening.setEAS(IEAS(address(other)));
        assertEq(address(screening.eas()), address(other));
    }

    function test_SetEAS_RevertsWhen_NotOwner() public {
        MockEAS other = new MockEAS();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        screening.setEAS(IEAS(address(other)));
    }

    function test_SetEAS_RevertsWhen_Zero() public {
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        vm.prank(OWNER);
        screening.setEAS(IEAS(address(0)));
    }

    function test_SetSchemaUID_Happy_EmitsAndUpdates() public {
        bytes32 newSchema = bytes32(uint256(0xBEEF));
        vm.expectEmit(false, false, false, true);
        emit ScreeningAttestations.SchemaUIDSet(SCHEMA_UID, newSchema);
        vm.prank(OWNER);
        screening.setSchemaUID(newSchema);
        assertEq(screening.schemaUID(), newSchema);
    }

    function test_SetSchemaUID_RevertsWhen_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        screening.setSchemaUID(bytes32(uint256(1)));
    }

    function test_SetSchemaUID_RevertsWhen_Zero() public {
        vm.expectRevert(SeqoraErrors.ZeroValue.selector);
        vm.prank(OWNER);
        screening.setSchemaUID(bytes32(0));
    }
}

// =============================================================================
// UNIT — pause / unpause
// =============================================================================

contract ScreeningAttestations_Pause_Test is ScreeningAttestationsBase {
    function test_RenounceOwnership_Reverts() public {
        // L-04 regression: owner's renounceOwnership must revert with RenounceDisabled and
        // leave ownership unchanged. Prevents permanent governance bricking.
        address ownerBefore = screening.owner();
        assertEq(ownerBefore, OWNER, "precondition: OWNER is the current owner");
        vm.prank(OWNER);
        vm.expectRevert(ScreeningAttestations.RenounceDisabled.selector);
        screening.renounceOwnership();
        assertEq(screening.owner(), ownerBefore, "owner unchanged after failed renounce");
    }

    function test_Pause_Happy() public {
        vm.prank(OWNER);
        screening.pause();
        assertTrue(screening.paused());
    }

    function test_Pause_RevertsWhen_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        screening.pause();
    }

    function test_Unpause_Happy() public {
        vm.prank(OWNER);
        screening.pause();
        vm.prank(OWNER);
        screening.unpause();
        assertFalse(screening.paused());
    }

    function test_Unpause_RevertsWhen_NotOwner() public {
        vm.prank(OWNER);
        screening.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        screening.unpause();
    }
}

// =============================================================================
// UNIT — isValid (happy + full revert/false matrix)
// =============================================================================

contract ScreeningAttestations_IsValid_Test is ScreeningAttestationsBase {
    bytes32 internal constant UID = bytes32(uint256(0x0F0F));
    bytes32 internal canonicalHash;

    function setUp() public override {
        super.setUp();
        canonicalHash = keccak256("canonical");
        _registerDefaultAttester();
    }

    function test_IsValid_Happy_AllChecksPass() public {
        _seedAttestation(UID, canonicalHash, ALICE, ATTESTER);
        assertTrue(screening.isValid(UID, canonicalHash, ALICE));
    }

    function test_IsValid_FalseWhen_Paused() public {
        _seedAttestation(UID, canonicalHash, ALICE, ATTESTER);
        vm.prank(OWNER);
        screening.pause();
        assertFalse(screening.isValid(UID, canonicalHash, ALICE));
    }

    function test_IsValid_FalseWhen_LocallyRevoked() public {
        _seedAttestation(UID, canonicalHash, ALICE, ATTESTER);
        vm.prank(OWNER);
        screening.localRevoke(UID);
        assertFalse(screening.isValid(UID, canonicalHash, ALICE));
    }

    function test_IsValid_FalseWhen_UnknownUID() public {
        // No seed — EAS returns a zero-initialized struct with schema == 0.
        assertFalse(screening.isValid(UID, canonicalHash, ALICE));
    }

    function test_IsValid_FalseWhen_SchemaMismatch() public {
        Attestation memory att = _goodAttestation(UID, canonicalHash, ALICE, ATTESTER);
        att.schema = OTHER_SCHEMA;
        eas.setAttestation(UID, att);
        assertFalse(screening.isValid(UID, canonicalHash, ALICE));
    }

    function test_IsValid_FalseWhen_EASRevoked() public {
        Attestation memory att = _goodAttestation(UID, canonicalHash, ALICE, ATTESTER);
        att.revocationTime = uint64(block.timestamp);
        eas.setAttestation(UID, att);
        assertFalse(screening.isValid(UID, canonicalHash, ALICE));
    }

    function test_IsValid_FalseWhen_Expired() public {
        vm.warp(1_000_000);
        Attestation memory att = _goodAttestation(UID, canonicalHash, ALICE, ATTESTER);
        att.expirationTime = uint64(block.timestamp - 1);
        eas.setAttestation(UID, att);
        assertFalse(screening.isValid(UID, canonicalHash, ALICE));
    }

    function test_IsValid_TrueWhen_ExpirationEqualsNow() public {
        // Boundary: expirationTime == block.timestamp. The impl uses `<` so equality still passes.
        // Documented behavior (spec: expired iff strictly less than now).
        vm.warp(1_000_000);
        Attestation memory att = _goodAttestation(UID, canonicalHash, ALICE, ATTESTER);
        att.expirationTime = uint64(block.timestamp);
        eas.setAttestation(UID, att);
        assertTrue(screening.isValid(UID, canonicalHash, ALICE), "equal-to-now must still be valid");
    }

    function test_IsValid_FalseWhen_AttesterNotApproved() public {
        Attestation memory att = _goodAttestation(UID, canonicalHash, ALICE, OTHER_ATTESTER);
        eas.setAttestation(UID, att);
        assertFalse(screening.isValid(UID, canonicalHash, ALICE));
    }

    function test_IsValid_FalseWhen_CanonicalHashMismatch() public {
        _seedAttestation(UID, canonicalHash, ALICE, ATTESTER);
        bytes32 wrongHash = keccak256("wrong");
        assertFalse(screening.isValid(UID, wrongHash, ALICE));
    }

    function test_IsValid_FalseWhen_RegistrantMismatch() public {
        _seedAttestation(UID, canonicalHash, ALICE, ATTESTER);
        assertFalse(screening.isValid(UID, canonicalHash, BOB));
    }

    function test_IsValid_FalseWhen_MalformedData_TooShort() public {
        Attestation memory att = _goodAttestation(UID, canonicalHash, ALICE, ATTESTER);
        att.data = abi.encodePacked(canonicalHash); // only 32 bytes < 160
        eas.setAttestation(UID, att);
        assertFalse(screening.isValid(UID, canonicalHash, ALICE));
    }

    function test_IsValid_TrueWhen_FutureExpiration() public {
        vm.warp(1_000_000);
        Attestation memory att = _goodAttestation(UID, canonicalHash, ALICE, ATTESTER);
        att.expirationTime = uint64(block.timestamp + 3600);
        eas.setAttestation(UID, att);
        assertTrue(screening.isValid(UID, canonicalHash, ALICE));
    }
}

// =============================================================================
// FUZZ — registrant binding (H-01 core property)
// =============================================================================

contract ScreeningAttestations_Fuzz_Test is ScreeningAttestationsBase {
    function setUp() public override {
        super.setUp();
        _registerDefaultAttester();
    }

    function testFuzz_isValid_RegistrantBinding(address attacker, address victim, bytes32 uid, bytes32 canonicalHash)
        public
    {
        vm.assume(attacker != victim);
        vm.assume(attacker != address(0) && victim != address(0));
        vm.assume(uid != bytes32(0));
        vm.assume(canonicalHash != bytes32(0));

        // Attestation issued to `victim`.
        _seedAttestation(uid, canonicalHash, victim, ATTESTER);

        // Queried with `attacker` as registrant — must return false.
        assertFalse(screening.isValid(uid, canonicalHash, attacker), "attacker cannot masquerade as victim");
        // Sanity: queried with `victim` — must return true.
        assertTrue(screening.isValid(uid, canonicalHash, victim));
    }
}

// =============================================================================
// INVARIANT — attester set & local revocation monotonicity
// =============================================================================

contract ScreeningAttestations_AttesterInvariant_Test is ScreeningAttestationsBase {
    // Snapshot of attesters we've registered via handler calls.
    address[] internal approvedSet;
    bytes32[] internal revokedUids;
    bytes32 internal trackedUid = bytes32(uint256(0xDEAD));
    bytes32 internal trackedHash;
    address internal trackedRegistrant;

    function setUp() public override {
        super.setUp();
        trackedHash = keccak256("inv-tracked");
        trackedRegistrant = ALICE;
        _registerDefaultAttester();
        approvedSet.push(ATTESTER);
        // Seed a valid attestation we'll try to keep checking.
        _seedAttestation(trackedUid, trackedHash, trackedRegistrant, ATTESTER);
        // Narrow invariant target to the screening contract only (don't spin on MockEAS reverts).
        targetContract(address(screening));
        // Exclude ownership-transfer selectors so fuzzing cannot rotate the owner and block state
        // mutations for the remainder of the run.
        bytes4[] memory excluded = new bytes4[](2);
        excluded[0] = bytes4(keccak256("transferOwnership(address)"));
        excluded[1] = bytes4(keccak256("renounceOwnership()"));
        excludeSelector(FuzzSelector({ addr: address(screening), selectors: excluded }));
    }

    /// @notice For every attester we registered, isApprovedAttester must agree (until revoke).
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 32
    function invariant_ApprovedSetConsistent() public view {
        for (uint256 i = 0; i < approvedSet.length; i++) {
            assertTrue(screening.isApprovedAttester(approvedSet[i]), "registered attester must remain approved");
        }
    }
}

// =============================================================================
// INVARIANT — once localRevoke(uid) is called, isValid(uid, ...) never returns true again
// =============================================================================

contract ScreeningAttestations_LocalRevokeMonotonicity_Test is ScreeningAttestationsBase {
    bytes32 internal constant UID = bytes32(uint256(0xABC1));
    bytes32 internal canonicalHash;

    function setUp() public override {
        super.setUp();
        canonicalHash = keccak256("mono");
        _registerDefaultAttester();
        _seedAttestation(UID, canonicalHash, ALICE, ATTESTER);
        vm.prank(OWNER);
        screening.localRevoke(UID);
    }

    /// @notice After localRevoke, no subsequent call to isValid(UID, any, any) returns true.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 32
    function invariant_LocalRevokeIsTerminal() public view {
        assertFalse(screening.isValid(UID, canonicalHash, ALICE));
        assertFalse(screening.isValid(UID, canonicalHash, BOB));
        assertFalse(screening.isValid(UID, keccak256("other"), ALICE));
    }
}
