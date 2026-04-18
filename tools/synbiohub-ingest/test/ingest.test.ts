import { describe, it, expect, vi } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ingest } from "../src/ingest.js";
import { mergeEntries } from "../src/manifest.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixture = readFileSync(join(__dirname, "fixtures", "minimal.rdf"), "utf8");

function mockSparqlResponse(bindings: Array<Record<string, { type: string; value: string }>>): Response {
  return new Response(JSON.stringify({ results: { bindings } }), { status: 200 });
}

describe("ingest (end-to-end with mocked network)", () => {
  it("produces pending-claim entries with stable canonicalHash", async () => {
    const fetchImpl = vi
      .fn<typeof fetch>()
      // SPARQL page 1
      .mockResolvedValueOnce(
        mockSparqlResponse([
          {
            subject: { type: "uri", value: "https://synbiohub.org/public/igem/BBa_E0040/1" },
            displayId: { type: "literal", value: "BBa_E0040" },
            title: { type: "literal", value: "GFP" },
            attributedTo: { type: "uri", value: "https://orcid.org/0000-0002-1825-0097" },
          },
        ]),
      )
      // SBOL fetch for the part
      .mockResolvedValueOnce(new Response(fixture, { status: 200 }))
      // SPARQL page 2 (empty → terminates)
      .mockResolvedValueOnce(mockSparqlResponse([]));

    const result = await ingest({
      instance: "https://synbiohub.org",
      pageSize: 1,
      requestDelayMs: 0,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(result.okCount).toBe(1);
    expect(result.errorCount).toBe(0);
    const entry = result.entries[0]!;
    expect(entry.status).toBe("pending");
    expect(entry.displayId).toBe("BBa_E0040");
    expect(entry.title).toBe("GFP");
    expect(entry.attributedTo).toBe("https://orcid.org/0000-0002-1825-0097");
    expect(entry.orcidId).toBe("0000-0002-1825-0097");
    expect(entry.canonicalHash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(BigInt(entry.tokenId)).toBe(BigInt(entry.canonicalHash));
    expect(entry.tripleCount).toBeGreaterThan(0);
  });

  it("records errors as error-status entries instead of aborting the run", async () => {
    const fetchImpl = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(
        mockSparqlResponse([
          { subject: { type: "uri", value: "https://synbiohub.org/public/igem/BAD/1" } },
          { subject: { type: "uri", value: "https://synbiohub.org/public/igem/OK/1" } },
        ]),
      )
      // BAD: SBOL fetch fails on every retry attempt.
      .mockResolvedValueOnce(new Response("oops", { status: 500, statusText: "err" }))
      .mockResolvedValueOnce(new Response("oops", { status: 500, statusText: "err" }))
      .mockResolvedValueOnce(new Response("oops", { status: 500, statusText: "err" }))
      // OK: SBOL fetch succeeds
      .mockResolvedValueOnce(new Response(fixture, { status: 200 }))
      // End of pagination
      .mockResolvedValueOnce(mockSparqlResponse([]));

    const result = await ingest({
      instance: "https://synbiohub.org",
      pageSize: 2,
      requestDelayMs: 0,
      retryBackoffMs: 0,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(result.entries).toHaveLength(2);
    expect(result.okCount).toBe(1);
    expect(result.errorCount).toBe(1);
    const bad = result.entries.find((e) => e.sourceUri.endsWith("BAD/1"))!;
    expect(bad.status).toBe("error");
    expect(bad.error).toMatch(/HTTP 500/);
  });
});

describe("mergeEntries (idempotent re-ingest)", () => {
  it("overwrites existing entries with the same sourceUri", () => {
    const prior = [
      {
        sourceUri: "https://s.org/p/A",
        sourceInstance: "https://s.org",
        canonicalHash: "0x" + "a".repeat(64),
        tokenId: "1",
        tripleCount: 3,
        ingestedAt: "2026-01-01T00:00:00.000Z",
        status: "pending" as const,
      },
    ];
    const incoming = [
      {
        sourceUri: "https://s.org/p/A",
        sourceInstance: "https://s.org",
        canonicalHash: ("0x" + "b".repeat(64)) as `0x${string}`,
        tokenId: "2",
        tripleCount: 5,
        ingestedAt: "2026-04-18T00:00:00.000Z",
        status: "pending" as const,
      },
      {
        sourceUri: "https://s.org/p/B",
        sourceInstance: "https://s.org",
        canonicalHash: ("0x" + "c".repeat(64)) as `0x${string}`,
        tokenId: "3",
        tripleCount: 2,
        ingestedAt: "2026-04-18T00:00:00.000Z",
        status: "pending" as const,
      },
    ];
    const merged = mergeEntries(prior as never, incoming);
    expect(merged).toHaveLength(2);
    expect(merged.find((e) => e.sourceUri.endsWith("/A"))!.canonicalHash).toBe("0x" + "b".repeat(64));
    expect(merged.find((e) => e.sourceUri.endsWith("/B"))!.canonicalHash).toBe("0x" + "c".repeat(64));
  });
});
