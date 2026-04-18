import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { createServer, type Server } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ingest } from "../src/ingest.js";
import { ga4ghSeqhash } from "../src/refget.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

// A minimal SBOL3 fixture with a known `sbol:elements` sequence so we can
// assert the expected ga4ghSeqhash exactly.
const KNOWN_SEQUENCE = "ATGCGTAAAGGAGAAGAACTTTTCACTGGAGTTGTCCCAATTCTTGTT";
const SBOL_FIXTURE = readFileSync(join(__dirname, "fixtures", "minimal.rdf"), "utf8");

function buildSparqlJson(partUri: string): string {
  return JSON.stringify({
    results: {
      bindings: [
        {
          subject: { type: "uri", value: partUri },
          displayId: { type: "literal", value: "BBa_E0040" },
          title: { type: "literal", value: "GFP" },
          attributedTo: { type: "uri", value: "https://orcid.org/0000-0002-1825-0097" },
        },
      ],
    },
  });
}

describe("end-to-end ingest against an in-process HTTP server", () => {
  let server: Server;
  let baseUrl: string;

  beforeAll(async () => {
    server = createServer((req, res) => {
      const host = req.headers.host ?? "localhost";
      if (!req.url) {
        res.statusCode = 400;
        res.end("bad request");
        return;
      }
      const url = new URL(req.url, `http://${host}`);

      if (url.pathname === "/sparql") {
        const partUri = `http://${host}/public/igem/BBa_E0040/1`;
        res.statusCode = 200;
        res.setHeader("content-type", "application/sparql-results+json");
        if (url.searchParams.get("query")?.includes("OFFSET 0")) {
          res.end(buildSparqlJson(partUri));
        } else {
          // End of pagination.
          res.end(JSON.stringify({ results: { bindings: [] } }));
        }
        return;
      }

      if (url.pathname === "/public/igem/BBa_E0040/1/sbol") {
        res.statusCode = 200;
        res.setHeader("content-type", "application/rdf+xml");
        res.end(SBOL_FIXTURE);
        return;
      }

      res.statusCode = 404;
      res.end("not found");
    });

    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
    const addr = server.address();
    if (typeof addr === "string" || addr === null) throw new Error("unexpected listen address");
    baseUrl = `http://127.0.0.1:${addr.port}`;
  });

  afterAll(async () => {
    await new Promise<void>((resolve, reject) =>
      server.close((err) => (err ? reject(err) : resolve())),
    );
  });

  it("produces a non-empty canonicalHash AND the correct ga4ghSeqhash for the known sequence", async () => {
    const result = await ingest({
      instance: baseUrl,
      pageSize: 1,
      requestDelayMs: 0,
      retryBackoffMs: 0,
      // Use the real (global) fetch — we're hitting a real loopback server.
    });

    expect(result.okCount).toBe(1);
    expect(result.errorCount).toBe(0);
    const entry = result.entries[0]!;
    expect(entry.status).toBe("pending");
    expect(entry.canonicalHash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(BigInt(entry.canonicalHash)).toBeGreaterThan(0n);
    expect(entry.tripleCount).toBeGreaterThan(0);
    expect(entry.ga4ghSeqhash).not.toBeNull();
    expect(entry.ga4ghSeqhash).toBe(ga4ghSeqhash(KNOWN_SEQUENCE));
    expect(entry.ga4ghSeqhash).toMatch(/^SQ\.[A-Za-z0-9_-]{32}$/);
  });
});
