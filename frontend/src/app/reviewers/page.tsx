import Link from "next/link";
import type { Metadata } from "next";
import Navbar from "@/components/Navbar";
import Footer from "@/components/Footer";
import { Container } from "@/components/Container";

export const metadata: Metadata = {
  title: "Reviewers",
  description:
    "Stake as a reviewer on the BiosafetyCourt. Raise disputes against flagged designs, earn cuts on dismissals, slash bad actors.",
};

export default function ReviewersPage() {
  return (
    <>
      <Navbar />
      <main className="flex-1">
        <section className="pt-16 md:pt-24 pb-20">
          <Container width="default">
            <nav className="t-mono text-[0.72rem] text-[color:var(--color-fg-subtle)]">
              <Link href="/" className="hover:text-[color:var(--color-fg)] transition-colors">
                ← Home
              </Link>
            </nav>

            <header className="mt-10 max-w-[62ch]">
              <span className="t-eyebrow">BiosafetyCourt</span>
              <h1 className="t-h1 mt-4 text-balance">
                Reviewers keep the registry honest.
              </h1>
              <p className="t-lead mt-5">
                Seqora&rsquo;s biosafety gate is not a committee decision — it is a
                Kleros-style market. Reviewers post a stake, raise disputes against
                designs they believe violate screening, and earn a cut when their
                challenge is upheld. Frivolous disputes slash the raiser.
              </p>
            </header>

            <div className="mt-16 grid grid-cols-1 gap-10 md:grid-cols-2 max-w-4xl">
              <Panel
                eyebrow="Who"
                title="Qualified reviewers"
                body="Biosecurity, IP, and synthetic-biology practitioners. v1 has no formal allowlist — anyone meeting the stake threshold can raise a dispute, and governance acts as arbitrator. v2 moves to a stake-weighted vote among approved reviewers."
              />
              <Panel
                eyebrow="Requirements"
                title="1 ETH minimum stake"
                body="Staked via receive() + stakeAsReviewer(). Each open dispute locks DISPUTE_BOND = 0.5 ETH against your stake. You cannot unstake while any bond is locked."
              />
              <Panel
                eyebrow="Upside"
                title="Earn on dismissals"
                body="On a Dismissed outcome, the raiser's 0.5 ETH bond is split 70/30 between the treasury and the resolving reviewer. UpheldTakedown releases your bond and freezes the flagged tokenId pending DAO ratification."
              />
              <Panel
                eyebrow="Downside"
                title="Frivolous disputes slash"
                body="If your dispute is dismissed, your 0.5 ETH bond is forfeit. There is no appeal. Stake only what you are willing to forfeit on a misjudged case."
              />
            </div>

            <section className="mt-20 max-w-[72ch]">
              <h2 className="t-eyebrow">How the lifecycle works</h2>
              <ol className="mt-6 space-y-5 text-[0.95rem] text-[color:var(--color-fg)] leading-relaxed list-none counter-reset-[step]">
                <Step n={1} title="Stake">
                  Send ETH to BiosafetyCourt; call{" "}
                  <code className="t-mono text-[0.85em]">stakeAsReviewer(amount)</code> to
                  promote the deposit to a bond. Minimum 1 ETH.
                </Step>
                <Step n={2} title="Raise">
                  <code className="t-mono text-[0.85em]">raiseDispute(tokenId, reason)</code>{" "}
                  opens a case and locks 0.5 ETH from your bond. Only one open dispute per
                  tokenId at a time.
                </Step>
                <Step n={3} title="Review window">
                  Governance (arbitrator in v1) resolves the case after{" "}
                  <code className="t-mono text-[0.85em]">MIN_DISPUTE_REVIEW_WINDOW</code>{" "}
                  has elapsed. Outcomes: UpheldTakedown, Dismissed, Settled.
                </Step>
                <Step n={4} title="Settle">
                  Uphold → bond released, tokenId frozen (or existing freeze preserved).
                  Dismissed → bond slashed, treasury + resolving reviewer paid. Settled →
                  bond released, no movement.
                </Step>
              </ol>
            </section>

            <section className="mt-20 max-w-[62ch]">
              <h2 className="t-eyebrow">Early-reviewer programme</h2>
              <p className="t-lead mt-5">
                We are onboarding the first cohort of reviewers ahead of the public court
                opening. If you have a biosecurity, synbio, or IP-law background and want
                to be part of the v1 launch set, reach out.
              </p>
              <div className="mt-8 flex flex-wrap items-center gap-3">
                <Link
                  href="mailto:reviewers@seqorabase.com?subject=Reviewer%20application"
                  className="inline-flex items-center gap-2 text-[0.9rem] px-4 py-2.5 rounded-[var(--radius-md)] bg-[color:var(--color-fg)] text-[color:var(--color-fg-inverse)] hover:bg-[color:var(--color-accent)] transition-colors"
                >
                  Apply via email
                  <ArrowRight />
                </Link>
                <Link
                  href="/contracts/biosafety-court"
                  className="inline-flex items-center gap-2 text-[0.9rem] px-4 py-2.5 rounded-[var(--radius-md)] border border-[color:var(--color-line-strong)] text-[color:var(--color-fg)] hover:border-[color:var(--color-fg-muted)] transition-colors"
                >
                  Read the BiosafetyCourt contract
                </Link>
              </div>
            </section>
          </Container>
        </section>
      </main>
      <Footer />
    </>
  );
}

function Panel({
  eyebrow,
  title,
  body,
}: {
  eyebrow: string;
  title: string;
  body: string;
}) {
  return (
    <div className="rounded-[var(--radius-lg)] border border-[color:var(--color-line)] bg-[color:var(--color-bg-raised)] p-7">
      <span className="t-eyebrow">{eyebrow}</span>
      <h3 className="t-h3 mt-3 text-[1.05rem] text-[color:var(--color-fg)]">{title}</h3>
      <p className="mt-3 text-[0.9rem] text-[color:var(--color-fg-muted)] leading-relaxed">
        {body}
      </p>
    </div>
  );
}

function Step({
  n,
  title,
  children,
}: {
  n: number;
  title: string;
  children: React.ReactNode;
}) {
  return (
    <li className="flex gap-5">
      <span
        aria-hidden
        className="flex-none h-8 w-8 rounded-full border border-[color:var(--color-line-strong)] flex items-center justify-center t-mono text-[0.78rem] text-[color:var(--color-fg-muted)]"
      >
        {n}
      </span>
      <div>
        <h4 className="t-mono text-[0.8rem] text-[color:var(--color-fg)]">{title}</h4>
        <p className="mt-1 text-[color:var(--color-fg-muted)]">{children}</p>
      </div>
    </li>
  );
}

function ArrowRight() {
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
