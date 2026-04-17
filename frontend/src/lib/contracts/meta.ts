import { base } from "wagmi/chains";
import { addresses } from "./addresses";

export type ContractMeta = {
  slug: string;
  name: keyof (typeof addresses)[typeof base.id];
  kind: string;
  tagline: string;
  summary: string;
  detail: string;
  keyFunctions: { sig: string; doc: string }[];
  invariants: string[];
  upgradeability: string;
};

export const contracts: ContractMeta[] = [
  {
    slug: "design-registry",
    name: "DesignRegistry",
    kind: "ERC-1155 · immutable",
    tagline: "The canonical registration primitive.",
    summary:
      "Tokenizes SBOL3 designs as content-addressed ERC-1155 tokens. tokenId is derived from keccak256 over the URDNA2015-canonicalized SBOL3, so the same design always produces the same id — no matter who registers it.",
    detail:
      "Registration is immutable. Forks are tracked as first-class relationships via parents[tokenId], with a hard cap of MAX_PARENTS = 16 per fork. The registry refuses to mint without a live screening attestation that binds the caller's registrant address, so mempool replays under a different account fail the screening check.",
    keyFunctions: [
      {
        sig: "register(registrant, canonicalHash, ga4ghSeqhash, arweaveTx, ceramicStreamId, royalty, attUID, parents)",
        doc: "Mints tokenId == uint256(canonicalHash) iff ScreeningAttestations.isValid(attUID, canonicalHash, registrant) returns true.",
      },
      {
        sig: "forkRegister(ForkParams)",
        doc: "Register a derivative design; records up to MAX_PARENTS parent tokenIds. Caller + attestation gating identical to register().",
      },
      {
        sig: "parentsOf(tokenId) view → uint256[]",
        doc: "Returns the parent tokenIds for a forked design, or an empty array for roots.",
      },
      {
        sig: "isRegistered(tokenId) view → bool",
        doc: "True iff the canonicalHash has already been minted. Idempotent per (design, network).",
      },
    ],
    invariants: [
      "tokenId == uint256(keccak256(URDNA2015(SBOL3))). Always.",
      "A tokenId can only be minted once per network.",
      "Screening attestation's registrant field must equal the mint target — no relayer spoofing.",
      "MAX_PARENTS = 16. Fork graphs are DAGs; cycles are impossible given hash-derived ids.",
    ],
    upgradeability:
      "None. No Ownable, no Pausable, no upgrade hooks. The screening contract is set once in the constructor. If screening semantics must change, deploy a fresh DesignRegistry — tokenIds remain stable because they are hash-derived.",
  },
  {
    slug: "screening-attestations",
    name: "ScreeningAttestations",
    kind: "Ownable2Step · EAS-backed",
    tagline: "The biosafety gate.",
    summary:
      "A governance-curated wrapper around the Ethereum Attestation Service. Every DesignRegistry listing must carry an attestation issued by an approved attester against the Seqora screening schema.",
    detail:
      "isValid is non-reverting — schema match, EAS revocation, local revocation, expiry, attester approval, canonicalHash field match, registrant field match, and pause state are checked in a single view. Defence-in-depth via localRevoke(uid) handles known-bad attestations when EAS-level revocation lags. v1 launch attester set is a small number of Seqora-operated relayer signers that wrap SecureDNA / IBBIS Common Mechanism JSON outputs, since those services do not yet emit EAS-native attestations.",
    keyFunctions: [
      {
        sig: "isValid(uid, canonicalHash, registrant) view → bool",
        doc: "Single non-reverting check consumed by DesignRegistry. False on any failure mode.",
      },
      {
        sig: "registerAttester(address, ScreenerKind)",
        doc: "Owner-only. Adds an approved screener to the active set.",
      },
      {
        sig: "revokeAttester(address)",
        doc: "Owner-only. Prospective revocation — already-minted designs are unaffected.",
      },
      {
        sig: "localRevoke(uid)",
        doc: "Owner-only, per-attestation retroactive blacklist. Bypassed by the EAS-native revocation path once it catches up.",
      },
    ],
    invariants: [
      "isValid never reverts — fail-closed with false so the registry surfaces a clean AttestationInvalid.",
      "Paused state returns isValid=false; no state is partially written during a pause.",
      "Schema UID and EAS address are set at construction; setters exist but are owner-gated.",
      "Attestation's registrant field must match the registrant arg — cross-account replay is blocked.",
    ],
    upgradeability:
      "None. v2 may deploy a fresh contract + coordinator if the schema evolves. EAS address has a setter to handle (unlikely) EAS redeployment.",
  },
  {
    slug: "license-registry",
    name: "LicenseRegistry",
    kind: "ERC-721 · UUPS upgradeable",
    tagline: "Story-PIL semantics native on Base.",
    summary:
      "Templates are a governance-curated catalog (SPDX-style), not per-tokenId wrappers. Registrants (or governance) mint ERC-721 License Tokens to licensees against a selected template.",
    detail:
      "checkLicenseValid is non-reverting so downstream contracts fail cleanly. Pausing the registry NEVER invalidates existing grants — only new grants / revocations are halted. The PIL bitfield carries PIL_COMMERCIAL, PIL_DERIVATIVE (requires PIL_ATTRIBUTION), PIL_ATTRIBUTION, PIL_EXCLUSIVE, PIL_TRANSFERABLE. At most one active PIL_EXCLUSIVE grant exists per tokenId across all licensees; non-exclusive templates permit multiple concurrent grants to the same licensee.",
    keyFunctions: [
      {
        sig: "grantLicense(tokenId, templateId, licensee, expiry, feePaid)",
        doc: "Mints a License Token. Callable by the tokenId's registrant (via DesignRegistry lookup) OR by owner/governance.",
      },
      {
        sig: "revokeLicense(licenseTokenId, reason)",
        doc: "Same auth set. Revocation is permanent — no un-revoke path.",
      },
      {
        sig: "checkLicenseValid(tokenId, user) view → bool",
        doc: "Non-reverting. False for expired, revoked, or missing grants; true as soon as any grant is valid.",
      },
      {
        sig: "registerLicenseTemplate(template)",
        doc: "Owner-only. Validates pilFlags ⊆ PIL_V1_MASK and boolean/flag agreement before accepting.",
      },
    ],
    invariants: [
      "Pausing halts new grants and revocations; existing valid grants remain valid.",
      "At most one active PIL_EXCLUSIVE grant per tokenId across all licensees.",
      "PIL_DERIVATIVE requires PIL_ATTRIBUTION. Validated at template register time.",
      "feePaid is recorded but not moved — RoyaltyRouter is the only surface that moves funds.",
    ],
    upgradeability:
      "UUPS. _authorizeUpgrade is onlyOwner. State lives in the proxy; implementation calls _disableInitializers() in the constructor. ERC-7201 namespaced storage + __gap reservation protect future appends.",
  },
  {
    slug: "royalty-router",
    name: "RoyaltyRouter",
    kind: "IHooks (Uniswap v4) · EIP-2981",
    tagline: "Payments hub with three operating modes.",
    summary:
      "Off-chain EIP-2981 lookup, direct push for non-swap flows, and a Uniswap v4 hook that intercepts swaps at the pool. A 3% protocol fee routes to the treasury; the remainder splits through a per-tokenId 0xSplits contract.",
    detail:
      "The v4 hook path is what makes royalties enforceable at the point of exchange rather than politely requested. The hook bills the input currency on both exactInput and exactOutput — the swapper always pays in the currency they are spending, which is the allowlisted side (USDC in v1). Hook permission encoding is enforced at construction via validateHookAddress; deploys with the wrong CREATE2 salt revert loudly.",
    keyFunctions: [
      {
        sig: "royaltyInfo(tokenId, salePrice) view → (address, uint256)",
        doc: "EIP-2981 interface. Marketplaces may honour or ignore this — soft enforcement only.",
      },
      {
        sig: "distribute(tokenId, currency, amount)",
        doc: "Direct push path. Pulls the input, takes the 3% protocol fee, forwards the remainder to the 0xSplits contract for tokenId.",
      },
      {
        sig: "beforeSwap(address, PoolKey, SwapParams, bytes) → (bytes4, BeforeSwapDelta, uint24)",
        doc: "v4 hook entry. Computes the royalty + protocol fee and encodes the delta into the specified/unspecified side appropriately.",
      },
      {
        sig: "afterSwap(address, PoolKey, SwapParams, BalanceDelta, bytes) → (bytes4, int128)",
        doc: "v4 hook exit. Calls PoolManager.take to settle the amount owed; distributes the proceeds to treasury + 0xSplits.",
      },
    ],
    invariants: [
      "Hook ALWAYS debits the currency the swapper is spending (the allowlisted side).",
      "Protocol fee = 3%. Flat, not configurable in v1.",
      "The IRoyaltyRouter.beforeSwap/afterSwap interface-shaped entrypoints are permanently disabled (revert HookMisconfigured) — the real v4 path is the canonical IHooks shape.",
      "validateHookAddress(this) reverts at construction on address/permission mismatch.",
    ],
    upgradeability:
      "Immutable. The v4 hook address encodes permissions in its trailing 14 bits — changing the router means redeploying to a new CREATE2 address. v2 replaces the instance; existing pools rebind.",
  },
  {
    slug: "provenance-registry",
    name: "ProvenanceRegistry",
    kind: "EIP-712 · immutable",
    tagline: "Append-only provenance log per design.",
    summary:
      "Two record kinds: AI/ML ModelCards (weights hash, prompt, seed, signed by the contributor) and governance-approved wet-lab attestations (signed by an approved oracle).",
    detail:
      "Only the 32-byte EIP-712 digest (recordHash) is stored on-chain; full payloads travel via calldata so off-chain indexers reconstruct from the transaction input. WetLabAttestation has its tokenId as the first signed field, closing cross-tokenId signature replay; ModelCards allow replay across derivative tokenIds by design, with per-tokenId dedup. Domain separator bakes in chainId + contract address — no cross-chain or cross-contract replay is possible.",
    keyFunctions: [
      {
        sig: "recordModelCard(tokenId, ModelCard, signature)",
        doc: "Verifies EIP-712 signature against modelCard.contributor. Dedup per (tokenId, recordHash).",
      },
      {
        sig: "recordWetLabAttestation(tokenId, WetLabAttestation, signature)",
        doc: "Verifies signature against attestation.oracle ∈ approved oracle set. tokenId field must equal the tokenId argument.",
      },
      {
        sig: "getProvenance(tokenId) view → ProvenanceRecord[]",
        doc: "Unpaginated; callers should prefer getRecordsByTokenId(tokenId, offset, limit) to avoid array-DoS.",
      },
      {
        sig: "localRevoke(recordHash)",
        doc: "Owner-only, retroactive invalidation of a specific record. History remains readable; validity view returns false.",
      },
    ],
    invariants: [
      "WetLabAttestation.tokenId (first signed field) must equal the tokenId argument — no cross-tokenId replay.",
      "ModelCard per-tokenId dedup via _seenRecord[tokenId][recordHash].",
      "Signature malleability closed by OZ ECDSA.recover (canonical s).",
      "Paused state halts new records; reads and governance continue.",
    ],
    upgradeability:
      "None. Oracle set and local revocations are owner-mutable; the contract itself is not upgradeable.",
  },
  {
    slug: "biosafety-court",
    name: "BiosafetyCourt",
    kind: "UUPS · Kleros-style",
    tagline: "Disputes and emergency freezes.",
    summary:
      "Slashable reviewer bonds plus a dual-key Safety Council path ratified by the DAO within 30 days — else the freeze auto-lifts.",
    detail:
      "Reviewers stake ≥ MIN_REVIEWER_STAKE (1 ETH) and lock DISPUTE_BOND (0.5 ETH) against each open dispute. Adverse outcomes slash. The Safety Council is a separate multisig from the DAO-governance owner and can immediately freeze a tokenId; governance has 30 days to ratify or reject, and after that window anyone can expireFreeze to auto-lift. Dispute resolution on an already-frozen tokenId preserves the existing freeze record — the council's appliedAt / expiresAt are NOT reset.",
    keyFunctions: [
      {
        sig: "stakeAsReviewer(bondAmount)",
        doc: "Consumes pendingDeposits (credited via receive()) to promote a deposit to a bond. bondAmount ≥ MIN_REVIEWER_STAKE.",
      },
      {
        sig: "raiseDispute(tokenId, reason)",
        doc: "Opens a case, locks DISPUTE_BOND from the reviewer's existing bond. One open dispute per tokenId at a time.",
      },
      {
        sig: "resolveDispute(caseId, outcome)",
        doc: "Governance-only in v1. UpheldTakedown freezes (or preserves existing freeze); Dismissed slashes the raiser; Settled releases the bond with no movement.",
      },
      {
        sig: "safetyCouncilFreeze(tokenId, reason) / ratifyFreeze / rejectFreeze / expireFreeze",
        doc: "Dual-key emergency flow. Council freezes, DAO ratifies or rejects, anyone can expireFreeze after FREEZE_RATIFY_WINDOW.",
      },
      {
        sig: "isFrozen(tokenId) view → (bool, uint64)",
        doc: "Lazy auto-lift: reads reflect true current state even if expireFreeze has not been called.",
      },
    ],
    invariants: [
      "At most one open dispute per tokenId. raiseDispute reverts if openDisputeOf[tokenId] != 0.",
      "Reviewer cannot exit while _disputeBondLocked[reviewer] > 0.",
      "UpheldTakedown on an already-frozen tokenId preserves the existing freeze record — no appliedAt / expiresAt reset.",
      "CEI + nonReentrant on all ETH-moving entry points.",
      "Safety Council ≠ DAO governance owner (address distinction enforced; signer separation is operational).",
    ],
    upgradeability:
      "UUPS. _authorizeUpgrade is onlyOwner. __gap reservation tracked alongside the storage layout; the packed uint128 accruals occupy a single slot.",
  },
];

export function getContractMeta(slug: string): ContractMeta | undefined {
  return contracts.find((c) => c.slug === slug);
}

export function getContractAddress(name: ContractMeta["name"]): `0x${string}` {
  return addresses[base.id][name];
}
