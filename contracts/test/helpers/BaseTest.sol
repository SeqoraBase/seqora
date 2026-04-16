// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { DesignRegistry } from "../../src/DesignRegistry.sol";
import { IScreeningAttestations } from "../../src/interfaces/IScreeningAttestations.sol";
import { SeqoraTypes } from "../../src/libraries/SeqoraTypes.sol";

import { AlwaysValidScreening } from "./MockScreening.sol";

/// @notice Shared harness for DesignRegistry-centric tests.
/// @dev Spins up an AlwaysValidScreening + DesignRegistry in setUp. Subclasses can override
///      `_deployScreening` to swap in one of the other mock screeners.
abstract contract BaseTest is Test {
    string internal constant BASE_URI = "ipfs://seqora/{id}.json";

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant RECIPIENT = address(0xEEEE);

    DesignRegistry internal registry;
    IScreeningAttestations internal screening;

    function setUp() public virtual {
        screening = _deployScreening();
        registry = new DesignRegistry(BASE_URI, screening);
        // Label for trace readability.
        vm.label(address(registry), "DesignRegistry");
        vm.label(address(screening), "Screening");
        vm.label(ALICE, "ALICE");
        vm.label(BOB, "BOB");
        vm.label(CAROL, "CAROL");
        vm.label(RECIPIENT, "RECIPIENT");
    }

    function _deployScreening() internal virtual returns (IScreeningAttestations) {
        return new AlwaysValidScreening();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _royalty(address recipient, uint16 bps, uint16 parentSplitBps)
        internal
        pure
        returns (SeqoraTypes.RoyaltyRule memory r)
    {
        r = SeqoraTypes.RoyaltyRule({ recipient: recipient, bps: bps, parentSplitBps: parentSplitBps });
    }

    function _defaultRoyalty() internal pure returns (SeqoraTypes.RoyaltyRule memory) {
        return _royalty(RECIPIENT, 500, 0);
    }

    /// @notice Register a genesis design with canned defaults. Prank'd as `registrant`.
    function _registerGenesis(address registrant, bytes32 canonicalHash) internal returns (uint256 tokenId) {
        vm.prank(registrant);
        tokenId = registry.register(
            registrant,
            canonicalHash,
            bytes32(0),
            "ar://tx",
            "ceramic://stream",
            _defaultRoyalty(),
            bytes32(uint256(1)),
            new bytes32[](0)
        );
    }

    /// @notice Register a single-parent fork. Prank'd as `registrant`.
    function _forkFrom(address registrant, uint256 parentTokenId, bytes32 canonicalHash)
        internal
        returns (uint256 tokenId)
    {
        SeqoraTypes.ForkParams memory params = SeqoraTypes.ForkParams({
            registrant: registrant,
            primaryParentTokenId: parentTokenId,
            additionalParentTokenIds: new bytes32[](0),
            canonicalHash: canonicalHash,
            ga4ghSeqhash: bytes32(0),
            arweaveTx: "ar://fork",
            ceramicStreamId: "ceramic://fork",
            royaltyRule: _royalty(RECIPIENT, 500, 1000),
            screeningAttestationUID: bytes32(uint256(2)),
            metadataURI: ""
        });
        vm.prank(registrant);
        tokenId = registry.forkRegister(params);
    }

    /// @notice Helper to build a ForkParams with canned defaults.
    function _forkParams(
        address registrant,
        uint256 primaryParentTokenId,
        bytes32 canonicalHash,
        bytes32[] memory additionalParents,
        SeqoraTypes.RoyaltyRule memory royalty,
        bytes32 attUid
    ) internal pure returns (SeqoraTypes.ForkParams memory params) {
        params = SeqoraTypes.ForkParams({
            registrant: registrant,
            primaryParentTokenId: primaryParentTokenId,
            additionalParentTokenIds: additionalParents,
            canonicalHash: canonicalHash,
            ga4ghSeqhash: bytes32(0),
            arweaveTx: "a",
            ceramicStreamId: "c",
            royaltyRule: royalty,
            screeningAttestationUID: attUid,
            metadataURI: ""
        });
    }
}
