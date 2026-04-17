import Link from "next/link";
import { Container } from "./Container";

export default function Hero() {
  return (
    <section className="relative pt-24 md:pt-32 pb-20 md:pb-28">
      <Container width="wide">
        <div className="grid grid-cols-1 lg:grid-cols-[minmax(0,1.05fr)_minmax(0,1fr)] gap-10 lg:gap-16 items-center">
          <div>
            <span className="t-eyebrow">v1 · Base mainnet · 517 tests passing</span>

            <h1 className="t-display mt-5 text-[color:var(--color-fg)] text-balance">
              A registry for the{" "}
              <em className="not-italic text-[color:var(--color-accent)]">
                designed genome
              </em>
              .
            </h1>

            <p className="t-lead mt-6">
              Seqora tokenizes SBOL3 designs as content-addressed ERC-1155s, attaches
              enforceable licenses, and routes royalties at the point of swap — so every
              fork, every grant, every payment is provable on-chain.
            </p>

            <div className="mt-9 flex flex-wrap items-center gap-3">
              <Link
                href="/spec"
                className="inline-flex items-center gap-2 text-[0.9rem] px-4 py-2.5 rounded-[var(--radius-md)] bg-[color:var(--color-fg)] text-[color:var(--color-fg-inverse)] hover:bg-[color:var(--color-accent)] transition-colors"
              >
                Read the spec
                <Arrow />
              </Link>
              <Link
                href="/reviewers"
                className="inline-flex items-center gap-2 text-[0.9rem] px-4 py-2.5 rounded-[var(--radius-md)] border border-[color:var(--color-line-strong)] text-[color:var(--color-fg)] hover:border-[color:var(--color-fg-muted)] transition-colors"
              >
                Apply as a reviewer
              </Link>
              <Link
                href="#contracts"
                className="text-[0.9rem] px-2 py-2.5 text-[color:var(--color-fg-muted)] hover:text-[color:var(--color-fg)] transition-colors"
              >
                See the contracts ↓
              </Link>
            </div>

            <dl className="mt-14 grid grid-cols-3 gap-6 max-w-lg">
              <Stat term="Designs" definition="Content-addressed" />
              <Stat term="Licenses" definition="Story-PIL native" />
              <Stat term="Royalties" definition="Uniswap v4 hook" />
            </dl>
          </div>

          <HeroVisualPlaceholder />
        </div>
      </Container>
    </section>
  );
}

function Stat({ term, definition }: { term: string; definition: string }) {
  return (
    <div className="border-l border-[color:var(--color-line)] pl-4">
      <dt className="t-eyebrow">{term}</dt>
      <dd className="mt-2 text-[0.9rem] text-[color:var(--color-fg)]">{definition}</dd>
    </div>
  );
}

function Arrow() {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden>
      <path
        d="M2.5 7h9m0 0L7.5 3m4 4L7.5 11"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function HeroVisualPlaceholder() {
  return (
    <div
      aria-hidden
      className="relative aspect-[4/5] max-h-[560px] w-full overflow-hidden rounded-[var(--radius-lg)] border border-[color:var(--color-line)] bg-[color:var(--color-bg-raised)] noise"
    >
      <div
        className="absolute inset-0 opacity-60"
        style={{
          background:
            "radial-gradient(80% 60% at 70% 30%, color-mix(in oklab, var(--color-accent) 20%, transparent), transparent 70%)",
        }}
      />
      <svg
        viewBox="0 0 400 500"
        className="relative h-full w-full text-[color:var(--color-fg-muted)]"
        aria-hidden
      >
        <defs>
          <linearGradient id="strand" x1="0" x2="1" y1="0" y2="1">
            <stop offset="0" stopColor="var(--color-accent)" stopOpacity="0.9" />
            <stop offset="1" stopColor="var(--color-fg-muted)" stopOpacity="0.35" />
          </linearGradient>
        </defs>
        {/* Simple double-helix placeholder — real WebGL helix is a later pass */}
        <g stroke="url(#strand)" strokeWidth="1.4" fill="none" opacity="0.9">
          {Array.from({ length: 22 }).map((_, i) => {
            const y = 40 + i * 20;
            const phase = (i * Math.PI) / 4;
            const x1 = 200 + Math.sin(phase) * 90;
            const x2 = 200 - Math.sin(phase) * 90;
            return <line key={i} x1={x1} y1={y} x2={x2} y2={y} opacity={0.45} />;
          })}
        </g>
        <g fill="none" stroke="var(--color-accent)" strokeWidth="1.6">
          <path
            d="M110 20 C 290 120, 110 220, 290 320 S 110 480, 290 580"
            opacity="0.9"
          />
          <path
            d="M290 20 C 110 120, 290 220, 110 320 S 290 480, 110 580"
            opacity="0.55"
          />
        </g>
        <g fill="var(--color-fg-subtle)" fontSize="9" fontFamily="var(--font-mono)">
          <text x="28" y="470">0x8e80…1cad</text>
          <text x="260" y="38">keccak256(URDNA2015(SBOL3))</text>
        </g>
      </svg>
      <div className="pointer-events-none absolute inset-x-0 bottom-0 h-24 bg-gradient-to-t from-[color:var(--color-bg)] to-transparent" />
    </div>
  );
}
