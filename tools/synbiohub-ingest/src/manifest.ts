import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync } from "node:fs";
import { dirname } from "node:path";

export interface ManifestEntry {
  /** Source SynBioHub part URI. */
  sourceUri: string;
  /** Source instance base URL. */
  sourceInstance: string;
  /** Display id from SPARQL metadata, if present. */
  displayId?: string;
  /** dcterms:title, if present. */
  title?: string;
  /** Author IRI as-fetched. */
  attributedTo?: string;
  /** Extracted ORCID id (without URL prefix), if the author IRI was an ORCID URL. */
  orcidId?: string;
  /** 0x-prefixed keccak256 of canonicalized N-Quads. */
  canonicalHash: `0x${string}`;
  /** uint256 tokenId as decimal string (JSON-safe). */
  tokenId: string;
  /** Number of triples canonicalized. */
  tripleCount: number;
  /**
   * GA4GH refget v1.0 sequence identifier, `SQ.<base64url-24>`. `null` when
   * the part has no `sbol:elements` literal (e.g., a composite component).
   * Optional for backward compatibility with manifests produced by v0.1.
   */
  ga4ghSeqhash?: string | null;
  /** ISO timestamp of ingest. */
  ingestedAt: string;
  /** Status of this entry. `pending` until a claim is processed. */
  status: "pending" | "claimed" | "error";
  /** Error message if `status === "error"`. */
  error?: string;
  /** Tx hash of the on-chain register call. Written by the /pending-claims UI after claiming. */
  claimTxHash?: `0x${string}`;
  /** ISO timestamp of the on-chain claim. */
  claimedAt?: string;
}

export interface Manifest {
  version: 1;
  generatedAt: string;
  sourceInstance: string;
  entries: ManifestEntry[];
}

export function readManifest(path: string): Manifest | null {
  if (!existsSync(path)) return null;
  const raw = readFileSync(path, "utf8");
  const parsed = JSON.parse(raw) as Manifest;
  if (parsed.version !== 1) {
    throw new Error(`unsupported manifest version ${parsed.version}`);
  }
  return parsed;
}

/**
 * Atomically write the manifest: write to `<path>.tmp`, fsync-equivalent via
 * `writeFileSync`, then rename. This avoids leaving a half-written JSON file
 * if the process is killed during a checkpoint flush.
 */
export function writeManifest(path: string, manifest: Manifest): void {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(manifest, null, 2) + "\n", "utf8");
  renameSync(tmp, path);
}

/**
 * Merge freshly-ingested entries into an existing manifest by `sourceUri`.
 * Re-ingestion of the same part overwrites the prior entry (idempotent).
 */
export function mergeEntries(existing: ManifestEntry[], incoming: ManifestEntry[]): ManifestEntry[] {
  const byUri = new Map<string, ManifestEntry>();
  for (const e of existing) byUri.set(e.sourceUri, e);
  for (const e of incoming) byUri.set(e.sourceUri, e);
  return [...byUri.values()].sort((a, b) => a.sourceUri.localeCompare(b.sourceUri));
}

/**
 * Return the set of `sourceUri` values that should be skipped on a `--resume`
 * run. By default, any non-error entry is skipped. If `force` is true, an
 * empty set is returned so every part is re-ingested.
 */
export function resumableSkipSet(existing: ManifestEntry[], force: boolean): Set<string> {
  if (force) return new Set();
  const skip = new Set<string>();
  for (const e of existing) {
    if (e.status === "pending" || e.status === "claimed") {
      skip.add(e.sourceUri);
    }
  }
  return skip;
}
