// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// -----------------------------------------------------------------------------
// LicenseRegistry — Seqora v1
//
// Plan (§3, §4): per-design licensing layer built on top of the immutable DesignRegistry.
// Implements Story-PIL semantics natively on Base (research 2026-04-16 §2 confirmed Story is
// L1-only, no Base). Templates are a governance-curated catalog (SPDX-style) — NOT per-tokenId.
//
//   design (DesignRegistry.tokenId)
//        ↓ (registrant or governance chooses a template + grants)
//   License Token (ERC-721 id = licenseTokenId)  ←→  (templateId, tokenId, licensee)
//
// Upgradeability
// --------------
//   UUPS (per architecture spec: UUPS only for LicenseRegistry + BiosafetyCourt). Implementation
//   calls `_disableInitializers()` in the constructor; state lives in the proxy. Upgrade is
//   `onlyOwner` via `_authorizeUpgrade`.
//
// Responsibilities
// ----------------
//   - Template catalog — `registerLicenseTemplate` / `setLicenseTemplateActive` /
//     `getLicenseTemplate`. Owner-only. Validates `pilFlags` combinations on register.
//   - Grant — `grantLicense(tokenId, licenseId, licensee, expiry, feePaid)`. Callable by the
//     tokenId's registrant (looked up via DesignRegistry) OR owner/governance. Mints an
//     ERC-721 License Token to the licensee.
//   - Revoke — `revokeLicense(licenseTokenId, reason)`. Same auth set.
//   - Validity — `checkLicenseValid(tokenId, user)` — non-reverting view; false for expired,
//     revoked, or missing. Pausing DOES NOT affect validity (existing licenses survive).
//   - Payment relay — deferred. `feePaid` is a scalar recorded in the `License` struct; the
//     actual fund movement is RoyaltyRouter's job. An optional `feeRouter` address, settable
//     by owner, is carried as a storage slot so v2 can wire RoyaltyRouter without breaking
//     ABI. It is NOT invoked in v1.
//
// PIL flag semantics (Story PIL re-implemented)
// --------------------------------------------
//   Bits defined in SeqoraTypes.PIL_* (v1 = 5 bits; 11 reserved). Validation on register:
//     - `pilFlags` must be a subset of `PIL_V1_MASK` (reject unknown bits).
//     - `PIL_DERIVATIVE` requires `PIL_ATTRIBUTION` (downstream must credit).
//     - `PIL_EXCLUSIVE` + `PIL_TRANSFERABLE` is ALLOWED (transferable exclusive is a real
//       market primitive — e.g. an exclusive license that can be assigned to an SPV).
//     - `commercialUse` / `requiresAttribution` legacy booleans must agree with the flag
//       bits (belt-and-suspenders; prevents silent catalogue drift).
//   Runtime at grant time:
//     - At most ONE non-revoked, non-expired grant with `PIL_EXCLUSIVE` may exist per
//       tokenId. Re-granting while an exclusive is active reverts.
//
// Re-grant policy (choice point)
// ------------------------------
//   Multiple grants with the SAME (tokenId, licensee, templateId) are ALLOWED and each
//   returns a new `licenseTokenId`. Rationale: (a) institutions often sub-license and may
//   want multiple seats on one template, (b) enforcing uniqueness would require an O(1)
//   lookup that adds storage for a negligible safety benefit. `checkLicenseValid` returns
//   true as soon as ANY of the user's grants is valid. Exception: exclusive (PIL_EXCLUSIVE)
//   templates — still only one active grant per tokenId across all licensees.
//
// Fork-graph royalty inheritance (read path)
// ------------------------------------------
//   LicenseRegistry intentionally does NOT compute parent royalty splits. Marketplaces read:
//     1. `getLicense(licenseTokenId)` → `License { tokenId, licenseId, licensee, ... }`
//     2. `IDesignRegistry(designRegistry).getDesign(tokenId).parentTokenIds`
//     3. `IRoyaltyRouter(router).computeSplit(...)` (RoyaltyRouter not in v1 ship scope)
//   This keeps the registry cheap and keeps fork-graph arithmetic in one place.
//
// Discrepancies from task brief (see agent-log entry for orchestrator attention)
// ------------------------------------------------------------------------------
//   1. Task says "createTemplate(tokenId, LicenseTemplate) callable by the registrant".
//      Interface declares `registerLicenseTemplate(LicenseTemplate calldata)` with no
//      tokenId param — templates are a governance-curated catalog (SPDX-style, keyed by
//      `licenseId`), not per-tokenId. I follow the interface. Per-registrant templates can
//      be added in v2 by hashing (registrant, salt) into the licenseId.
//   2. Task describes `openGrant=true` licensee-initiated grants with payment. Interface has
//      no `openGrant` field or payable path; `grantLicense` is non-payable. v1 auth set is
//      (registrant-of-tokenId, owner/governance). The `feeRouter` stub is reserved for v2.
//   3. Task says "LicenseTemplate has defaultDuration (uint32 days)" and "pilFlags bitfield
//      (uint16)". The existing struct had neither; I added both as appended fields (ABI
//      non-breaking — the struct is only consumed via the contract's own calls).
// -----------------------------------------------------------------------------

import { ERC721Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { ILicenseRegistry } from "./interfaces/ILicenseRegistry.sol";
import { IDesignRegistry } from "./interfaces/IDesignRegistry.sol";
import { SeqoraTypes } from "./libraries/SeqoraTypes.sol";
import { SeqoraErrors } from "./libraries/SeqoraErrors.sol";

/// @title LicenseRegistry
/// @notice Per-design license templates + ERC-721 License Tokens, with Story-PIL semantics.
/// @dev UUPS-upgradable. Owner (Seqora governance multisig) manages the template catalog,
///      can revoke licenses, pause new grants, and authorize implementation upgrades.
contract LicenseRegistry is
    Initializable,
    ERC721Upgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ILicenseRegistry
{
    // -------------------------------------------------------------------------
    // Local errors (impl-specific; interface-level errors live on ILicenseRegistry)
    // -------------------------------------------------------------------------

    /// @notice Thrown on any attempt to call `renounceOwnership` — governance bricking disabled.
    error RenounceDisabled();

    /// @notice Thrown when caller is not authorised to perform the action.
    /// @param caller msg.sender.
    error NotAuthorized(address caller);

    /// @notice Thrown when `pilFlags` contains bits outside `PIL_V1_MASK`.
    /// @param pilFlags The supplied bitfield.
    error InvalidPilFlags(uint16 pilFlags);

    /// @notice Thrown when `PIL_DERIVATIVE` is set without `PIL_ATTRIBUTION`.
    error DerivativeRequiresAttribution();

    /// @notice Thrown when legacy `commercialUse` / `requiresAttribution` booleans contradict `pilFlags`.
    error PilFlagBooleanMismatch();

    /// @notice Thrown when `grantLicense` is attempted against an inactive / retired template.
    /// @param licenseId Template id.
    error TemplateInactive(bytes32 licenseId);

    /// @notice Thrown when a second active exclusive grant is attempted for the same tokenId.
    /// @param tokenId Design id.
    /// @param existingLicenseTokenId The already-outstanding exclusive License Token id.
    error ExclusiveAlreadyGranted(uint256 tokenId, uint256 existingLicenseTokenId);

    /// @notice Thrown when `tokenId` is not a registered design in the DesignRegistry.
    /// @param tokenId Design id that failed the existence check.
    error UnknownDesign(uint256 tokenId);

    /// @notice Thrown when attempting to transfer a non-transferable license token.
    /// @param licenseTokenId License token id.
    error LicenseNotTransferable(uint256 licenseTokenId);

    /// @notice Thrown when `revokeLicense` is called on an already-revoked license.
    /// @param licenseTokenId License token id.
    error AlreadyRevoked(uint256 licenseTokenId);

    /// @notice Thrown when a template's `defaultDuration` (in days) exceeds `MAX_LICENSE_DURATION`.
    /// @dev Per audit finding M-04. `0` (perpetual) is always allowed.
    /// @param suppliedDays Caller-supplied duration in days.
    /// @param maxDays The enforced cap in days (MAX_LICENSE_DURATION / 1 day).
    error DurationTooLong(uint32 suppliedDays, uint32 maxDays);

    // -------------------------------------------------------------------------
    // Impl-only events (interface declares the four headline events)
    // -------------------------------------------------------------------------

    /// @notice Emitted when the optional feeRouter (v2 RoyaltyRouter stub) is updated.
    /// @param prev Previous router address.
    /// @param next New router address.
    event FeeRouterSet(address indexed prev, address indexed next);

    /// @notice Emitted inside `_authorizeUpgrade` before OZ runs the 1822 check. Lets off-chain
    ///         monitors flag pending-upgrade simulations without waiting for `Upgraded`.
    /// @param newImplementation Address governance is authorising as the next impl.
    event UpgradeAuthorized(address indexed newImplementation);

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Seconds per day — `defaultDuration` is expressed in days, converted on grant.
    uint64 internal constant SECONDS_PER_DAY = 86_400;

    // -------------------------------------------------------------------------
    // Storage (UUPS — any addition must append to preserve slot layout)
    // -------------------------------------------------------------------------

    /// @notice Immutable reference (per deployment) to the canonical DesignRegistry.
    /// @dev Not `immutable` (UUPS impl slots are not immutable-friendly); set in initializer
    ///      and effectively frozen. Upgrades that rotate this pointer would break the
    ///      invariant "every License Token points to a valid tokenId" — forbidden by design.
    IDesignRegistry public designRegistry;

    /// @notice Optional v2 RoyaltyRouter. Address(0) in v1 (no payment routing). Owner-settable.
    /// @dev Reserved slot — v2 will wire this in without breaking ABI. Currently unused.
    address public feeRouter;

    /// @notice Monotonic counter for new License Token ids.
    uint256 public nextLicenseTokenId;

    /// @dev licenseId -> full LicenseTemplate.
    mapping(bytes32 => SeqoraTypes.LicenseTemplate) private _templates;

    /// @dev licenseTokenId -> full License record.
    mapping(uint256 => SeqoraTypes.License) private _licenses;

    /// @dev tokenId -> outstanding exclusive licenseTokenId, or 0 if none.
    mapping(uint256 => uint256) private _exclusiveHolder;

    /// @dev Reverse index for O(1)-ish `checkLicenseValid`. Maps (tokenId, holder) to the list
    ///      of licenseTokenIds ever minted-to or transferred-to `holder` against `tokenId`.
    ///      Written on grant (`grantLicense`) and on transfer (`_update`); entries are NEVER
    ///      removed — iteration filters by `_isLicenseLive`, and realistic per-holder arrays
    ///      stay small (<< 16) in practice. Closes audit M-01: griefing via mass-grant no
    ///      longer linearly scales `checkLicenseValid` runtime because only the target
    ///      holder's array is walked, not the entire grant history.
    mapping(uint256 tokenId => mapping(address holder => uint256[] licenseTokenIds)) private _licensesOf;

    /// @dev Reserved storage for future fields (UUPS upgrade safety). 50 slots is the standard
    ///      OZ reservation pattern; reduce this gap by N for every N new fields added above.
    uint256[44] private __gap;

    // -------------------------------------------------------------------------
    // Constructor / initializer
    // -------------------------------------------------------------------------

    /// @notice Locks the implementation contract so it can only be initialised via a proxy.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-time initializer for the proxy.
    /// @dev Wires the DesignRegistry reference, sets the governance owner, and initialises all
    ///      parent modules. `nextLicenseTokenId` starts at 1 — token id 0 is reserved as the
    ///      "missing" sentinel (consistent with `_exclusiveHolder`'s default of 0).
    /// @param registry The canonical, immutable DesignRegistry this LicenseRegistry is bound to.
    /// @param governance Initial owner (Safety Council / governance multisig).
    function initialize(IDesignRegistry registry, address governance) external initializer {
        if (address(registry) == address(0)) revert SeqoraErrors.ZeroAddress();
        if (governance == address(0)) revert SeqoraErrors.ZeroAddress();

        __ERC721_init("Seqora License", "SEQ-LIC");
        __Ownable_init(governance);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        designRegistry = registry;
        nextLicenseTokenId = 1;
    }

    // -------------------------------------------------------------------------
    // Templates (governance-gated)
    // -------------------------------------------------------------------------

    /// @inheritdoc ILicenseRegistry
    /// @dev Owner-only. Validates `pilFlags` against `PIL_V1_MASK`, enforces the
    ///      `PIL_DERIVATIVE ⇒ PIL_ATTRIBUTION` rule, and checks that legacy
    ///      `commercialUse` / `requiresAttribution` booleans agree with the flags.
    ///      The template is persisted ACTIVE regardless of the supplied `active` field —
    ///      use `setLicenseTemplateActive` to retire later.
    function registerLicenseTemplate(SeqoraTypes.LicenseTemplate calldata template) external onlyOwner {
        if (template.licenseId == bytes32(0)) revert SeqoraErrors.ZeroValue();
        if (_templates[template.licenseId].licenseId != bytes32(0)) {
            revert LicenseTemplateAlreadyExists(template.licenseId);
        }

        _validatePilFlags(template);
        _validateDuration(template.defaultDuration);

        SeqoraTypes.LicenseTemplate storage stored = _templates[template.licenseId];
        stored.licenseId = template.licenseId;
        stored.name = template.name;
        stored.uri = template.uri;
        stored.commercialUse = template.commercialUse;
        stored.requiresAttribution = template.requiresAttribution;
        stored.active = true;
        stored.pilFlags = template.pilFlags;
        stored.defaultDuration = template.defaultDuration;

        emit LicenseTemplateRegistered(template.licenseId, template.name, template.uri);
        emit LicenseTemplateStatusChanged(template.licenseId, true);
    }

    /// @inheritdoc ILicenseRegistry
    /// @dev Owner-only. Setting `active = false` is the "retire" path from the task brief —
    ///      existing grants on this template survive (validity only reads `_licenses`, not
    ///      template.active); only NEW grants against this template are blocked.
    function setLicenseTemplateActive(bytes32 licenseId, bool active) external onlyOwner {
        SeqoraTypes.LicenseTemplate storage t = _templates[licenseId];
        if (t.licenseId == bytes32(0)) revert UnknownLicenseTemplate(licenseId);
        if (t.active == active) return;
        t.active = active;
        emit LicenseTemplateStatusChanged(licenseId, active);
    }

    /// @inheritdoc ILicenseRegistry
    function getLicenseTemplate(bytes32 licenseId) external view returns (SeqoraTypes.LicenseTemplate memory template) {
        template = _templates[licenseId];
        if (template.licenseId == bytes32(0)) revert UnknownLicenseTemplate(licenseId);
    }

    // -------------------------------------------------------------------------
    // Grants
    // -------------------------------------------------------------------------

    /// @inheritdoc ILicenseRegistry
    /// @dev Auth: caller must be the `registrant` of `tokenId` (looked up on DesignRegistry)
    ///      OR the contract owner (governance). Payment routing is out-of-scope in v1; the
    ///      `feePaid` argument is recorded verbatim on the License struct for accounting.
    ///
    ///      Reverts: `Paused` if paused, `UnknownDesign` if tokenId not registered,
    ///      `UnknownLicenseTemplate` for missing/retired templates, `TemplateInactive` for
    ///      retired templates, `NotAuthorized` if caller is neither registrant nor owner,
    ///      `ZeroAddress` if licensee is zero, `ExclusiveAlreadyGranted` if a prior active
    ///      exclusive grant exists on the same tokenId.
    ///
    ///      Non-reentrant — prepares for v2 when `feeRouter` may move funds via `IFeePayer`.
    function grantLicense(uint256 tokenId, bytes32 licenseId, address licensee, uint64 expiry, uint128 feePaid)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 licenseTokenId)
    {
        if (licensee == address(0)) revert SeqoraErrors.ZeroAddress();

        // --- Template lookup ---
        SeqoraTypes.LicenseTemplate storage t = _templates[licenseId];
        if (t.licenseId == bytes32(0)) revert UnknownLicenseTemplate(licenseId);
        if (!t.active) revert TemplateInactive(licenseId);

        // --- Design existence + authorisation ---
        if (!designRegistry.isRegistered(tokenId)) revert UnknownDesign(tokenId);
        address registrant = designRegistry.getDesign(tokenId).registrant;

        if (msg.sender != registrant && msg.sender != owner()) {
            revert NotAuthorized(msg.sender);
        }

        // --- Exclusivity guard ---
        uint16 pilFlags = t.pilFlags;
        if (pilFlags & SeqoraTypes.PIL_EXCLUSIVE != 0) {
            uint256 existing = _exclusiveHolder[tokenId];
            if (existing != 0 && _isLicenseLive(existing)) {
                revert ExclusiveAlreadyGranted(tokenId, existing);
            }
        }

        // --- Expiry derivation ---
        // expiry == 0 AND template.defaultDuration > 0 → now + defaultDuration days.
        // expiry == 0 AND template.defaultDuration == 0 → perpetual (stored as 0).
        // expiry > 0 → honour caller's value (MUST be in the future — no past-expiry grants).
        // M-04: per-grant `expiry` overrides are capped at `block.timestamp + MAX_LICENSE_DURATION`
        //       to prevent 11M-year expiries indistinguishable from perpetual. Template-derived
        //       expiries are already bounded by `_validateDuration` on register.
        uint64 resolvedExpiry = expiry;
        if (resolvedExpiry == 0 && t.defaultDuration > 0) {
            // SECONDS_PER_DAY * MAX_LICENSE_DURATION/1day fits in uint64 (<< 2^64) — safe promotion.
            resolvedExpiry = uint64(block.timestamp) + uint64(t.defaultDuration) * SECONDS_PER_DAY;
        } else if (resolvedExpiry != 0) {
            if (resolvedExpiry <= block.timestamp) {
                revert SeqoraErrors.ZeroValue(); // reuse: "must be in future" is a ZeroValue-shaped error
            }
            uint256 delta = uint256(resolvedExpiry) - block.timestamp;
            if (delta > SeqoraTypes.MAX_LICENSE_DURATION) {
                // Report violation in *days* for consistency with template-level error.
                // Cast safety: `delta / SECONDS_PER_DAY` <= uint64.max / 86400 < 2^48 — fits uint32
                // only up to ~130 years-over-max, so saturate at uint32.max on the upper edge.
                uint256 deltaDays = delta / SECONDS_PER_DAY;
                // forge-lint: disable-next-line(unsafe-typecast)
                uint32 reportedDays = deltaDays > type(uint32).max ? type(uint32).max : uint32(deltaDays);
                // forge-lint: disable-next-line(unsafe-typecast)
                uint32 maxDays = uint32(SeqoraTypes.MAX_LICENSE_DURATION / SECONDS_PER_DAY);
                revert DurationTooLong(reportedDays, maxDays);
            }
        }

        // --- Mint + persist ---
        licenseTokenId = nextLicenseTokenId;
        unchecked {
            // uint256 overflow is unreachable under any realistic license volume.
            nextLicenseTokenId = licenseTokenId + 1;
        }

        SeqoraTypes.License storage l = _licenses[licenseTokenId];
        l.tokenId = tokenId;
        l.licenseId = licenseId;
        l.licensee = licensee;
        l.grantedAt = uint64(block.timestamp);
        l.expiry = resolvedExpiry;
        l.feePaid = feePaid;
        // l.revoked = false (default)

        if (pilFlags & SeqoraTypes.PIL_EXCLUSIVE != 0) {
            _exclusiveHolder[tokenId] = licenseTokenId;
        }

        // M-01: write to the reverse index BEFORE the ERC-721 mint. A well-behaved
        // receiver may re-enter a view on this contract and the state should be
        // consistent by then; the nonReentrant guard blocks write re-entry.
        _licensesOf[tokenId][licensee].push(licenseTokenId);

        // ERC-721 mint: licensee gets the License Token. `_safeMint` enforces receiver hook
        // so a non-receiver contract can't silently accept tokens. The ERC721 hook is the
        // only reentrancy vector; `nonReentrant` above defends against it.
        _safeMint(licensee, licenseTokenId);

        emit LicenseGranted(licenseTokenId, tokenId, licenseId, licensee, resolvedExpiry, feePaid);
    }

    /// @inheritdoc ILicenseRegistry
    /// @dev Auth: caller must be the `registrant` of `tokenId` OR the contract owner. In v2
    ///      the BiosafetyCourt address gains revocation authority as a third branch.
    ///
    ///      Idempotency: reverts `AlreadyRevoked` if already revoked (prevents event spam /
    ///      silent-no-op governance txns). Pause does NOT affect revoke — owners must always
    ///      be able to kill a compromised license.
    function revokeLicense(uint256 licenseTokenId, string calldata reason) external {
        SeqoraTypes.License storage l = _licenses[licenseTokenId];
        if (l.licensee == address(0)) revert SeqoraErrors.UnknownToken(licenseTokenId);
        if (l.revoked) revert AlreadyRevoked(licenseTokenId);

        address registrant = designRegistry.getDesign(l.tokenId).registrant;
        if (msg.sender != registrant && msg.sender != owner()) {
            revert NotAuthorized(msg.sender);
        }

        l.revoked = true;

        // If this was the outstanding exclusive grant, clear the slot so a replacement
        // can be issued. The License Token itself is not burned — downstream auditors
        // want to see revoked licenses in history.
        SeqoraTypes.LicenseTemplate storage t = _templates[l.licenseId];
        if (t.pilFlags & SeqoraTypes.PIL_EXCLUSIVE != 0 && _exclusiveHolder[l.tokenId] == licenseTokenId) {
            _exclusiveHolder[l.tokenId] = 0;
        }

        emit LicenseRevoked(licenseTokenId, msg.sender, reason);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice O(1) validity check for a specific License Token + holder pair.
    /// @dev Returns true iff the referenced License Token is non-revoked, non-expired, and
    ///      the licensee matches the current ERC-721 owner (so post-transfer validity tracks
    ///      the holder, not the original licensee — required for `PIL_TRANSFERABLE`). Does
    ///      NOT revert on unknown licenseTokenId; returns false.
    /// @param licenseTokenId ERC-721 License Token id.
    /// @param licensee Candidate holder to match against current ownership.
    /// @return valid True iff the license is currently usable by `licensee`.
    function isLicenseValid(uint256 licenseTokenId, address licensee) external view returns (bool valid) {
        SeqoraTypes.License storage l = _licenses[licenseTokenId];
        if (l.licensee == address(0)) return false; // unknown
        if (l.revoked) return false;
        if (l.expiry != 0 && l.expiry < block.timestamp) return false;
        // Track current holder — exists() is implicit: if revoked + transfer logic didn't burn
        // then ownerOf reverts only when non-existent (which we've already filtered).
        if (_ownerOf(licenseTokenId) != licensee) return false;
        valid = true;
    }

    /// @inheritdoc ILicenseRegistry
    /// @notice Returns true iff `user` currently holds at least one non-revoked, non-expired
    ///         license against `tokenId`.
    /// @dev Invariant (chosen here): a single user MAY hold multiple live licenses against the
    ///      same `tokenId` — non-exclusive templates are explicitly re-grantable per the
    ///      registry's re-grant policy and transferable licenses can accumulate via secondary
    ///      transfers. Therefore the reverse index stores an ARRAY of licenseTokenIds per
    ///      (tokenId, holder), not a scalar. The array is append-only — entries are NEVER
    ///      removed on revoke or expiry or transfer-out; the scan filters them via
    ///      `_isLicenseLive` + `_ownerOf(id) == user`. Per-holder arrays are bounded in
    ///      practice (<< 16) because they are indexed by (tokenId, user), not by global
    ///      nextLicenseTokenId. Closes audit M-01: griefing via mass-grants to throwaway
    ///      addresses can NOT inflate this loop for any honest `user`.
    function checkLicenseValid(uint256 tokenId, address user) external view returns (bool valid) {
        // MUST remain — _ownerOf(burnt/non-existent) == 0; a `user == 0` probe would otherwise
        // match any never-minted or burnt license id via _ownerOf returning 0.
        if (user == address(0)) return false;

        uint256[] storage ids = _licensesOf[tokenId][user];
        uint256 n = ids.length;
        for (uint256 i = 0; i < n;) {
            uint256 id = ids[i];
            SeqoraTypes.License storage l = _licenses[id];
            if (!l.revoked && (l.expiry == 0 || l.expiry >= block.timestamp) && _ownerOf(id) == user) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        valid = false;
    }

    /// @inheritdoc ILicenseRegistry
    function getLicense(uint256 licenseTokenId) external view returns (SeqoraTypes.License memory license) {
        license = _licenses[licenseTokenId];
        if (license.licensee == address(0)) revert SeqoraErrors.UnknownToken(licenseTokenId);
    }

    /// @notice Whether this registry is currently paused (disables new grants only).
    /// @return p True iff paused.
    function isPaused() external view returns (bool p) {
        p = paused();
    }

    // -------------------------------------------------------------------------
    // Governance / admin
    // -------------------------------------------------------------------------

    /// @notice Halt new license grants. Existing licenses remain valid.
    /// @dev Owner-only. `isLicenseValid` / `checkLicenseValid` / `revokeLicense` are NOT
    ///      affected — pausing must not invalidate legitimately-held licenses (brief §6).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume new license grants.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Set the v2 RoyaltyRouter address (payment-routing stub for forward compat).
    /// @dev Owner-only. Not used in v1 — `grantLicense` records `feePaid` without routing. The
    ///      field is reserved so v2 can wire RoyaltyRouter without breaking ABI.
    /// @param router New router address (address(0) disables).
    function setFeeRouter(address router) external onlyOwner {
        address prev = feeRouter;
        feeRouter = router;
        emit FeeRouterSet(prev, router);
    }

    /// @notice Override disables `renounceOwnership` to prevent permanent governance bricking.
    /// @dev Mirrors L-04 fix applied to ScreeningAttestations. A renounced owner cannot register
    ///      templates, revoke licenses, pause, rotate the feeRouter, or authorize upgrades —
    ///      every lever collapses. Always reverts with `RenounceDisabled`.
    function renounceOwnership() public view override(OwnableUpgradeable) onlyOwner {
        revert RenounceDisabled();
    }

    // -------------------------------------------------------------------------
    // ERC-721 transfer gating
    // -------------------------------------------------------------------------

    /// @dev Enforces `PIL_TRANSFERABLE` at the ERC-721 `_update` seam. Mints (`from == 0`)
    ///      and burns (`to == 0`) are always allowed — the flag only governs licensee-to-
    ///      third-party transfers. When paused, transfers continue to work (pausing halts
    ///      NEW GRANTS, not existing license mobility) per brief §6.
    ///
    ///      We also block transfers of REVOKED licenses so a revoked license can't be
    ///      "sold on" to an unwary buyer.
    function _update(address to, uint256 licenseTokenId, address auth)
        internal
        override
        returns (address previousOwner)
    {
        previousOwner = super._update(to, licenseTokenId, auth);

        // Mint: previousOwner == address(0), no transfer semantics to enforce.
        // Burn: to == address(0), allow (we don't mint-and-burn in v1 but keep the door open).
        if (previousOwner != address(0) && to != address(0)) {
            SeqoraTypes.License storage l = _licenses[licenseTokenId];
            if (l.revoked) revert LicenseRevokedError(licenseTokenId);
            SeqoraTypes.LicenseTemplate storage t = _templates[l.licenseId];
            if (t.pilFlags & SeqoraTypes.PIL_TRANSFERABLE == 0) {
                revert LicenseNotTransferable(licenseTokenId);
            }
            // M-01: Maintain the reverse index for the new holder on transfer. We DO NOT
            // remove the previous owner's entry — `checkLicenseValid` filters stale entries
            // via `_ownerOf(id) == user`. Appending is O(1); lazy cleanup keeps
            // per-transfer gas flat.
            _licensesOf[l.tokenId][to].push(licenseTokenId);
        }
    }

    /// @dev Overrides OZ v5's `_approve` to fail fast on non-transferable licenses. Allows
    ///      `to == address(0)` (approval clearing) so holders can always reset stale state.
    ///      Per-token check is cheap (one SLOAD of the license + one of the template). Audit
    ///      M-02: prevents wallets and marketplace aggregators from displaying misleading
    ///      "approved" state on non-transferable license tokens.
    ///
    ///      NOTE on `setApprovalForAll`: not overridden. `setApprovalForAll` is operator-level
    ///      (not per-token) and cannot cheaply introspect the caller's license catalogue; its
    ///      practical effect is a no-op because any transfer still routes through `_update`
    ///      which blocks non-transferable licenses. Integrators relying on
    ///      `isApprovedForAll` to gate listing acceptance must still consult `pilFlags` per
    ///      license.
    function _approve(address to, uint256 licenseTokenId, address auth, bool emitEvent) internal override {
        if (to != address(0)) {
            _assertTransferable(licenseTokenId);
        }
        super._approve(to, licenseTokenId, auth, emitEvent);
    }

    // -------------------------------------------------------------------------
    // UUPS
    // -------------------------------------------------------------------------

    /// @notice UUPS upgrade authorisation hook. Owner-only.
    /// @dev Governance multisig authorises every implementation swap. OZ's `UUPSUpgradeable`
    ///      additionally checks the new implementation is a valid ERC-1822 Proxiable. Upgrading
    ///      the `designRegistry` pointer is explicitly NOT supported; a v2 implementation that
    ///      re-binds the pointer must include a one-shot re-initializer that wipes pending
    ///      state and is audit-reviewed.
    /// @param newImplementation Address of the new implementation contract.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // OZ validates `newImplementation` against ERC-1822 in `upgradeToAndCall`. Emit so
        // off-chain monitors flag pending-upgrade authorizations even without the proxy-level
        // `Upgraded` event (some tooling misses internal proxy events).
        emit UpgradeAuthorized(newImplementation);
    }

    // -------------------------------------------------------------------------
    // ERC-165
    // -------------------------------------------------------------------------

    /// @inheritdoc ERC721Upgradeable
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Upgradeable) returns (bool) {
        return interfaceId == type(ILicenseRegistry).interfaceId || super.supportsInterface(interfaceId);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev A license is "live" iff non-revoked, non-expired, and the license token still
    ///      has an owner. Used for exclusive-grant guard in `grantLicense`.
    ///
    ///      NOTE on the historical `l.revoked` defensive check: removed as of the 18:30
    ///      audit-fix pass. The single call-site (`grantLicense`'s exclusive-slot guard)
    ///      reads `_exclusiveHolder[tokenId]`, which `revokeLicense` ALREADY clears when it
    ///      revokes the exclusive holder (see `revokeLicense` body). A stale revoked id
    ///      could only reach this function via a future, currently-nonexistent code path —
    ///      at which point adding the check back is a one-line defence. Keeping dead code
    ///      made the branch look "covered" under `forge coverage` while never actually
    ///      firing; removing it clarifies the invariant and lets coverage report truthfully.
    function _isLicenseLive(uint256 licenseTokenId) internal view returns (bool) {
        SeqoraTypes.License storage l = _licenses[licenseTokenId];
        if (l.licensee == address(0)) return false;
        if (l.expiry != 0 && l.expiry < block.timestamp) return false;
        return _ownerOf(licenseTokenId) != address(0);
    }

    /// @dev Reverts with `LicenseNotTransferable(licenseTokenId)` if the license's template
    ///      does NOT have `PIL_TRANSFERABLE` set. Used by the `_approve` override (M-02) and
    ///      reused-by-construction by `_update` (for actual transfers).
    function _assertTransferable(uint256 licenseTokenId) internal view {
        SeqoraTypes.License storage l = _licenses[licenseTokenId];
        // Unknown / never-minted token — let OZ surface the error at the super call site.
        if (l.licensee == address(0)) return;
        SeqoraTypes.LicenseTemplate storage t = _templates[l.licenseId];
        if (t.pilFlags & SeqoraTypes.PIL_TRANSFERABLE == 0) {
            revert LicenseNotTransferable(licenseTokenId);
        }
    }

    /// @dev Enforces `MAX_LICENSE_DURATION` cap on template `defaultDuration` (expressed in
    ///      DAYS). `0` is allowed (= "no default expiry; perpetual unless overridden"). Audit
    ///      M-04 closer.
    function _validateDuration(uint32 durationDays) internal pure {
        if (durationDays == 0) return;
        // Cast safety: MAX_LICENSE_DURATION / SECONDS_PER_DAY == 36_500 (100 years in days),
        // well within uint32 (max 4.29B).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 maxDays = uint32(SeqoraTypes.MAX_LICENSE_DURATION / SECONDS_PER_DAY);
        if (durationDays > maxDays) revert DurationTooLong(durationDays, maxDays);
    }

    /// @dev PIL flag sanity: reject unknown bits, require PIL_DERIVATIVE ⇒ PIL_ATTRIBUTION,
    ///      and require legacy booleans to agree with the flags.
    function _validatePilFlags(SeqoraTypes.LicenseTemplate calldata template) internal pure {
        uint16 flags = template.pilFlags;

        // Reject bits outside the v1 mask.
        if (flags & ~SeqoraTypes.PIL_V1_MASK != 0) revert InvalidPilFlags(flags);

        // PIL_DERIVATIVE requires PIL_ATTRIBUTION (downstream must credit).
        if (flags & SeqoraTypes.PIL_DERIVATIVE != 0 && flags & SeqoraTypes.PIL_ATTRIBUTION == 0) {
            revert DerivativeRequiresAttribution();
        }

        // Legacy booleans must match flag bits.
        bool flagCommercial = (flags & SeqoraTypes.PIL_COMMERCIAL) != 0;
        bool flagAttribution = (flags & SeqoraTypes.PIL_ATTRIBUTION) != 0;
        if (template.commercialUse != flagCommercial) revert PilFlagBooleanMismatch();
        if (template.requiresAttribution != flagAttribution) revert PilFlagBooleanMismatch();
    }
}
