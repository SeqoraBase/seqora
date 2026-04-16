# Seqora — Project Context for Claude Code

**Working directory** for this project: `/Users/dennisgoslar/Projects/Seqora`. Always `cd` here before running Foundry, node, or agent commands.

## What Seqora is

SBOL-native, royalty-enforcing on-chain registry for engineered DNA designs. Target chain: **Base** (Coinbase L2). Native token placeholder: **$SEQ**. Canonical research and strategy live in `docs/plan.md`.

**Core thesis in one line:** the Addgene-scale design primitive that BIO/Molecule/LabDAO haven't built — because they optimized for capital, IP wrappers, and compute respectively.

## Repo layout

```
Seqora/
├── CLAUDE.md                    — this file; project-wide context for every Claude session
├── .claude/
│   ├── agents/*.md              — specialized subagents (research-scout, solidity-engineer, sec-auditor, tester, scaffolding, docs-writer)
│   └── settings.json            — permissions + hook config
├── .gitignore                   — ignores docs/ (private research) and build artifacts
├── docs/                        — GITIGNORED; private planning + research
│   ├── plan.md                  — master plan, do not rewrite without user approval
│   ├── agent-log.md             — inter-agent handoff journal; every agent appends here
│   └── research/                — research-scout dated reports
├── contracts/                   — Foundry project (Solidity)
│   ├── src/                     — production contracts
│   ├── test/                    — Foundry tests
│   ├── script/                  — deployment scripts
│   └── foundry.toml
└── frontend/                    — (future) Next.js + wagmi + Farcaster Mini App
```

## Architecture in one screen

**On-chain (Base):**
- `DesignRegistry` (ERC-1155) — tokenId = keccak256(URDNA2015-canonicalized SBOL3). Immutable per tokenId.
- `LicenseRegistry` — per-tokenId license pointer + fork parent graph (Story PIL semantics).
- `RoyaltyRouter` — EIP-2981 + 0xSplits; Uniswap v4 hook enforces cut at swap.
- `ScreeningAttestations` — EAS schema; attester set governed by DAO.
- `ProvenanceRegistry` — ModelCard schema + wet-lab oracle attestations.
- `BiosafetyCourt` — Kleros-style slashable reviewer bonds; 48h Safety Council takedown, 30-day DAO ratification.

**Off-chain:** Arweave (canonical SBOL), Filecoin (bulk raw data), Ceramic (mutable metadata), IPFS/Pinata (hot gateway).

## Rules of engagement for all agents

1. **Read `docs/plan.md` first.** It is canonical. Do not contradict it without explicit user approval — flag conflicts in `docs/agent-log.md` and pause.
2. **Log handoffs in `docs/agent-log.md`.** Append-only. Every agent invocation ends with a log entry: `## YYYY-MM-DD HH:MM — <agent-name> — <what was done>` followed by 3-10 bullets and a "Next up / blockers" line.
3. **Never commit secrets or `.env`.** Never commit `docs/` (gitignored) or `contracts/out/`, `contracts/cache/`, `node_modules/`, `.anvil/`.
4. **Opus for hard reasoning, Sonnet for bulk work.** Solidity-engineer and sec-auditor default to Opus. Research-scout, scaffolding, docs-writer default to Sonnet.
5. **Fail loud, don't fake it.** If a tool can't verify something (e.g., no live X API for research), say so in the log rather than fabricating.
6. **Respect the plan's v1/v2 split.** v1 ships: registration, storage pointers, licensing, attestation gate, royalty router, minimal DAO. v2: proof-of-synthesis, ZK-screening, AI BioAgent API. Don't scope-creep into v2 without approval.
7. **Ask the user only for genuine blockers.** Architectural tradeoffs that materially change the plan, legal/biosafety questions, tokenomics decisions. Everything else: make a judgment call, log it, proceed.

## Open questions (unresolved; user input needed to close)

Listed in `docs/plan.md` §9. Summary:
1. Wrap Molecule IPT or ship a new primitive?
2. Base-only or Base + Story Protocol bridge?
3. Fair launch vs VC-led vs hybrid?
4. AI-bio wedge vs academic-parts wedge?
5. Ship biosafety oracle v1 or defer to v2?

Current working assumptions (override with user input):
- Partner with Molecule on IPT at v1, plan independence for v2.
- Base primary, Story bridge at v2.
- Hybrid launch: BIO-style community auction + $6–8M strategic seed.
- Lead narrative with AI-bio, include academic parts.
- v1 biosafety = signed screening attestations only; proof-of-synthesis = v2.

## Quickstart for a fresh Claude session

```
cd /Users/dennisgoslar/Projects/Seqora
cat docs/plan.md                      # canonical plan
tail -80 docs/agent-log.md            # what just happened
ls .claude/agents/                    # available specialized agents
cd contracts && forge build           # verify build green
```
