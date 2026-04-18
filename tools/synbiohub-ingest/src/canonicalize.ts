import { StreamParser as TurtleStreamParser } from "n3";
import { RdfXmlParser } from "rdfxml-streaming-parser";
import { canonize } from "rdf-canonize";
import { keccak_256 } from "@noble/hashes/sha3";
import { Readable } from "node:stream";
import type { Quad } from "@rdfjs/types";

export type SerializationFormat = "application/rdf+xml" | "text/turtle";

export interface CanonicalizationResult {
  /** 0x-prefixed 32-byte keccak256 of the canonicalized N-Quads. */
  canonicalHash: `0x${string}`;
  /** uint256 tokenId = canonicalHash as big-endian unsigned integer. */
  tokenId: bigint;
  /** Canonical N-Quads string (Unicode NFC not applied — RDF canonicalization spec handles normalization). */
  canonicalNQuads: string;
  /** Number of triples canonicalized. */
  tripleCount: number;
}

function parseRdfXml(input: string): Promise<Quad[]> {
  return new Promise((resolve, reject) => {
    const parser = new RdfXmlParser();
    const quads: Quad[] = [];
    parser.on("data", (q: Quad) => quads.push(q));
    parser.on("error", reject);
    parser.on("end", () => resolve(quads));
    Readable.from([input]).pipe(parser);
  });
}

function parseTurtle(input: string): Promise<Quad[]> {
  return new Promise((resolve, reject) => {
    const parser = new TurtleStreamParser({ format: "text/turtle" });
    const quads: Quad[] = [];
    parser.on("data", (q: Quad) => quads.push(q));
    parser.on("error", reject);
    parser.on("end", () => resolve(quads));
    Readable.from([input]).pipe(parser);
  });
}

async function parseQuads(input: string, format: SerializationFormat): Promise<Quad[]> {
  if (format === "application/rdf+xml") return parseRdfXml(input);
  if (format === "text/turtle") return parseTurtle(input);
  throw new Error(`unsupported serialization: ${format satisfies never}`);
}

/**
 * Canonicalize an SBOL/RDF document and derive a Seqora tokenId.
 *
 * Pipeline: parse → URDNA2015 canonicalize (via rdf-canonize) → keccak256.
 * This matches the on-chain expectation: DesignRegistry.register accepts
 * canonicalHash = keccak256 of the canonicalized RDF, and tokenId = uint256(canonicalHash).
 *
 * The canonicalization step is deterministic under triple reordering, so
 * ingesting the same part twice — even across SynBioHub mirrors — yields
 * an identical canonicalHash.
 */
export async function canonicalizeSbol(
  input: string,
  format: SerializationFormat = "application/rdf+xml",
): Promise<CanonicalizationResult> {
  const quads = await parseQuads(input, format);
  if (quads.length === 0) {
    throw new Error("empty RDF input — no triples parsed");
  }

  const canonicalNQuads = (await canonize(quads as unknown as object[], {
    algorithm: "URDNA2015",
    format: "application/n-quads",
  })) as string;

  const digest = keccak_256(new TextEncoder().encode(canonicalNQuads));
  const hex = Buffer.from(digest).toString("hex");
  const canonicalHash = `0x${hex}` as const;
  const tokenId = BigInt(canonicalHash);

  return {
    canonicalHash,
    tokenId,
    canonicalNQuads,
    tripleCount: quads.length,
  };
}
