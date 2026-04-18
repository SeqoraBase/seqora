import { describe, it, expect, vi } from "vitest";
import { SynBioHubClient, extractOrcidId } from "../src/synbiohub.js";

describe("extractOrcidId", () => {
  it("parses canonical ORCID URLs", () => {
    expect(extractOrcidId("https://orcid.org/0000-0002-1825-0097")).toBe("0000-0002-1825-0097");
    expect(extractOrcidId("http://orcid.org/0000-0001-2345-678X")).toBe("0000-0001-2345-678X");
  });

  it("returns null for non-ORCID IRIs", () => {
    expect(extractOrcidId("https://synbiohub.org/user/alice")).toBeNull();
    expect(extractOrcidId(undefined)).toBeNull();
    expect(extractOrcidId("")).toBeNull();
  });
});

describe("SynBioHubClient", () => {
  it("paginates via SPARQL offset/limit and yields parsed part refs", async () => {
    const page1 = {
      results: {
        bindings: [
          {
            subject: { type: "uri", value: "https://synbiohub.org/public/igem/BBa_E0040/1" },
            displayId: { type: "literal", value: "BBa_E0040" },
            title: { type: "literal", value: "GFP" },
            attributedTo: { type: "uri", value: "https://orcid.org/0000-0002-1825-0097" },
          },
          {
            subject: { type: "uri", value: "https://synbiohub.org/public/igem/BBa_B0030/1" },
            displayId: { type: "literal", value: "BBa_B0030" },
          },
        ],
      },
    };
    const page2 = { results: { bindings: [] } };

    const fetchImpl = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify(page1), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify(page2), { status: 200 }));

    const client = new SynBioHubClient({
      instance: "https://synbiohub.org",
      requestDelayMs: 0,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    const refs = [];
    for await (const r of client.listPublicParts({ pageSize: 2 })) refs.push(r);

    expect(refs).toHaveLength(2);
    expect(refs[0]).toMatchObject({
      uri: "https://synbiohub.org/public/igem/BBa_E0040/1",
      displayId: "BBa_E0040",
      title: "GFP",
      attributedTo: "https://orcid.org/0000-0002-1825-0097",
    });
    expect(refs[1]?.displayId).toBe("BBa_B0030");
    expect(fetchImpl).toHaveBeenCalledTimes(2);
    const firstCall = fetchImpl.mock.calls[0]?.[0] as string;
    expect(firstCall).toContain("/sparql?query=");
    expect(firstCall).toContain("OFFSET%200");
    const secondCall = fetchImpl.mock.calls[1]?.[0] as string;
    expect(secondCall).toContain("OFFSET%202");
  });

  it("respects an explicit --limit cap", async () => {
    const page = {
      results: {
        bindings: Array.from({ length: 5 }, (_, i) => ({
          subject: { type: "uri", value: `https://example.org/part/${i}` },
        })),
      },
    };
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify(page), { status: 200 }));
    const client = new SynBioHubClient({
      instance: "https://example.org",
      requestDelayMs: 0,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    const refs = [];
    for await (const r of client.listPublicParts({ pageSize: 5, limit: 3 })) refs.push(r);
    expect(refs).toHaveLength(3);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("throws on non-2xx responses (after exhausting retries on 5xx)", async () => {
    const fetchImpl = vi.fn(async () => new Response("nope", { status: 502, statusText: "Bad Gateway" }));
    const client = new SynBioHubClient({
      instance: "https://example.org",
      requestDelayMs: 0,
      retryBackoffMs: 0,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    await expect(client.fetchSbolRdfXml("https://example.org/public/x/1")).rejects.toThrow(/HTTP 502/);
    // 3 retry attempts by default on 5xx.
    expect(fetchImpl).toHaveBeenCalledTimes(3);
  });

  it("sends a User-Agent identifying Seqora", async () => {
    const fetchImpl = vi.fn(async () => new Response("<rdf/>", { status: 200 }));
    const client = new SynBioHubClient({
      instance: "https://example.org",
      requestDelayMs: 0,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    await client.fetchSbolRdfXml("https://example.org/public/x/1");
    const init = fetchImpl.mock.calls[0]?.[1] as RequestInit;
    const headers = init.headers as Record<string, string>;
    expect(headers["User-Agent"]).toMatch(/Seqora-SynBioHubIngest/);
    expect(headers.Accept).toBe("application/rdf+xml");
  });
});
