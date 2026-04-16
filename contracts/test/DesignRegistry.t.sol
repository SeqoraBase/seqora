// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC1155MetadataURI } from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { DesignRegistry } from "../src/DesignRegistry.sol";
import { IDesignRegistry } from "../src/interfaces/IDesignRegistry.sol";
import { IScreeningAttestations } from "../src/interfaces/IScreeningAttestations.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";
import { SeqoraErrors } from "../src/libraries/SeqoraErrors.sol";

import { BaseTest } from "./helpers/BaseTest.sol";
import {
    AlwaysValidScreening,
    AlwaysInvalidScreening,
    RevertingScreening,
    ReentrantReceiver,
    ToggleableScreening,
    ScopedScreening
} from "./helpers/MockScreening.sol";

/// @notice Concrete ERC-1155 holder used by receiver tests (OZ's ERC1155Holder is abstract).
contract ERC1155HolderStub {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return ERC1155HolderStub.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return ERC1155HolderStub.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x4e2312e0 || id == 0x01ffc9a7; // IERC1155Receiver + ERC165
    }
}

/// @notice Thin relayer that submits `register` / `forkRegister` on behalf of a user.
/// @dev Tests the M-02 fix: mint target / stored registrant come from the arg, NOT msg.sender.
contract Relayer {
    function relayRegister(
        DesignRegistry registry,
        address registrant,
        bytes32 canonicalHash,
        bytes32 attUid,
        SeqoraTypes.RoyaltyRule memory royalty
    ) external returns (uint256) {
        return registry.register(registrant, canonicalHash, bytes32(0), "ar", "ce", royalty, attUid, new bytes32[](0));
    }

    function relayForkRegister(DesignRegistry registry, SeqoraTypes.ForkParams memory params)
        external
        returns (uint256)
    {
        return registry.forkRegister(params);
    }
}

// =============================================================================
// UNIT — constructor
// =============================================================================

contract DesignRegistry_Constructor_Test is Test {
    function test_Constructor_StoresScreeningAndBaseUri() public {
        AlwaysValidScreening s = new AlwaysValidScreening();
        DesignRegistry r = new DesignRegistry("ipfs://seqora/{id}.json", s);
        assertEq(address(r.SCREENING()), address(s), "screening bound on deploy");
        assertEq(r.uri(0), "ipfs://seqora/{id}.json", "base uri persists");
    }

    function test_Constructor_RevertsWhen_ScreeningZero() public {
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        new DesignRegistry("ipfs://seqora/{id}.json", IScreeningAttestations(address(0)));
    }
}

// =============================================================================
// UNIT — register
// =============================================================================

contract DesignRegistry_Register_Test is BaseTest {
    function test_Register_HappyPath_MintsAndStoresHeader() public {
        bytes32 h = keccak256("design-1");
        SeqoraTypes.RoyaltyRule memory royalty = _royalty(RECIPIENT, 500, 0);

        vm.prank(ALICE);
        uint256 tokenId = registry.register(
            ALICE,
            h,
            bytes32(uint256(0xF00D)),
            "ar://tx1",
            "ceramic://s1",
            royalty,
            bytes32(uint256(0xBEEF)),
            new bytes32[](0)
        );

        assertEq(tokenId, uint256(h), "tokenId == uint256(canonicalHash)");
        assertTrue(registry.isRegistered(tokenId), "isRegistered flips on");
        assertEq(registry.balanceOf(ALICE, tokenId), 1, "one token minted");

        SeqoraTypes.Design memory d = registry.getDesign(tokenId);
        assertEq(d.canonicalHash, h, "header.canonicalHash");
        assertEq(d.ga4ghSeqhash, bytes32(uint256(0xF00D)), "header.ga4ghSeqhash");
        assertEq(d.arweaveTx, "ar://tx1", "header.arweaveTx");
        assertEq(d.ceramicStreamId, "ceramic://s1", "header.ceramicStreamId");
        assertEq(d.royalty.recipient, RECIPIENT, "header.royalty.recipient");
        assertEq(d.royalty.bps, 500, "header.royalty.bps");
        assertEq(d.royalty.parentSplitBps, 0, "header.royalty.parentSplitBps");
        assertEq(d.screeningAttestationUID, bytes32(uint256(0xBEEF)), "header.attUid");
        assertEq(d.registrant, ALICE, "header.registrant");
        assertEq(d.registeredAt, uint64(block.timestamp), "header.registeredAt");
        assertEq(d.parentTokenIds.length, 0, "genesis has no parents");
    }

    function test_Register_EmitsDesignRegistered() public {
        bytes32 h = keccak256("emit-reg");
        SeqoraTypes.RoyaltyRule memory royalty = _royalty(RECIPIENT, 100, 0);

        vm.expectEmit(true, true, false, true, address(registry));
        emit IDesignRegistry.DesignRegistered(uint256(h), ALICE, h, bytes32(uint256(9)), bytes32(uint256(11)));

        vm.prank(ALICE);
        registry.register(
            ALICE, h, bytes32(uint256(9)), "ar://x", "ceramic://y", royalty, bytes32(uint256(11)), new bytes32[](0)
        );
    }

    function test_Register_RevertsWhen_RegistrantZero() public {
        // L-01 confirmation: registrant == address(0) must revert.
        bytes32 h = keccak256("registrant-zero");
        vm.expectRevert(SeqoraErrors.ZeroAddress.selector);
        vm.prank(ALICE);
        registry.register(address(0), h, bytes32(0), "a", "c", _defaultRoyalty(), bytes32(uint256(1)), new bytes32[](0));
    }

    function test_Register_RevertsWhen_CanonicalHashZero() public {
        vm.expectRevert(SeqoraErrors.ZeroValue.selector);
        vm.prank(ALICE);
        registry.register(
            ALICE, bytes32(0), bytes32(0), "a", "c", _defaultRoyalty(), bytes32(uint256(1)), new bytes32[](0)
        );
    }

    function test_Register_RevertsWhen_AlreadyRegistered() public {
        bytes32 h = keccak256("dup");
        _registerGenesis(ALICE, h);

        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.AlreadyRegistered.selector, uint256(h)));
        vm.prank(BOB);
        registry.register(BOB, h, bytes32(0), "a", "c", _defaultRoyalty(), bytes32(uint256(1)), new bytes32[](0));
    }

    function test_Register_RevertsWhen_ParentsProvided() public {
        bytes32 h = keccak256("use-fork");
        bytes32[] memory parents = new bytes32[](1);
        parents[0] = bytes32(uint256(keccak256("p")));

        vm.expectRevert(DesignRegistry.UseForkRegister.selector);
        vm.prank(ALICE);
        registry.register(ALICE, h, bytes32(0), "a", "c", _defaultRoyalty(), bytes32(uint256(1)), parents);
    }

    function test_Register_RevertsWhen_RoyaltyBpsOutOfRange() public {
        bytes32 h = keccak256("bps-over");
        uint16 badBps = SeqoraTypes.MAX_ROYALTY_BPS + 1;
        SeqoraTypes.RoyaltyRule memory royalty = _royalty(RECIPIENT, badBps, 0);

        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.BpsOutOfRange.selector, badBps));
        vm.prank(ALICE);
        registry.register(ALICE, h, bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0));
    }

    function test_Register_RevertsWhen_ParentSplitBpsOutOfRange() public {
        bytes32 h = keccak256("psbps-over");
        uint16 badPs = SeqoraTypes.BPS + 1;
        SeqoraTypes.RoyaltyRule memory royalty = _royalty(RECIPIENT, 100, badPs);

        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.BpsOutOfRange.selector, badPs));
        vm.prank(ALICE);
        registry.register(ALICE, h, bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0));
    }

    function test_Register_RevertsWhen_GenesisSetsParentSplit() public {
        bytes32 h = keccak256("genesis-ps");
        SeqoraTypes.RoyaltyRule memory royalty = _royalty(RECIPIENT, 100, 500);

        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.BpsOutOfRange.selector, uint16(500)));
        vm.prank(ALICE);
        registry.register(ALICE, h, bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0));
    }

    function test_Register_RevertsWhen_RecipientZeroWithBpsGtZero() public {
        bytes32 h = keccak256("recipient-zero");
        SeqoraTypes.RoyaltyRule memory royalty = _royalty(address(0), 500, 0);

        vm.expectRevert(DesignRegistry.InvalidRoyaltyRecipient.selector);
        vm.prank(ALICE);
        registry.register(ALICE, h, bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0));
    }

    function test_Register_AllowsZeroRecipient_WhenBpsZero() public {
        bytes32 h = keccak256("zero-bps-ok");
        SeqoraTypes.RoyaltyRule memory royalty = _royalty(address(0), 0, 0);

        vm.prank(ALICE);
        uint256 tokenId =
            registry.register(ALICE, h, bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0));
        assertTrue(registry.isRegistered(tokenId));
    }

    function test_Register_RevertsWhen_ScreeningReturnsFalse() public {
        // Swap screening for the invalid variant.
        AlwaysInvalidScreening bad = new AlwaysInvalidScreening();
        DesignRegistry r = new DesignRegistry("u", bad);

        bytes32 h = keccak256("bad-att");
        bytes32 uid = bytes32(uint256(42));
        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.AttestationInvalid.selector, uid));
        vm.prank(ALICE);
        r.register(ALICE, h, bytes32(0), "a", "c", _defaultRoyalty(), uid, new bytes32[](0));
    }

    function test_Register_BubblesUpScreeningRevert() public {
        RevertingScreening bad = new RevertingScreening();
        DesignRegistry r = new DesignRegistry("u", bad);

        vm.expectRevert(RevertingScreening.ScreeningBoom.selector);
        vm.prank(ALICE);
        r.register(
            ALICE, keccak256("x"), bytes32(0), "a", "c", _defaultRoyalty(), bytes32(uint256(1)), new bytes32[](0)
        );
    }

    function test_Register_AllowsMaxRoyaltyBps() public {
        bytes32 h = keccak256("max-bps");
        SeqoraTypes.RoyaltyRule memory royalty = _royalty(RECIPIENT, SeqoraTypes.MAX_ROYALTY_BPS, 0);

        vm.prank(ALICE);
        uint256 tokenId =
            registry.register(ALICE, h, bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0));
        SeqoraTypes.Design memory d = registry.getDesign(tokenId);
        assertEq(d.royalty.bps, SeqoraTypes.MAX_ROYALTY_BPS);
    }

    // ---------------------------------------------------------------------
    // L-02 — string length caps
    // ---------------------------------------------------------------------

    function test_Register_RevertsWhen_ArweaveTxExceeds128() public {
        bytes32 h = keccak256("long-arweave");
        string memory tooLong = _repeat("a", 129);
        vm.expectRevert(abi.encodeWithSelector(DesignRegistry.StringTooLong.selector, 129, 128));
        vm.prank(ALICE);
        registry.register(ALICE, h, bytes32(0), tooLong, "c", _defaultRoyalty(), bytes32(uint256(1)), new bytes32[](0));
    }

    function test_Register_RevertsWhen_CeramicStreamIdExceeds128() public {
        bytes32 h = keccak256("long-ceramic");
        string memory tooLong = _repeat("c", 129);
        vm.expectRevert(abi.encodeWithSelector(DesignRegistry.StringTooLong.selector, 129, 128));
        vm.prank(ALICE);
        registry.register(ALICE, h, bytes32(0), "a", tooLong, _defaultRoyalty(), bytes32(uint256(1)), new bytes32[](0));
    }

    function test_Register_AllowsExactly128ByteStrings() public {
        bytes32 h = keccak256("exactly-128");
        string memory exactly128Ar = _repeat("a", 128);
        string memory exactly128Ce = _repeat("c", 128);
        vm.prank(ALICE);
        uint256 tokenId = registry.register(
            ALICE, h, bytes32(0), exactly128Ar, exactly128Ce, _defaultRoyalty(), bytes32(uint256(1)), new bytes32[](0)
        );
        SeqoraTypes.Design memory d = registry.getDesign(tokenId);
        assertEq(bytes(d.arweaveTx).length, 128, "128-byte arweave persists");
        assertEq(bytes(d.ceramicStreamId).length, 128, "128-byte ceramic persists");
    }

    // ---------------------------------------------------------------------
    // H-01 — registrant-bound attestation
    // ---------------------------------------------------------------------

    function test_Register_HSubstitution_RejectsWhenRegistrantIsBob() public {
        // ScopedScreening is valid only for (uid, hash, ALICE).
        bytes32 uid = bytes32(uint256(0xA77));
        bytes32 h = keccak256("alice-design");
        ScopedScreening scoped = new ScopedScreening(uid, h, ALICE);
        DesignRegistry r = new DesignRegistry("u", scoped);

        // Bob front-runs Alice's calldata, substituting himself as registrant.
        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.AttestationInvalid.selector, uid));
        vm.prank(BOB);
        r.register(BOB, h, bytes32(0), "a", "c", _defaultRoyalty(), uid, new bytes32[](0));
    }

    function test_Register_HSubstitution_SucceedsWhenRegistrantIsAlice() public {
        // Same ScopedScreening; Bob is now acting as a relayer and sets registrant=Alice.
        bytes32 uid = bytes32(uint256(0xA77));
        bytes32 h = keccak256("alice-design");
        ScopedScreening scoped = new ScopedScreening(uid, h, ALICE);
        DesignRegistry r = new DesignRegistry("u", scoped);

        vm.prank(BOB);
        uint256 tokenId = r.register(ALICE, h, bytes32(0), "a", "c", _defaultRoyalty(), uid, new bytes32[](0));
        assertEq(r.balanceOf(ALICE, tokenId), 1, "mint target is Alice");
        assertEq(r.balanceOf(BOB, tokenId), 0, "relayer holds nothing");
        assertEq(r.getDesign(tokenId).registrant, ALICE, "stored registrant is Alice");
    }

    function test_Register_HReplay_CannotRegisterDifferentHashWithSameUID() public {
        // Scoped screener bound to (uid, hashA, ALICE). Attempting to reuse uid for a different
        // canonicalHash must fail screening.
        bytes32 uid = bytes32(uint256(0x5EED));
        bytes32 hashA = keccak256("design-A");
        bytes32 hashB = keccak256("design-B");
        ScopedScreening scoped = new ScopedScreening(uid, hashA, ALICE);
        DesignRegistry r = new DesignRegistry("u", scoped);

        // Sanity: hashA works.
        vm.prank(ALICE);
        r.register(ALICE, hashA, bytes32(0), "a", "c", _defaultRoyalty(), uid, new bytes32[](0));

        // hashB with same uid — screening rejects (canonicalHash mismatch).
        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.AttestationInvalid.selector, uid));
        vm.prank(ALICE);
        r.register(ALICE, hashB, bytes32(0), "a", "c", _defaultRoyalty(), uid, new bytes32[](0));
    }

    // ---------------------------------------------------------------------
    // M-02 — relayer path
    // ---------------------------------------------------------------------

    function test_Register_Relayer_MintsToRegistrant() public {
        Relayer relayer = new Relayer();
        bytes32 h = keccak256("relayer-design");

        uint256 tokenId = relayer.relayRegister(registry, ALICE, h, bytes32(uint256(1)), _defaultRoyalty());
        assertEq(registry.balanceOf(ALICE, tokenId), 1, "mint to Alice, not relayer");
        assertEq(registry.balanceOf(address(relayer), tokenId), 0, "relayer holds nothing");
        SeqoraTypes.Design memory d = registry.getDesign(tokenId);
        assertEq(d.registrant, ALICE, "stored registrant is Alice");
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _repeat(string memory c, uint256 n) internal pure returns (string memory out) {
        bytes memory src = bytes(c);
        bytes memory buf = new bytes(src.length * n);
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < src.length; j++) {
                buf[i * src.length + j] = src[j];
            }
        }
        out = string(buf);
    }
}

// =============================================================================
// UNIT — forkRegister
// =============================================================================

contract DesignRegistry_ForkRegister_Test is BaseTest {
    bytes32 internal constant PARENT_HASH = bytes32(uint256(keccak256("genesis-parent")));
    uint256 internal parentId;

    function setUp() public override {
        super.setUp();
        parentId = _registerGenesis(ALICE, PARENT_HASH);
    }

    function test_ForkRegister_SingleParent_MintsChild() public {
        bytes32 childHash = keccak256("child-1");
        SeqoraTypes.RoyaltyRule memory royalty = _royalty(RECIPIENT, 500, 1000);
        SeqoraTypes.ForkParams memory params =
            _forkParams(BOB, parentId, childHash, new bytes32[](0), royalty, bytes32(uint256(7)));

        vm.prank(BOB);
        uint256 childId = registry.forkRegister(params);

        assertEq(childId, uint256(childHash));
        assertEq(registry.balanceOf(BOB, childId), 1);
        bytes32[] memory parents = registry.parentsOf(childId);
        assertEq(parents.length, 1);
        assertEq(parents[0], bytes32(parentId));
    }

    function test_ForkRegister_MultiParent_OrderedPrimaryFirst() public {
        uint256 pB = _registerGenesis(BOB, keccak256("pB"));
        uint256 pC = _registerGenesis(CAROL, keccak256("pC"));

        bytes32 childHash = keccak256("child-multi");
        bytes32[] memory additional = new bytes32[](2);
        additional[0] = bytes32(pB);
        additional[1] = bytes32(pC);

        SeqoraTypes.RoyaltyRule memory royalty = _royalty(RECIPIENT, 1000, 5000);
        SeqoraTypes.ForkParams memory params =
            _forkParams(BOB, parentId, childHash, additional, royalty, bytes32(uint256(9)));

        vm.prank(BOB);
        uint256 childId = registry.forkRegister(params);

        bytes32[] memory stored = registry.parentsOf(childId);
        assertEq(stored.length, 3, "primary + two additional");
        assertEq(stored[0], bytes32(parentId), "[0] is primary");
        assertEq(stored[1], bytes32(pB));
        assertEq(stored[2], bytes32(pC));
    }

    function test_ForkRegister_EmitsDesignForkedWithFullParents() public {
        uint256 pB = _registerGenesis(BOB, keccak256("pB-emit"));
        bytes32 childHash = keccak256("child-emit");
        bytes32[] memory additional = new bytes32[](1);
        additional[0] = bytes32(pB);

        bytes32[] memory expectedParents = new bytes32[](2);
        expectedParents[0] = bytes32(parentId);
        expectedParents[1] = bytes32(pB);

        vm.expectEmit(true, true, false, true, address(registry));
        emit IDesignRegistry.DesignForked(uint256(childHash), expectedParents, BOB);

        SeqoraTypes.ForkParams memory params =
            _forkParams(BOB, parentId, childHash, additional, _royalty(RECIPIENT, 100, 1000), bytes32(uint256(3)));
        vm.prank(BOB);
        registry.forkRegister(params);
    }

    function test_ForkRegister_RevertsWhen_PrimaryParentZero() public {
        SeqoraTypes.ForkParams memory params = _forkParams(
            ALICE, 0, keccak256("x"), new bytes32[](0), _royalty(RECIPIENT, 100, 500), bytes32(uint256(1))
        );
        vm.expectRevert(DesignRegistry.NoParentsForFork.selector);
        vm.prank(ALICE);
        registry.forkRegister(params);
    }

    function test_ForkRegister_RevertsWhen_PrimaryParentUnknown() public {
        uint256 fake = uint256(keccak256("nope"));
        SeqoraTypes.ForkParams memory params = _forkParams(
            ALICE, fake, keccak256("child"), new bytes32[](0), _royalty(RECIPIENT, 100, 500), bytes32(uint256(1))
        );
        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.InvalidParent.selector, bytes32(fake)));
        vm.prank(ALICE);
        registry.forkRegister(params);
    }

    function test_ForkRegister_RevertsWhen_SelfParent_Primary() public {
        bytes32 childHash = bytes32(parentId);
        SeqoraTypes.ForkParams memory params = _forkParams(
            BOB, parentId, childHash, new bytes32[](0), _royalty(RECIPIENT, 100, 500), bytes32(uint256(1))
        );
        vm.expectRevert(abi.encodeWithSelector(DesignRegistry.SelfParent.selector, parentId));
        vm.prank(BOB);
        registry.forkRegister(params);
    }

    function test_ForkRegister_RevertsWhen_AdditionalParentZero() public {
        bytes32[] memory additional = new bytes32[](1);
        additional[0] = bytes32(0);
        SeqoraTypes.ForkParams memory params = _forkParams(
            BOB, parentId, keccak256("child-zero"), additional, _royalty(RECIPIENT, 100, 500), bytes32(uint256(1))
        );
        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.InvalidParent.selector, bytes32(0)));
        vm.prank(BOB);
        registry.forkRegister(params);
    }

    function test_ForkRegister_RevertsWhen_AdditionalParentIsSelf() public {
        bytes32 childHash = keccak256("self-additional");
        bytes32[] memory additional = new bytes32[](1);
        additional[0] = childHash;
        SeqoraTypes.ForkParams memory params =
            _forkParams(BOB, parentId, childHash, additional, _royalty(RECIPIENT, 100, 500), bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(DesignRegistry.SelfParent.selector, uint256(childHash)));
        vm.prank(BOB);
        registry.forkRegister(params);
    }

    function test_ForkRegister_RevertsWhen_AdditionalDuplicatesPrimary() public {
        bytes32[] memory additional = new bytes32[](1);
        additional[0] = bytes32(parentId);
        SeqoraTypes.ForkParams memory params = _forkParams(
            BOB, parentId, keccak256("dup-primary"), additional, _royalty(RECIPIENT, 100, 500), bytes32(uint256(1))
        );
        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.InvalidParent.selector, bytes32(parentId)));
        vm.prank(BOB);
        registry.forkRegister(params);
    }

    function test_ForkRegister_RevertsWhen_AdditionalParentUnknown() public {
        bytes32 fake = bytes32(uint256(keccak256("ghost")));
        bytes32[] memory additional = new bytes32[](1);
        additional[0] = fake;
        SeqoraTypes.ForkParams memory params =
            _forkParams(BOB, parentId, keccak256("c"), additional, _royalty(RECIPIENT, 100, 500), bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.InvalidParent.selector, fake));
        vm.prank(BOB);
        registry.forkRegister(params);
    }

    function test_ForkRegister_RevertsWhen_DuplicatesWithinAdditional() public {
        uint256 pB = _registerGenesis(BOB, keccak256("pB-dup"));
        bytes32[] memory additional = new bytes32[](2);
        additional[0] = bytes32(pB);
        additional[1] = bytes32(pB);
        SeqoraTypes.ForkParams memory params = _forkParams(
            CAROL, parentId, keccak256("c-dup"), additional, _royalty(RECIPIENT, 100, 500), bytes32(uint256(1))
        );
        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.InvalidParent.selector, bytes32(pB)));
        vm.prank(CAROL);
        registry.forkRegister(params);
    }

    function test_ForkRegister_RevertsWhen_CanonicalHashZero() public {
        SeqoraTypes.ForkParams memory params = _forkParams(
            BOB, parentId, bytes32(0), new bytes32[](0), _royalty(RECIPIENT, 100, 500), bytes32(uint256(1))
        );
        vm.expectRevert(SeqoraErrors.ZeroValue.selector);
        vm.prank(BOB);
        registry.forkRegister(params);
    }

    function test_ForkRegister_RevertsWhen_AlreadyRegistered() public {
        bytes32 childHash = keccak256("fork-dup");
        _forkFrom(BOB, parentId, childHash);
        SeqoraTypes.ForkParams memory params = _forkParams(
            CAROL, parentId, childHash, new bytes32[](0), _royalty(RECIPIENT, 100, 500), bytes32(uint256(1))
        );
        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.AlreadyRegistered.selector, uint256(childHash)));
        vm.prank(CAROL);
        registry.forkRegister(params);
    }

    function test_ForkRegister_RevertsWhen_ScreeningInvalid() public {
        ToggleableScreening tog = new ToggleableScreening(true);
        DesignRegistry r2 = new DesignRegistry("u", tog);

        bytes32 pHash = keccak256("parent-for-invalid");
        vm.prank(ALICE);
        uint256 pid =
            r2.register(ALICE, pHash, bytes32(0), "a", "c", _defaultRoyalty(), bytes32(uint256(1)), new bytes32[](0));

        tog.setValid(false);

        bytes32 cHash = keccak256("fork-invalid");
        bytes32 uid = bytes32(uint256(99));
        SeqoraTypes.ForkParams memory params =
            _forkParams(BOB, pid, cHash, new bytes32[](0), _royalty(RECIPIENT, 100, 500), uid);
        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.AttestationInvalid.selector, uid));
        vm.prank(BOB);
        r2.forkRegister(params);
    }

    function test_ForkRegister_AllowsZeroParentSplit() public {
        bytes32 childHash = keccak256("fork-zero-ps");
        SeqoraTypes.RoyaltyRule memory royalty = _royalty(RECIPIENT, 500, 0);
        SeqoraTypes.ForkParams memory params =
            _forkParams(BOB, parentId, childHash, new bytes32[](0), royalty, bytes32(uint256(1)));
        vm.prank(BOB);
        uint256 childId = registry.forkRegister(params);
        SeqoraTypes.Design memory d = registry.getDesign(childId);
        assertEq(d.royalty.parentSplitBps, 0);
    }

    function test_ForkRegister_RevertsWhen_ParentSplitBpsOutOfRange() public {
        uint16 badPs = SeqoraTypes.BPS + 1;
        SeqoraTypes.ForkParams memory params = _forkParams(
            BOB, parentId, keccak256("bad-ps"), new bytes32[](0), _royalty(RECIPIENT, 100, badPs), bytes32(uint256(1))
        );
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.BpsOutOfRange.selector, badPs));
        vm.prank(BOB);
        registry.forkRegister(params);
    }

    // ---------------------------------------------------------------------
    // M-01 — MAX_PARENTS cap
    // ---------------------------------------------------------------------

    function test_ForkRegister_AtMaxParents_Succeeds_Boundary() public {
        // 1 primary + 15 additional == 16 total (MAX_PARENTS).
        uint256 needed = SeqoraTypes.MAX_PARENTS - 1;
        bytes32[] memory additional = new bytes32[](needed);
        for (uint256 i = 0; i < needed; i++) {
            uint256 pid = _registerGenesis(ALICE, keccak256(abi.encode("p-max", i)));
            additional[i] = bytes32(pid);
        }

        bytes32 childHash = keccak256("child-at-max");
        SeqoraTypes.ForkParams memory params =
            _forkParams(BOB, parentId, childHash, additional, _royalty(RECIPIENT, 100, 1000), bytes32(uint256(1)));
        vm.prank(BOB);
        uint256 childId = registry.forkRegister(params);
        assertEq(registry.parentsOf(childId).length, SeqoraTypes.MAX_PARENTS, "exactly 16 parents stored");
    }

    function test_ForkRegister_OverMaxParents_Reverts_Boundary() public {
        // 1 primary + 16 additional == 17 total — reverts TooManyParents(17, 16).
        uint256 over = SeqoraTypes.MAX_PARENTS;
        bytes32[] memory additional = new bytes32[](over);
        for (uint256 i = 0; i < over; i++) {
            uint256 pid = _registerGenesis(ALICE, keccak256(abi.encode("p-over", i)));
            additional[i] = bytes32(pid);
        }

        bytes32 childHash = keccak256("child-over-max");
        SeqoraTypes.ForkParams memory params =
            _forkParams(BOB, parentId, childHash, additional, _royalty(RECIPIENT, 100, 1000), bytes32(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(IDesignRegistry.TooManyParents.selector, over + 1, SeqoraTypes.MAX_PARENTS)
        );
        vm.prank(BOB);
        registry.forkRegister(params);
    }

    // ---------------------------------------------------------------------
    // H-01 — registrant-bound attestation on forkRegister
    // ---------------------------------------------------------------------

    function test_ForkRegister_HSubstitution_RejectsWhenRegistrantIsBob() public {
        // Build a fresh registry backed by a scoped screener bound to (uid, childHash, ALICE).
        bytes32 uid = bytes32(uint256(0xF0F0));
        bytes32 childHash = keccak256("fork-alice");
        ScopedScreening scoped = new ScopedScreening(uid, childHash, ALICE);
        // We also need a scoped-pass for the parent genesis. Use a toggleable proxy: register the
        // parent under an AlwaysValidScreening registry, but to keep it simple we use a second
        // scoped screener + second registry. Simpler: use AlwaysValid for the parent registration
        // step then deploy registrar with scoped. We instead deploy a dedicated registry with an
        // "either/or" screener.
        // Simplest path: deploy a ToggleableScreening-like MultiValidScreening — but we already
        // have the primitives. Approach: use an AlwaysValidScreening instance just for parent
        // seeding, then run the real fork check using a separate registry bound to scoped.
        // For brevity we use a local dual-screener: accept `(anyUid, anyHash, ALICE)` always true
        // for parent seeding, but we need the fork to only pass for (uid, childHash, ALICE) — which
        // is already the scoped behavior if we use ALICE for both.
        // Parent registration: parentHash = keccak256("fork-alice-parent"), uid = uid, registrant
        // = ALICE => passes.
        // We can't do that because ScopedScreening checks exact uid+hash. So deploy a chain:
        //   1) Registry A (AlwaysValid) — register parent.
        //   2) A separate registry B bound to ScopedScreening that we test the fork against.
        // But `forkRegister` on B requires the parent to exist *in B*. So build B with a scoped
        // screener that is permissive for the parent too. We do this by using a composite screener.

        // Use a FlexibleScreening: valid for (uid0, parentHash, ALICE) AND (uid, childHash, ALICE).
        // We don't have one — compose two scopes via `isValid` OR logic inline with ToggleableScreening?
        // Cleaner: deploy FlexibleScreening built inline via a helper `DualScopedScreening` would
        // require a new mock. Easiest: use `AlwaysValidScreening`, seed parent, then pretend the
        // fork screener is `ScopedScreening` by deploying a FRESH DesignRegistry WITH `scoped` and
        // seeding its parent under the scoped tuple (uid0, parentHash, ALICE).

        // Approach: seed parent under the same scoped screener by aligning the parent's uid+hash
        // to what ScopedScreening expects. ScopedScreening only returns true for ONE tuple. So we
        // CAN'T seed a parent under the same scoped screener. Solution: use a helper screener that
        // answers true for BOTH the parent tuple and the child tuple.
        assertTrue(address(scoped) != address(0)); // keep reference
        // Use TwoTupleScreening (inline below) ...
        _runForkSubstitutionTest(uid, childHash, false);
    }

    function test_ForkRegister_HSubstitution_SucceedsWhenRegistrantIsAlice() public {
        _runForkSubstitutionTest(bytes32(uint256(0xF0F1)), keccak256("fork-alice-ok"), true);
    }

    function _runForkSubstitutionTest(bytes32 uid, bytes32 childHash, bool useAliceAsRegistrant) internal {
        // Seed parent in a fresh registry backed by AlwaysValidScreening.
        AlwaysValidScreening v = new AlwaysValidScreening();
        DesignRegistry seed = new DesignRegistry("u", v);
        bytes32 parentHash = keccak256(abi.encode("fork-parent", uid));
        vm.prank(ALICE);
        uint256 parentSeedId = seed.register(
            ALICE, parentHash, bytes32(0), "a", "c", _defaultRoyalty(), bytes32(uint256(0xAA)), new bytes32[](0)
        );

        // Now deploy a second registry bound to a scoped screener. We cannot reuse the parent
        // there because that registry's state is empty. So instead: swap the screener on the
        // seeded registry via a screener that answers OR-logic. Simpler: test substitution on the
        // seeded registry directly, using ToggleableScreening — set it invalid for a moment and
        // confirm AttestationInvalid. But that doesn't prove the registrant binding.
        //
        // Better plan: deploy a *dual-scoped* registry from scratch. The parent registration on
        // that registry needs to pass a scoped screen bound to (uidParent, parentHash, ALICE); the
        // fork registration needs a scoped screen bound to (uid, childHash, <ALICE or BOB>).
        // We implement this with a simple dual-tuple screener below.
        DualScopedScreening dual =
            new DualScopedScreening(bytes32(uint256(0xAA)), parentHash, ALICE, uid, childHash, ALICE);
        DesignRegistry r = new DesignRegistry("u", dual);
        // Seed parent in `r`.
        vm.prank(ALICE);
        uint256 parentId_ = r.register(
            ALICE, parentHash, bytes32(0), "a", "c", _defaultRoyalty(), bytes32(uint256(0xAA)), new bytes32[](0)
        );
        assertEq(parentId_, parentSeedId, "parent tokenIds match across registries (hash-derived)");

        // Build fork params.
        address registrant = useAliceAsRegistrant ? ALICE : BOB;
        SeqoraTypes.ForkParams memory params =
            _forkParams(registrant, parentId_, childHash, new bytes32[](0), _royalty(RECIPIENT, 100, 1000), uid);

        if (useAliceAsRegistrant) {
            // Bob is a relayer submitting with registrant=Alice.
            vm.prank(BOB);
            uint256 childId = r.forkRegister(params);
            assertEq(r.balanceOf(ALICE, childId), 1);
            assertEq(r.balanceOf(BOB, childId), 0);
            assertEq(r.getDesign(childId).registrant, ALICE);
        } else {
            // Bob tries to substitute himself as registrant; scoped screener rejects.
            vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.AttestationInvalid.selector, uid));
            vm.prank(BOB);
            r.forkRegister(params);
        }
    }

    function test_ForkRegister_Relayer_MintsToRegistrant() public {
        // Seed a parent under ALWAYS-VALID screening. Then a relayer forks on Alice's behalf.
        Relayer relayer = new Relayer();
        bytes32 childHash = keccak256("fork-relayer");
        SeqoraTypes.ForkParams memory params = _forkParams(
            ALICE, parentId, childHash, new bytes32[](0), _royalty(RECIPIENT, 100, 1000), bytes32(uint256(2))
        );
        uint256 childId = relayer.relayForkRegister(registry, params);
        assertEq(registry.balanceOf(ALICE, childId), 1);
        assertEq(registry.balanceOf(address(relayer), childId), 0);
        assertEq(registry.getDesign(childId).registrant, ALICE);
    }
}

/// @notice Test-only screener that accepts TWO preconfigured (uid, hash, registrant) tuples.
/// @dev Needed to seed a parent + test a fork in the same scoped-registry configuration.
contract DualScopedScreening is IScreeningAttestations {
    bytes32 public immutable UID_A;
    bytes32 public immutable HASH_A;
    address public immutable REG_A;
    bytes32 public immutable UID_B;
    bytes32 public immutable HASH_B;
    address public immutable REG_B;

    constructor(bytes32 uidA, bytes32 hashA, address regA, bytes32 uidB, bytes32 hashB, address regB) {
        UID_A = uidA;
        HASH_A = hashA;
        REG_A = regA;
        UID_B = uidB;
        HASH_B = hashB;
        REG_B = regB;
    }

    function registerAttester(address, SeqoraTypes.ScreenerKind) external { }
    function revokeAttester(address, string calldata) external { }

    function getScreenerKind(address) external pure returns (SeqoraTypes.ScreenerKind) {
        return SeqoraTypes.ScreenerKind.Other;
    }

    function isApproved(address) external pure returns (bool) {
        return true;
    }

    function isValid(bytes32 uid, bytes32 canonicalHash, address registrant) external view returns (bool) {
        if (uid == UID_A && canonicalHash == HASH_A && registrant == REG_A) return true;
        if (uid == UID_B && canonicalHash == HASH_B && registrant == REG_B) return true;
        return false;
    }
}

// =============================================================================
// UNIT — views
// =============================================================================

contract DesignRegistry_Views_Test is BaseTest {
    function test_GetDesign_RevertsWhen_UnknownToken() public {
        uint256 fake = 0xDEAD;
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.UnknownToken.selector, fake));
        registry.getDesign(fake);
    }

    function test_ParentsOf_RevertsWhen_UnknownToken() public {
        uint256 fake = 0xBEEF;
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.UnknownToken.selector, fake));
        registry.parentsOf(fake);
    }

    function test_IsRegistered_ReturnsFalseForUnknown() public view {
        assertFalse(registry.isRegistered(uint256(keccak256("never"))));
    }

    function test_IsRegistered_TrueAfterRegister() public {
        uint256 id = _registerGenesis(ALICE, keccak256("x"));
        assertTrue(registry.isRegistered(id));
    }

    function test_ParentsOf_GenesisIsEmpty() public {
        uint256 id = _registerGenesis(ALICE, keccak256("g"));
        bytes32[] memory p = registry.parentsOf(id);
        assertEq(p.length, 0);
    }
}

// =============================================================================
// UNIT — ERC-165 / ERC-1155 conformance
// =============================================================================

contract DesignRegistry_Conformance_Test is BaseTest {
    function test_SupportsInterface_IDesignRegistry() public view {
        assertTrue(registry.supportsInterface(type(IDesignRegistry).interfaceId));
    }

    function test_SupportsInterface_ERC165() public view {
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId));
    }

    function test_SupportsInterface_IERC1155() public view {
        assertTrue(registry.supportsInterface(type(IERC1155).interfaceId));
    }

    function test_SupportsInterface_IERC1155MetadataURI() public view {
        assertTrue(registry.supportsInterface(type(IERC1155MetadataURI).interfaceId));
    }

    function test_SupportsInterface_RejectsRandom() public view {
        assertFalse(registry.supportsInterface(bytes4(0xdeadbeef)));
    }

    function test_Uri_ReturnsBaseUri() public view {
        assertEq(registry.uri(0), BASE_URI);
    }
}

// =============================================================================
// UNIT — reentrancy
// =============================================================================

contract DesignRegistry_Reentrancy_Test is Test {
    address internal constant RECIPIENT = address(0xEEEE);

    /// @notice DesignRegistry.register calls SCREENING.isValid via STATICCALL (interface is `view`),
    ///         so a hostile screener cannot make any state-mutating re-entry into register. The real
    ///         reentrancy surface is the ERC-1155 receiver hook fired from `_mint`. The nonReentrant
    ///         guard must block a recursive register() call from inside that hook.
    function test_Register_RevertsWhen_ReceiverReentersRegister() public {
        AlwaysValidScreening good = new AlwaysValidScreening();
        DesignRegistry r = new DesignRegistry("u", good);

        ReentrantReceiver hostile = new ReentrantReceiver();
        hostile.setRegistry(r);
        hostile.arm();

        SeqoraTypes.RoyaltyRule memory royalty =
            SeqoraTypes.RoyaltyRule({ recipient: RECIPIENT, bps: 100, parentSplitBps: 0 });

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(address(hostile));
        r.register(
            address(hostile), keccak256("outer"), bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0)
        );
    }
}

// =============================================================================
// UNIT — ERC-1155 receiver semantics
// =============================================================================

contract DesignRegistry_Receiver_Test is BaseTest {
    function test_Register_MintsToERC1155HolderContract() public {
        ERC1155HolderStub holder = new ERC1155HolderStub();
        bytes32 h = keccak256("to-holder");

        vm.prank(address(holder));
        uint256 tokenId = registry.register(
            address(holder), h, bytes32(0), "a", "c", _defaultRoyalty(), bytes32(uint256(1)), new bytes32[](0)
        );

        assertEq(registry.balanceOf(address(holder), tokenId), 1);
    }

    function test_Register_RevertsWhen_RegistrantIsNonReceiverContract() public {
        bytes32 h = keccak256("to-nonreceiver");
        vm.prank(address(this));
        vm.expectRevert(); // OZ ERC1155InvalidReceiver — selector varies, broad revert is fine here
        registry.register(
            address(this), h, bytes32(0), "a", "c", _defaultRoyalty(), bytes32(uint256(1)), new bytes32[](0)
        );
    }
}

// =============================================================================
// FUZZ
// =============================================================================

contract DesignRegistry_Fuzz_Test is BaseTest {
    function testFuzz_Register_AnyValidPayload(
        bytes32 canonicalHash,
        bytes32 ga4ghSeqhash,
        address registrant,
        uint16 bpsSeed,
        bytes32 attUid
    ) public {
        vm.assume(canonicalHash != bytes32(0));
        vm.assume(registrant != address(0));
        vm.assume(uint160(registrant) > 0xFF);
        vm.assume(registrant.code.length == 0);
        uint16 bps = uint16(bpsSeed % (SeqoraTypes.MAX_ROYALTY_BPS + 1));
        address recipient = bps == 0 ? address(0) : RECIPIENT;
        SeqoraTypes.RoyaltyRule memory royalty = _royalty(recipient, bps, 0);

        vm.prank(registrant);
        uint256 tokenId = registry.register(
            registrant, canonicalHash, ga4ghSeqhash, "ar://tx", "ceramic://s", royalty, attUid, new bytes32[](0)
        );

        assertEq(tokenId, uint256(canonicalHash));
        assertTrue(registry.isRegistered(tokenId));
        assertEq(registry.balanceOf(registrant, tokenId), 1);
        SeqoraTypes.Design memory d = registry.getDesign(tokenId);
        assertEq(d.registrant, registrant);
        assertEq(d.royalty.bps, bps);
        assertEq(d.parentTokenIds.length, 0);
    }

    function testFuzz_Register_RevertsWhen_RoyaltyBpsOverMax(uint16 bpsSeed) public {
        bpsSeed = uint16(bound(bpsSeed, SeqoraTypes.MAX_ROYALTY_BPS + 1, type(uint16).max));
        bytes32 h = keccak256(abi.encode("fuzz-bps", bpsSeed));

        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.BpsOutOfRange.selector, bpsSeed));
        vm.prank(ALICE);
        registry.register(
            ALICE, h, bytes32(0), "a", "c", _royalty(RECIPIENT, bpsSeed, 0), bytes32(uint256(1)), new bytes32[](0)
        );
    }

    function testFuzz_ForkRegister_ParentSplitBps(uint16 parentSplitSeed) public {
        bytes32 pHash = keccak256("fuzz-parent");
        uint256 pid = _registerGenesis(ALICE, pHash);

        uint16 ps = uint16(bound(parentSplitSeed, 0, SeqoraTypes.BPS));
        bytes32 cHash = keccak256(abi.encode("fuzz-child", ps));
        SeqoraTypes.ForkParams memory params =
            _forkParams(BOB, pid, cHash, new bytes32[](0), _royalty(RECIPIENT, 100, ps), bytes32(uint256(1)));
        vm.prank(BOB);
        uint256 cid = registry.forkRegister(params);

        SeqoraTypes.Design memory d = registry.getDesign(cid);
        assertEq(d.royalty.parentSplitBps, ps);
    }

    function testFuzz_ForkRegister_ParentSplitOverRange_Reverts(uint32 psSeed) public {
        uint16 bad = uint16(bound(psSeed, SeqoraTypes.BPS + 1, type(uint16).max));
        bytes32 pHash = keccak256("fuzz-parent-2");
        uint256 pid = _registerGenesis(ALICE, pHash);

        SeqoraTypes.ForkParams memory params = _forkParams(
            BOB,
            pid,
            keccak256(abi.encode("bad-ps", bad)),
            new bytes32[](0),
            _royalty(RECIPIENT, 100, bad),
            bytes32(uint256(1))
        );
        vm.expectRevert(abi.encodeWithSelector(SeqoraErrors.BpsOutOfRange.selector, bad));
        vm.prank(BOB);
        registry.forkRegister(params);
    }

    function testFuzz_ForkRegister_ArbitraryParents(
        bytes32 primarySeed,
        bytes32 childSeed,
        uint8 extraCount,
        address registrant
    ) public {
        vm.assume(primarySeed != bytes32(0));
        vm.assume(childSeed != bytes32(0));
        vm.assume(primarySeed != childSeed);
        vm.assume(registrant != address(0));
        vm.assume(uint160(registrant) > 0xFF);
        vm.assume(registrant.code.length == 0);

        bytes32 pHash = keccak256(abi.encode("fp", primarySeed));
        uint256 pid = _registerGenesis(ALICE, pHash);

        uint256 n = uint256(extraCount) % 7;

        bytes32[] memory additional = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 extraHash = keccak256(abi.encode("extra", primarySeed, i));
            if (extraHash == pHash || extraHash == bytes32(0)) continue;
            uint256 extraId = _registerGenesis(ALICE, extraHash);
            additional[i] = bytes32(extraId);
        }
        for (uint256 i = 0; i < n; i++) {
            if (additional[i] == bytes32(0)) return;
        }

        bytes32 cHash = keccak256(abi.encode("fc", childSeed));
        if (cHash == pHash) return;
        for (uint256 i = 0; i < n; i++) {
            if (cHash == additional[i]) return;
        }
        if (registry.isRegistered(uint256(cHash))) return;

        SeqoraTypes.ForkParams memory params =
            _forkParams(registrant, pid, cHash, additional, _royalty(RECIPIENT, 100, 1000), bytes32(uint256(1)));
        vm.prank(registrant);
        uint256 cid = registry.forkRegister(params);

        bytes32[] memory stored = registry.parentsOf(cid);
        assertEq(stored.length, n + 1, "primary + n additional");
        assertEq(stored[0], bytes32(pid));
    }

    function testFuzz_Register_HRegistrantBinding(address attacker, address victim, bytes32 attUid, bytes32 hash)
        public
    {
        vm.assume(attacker != victim);
        vm.assume(attacker != address(0) && victim != address(0));
        vm.assume(uint160(attacker) > 0xFF && uint160(victim) > 0xFF);
        vm.assume(attacker.code.length == 0 && victim.code.length == 0);
        vm.assume(hash != bytes32(0));
        vm.assume(attUid != bytes32(0));

        // Deploy a scoped screener that is valid ONLY for (attUid, hash, victim).
        ScopedScreening scoped = new ScopedScreening(attUid, hash, victim);
        DesignRegistry r = new DesignRegistry("u", scoped);

        // Attacker substitutes themselves as registrant — must revert.
        vm.expectRevert(abi.encodeWithSelector(IDesignRegistry.AttestationInvalid.selector, attUid));
        vm.prank(attacker);
        r.register(attacker, hash, bytes32(0), "a", "c", _defaultRoyalty(), attUid, new bytes32[](0));
    }
}
