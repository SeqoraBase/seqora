import { readFile } from "node:fs/promises";
import path from "node:path";
import Link from "next/link";
import type { Metadata } from "next";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import Navbar from "@/components/Navbar";
import Footer from "@/components/Footer";
import { Container } from "@/components/Container";

export const metadata: Metadata = {
  title: "Protocol specification",
  description:
    "The Seqora v1 protocol specification. Six contracts, canonical flows, license semantics, royalty flow, biosafety court, threat model.",
};

async function loadSpec(): Promise<string> {
  const file = path.resolve(process.cwd(), "src/content/spec.md");
  return readFile(file, "utf-8");
}

const components: Components = {
  h1: ({ children }) => (
    <h1 className="t-h1 mt-0 mb-6 text-balance">{children}</h1>
  ),
  h2: ({ children }) => (
    <h2 className="t-h2 mt-14 mb-4 scroll-mt-24">{children}</h2>
  ),
  h3: ({ children }) => (
    <h3 className="t-h3 mt-10 mb-3 text-[1.05rem] text-[color:var(--color-fg)]">
      {children}
    </h3>
  ),
  h4: ({ children }) => (
    <h4 className="mt-6 mb-2 t-mono text-[0.85rem] text-[color:var(--color-fg)]">
      {children}
    </h4>
  ),
  p: ({ children }) => (
    <p className="my-4 text-[0.95rem] leading-relaxed text-[color:var(--color-fg)]">
      {children}
    </p>
  ),
  em: ({ children }) => (
    <em className="not-italic text-[color:var(--color-fg-muted)]">{children}</em>
  ),
  strong: ({ children }) => (
    <strong className="font-medium text-[color:var(--color-fg)]">{children}</strong>
  ),
  a: ({ href, children }) => (
    <Link
      href={href ?? "#"}
      className="text-[color:var(--color-accent)] underline-offset-4 hover:underline"
      target={href?.startsWith("http") ? "_blank" : undefined}
      rel={href?.startsWith("http") ? "noopener" : undefined}
    >
      {children}
    </Link>
  ),
  ul: ({ children }) => (
    <ul className="my-4 ml-4 space-y-1.5 text-[0.95rem] leading-relaxed text-[color:var(--color-fg)] list-disc marker:text-[color:var(--color-fg-subtle)]">
      {children}
    </ul>
  ),
  ol: ({ children }) => (
    <ol className="my-4 ml-4 space-y-1.5 text-[0.95rem] leading-relaxed text-[color:var(--color-fg)] list-decimal marker:text-[color:var(--color-fg-subtle)]">
      {children}
    </ol>
  ),
  li: ({ children }) => <li className="pl-2">{children}</li>,
  code: ({ className, children }) => {
    const inline = !className?.startsWith("language-");
    if (inline) {
      return (
        <code className="t-mono text-[0.85em] px-1.5 py-0.5 rounded-[var(--radius-sm)] bg-[color:var(--color-bg-raised)] border border-[color:var(--color-line)] text-[color:var(--color-fg)]">
          {children}
        </code>
      );
    }
    return <code className="t-mono text-[0.82rem]">{children}</code>;
  },
  pre: ({ children }) => (
    <pre className="my-5 overflow-x-auto rounded-[var(--radius-md)] border border-[color:var(--color-line)] bg-[color:var(--color-bg-raised)] p-4 leading-[1.55]">
      {children}
    </pre>
  ),
  table: ({ children }) => (
    <div className="my-6 overflow-x-auto rounded-[var(--radius-md)] border border-[color:var(--color-line)]">
      <table className="w-full border-collapse text-[0.88rem]">{children}</table>
    </div>
  ),
  thead: ({ children }) => (
    <thead className="bg-[color:var(--color-bg-raised)] text-left">{children}</thead>
  ),
  th: ({ children }) => (
    <th className="px-4 py-2.5 t-eyebrow text-[0.68rem] border-b border-[color:var(--color-line)]">
      {children}
    </th>
  ),
  td: ({ children }) => (
    <td className="px-4 py-2.5 border-b border-[color:var(--color-line)] text-[color:var(--color-fg)] last:border-b-0">
      {children}
    </td>
  ),
  tr: ({ children }) => <tr className="[&:last-child_td]:border-b-0">{children}</tr>,
  hr: () => <hr className="my-14 border-[color:var(--color-line)]" />,
  blockquote: ({ children }) => (
    <blockquote className="my-5 border-l-2 border-[color:var(--color-accent)] pl-4 text-[color:var(--color-fg-muted)]">
      {children}
    </blockquote>
  ),
};

export default async function SpecPage() {
  const spec = await loadSpec();
  return (
    <>
      <Navbar />
      <main className="flex-1">
        <section className="pt-16 md:pt-24 pb-24">
          <Container width="prose">
            <nav className="t-mono text-[0.72rem] text-[color:var(--color-fg-subtle)]">
              <Link href="/" className="hover:text-[color:var(--color-fg)] transition-colors">
                ← Home
              </Link>
            </nav>

            <div className="mt-10">
              <ReactMarkdown remarkPlugins={[remarkGfm]} components={components}>
                {spec}
              </ReactMarkdown>
            </div>
          </Container>
        </section>
      </main>
      <Footer />
    </>
  );
}
