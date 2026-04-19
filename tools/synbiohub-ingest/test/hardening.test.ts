import { describe, it, expect, vi } from "vitest";
import {
  SynBioHubClient,
  RedirectOriginMismatch,
  ResponseTooLarge,
  HttpError,
} from "../src/synbiohub.js";

describe("redirect pinning", () => {
  it("refuses to follow a redirect to a different origin", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(null, {
          status: 302,
          headers: { Location: "http://169.254.169.254/metadata" },
        }),
    );
    const client = new SynBioHubClient({
      instance: "https://synbiohub.org",
      requestDelayMs: 0,
      retryBackoffMs: 0,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    await expect(client.fetchSbolRdfXml("https://synbiohub.org/public/p/1")).rejects.toBeInstanceOf(
      RedirectOriginMismatch,
    );
    // A redirect to a disallowed origin must not be followed.
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("follows a redirect when the target host is the same origin", async () => {
    const fetchImpl = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(
        new Response(null, {
          status: 301,
          headers: { Location: "https://synbiohub.org/public/p/1/sbol?v=2" },
        }),
      )
      .mockResolvedValueOnce(new Response("<rdf/>", { status: 200 }));

    const client = new SynBioHubClient({
      instance: "https://synbiohub.org",
      requestDelayMs: 0,
      retryBackoffMs: 0,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    const body = await client.fetchSbolRdfXml("https://synbiohub.org/public/p/1");
    expect(body).toBe("<rdf/>");
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("follows a redirect to an explicitly-allowed additional host", async () => {
    const fetchImpl = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(
        new Response(null, {
          status: 302,
          headers: { Location: "https://mirror.example.org/public/p/1/sbol" },
        }),
      )
      .mockResolvedValueOnce(new Response("<rdf/>", { status: 200 }));
    const client = new SynBioHubClient({
      instance: "https://synbiohub.org",
      requestDelayMs: 0,
      retryBackoffMs: 0,
      allowedRedirectHosts: ["mirror.example.org"],
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    const body = await client.fetchSbolRdfXml("https://synbiohub.org/public/p/1");
    expect(body).toBe("<rdf/>");
  });
});

describe("response size cap", () => {
  it("aborts when the response body exceeds maxResponseBytes", async () => {
    // A 2 KiB body with a 1 KiB cap.
    const big = "A".repeat(2048);
    const fetchImpl = vi.fn(async () => new Response(big, { status: 200 }));
    const client = new SynBioHubClient({
      instance: "https://synbiohub.org",
      requestDelayMs: 0,
      retryBackoffMs: 0,
      maxResponseBytes: 1024,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    await expect(client.fetchSbolRdfXml("https://synbiohub.org/public/p/1")).rejects.toBeInstanceOf(
      ResponseTooLarge,
    );
  });

  it("does not trip when the body is within the cap", async () => {
    const small = "A".repeat(500);
    const fetchImpl = vi.fn(async () => new Response(small, { status: 200 }));
    const client = new SynBioHubClient({
      instance: "https://synbiohub.org",
      requestDelayMs: 0,
      retryBackoffMs: 0,
      maxResponseBytes: 1024,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    const body = await client.fetchSbolRdfXml("https://synbiohub.org/public/p/1");
    expect(body).toBe(small);
  });
});

describe("retry on transient failures", () => {
  it("retries on 5xx and succeeds on the 3rd attempt", async () => {
    const fetchImpl = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response("fail", { status: 503, statusText: "Service Unavailable" }))
      .mockResolvedValueOnce(new Response("fail", { status: 503, statusText: "Service Unavailable" }))
      .mockResolvedValueOnce(new Response("<rdf/>", { status: 200 }));

    const client = new SynBioHubClient({
      instance: "https://synbiohub.org",
      requestDelayMs: 0,
      retryBackoffMs: 0,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    const body = await client.fetchSbolRdfXml("https://synbiohub.org/public/p/1");
    expect(body).toBe("<rdf/>");
    expect(fetchImpl).toHaveBeenCalledTimes(3);
  });

  it("does NOT retry on 4xx", async () => {
    const fetchImpl = vi.fn(async () => new Response("nope", { status: 404, statusText: "Not Found" }));
    const client = new SynBioHubClient({
      instance: "https://synbiohub.org",
      requestDelayMs: 0,
      retryBackoffMs: 0,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    await expect(client.fetchSbolRdfXml("https://synbiohub.org/public/p/1")).rejects.toBeInstanceOf(
      HttpError,
    );
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("retries on network errors (TypeError from fetch)", async () => {
    const fetchImpl = vi
      .fn<typeof fetch>()
      .mockRejectedValueOnce(new TypeError("fetch failed"))
      .mockResolvedValueOnce(new Response("<rdf/>", { status: 200 }));

    const client = new SynBioHubClient({
      instance: "https://synbiohub.org",
      requestDelayMs: 0,
      retryBackoffMs: 0,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    const body = await client.fetchSbolRdfXml("https://synbiohub.org/public/p/1");
    expect(body).toBe("<rdf/>");
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("retries when the client's own timeout aborts the request", async () => {
    // First call: hang past the client timeout so the AbortController fires.
    // Second call: succeed.
    const fetchImpl = vi
      .fn<typeof fetch>()
      .mockImplementationOnce((_url, init) => {
        return new Promise((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () => {
            reject(new DOMException("The operation was aborted.", "AbortError"));
          });
        });
      })
      .mockResolvedValueOnce(new Response("<rdf/>", { status: 200 }));

    const client = new SynBioHubClient({
      instance: "https://synbiohub.org",
      requestDelayMs: 0,
      retryBackoffMs: 0,
      timeoutMs: 50,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    const body = await client.fetchSbolRdfXml("https://synbiohub.org/public/p/1");
    expect(body).toBe("<rdf/>");
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });
});
