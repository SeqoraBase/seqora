import { canonicalizeSbol } from "./canonicalize.js";
import { extractOrcidId, SynBioHubClient, type SynBioHubPartRef } from "./synbiohub.js";
import type { ManifestEntry } from "./manifest.js";

export interface IngestOptions {
  instance: string;
  limit?: number;
  pageSize?: number;
  requestDelayMs?: number;
  fetchImpl?: typeof fetch;
  /** Optional progress callback, fired once per processed part. */
  onProgress?: (entry: ManifestEntry, index: number) => void;
}

export interface IngestResult {
  entries: ManifestEntry[];
  okCount: number;
  errorCount: number;
}

export async function ingest(opts: IngestOptions): Promise<IngestResult> {
  const client = new SynBioHubClient({
    instance: opts.instance,
    requestDelayMs: opts.requestDelayMs,
    fetchImpl: opts.fetchImpl,
  });

  const entries: ManifestEntry[] = [];
  let index = 0;
  let okCount = 0;
  let errorCount = 0;

  for await (const ref of client.listPublicParts({ pageSize: opts.pageSize, limit: opts.limit })) {
    const entry = await ingestOne(client, opts.instance, ref);
    entries.push(entry);
    if (entry.status === "error") errorCount++;
    else okCount++;
    opts.onProgress?.(entry, index++);
  }

  return { entries, okCount, errorCount };
}

async function ingestOne(
  client: SynBioHubClient,
  sourceInstance: string,
  ref: SynBioHubPartRef,
): Promise<ManifestEntry> {
  const base: Omit<ManifestEntry, "canonicalHash" | "tokenId" | "tripleCount" | "status"> = {
    sourceUri: ref.uri,
    sourceInstance,
    displayId: ref.displayId,
    title: ref.title,
    attributedTo: ref.attributedTo,
    orcidId: extractOrcidId(ref.attributedTo) ?? undefined,
    ingestedAt: new Date().toISOString(),
  };

  try {
    const rdf = await client.fetchSbolRdfXml(ref.uri);
    const { canonicalHash, tokenId, tripleCount } = await canonicalizeSbol(rdf, "application/rdf+xml");
    return {
      ...base,
      canonicalHash,
      tokenId: tokenId.toString(),
      tripleCount,
      status: "pending",
    };
  } catch (err) {
    return {
      ...base,
      canonicalHash: "0x0000000000000000000000000000000000000000000000000000000000000000",
      tokenId: "0",
      tripleCount: 0,
      status: "error",
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
