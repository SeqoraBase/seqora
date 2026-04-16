// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { DesignRegistry } from "../../src/DesignRegistry.sol";
import { LicenseRegistry } from "../../src/LicenseRegistry.sol";
import { IScreeningAttestations } from "../../src/interfaces/IScreeningAttestations.sol";
import { IDesignRegistry } from "../../src/interfaces/IDesignRegistry.sol";
import { SeqoraTypes } from "../../src/libraries/SeqoraTypes.sol";

import { AlwaysValidScreening } from "./MockScreening.sol";

/// @notice Upgradeable v2 mock used by the UUPS upgrade test. Adds a new getter and a bumped
///         version constant while keeping the storage layout compatible with v1.
contract LicenseRegistryV2Mock is LicenseRegistry {
    /// @notice Constant bumped in v2 so tests can observe the upgrade took effect.
    string public constant VERSION = "v2-mock";

    /// @notice A v2-only function that does NOT exist in v1.
    function v2Only() external pure returns (uint256) {
        return 4242;
    }
}

/// @notice Harness that stands up the full DesignRegistry + ScreeningAttestations mock +
///         LicenseRegistry UUPS proxy stack. Subclasses get ergonomic helpers for registering
///         designs, templates, and granting licenses.
abstract contract LicenseRegistryHarness is Test {
    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------

    address internal constant GOVERNANCE = address(0x6060);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant DAVE = address(0xDA4E);
    address internal constant RECIPIENT = address(0xEEEE);

    string internal constant DESIGN_BASE_URI = "ipfs://seqora/{id}.json";

    // -------------------------------------------------------------------------
    // Deployed contracts
    // -------------------------------------------------------------------------

    IScreeningAttestations internal screening;
    DesignRegistry internal designs;
    LicenseRegistry internal impl;
    LicenseRegistry internal licenses; // proxy, cast to LicenseRegistry for ergonomic calls
    ERC1967Proxy internal proxy;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public virtual {
        screening = _deployScreening();
        designs = new DesignRegistry(DESIGN_BASE_URI, screening);

        impl = new LicenseRegistry();
        bytes memory initCalldata =
            abi.encodeCall(LicenseRegistry.initialize, (IDesignRegistry(address(designs)), GOVERNANCE));
        proxy = new ERC1967Proxy(address(impl), initCalldata);
        licenses = LicenseRegistry(address(proxy));

        vm.label(address(screening), "Screening");
        vm.label(address(designs), "DesignRegistry");
        vm.label(address(impl), "LicenseRegistry.impl");
        vm.label(address(proxy), "LicenseRegistry.proxy");
        vm.label(GOVERNANCE, "GOVERNANCE");
        vm.label(ALICE, "ALICE");
        vm.label(BOB, "BOB");
        vm.label(CAROL, "CAROL");
        vm.label(DAVE, "DAVE");
    }

    function _deployScreening() internal virtual returns (IScreeningAttestations) {
        return new AlwaysValidScreening();
    }

    // -------------------------------------------------------------------------
    // Helpers — designs
    // -------------------------------------------------------------------------

    function _defaultRoyalty() internal pure returns (SeqoraTypes.RoyaltyRule memory) {
        return SeqoraTypes.RoyaltyRule({ recipient: RECIPIENT, bps: 500, parentSplitBps: 0 });
    }

    /// @notice Register a genesis design in the underlying DesignRegistry. The registrant is
    ///         pranked as both the mint target and the caller so LicenseRegistry auth checks
    ///         against `registrant` land on a known address.
    function _registerDesign(address registrant, bytes32 canonicalHash) internal returns (uint256 tokenId) {
        vm.prank(registrant);
        tokenId = designs.register(
            registrant,
            canonicalHash,
            bytes32(0),
            "ar://tx",
            "ceramic://s",
            _defaultRoyalty(),
            bytes32(uint256(1)),
            new bytes32[](0)
        );
    }

    function _registerDesign(address registrant) internal returns (uint256 tokenId) {
        // Unique hash per call via the registrant + block counter.
        bytes32 canonical = keccak256(abi.encode(registrant, block.number, block.timestamp, gasleft()));
        return _registerDesign(registrant, canonical);
    }

    // -------------------------------------------------------------------------
    // Helpers — templates
    // -------------------------------------------------------------------------

    function _buildTemplate(bytes32 licenseId, uint16 pilFlags, uint32 defaultDuration)
        internal
        pure
        returns (SeqoraTypes.LicenseTemplate memory t)
    {
        bool commercial = (pilFlags & SeqoraTypes.PIL_COMMERCIAL) != 0;
        bool attribution = (pilFlags & SeqoraTypes.PIL_ATTRIBUTION) != 0;
        t = SeqoraTypes.LicenseTemplate({
            licenseId: licenseId,
            name: "Tmpl",
            uri: "ipfs://tmpl",
            commercialUse: commercial,
            requiresAttribution: attribution,
            active: true,
            pilFlags: pilFlags,
            defaultDuration: defaultDuration
        });
    }

    function _createTemplate(bytes32 licenseId, uint16 pilFlags, uint32 defaultDuration) internal {
        SeqoraTypes.LicenseTemplate memory t = _buildTemplate(licenseId, pilFlags, defaultDuration);
        vm.prank(GOVERNANCE);
        licenses.registerLicenseTemplate(t);
    }

    // -------------------------------------------------------------------------
    // Helpers — grants
    // -------------------------------------------------------------------------

    /// @notice Grant a license from the tokenId registrant. Default expiry 0 (lets template
    ///         defaultDuration apply), feePaid 0.
    function _grantLicense(address registrant, uint256 tokenId, bytes32 licenseId, address licensee)
        internal
        returns (uint256 licenseTokenId)
    {
        vm.prank(registrant);
        licenseTokenId = licenses.grantLicense(tokenId, licenseId, licensee, 0, 0);
    }

    function _grantLicenseWithExpiry(
        address registrant,
        uint256 tokenId,
        bytes32 licenseId,
        address licensee,
        uint64 expiry,
        uint128 feePaid
    ) internal returns (uint256 licenseTokenId) {
        vm.prank(registrant);
        licenseTokenId = licenses.grantLicense(tokenId, licenseId, licensee, expiry, feePaid);
    }
}
