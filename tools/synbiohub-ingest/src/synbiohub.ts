export interface SynBioHubPartRef {
  /** Canonical SBOL part URI on the source instance. */
  uri: string;
  /** Display id (e.g., `BBa_E0040`) if resolvable from SPARQL metadata. */
  displayId?: string;
  /** Free-text title (dcterms:title) if present. */
  title?: string;
  /** Author IRI, possibly an ORCID URL. */
  attributedTo?: string;
}

export interface SynBioHubClientOptions {
  /** Instance base URL — no trailing slash, e.g. `https://synbiohub.org`. */
  instance: string;
  /** Polite delay between requests (ms). Defaults to 250. */
  requestDelayMs?: number;
  /** Request timeout (ms). Defaults to 20_000. */
  timeoutMs?: number;
  /** User-Agent header value. Defaults to Seqora ingest identifier. */
  userAgent?: string;
  /** Allow overriding fetch for tests. */
  fetchImpl?: typeof fetch;
}

const DEFAULT_UA =
  "Seqora-SynBioHubIngest/0.1 (+https://github.com/SeqoraBase/seqora)";

export class SynBioHubClient {
  private readonly instance: string;
  private readonly requestDelayMs: number;
  private readonly timeoutMs: number;
  private readonly userAgent: string;
  private readonly fetchImpl: typeof fetch;
  private lastRequestAt = 0;

  constructor(opts: SynBioHubClientOptions) {
    this.instance = opts.instance.replace(/\/$/, "");
    this.requestDelayMs = opts.requestDelayMs ?? 250;
    this.timeoutMs = opts.timeoutMs ?? 20_000;
    this.userAgent = opts.userAgent ?? DEFAULT_UA;
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  /**
   * List public SBOL Components via SPARQL, paginated.
   * Returns partial metadata suitable for driving per-part SBOL fetches.
   */
  async *listPublicParts(opts: { pageSize?: number; limit?: number } = {}): AsyncGenerator<SynBioHubPartRef> {
    const pageSize = opts.pageSize ?? 200;
    const hardCap = opts.limit ?? Number.POSITIVE_INFINITY;
    let yielded = 0;
    let offset = 0;

    while (yielded < hardCap) {
      const pageLimit = Math.min(pageSize, hardCap - yielded);
      const query = buildListQuery(pageLimit, offset);
      const results = await this.runSparql(query);
      if (results.length === 0) return;

      for (const row of results) {
        if (yielded >= hardCap) return;
        yield {
          uri: row.uri,
          displayId: row.displayId,
          title: row.title,
          attributedTo: row.attributedTo,
        };
        yielded++;
      }
      offset += results.length;
      if (results.length < pageLimit) return;
    }
  }

  /**
   * Fetch SBOL RDF/XML for a given part URI.
   * Returns the raw response body (to be fed into canonicalizeSbol).
   */
  async fetchSbolRdfXml(partUri: string): Promise<string> {
    const url = `${partUri.replace(/\/$/, "")}/sbol`;
    return this.request(url, { Accept: "application/rdf+xml" });
  }

  private async runSparql(query: string): Promise<SparqlBinding[]> {
    const url = `${this.instance}/sparql?query=${encodeURIComponent(query)}`;
    const body = await this.request(url, { Accept: "application/sparql-results+json" });
    const parsed = JSON.parse(body) as SparqlJsonResults;
    return parsed.results.bindings.map((b) => ({
      uri: b.subject?.value ?? "",
      displayId: b.displayId?.value,
      title: b.title?.value,
      attributedTo: b.attributedTo?.value,
    }));
  }

  private async request(url: string, headers: Record<string, string>): Promise<string> {
    await this.throttle();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const res = await this.fetchImpl(url, {
        method: "GET",
        headers: { "User-Agent": this.userAgent, ...headers },
        signal: controller.signal,
        redirect: "follow",
      });
      if (!res.ok) {
        throw new Error(`HTTP ${res.status} ${res.statusText} for ${url}`);
      }
      return await res.text();
    } finally {
      clearTimeout(timer);
    }
  }

  private async throttle(): Promise<void> {
    const since = Date.now() - this.lastRequestAt;
    if (since < this.requestDelayMs) {
      await new Promise((r) => setTimeout(r, this.requestDelayMs - since));
    }
    this.lastRequestAt = Date.now();
  }
}

interface SparqlBinding {
  uri: string;
  displayId?: string;
  title?: string;
  attributedTo?: string;
}

interface SparqlJsonResults {
  results: {
    bindings: Array<Record<string, { type: string; value: string } | undefined>>;
  };
}

function buildListQuery(limit: number, offset: number): string {
  return `
PREFIX sbol: <http://sbols.org/v3#>
PREFIX sbol2: <http://sbols.org/v2#>
PREFIX dcterms: <http://purl.org/dc/terms/>
PREFIX prov: <http://www.w3.org/ns/prov#>
SELECT DISTINCT ?subject ?displayId ?title ?attributedTo WHERE {
  { ?subject a sbol:Component } UNION { ?subject a sbol2:ComponentDefinition }
  OPTIONAL { ?subject sbol:displayId ?displayId }
  OPTIONAL { ?subject sbol2:displayId ?displayId }
  OPTIONAL { ?subject dcterms:title ?title }
  OPTIONAL { ?subject prov:wasAttributedTo ?attributedTo }
}
ORDER BY ?subject
LIMIT ${limit}
OFFSET ${offset}
`.trim();
}

/**
 * Extract the ORCID id from an author IRI, if present.
 * Returns `null` for unknown IRIs.
 */
export function extractOrcidId(iri: string | undefined): string | null {
  if (!iri) return null;
  const match = iri.match(/orcid\.org\/(\d{4}-\d{4}-\d{4}-\d{3}[\dX])/);
  return match?.[1] ?? null;
}
