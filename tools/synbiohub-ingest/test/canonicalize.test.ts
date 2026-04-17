import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { canonicalizeSbol } from "../src/canonicalize.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixture = (name: string) => readFileSync(join(__dirname, "fixtures", name), "utf8");

describe("canonicalizeSbol", () => {
  it("produces a deterministic canonicalHash across repeated calls", async () => {
    const rdf = fixture("minimal.rdf");
    const a = await canonicalizeSbol(rdf, "application/rdf+xml");
    const b = await canonicalizeSbol(rdf, "application/rdf+xml");
    const c = await canonicalizeSbol(rdf, "application/rdf+xml");
    expect(a.canonicalHash).toBe(b.canonicalHash);
    expect(b.canonicalHash).toBe(c.canonicalHash);
    expect(a.canonicalHash).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it("derives tokenId = uint256(canonicalHash)", async () => {
    const rdf = fixture("minimal.rdf");
    const r = await canonicalizeSbol(rdf, "application/rdf+xml");
    const expected = BigInt(r.canonicalHash);
    expect(r.tokenId).toBe(expected);
    expect(r.tokenId).toBeGreaterThan(0n);
    expect(r.tokenId).toBeLessThan(2n ** 256n);
  });

  it("ignores XML attribute ordering via RDF canonicalization", async () => {
    const rdf = fixture("minimal.rdf");
    // Re-serialize with attributes in a different order; URDNA2015 works over the
    // parsed quad set, not the source bytes, so the hash must be identical.
    const shuffled = rdf.replace(
      'xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"\n         xmlns:sbol="http://sbols.org/v3#"',
      'xmlns:sbol="http://sbols.org/v3#"\n         xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"',
    );
    const a = await canonicalizeSbol(rdf, "application/rdf+xml");
    const b = await canonicalizeSbol(shuffled, "application/rdf+xml");
    expect(a.canonicalHash).toBe(b.canonicalHash);
  });

  it("produces identical canonicalHash from RDF/XML vs Turtle of the same graph", async () => {
    const rdf = fixture("minimal.rdf");
    const ttl = fixture("minimal.ttl");
    const fromRdf = await canonicalizeSbol(rdf, "application/rdf+xml");
    const fromTtl = await canonicalizeSbol(ttl, "text/turtle");
    expect(fromRdf.canonicalHash).toBe(fromTtl.canonicalHash);
    expect(fromRdf.tripleCount).toBe(fromTtl.tripleCount);
  });

  it("rejects empty input", async () => {
    await expect(canonicalizeSbol("", "text/turtle")).rejects.toThrow(/empty|no triples/i);
  });

  it("distinguishes two different parts with different hashes", async () => {
    const rdf = fixture("minimal.rdf");
    const mutated = rdf.replace(
      "ATGCGTAAAGGAGAAGAACTTTTCACTGGAGTTGTCCCAATTCTTGTT",
      "CGTAAAGGAGAAGAACTTTTCACTGGAGTTGTCCCAATTCTTGTTGCT",
    );
    const a = await canonicalizeSbol(rdf, "application/rdf+xml");
    const b = await canonicalizeSbol(mutated, "application/rdf+xml");
    expect(a.canonicalHash).not.toBe(b.canonicalHash);
  });
});
