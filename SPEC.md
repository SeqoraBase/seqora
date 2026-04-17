# Seqora Protocol Specification

*v1 · Base mainnet · this document describes what the contracts do, how they are trusted, and what they explicitly do not do.*

---

## 1. Overview

Seqora is an on-chain registry for engineered biological designs. Every registered design is **content-addressed** — its ERC-1155 `tokenId` is the keccak256 of the URDNA2015-canonicalized SBOL3 document, so identical designs always produce identical ids regardless of who registers them. Designs are **gated** — registration requires a live attestation from an approved biosafety screener. Designs are **composable** — forks record their parents on-chain and inherit royalties through the graph. Designs are **monetizable** — licenses are enforced at the point of swap through a Uniswap v4 hook, not politely requested from marketplaces through EIP-2981.

The protocol is six contracts, each with a single responsibility. Registration is immutable. Licensing is upgradeable. Royalties are enforced by code. Biosafety is governance-curated with a dispute path that slashes bad actors.

---

## 2. Design goals

1. **One tokenId per design, no matter who registers it.** Content-addressing is non-negotiable — the canonical hash is the ground truth.
2. **No listing without a screening attestation.** Biosafety is a contract-level invariant, not a UX nudge.
3. **Immutability where upgrades break trust; upgrades where schemas must evolve.** Registration, screening, and provenance are immutable. Licensing and the biosafety court are UUPS — their state surfaces will move as standards mature.
4. **Royalties enforced at the venue of exchange.** EIP-2981 is a soft suggestion; the v4 hook is an invariant.
5. **Emergency takedown exists, but is reversible.** The Safety Council can freeze a tokenId immediately, but the freeze auto-lifts after 30 days unless the DAO ratifies.
6. **Fail closed at trust boundaries.** Non-reverting validity views (`isValid`, `checkLicenseValid`) let downstream contracts fail cleanly. Paused state never invalidates grants that were valid at the time they were issued.

---

## 3. The six primitives

### 3.1 `DesignRegistry` · ERC-1155 · immutable

The canonical registration primitive.

- `tokenId == uint256(keccak256(URDNA2015(SBOL3)))`. Same design → same id, forever.
- `register(registrant, canonicalHash, ga4ghSeqhash, arweaveTx, ceramicStreamId, royalty, attUID, parents)` mints iff `ScreeningAttestations.isValid(attUID, canonicalHash, registrant)` returns true.
- `forkRegister(ForkParams)` records up to `MAX_PARENTS = 16` parent tokenIds; the protocol does not compute derivative royalty splits on-chain — marketplaces walk the parent graph and settle off-chain.
- Not Ownable, not Pausable, not upgradeable. The screening contract address is set once in the constructor. If the screening contract must change, deploy a fresh `DesignRegistry` — tokenIds remain stable because they are hash-derived.

**Trust:** zero — every check happens on-chain against inputs the caller cannot forge without a valid attestation.

### 3.2 `ScreeningAttestations` · EAS-backed · Ownable2Step

The biosafety gate.

- A governance-curated wrapper around the Ethereum Attestation Service. Approved attesters issue attestations against the Seqora schema; `DesignRegistry.register` consults `isValid(uid, canonicalHash, registrant)` as its listing gate.
- `isValid` is non-reverting. It checks schema match, EAS revocation, local revocation, expiry, attester approval, `canonicalHash` field match, `registrant` field match, and pause state in a single view.
- `localRevoke(uid)` blacklists an individual attestation UID as defence-in-depth when EAS-level revocation lags.
- Emergency pausable. Paused → `isValid` returns false → `DesignRegistry.register` reverts `AttestationInvalid` at its boundary.
- v1 launch attester set is a small number of Seqora-operated relayer signers that wrap JSON outputs from SecureDNA and IBBIS Common Mechanism, because those services do not yet emit EAS-native attestations.

**Trust:** the attester set. Compromise of an approved attester is mitigated by `localRevoke` + `revokeAttester`.

### 3.3 `LicenseRegistry` · ERC-721 · UUPS

The licensing layer. Implements Story-PIL semantics natively on Base.

- Templates are a **governance-curated catalog** (SPDX-style), not per-tokenId wrappers. Register once, grant many times.
- `grantLicense(tokenId, templateId, licensee, expiry, feePaid)` mints a License Token (ERC-721) to the licensee. Callable by the tokenId's registrant OR by governance.
- `revokeLicense(licenseTokenId, reason)` — same auth set.
- `checkLicenseValid(tokenId, user)` is non-reverting: false for expired, revoked, or missing grants. Pausing the registry does NOT invalidate existing grants — only new grants / revocations are halted.
- Payment relay is deferred: `feePaid` is recorded, but actual fund movement is `RoyaltyRouter`'s job. A `feeRouter` slot is reserved so v2 can wire push-flows without an ABI break.
- Upgradeable via UUPS, `_authorizeUpgrade` is `onlyOwner`.

#### PIL flag semantics

The `pilFlags` bitfield on each template must be a subset of `PIL_V1_MASK` (five bits in v1, eleven reserved):

| Flag | Meaning |
|---|---|
| `PIL_COMMERCIAL` | Commercial use permitted |
| `PIL_DERIVATIVE` | Derivative works permitted (requires `PIL_ATTRIBUTION`) |
| `PIL_ATTRIBUTION` | Downstream must credit |
| `PIL_EXCLUSIVE` | At most one active grant per tokenId across all licensees |
| `PIL_TRANSFERABLE` | License Token is transferable (combinable with `PIL_EXCLUSIVE`) |

At grant time, re-granting while an `PIL_EXCLUSIVE` template already has an active grant on that tokenId reverts. Non-exclusive templates permit multiple concurrent grants to the same licensee (institutions routinely sub-license and need multiple seats).

### 3.4 `RoyaltyRouter` · IHooks (Uniswap v4) · EIP-2981

The payments hub. Three modes of operation, same contract.

1. **Off-chain EIP-2981 lookup.** Marketplaces call `royaltyInfo(tokenId, salePrice)` and split manually. Polite but unenforceable.
2. **Direct push.** Non-swap flows (e.g. open-grant licensing fees) call `distribute(tokenId, currency, amount)` — 3% protocol fee routes to the treasury, remainder to a per-tokenId 0xSplits contract that encodes the royalty rule registered in `DesignRegistry`.
3. **Uniswap v4 hook.** When a license-bearing token is swapped through a pool that installs the router as its hook, `beforeSwap` and `afterSwap` intercept the swap and debit royalty + protocol fee from the input currency.

The invariant for mode 3 is: **the royalty + protocol fee is always denominated in the currency the swapper is spending**. That side is on the allowlist (USDC in v1) so the hook can take liquid payment. v4 calls this the *specified* side on `exactInput` and the *unspecified* side on `exactOutput`; the router handles both. The allowlisted currency set is governance-controlled.

Hook address deployment is enforced at construction — v4 encodes hook permissions in the trailing 14 bits of the contract address. `validateHookAddress(this)` reverts on mismatch, failing deploys loudly until the right CREATE2 salt is used.

### 3.5 `ProvenanceRegistry` · EIP-712 · immutable

The append-only provenance log per design. Two record kinds:

1. **ModelCard** — AI/ML lineage (weights hash, prompt hash, seed, tool name/version, human contributor). Signed EIP-712 by the contributor, which lets relayers submit on the contributor's behalf while binding authorship to a key the human controls.
2. **WetLabAttestation** — governance-approved oracle asserts "this design was synthesized / validated, here is the off-chain receipt hash". Signed EIP-712 by `attestation.oracle` (must be in the approved oracle set).

Only the 32-byte EIP-712 digest is stored on-chain; full payloads travel via calldata for cheap off-chain indexing. On-chain footprint is `O(records × 1 slot + overhead)`, not `O(records × payload-bytes)`.

Cross-tokenId signature replay is closed at the schema level for `WetLabAttestation`: `tokenId` is the first signed field, so a signature captured for design A cannot be submitted against design B. ModelCard payloads are *allowed* to be reused across derivative tokenIds by design, with per-tokenId dedup (`_seenRecord[tokenId][recordHash]`).

Oracle set is mutable by the Seqora multisig; individual records can be locally revoked without touching history.

### 3.6 `BiosafetyCourt` · UUPS · Kleros-style

Disputes and emergency freezes.

**Reviewer stakes and disputes.**
- Anyone meeting `MIN_REVIEWER_STAKE` (1 ETH) can register as a reviewer and stake a bond.
- `raiseDispute(tokenId, reason)` locks `DISPUTE_BOND` (0.5 ETH) against the reviewer's stake. One open dispute per tokenId at a time.
- `resolveDispute(caseId, outcome)` is callable after the review window elapses and only by governance in v1 (arbitrator role). Outcomes:
  - `UpheldTakedown` — tokenId is frozen (unless already frozen by a concurrent council action, in which case the existing freeze is preserved and the dispute still closes). Raiser's bond is released.
  - `Dismissed` — raiser's `DISPUTE_BOND` is slashed. The slash splits via `DISMISSAL_TREASURY_CUT_BPS` / `DISMISSAL_REVIEWER_CUT_BPS`, with any residue going to the treasury.
  - `Settled` — no movement. Bond released.
- `requestUnstake` / `unstakeReviewer` are gated by `_disputeBondLocked[reviewer] > 0` — a reviewer cannot exit while any bond collateralizes a pending slash. Cooldown is `REVIEWER_UNSTAKE_COOLDOWN`.

**Safety Council emergency freeze.**
- The Safety Council is a multisig address distinct from the DAO-governance owner (per plan §6 #4, intended to be 5-of-9 with mixed biosecurity / IP / synbio expertise).
- `safetyCouncilFreeze(tokenId, reason)` freezes a tokenId for up to 30 days. The freeze auto-lifts if the DAO does not ratify within `FREEZE_RATIFY_WINDOW`.
- `ratifyFreeze(tokenId)` (governance) converts the freeze to a durable takedown.
- `rejectFreeze(tokenId)` (governance) lifts it immediately.
- `expireFreeze(tokenId)` (anyone) lifts the freeze after the window elapses — the council cannot extend via inaction.

**Settlement + reentrancy posture.**
- All ETH payouts happen *after* state mutations (CEI), with `nonReentrant` on every external entry point that touches balances. Payout failures revert with `TransferFailed(to, amount)`.
- Treasury accrual and reviewer-cut accrual are separated from `address(this).balance` so bond / deposit accounting is never conflated with revenue.

---

## 4. Canonical flows

### 4.1 Register a new design

```
registrant                  DesignRegistry             ScreeningAttestations
    │                              │                          │
    │── register(…attUID…) ───────▶│                          │
    │                              │── isValid(uid, hash) ───▶│
    │                              │◀────────── true ─────────│
    │                              │── _mint(registrant, tokenId, 1) ─┐
    │◀─ DesignRegistered ──────────│                                  │
    │                              ▼                                  │
    │                         parents[tokenId] = parents ◀────────────┘
```

`tokenId` is derived from `canonicalHash`; the registry refuses to mint if it is already registered. `parents` populates the fork graph for `forkRegister`.

### 4.2 Grant a license

```
registrant                LicenseRegistry              DesignRegistry
    │                            │                            │
    │── grantLicense(tokenId, templateId, licensee, expiry) ─▶│
    │                            │── registrantOf(tokenId) ──▶│
    │                            │◀────── registrant ─────────│
    │                            │── _mint ERC-721 ──┐
    │                            │                   │
    │◀─ LicenseGranted ──────────│◀──────────────────┘
```

`checkLicenseValid(tokenId, user)` returns true as soon as the user holds any non-expired, non-revoked grant. Pausing the registry does not touch existing grants.

### 4.3 Royalty on a swap (v4 hook path)

```
swapper ── swap ▶ PoolManager ── beforeSwap(key, params) ──▶ RoyaltyRouter
                       │                                         │
                       │◀── BeforeSwapDelta(+total, 0) ──────────│  (exactInput)
                       │                                         │
                       ├── executes swap with delta ─────────────┤
                       │                                         │
                       │── afterSwap(key, params, delta) ───────▶│
                       │                                         │── take(currency, router, total)
                       │                                         │── _distributeRoyalty(tokenId, amount)
```

On `exactOutput` the billing side flips to unspecified; the invariant that the hook is paid in the currency the swapper spends holds in both directions.

### 4.4 Dispute lifecycle

```
reviewer                  BiosafetyCourt                governance
   │                            │                           │
   │── raiseDispute(tokenId) ──▶│                           │
   │                            │   bond locked, case opened│
   │                            │                           │
   │                            │◀── resolveDispute(case,   │
   │                            │     UpheldTakedown)       │
   │                            │                           │
   │                            │── _setFreezeActive(…) ┐   │
   │                            │                       │   │
   │◀─ DisputeResolved ─────────│◀──────────────────────┘   │
```

On a `Dismissed` outcome, the raiser's `DISPUTE_BOND` is slashed and split; on `Settled`, the bond is simply released. `UpheldTakedown` on an already-frozen tokenId preserves the existing freeze record.

---

## 5. Threat model summary

Non-exhaustive. The per-contract natspec in `contracts/src/*.sol` enumerates the complete set of invariants and hardening notes; three audit passes (H-severity findings closed, N-severity followups in PR #7) are on file.

1. **Compromised attester.** A malicious approved attester can sign for any `(canonicalHash, registrant)`. Mitigations: `ScreeningAttestations.localRevoke(uid)` (retroactive, per-attestation) and `revokeAttester(address)` (prospective, per-signer).
2. **Compromised oracle.** A malicious approved provenance oracle can fabricate attestations for any tokenId. Same dual mitigation: `localRevoke(recordHash)` and `setOracleApproved(oracle, false)`.
3. **Registrant mempool replay.** `DesignRegistry.register` binds `registrant` to the attestation's `registrant` field; a front-runner cannot register a copy under a different account because the attestation was signed for the original.
4. **EIP-712 cross-chain / cross-contract replay.** Domain separator bakes in `block.chainid` and contract address; a signature for Base mainnet does not verify on Base Sepolia or any fork.
5. **Re-entrancy on payouts.** All ETH movement is CEI + `nonReentrant`. Recorded fuzz coverage on the `BiosafetyCourtReentrant` harness (5 tests, full pass).
6. **Safety Council overreach.** The council can freeze, but cannot extend past `FREEZE_RATIFY_WINDOW` without DAO ratification, and cannot override an existing council-frozen record via a subsequent `UpheldTakedown` resolution. The freeze itself auto-lifts on inaction.
7. **Royalty bypass.** EIP-2981 alone is bypassable; the v4 hook is not — pools that install the router as hook cannot route around it without failing the v4 permission check at deploy time.
8. **Upgrade safety (UUPS contracts).** `__gap` reservations on `LicenseRegistry` and `BiosafetyCourt`. `_authorizeUpgrade` is `onlyOwner`. Gap sizes documented alongside the storage layout.

**What the protocol does NOT defend against.** Collusion between a super-majority of the approved-attester set and a super-majority of governance. That collapses the biosafety gate entirely — it is a social / structural problem, not a cryptographic one. The mitigation is attester-set diversity plus the Safety Council's authority to freeze independently of governance.

---

## 6. Future work (v2)

Each of these is deliberately out of scope for v1, called out so the v1 posture is honest about what it does not do.

1. **Proof-of-synthesis oracle.** v1 ships with signed synthesis receipts (Twist / IDT / Ansa APIs bridged via a Seqora-run signer) recorded as `WetLabAttestation` records — trust-minimized but not trustless. v2 targets Nanopore TEE attestation with DNA-watermarking, which lets the oracle bind a receipt to an actual synthesized molecule in a way a rogue signer cannot fake.
2. **ZK-screening.** v1 screening is a signed attestation; the screener sees the sequence. v2 will implement Icefish-style zkSNARK circuits (IACR ePrint 2026/463 line of work) so sequences can be screened without being disclosed to the screener.
3. **Cross-chain IP-NFT portability.** Superchain bridges for OP-stack chains; LayerZero / CCIP for off-Superchain portability (Ethereum, Solana, Story).
4. **BioAgent API.** Paid query surface for AI agents that want authoritative provenance on a design or a license validity check without running their own indexer.
5. **LabDAO PLEX integration.** Content-addressed compute attestation bound to a tokenId.
6. **Fractionalization via Molecule IPT wrapping.** Evaluated for v1; deferred pending legal wrapper alignment.

---

## 7. References

### Standards implemented or consumed

- **SBOL3** (Synthetic Biology Open Language v3.0.1) — canonical design serialization.
- **URDNA2015** — RDF dataset canonicalization; input to the `tokenId` hash.
- **GA4GH VRS seqhash** — canonical sequence digest.
- **ERC-1155** — multi-token standard for `DesignRegistry`.
- **ERC-721** — single-token standard for License Tokens.
- **EIP-712** — typed structured data signing (ModelCard, WetLabAttestation).
- **EIP-2981** — NFT royalty standard (off-chain lookup mode).
- **ERC-1822 / UUPS** — upgrade pattern for `LicenseRegistry`, `BiosafetyCourt`.
- **ERC-7201** — namespaced storage for UUPS-safe storage layout.
- **Uniswap v4 `IHooks`** — swap-time royalty enforcement.
- **Ethereum Attestation Service** — screening attestation substrate.

### Adjacent protocols

- **Story Protocol PIL** — licensing semantics ported natively to Base.
- **0xSplits** — per-tokenId royalty recipient contracts.
- **Kleros** — slashable-bond reviewer model.

---

## 8. Deployment

v1 is live on **Base mainnet**. Contract addresses are tracked in `frontend/src/components/ContractCards.tsx` and on the protocol website. The build system is [Foundry](https://book.getfoundry.sh); tests run under `forge test` (517 tests, all pass). Coverage for the three UUPS / most-sensitive contracts:

| Contract | Lines | Branches | Funcs |
|---|---|---|---|
| `BiosafetyCourt` | 96.06% | 98.08% | 100% |
| `ProvenanceRegistry` | 97.50% | 100% | 100% |
| `RoyaltyRouter` | 91.30% | 96.77% | 100% |

Source of truth is the contracts themselves. If this document and the code disagree, the code is right and this document is wrong.
