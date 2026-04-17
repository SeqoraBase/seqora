// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { Vm } from "forge-std/Vm.sol";

import { LicenseRegistry } from "../../src/LicenseRegistry.sol";
import { DesignRegistry } from "../../src/DesignRegistry.sol";
import { ILicenseRegistry } from "../../src/interfaces/ILicenseRegistry.sol";
import { SeqoraTypes } from "../../src/libraries/SeqoraTypes.sol";

/// @notice Invariant-test handler. Bounds inputs so calls land on meaningful code paths, and
///         exposes counters the invariants can iterate. Captures emitted Granted/Revoked events
///         for the per-tokenId live-count invariant.
contract LicenseRegistryHandler is CommonBase, StdCheats, StdUtils {
    LicenseRegistry public immutable registry;
    DesignRegistry public immutable designs;
    address public immutable governance;

    // Template catalog we register at construction (well-known pilFlags).
    bytes32 public constant T_ATTR = keccak256("H_ATTR");
    bytes32 public constant T_EXCL = keccak256("H_EXCL");
    bytes32 public constant T_XFER = keccak256("H_XFER");
    bytes32[] internal _templateIds;

    // Actor bank
    address[] internal _actors;
    // Registered design tokenIds tracked via DesignRegistry
    uint256[] internal _designIds;
    // Registrants indexed same as _designIds
    mapping(uint256 => address) internal _designRegistrants;

    // Licenses minted by this handler
    uint256[] internal _licenseIds;
    // Track tokenIds that have EVER had an exclusive live grant
    mapping(uint256 => uint256) public liveExclusiveCount;

    // Per-tokenId live count (granted - revoked), per the invariant requirement
    mapping(uint256 => int256) public liveByToken;

    // Counters
    uint256 public grantAttempts;
    uint256 public grantSuccesses;
    uint256 public revokeAttempts;
    uint256 public revokeSuccesses;
    uint256 public transferAttempts;
    uint256 public transferSuccesses;

    constructor(LicenseRegistry registry_, DesignRegistry designs_, address governance_) {
        registry = registry_;
        designs = designs_;
        governance = governance_;

        _actors.push(address(0xA11CE));
        _actors.push(address(0xB0B));
        _actors.push(address(0xCA401));
        _actors.push(address(0xDA4E));

        // Register templates from governance so grantLicense has at least one valid id.
        _seedTemplate(T_ATTR, SeqoraTypes.PIL_ATTRIBUTION, 0);
        _seedTemplate(T_EXCL, SeqoraTypes.PIL_EXCLUSIVE, 0);
        _seedTemplate(T_XFER, SeqoraTypes.PIL_COMMERCIAL | SeqoraTypes.PIL_TRANSFERABLE, 0);
        _templateIds.push(T_ATTR);
        _templateIds.push(T_EXCL);
        _templateIds.push(T_XFER);

        // Seed a few designs across actors so grantLicense has valid tokenIds.
        for (uint256 i = 0; i < 3; i++) {
            _seedDesign(_actors[i]);
        }
    }

    // -------------------------------------------------------------------------
    // View helpers for invariant assertions
    // -------------------------------------------------------------------------

    function licenseCount() external view returns (uint256) {
        return _licenseIds.length;
    }

    function licenseAt(uint256 i) external view returns (uint256) {
        return _licenseIds[i];
    }

    function designCount() external view returns (uint256) {
        return _designIds.length;
    }

    function designAt(uint256 i) external view returns (uint256) {
        return _designIds[i];
    }

    function templateCount() external view returns (uint256) {
        return _templateIds.length;
    }

    function templateAt(uint256 i) external view returns (bytes32) {
        return _templateIds[i];
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    function grant(uint8 actorIdx, uint8 designIdx, uint8 tmplIdx, uint8 licenseeIdx, uint32 feePaid) external {
        grantAttempts++;
        uint256 designTokenId = _designIds[designIdx % _designIds.length];
        address registrant = _designRegistrants[designTokenId];
        address licensee = _actors[licenseeIdx % _actors.length];
        bytes32 tmpl = _templateIds[tmplIdx % _templateIds.length];

        vm.prank(registrant);
        try registry.grantLicense(designTokenId, tmpl, licensee, 0, feePaid) returns (uint256 lt) {
            _licenseIds.push(lt);
            liveByToken[designTokenId] += 1;
            if (tmpl == T_EXCL) liveExclusiveCount[designTokenId] += 1;
            grantSuccesses++;
        } catch {
            // Expected: ExclusiveAlreadyGranted on repeated exclusive attempts.
        }
        actorIdx; // silence warning
    }

    function revoke(uint8 licIdx) external {
        revokeAttempts++;
        if (_licenseIds.length == 0) return;
        uint256 lt = _licenseIds[licIdx % _licenseIds.length];
        SeqoraTypes.License memory l = registry.getLicense(lt);
        if (l.revoked) return;
        address registrant = _designRegistrants[l.tokenId];

        vm.prank(registrant);
        try registry.revokeLicense(lt, "inv") {
            liveByToken[l.tokenId] -= 1;
            if (l.licenseId == T_EXCL) liveExclusiveCount[l.tokenId] -= 1;
            revokeSuccesses++;
        } catch { }
    }

    function xfer(uint8 licIdx, uint8 toIdx) external {
        transferAttempts++;
        if (_licenseIds.length == 0) return;
        uint256 lt = _licenseIds[licIdx % _licenseIds.length];
        address from = registry.ownerOf(lt);
        address to = _actors[toIdx % _actors.length];
        if (from == to) return;

        vm.prank(from);
        try registry.safeTransferFrom(from, to, lt) {
            transferSuccesses++;
        } catch { }
    }

    /// @notice Bogus grant spam to a unique junk address. Exercises the bounded-gas invariant —
    ///         `checkLicenseValid(tokenId, honestUser)` must remain bounded even as the
    ///         total grant count grows. Call count in the invariant run bounds the spam.
    function spamGrant(uint8 designIdx) external {
        grantAttempts++;
        uint256 designTokenId = _designIds[designIdx % _designIds.length];
        address registrant = _designRegistrants[designTokenId];
        address junk = address(uint160(0x20000 + grantAttempts));
        vm.prank(registrant);
        try registry.grantLicense(designTokenId, T_ATTR, junk, 0, 0) returns (uint256 lt) {
            _licenseIds.push(lt);
            liveByToken[designTokenId] += 1;
            grantSuccesses++;
        } catch { }
    }

    // -------------------------------------------------------------------------
    // Seeding
    // -------------------------------------------------------------------------

    function _seedTemplate(bytes32 id, uint16 flags, uint32 duration) internal {
        SeqoraTypes.LicenseTemplate memory t = SeqoraTypes.LicenseTemplate({
            licenseId: id,
            name: "H",
            uri: "u",
            commercialUse: (flags & SeqoraTypes.PIL_COMMERCIAL) != 0,
            requiresAttribution: (flags & SeqoraTypes.PIL_ATTRIBUTION) != 0,
            active: true,
            pilFlags: flags,
            defaultDuration: duration
        });
        vm.prank(governance);
        registry.registerLicenseTemplate(t);
    }

    function _seedDesign(address registrant) internal {
        bytes32 canonical = keccak256(abi.encode("H-design", registrant, _designIds.length));
        SeqoraTypes.RoyaltyRule memory royalty =
            SeqoraTypes.RoyaltyRule({ recipient: address(0xEEEE), bps: 500, parentSplitBps: 0 });
        vm.prank(registrant);
        uint256 tokenId = designs.register(
            registrant, canonical, bytes32(0), "a", "c", royalty, bytes32(uint256(1)), new bytes32[](0)
        );
        _designIds.push(tokenId);
        _designRegistrants[tokenId] = registrant;
    }
}
