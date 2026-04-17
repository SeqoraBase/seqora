import Link from "next/link";
import { Container } from "./Container";

const cols: { title: string; links: { label: string; href: string; external?: boolean }[] }[] = [
  {
    title: "Protocol",
    links: [
      { label: "Spec", href: "/spec" },
      { label: "Contracts", href: "/#contracts" },
      { label: "Architecture", href: "/#architecture" },
      { label: "Proof", href: "/#proof" },
    ],
  },
  {
    title: "Build",
    links: [
      { label: "GitHub", href: "https://github.com/SeqoraBase/seqora", external: true },
      { label: "Register a design", href: "/register" },
      { label: "Browse registry", href: "/registry" },
      { label: "Reviewers", href: "/reviewers" },
    ],
  },
  {
    title: "Connect",
    links: [
      { label: "Discord", href: "#", external: true },
      { label: "X / Twitter", href: "#", external: true },
      { label: "Farcaster", href: "#", external: true },
      { label: "security@seqorabase.com", href: "mailto:security@seqorabase.com" },
    ],
  },
];

export default function Footer() {
  return (
    <footer className="mt-24 border-t border-[color:var(--color-line)]">
      <Container width="wide" className="py-16">
        <div className="grid grid-cols-2 gap-10 md:grid-cols-[1.2fr_repeat(3,1fr)] md:gap-12">
          <div>
            <div className="font-[family-name:var(--font-serif)] text-[1.25rem] tracking-tight">
              Seqora
            </div>
            <p className="mt-3 max-w-[38ch] text-[0.875rem] leading-relaxed text-[color:var(--color-fg-muted)]">
              SBOL-native, royalty-enforcing on-chain registry for engineered DNA designs.
            </p>
            <p className="mt-4 text-[0.75rem] t-mono text-[color:var(--color-fg-subtle)]">
              Built on Base · MIT licensed
            </p>
          </div>

          {cols.map((col) => (
            <div key={col.title}>
              <h4 className="t-eyebrow mb-4">{col.title}</h4>
              <ul className="space-y-2.5">
                {col.links.map((l) => (
                  <li key={l.label}>
                    <Link
                      href={l.href}
                      {...(l.external ? { target: "_blank", rel: "noopener" } : {})}
                      className="text-[0.875rem] text-[color:var(--color-fg-muted)] hover:text-[color:var(--color-fg)] transition-colors"
                    >
                      {l.label}
                    </Link>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        <div className="mt-14 pt-6 border-t border-[color:var(--color-line)] flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <p className="t-mono text-[0.72rem] text-[color:var(--color-fg-subtle)] tracking-wide">
            © 2026 Seqora · Not a licensed legal advisor. See SECURITY.md for disclosure policy.
          </p>
          <p className="t-mono text-[0.72rem] text-[color:var(--color-fg-subtle)] tracking-wide">
            v1 · Base mainnet
          </p>
        </div>
      </Container>
    </footer>
  );
}
