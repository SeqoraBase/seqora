#!/usr/bin/env node
// Regenerate `frontend/src/lib/contracts/<Name>Abi.ts` from `contracts/out/<Name>.sol/<Name>.json`.
//
// Run locally after changing contract ABIs; CI runs this same script and fails if the working
// tree is dirty after regeneration (i.e. someone hand-edited an Abi.ts file or forgot to sync).
//
// Usage: node scripts/sync-abis.mjs
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const CONTRACTS = [
  "DesignRegistry",
  "LicenseRegistry",
  "BiosafetyCourt",
  "ProvenanceRegistry",
  "RoyaltyRouter",
  "ScreeningAttestations",
];

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..");
const outDir = resolve(repoRoot, "contracts", "out");
const abiDir = resolve(repoRoot, "frontend", "src", "lib", "contracts");

async function main() {
  await mkdir(abiDir, { recursive: true });
  for (const name of CONTRACTS) {
    const artifactPath = resolve(outDir, `${name}.sol`, `${name}.json`);
    const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
    if (!Array.isArray(artifact.abi)) {
      throw new Error(`${artifactPath}: missing 'abi' array — did you run 'forge build'?`);
    }
    const outPath = resolve(abiDir, `${name}Abi.ts`);
    const body = `export const ${name}Abi = ${JSON.stringify(artifact.abi, null, 2)} as const;\n`;
    await writeFile(outPath, body);
    console.log(`[sync-abis] ${artifactPath} → ${outPath}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
