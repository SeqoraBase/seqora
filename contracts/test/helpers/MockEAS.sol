// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEAS } from "eas-contracts/IEAS.sol";
import { Attestation } from "eas-contracts/Common.sol";
import { ISchemaRegistry } from "eas-contracts/ISchemaRegistry.sol";
import {
    AttestationRequest,
    RevocationRequest,
    MultiAttestationRequest,
    MultiRevocationRequest
} from "eas-contracts/IEAS.sol";
import {
    DelegatedAttestationRequest,
    DelegatedRevocationRequest,
    MultiDelegatedAttestationRequest,
    MultiDelegatedRevocationRequest
} from "eas-contracts/IEAS.sol";

/// @notice Minimal mock of Ethereum Attestation Service v1.9.0 used by ScreeningAttestations tests.
/// @dev Implements only `getAttestation(bytes32)` — every other IEAS method reverts so tests do not
///      accidentally exercise unimplemented surface. Tests build `Attestation` structs via
///      `setAttestation(uid, attestation)` before calling into ScreeningAttestations.
contract MockEAS is IEAS {
    mapping(bytes32 => Attestation) private _attestations;

    string public constant VERSION_STRING = "mock-eas-1.9.0";

    // -------------------------------------------------------------------------
    // Test control surface
    // -------------------------------------------------------------------------

    /// @notice Store a full attestation under `uid`.
    function setAttestation(bytes32 uid, Attestation memory att) external {
        _attestations[uid] = att;
    }

    // -------------------------------------------------------------------------
    // ISemver
    // -------------------------------------------------------------------------

    function version() external pure returns (string memory) {
        return VERSION_STRING;
    }

    // -------------------------------------------------------------------------
    // IEAS — implemented
    // -------------------------------------------------------------------------

    function getAttestation(bytes32 uid) external view returns (Attestation memory) {
        return _attestations[uid];
    }

    function isAttestationValid(bytes32 uid) external view returns (bool) {
        return _attestations[uid].schema != bytes32(0);
    }

    // -------------------------------------------------------------------------
    // IEAS — unused (revert to fail loudly if a test accidentally depends on them)
    // -------------------------------------------------------------------------

    function getSchemaRegistry() external pure returns (ISchemaRegistry) {
        revert("MockEAS: getSchemaRegistry not implemented");
    }

    function attest(AttestationRequest calldata) external payable returns (bytes32) {
        revert("MockEAS: attest not implemented");
    }

    function attestByDelegation(DelegatedAttestationRequest calldata) external payable returns (bytes32) {
        revert("MockEAS: attestByDelegation not implemented");
    }

    function multiAttest(MultiAttestationRequest[] calldata) external payable returns (bytes32[] memory) {
        revert("MockEAS: multiAttest not implemented");
    }

    function multiAttestByDelegation(MultiDelegatedAttestationRequest[] calldata)
        external
        payable
        returns (bytes32[] memory)
    {
        revert("MockEAS: multiAttestByDelegation not implemented");
    }

    function revoke(RevocationRequest calldata) external payable {
        revert("MockEAS: revoke not implemented");
    }

    function revokeByDelegation(DelegatedRevocationRequest calldata) external payable {
        revert("MockEAS: revokeByDelegation not implemented");
    }

    function multiRevoke(MultiRevocationRequest[] calldata) external payable {
        revert("MockEAS: multiRevoke not implemented");
    }

    function multiRevokeByDelegation(MultiDelegatedRevocationRequest[] calldata) external payable {
        revert("MockEAS: multiRevokeByDelegation not implemented");
    }

    function timestamp(bytes32) external pure returns (uint64) {
        revert("MockEAS: timestamp not implemented");
    }

    function multiTimestamp(bytes32[] calldata) external pure returns (uint64) {
        revert("MockEAS: multiTimestamp not implemented");
    }

    function revokeOffchain(bytes32) external pure returns (uint64) {
        revert("MockEAS: revokeOffchain not implemented");
    }

    function multiRevokeOffchain(bytes32[] calldata) external pure returns (uint64) {
        revert("MockEAS: multiRevokeOffchain not implemented");
    }

    function getTimestamp(bytes32) external pure returns (uint64) {
        revert("MockEAS: getTimestamp not implemented");
    }

    function getRevokeOffchain(address, bytes32) external pure returns (uint64) {
        revert("MockEAS: getRevokeOffchain not implemented");
    }
}
