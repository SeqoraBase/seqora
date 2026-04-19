import { canonicalizeSbol } from "./canonicalize.js";
import { extractOrcidId, SynBioHubClient, type SynBioHubPartRef } from "./synbiohub.js";
import type { ManifestEntry } from "./manifest.js";
import { ga4ghSeqhash, extractElementsFromRdfXml } from "./refget.js";

export interface IngestOptions {
  instance: string;
  limit?: number;
  pageSize?: number;
  requestDelayMs?: number;
  fetchImpl?: typeof fetch;
  /** Max bytes to read from any single response body. Defaults to 16 MiB. */
  maxResponseBytes?: number;
  /** Max retry attempts for transient failures (5xx, network). Defaults to 3. */
  maxRetries?: number;
  /** Base retry backoff (ms). Defaults to 250ms. */
  retryBackoffMs?: number;
  /** Per-request timeout (ms). Defaults to 60_000. */
  timeoutMs?: number;
  /** Optional progress callback, fired once per processed part. */
  onProgress?: (entry: ManifestEntry, index: number) => void;
  /**
   * Set of `sourceUri` values to skip (used by `--resume`). Skipped parts
   * never trigger a network call; they are simply absent from `entries`.
   */
  skipUris?: Set<string>;
  /**
   * Invoked every `checkpointEvery` entries with the current accumulated
   * slice. Callers use this to flush an intermediate manifest to disk.
   */
  onCheckpoint?: (entries: ManifestEntry[]) => void | Promise<void>;
  /** Flush a checkpoint every N ingested parts. Defaults to 50. */
  checkpointEvery?: number;
}

export interface IngestResult {
  entries: ManifestEntry[];
  okCount: number;
  errorCount: number;
  skippedCount: number;
}

export async function ingest(opts: IngestOptions): Promise<IngestResult> {
  const client = new SynBioHubClient({
    instance: opts.instance,
    requestDelayMs: opts.requestDelayMs,
    fetchImpl: opts.fetchImpl,
    maxResponseBytes: opts.maxResponseBytes,
    maxRetries: opts.maxRetries,
    retryBackoffMs: opts.retryBackoffMs,
    timeoutMs: opts.timeoutMs,
  });

  const entries: ManifestEntry[] = [];
  let index = 0;
  let okCount = 0;
  let errorCount = 0;
  let skippedCount = 0;
  const checkpointEvery = opts.checkpointEvery ?? 50;
  const skipUris = opts.skipUris ?? new Set<string>();

  for await (const ref of client.listPublicParts({ pageSize: opts.pageSize, limit: opts.limit })) {
    if (skipUris.has(ref.uri)) {
      skippedCount++;
      continue;
    }
    const entry = await ingestOne(client, opts.instance, ref);
    entries.push(entry);
    if (entry.status === "error") errorCount++;
    else okCount++;
    opts.onProgress?.(entry, index++);

    if (opts.onCheckpoint && entries.length > 0 && entries.length % checkpointEvery === 0) {
      await opts.onCheckpoint(entries);
    }
  }

  return { entries, okCount, errorCount, skippedCount };
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
    const elements = extractElementsFromRdfXml(rdf);
    return {
      ...base,
      canonicalHash,
      tokenId: tokenId.toString(),
      tripleCount,
      ga4ghSeqhash: elements ? ga4ghSeqhash(elements) : null,
      status: "pending",
    };
  } catch (err) {
    return {
      ...base,
      canonicalHash: "0x0000000000000000000000000000000000000000000000000000000000000000",
      tokenId: "0",
      tripleCount: 0,
      ga4ghSeqhash: null,
      status: "error",
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
