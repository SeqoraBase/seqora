import Link from "next/link";
import { Container } from "./Container";

type ContractCard = {
  slug: string;
  name: string;
  kind: string;
  address?: `0x${string}`;
  summary: string;
  detail: string;
  primitives: string[];
};

const addresses = {
  DesignRegistry: "0x8e8057b5dc94cec2155d0da07e6cc9231d851cad",
  ScreeningAttestations: "0x47612f007bcb1f640c9e8643c3990df9c7ce6dab",
  LicenseRegistry: "0x07323af159c3b2319c89b8dec7147df3eeb8115f",
  RoyaltyRouter: "0x22ca9ccc81ea63881021d643d1e9490d060e40c8",
  ProvenanceRegistry: "0xf687adfafa55299e84f4115be7ab97af25a08f20",
  BiosafetyCourt: "0x96f33aa188ac9148ed89e55d6798e2c58ae2207c",
} as const;

const cards: ContractCard[] = [
  {
    slug: "design-registry",
    name: "DesignRegistry",
    kind: "ERC-1155 · immutable",
    address: addresses.DesignRegistry,
    summary:
      "The canonical registration primitive. Tokenizes SBOL3 designs as content-addressed ERC-1155 tokens.",
    detail:
      "tokenId is derived from keccak256 over the URDNA2015-canonicalized SBOL3, so the same design always produces the same id — no matter who registers it. Once registered, a design is immutable; forks are tracked as first-class relationships.",
    primitives: ["register()", "forkRegister()", "parentsOf()"],
  },
  {
    slug: "screening-attestations",
    name: "ScreeningAttestations",
    kind: "Ownable2Step · EAS-backed",
    address: addresses.ScreeningAttestations,
    summary:
      "The biosafety gate. Every registration must carry a screening attestation issued by an approved attester against the Seqora schema.",
    detail:
      "A thin governance-curated wrapper around the Ethereum Attestation Service. Checks schema match, revocation state, expiry, and registrant binding in a single non-reverting view. Emergency-pausable; local revocation as defence-in-depth when EAS revocation lags.",
    primitives: ["isValid()", "registerAttester()", "localRevoke()"],
  },
  {
    slug: "license-registry",
    name: "LicenseRegistry",
    kind: "ERC-721 · UUPS upgradeable",
    address: addresses.LicenseRegistry,
    summary:
      "The licensing layer. Story-PIL semantics native on Base — a governance-curated template catalog, not per-tokenId wrappers.",
    detail:
      "Registrants (or governance) mint License Tokens to licensees against a selected template. Validity is a non-reverting view so downstream contracts fail cleanly. Pausing the registry never invalidates existing grants.",
    primitives: ["grantLicense()", "revokeLicense()", "checkLicenseValid()"],
  },
  {
    slug: "royalty-router",
    name: "RoyaltyRouter",
    kind: "IHooks (Uniswap v4) · EIP-2981",
    address: addresses.RoyaltyRouter,
    summary:
      "The payments hub. Three operating modes: off-chain 2981 lookup, direct push, and Uniswap v4 hook intercepting swaps at the pool.",
    detail:
      "A 3% protocol fee routes to the treasury; the remainder splits through a per-tokenId 0xSplits contract. The v4 hook path (beforeSwap / afterSwap) is what makes royalties enforceable at the point of exchange, not politely requested.",
    primitives: ["royaltyInfo()", "distribute()", "beforeSwap()"],
  },
  {
    slug: "provenance-registry",
    name: "ProvenanceRegistry",
    kind: "EIP-712 · immutable",
    address: addresses.ProvenanceRegistry,
    summary:
      "Append-only provenance log per design. Two record kinds: AI/ML ModelCards and governance-approved wet-lab attestations.",
    detail:
      "Only the 32-byte EIP-712 digest is stored on-chain; full payloads travel via calldata for cheap off-chain indexing. Oracle set is mutable by the Seqora multisig; individual records can be locally revoked without touching history.",
    primitives: ["recordModelCard()", "recordWetLabAttestation()", "revokeRecord()"],
  },
  {
    slug: "biosafety-court",
    name: "BiosafetyCourt",
    kind: "UUPS · Kleros-style",
    address: addresses.BiosafetyCourt,
    summary:
      "Disputes and emergency freezes. Slashable reviewer bonds plus a dual-key Safety Council path ratified by the DAO within 30 days.",
    detail:
      "Reviewers stake bonds to open cases; adverse outcomes slash. The Safety Council can immediately freeze a tokenId for up to 30 days while the DAO deliberates — if the DAO doesn't ratify, anyone can auto-lift the freeze.",
    primitives: ["raiseDispute()", "resolve()", "councilFreeze()"],
  },
];

export default function ContractCards() {
  return (
    <section id="contracts" className="py-24 md:py-32 border-t border-[color:var(--color-line)]">
      <Container width="wide">
        <header className="max-w-[62ch]">
          <span className="t-eyebrow">Six contracts</span>
          <h2 className="t-h1 mt-4 text-balance">
            The registry is six composable primitives, not a monolith.
          </h2>
          <p className="t-lead mt-5">
            Each contract does one thing. Registration is immutable. Licensing is
            upgradeable. Royalties are enforced by a hook, not trusted to a marketplace.
            Biosafety is governance-curated with a dispute path that slashes bad actors.
          </p>
        </header>

        <ul className="mt-14 grid grid-cols-1 gap-5 md:grid-cols-2">
          {cards.map((c) => (
            <Card key={c.slug} card={c} />
          ))}
        </ul>
      </Container>
    </section>
  );
}

function Card({ card }: { card: ContractCard }) {
  const short = card.address
    ? `${card.address.slice(0, 6)}…${card.address.slice(-4)}`
    : null;

  return (
    <li className="group relative flex flex-col rounded-[var(--radius-lg)] border border-[color:var(--color-line)] bg-[color:var(--color-bg-raised)] p-7 transition-colors hover:border-[color:var(--color-line-strong)]">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h3 className="t-h3 font-[family-name:var(--font-mono)] text-[1rem] font-medium tracking-tight text-[color:var(--color-fg)]">
            {card.name}
          </h3>
          <p className="mt-1 t-mono text-[0.72rem] tracking-wide text-[color:var(--color-fg-subtle)]">
            {card.kind}
          </p>
        </div>
        {short && (
          <Link
            href={`https://basescan.org/address/${card.address}`}
            target="_blank"
            rel="noopener"
            className="inline-flex items-center gap-1 t-mono text-[0.72rem] text-[color:var(--color-fg-muted)] hover:text-[color:var(--color-accent)] transition-colors whitespace-nowrap"
            aria-label={`View ${card.name} on Basescan`}
          >
            {short}
            <ExternalGlyph />
          </Link>
        )}
      </div>

      <p className="mt-5 text-[0.95rem] text-[color:var(--color-fg)] leading-relaxed">
        {card.summary}
      </p>
      <p className="mt-3 text-[0.875rem] text-[color:var(--color-fg-muted)] leading-relaxed">
        {card.detail}
      </p>

      <div className="mt-5 flex flex-wrap gap-1.5">
        {card.primitives.map((p) => (
          <code
            key={p}
            className="t-mono text-[0.72rem] px-2 py-1 rounded-[var(--radius-sm)] bg-[color:var(--color-bg)] border border-[color:var(--color-line)] text-[color:var(--color-fg-muted)]"
          >
            {p}
          </code>
        ))}
      </div>

      <div className="mt-6 pt-5 border-t border-[color:var(--color-line)] flex items-center justify-between text-[0.8rem]">
        <Link
          href={`/contracts/${card.slug}`}
          className="text-[color:var(--color-fg-muted)] hover:text-[color:var(--color-accent)] transition-colors inline-flex items-center gap-1"
        >
          Read contract
          <ArrowRight />
        </Link>
        <Link
          href={`https://github.com/SeqoraBase/seqora/blob/main/contracts/src/${card.name}.sol`}
          target="_blank"
          rel="noopener"
          className="t-mono text-[0.72rem] text-[color:var(--color-fg-subtle)] hover:text-[color:var(--color-fg)] transition-colors"
        >
          src/{card.name}.sol
        </Link>
      </div>
    </li>
  );
}

function ExternalGlyph() {
  return (
    <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden>
      <path
        d="M3.5 2h4v4M7.5 2 3 6.5M3 2.5v5h5"
        stroke="currentColor"
        strokeWidth="1"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function ArrowRight() {
  return (
    <svg width="11" height="11" viewBox="0 0 11 11" fill="none" aria-hidden>
      <path
        d="M2 5.5h7m0 0L6 2.5m3 3L6 8.5"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
