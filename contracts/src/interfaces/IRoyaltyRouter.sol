// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRoyaltyRouter
/// @notice EIP-2981 royalty info plus payout to the per-design 0xSplits contract.
/// @dev Per plan §4: Uniswap v4 hook enforces a 3% protocol fee on swaps that include a
///      license payment. This interface defines the payout API plus the v4 hook surface
///      (signatures only — full hook impl lives in a separate contract). The split address
///      for a given tokenId is set once, at registration or forkRegister, and is then immutable.
interface IRoyaltyRouter {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when royalty is distributed for a tokenId.
    /// @param tokenId Design id royalties were collected on.
    /// @param currency ERC-20 (USDC) used; address(0) for native ETH.
    /// @param amount Gross amount distributed (pre-protocol-fee).
    /// @param splits Split contract that received the payout.
    event RoyaltyDistributed(uint256 indexed tokenId, address indexed currency, uint256 amount, address splits);

    /// @notice Emitted when the splits contract is set for a tokenId. One-time per tokenId.
    /// @param tokenId Design id.
    /// @param splits Address of the 0xSplits contract.
    event SplitsContractSet(uint256 indexed tokenId, address indexed splits);

    /// @notice Emitted when the protocol fee is taken on a license-bearing swap.
    /// @param tokenId Design id the license referenced.
    /// @param currency Currency the fee was taken in.
    /// @param amount Fee amount (in `currency` units).
    event ProtocolFeeCollected(uint256 indexed tokenId, address indexed currency, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when attempting to set the splits contract a second time for a tokenId.
    /// @param tokenId The tokenId whose splits is already set.
    error SplitsAlreadySet(uint256 tokenId);

    /// @notice Thrown when basis-point input is out of range (> SeqoraTypes.BPS).
    /// @param bps The supplied bps.
    error InvalidBps(uint16 bps);

    /// @notice Thrown when amount supplied to `distribute` is zero.
    error ZeroAmount();

    // -------------------------------------------------------------------------
    // EIP-2981
    // -------------------------------------------------------------------------

    /// @notice EIP-2981 royalty info.
    /// @dev Reads royalty rule from DesignRegistry. Returns address(0) and 0 if tokenId unknown.
    /// @param tokenId Design id.
    /// @param salePrice Sale price the royalty is being computed against.
    /// @return receiver Address royalties should be paid to (split contract).
    /// @return royaltyAmount Royalty amount in the same units as `salePrice`.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);

    // -------------------------------------------------------------------------
    // Splits binding (one-time)
    // -------------------------------------------------------------------------

    /// @notice Set the 0xSplits contract for a tokenId. Idempotent-locked: only one successful call.
    /// @dev Intended to be called by DesignRegistry inside `register` / `forkRegister`. Subsequent
    ///      calls revert with SplitsAlreadySet.
    /// @param tokenId Design id.
    /// @param splits 0xSplits contract address.
    function setSplitsContract(uint256 tokenId, address splits) external;

    /// @notice Read the splits contract bound to a tokenId.
    /// @param tokenId Design id.
    /// @return splits The split contract address (address(0) if unset).
    function getSplitsContract(uint256 tokenId) external view returns (address splits);

    // -------------------------------------------------------------------------
    // Payouts
    // -------------------------------------------------------------------------

    /// @notice Push `amount` of `currency` into the splits contract for `tokenId`.
    /// @dev Caller must have approved (ERC-20) or attached (native) the funds. Reverts on
    ///      ZeroAmount or unset splits.
    /// @param tokenId Design id royalties were collected on.
    /// @param currency ERC-20 address; address(0) for native ETH.
    /// @param amount Gross amount to forward.
    function distribute(uint256 tokenId, address currency, uint256 amount) external payable;

    // -------------------------------------------------------------------------
    // Uniswap v4 hook surface
    // -------------------------------------------------------------------------
    //
    // The actual hook entrypoints live on IHooks (v4-core), NOT this interface. Earlier
    // revisions of this interface declared v2-shaped `beforeSwap(address,bytes,bytes,bytes)` /
    // `afterSwap(address,bytes,bytes,bytes,bytes)` stubs for "ABI compatibility", but the v4
    // PoolManager never invokes those selectors — the canonical v4 selectors differ. The
    // router implementation inherits `IHooks` directly and exposes the real surface there.
}
