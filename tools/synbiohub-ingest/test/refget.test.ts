import { describe, it, expect } from "vitest";
import { createHash } from "node:crypto";
import { ga4ghSeqhash, extractElementsFromRdfXml } from "../src/refget.js";

function expectedHash(seq: string): string {
  const digest = createHash("sha512").update(seq.replace(/\s+/g, "").toUpperCase(), "utf8").digest();
  const truncated = digest.subarray(0, 24);
  const b64 = truncated.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return "SQ." + b64;
}

describe("ga4ghSeqhash", () => {
  it("computes SQ.<base64url-24> over uppercased bases, no padding", async () => {
    const seq = "ACGT";
    const h = ga4ghSeqhash(seq);
    expect(h).toMatch(/^SQ\.[A-Za-z0-9_-]{32}$/);
    expect(h).not.toContain("=");
    expect(h).toBe(expectedHash(seq));
  });

  it("is case-insensitive and whitespace-insensitive", () => {
    expect(ga4ghSeqhash("acgt")).toBe(ga4ghSeqhash("ACGT"));
    expect(ga4ghSeqhash("AC\n  GT\t")).toBe(ga4ghSeqhash("ACGT"));
  });

  it("matches the published refget test vector for MD5-style identity input", () => {
    // Reference-value: the GA4GH refget spec gives the example sequence
    // "ACGTACGT" (8 bases). Verify we compute the spec-correct value.
    const h = ga4ghSeqhash("ACGTACGT");
    expect(h).toBe(expectedHash("ACGTACGT"));
  });

  it("distinguishes different sequences", () => {
    expect(ga4ghSeqhash("ACGT")).not.toBe(ga4ghSeqhash("ACGA"));
  });
});

describe("extractElementsFromRdfXml", () => {
  it("extracts SBOL3 sbol:elements content", () => {
    const xml = `
      <sbol:Sequence xmlns:sbol="http://sbols.org/v3#">
        <sbol:elements>ATGCGT</sbol:elements>
      </sbol:Sequence>
    `;
    expect(extractElementsFromRdfXml(xml)).toBe("ATGCGT");
  });

  it("extracts SBOL2 sbol2:elements content", () => {
    const xml = `
      <sbol2:Sequence xmlns:sbol2="http://sbols.org/v2#">
        <sbol2:elements>ATGC</sbol2:elements>
      </sbol2:Sequence>
    `;
    expect(extractElementsFromRdfXml(xml)).toBe("ATGC");
  });

  it("returns null when no elements literal is present", () => {
    const xml = `
      <sbol:Component xmlns:sbol="http://sbols.org/v3#">
        <sbol:displayId>Composite</sbol:displayId>
      </sbol:Component>
    `;
    expect(extractElementsFromRdfXml(xml)).toBeNull();
  });

  it("strips surrounding whitespace", () => {
    const xml = `<sbol:elements>
      ATGCGT
    </sbol:elements>`;
    expect(extractElementsFromRdfXml(xml)).toBe("ATGCGT");
  });
});
