import Link from "next/link";
import { notFound } from "next/navigation";
import type { Metadata } from "next";
import Navbar from "@/components/Navbar";
import Footer from "@/components/Footer";
import { Container } from "@/components/Container";
import { contracts, getContractAddress, getContractMeta } from "@/lib/contracts/meta";

export function generateStaticParams() {
  return contracts.map((c) => ({ slug: c.slug }));
}

export async function generateMetadata(
  props: PageProps<"/contracts/[slug]">
): Promise<Metadata> {
  const { slug } = await props.params;
  const contract = getContractMeta(slug);
  if (!contract) return { title: "Contract not found" };
  return {
    title: contract.name,
    description: `${contract.tagline} ${contract.summary}`,
  };
}

export default async function ContractPage(props: PageProps<"/contracts/[slug]">) {
  const { slug } = await props.params;
  const contract = getContractMeta(slug);
  if (!contract) notFound();

  const address = getContractAddress(contract.name);
  const idx = contracts.findIndex((c) => c.slug === contract.slug);
  const prev = idx > 0 ? contracts[idx - 1] : null;
  const next = idx < contracts.length - 1 ? contracts[idx + 1] : null;

  return (
    <>
      <Navbar />
      <main className="flex-1">
        <article className="pt-16 md:pt-24 pb-24">
          <Container width="default">
            <nav className="t-mono text-[0.72rem] text-[color:var(--color-fg-subtle)]">
              <Link href="/#contracts" className="hover:text-[color:var(--color-fg)] transition-colors">
                ← All contracts
              </Link>
            </nav>

            <header className="mt-10 max-w-[62ch]">
              <span className="t-mono text-[0.72rem] tracking-wide text-[color:var(--color-fg-subtle)]">
                {contract.kind}
              </span>
              <h1 className="t-h1 mt-3 font-[family-name:var(--font-mono)] tracking-tight">
                {contract.name}
              </h1>
              <p className="t-lead mt-4 text-[color:var(--color-fg-muted)]">
                {contract.tagline}
              </p>
            </header>

            <dl className="mt-10 grid grid-cols-1 gap-5 sm:grid-cols-3 max-w-3xl">
              <MetaRow label="Address">
                <Link
                  href={`https://basescan.org/address/${address}`}
                  target="_blank"
                  rel="noopener"
                  className="t-mono text-[0.78rem] break-all hover:text-[color:var(--color-accent)] transition-colors"
                >
                  {address}
                </Link>
              </MetaRow>
              <MetaRow label="Network">
                <span className="t-mono text-[0.78rem]">Base mainnet</span>
              </MetaRow>
              <MetaRow label="Source">
                <Link
                  href={`https://github.com/SeqoraBase/seqora/blob/main/contracts/src/${contract.name}.sol`}
                  target="_blank"
                  rel="noopener"
                  className="t-mono text-[0.78rem] hover:text-[color:var(--color-accent)] transition-colors"
                >
                  src/{contract.name}.sol
                </Link>
              </MetaRow>
            </dl>

            <section className="mt-16 max-w-[72ch]">
              <h2 className="t-eyebrow">Summary</h2>
              <p className="mt-4 text-[1rem] text-[color:var(--color-fg)] leading-relaxed">
                {contract.summary}
              </p>
              <p className="mt-5 text-[0.95rem] text-[color:var(--color-fg-muted)] leading-relaxed">
                {contract.detail}
              </p>
            </section>

            <section className="mt-16">
              <h2 className="t-eyebrow">Key functions</h2>
              <ul className="mt-5 space-y-4">
                {contract.keyFunctions.map((f) => (
                  <li
                    key={f.sig}
                    className="rounded-[var(--radius-md)] border border-[color:var(--color-line)] bg-[color:var(--color-bg-raised)] p-5"
                  >
                    <code className="t-mono text-[0.8rem] text-[color:var(--color-fg)] break-all">
                      {f.sig}
                    </code>
                    <p className="mt-2 text-[0.88rem] text-[color:var(--color-fg-muted)] leading-relaxed">
                      {f.doc}
                    </p>
                  </li>
                ))}
              </ul>
            </section>

            <section className="mt-16 max-w-[72ch]">
              <h2 className="t-eyebrow">Invariants</h2>
              <ul className="mt-5 space-y-3 text-[0.95rem] text-[color:var(--color-fg)] leading-relaxed">
                {contract.invariants.map((inv) => (
                  <li key={inv} className="flex gap-3">
                    <span
                      aria-hidden
                      className="mt-[0.55rem] h-[5px] w-[5px] flex-none rounded-full bg-[color:var(--color-accent)]"
                    />
                    <span>{inv}</span>
                  </li>
                ))}
              </ul>
            </section>

            <section className="mt-16 max-w-[72ch]">
              <h2 className="t-eyebrow">Upgradeability</h2>
              <p className="mt-4 text-[0.95rem] text-[color:var(--color-fg-muted)] leading-relaxed">
                {contract.upgradeability}
              </p>
            </section>

            <nav className="mt-20 pt-8 border-t border-[color:var(--color-line)] flex items-center justify-between text-[0.85rem]">
              {prev ? (
                <Link
                  href={`/contracts/${prev.slug}`}
                  className="inline-flex flex-col text-[color:var(--color-fg-muted)] hover:text-[color:var(--color-fg)] transition-colors"
                >
                  <span className="t-eyebrow text-[0.68rem]">Previous</span>
                  <span className="mt-1 t-mono">{prev.name}</span>
                </Link>
              ) : (
                <span />
              )}
              {next ? (
                <Link
                  href={`/contracts/${next.slug}`}
                  className="inline-flex flex-col items-end text-[color:var(--color-fg-muted)] hover:text-[color:var(--color-fg)] transition-colors"
                >
                  <span className="t-eyebrow text-[0.68rem]">Next</span>
                  <span className="mt-1 t-mono">{next.name}</span>
                </Link>
              ) : (
                <span />
              )}
            </nav>
          </Container>
        </article>
      </main>
      <Footer />
    </>
  );
}

function MetaRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="border-l border-[color:var(--color-line)] pl-4">
      <dt className="t-eyebrow text-[0.65rem]">{label}</dt>
      <dd className="mt-2">{children}</dd>
    </div>
  );
}
