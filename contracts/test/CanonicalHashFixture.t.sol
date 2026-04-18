// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { DesignRegistry } from "../src/DesignRegistry.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";

import { BaseTest } from "./helpers/BaseTest.sol";

/// @notice Cross-language digest fixture: pins DesignRegistry's tokenId derivation to the exact
///         bytes produced by the off-chain canonicalizer (the seqora/canonicalize workspace
///         package, running URDNA2015 + keccak256). The fixture JSON is regenerated from real
///         SBOL/RDF inputs by `packages/canonicalize/scripts/generate-fixture.ts`; this test
///         asserts that the `expectedCanonicalHash` each entry declares is the tokenId a
///         `register(...)` call would mint for that canonicalHash.
///
/// @dev This is the cross-language half of the drift-elimination fix: the TypeScript tool and
///      the Solidity registry must agree on `uint256(keccak256(URDNA2015(sbol)))`, or the
///      frontend / ingest tool and the chain will disagree on tokenIds. If this test fails,
///      either the off-chain pipeline or the on-chain `tokenId = uint256(canonicalHash)`
///      derivation has drifted — do NOT "fix" by regenerating the fixture without understanding
///      which side changed.
contract CanonicalHashFixture_Test is BaseTest {
    string internal constant FIXTURE_PATH = "./test/fixtures/canonical-hash.json";

    function test_Fixture_TokenIdMatchesExpectedCanonicalHash() public {
        string memory json = vm.readFile(FIXTURE_PATH);

        // Make sure the fixture actually has entries — guard against a future generator bug
        // silently emitting an empty array. The generator emits a flat top-level
        // `expectedCanonicalHashes` array precisely because Foundry's JSON cheatcode parser
        // doesn't support the JSONPath `[*]` wildcard.
        bytes32[] memory expectedHashes = vm.parseJsonBytes32Array(json, ".expectedCanonicalHashes");
        assertGt(expectedHashes.length, 0, "fixture has no entries");

        for (uint256 i = 0; i < expectedHashes.length; i++) {
            bytes32 canonicalHash = expectedHashes[i];
            assertTrue(canonicalHash != bytes32(0), "fixture entry has zero hash");

            // Each registration needs a unique registrant so the ERC-1155 mint path doesn't
            // collide when the same canonicalHash is asserted twice (the two fixture entries
            // encode the same graph as RDF/XML and Turtle and MUST produce the same hash).
            address registrant = address(uint160(uint256(keccak256(abi.encode("fixture-registrant", i)))));
            vm.assume(registrant != address(0));

            // Use a fresh registry for every entry so identical hashes across RDF/XML and
            // Turtle serializations don't collide on the AlreadyRegistered guard. This keeps
            // the fixture schema flexible — future entries can legitimately share a hash.
            DesignRegistry r = new DesignRegistry(BASE_URI, screening);

            vm.prank(registrant);
            uint256 tokenId = r.register(
                registrant,
                canonicalHash,
                bytes32(0),
                "ar://fixture",
                "ceramic://fixture",
                _defaultRoyalty(),
                bytes32(uint256(1)),
                new bytes32[](0)
            );

            assertEq(tokenId, uint256(canonicalHash), "tokenId must equal uint256(canonicalHash)");
            assertTrue(r.isRegistered(tokenId), "design must be registered");

            SeqoraTypes.Design memory design = r.getDesign(tokenId);
            assertEq(design.canonicalHash, canonicalHash, "stored canonicalHash must match fixture");
            assertEq(design.registrant, registrant, "stored registrant must match mint target");
        }
    }

    function test_Fixture_AllEntriesParseable() public view {
        string memory json = vm.readFile(FIXTURE_PATH);
        // Sanity parse: versions / counts / per-entry strings. If the schema ever drifts this
        // assertion catches it before the main test silently skips entries.
        uint256 version = vm.parseJsonUint(json, ".version");
        assertEq(version, 1, "fixture schema version must be 1");

        bytes32[] memory expectedHashes = vm.parseJsonBytes32Array(json, ".expectedCanonicalHashes");
        assertGt(expectedHashes.length, 0, "fixture must declare at least one entry");
    }
}
