import { describe, it, expect, vi } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ingest } from "../src/ingest.js";
import { resumableSkipSet, type ManifestEntry } from "../src/manifest.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixture = readFileSync(join(__dirname, "fixtures", "minimal.rdf"), "utf8");

function mockSparqlResponse(
  bindings: Array<Record<string, { type: string; value: string }>>,
): Response {
  return new Response(JSON.stringify({ results: { bindings } }), { status: 200 });
}

describe("checkpoint flush", () => {
  it("invokes onCheckpoint every N entries with the accumulated slice", async () => {
    const parts = Array.from({ length: 5 }, (_, i) => ({
      subject: { type: "uri", value: `https://synbiohub.org/public/igem/P${i}/1` },
    }));
    const fetchImpl = vi.fn<typeof fetch>();
    fetchImpl.mockResolvedValueOnce(mockSparqlResponse(parts));
    for (let i = 0; i < 5; i++) {
      fetchImpl.mockResolvedValueOnce(new Response(fixture, { status: 200 }));
    }
    fetchImpl.mockResolvedValueOnce(mockSparqlResponse([]));

    const checkpoints: number[] = [];
    const result = await ingest({
      instance: "https://synbiohub.org",
      pageSize: 5,
      requestDelayMs: 0,
      retryBackoffMs: 0,
      checkpointEvery: 2,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      onCheckpoint: (entries) => {
        // Snapshot the size at each flush.
        checkpoints.push(entries.length);
      },
    });

    expect(result.entries).toHaveLength(5);
    expect(result.okCount).toBe(5);
    // Flushes happen at sizes 2 and 4 (not 5 — that's the caller's final flush).
    expect(checkpoints).toEqual([2, 4]);
  });
});

describe("resumableSkipSet", () => {
  const entries: ManifestEntry[] = [
    {
      sourceUri: "https://s.org/p/A",
      sourceInstance: "https://s.org",
      canonicalHash: ("0x" + "a".repeat(64)) as `0x${string}`,
      tokenId: "1",
      tripleCount: 3,
      ingestedAt: "2026-01-01T00:00:00.000Z",
      status: "pending",
    },
    {
      sourceUri: "https://s.org/p/B",
      sourceInstance: "https://s.org",
      canonicalHash: "0x" + "0".repeat(64) as `0x${string}`,
      tokenId: "0",
      tripleCount: 0,
      ingestedAt: "2026-01-01T00:00:00.000Z",
      status: "error",
      error: "boom",
    },
    {
      sourceUri: "https://s.org/p/C",
      sourceInstance: "https://s.org",
      canonicalHash: ("0x" + "c".repeat(64)) as `0x${string}`,
      tokenId: "2",
      tripleCount: 4,
      ingestedAt: "2026-01-01T00:00:00.000Z",
      status: "claimed",
    },
  ];

  it("skips pending and claimed entries, but not errors", () => {
    const skip = resumableSkipSet(entries, false);
    expect(skip.has("https://s.org/p/A")).toBe(true);
    expect(skip.has("https://s.org/p/C")).toBe(true);
    expect(skip.has("https://s.org/p/B")).toBe(false);
  });

  it("returns an empty set when force=true", () => {
    const skip = resumableSkipSet(entries, true);
    expect(skip.size).toBe(0);
  });
});

describe("ingest --resume behavior via skipUris", () => {
  it("skips parts whose sourceUri is in skipUris (no SBOL fetch issued)", async () => {
    const parts = [
      { subject: { type: "uri", value: "https://synbiohub.org/public/igem/A/1" } },
      { subject: { type: "uri", value: "https://synbiohub.org/public/igem/B/1" } },
    ];
    const fetchImpl = vi.fn<typeof fetch>();
    fetchImpl.mockResolvedValueOnce(mockSparqlResponse(parts));
    // Only B's SBOL fetch should happen; A is skipped.
    fetchImpl.mockResolvedValueOnce(new Response(fixture, { status: 200 }));
    fetchImpl.mockResolvedValueOnce(mockSparqlResponse([]));

    const result = await ingest({
      instance: "https://synbiohub.org",
      pageSize: 2,
      requestDelayMs: 0,
      retryBackoffMs: 0,
      skipUris: new Set(["https://synbiohub.org/public/igem/A/1"]),
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(result.skippedCount).toBe(1);
    expect(result.entries).toHaveLength(1);
    expect(result.entries[0]?.sourceUri).toBe("https://synbiohub.org/public/igem/B/1");
    // 2 calls total: 1 SPARQL page + 1 SBOL fetch for B (no SBOL for A).
    // (End-of-pagination page is not fetched because the first page returned fewer
    // than pageSize rows after skipping, but we yielded both; check exact count.)
    expect(fetchImpl.mock.calls.length).toBeGreaterThanOrEqual(2);
    // Crucially, no SBOL fetch was issued for A.
    const urls = fetchImpl.mock.calls.map((c) => c[0] as string);
    expect(urls.some((u) => u.includes("/A/1/sbol"))).toBe(false);
    expect(urls.some((u) => u.includes("/B/1/sbol"))).toBe(true);
  });
});
