// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SeqoraTypes } from "../libraries/SeqoraTypes.sol";

/// @title ILicenseRegistry
/// @notice Per-design license templates and granted License Tokens (ERC-721).
/// @dev UUPS-upgradable per plan §4. Templates are SPDX-style (OpenMTA, OpenMTA-NC,
///      Custom-Commercial, etc.) registered by governance. Granting a license mints an
///      ERC-721 License Token to the licensee; revocation flips the `revoked` flag and
///      is gated by governance / Safety Council.
interface ILicenseRegistry {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a new license template is registered.
    /// @param licenseId Template identifier (e.g. keccak256("OpenMTA")).
    /// @param name Human-readable name.
    /// @param uri Off-chain pointer to the legal text.
    event LicenseTemplateRegistered(bytes32 indexed licenseId, string name, string uri);

    /// @notice Emitted when a license template's `active` flag is toggled.
    /// @param licenseId Template identifier.
    /// @param active New active flag.
    event LicenseTemplateStatusChanged(bytes32 indexed licenseId, bool active);

    /// @notice Emitted when a license is granted.
    /// @param licenseTokenId ERC-721 token id minted to the licensee.
    /// @param tokenId Design tokenId being licensed.
    /// @param licenseId Template used.
    /// @param licensee Address granted the license.
    /// @param expiry Unix seconds; 0 = perpetual.
    /// @param feePaid Fee amount recorded.
    event LicenseGranted(
        uint256 indexed licenseTokenId,
        uint256 indexed tokenId,
        bytes32 indexed licenseId,
        address licensee,
        uint64 expiry,
        uint128 feePaid
    );

    /// @notice Emitted when a license is revoked.
    /// @param licenseTokenId License Token id.
    /// @param revoker Governance / Safety Council address that triggered revocation.
    /// @param reason Free-form short reason.
    event LicenseRevoked(uint256 indexed licenseTokenId, address indexed revoker, string reason);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when the referenced license has expired.
    /// @param licenseTokenId The expired license.
    error LicenseExpired(uint256 licenseTokenId);

    /// @notice Thrown when the referenced license has been revoked.
    /// @param licenseTokenId The revoked license.
    error LicenseRevokedError(uint256 licenseTokenId);

    /// @notice Thrown when an unknown or inactive licenseId is supplied.
    /// @param licenseId The unknown template id.
    error UnknownLicenseTemplate(bytes32 licenseId);

    /// @notice Thrown when caller is not the licensee of the referenced License Token.
    /// @param caller msg.sender at the failing call.
    /// @param licenseTokenId The license being acted on.
    error NotLicensee(address caller, uint256 licenseTokenId);

    /// @notice Thrown when a license template id has already been registered.
    /// @param licenseId The duplicate template id.
    error LicenseTemplateAlreadyExists(bytes32 licenseId);

    // -------------------------------------------------------------------------
    // Templates (governance-gated)
    // -------------------------------------------------------------------------

    /// @notice Register a new license template. Governance-only.
    /// @param template Full template struct (licenseId is the key).
    function registerLicenseTemplate(SeqoraTypes.LicenseTemplate calldata template) external;

    /// @notice Toggle whether a license template can be used for new grants. Governance-only.
    /// @param licenseId Template id.
    /// @param active New status.
    function setLicenseTemplateActive(bytes32 licenseId, bool active) external;

    /// @notice Read a registered license template.
    /// @param licenseId Template id.
    /// @return template The stored template.
    function getLicenseTemplate(bytes32 licenseId) external view returns (SeqoraTypes.LicenseTemplate memory template);

    // -------------------------------------------------------------------------
    // Grants
    // -------------------------------------------------------------------------

    /// @notice Grant a license against a registered design. Mints an ERC-721 License Token.
    /// @dev Reverts with UnknownLicenseTemplate if the licenseId is not registered or inactive.
    ///      Fee accounting is handled by RoyaltyRouter; this function only records the grant.
    /// @param tokenId Design tokenId being licensed.
    /// @param licenseId Template id used.
    /// @param licensee Address receiving the License Token.
    /// @param expiry Unix seconds (0 = perpetual).
    /// @param feePaid Fee recorded against this grant.
    /// @return licenseTokenId Newly minted ERC-721 id.
    function grantLicense(uint256 tokenId, bytes32 licenseId, address licensee, uint64 expiry, uint128 feePaid)
        external
        returns (uint256 licenseTokenId);

    /// @notice Revoke an existing License Token. Governance / Safety-Council gated.
    /// @param licenseTokenId The license to revoke.
    /// @param reason Free-form short reason recorded in the event.
    function revokeLicense(uint256 licenseTokenId, string calldata reason) external;

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Whether `user` currently holds a non-revoked, non-expired license for `tokenId`.
    /// @param tokenId Design id.
    /// @param user Candidate licensee.
    /// @return valid True iff a usable license exists for this pair.
    function checkLicenseValid(uint256 tokenId, address user) external view returns (bool valid);

    /// @notice Read a License Token record.
    /// @param licenseTokenId The ERC-721 id.
    /// @return license Stored license struct.
    function getLicense(uint256 licenseTokenId) external view returns (SeqoraTypes.License memory license);
}
