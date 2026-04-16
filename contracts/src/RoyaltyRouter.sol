// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------------------
// RoyaltyRouter — Seqora v1
//
// Plan (§3, §4, §5, §6): payments hub. Three modes of operation:
//   1. EIP-2981 off-chain lookup   — marketplaces call `royaltyInfo(tokenId, salePrice)`.
//   2. Direct `distribute`         — non-swap flows (e.g. open-grant licensing fees) push
//                                    funds through the router; 3% protocol fee → treasury,
//                                    balance → per-tokenId 0xSplits.
//   3. Uniswap v4 hook             — when a license-bearing token is swapped through a pool
//                                    that installs THIS contract as its hook, beforeSwap/
//                                    afterSwap intercept the swap and route the royalty +
//                                    protocol fee to 0xSplits + treasury.
//
// Interface divergence (logged to orchestrator)
// --------------------------------------------
//   IRoyaltyRouter declares `beforeSwap(address,bytes,bytes,bytes) returns (bytes4)` and
//   `afterSwap(address,bytes,bytes,bytes,bytes) returns (bytes4)`. Those signatures CANNOT
//   be invoked by the v4 PoolManager — PoolManager uses the canonical Uniswap v4
//   `IHooks.beforeSwap(address,PoolKey,SwapParams,bytes) returns (bytes4,BeforeSwapDelta,
//   uint24)` and `IHooks.afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes) returns
//   (bytes4,int128)`. Their function selectors differ, so both selectors can coexist on
//   the same contract. The IRoyaltyRouter-shaped entrypoints are retained for ABI
//   compatibility with the interface and are permanently disabled (revert `HookMisconfigured`
//   to make any accidental call unambiguous). The REAL v4 hook path is the IHooks
//   implementation. Orchestrator should reconcile the interface vs. the v4 reality in a
//   follow-up interface-tidy pass (see agent-log).
//
// Hook permission encoding (v4)
// -----------------------------
//   v4 inspects the trailing 14 bits of a hook's ADDRESS to know which hooks to call. We
//   declare `beforeSwap = true`, `afterSwap = true`, and `beforeSwapReturnDelta = true`
//   (because we decrement the user's input amount by our take). Deployment to the correct
//   address is the deployer's problem — `validateHookAddress(this)` in the constructor will
//   revert on mismatch, failing deploys loudly until the right CREATE2 salt is used.
//
// Take-side choice
// ----------------
//   We take in `beforeSwap` by returning a positive `specifiedDelta` (the hook is owed the
//   fee). The PoolManager then carries that credit to `afterSwap` / the unlock callback,
//   where the sender settles against us. In `afterSwap` we actually `take(currency, this,
//   fee)` and `transfer` to treasury + splits. This is the "specified side" pattern used
//   by CustomCurveHook / LPFeeTakingHook — it works cleanly for both exactInput and
//   exactOutput without a second swap leg. v1 collects ONLY in the unspecified currency
//   (the side the swapper is spending) to keep the math simple and avoid a second transfer.
//
// Fee-on-top vs inclusive
// -----------------------
//   `distribute` treats `amount` as GROSS — protocol fee is inclusive (3% is taken OUT OF
//   `amount`). `royaltyInfo` returns the registrant's royalty EXCLUDING the protocol fee
//   (protocol fee is "on top" of the EIP-2981 royalty on trading venues). The v4 hook
//   mirrors the `distribute` path: the (royalty-bps + 3%) total is removed from the
//   swap's unspecified amount.
// -----------------------------------------------------------------------------

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/types/BeforeSwapDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/types/PoolOperation.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";

import { IRoyaltyRouter } from "./interfaces/IRoyaltyRouter.sol";
import { IDesignRegistry } from "./interfaces/IDesignRegistry.sol";
import { SeqoraTypes } from "./libraries/SeqoraTypes.sol";
import { SeqoraErrors } from "./libraries/SeqoraErrors.sol";

/// @title RoyaltyRouter
/// @notice EIP-2981 + 0xSplits routing + Uniswap v4 hook enforcing Seqora's 3% protocol fee.
/// @dev Immutable — no UUPS. Governance is scoped to (a) token allowlist, (b) emergency hook
///      pause, (c) fallback `setSplits` auth. Core math and addresses are fixed at deploy.
contract RoyaltyRouter is IRoyaltyRouter, IHooks, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // -------------------------------------------------------------------------
    // Local errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when `distribute` or the v4 hook is called with a currency that is
    ///         not on the governance-controlled allowlist.
    /// @param token ERC-20 token address that was rejected.
    error UnsupportedToken(address token);

    /// @notice Thrown when a hook-path operation needs a splits contract but none has been set
    ///         and no RoyaltyRule fallback recipient exists.
    /// @param tokenId Design id that is missing a payout target.
    error SplitsNotSet(uint256 tokenId);

    /// @notice Thrown when this contract is deployed to an address whose trailing bits do not
    ///         encode the required v4 hook permissions, or when a placeholder IRoyaltyRouter
    ///         hook entrypoint is invoked (those are retained for ABI compat but unused).
    error HookMisconfigured();

    /// @notice Thrown on any attempt to call `renounceOwnership`. Mirrors L-04 / LicenseRegistry.
    error RenounceDisabled();

    /// @notice Thrown when a v4 hook method is invoked by any address other than the PoolManager.
    /// @param caller The unauthorised caller.
    error NotPoolManager(address caller);

    // -------------------------------------------------------------------------
    // Impl-only events
    // -------------------------------------------------------------------------

    /// @notice Emitted when governance toggles a currency in or out of the allowlist.
    /// @param token ERC-20 address (native ETH not supported in the allowlist).
    /// @param allowed New allow state.
    event SupportedTokenSet(address indexed token, bool allowed);

    /// @notice Emitted when `distribute` routes funds through the router.
    /// @param tokenId Design id the payment is attributed to.
    /// @param token ERC-20 currency.
    /// @param amount Gross amount pulled from caller.
    /// @param protocolFee 3% fee sent to TREASURY.
    /// @param royaltyAmount Net amount sent to the splits contract (or RoyaltyRule fallback).
    event Distributed(
        uint256 indexed tokenId, address indexed token, uint256 amount, uint256 protocolFee, uint256 royaltyAmount
    );

    /// @notice Emitted on a v4 swap when the hook collects the royalty + protocol fee.
    /// @param tokenId Design id decoded from `hookData`.
    /// @param token ERC-20 currency the take was denominated in.
    /// @param royaltyAmount Amount routed to the splits contract / fallback recipient.
    /// @param protocolFee 3% fee sent to TREASURY.
    event HookCollected(uint256 indexed tokenId, address indexed token, uint256 royaltyAmount, uint256 protocolFee);

    /// @notice Emitted when governance toggles the emergency hook-collection pause.
    /// @param paused True when the hook will skip the fee take but continue to allow swaps.
    event HookCollectionPaused(bool paused);

    // -------------------------------------------------------------------------
    // Immutable state
    // -------------------------------------------------------------------------

    /// @notice Canonical DesignRegistry. The ONLY authorised automatic caller of `setSplitsContract`.
    IDesignRegistry public immutable DESIGN_REGISTRY;

    /// @notice Seqora protocol treasury — receives the 3% PROTOCOL_FEE_BPS on every distribution.
    /// @dev Immutable for v1. A treasury rotation requires redeploy.
    address public immutable TREASURY;

    /// @notice Uniswap v4 PoolManager (Base mainnet: 0x498581ff718922c3f8e6a244956af099b2652b2b).
    /// @dev Passed via constructor to stay testable; NOT hardcoded.
    IPoolManager public immutable POOL_MANAGER;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @dev tokenId -> 0xSplits contract. One-time write (`setSplitsContract`). Zero = unset.
    mapping(uint256 => address) private _splitsOf;

    /// @notice ERC-20 allowlist for `distribute` and the v4 hook path.
    /// @dev Governance-managed. USDC will be the day-one entry (Base: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).
    mapping(address => bool) public supportedToken;

    /// @notice Emergency circuit breaker for the hook-collection path.
    /// @dev When true, `beforeSwap` returns ZERO_DELTA and `afterSwap` skips the transfer so the
    ///      user's swap proceeds without being taxed. Chosen over reverting because a reverting
    ///      hook would brick every v4 pool that installed us; graceful degradation is the safer
    ///      failure mode.
    bool public hookCollectionPaused;

    // -------------------------------------------------------------------------
    // Transient hook context
    // -------------------------------------------------------------------------

    /// @dev Memo of the unspecified-side amount the hook needs to `take` in `afterSwap`, scoped
    ///      per swap by a single-slot `_pendingTake` struct keyed on (tokenId, currency). Written
    ///      in `beforeSwap`, consumed in `afterSwap`. The PoolManager's unlock lifecycle
    ///      guarantees no interleaved v4 swap can overwrite this within a single transaction
    ///      because all hook callbacks fire inside one unlock frame. Cleared on consumption.
    ///
    ///      NOTE: for v1 we support at most ONE license-bearing swap per top-level v4 operation
    ///      (a reasonable constraint; nested v4 swaps of license tokens are extremely unusual).
    ///      If a composite callback tries to pile up a second pending take, `_pendingTake.amount
    ///      != 0` would collide — we overwrite and emit only the final `HookCollected`. This is
    ///      documented as a TODO for sec-auditor; the conservative fix is per-call transient
    ///      storage (EIP-1153), which lands when we bump to cancun-only builds.
    struct PendingTake {
        uint256 tokenId;
        address token;
        uint256 royaltyAmount;
        uint256 protocolFee;
    }

    PendingTake private _pendingTake;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Only callable inside a v4 PoolManager-initiated hook callback.
    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploy the router. MUST be invoked via CREATE2 with a salt whose resulting
    ///         address encodes the v4 hook permission flags in its trailing bits.
    /// @param designRegistry_ Canonical DesignRegistry this router reads royalty rules from.
    /// @param treasury_ Seqora treasury address (3% protocol fee receiver).
    /// @param poolManager_ Uniswap v4 PoolManager for this chain (Base mainnet address in plan §4).
    /// @param governance_ Initial owner (Safety Council / governance multisig).
    constructor(IDesignRegistry designRegistry_, address treasury_, IPoolManager poolManager_, address governance_)
        Ownable(governance_)
    {
        if (address(designRegistry_) == address(0)) revert SeqoraErrors.ZeroAddress();
        if (treasury_ == address(0)) revert SeqoraErrors.ZeroAddress();
        if (address(poolManager_) == address(0)) revert SeqoraErrors.ZeroAddress();
        // `governance_ == 0` is handled by OZ `Ownable`'s constructor via `OwnableInvalidOwner`.

        DESIGN_REGISTRY = designRegistry_;
        TREASURY = treasury_;
        POOL_MANAGER = poolManager_;

        // Validate that THIS contract's address encodes the hook flags we need. Deploys to a
        // wrong address fail loudly here. CREATE2 salt mining lives in deployment scripts.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // -------------------------------------------------------------------------
    // EIP-2981
    // -------------------------------------------------------------------------

    /// @inheritdoc IRoyaltyRouter
    /// @dev Returns the REGISTRANT's royalty only, excluding the 3% protocol fee. The protocol
    ///      fee is taken on the v4 swap leg (or inside `distribute`) on top of this value.
    ///      Returns `(address(0), 0)` for unknown or unregistered tokenIds — EIP-2981 explicitly
    ///      allows zero royalty, and a revert here would break every marketplace aggregator that
    ///      sweeps royaltyInfo across an unknown catalogue.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        if (!DESIGN_REGISTRY.isRegistered(tokenId)) return (address(0), 0);
        SeqoraTypes.Design memory d = DESIGN_REGISTRY.getDesign(tokenId);

        // Splits contract is the preferred recipient; RoyaltyRule.recipient is the fallback. If
        // both are zero and royalty > 0, we return (0, 0) — marketplaces MUST treat that as
        // "no royalty enforced at this endpoint" and NOT send funds to address(0).
        address splits = _splitsOf[tokenId];
        receiver = splits != address(0) ? splits : d.royalty.recipient;

        // bps is bounded at mint time (`DesignRegistry` enforces <= MAX_ROYALTY_BPS = 2500).
        // Solidity 0.8 checked math covers the multiply overflow edge (salePrice <= 2^256 / 2500).
        royaltyAmount = (salePrice * d.royalty.bps) / SeqoraTypes.BPS;
    }

    // -------------------------------------------------------------------------
    // Splits binding
    // -------------------------------------------------------------------------

    /// @inheritdoc IRoyaltyRouter
    /// @dev Auth: `msg.sender` MUST be either (a) the DesignRegistry (wiring at registration /
    ///      forkRegister time) OR (b) the tokenId's registrant OR (c) the router owner
    ///      (governance fallback when registry wiring is misconfigured). One-time-settable —
    ///      subsequent calls revert `SplitsAlreadySet`.
    function setSplitsContract(uint256 tokenId, address splits) external {
        if (splits == address(0)) revert SeqoraErrors.ZeroAddress();
        if (_splitsOf[tokenId] != address(0)) revert SplitsAlreadySet(tokenId);

        // Existence gate: unregistered tokenIds cannot bind splits — the registry lookup also
        // fails cheaply for zero tokenIds (registeredAt == 0).
        if (!DESIGN_REGISTRY.isRegistered(tokenId)) revert SeqoraErrors.UnknownToken(tokenId);

        if (msg.sender != address(DESIGN_REGISTRY) && msg.sender != owner()) {
            address registrant = DESIGN_REGISTRY.getDesign(tokenId).registrant;
            if (msg.sender != registrant) revert SeqoraErrors.NotAuthorized(msg.sender);
        }

        _splitsOf[tokenId] = splits;
        emit SplitsContractSet(tokenId, splits);
    }

    /// @inheritdoc IRoyaltyRouter
    function getSplitsContract(uint256 tokenId) external view returns (address splits) {
        splits = _splitsOf[tokenId];
    }

    // -------------------------------------------------------------------------
    // Direct distribute (non-swap flows)
    // -------------------------------------------------------------------------

    /// @inheritdoc IRoyaltyRouter
    /// @dev v1 supports ONLY ERC-20 `currency`; native ETH is declined with `UnsupportedToken`
    ///      because the native-ETH branch of the allowlist+transfer plumbing is not yet audited
    ///      (sec-auditor TODO). Callers paying ETH should wrap to WETH and route through here,
    ///      or use v2's forthcoming native-ETH path.
    ///
    ///      Non-reentrant. Not pausable — pausing the router's off-swap payment rails would
    ///      break open-grant license checkouts mid-flow.
    ///
    ///      Routing: (a) 3% of `amount` → TREASURY, (b) remainder → `_splitsOf[tokenId]` or
    ///      `RoyaltyRule.recipient` fallback. Reverts `SplitsNotSet` if both are zero (no
    ///      valid payout target).
    function distribute(uint256 tokenId, address currency, uint256 amount) external payable nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (currency == address(0)) revert UnsupportedToken(currency);
        if (!supportedToken[currency]) revert UnsupportedToken(currency);

        // Native ETH not supported in v1 — reject msg.value to avoid stuck ETH.
        if (msg.value != 0) revert UnsupportedToken(address(0));

        if (!DESIGN_REGISTRY.isRegistered(tokenId)) revert SeqoraErrors.UnknownToken(tokenId);

        address payoutTarget = _resolvePayoutTarget(tokenId);
        if (payoutTarget == address(0)) revert SplitsNotSet(tokenId);

        (uint256 protocolFee, uint256 royaltyAmount) = _splitAmount(amount);

        // --- Interactions ---
        // Pull gross from caller, then split-and-forward. SafeERC20 surfaces broken tokens.
        IERC20 token = IERC20(currency);
        token.safeTransferFrom(msg.sender, address(this), amount);

        if (protocolFee > 0) token.safeTransfer(TREASURY, protocolFee);
        if (royaltyAmount > 0) token.safeTransfer(payoutTarget, royaltyAmount);

        emit Distributed(tokenId, currency, amount, protocolFee, royaltyAmount);
        // IRoyaltyRouter-compat event so legacy indexers still see the payout.
        emit RoyaltyDistributed(tokenId, currency, amount, payoutTarget);
        emit ProtocolFeeCollected(tokenId, currency, protocolFee);
    }

    // -------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------

    /// @notice Add or remove a currency from the allowlist.
    /// @dev Owner-only. Allowed tokens MUST be ERC-20-compliant — no rebasing, no fee-on-
    ///      transfer (SafeERC20 can survive the latter but the distribute math assumes amounts
    ///      land exactly). Reject those at governance-review time rather than on-chain.
    /// @param token ERC-20 address to toggle.
    /// @param allowed New state (true = allowed).
    function setSupportedToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert SeqoraErrors.ZeroAddress();
        supportedToken[token] = allowed;
        emit SupportedTokenSet(token, allowed);
    }

    /// @notice Toggle the emergency hook-collection pause.
    /// @dev When paused, the v4 hook path skips the fee take but STILL allows swaps through
    ///      (graceful degradation — reverting in a hook would brick every pool that installed
    ///      this router). Distribute is intentionally NOT paused by this lever.
    /// @param paused New state.
    function setHookCollectionPaused(bool paused) external onlyOwner {
        hookCollectionPaused = paused;
        emit HookCollectionPaused(paused);
    }

    /// @notice Disables `renounceOwnership`. See L-04.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // -------------------------------------------------------------------------
    // IRoyaltyRouter legacy hook stubs (NOT used by v4 PoolManager — see contract header)
    // -------------------------------------------------------------------------

    /// @inheritdoc IRoyaltyRouter
    /// @dev Retained for ABI compatibility with the interface. The v4 PoolManager calls the
    ///      `IHooks.beforeSwap` overload below (different selector). If an integrator wires
    ///      this selector by mistake we revert loudly so the misconfiguration surfaces in tests.
    function beforeSwap(address, bytes calldata, bytes calldata, bytes calldata) external pure returns (bytes4) {
        revert HookMisconfigured();
    }

    /// @inheritdoc IRoyaltyRouter
    /// @dev See `beforeSwap` stub above — kept for ABI compat only.
    function afterSwap(address, bytes calldata, bytes calldata, bytes calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookMisconfigured();
    }

    // -------------------------------------------------------------------------
    // Uniswap v4 IHooks implementation (the REAL hook surface)
    // -------------------------------------------------------------------------

    /// @notice Declare which IHooks callbacks this contract exposes.
    /// @dev The contract's deployed address MUST encode these same bits in its trailing 14 bits
    ///      (`Hooks.validateHookPermissions`). All other flags are false.
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
        // beforeSwapReturnDelta = true so the PoolManager picks up our fee take in `beforeSwap`
        // via the `specifiedDelta` return channel.
        p.beforeSwapReturnDelta = true;
    }

    /// @notice v4 `beforeSwap` hook. Computes royalty + protocol fee and records them for
    ///         consumption in `afterSwap`.
    /// @dev Called by the PoolManager only. `hookData` is expected to `abi.encode(uint256
    ///      tokenId)` — a swap that wants the royalty-enforcement semantics MUST attach the
    ///      license tokenId. Empty or malformed hookData short-circuits: the hook returns a
    ///      zero delta and does NOT block the swap. This is a design choice (permissive for
    ///      non-license pools, strict via `supportedToken` for license pools).
    ///
    ///      Math:
    ///        amountSpecified < 0  → exactInput  → fee comes out of the INPUT amount (the
    ///                                             currency being spent; "unspecified side"
    ///                                             is the currency being received).
    ///        amountSpecified >= 0 → exactOutput → fee comes out of the OUTPUT amount (still
    ///                                             the currency the pool owes; "unspecified
    ///                                             side" is what the swapper receives).
    ///      In both cases we bill the unspecified side — the hook owes or is owed the fee
    ///      against the same currency the swap's counter-leg is in. Simpler than a two-side
    ///      take and sufficient for v1.
    function beforeSwap(
        address,
        /* sender */
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) {
        selector = IHooks.beforeSwap.selector;
        lpFeeOverride = 0;

        // Pause, empty hookData, or non-license swap — proceed without a take.
        if (hookCollectionPaused || hookData.length != 32) return (selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 tokenId = abi.decode(hookData, (uint256));
        if (tokenId == 0 || !DESIGN_REGISTRY.isRegistered(tokenId)) {
            return (selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Nominal swap amount (input for exactIn, output for exactOut). Treat as absolute.
        int256 amountSpecified = params.amountSpecified;
        uint256 absAmount = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        if (absAmount == 0) return (selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Determine which side we bill. The "unspecified" currency (per v4 semantics) is the
        // OTHER side of the swap relative to `amountSpecified`. For a zeroForOne exactInput,
        // specified = currency0 (input), unspecified = currency1 (output).
        Currency billedCurrency = _unspecifiedCurrency(key, params);
        address billedToken = Currency.unwrap(billedCurrency);

        // Only proceed if the billed currency is on the allowlist. Native ETH (address(0)) is
        // excluded from the allowlist by `setSupportedToken`'s zero-address guard, so we
        // naturally skip ETH-denominated pools here (v1 scope).
        if (billedToken == address(0) || !supportedToken[billedToken]) {
            return (selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Pull royaltyRule off the registry to size the take.
        SeqoraTypes.RoyaltyRule memory rule = DESIGN_REGISTRY.getDesign(tokenId).royalty;
        uint256 royaltyBps = rule.bps;
        uint256 royaltyAmount = (absAmount * royaltyBps) / SeqoraTypes.BPS;
        uint256 protocolFee = (absAmount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        uint256 total = royaltyAmount + protocolFee;
        if (total == 0) return (selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Stage the take for afterSwap to settle. Overwriting here (vs. append) is fine for v1:
        // v4 hook callbacks fire synchronously inside the PoolManager unlock, so a second
        // beforeSwap cannot interleave before the matching afterSwap drains the memo.
        _pendingTake = PendingTake({
            tokenId: tokenId, token: billedToken, royaltyAmount: royaltyAmount, protocolFee: protocolFee
        });

        // Positive unspecified delta ⇒ the hook is OWED `total` in the billed currency; the
        // swapper's unspecified-side balance will be debited by this much before `afterSwap`
        // settles. `specifiedDelta` stays zero so the swap's specified amount is unchanged.
        delta = toBeforeSwapDelta(0, int128(int256(total)));
    }

    /// @notice v4 `afterSwap` hook. Settles the pending take by calling `PoolManager.take`
    ///         and forwarding to treasury + splits.
    /// @dev The `total` we earned in `beforeSwap` is now claimable via `POOL_MANAGER.take()`.
    ///      We transfer to the registrant (via splits or fallback) and to the treasury in the
    ///      same call. Reverts inside this hook would roll back the entire swap, so every
    ///      external transfer must be resilient — SafeERC20 handles missing return data.
    function afterSwap(
        address, /* sender */
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta, /* delta */
        bytes calldata /* hookData */
    )
        external
        onlyPoolManager
        returns (bytes4 selector, int128 hookUnspecifiedDelta)
    {
        selector = IHooks.afterSwap.selector;

        PendingTake memory p = _pendingTake;
        if (p.royaltyAmount == 0 && p.protocolFee == 0) {
            // Nothing to settle (paused / non-license / unsupported-token path in beforeSwap).
            return (selector, 0);
        }

        // Consume the memo exactly once — clear before external calls for belt-and-suspenders.
        delete _pendingTake;

        uint256 total = p.royaltyAmount + p.protocolFee;
        Currency c = Currency.wrap(p.token);

        // Take the owed amount from the PoolManager into this contract, then fan out.
        POOL_MANAGER.take(c, address(this), total);

        IERC20 token = IERC20(p.token);
        if (p.protocolFee > 0) token.safeTransfer(TREASURY, p.protocolFee);
        if (p.royaltyAmount > 0) {
            address payoutTarget = _resolvePayoutTarget(p.tokenId);
            if (payoutTarget == address(0)) {
                // No payout target → send the royalty to the treasury as a last-resort sink
                // rather than reverting inside the hook (reverting would fail the swap).
                // sec-auditor TODO: confirm "forfeit to treasury" is the desired default or
                // whether we'd rather lock-and-pause here.
                token.safeTransfer(TREASURY, p.royaltyAmount);
            } else {
                token.safeTransfer(payoutTarget, p.royaltyAmount);
            }
        }

        emit HookCollected(p.tokenId, p.token, p.royaltyAmount, p.protocolFee);
        emit ProtocolFeeCollected(p.tokenId, p.token, p.protocolFee);

        // We've already claimed `total` in `beforeSwap` via the unspecified BeforeSwapDelta;
        // afterSwap returns 0 so no additional accounting is applied.
        hookUnspecifiedDelta = 0;
    }

    // -------------------------------------------------------------------------
    // Unused IHooks — revert to signal misconfiguration (permissions flag should block these)
    // -------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookMisconfigured();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookMisconfigured();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookMisconfigured();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookMisconfigured();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookMisconfigured();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookMisconfigured();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookMisconfigured();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookMisconfigured();
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Compute (protocolFee, royaltyAmount) for a gross `amount`. 3% of gross →
    ///      protocolFee; remainder → royaltyAmount. Inclusive semantics; see header.
    function _splitAmount(uint256 amount) internal pure returns (uint256 protocolFee, uint256 royaltyAmount) {
        protocolFee = (amount * SeqoraTypes.PROTOCOL_FEE_BPS) / SeqoraTypes.BPS;
        // protocolFee <= amount (PROTOCOL_FEE_BPS <= BPS), so the sub cannot underflow.
        royaltyAmount = amount - protocolFee;
    }

    /// @dev Resolve the best payout target for a tokenId. Order of preference:
    ///      (1) explicit splits contract set via `setSplitsContract`,
    ///      (2) RoyaltyRule.recipient fallback (set at registration),
    ///      (3) address(0) — caller must handle as "no target".
    function _resolvePayoutTarget(uint256 tokenId) internal view returns (address) {
        address splits = _splitsOf[tokenId];
        if (splits != address(0)) return splits;
        SeqoraTypes.RoyaltyRule memory rule = DESIGN_REGISTRY.getDesign(tokenId).royalty;
        return rule.recipient;
    }

    /// @dev Compute which side of the pool the swap's "unspecified" amount is denominated in.
    ///      v4: `amountSpecified < 0` ⇒ exactInput (specified is the amount going IN).
    ///           `amountSpecified > 0` ⇒ exactOutput (specified is the amount coming OUT).
    ///
    ///         zeroForOne=true, exactIn  → specified=cur0, unspecified=cur1
    ///         zeroForOne=true, exactOut → specified=cur1, unspecified=cur0
    ///         zeroForOne=false, exactIn → specified=cur1, unspecified=cur0
    ///         zeroForOne=false, exactOut→ specified=cur0, unspecified=cur1
    function _unspecifiedCurrency(PoolKey calldata key, SwapParams calldata params) internal pure returns (Currency) {
        bool exactInput = params.amountSpecified < 0;
        // exactIn: specified is the token being spent (zeroForOne=true → cur0 spent).
        // exactOut: specified is the token being received.
        bool specifiedIsZero = exactInput ? params.zeroForOne : !params.zeroForOne;
        return specifiedIsZero ? key.currency1 : key.currency0;
    }

    // -------------------------------------------------------------------------
    // ABI compatibility
    // -------------------------------------------------------------------------

    /// @notice Prevent accidental ETH pushes to this contract — v1 does not support native ETH.
    /// @dev Both receive() and fallback() revert. ETH routed through the router would otherwise
    ///      be stuck (no withdrawal path).
    receive() external payable {
        revert UnsupportedToken(address(0));
    }

    fallback() external payable {
        revert HookMisconfigured();
    }
}
