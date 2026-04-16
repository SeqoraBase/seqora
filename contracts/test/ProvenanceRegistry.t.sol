// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { BaseTest } from "./helpers/BaseTest.sol";
import { ProvenanceSigning } from "./helpers/ProvenanceSigning.sol";

import { ProvenanceRegistry } from "../src/ProvenanceRegistry.sol";
import { IProvenanceRegistry } from "../src/interfaces/IProvenanceRegistry.sol";
import { IDesignRegistry } from "../src/interfaces/IDesignRegistry.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";
import { SeqoraErrors } from "../src/libraries/SeqoraErrors.sol";

// ============================================================================
// SHARED HARNESS
// ============================================================================

/// @dev Base harness shared by every ProvenanceRegistry test suite. Registers a single genesis
///      tokenId by ALICE and pre-approves a canonical oracle wallet.
abstract contract ProvHarness is BaseTest {
    using ProvenanceSigning for ProvenanceRegistry;

    ProvenanceRegistry internal provenance;

    address internal constant OWNER = address(0x0AFE);

    // Canonical contributor (for ModelCard signing).
    uint256 internal constant CONTRIB_PK = 0xC0FFEE;
    address internal contributor;

    // Canonical oracle (for WetLabAttestation signing).
    uint256 internal constant ORACLE_PK = 0xFACADE;
    address internal oracle;

    // Second approved oracle used for multi-oracle assertions.
    uint256 internal constant ORACLE2_PK = 0xBEEF01;
    address internal oracle2;

    // Stranger for negative-auth tests.
    address internal constant STRANGER = address(0xDEAD);

    // Pre-registered genesis tokenId available to every test.
    uint256 internal TOKEN_A;

    function setUp() public virtual override {
        super.setUp();
        contributor = vm.addr(CONTRIB_PK);
        oracle = vm.addr(ORACLE_PK);
        oracle2 = vm.addr(ORACLE2_PK);

        provenance = new ProvenanceRegistry(registry, OWNER);
        vm.prank(OWNER);
        provenance.registerOracle(oracle);
        vm.prank(OWNER);
        provenance.registerOracle(oracle2);

        TOKEN_A = _registerGenesis(ALICE, keccak256("genesis-A"));

        vm.label(address(provenance), "ProvenanceRegistry");
        vm.label(OWNER, "OWNER");
        vm.label(contributor, "CONTRIBUTOR");
        vm.label(oracle, "ORACLE");
        vm.label(oracle2, "ORACLE2");
        vm.label(STRANGER, "STRANGER");
    }

    // -------------------------------------------------------------------------
    // Builders
    // -------------------------------------------------------------------------

    function _card(address contrib_, bytes32 salt) internal view returns (SeqoraTypes.ModelCard memory card) {
        card = SeqoraTypes.ModelCard({
            weightsHash: keccak256(abi.encode("weights", salt)),
            promptHash: keccak256(abi.encode("prompt", salt)),
            seed: salt,
            toolName: "RFdiffusion",
            toolVersion: "1.2.0",
            contributor: contrib_,
            createdAt: uint64(block.timestamp)
        });
    }

    function _att(address oracle_, bytes32 salt) internal view returns (SeqoraTypes.WetLabAttestation memory att) {
        att = SeqoraTypes.WetLabAttestation({
            oracle: oracle_,
            vendor: "Twist Bioscience",
            orderRef: "TW-0001",
            synthesizedAt: uint64(block.timestamp),
            payloadHash: keccak256(abi.encode("payload", salt))
        });
    }
}

// ============================================================================
// CONSTRUCTOR
// ============================================================================

contract ProvenanceRegistry_Constructor_Test is ProvHarness {
    function test_Constructor_SetsDesignRegistryAndOwner() public view {
        assertEq(address(provenance.designRegistry()), address(registry), "designRegistry stored");
        assertEq(provenance.owner(), OWNER, "owner set");
        assertFalse(provenance.paused(), "not paused");
    }

    function test_Constructor_TypehashStringsAreStable() public view {
        assertEq(
            provenance.MODEL_CARD_TYPEHASH(),
            keccak256(
                "ModelCard(bytes32 weightsHash,bytes32 promptHash,bytes32 seed,string toolName,string toolVersion,address contributor,uint64 createdAt)"
            ),
            "MODEL_CARD_TYPEHASH"
        );
        assertEq(
            provenance.WET_LAB_ATTESTATION_TYPEHASH(),
            keccak256(
                "WetLabAttestation(address oracle,string vendor,string orderRef,uint64 synthesizedAt,bytes32 payloadHash)"
            ),
            "WET_LAB_ATTESTATION_TYPEHASH"
        );
    }

    function test_Constructor_MaxPageLimitIsHundred() public view {
        assertEq(provenance.MAX_PAGE_LIMIT(), 100);
    }

    function test_Constructor_RevertsWhen_ZeroRegistry() public {
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        new ProvenanceRegistry(IDesignRegistry(address(0)), OWNER);
    }

    function test_Constructor_RevertsWhen_ZeroOwner() public {
        // Ownable reverts with OwnableInvalidOwner(0).
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ProvenanceRegistry(registry, address(0));
    }
}

// ============================================================================
// recordModelCard — happy + revert + event
// ============================================================================

contract ProvenanceRegistry_RecordModelCard_Test is ProvHarness {
    using ProvenanceSigning for ProvenanceRegistry;

    function test_RecordModelCard_Happy_StoresAndEmits() public {
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("mc-1"));
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        bytes32 digest = provenance.modelCardDigest(card);

        vm.expectEmit(true, true, true, true, address(provenance));
        emit IProvenanceRegistry.ModelCardRecorded(TOKEN_A, digest, contributor);

        vm.prank(STRANGER); // relayer flow — msg.sender is unrestricted
        provenance.recordModelCard(TOKEN_A, card, sig);

        assertEq(provenance.getRecordCount(TOKEN_A), 1);
        assertEq(provenance.provenanceCount(TOKEN_A), 1);
        assertTrue(provenance.isRecordValid(TOKEN_A, digest));

        SeqoraTypes.ProvenanceRecord[] memory all = provenance.getProvenance(TOKEN_A);
        assertEq(all.length, 1);
        assertEq(uint256(all[0].kind), uint256(SeqoraTypes.ProvenanceKind.ModelCard));
        assertEq(all[0].recordHash, digest);
        assertEq(all[0].submitter, contributor);
        assertEq(all[0].recordedAt, uint64(block.timestamp));
    }

    function test_RecordModelCard_RevertsWhen_ZeroContributor() public {
        SeqoraTypes.ModelCard memory card = _card(address(0), keccak256("mc-zero"));
        // Sign with something — auth check happens before signature check.
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        provenance.recordModelCard(TOKEN_A, card, sig);
    }

    function test_RecordModelCard_RevertsWhen_UnknownToken() public {
        uint256 unknownId = uint256(keccak256("never-registered"));
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("mc-unknown"));
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.UnknownToken.selector, unknownId));
        provenance.recordModelCard(unknownId, card, sig);
    }

    function test_RecordModelCard_RevertsWhen_SignerMismatch() public {
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("mc-mismatch"));
        // Sign with a different private key — recovery yields a different address.
        bytes memory badSig = ProvenanceSigning.signModelCard(ORACLE_PK, card, provenance);
        vm.expectRevert(IProvenanceRegistry.InvalidSignature.selector);
        provenance.recordModelCard(TOKEN_A, card, badSig);
    }

    function test_RecordModelCard_RevertsWhen_WrongTypehash() public {
        // Signer used a wrong typehash (e.g. WET_LAB_ATTESTATION_TYPEHASH) → recovered address
        // won't match card.contributor.
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("mc-wrong-type"));
        bytes32 badStructHash = keccak256(
            abi.encode(
                provenance.WET_LAB_ATTESTATION_TYPEHASH(),
                card.weightsHash,
                card.promptHash,
                card.seed,
                keccak256(bytes(card.toolName)),
                keccak256(bytes(card.toolVersion)),
                card.contributor,
                card.createdAt
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", provenance.domainSeparator(), badStructHash));
        bytes memory sig = ProvenanceSigning.signDigest(CONTRIB_PK, digest);
        vm.expectRevert(IProvenanceRegistry.InvalidSignature.selector);
        provenance.recordModelCard(TOKEN_A, card, sig);
    }

    function test_RecordModelCard_RevertsWhen_TamperedField() public {
        // Sign the original card; submit a card with one field flipped. Digest recomputed from
        // the submitted card differs → recovered signer != original contributor.
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("mc-tamper"));
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        card.seed = keccak256("tampered");
        vm.expectRevert(IProvenanceRegistry.InvalidSignature.selector);
        provenance.recordModelCard(TOKEN_A, card, sig);
    }

    function test_RecordModelCard_RevertsWhen_Duplicate() public {
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("mc-dup"));
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        bytes32 digest = provenance.modelCardDigest(card);

        provenance.recordModelCard(TOKEN_A, card, sig);
        vm.expectRevert(abi.encodeWithSelector(IProvenanceRegistry.DuplicateProvenance.selector, TOKEN_A, digest));
        provenance.recordModelCard(TOKEN_A, card, sig);
    }

    function test_RecordModelCard_SameCardAcrossTokenIds_IsAllowed() public {
        // Same canonical ModelCard can be recorded against multiple tokenIds — this is
        // intentional per the contract's threat-model header (§1).
        uint256 tokenB = _registerGenesis(BOB, keccak256("genesis-B"));
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("mc-cross"));
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);

        provenance.recordModelCard(TOKEN_A, card, sig);
        provenance.recordModelCard(tokenB, card, sig);

        bytes32 digest = provenance.modelCardDigest(card);
        assertTrue(provenance.isRecordValid(TOKEN_A, digest));
        assertTrue(provenance.isRecordValid(tokenB, digest));
        assertEq(provenance.getRecordCount(TOKEN_A), 1);
        assertEq(provenance.getRecordCount(tokenB), 1);
    }

    function test_RecordModelCard_RevertsWhen_Paused() public {
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("mc-paused"));
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        vm.prank(OWNER);
        provenance.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        provenance.recordModelCard(TOKEN_A, card, sig);
    }

    function test_RecordModelCard_AfterLocalRevoke_DuplicateStillReverts() public {
        // Document behavior: once recorded + locally revoked, resubmission reverts
        // DuplicateProvenance (NOT the revoke state) because _seenRecord flag stays true.
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("mc-revoke"));
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        bytes32 digest = provenance.modelCardDigest(card);

        provenance.recordModelCard(TOKEN_A, card, sig);
        vm.prank(OWNER);
        provenance.localRevoke(TOKEN_A, digest);

        assertFalse(provenance.isRecordValid(TOKEN_A, digest), "revoked => invalid");
        vm.expectRevert(abi.encodeWithSelector(IProvenanceRegistry.DuplicateProvenance.selector, TOKEN_A, digest));
        provenance.recordModelCard(TOKEN_A, card, sig);
    }

    function test_RecordModelCard_BadSignatureLength_Reverts() public {
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("mc-badlen"));
        bytes memory shortSig = hex"deadbeef";
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 4));
        provenance.recordModelCard(TOKEN_A, card, shortSig);
    }
}

// ============================================================================
// recordWetLabAttestation — happy + revert + event + CROSS-TOKENID replay
// ============================================================================

contract ProvenanceRegistry_RecordWetLab_Test is ProvHarness {
    using ProvenanceSigning for ProvenanceRegistry;

    function test_RecordWetLab_Happy_StoresAndEmits() public {
        SeqoraTypes.WetLabAttestation memory att = _att(oracle, keccak256("wl-1"));
        bytes memory sig = ProvenanceSigning.signWetLabAttestation(ORACLE_PK, att, provenance);
        bytes32 digest = provenance.wetLabDigest(att);

        vm.expectEmit(true, true, true, true, address(provenance));
        emit IProvenanceRegistry.WetLabRecorded(TOKEN_A, digest, oracle);

        vm.prank(STRANGER);
        provenance.recordWetLabAttestation(TOKEN_A, att, sig);

        assertEq(provenance.getRecordCount(TOKEN_A), 1);
        assertTrue(provenance.isRecordValid(TOKEN_A, digest));
        SeqoraTypes.ProvenanceRecord[] memory all = provenance.getProvenance(TOKEN_A);
        assertEq(uint256(all[0].kind), uint256(SeqoraTypes.ProvenanceKind.WetLab));
        assertEq(all[0].submitter, oracle);
    }

    function test_RecordWetLab_RevertsWhen_ZeroOracle() public {
        SeqoraTypes.WetLabAttestation memory att = _att(address(0), keccak256("wl-zero"));
        bytes memory sig = ProvenanceSigning.signWetLabAttestation(ORACLE_PK, att, provenance);
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        provenance.recordWetLabAttestation(TOKEN_A, att, sig);
    }

    function test_RecordWetLab_RevertsWhen_OracleNotApproved() public {
        uint256 rougePk = 0xBADBAD;
        address rogue = vm.addr(rougePk);
        SeqoraTypes.WetLabAttestation memory att = _att(rogue, keccak256("wl-rogue"));
        bytes memory sig = ProvenanceSigning.signWetLabAttestation(rougePk, att, provenance);
        vm.expectRevert(abi.encodeWithSelector(IProvenanceRegistry.OracleNotApproved.selector, rogue));
        provenance.recordWetLabAttestation(TOKEN_A, att, sig);
    }

    function test_RecordWetLab_AfterRevoke_FreshAttestationReverts() public {
        // Record one valid attestation, then revoke the oracle, then verify a NEW attestation
        // by the same oracle reverts OracleNotApproved.
        SeqoraTypes.WetLabAttestation memory a1 = _att(oracle, keccak256("wl-first"));
        bytes memory s1 = ProvenanceSigning.signWetLabAttestation(ORACLE_PK, a1, provenance);
        provenance.recordWetLabAttestation(TOKEN_A, a1, s1);

        vm.prank(OWNER);
        provenance.revokeOracle(oracle);

        SeqoraTypes.WetLabAttestation memory a2 = _att(oracle, keccak256("wl-after-revoke"));
        bytes memory s2 = ProvenanceSigning.signWetLabAttestation(ORACLE_PK, a2, provenance);
        vm.expectRevert(abi.encodeWithSelector(IProvenanceRegistry.OracleNotApproved.selector, oracle));
        provenance.recordWetLabAttestation(TOKEN_A, a2, s2);
    }

    function test_RecordWetLab_RevertsWhen_UnknownToken() public {
        uint256 unknownId = uint256(keccak256("unknown-token"));
        SeqoraTypes.WetLabAttestation memory att = _att(oracle, keccak256("wl-unknown"));
        bytes memory sig = ProvenanceSigning.signWetLabAttestation(ORACLE_PK, att, provenance);
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.UnknownToken.selector, unknownId));
        provenance.recordWetLabAttestation(unknownId, att, sig);
    }

    function test_RecordWetLab_RevertsWhen_SignatureMismatch() public {
        SeqoraTypes.WetLabAttestation memory att = _att(oracle, keccak256("wl-mismatch"));
        // Sign with oracle2's key but leave att.oracle = oracle1 (approved). Oracle approval
        // check passes (oracle1 is approved); signature recovery fails (recovers to oracle2).
        bytes memory badSig = ProvenanceSigning.signWetLabAttestation(ORACLE2_PK, att, provenance);
        vm.expectRevert(IProvenanceRegistry.InvalidSignature.selector);
        provenance.recordWetLabAttestation(TOKEN_A, att, badSig);
    }

    function test_RecordWetLab_RevertsWhen_Paused() public {
        SeqoraTypes.WetLabAttestation memory att = _att(oracle, keccak256("wl-paused"));
        bytes memory sig = ProvenanceSigning.signWetLabAttestation(ORACLE_PK, att, provenance);
        vm.prank(OWNER);
        provenance.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        provenance.recordWetLabAttestation(TOKEN_A, att, sig);
    }

    function test_RecordWetLab_Replay_SameTokenId_Reverts() public {
        SeqoraTypes.WetLabAttestation memory att = _att(oracle, keccak256("wl-replay"));
        bytes memory sig = ProvenanceSigning.signWetLabAttestation(ORACLE_PK, att, provenance);
        bytes32 digest = provenance.wetLabDigest(att);

        provenance.recordWetLabAttestation(TOKEN_A, att, sig);
        vm.expectRevert(abi.encodeWithSelector(IProvenanceRegistry.DuplicateProvenance.selector, TOKEN_A, digest));
        provenance.recordWetLabAttestation(TOKEN_A, att, sig);
    }

    /// @notice CRITICAL test per tester brief: `WetLabAttestation` struct has no `tokenId` field,
    ///         so a single signed attestation can be submitted against ANY tokenId. This is the
    ///         contract's documented behavior (threat-model §1) — intentional so the same receipt
    ///         can attach to fork children.
    ///
    ///         Verdict documented inline: contract leaves cross-tokenId replay OPEN. A single
    ///         oracle signature can land on multiple tokenIds. The only defense is per-tokenId
    ///         dedup via `_seenRecord[tokenId][recordHash]`, which is scoped to one tokenId.
    function test_RecordWetLab_CrossTokenId_ReplayLandsOnBothTokens() public {
        uint256 tokenB = _registerGenesis(BOB, keccak256("genesis-B"));
        SeqoraTypes.WetLabAttestation memory att = _att(oracle, keccak256("wl-cross"));
        bytes memory sig = ProvenanceSigning.signWetLabAttestation(ORACLE_PK, att, provenance);
        bytes32 digest = provenance.wetLabDigest(att);

        // First: land on TOKEN_A.
        provenance.recordWetLabAttestation(TOKEN_A, att, sig);
        // Second: same signed blob lands on tokenB — proves cross-tokenId replay is possible.
        provenance.recordWetLabAttestation(tokenB, att, sig);

        assertTrue(provenance.isRecordValid(TOKEN_A, digest), "A: valid");
        assertTrue(provenance.isRecordValid(tokenB, digest), "B: valid");
        assertEq(provenance.getRecordCount(TOKEN_A), 1);
        assertEq(provenance.getRecordCount(tokenB), 1);
    }

    function test_RecordWetLab_BadSignatureLength_Reverts() public {
        SeqoraTypes.WetLabAttestation memory att = _att(oracle, keccak256("wl-badlen"));
        bytes memory shortSig = hex"deadbeef";
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 4));
        provenance.recordWetLabAttestation(TOKEN_A, att, shortSig);
    }
}

// ============================================================================
// Oracle governance
// ============================================================================

contract ProvenanceRegistry_OracleGov_Test is ProvHarness {
    function test_SetOracleApproved_Happy_TrueThenFalse_EmitsEvents() public {
        address fresh = vm.addr(0xAA11);
        assertFalse(provenance.isOracleApproved(fresh));

        vm.expectEmit(true, false, false, true, address(provenance));
        emit IProvenanceRegistry.OracleApprovalChanged(fresh, true);
        vm.prank(OWNER);
        provenance.setOracleApproved(fresh, true);
        assertTrue(provenance.isOracleApproved(fresh));
        assertTrue(provenance.isApprovedOracle(fresh));

        vm.expectEmit(true, false, false, true, address(provenance));
        emit IProvenanceRegistry.OracleApprovalChanged(fresh, false);
        vm.prank(OWNER);
        provenance.setOracleApproved(fresh, false);
        assertFalse(provenance.isOracleApproved(fresh));
    }

    function test_SetOracleApproved_Idempotent_DoesNotRevert() public {
        address fresh = vm.addr(0xAA12);
        vm.prank(OWNER);
        provenance.setOracleApproved(fresh, true);
        vm.prank(OWNER);
        provenance.setOracleApproved(fresh, true); // no-op, must not revert
        assertTrue(provenance.isOracleApproved(fresh));
    }

    function test_SetOracleApproved_RevertsWhen_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        vm.prank(STRANGER);
        provenance.setOracleApproved(vm.addr(0x42), true);
    }

    function test_SetOracleApproved_RevertsWhen_ZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        provenance.setOracleApproved(address(0), true);
    }

    function test_RegisterOracle_Happy_Emits() public {
        address fresh = vm.addr(0xAA13);
        vm.expectEmit(true, false, false, true, address(provenance));
        emit IProvenanceRegistry.OracleApprovalChanged(fresh, true);
        vm.prank(OWNER);
        provenance.registerOracle(fresh);
        assertTrue(provenance.isOracleApproved(fresh));
    }

    function test_RegisterOracle_RevertsWhen_NotOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        provenance.registerOracle(vm.addr(0x42));
    }

    function test_RegisterOracle_RevertsWhen_Zero() public {
        vm.prank(OWNER);
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        provenance.registerOracle(address(0));
    }

    function test_RevokeOracle_Happy_Emits() public {
        vm.expectEmit(true, false, false, true, address(provenance));
        emit IProvenanceRegistry.OracleApprovalChanged(oracle, false);
        vm.prank(OWNER);
        provenance.revokeOracle(oracle);
        assertFalse(provenance.isOracleApproved(oracle));
    }

    function test_RevokeOracle_RevertsWhen_NotOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        provenance.revokeOracle(oracle);
    }

    function test_RevokeOracle_RevertsWhen_Zero() public {
        vm.prank(OWNER);
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        provenance.revokeOracle(address(0));
    }
}

// ============================================================================
// Local revocation
// ============================================================================

contract ProvenanceRegistry_Revocation_Test is ProvHarness {
    using ProvenanceSigning for ProvenanceRegistry;

    function _recordOne(bytes32 salt) internal returns (bytes32 digest) {
        SeqoraTypes.ModelCard memory card = _card(contributor, salt);
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        provenance.recordModelCard(TOKEN_A, card, sig);
        digest = provenance.modelCardDigest(card);
    }

    /// @dev Local mirror of `ProvenanceRegistry.LocalRecordRevocation` — Foundry matches events by
    ///      signature (name + params), so the mirror MUST use the identical event name.
    event LocalRecordRevocation(uint256 indexed tokenId, bytes32 indexed recordHash, address indexed by);

    function test_LocalRevoke_Happy_FlagsAndEmits() public {
        bytes32 d = _recordOne(keccak256("rv-1"));
        assertTrue(provenance.isRecordValid(TOKEN_A, d));

        vm.expectEmit(true, true, true, true, address(provenance));
        emit LocalRecordRevocation(TOKEN_A, d, OWNER);

        vm.prank(OWNER);
        provenance.localRevoke(TOKEN_A, d);

        assertFalse(provenance.isRecordValid(TOKEN_A, d));
        assertTrue(provenance.locallyRevoked(d));
        // Record still appears in the array (revoke does not delete).
        SeqoraTypes.ProvenanceRecord[] memory all = provenance.getProvenance(TOKEN_A);
        assertEq(all.length, 1);
        assertEq(all[0].recordHash, d);
    }

    function test_LocalRevoke_RevertsWhen_NotOwner() public {
        bytes32 d = _recordOne(keccak256("rv-2"));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        provenance.localRevoke(TOKEN_A, d);
    }

    function test_LocalRevoke_RevertsWhen_ZeroHash() public {
        vm.prank(OWNER);
        vm.expectRevert(SeqoraErrors.ZeroValue.selector);
        provenance.localRevoke(TOKEN_A, bytes32(0));
    }

    function test_LocalRevoke_RevertsWhen_UnknownRecord() public {
        bytes32 unknownHash = keccak256("never-recorded");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ProvenanceRegistry.UnknownRecord.selector, TOKEN_A, unknownHash));
        provenance.localRevoke(TOKEN_A, unknownHash);
    }

    function test_LocalRevoke_Idempotent_SecondCallNoop() public {
        bytes32 d = _recordOne(keccak256("rv-3"));

        vm.prank(OWNER);
        provenance.localRevoke(TOKEN_A, d);
        // Second call — no revert, no extra event (idempotent).
        vm.recordLogs();
        vm.prank(OWNER);
        provenance.localRevoke(TOKEN_A, d);
        assertEq(vm.getRecordedLogs().length, 0, "idempotent: no event on second call");
        assertFalse(provenance.isRecordValid(TOKEN_A, d));
    }

    function test_LocalRevoke_ScopeIsGlobalOnRecordHash() public {
        // Same recordHash exists under two tokenIds; revoking via TOKEN_A invalidates it under tokenB too.
        uint256 tokenB = _registerGenesis(BOB, keccak256("genesis-B"));
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("rv-cross"));
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        provenance.recordModelCard(TOKEN_A, card, sig);
        provenance.recordModelCard(tokenB, card, sig);
        bytes32 d = provenance.modelCardDigest(card);
        assertTrue(provenance.isRecordValid(TOKEN_A, d));
        assertTrue(provenance.isRecordValid(tokenB, d));

        vm.prank(OWNER);
        provenance.localRevoke(TOKEN_A, d);

        assertFalse(provenance.isRecordValid(TOKEN_A, d), "A invalid");
        assertFalse(provenance.isRecordValid(tokenB, d), "B invalid - global scope");
    }

    function test_LocalRevoke_UnknownUnderTokenButExistsElsewhere_Reverts() public {
        uint256 tokenB = _registerGenesis(BOB, keccak256("genesis-B"));
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("rv-scoped"));
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        provenance.recordModelCard(TOKEN_A, card, sig);
        bytes32 d = provenance.modelCardDigest(card);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ProvenanceRegistry.UnknownRecord.selector, tokenB, d));
        provenance.localRevoke(tokenB, d);
    }
}

// ============================================================================
// Reads: pagination, counts, validity
// ============================================================================

contract ProvenanceRegistry_Reads_Test is ProvHarness {
    using ProvenanceSigning for ProvenanceRegistry;

    function _recordN(uint256 n) internal returns (bytes32[] memory digests) {
        digests = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            SeqoraTypes.ModelCard memory card = _card(contributor, bytes32(uint256(keccak256(abi.encode("p", i)))));
            bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
            provenance.recordModelCard(TOKEN_A, card, sig);
            digests[i] = provenance.modelCardDigest(card);
        }
    }

    function test_Reads_CountZeroForFreshToken() public {
        uint256 fresh = _registerGenesis(BOB, keccak256("genesis-fresh"));
        assertEq(provenance.getRecordCount(fresh), 0);
        assertEq(provenance.provenanceCount(fresh), 0);
        SeqoraTypes.ProvenanceRecord[] memory empty = provenance.getProvenance(fresh);
        assertEq(empty.length, 0);
    }

    function test_Reads_CountForUnregistered_ReturnsZero() public view {
        // Unregistered tokenId reads return zero (no revert on reads).
        assertEq(provenance.getRecordCount(uint256(keccak256("never"))), 0);
        assertEq(provenance.provenanceCount(uint256(keccak256("never"))), 0);
    }

    function test_Pagination_EmptyWhenOffsetBeyondTotal() public {
        _recordN(3);
        (SeqoraTypes.ProvenanceRecord[] memory page, uint256 total) = provenance.getRecordsByTokenId(TOKEN_A, 10, 50);
        assertEq(page.length, 0);
        assertEq(total, 3);
    }

    function test_Pagination_LimitZero_ReturnsEmpty() public {
        _recordN(2);
        (SeqoraTypes.ProvenanceRecord[] memory page, uint256 total) = provenance.getRecordsByTokenId(TOKEN_A, 0, 0);
        assertEq(page.length, 0);
        assertEq(total, 2);
    }

    function test_Pagination_LimitCappedAt100() public {
        uint256 n = 7;
        _recordN(n);
        (SeqoraTypes.ProvenanceRecord[] memory page, uint256 total) =
            provenance.getRecordsByTokenId(TOKEN_A, 0, type(uint256).max);
        // Total records < 100 < limit, so pageSize = total.
        assertEq(page.length, n);
        assertEq(total, n);
    }

    function test_Pagination_TotalMatchesGetRecordCount() public {
        _recordN(5);
        (, uint256 total) = provenance.getRecordsByTokenId(TOKEN_A, 0, 100);
        assertEq(total, provenance.getRecordCount(TOKEN_A));
    }

    function test_Pagination_ConsecutivePagesReconstructArray() public {
        uint256 n = 10;
        bytes32[] memory digests = _recordN(n);

        uint256 pageSize = 3;
        uint256 collected;
        for (uint256 offset = 0; offset < n; offset += pageSize) {
            (SeqoraTypes.ProvenanceRecord[] memory page, uint256 total) =
                provenance.getRecordsByTokenId(TOKEN_A, offset, pageSize);
            assertEq(total, n);
            for (uint256 i = 0; i < page.length; i++) {
                assertEq(page[i].recordHash, digests[collected], "append order preserved");
                collected++;
            }
        }
        assertEq(collected, n);
    }

    function test_Pagination_OversizedLimitSilentlyCapped() public {
        // Stress: record 105 entries, request a huge limit, expect EXACTLY 100 returned.
        _recordN(105);
        (SeqoraTypes.ProvenanceRecord[] memory page, uint256 total) = provenance.getRecordsByTokenId(TOKEN_A, 0, 10_000);
        assertEq(page.length, 100, "capped at MAX_PAGE_LIMIT");
        assertEq(total, 105);
    }

    function test_IsRecordValid_UnknownHash_False() public view {
        assertFalse(provenance.isRecordValid(TOKEN_A, keccak256("unknown")));
    }

    function test_IsRecordValid_Revoked_False() public {
        bytes32[] memory ds = _recordN(1);
        vm.prank(OWNER);
        provenance.localRevoke(TOKEN_A, ds[0]);
        assertFalse(provenance.isRecordValid(TOKEN_A, ds[0]));
    }

    function test_Reads_CountUnchangedAfterRevocation() public {
        bytes32[] memory ds = _recordN(3);
        vm.prank(OWNER);
        provenance.localRevoke(TOKEN_A, ds[1]);
        // Revocations do NOT delete records — count stays 3.
        assertEq(provenance.getRecordCount(TOKEN_A), 3);
    }

    function test_DomainSeparator_MatchesEIP712() public view {
        // Recompute the domain separator off-contract and assert equality.
        bytes32 typeHash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 expected = keccak256(
            abi.encode(
                typeHash,
                keccak256(bytes("Seqora ProvenanceRegistry")),
                keccak256(bytes("1")),
                block.chainid,
                address(provenance)
            )
        );
        assertEq(provenance.domainSeparator(), expected);
    }
}

// ============================================================================
// Pause / unpause + governance
// ============================================================================

contract ProvenanceRegistry_Pause_Test is ProvHarness {
    using ProvenanceSigning for ProvenanceRegistry;

    function test_Pause_Unpause_Happy() public {
        assertFalse(provenance.paused());
        vm.prank(OWNER);
        provenance.pause();
        assertTrue(provenance.paused());
        vm.prank(OWNER);
        provenance.unpause();
        assertFalse(provenance.paused());
    }

    function test_Pause_RevertsWhen_NotOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        provenance.pause();
    }

    function test_Unpause_RevertsWhen_NotOwner() public {
        vm.prank(OWNER);
        provenance.pause();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        provenance.unpause();
    }

    function test_Paused_ReadsStillWork() public {
        // Record a card, then pause. Reads + isRecordValid + domainSeparator still work.
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("pr-read"));
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        provenance.recordModelCard(TOKEN_A, card, sig);
        vm.prank(OWNER);
        provenance.pause();

        assertEq(provenance.getRecordCount(TOKEN_A), 1);
        assertTrue(provenance.isRecordValid(TOKEN_A, provenance.modelCardDigest(card)));
        // reads
        assertEq(provenance.getProvenance(TOKEN_A).length, 1);
        (, uint256 total) = provenance.getRecordsByTokenId(TOKEN_A, 0, 10);
        assertEq(total, 1);
    }

    function test_Paused_OracleGovernanceStillWorks() public {
        vm.prank(OWNER);
        provenance.pause();

        address fresh = vm.addr(0xFACE);
        vm.prank(OWNER);
        provenance.setOracleApproved(fresh, true);
        assertTrue(provenance.isOracleApproved(fresh));
    }

    function test_Paused_LocalRevokeStillWorks() public {
        SeqoraTypes.ModelCard memory card = _card(contributor, keccak256("pr-revoke"));
        bytes memory sig = ProvenanceSigning.signModelCard(CONTRIB_PK, card, provenance);
        provenance.recordModelCard(TOKEN_A, card, sig);
        bytes32 d = provenance.modelCardDigest(card);

        vm.prank(OWNER);
        provenance.pause();

        vm.prank(OWNER);
        provenance.localRevoke(TOKEN_A, d);
        assertFalse(provenance.isRecordValid(TOKEN_A, d));
    }
}

// ============================================================================
// renounceOwnership + ownership transfer
// ============================================================================

contract ProvenanceRegistry_Ownership_Test is ProvHarness {
    function test_Renounce_RevertsAlways() public {
        vm.prank(OWNER);
        vm.expectRevert(ProvenanceRegistry.RenounceDisabled.selector);
        provenance.renounceOwnership();
    }

    function test_Renounce_RevertsFor_NonOwner() public {
        // onlyOwner fires first.
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        provenance.renounceOwnership();
    }

    function test_TransferOwnership_Is2Step() public {
        address newOwner = vm.addr(0xD00D);
        vm.prank(OWNER);
        provenance.transferOwnership(newOwner);
        assertEq(provenance.pendingOwner(), newOwner, "pending queued");
        assertEq(provenance.owner(), OWNER, "owner still old until accept");

        vm.prank(newOwner);
        provenance.acceptOwnership();
        assertEq(provenance.owner(), newOwner, "rotated");
    }
}

// ============================================================================
// FUZZ
// ============================================================================

contract ProvenanceRegistry_Fuzz_Test is ProvHarness {
    using ProvenanceSigning for ProvenanceRegistry;

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_RecordModelCard_AnyValidSignature(
        uint256 pkSeed,
        bytes32 weightsHash,
        bytes32 promptHash,
        bytes32 seed,
        uint64 createdAt
    ) public {
        // Bound pk to secp256k1's valid range (1..n-1). Use a large safe interior range.
        uint256 pk = bound(pkSeed, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        address signer = vm.addr(pk);

        SeqoraTypes.ModelCard memory card = SeqoraTypes.ModelCard({
            weightsHash: weightsHash,
            promptHash: promptHash,
            seed: seed,
            toolName: "T",
            toolVersion: "v",
            contributor: signer,
            createdAt: createdAt
        });
        bytes memory sig = ProvenanceSigning.signModelCard(pk, card, provenance);
        bytes32 digest = provenance.modelCardDigest(card);

        // Duplicate guard: if fuzzer lands the same digest twice across runs (near-impossible),
        // just skip — structural property doesn't depend on this run.
        if (provenance.isRecordValid(TOKEN_A, digest)) return;

        vm.expectEmit(true, true, true, true, address(provenance));
        emit IProvenanceRegistry.ModelCardRecorded(TOKEN_A, digest, signer);
        provenance.recordModelCard(TOKEN_A, card, sig);
        assertTrue(provenance.isRecordValid(TOKEN_A, digest));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_WetLabAttestation_AnyApprovedOracle(uint256 pkSeed, uint64 synthesizedAt, bytes32 payloadHash)
        public
    {
        uint256 pk = bound(pkSeed, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        address orc = vm.addr(pk);

        vm.prank(OWNER);
        provenance.registerOracle(orc);

        SeqoraTypes.WetLabAttestation memory att = SeqoraTypes.WetLabAttestation({
            oracle: orc, vendor: "V", orderRef: "O", synthesizedAt: synthesizedAt, payloadHash: payloadHash
        });
        bytes memory sig = ProvenanceSigning.signWetLabAttestation(pk, att, provenance);
        bytes32 digest = provenance.wetLabDigest(att);
        if (provenance.isRecordValid(TOKEN_A, digest)) return;

        vm.expectEmit(true, true, true, true, address(provenance));
        emit IProvenanceRegistry.WetLabRecorded(TOKEN_A, digest, orc);
        provenance.recordWetLabAttestation(TOKEN_A, att, sig);
        assertTrue(provenance.isRecordValid(TOKEN_A, digest));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_Pagination_AlwaysConsistent(uint64 offset, uint16 limit) public {
        // Seed N=25 records.
        uint256 N = 25;
        bytes32[] memory digests = new bytes32[](N);
        for (uint256 i = 0; i < N; i++) {
            SeqoraTypes.ModelCard memory c = _card(contributor, bytes32(uint256(keccak256(abi.encode("pf", i)))));
            bytes memory s = ProvenanceSigning.signModelCard(CONTRIB_PK, c, provenance);
            provenance.recordModelCard(TOKEN_A, c, s);
            digests[i] = provenance.modelCardDigest(c);
        }

        (SeqoraTypes.ProvenanceRecord[] memory page, uint256 total) =
            provenance.getRecordsByTokenId(TOKEN_A, offset, limit);
        assertEq(total, N, "total always equals N");

        // Expected pageSize:
        uint256 effLimit = limit > provenance.MAX_PAGE_LIMIT() ? provenance.MAX_PAGE_LIMIT() : limit;
        uint256 expectedSize;
        if (offset >= N) {
            expectedSize = 0;
        } else {
            uint256 end = offset + effLimit;
            if (end > N) end = N;
            expectedSize = end - offset;
        }
        assertEq(page.length, expectedSize, "pageSize formula holds");

        // Records in returned page match the append-order slice.
        for (uint256 i = 0; i < page.length; i++) {
            assertEq(page[i].recordHash, digests[offset + i], "slice order preserved");
        }
    }

    /// forge-config: default.fuzz.runs = 128
    /// @notice Fuzz confirms cross-tokenId replay behavior: a signed attestation can be landed
    ///         against any pair of distinct tokenIds, documenting the contract's open policy.
    function testFuzz_CrossTokenIdReplay(bytes32 saltA, bytes32 saltB) public {
        // Derive two distinct canonical hashes from user-supplied salts.
        vm.assume(saltA != saltB);
        vm.assume(saltA != bytes32(0));
        vm.assume(saltB != bytes32(0));
        // Use different-shaped canonical hashes from the existing TOKEN_A.
        bytes32 hashA = keccak256(abi.encode("fuzzA", saltA));
        bytes32 hashB = keccak256(abi.encode("fuzzB", saltB));
        vm.assume(hashA != hashB);

        uint256 idA = _registerGenesis(ALICE, hashA);
        uint256 idB = _registerGenesis(BOB, hashB);

        SeqoraTypes.WetLabAttestation memory att = _att(oracle, keccak256(abi.encode(saltA, saltB)));
        bytes memory sig = ProvenanceSigning.signWetLabAttestation(ORACLE_PK, att, provenance);
        bytes32 digest = provenance.wetLabDigest(att);

        // Lands on both tokenIds — cross-tokenId replay is OPEN by design.
        provenance.recordWetLabAttestation(idA, att, sig);
        provenance.recordWetLabAttestation(idB, att, sig);
        assertTrue(provenance.isRecordValid(idA, digest));
        assertTrue(provenance.isRecordValid(idB, digest));
    }
}
