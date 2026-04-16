// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IScreeningAttestations } from "../../src/interfaces/IScreeningAttestations.sol";
import { IDesignRegistry } from "../../src/interfaces/IDesignRegistry.sol";
import { SeqoraTypes } from "../../src/libraries/SeqoraTypes.sol";

/// @notice Base stub — governance methods reduced to no-ops; each variant overrides `isValid`.
/// @dev The 3-arg `isValid(uid, canonicalHash, registrant)` is the post-H-01 shape.
abstract contract MockScreeningBase is IScreeningAttestations {
    function registerAttester(address, SeqoraTypes.ScreenerKind) external { }
    function revokeAttester(address, string calldata) external { }

    function getScreenerKind(address) external pure returns (SeqoraTypes.ScreenerKind) {
        return SeqoraTypes.ScreenerKind.Other;
    }

    function isApproved(address) external pure returns (bool) {
        return true;
    }

    function isValid(bytes32, bytes32, address) external view virtual returns (bool);
}

/// @notice Always returns true — baseline path for happy tests.
contract AlwaysValidScreening is MockScreeningBase {
    function isValid(bytes32, bytes32, address) external pure override returns (bool) {
        return true;
    }
}

/// @notice Always returns false — forces `AttestationInvalid` in DesignRegistry.
contract AlwaysInvalidScreening is MockScreeningBase {
    function isValid(bytes32, bytes32, address) external pure override returns (bool) {
        return false;
    }
}

/// @notice Always reverts — forces the external call to bubble up.
contract RevertingScreening is MockScreeningBase {
    error ScreeningBoom();

    function isValid(bytes32, bytes32, address) external pure override returns (bool) {
        revert ScreeningBoom();
    }
}

/// @notice Storage-backed toggle so tests can flip validity mid-run.
contract ToggleableScreening is MockScreeningBase {
    bool public valid;

    constructor(bool initial) {
        valid = initial;
    }

    function setValid(bool v) external {
        valid = v;
    }

    function isValid(bytes32, bytes32, address) external view override returns (bool) {
        return valid;
    }
}

/// @notice H-01 substitution-attack mock: returns true ONLY for a preconfigured tuple.
/// @dev Models an on-chain EAS attestation issued by an attester who signed specifically over
///      `(expectedUid, expectedCanonicalHash, expectedRegistrant)`. Any front-runner supplying
///      a different `registrant` for the same (uid, canonicalHash) must be rejected.
contract ScopedScreening is MockScreeningBase {
    bytes32 public immutable EXPECTED_UID;
    bytes32 public immutable EXPECTED_HASH;
    address public immutable EXPECTED_REGISTRANT;

    constructor(bytes32 uid_, bytes32 hash_, address registrant_) {
        EXPECTED_UID = uid_;
        EXPECTED_HASH = hash_;
        EXPECTED_REGISTRANT = registrant_;
    }

    function isValid(bytes32 uid, bytes32 canonicalHash, address registrant) external view override returns (bool) {
        return uid == EXPECTED_UID && canonicalHash == EXPECTED_HASH && registrant == EXPECTED_REGISTRANT;
    }
}

/// @notice Screener whose `isValid` is declared view-compatible but whose stored config can be
///         toggled to attempt an on-read reentry via a static-call-friendly path.
/// @dev DesignRegistry calls `isValid` via STATICCALL (interface declares `view`), which forbids
///      state-modifying sub-calls. A re-entry attempt would revert from the EVM before ever
///      reaching the reentrancy guard. The true reentrancy vector is the ERC-1155 receiver hook
///      — see `ReentrantReceiver` below.
contract ReentrantReceiver {
    IDesignRegistry public registry;
    bool public armed;

    error ReentryReverted();

    function setRegistry(IDesignRegistry r) external {
        registry = r;
    }

    function arm() external {
        armed = true;
    }

    /// @notice ERC-1155 receiver hook. When armed, tries to re-enter `register` on the registry.
    /// @dev MUST revert with ReentrancyGuardReentrantCall — that is the property under test.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        if (armed && address(registry) != address(0)) {
            armed = false;
            SeqoraTypes.RoyaltyRule memory royalty =
                SeqoraTypes.RoyaltyRule({ recipient: address(0xBEEF), bps: 0, parentSplitBps: 0 });
            registry.register(
                address(this),
                keccak256("reentrant-attempt"),
                bytes32(0),
                "ar://x",
                "ceramic://x",
                royalty,
                bytes32(uint256(42)),
                new bytes32[](0)
            );
            // If the call somehow succeeds, surface it.
            revert ReentryReverted();
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return ReentrantReceiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}
