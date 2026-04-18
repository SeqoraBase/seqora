// Thin re-export shim. The canonicalizer lives in @seqora/canonicalize so the
// ingest tool, the Foundry fixture, and any future frontend code all agree on
// the SBOL3 → URDNA2015 → keccak256 pipeline.
export { canonicalizeSbol } from "@seqora/canonicalize";
export type { CanonicalizationResult, SerializationFormat } from "@seqora/canonicalize";
