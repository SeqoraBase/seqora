# @seqora/synbiohub-ingest

One-way ingest from public SynBioHub instances into a Seqora pending-claim
manifest. Produces a deterministic `canonicalHash` and derived `tokenId`
for every part, so the resulting manifest can be consumed by the frontend
as a read-only preview until the original uploader claims their design
via the ORCID-linked wallet flow.

No on-chain writes. No partner gating. Safe to run against any public
SynBioHub endpoint.

## Usage

```
npm install
npm run build
npx seqora-synbiohub-ingest --instance https://synbiohub.org --limit 100 --out ./out/manifest.json
```

## What it does

1. Queries the SynBioHub SPARQL endpoint for public parts.
2. Fetches each part's SBOL3 RDF via `/sbol`.
3. Canonicalizes the RDF with URDNA2015 and computes
   `canonicalHash = keccak256(canonicalized N-Quads UTF-8)`.
4. Resolves author IRIs to ORCID identifiers where possible.
5. Writes a manifest of pending-claim records — one per part — to the
   output file. Re-runs are idempotent: the same part yields the same
   `canonicalHash` on every run.

## Tests

```
npm test
```

Fixture-based determinism test: re-canonicalizing the same SBOL payload
with shuffled triple order must produce the identical `canonicalHash`.

## Scope

This is the MVP slice of
`docs/integrations/synbiohub.md` (closed-core) §9. Out of scope here:
- preview web UI (lives in `frontend/`)
- on-chain mint relayer (depends on the signed claim flow)
- ORCID OAuth sign-in (claim-time, not ingest-time)
