#!/usr/bin/env node
import { parseArgs } from "node:util";
import { appendFileSync, closeSync, mkdirSync, openSync } from "node:fs";
import { dirname } from "node:path";
import {
  mergeEntries,
  readManifest,
  resumableSkipSet,
  writeManifest,
  type Manifest,
  type ManifestEntry,
} from "./manifest.js";
import { ingest } from "./ingest.js";

interface CliArgs {
  instance: string;
  out: string;
  limit?: number;
  pageSize?: number;
  requestDelayMs?: number;
  maxResponseBytes?: number;
  maxRetries?: number;
  checkpointEvery?: number;
  log?: string;
  resume: boolean;
  force: boolean;
  quiet: boolean;
}

function parseCli(argv: string[]): CliArgs {
  const { values } = parseArgs({
    args: argv,
    options: {
      instance: { type: "string" },
      out: { type: "string" },
      limit: { type: "string" },
      "page-size": { type: "string" },
      "request-delay-ms": { type: "string" },
      "max-response-bytes": { type: "string" },
      "max-retries": { type: "string" },
      "checkpoint-every": { type: "string" },
      log: { type: "string" },
      resume: { type: "boolean" },
      force: { type: "boolean" },
      quiet: { type: "boolean" },
      help: { type: "boolean", short: "h" },
    },
    allowPositionals: false,
  });

  if (values.help) {
    printHelp();
    process.exit(0);
  }

  if (!values.instance) {
    printHelp();
    throw new Error("--instance is required");
  }
  if (!values.out) {
    printHelp();
    throw new Error("--out is required");
  }

  const parseOptionalNumber = (flag: string, raw: string | undefined): number | undefined => {
    if (raw === undefined) return undefined;
    const n = Number(raw);
    if (!Number.isFinite(n) || n <= 0) throw new Error(`${flag} must be a positive number, got ${raw}`);
    return n;
  };

  return {
    instance: values.instance,
    out: values.out,
    limit: parseOptionalNumber("--limit", values.limit),
    pageSize: parseOptionalNumber("--page-size", values["page-size"]),
    requestDelayMs: parseOptionalNumber("--request-delay-ms", values["request-delay-ms"]),
    maxResponseBytes: parseOptionalNumber("--max-response-bytes", values["max-response-bytes"]),
    maxRetries: parseOptionalNumber("--max-retries", values["max-retries"]),
    checkpointEvery: parseOptionalNumber("--checkpoint-every", values["checkpoint-every"]),
    log: values.log,
    resume: values.resume ?? false,
    force: values.force ?? false,
    quiet: values.quiet ?? false,
  };
}

function printHelp(): void {
  const msg = `
seqora-synbiohub-ingest — pull public SynBioHub parts into a pending-claim manifest.

Usage:
  seqora-synbiohub-ingest --instance <url> --out <path> [options]

Required:
  --instance              Base URL of the SynBioHub instance (e.g., https://synbiohub.org).
  --out                   Output manifest JSON path. Existing entries are merged by sourceUri.

Ingest shaping:
  --limit N               Hard cap on parts to ingest. Default: unlimited.
  --page-size N           SPARQL page size. Default: 200.
  --request-delay-ms N    Polite delay between HTTP requests. Default: 250.

Safety & transport:
  --max-response-bytes N  Max bytes per HTTP response body. Default: 16777216 (16 MiB).
  --max-retries N         Max retry attempts on 5xx/network errors. Default: 3.

Durability:
  --checkpoint-every N    Flush manifest to --out every N ingested parts. Default: 50.
  --resume                Skip sourceUris already present with status "pending" or "claimed".
                          Error entries are still re-ingested.
  --force                 With --resume, re-ingest every entry including previous successes.
  --log <path>            Write one NDJSON log record per ingested part to <path> (appended).

Output:
  --quiet                 Suppress per-part progress output on stdout.
  -h, --help              Show this message.

Exit codes:
  0  success (all parts ingested, even if some entries errored)
  1  configuration or runtime error
`.trim();
  process.stdout.write(msg + "\n");
}

async function main(): Promise<void> {
  const args = parseCli(process.argv.slice(2));

  const existing = readManifest(args.out);
  const priorEntries: ManifestEntry[] = existing?.entries ?? [];
  const skipUris = args.resume ? resumableSkipSet(priorEntries, args.force) : new Set<string>();

  // Open the NDJSON log file up-front so we fail fast on permission errors.
  let logFd: number | null = null;
  if (args.log) {
    mkdirSync(dirname(args.log), { recursive: true });
    logFd = openSync(args.log, "a");
  }

  const appendLog = (entry: ManifestEntry, index: number): void => {
    if (logFd === null) return;
    const record = {
      ts: new Date().toISOString(),
      index,
      sourceUri: entry.sourceUri,
      displayId: entry.displayId ?? null,
      status: entry.status,
      canonicalHash: entry.canonicalHash,
      tokenId: entry.tokenId,
      tripleCount: entry.tripleCount,
      ga4ghSeqhash: entry.ga4ghSeqhash ?? null,
      error: entry.error ?? null,
    };
    appendFileSync(logFd, JSON.stringify(record) + "\n");
  };

  // Intermediate flush helper: merge incoming-so-far into prior entries and
  // atomically rewrite the manifest.
  const flush = (incoming: ManifestEntry[]): void => {
    const manifest: Manifest = {
      version: 1,
      generatedAt: new Date().toISOString(),
      sourceInstance: args.instance,
      entries: mergeEntries(priorEntries, incoming),
    };
    writeManifest(args.out, manifest);
  };

  try {
    const result = await ingest({
      instance: args.instance,
      limit: args.limit,
      pageSize: args.pageSize,
      requestDelayMs: args.requestDelayMs,
      maxResponseBytes: args.maxResponseBytes,
      maxRetries: args.maxRetries,
      checkpointEvery: args.checkpointEvery,
      skipUris,
      onCheckpoint: (entries) => flush(entries),
      onProgress: (entry, i) => {
        appendLog(entry, i);
        if (args.quiet) return;
        const tag = entry.status === "error" ? "ERR " : "ok  ";
        const label = entry.displayId ?? entry.sourceUri.split("/").slice(-2).join("/");
        const detail = entry.status === "error" ? ` (${entry.error})` : ` ${entry.canonicalHash}`;
        process.stdout.write(`[${i + 1}] ${tag}${label}${detail}\n`);
      },
    });

    // Final flush — always write, even if zero new entries, so `generatedAt`
    // advances and `--resume` sees the latest run.
    flush(result.entries);

    if (!args.quiet) {
      const skipNote = result.skippedCount > 0 ? `, ${result.skippedCount} skipped` : "";
      process.stdout.write(
        `\nDone. ${result.okCount} ok, ${result.errorCount} errored${skipNote}. Manifest: ${args.out}\n`,
      );
    }
  } finally {
    if (logFd !== null) {
      try {
        closeSync(logFd);
      } catch {
        // best-effort
      }
    }
  }
}

main().catch((err: unknown) => {
  process.stderr.write(`fatal: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
