#!/usr/bin/env node
import { parseArgs } from "node:util";
import { mergeEntries, readManifest, writeManifest, type Manifest } from "./manifest.js";
import { ingest } from "./ingest.js";

interface CliArgs {
  instance: string;
  out: string;
  limit?: number;
  pageSize?: number;
  requestDelayMs?: number;
  quiet?: boolean;
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
    quiet: values.quiet ?? false,
  };
}

function printHelp(): void {
  const msg = `
seqora-synbiohub-ingest — pull public SynBioHub parts into a pending-claim manifest.

Usage:
  seqora-synbiohub-ingest --instance <url> --out <path> [--limit N] [--page-size N]
                          [--request-delay-ms N] [--quiet]

Options:
  --instance             Base URL of the SynBioHub instance (e.g., https://synbiohub.org).
  --out                  Output manifest JSON path. Existing entries are merged by sourceUri.
  --limit                Hard cap on parts to ingest. Default: unlimited.
  --page-size            SPARQL page size. Default: 200.
  --request-delay-ms     Polite delay between HTTP requests. Default: 250.
  --quiet                Suppress per-part progress output.
  -h, --help             Show this message.

Exit codes:
  0  success (all parts ingested, even if some entries errored)
  1  configuration or runtime error
`.trim();
  process.stdout.write(msg + "\n");
}

async function main(): Promise<void> {
  const args = parseCli(process.argv.slice(2));

  const existing = readManifest(args.out);
  const priorEntries = existing?.entries ?? [];

  const result = await ingest({
    instance: args.instance,
    limit: args.limit,
    pageSize: args.pageSize,
    requestDelayMs: args.requestDelayMs,
    onProgress: args.quiet
      ? undefined
      : (entry, i) => {
          const tag = entry.status === "error" ? "ERR " : "ok  ";
          const label = entry.displayId ?? entry.sourceUri.split("/").slice(-2).join("/");
          const detail = entry.status === "error" ? ` (${entry.error})` : ` ${entry.canonicalHash}`;
          process.stdout.write(`[${i + 1}] ${tag}${label}${detail}\n`);
        },
  });

  const manifest: Manifest = {
    version: 1,
    generatedAt: new Date().toISOString(),
    sourceInstance: args.instance,
    entries: mergeEntries(priorEntries, result.entries),
  };
  writeManifest(args.out, manifest);

  if (!args.quiet) {
    process.stdout.write(
      `\nDone. ${result.okCount} ok, ${result.errorCount} errored. Manifest: ${args.out}\n`,
    );
  }
}

main().catch((err: unknown) => {
  process.stderr.write(`fatal: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
