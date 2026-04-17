import Link from "next/link";
import { Container } from "./Container";

const links = [
  { href: "/#problem", label: "Problem" },
  { href: "/#architecture", label: "Architecture" },
  { href: "/#contracts", label: "Contracts" },
  { href: "/#proof", label: "Proof" },
];

export default function Navbar() {
  return (
    <header className="sticky top-0 z-40 backdrop-blur-md bg-[color:var(--color-bg)]/72 border-b border-[color:var(--color-line)]">
      <Container width="wide" className="flex h-14 items-center justify-between">
        <Link
          href="/"
          className="flex items-center gap-2 text-[color:var(--color-fg)]"
          aria-label="Seqora — home"
        >
          <LogoMark />
          <span className="font-[family-name:var(--font-serif)] text-[1.05rem] tracking-tight">
            Seqora
          </span>
        </Link>

        <nav className="hidden md:flex items-center gap-7 text-[0.875rem] text-[color:var(--color-fg-muted)]">
          {links.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              className="hover:text-[color:var(--color-fg)] transition-colors"
            >
              {l.label}
            </Link>
          ))}
        </nav>

        <div className="flex items-center gap-3">
          <Link
            href="https://github.com/SeqoraBase/seqora"
            target="_blank"
            rel="noopener"
            className="hidden sm:inline-flex items-center gap-1.5 text-[0.8rem] text-[color:var(--color-fg-muted)] hover:text-[color:var(--color-fg)] px-1 py-1"
            aria-label="GitHub"
          >
            <GithubGlyph />
            <span>GitHub</span>
          </Link>
          <div className="hidden md:block text-[0.8rem]">
            <appkit-button />
          </div>
          <Link
            href="/spec"
            className="inline-flex items-center text-[0.875rem] px-3.5 py-1.5 rounded-[var(--radius-md)] bg-[color:var(--color-fg)] text-[color:var(--color-fg-inverse)] hover:bg-[color:var(--color-accent)] transition-colors"
          >
            Read the spec
          </Link>
        </div>
      </Container>
    </header>
  );
}

function LogoMark() {
  return (
    <svg
      width="22"
      height="22"
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden
      className="text-[color:var(--color-accent)]"
    >
      <path
        d="M4 4C9 4 9 20 14 20M10 4C15 4 15 20 20 20"
        stroke="currentColor"
        strokeWidth="1.75"
        strokeLinecap="round"
      />
      <path
        d="M5 8H9M5 16H9M15 8H19M15 16H19"
        stroke="currentColor"
        strokeWidth="1.75"
        strokeLinecap="round"
        opacity="0.55"
      />
    </svg>
  );
}

function GithubGlyph() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M12 .5C5.65.5.5 5.65.5 12a11.5 11.5 0 0 0 7.86 10.92c.58.1.79-.25.79-.56v-2c-3.2.7-3.88-1.38-3.88-1.38-.52-1.33-1.28-1.68-1.28-1.68-1.05-.72.08-.7.08-.7 1.16.08 1.77 1.2 1.77 1.2 1.03 1.77 2.7 1.26 3.36.96.1-.75.4-1.26.73-1.55-2.55-.29-5.23-1.28-5.23-5.7 0-1.26.45-2.29 1.19-3.1-.12-.3-.52-1.48.11-3.08 0 0 .97-.31 3.18 1.18a11 11 0 0 1 5.8 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.6.23 2.78.11 3.08.74.81 1.19 1.84 1.19 3.1 0 4.43-2.69 5.4-5.25 5.69.41.36.78 1.07.78 2.16v3.2c0 .31.21.67.8.56A11.5 11.5 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5Z" />
    </svg>
  );
}
