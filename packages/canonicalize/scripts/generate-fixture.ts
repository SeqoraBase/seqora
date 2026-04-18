/**
 * Generate the canonical-hash fixture consumed by contracts/test/CanonicalHashFixture.t.sol.
 *
 * Input: the RDF/Turtle fixtures under packages/canonicalize/test/fixtures/.
 * Output: contracts/test/fixtures/canonical-hash.json containing one entry per fixture:
 *   {
 *     "name": string,           // human-readable id
 *     "file": string,            // fixture filename (for provenance)
 *     "format": "application/rdf+xml" | "text/turtle",
 *     "sbol": string,            // raw fixture contents
 *     "canonicalNQuads": string, // URDNA2015 output (informational)
 *     "expectedCanonicalHash": "0x..." // keccak256(URDNA2015(sbol))
 *   }
 *
 * The Foundry test loads this file and asserts uint256(expectedCanonicalHash) is the
 * tokenId a DesignRegistry.register call would produce for that canonicalHash.
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";
import { canonicalizeSbol, type SerializationFormat } from "../src/canonicalize.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURES_DIR = resolve(__dirname, "..", "test", "fixtures");
const OUTPUT_PATH = resolve(
  __dirname,
  "..",
  "..",
  "..",
  "contracts",
  "test",
  "fixtures",
  "canonical-hash.json",
);

interface FixtureSpec {
  name: string;
  file: string;
  format: SerializationFormat;
}

const SPECS: readonly FixtureSpec[] = [
  { name: "minimal-rdfxml", file: "minimal.rdf", format: "application/rdf+xml" },
  { name: "minimal-turtle", file: "minimal.ttl", format: "text/turtle" },
];

interface FixtureEntry {
  name: string;
  file: string;
  format: SerializationFormat;
  sbol: string;
  canonicalNQuads: string;
  tripleCount: number;
  expectedCanonicalHash: `0x${string}`;
  expectedTokenId: string;
}

async function main(): Promise<void> {
  const entries: FixtureEntry[] = [];
  for (const spec of SPECS) {
    const path = join(FIXTURES_DIR, spec.file);
    const sbol = readFileSync(path, "utf8");
    const { canonicalHash, tokenId, canonicalNQuads, tripleCount } = await canonicalizeSbol(
      sbol,
      spec.format,
    );
    entries.push({
      name: spec.name,
      file: spec.file,
      format: spec.format,
      sbol,
      canonicalNQuads,
      tripleCount,
      expectedCanonicalHash: canonicalHash,
      expectedTokenId: tokenId.toString(),
    });
  }

  mkdirSync(dirname(OUTPUT_PATH), { recursive: true });
  // We emit two parallel top-level arrays (`expectedCanonicalHashes`,
  // `expectedTokenIds`) alongside the rich `entries` list because Foundry's
  // JSON cheatcode parser does not support the JSONPath `[*]` wildcard — it
  // can only read values at fixed paths. The flat arrays give the Solidity
  // fixture test a single-read path (`.expectedCanonicalHashes`) while
  // `entries` preserves per-fixture provenance for humans and for future
  // scripts.
  writeFileSync(
    OUTPUT_PATH,
    JSON.stringify(
      {
        version: 1,
        generator: "@seqora/canonicalize/scripts/generate-fixture.ts",
        expectedCanonicalHashes: entries.map((e) => e.expectedCanonicalHash),
        expectedTokenIds: entries.map((e) => e.expectedTokenId),
        entries,
      },
      null,
      2,
    ) + "\n",
  );

  process.stdout.write(`wrote ${entries.length} entries → ${OUTPUT_PATH}\n`);
  for (const e of entries) {
    process.stdout.write(`  ${e.name}: ${e.expectedCanonicalHash}\n`);
  }
}

main().catch((err: unknown) => {
  process.stderr.write(`fatal: ${err instanceof Error ? err.stack ?? err.message : String(err)}\n`);
  process.exit(1);
});
