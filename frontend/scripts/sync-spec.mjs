#!/usr/bin/env node
import { copyFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, "..", "..", "SPEC.md");
const dst = resolve(here, "..", "src", "content", "spec.md");

await mkdir(dirname(dst), { recursive: true });
await copyFile(src, dst);
console.log(`[sync-spec] ${src} → ${dst}`);
