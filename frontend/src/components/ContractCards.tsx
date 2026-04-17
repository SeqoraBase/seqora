import Link from "next/link";
import { Container } from "./Container";
import { contracts, getContractAddress, type ContractMeta } from "@/lib/contracts/meta";

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
          {contracts.map((c) => (
            <Card key={c.slug} contract={c} />
          ))}
        </ul>
      </Container>
    </section>
  );
}

function Card({ contract }: { contract: ContractMeta }) {
  const address = getContractAddress(contract.name);
  const short = `${address.slice(0, 6)}…${address.slice(-4)}`;
  const primitives = contract.keyFunctions.slice(0, 3).map((f) => f.sig.split("(")[0] + "()");

  return (
    <li className="group relative flex flex-col rounded-[var(--radius-lg)] border border-[color:var(--color-line)] bg-[color:var(--color-bg-raised)] p-7 transition-colors hover:border-[color:var(--color-line-strong)]">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h3 className="t-h3 font-[family-name:var(--font-mono)] text-[1rem] font-medium tracking-tight text-[color:var(--color-fg)]">
            {contract.name}
          </h3>
          <p className="mt-1 t-mono text-[0.72rem] tracking-wide text-[color:var(--color-fg-subtle)]">
            {contract.kind}
          </p>
        </div>
        <Link
          href={`https://basescan.org/address/${address}`}
          target="_blank"
          rel="noopener"
          className="inline-flex items-center gap-1 t-mono text-[0.72rem] text-[color:var(--color-fg-muted)] hover:text-[color:var(--color-accent)] transition-colors whitespace-nowrap"
          aria-label={`View ${contract.name} on Basescan`}
        >
          {short}
          <ExternalGlyph />
        </Link>
      </div>

      <p className="mt-5 text-[0.95rem] text-[color:var(--color-fg)] leading-relaxed">
        {contract.summary}
      </p>

      <div className="mt-5 flex flex-wrap gap-1.5">
        {primitives.map((p) => (
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
          href={`/contracts/${contract.slug}`}
          className="text-[color:var(--color-fg-muted)] hover:text-[color:var(--color-accent)] transition-colors inline-flex items-center gap-1"
        >
          Read contract
          <ArrowRight />
        </Link>
        <Link
          href={`https://github.com/SeqoraBase/seqora/blob/main/contracts/src/${contract.name}.sol`}
          target="_blank"
          rel="noopener"
          className="t-mono text-[0.72rem] text-[color:var(--color-fg-subtle)] hover:text-[color:var(--color-fg)] transition-colors"
        >
          src/{contract.name}.sol
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
