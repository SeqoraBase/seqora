// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SeqoraErrors
/// @notice Cross-contract custom errors hoisted to a single import surface.
/// @dev Contract-specific errors live next to their interface; only truly shared errors live here.
library SeqoraErrors {
    // -------------------------------------------------------------------------
    // Address / auth
    // -------------------------------------------------------------------------

    /// @notice Thrown when a zero address is supplied where a non-zero address is required.
    error ZeroAddress();

    /// @notice Thrown when caller is not authorized for the requested action.
    /// @param caller The address that attempted the call.
    error NotAuthorized(address caller);

    /// @notice Thrown when an action is attempted while the contract is paused.
    error Paused();

    // -------------------------------------------------------------------------
    // Generic input validation
    // -------------------------------------------------------------------------

    /// @notice Thrown when an unexpected zero value is supplied.
    error ZeroValue();

    /// @notice Thrown when a referenced tokenId has not been registered.
    /// @param tokenId The tokenId that was looked up.
    error UnknownToken(uint256 tokenId);

    /// @notice Thrown when basis-point input exceeds the protocol-wide cap.
    /// @param bps The value supplied.
    error BpsOutOfRange(uint16 bps);

    /// @notice Thrown when a caller-supplied `expiry` timestamp is not strictly in the future.
    /// @param expiry The expiry timestamp supplied by the caller (seconds since epoch).
    error ExpiryNotInFuture(uint64 expiry);
}
