import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
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
  /** ISO timestamp of ingest. */
  ingestedAt: string;
  /** Status of this entry. `pending` until a claim is processed. */
  status: "pending" | "claimed" | "error";
  /** Error message if `status === "error"`. */
  error?: string;
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

export function writeManifest(path: string, manifest: Manifest): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(manifest, null, 2) + "\n", "utf8");
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
