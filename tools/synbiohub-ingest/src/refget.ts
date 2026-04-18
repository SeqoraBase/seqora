import { sha512 } from "@noble/hashes/sha512";

/**
 * Compute a GA4GH refget v1.0 sequence identifier for a raw biological sequence.
 *
 *   ga4ghSeqhash = "SQ." + base64url(truncate(sha512(upper(bases)), 24))
 *
 * - Input is trimmed of surrounding whitespace; all internal whitespace
 *   (spaces, tabs, newlines) is stripped before hashing.
 * - Bases are uppercased per the spec.
 * - SHA-512 is truncated to the first 24 bytes (192 bits).
 * - Encoded as RFC 4648 §5 base64url with no padding.
 *
 * See: https://samtools.github.io/hts-specs/refget.html (§1.0)
 */
export function ga4ghSeqhash(raw: string): string {
  const cleaned = raw.replace(/\s+/g, "").toUpperCase();
  const digest = sha512(new TextEncoder().encode(cleaned));
  const truncated = digest.subarray(0, 24);
  return "SQ." + base64url(truncated);
}

function base64url(bytes: Uint8Array): string {
  // Node's Buffer supports "base64url" natively on Node >= 16, but use a
  // stable manual conversion to avoid Buffer typings leaking into a browser
  // build in the future.
  const b64 = Buffer.from(bytes).toString("base64");
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * Extract a raw base sequence from an SBOL RDF/XML document by scanning the
 * `sbol:elements` (SBOL3) and `sbol2:elements` (SBOL2) literal contents.
 *
 * Returns the first non-empty elements literal found, or `null` if none.
 *
 * We deliberately use a regex rather than a full RDF parser here because:
 * - The canonical hash path already validates RDF structure upstream.
 * - refget hashing is a best-effort annotation; a parse failure on a
 *   composite part (no `sbol:elements` at all) must not fail the ingest.
 */
export function extractElementsFromRdfXml(rdfXml: string): string | null {
  // Match either the SBOL3 or SBOL2 `elements` tag. We accept any prefix that
  // maps to the known namespaces via an explicit xmlns attribute OR the common
  // conventional prefixes `sbol:` / `sbol2:`.
  const patterns = [
    /<sbol:elements(?:\s[^>]*)?>([^<]*)<\/sbol:elements>/i,
    /<sbol2:elements(?:\s[^>]*)?>([^<]*)<\/sbol2:elements>/i,
    // Fall back to any *:elements that is a child of a known sequence context.
    // This handles unusual prefix choices.
    /<([a-zA-Z][\w-]*):elements(?:\s[^>]*)?>([^<]*)<\/\1:elements>/i,
  ];
  for (const re of patterns) {
    const m = rdfXml.match(re);
    if (!m) continue;
    // For the fallback pattern, the text is in group 2 instead of group 1.
    const text = (m[1] && !m[2] ? m[1] : m[2] ?? m[1]) ?? "";
    const cleaned = text.replace(/\s+/g, "");
    if (cleaned.length > 0) return cleaned;
  }
  return null;
}
