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
  /** Request timeout (ms). Defaults to 60_000. SynBioHub's `/sbol` endpoint renders on demand and can take >20s. */
  timeoutMs?: number;
  /** User-Agent header value. Defaults to Seqora ingest identifier. */
  userAgent?: string;
  /** Allow overriding fetch for tests. */
  fetchImpl?: typeof fetch;
  /**
   * Max bytes to read from any single response body before aborting.
   * Defaults to 16 MiB. Applies to both SPARQL JSON and SBOL RDF/XML.
   */
  maxResponseBytes?: number;
  /** Max retry attempts for transient failures (network errors + 5xx). Defaults to 3. */
  maxRetries?: number;
  /** Base backoff (ms) for exponential retry: attempt n waits base * 2^(n-1). Defaults to 250. */
  retryBackoffMs?: number;
  /**
   * Additional hostnames that redirects are allowed to target, beyond the
   * configured `instance` host. Useful for mirrors that redirect to a stable
   * canonical host (e.g., `synbiohub.org` → `www.synbiohub.org`).
   */
  allowedRedirectHosts?: string[];
}

const DEFAULT_UA =
  "Seqora-SynBioHubIngest/0.1 (+https://github.com/SeqoraBase/seqora)";
const DEFAULT_MAX_RESPONSE_BYTES = 16 * 1024 * 1024; // 16 MiB
const DEFAULT_MAX_RETRIES = 3;
const DEFAULT_RETRY_BACKOFF_MS = 250;

/**
 * Raised when a response redirect targets a host not in the allowlist.
 * The redirect is never followed; the ingest entry is marked as an error.
 */
export class RedirectOriginMismatch extends Error {
  readonly code = "E_REDIRECT_ORIGIN_MISMATCH";
  constructor(
    readonly from: string,
    readonly to: string,
  ) {
    super(`refusing to follow cross-origin redirect: ${from} -> ${to}`);
    this.name = "RedirectOriginMismatch";
  }
}

/** Raised when a response body exceeds `maxResponseBytes`. */
export class ResponseTooLarge extends Error {
  readonly code = "E_RESPONSE_TOO_LARGE";
  constructor(
    readonly url: string,
    readonly limit: number,
  ) {
    super(`response body exceeded ${limit} bytes for ${url}`);
    this.name = "ResponseTooLarge";
  }
}

export class SynBioHubClient {
  private readonly instance: string;
  private readonly instanceHost: string;
  private readonly requestDelayMs: number;
  private readonly timeoutMs: number;
  private readonly userAgent: string;
  private readonly fetchImpl: typeof fetch;
  private readonly maxResponseBytes: number;
  private readonly maxRetries: number;
  private readonly retryBackoffMs: number;
  private readonly allowedRedirectHosts: Set<string>;
  private lastRequestAt = 0;

  constructor(opts: SynBioHubClientOptions) {
    this.instance = opts.instance.replace(/\/$/, "");
    this.instanceHost = new URL(this.instance).host.toLowerCase();
    this.requestDelayMs = opts.requestDelayMs ?? 250;
    this.timeoutMs = opts.timeoutMs ?? 60_000;
    this.userAgent = opts.userAgent ?? DEFAULT_UA;
    this.fetchImpl = opts.fetchImpl ?? fetch;
    this.maxResponseBytes = opts.maxResponseBytes ?? DEFAULT_MAX_RESPONSE_BYTES;
    this.maxRetries = opts.maxRetries ?? DEFAULT_MAX_RETRIES;
    this.retryBackoffMs = opts.retryBackoffMs ?? DEFAULT_RETRY_BACKOFF_MS;
    this.allowedRedirectHosts = new Set(
      [this.instanceHost, ...(opts.allowedRedirectHosts ?? [])].map((h) => h.toLowerCase()),
    );
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
    let lastErr: unknown = null;
    for (let attempt = 1; attempt <= this.maxRetries; attempt++) {
      try {
        return await this.requestOnce(url, headers);
      } catch (err) {
        lastErr = err;
        if (!isRetryable(err) || attempt === this.maxRetries) {
          throw err;
        }
        const delay = this.retryBackoffMs * 2 ** (attempt - 1);
        await new Promise((r) => setTimeout(r, delay));
      }
    }
    // Unreachable — loop either returns or throws.
    throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
  }

  private async requestOnce(url: string, headers: Record<string, string>): Promise<string> {
    await this.throttle();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const res = await this.fetchImpl(url, {
        method: "GET",
        headers: { "User-Agent": this.userAgent, ...headers },
        signal: controller.signal,
        redirect: "manual",
      });

      // Handle 3xx: validate Location origin before following.
      if (res.status >= 300 && res.status < 400) {
        const location = res.headers.get("location");
        if (!location) {
          throw new HttpError(res.status, res.statusText, url, "redirect missing Location header");
        }
        const target = new URL(location, url);
        if (!this.allowedRedirectHosts.has(target.host.toLowerCase())) {
          throw new RedirectOriginMismatch(url, target.toString());
        }
        // Cancel body, then follow manually with the validated URL.
        await drainBody(res);
        return this.requestOnce(target.toString(), headers);
      }

      if (!res.ok) {
        throw new HttpError(res.status, res.statusText, url);
      }
      return await readCappedText(res, url, this.maxResponseBytes);
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

/** HTTP error with status, preserved so retry logic can branch on 5xx vs 4xx. */
export class HttpError extends Error {
  readonly code = "E_HTTP";
  constructor(
    readonly status: number,
    readonly statusText: string,
    readonly url: string,
    detail?: string,
  ) {
    super(
      `HTTP ${status} ${statusText} for ${url}${detail ? ` (${detail})` : ""}`,
    );
    this.name = "HttpError";
  }
}

function isRetryable(err: unknown): boolean {
  // Redirects and 4xx are never retried.
  if (err instanceof RedirectOriginMismatch) return false;
  if (err instanceof ResponseTooLarge) return false;
  if (err instanceof HttpError) {
    return err.status >= 500 && err.status < 600;
  }
  // AbortError from our own timeout is retryable; so are generic network errors.
  if (err instanceof Error) {
    if (err.name === "AbortError") return true;
    // fetch() throws TypeError on DNS/connection failures.
    if (err.name === "TypeError") return true;
  }
  return false;
}

async function drainBody(res: Response): Promise<void> {
  try {
    if (res.body && !res.bodyUsed) {
      const reader = res.body.getReader();
      // eslint-disable-next-line no-constant-condition
      while (true) {
        const { done } = await reader.read();
        if (done) break;
      }
    }
  } catch {
    // best-effort
  }
}

async function readCappedText(res: Response, url: string, limit: number): Promise<string> {
  if (!res.body) {
    const text = await res.text();
    if (Buffer.byteLength(text, "utf8") > limit) {
      throw new ResponseTooLarge(url, limit);
    }
    return text;
  }
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.byteLength;
    if (total > limit) {
      // Stop reading and abort.
      try {
        await reader.cancel();
      } catch {
        // ignore
      }
      throw new ResponseTooLarge(url, limit);
    }
    chunks.push(value);
  }
  // Concatenate without allocating a giant intermediate buffer twice.
  const out = new Uint8Array(total);
  let pos = 0;
  for (const chunk of chunks) {
    out.set(chunk, pos);
    pos += chunk.byteLength;
  }
  return new TextDecoder("utf-8").decode(out);
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
