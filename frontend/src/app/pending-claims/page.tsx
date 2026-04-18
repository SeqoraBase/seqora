"use client";

import { useCallback, useMemo, useState } from "react";
import {
  useAccount,
  useChainId,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import {
  AlertCircle,
  CheckCircle,
  ExternalLink,
  FileJson,
  Loader2,
  Upload,
} from "lucide-react";
import Navbar from "@/components/Navbar";
import { DesignRegistryAbi, getAddress } from "@/lib/contracts";
import { basescanTxUrl } from "@/lib/explorer";

const ZERO_BYTES32 =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

type EntryStatus = "pending" | "claimed" | "error";

interface ManifestEntry {
  sourceUri: string;
  sourceInstance: string;
  displayId?: string;
  title?: string;
  attributedTo?: string;
  orcidId?: string;
  canonicalHash: `0x${string}`;
  tokenId: string;
  tripleCount: number;
  ga4ghSeqhash?: string | null;
  ingestedAt: string;
  status: EntryStatus;
  error?: string;
}

interface Manifest {
  version: 1;
  generatedAt: string;
  sourceInstance: string;
  entries: ManifestEntry[];
}

interface EntryFormState {
  screeningUID: string;
  arweaveTx: string;
  ceramicStreamId: string;
}

function isBytes32(value: string): value is `0x${string}` {
  return /^0x[0-9a-fA-F]{64}$/.test(value);
}

function isNonZeroBytes32(value: string): value is `0x${string}` {
  return isBytes32(value) && value.toLowerCase() !== ZERO_BYTES32;
}

function parseManifest(raw: string): Manifest {
  const parsed = JSON.parse(raw) as unknown;
  if (
    !parsed ||
    typeof parsed !== "object" ||
    (parsed as { version?: unknown }).version !== 1 ||
    !Array.isArray((parsed as { entries?: unknown }).entries)
  ) {
    throw new Error("not a v1 ingest manifest (missing version or entries)");
  }
  return parsed as Manifest;
}

function shortHash(h: string): string {
  return `${h.slice(0, 10)}…${h.slice(-8)}`;
}

function shortTokenId(tokenId: string): string {
  // tokenId is a decimal uint256 in the manifest; show its keccak-hash-like
  // leading digits so the UI stays compact without losing uniqueness signal.
  return tokenId.length > 12 ? `${tokenId.slice(0, 6)}…${tokenId.slice(-4)}` : tokenId;
}

function StatusBadge({ status }: { status: EntryStatus | "registering" | "registered" }) {
  const styles: Record<string, string> = {
    pending: "text-text-tertiary bg-surface border border-border",
    error: "text-red-400 bg-red-500/10 border border-red-500/30",
    claimed: "text-primary bg-primary/10 border border-primary/30",
    registering: "text-primary bg-primary/10 border border-primary/30",
    registered: "text-primary bg-primary/10 border border-primary/30",
  };
  const labels: Record<string, string> = {
    pending: "Pending",
    error: "Error",
    claimed: "Claimed",
    registering: "Registering…",
    registered: "Registered ✓",
  };
  return (
    <span className={`text-xs px-2 py-0.5 rounded-full ${styles[status]}`}>
      {labels[status]}
    </span>
  );
}

interface EntryCardProps {
  entry: ManifestEntry;
  royaltyBps: string;
  locallyRegistered: boolean;
  registeringUri: string | null;
  onRegister: (entry: ManifestEntry, form: EntryFormState) => void;
  txHash: `0x${string}` | undefined;
  isPending: boolean;
  isConfirming: boolean;
  chainId: number;
}

function EntryCard({
  entry,
  royaltyBps,
  locallyRegistered,
  registeringUri,
  onRegister,
  txHash,
  isPending,
  isConfirming,
  chainId,
}: EntryCardProps) {
  const [form, setForm] = useState<EntryFormState>({
    screeningUID: "",
    arweaveTx: "",
    ceramicStreamId: "",
  });
  const [expanded, setExpanded] = useState(false);

  const isActive = registeringUri === entry.sourceUri;
  const isBusy = isActive && (isPending || isConfirming);

  const onChainStatus = locallyRegistered ? "registered" : entry.status;
  const displayStatus: EntryStatus | "registering" | "registered" =
    isActive && (isPending || isConfirming)
      ? "registering"
      : onChainStatus;

  const screeningValid = isNonZeroBytes32(form.screeningUID);
  const bpsNumber = Number(royaltyBps);
  const royaltyValid = Number.isFinite(bpsNumber) && bpsNumber >= 0 && bpsNumber <= 10000;
  const canRegister =
    entry.status === "pending" &&
    !locallyRegistered &&
    !isBusy &&
    screeningValid &&
    royaltyValid;

  return (
    <div className="rounded-xl border border-border bg-surface p-5">
      <div className="flex items-start justify-between gap-3 mb-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2 mb-1">
            <h3 className="text-text-primary font-semibold text-sm truncate">
              {entry.displayId ?? entry.title ?? "Untitled part"}
            </h3>
            <StatusBadge status={displayStatus} />
          </div>
          {entry.title && entry.displayId && (
            <p className="text-text-secondary text-xs truncate">{entry.title}</p>
          )}
          <a
            href={entry.sourceUri}
            target="_blank"
            rel="noopener noreferrer"
            className="text-text-tertiary text-xs flex items-center gap-1 hover:text-primary truncate mt-1"
          >
            <span className="truncate">{entry.sourceUri}</span>
            <ExternalLink size={10} className="shrink-0" />
          </a>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-xs mb-3">
        <div className="flex justify-between">
          <span className="text-text-tertiary">Canonical hash</span>
          <span className="text-text-secondary font-mono">{shortHash(entry.canonicalHash)}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-text-tertiary">Token ID</span>
          <span className="text-text-secondary font-mono">{shortTokenId(entry.tokenId)}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-text-tertiary">Triples</span>
          <span className="text-text-secondary">{entry.tripleCount.toLocaleString()}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-text-tertiary">Ingested</span>
          <span className="text-text-secondary">
            {new Date(entry.ingestedAt).toLocaleDateString()}
          </span>
        </div>
        {entry.orcidId && (
          <div className="col-span-2 flex justify-between">
            <span className="text-text-tertiary">Author ORCID</span>
            <a
              href={`https://orcid.org/${entry.orcidId}`}
              target="_blank"
              rel="noopener noreferrer"
              className="text-primary font-mono hover:underline"
            >
              {entry.orcidId}
            </a>
          </div>
        )}
      </div>

      {entry.status === "error" && entry.error && (
        <div className="rounded-lg border border-red-500/30 bg-red-500/10 p-2 text-xs text-red-400 mb-3">
          <AlertCircle size={12} className="inline mr-1" />
          {entry.error}
        </div>
      )}

      {entry.status === "claimed" && !locallyRegistered && (
        <p className="text-xs text-text-tertiary">
          Manifest marks this part as already claimed on-chain.
        </p>
      )}

      {locallyRegistered && txHash && (
        <div className="rounded-lg border border-primary/30 bg-primary/10 p-2 text-xs text-primary flex items-center gap-2">
          <CheckCircle size={12} />
          <span className="flex-1">Registered on-chain.</span>
          <a
            href={basescanTxUrl(chainId, txHash)}
            target="_blank"
            rel="noopener noreferrer"
            className="underline flex items-center gap-1"
          >
            View tx <ExternalLink size={10} />
          </a>
        </div>
      )}

      {entry.status === "pending" && !locallyRegistered && (
        <>
          {!expanded ? (
            <button
              onClick={() => setExpanded(true)}
              className="w-full rounded-lg border border-border bg-base py-2 text-xs font-medium text-text-secondary hover:text-text-primary hover:border-primary/40 transition-colors"
            >
              Prepare on-chain registration
            </button>
          ) : (
            <div className="space-y-3 border-t border-border pt-3 mt-2">
              <div>
                <label className="block text-xs font-medium text-text-primary mb-1">
                  Screening Attestation UID
                </label>
                <input
                  type="text"
                  value={form.screeningUID}
                  onChange={(e) => setForm({ ...form, screeningUID: e.target.value })}
                  placeholder="0x… (EAS UID from approved screener)"
                  className="w-full rounded-lg border border-border bg-base px-3 py-2 text-text-primary placeholder:text-text-tertiary focus:outline-none focus:border-primary/60 font-mono text-xs"
                />
                {form.screeningUID.length > 0 && !screeningValid && (
                  <p className="mt-1 text-xs text-red-400">Must be a non-zero 32-byte hex value.</p>
                )}
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-medium text-text-primary mb-1">
                    Arweave TX{" "}
                    <span className="text-text-tertiary font-normal">(optional)</span>
                  </label>
                  <input
                    type="text"
                    value={form.arweaveTx}
                    onChange={(e) => setForm({ ...form, arweaveTx: e.target.value })}
                    placeholder="Arweave tx id"
                    className="w-full rounded-lg border border-border bg-base px-3 py-2 text-text-primary placeholder:text-text-tertiary focus:outline-none focus:border-primary/60 text-xs"
                  />
                </div>
                <div>
                  <label className="block text-xs font-medium text-text-primary mb-1">
                    Ceramic stream{" "}
                    <span className="text-text-tertiary font-normal">(optional)</span>
                  </label>
                  <input
                    type="text"
                    value={form.ceramicStreamId}
                    onChange={(e) =>
                      setForm({ ...form, ceramicStreamId: e.target.value })
                    }
                    placeholder="Ceramic stream id"
                    className="w-full rounded-lg border border-border bg-base px-3 py-2 text-text-primary placeholder:text-text-tertiary focus:outline-none focus:border-primary/60 text-xs"
                  />
                </div>
              </div>

              <button
                disabled={!canRegister}
                onClick={() => onRegister(entry, form)}
                className="w-full rounded-lg bg-primary py-2.5 font-semibold text-xs transition-all hover:bg-primary-hover disabled:opacity-50 disabled:cursor-not-allowed"
                style={{ color: "#0A0B0F" }}
              >
                {isBusy ? (
                  <span className="flex items-center justify-center gap-2">
                    <Loader2 size={12} className="animate-spin" />
                    {isPending ? "Confirm in Wallet…" : "Confirming…"}
                  </span>
                ) : !screeningValid ? (
                  "Enter screening UID"
                ) : (
                  `Register @ ${(bpsNumber / 100).toFixed(2)}% royalty`
                )}
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}

export default function PendingClaimsPage() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const registryAddress = getAddress("DesignRegistry", chainId);

  const [manifest, setManifest] = useState<Manifest | null>(null);
  const [parseError, setParseError] = useState<string | null>(null);
  const [royaltyBps, setRoyaltyBps] = useState("500");
  const [registeringUri, setRegisteringUri] = useState<string | null>(null);
  // sourceUri → tx hash of a successful register in this session
  const [registered, setRegistered] = useState<Record<string, `0x${string}`>>({});

  const { writeContract, data: txHash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  // Commit successful tx → local "registered" map so the entry flips to Claimed.
  if (isSuccess && txHash && registeringUri && !registered[registeringUri]) {
    setRegistered((prev) => ({ ...prev, [registeringUri]: txHash }));
  }

  const handleFile = useCallback(async (file: File) => {
    setParseError(null);
    try {
      const text = await file.text();
      setManifest(parseManifest(text));
    } catch (err) {
      setManifest(null);
      setParseError(err instanceof Error ? err.message : "failed to parse manifest");
    }
  }, []);

  const handlePaste = useCallback((raw: string) => {
    setParseError(null);
    if (!raw.trim()) {
      setManifest(null);
      return;
    }
    try {
      setManifest(parseManifest(raw));
    } catch (err) {
      setManifest(null);
      setParseError(err instanceof Error ? err.message : "failed to parse manifest");
    }
  }, []);

  const handleRegister = useCallback(
    (entry: ManifestEntry, form: EntryFormState) => {
      if (!address) return;
      if (!isNonZeroBytes32(form.screeningUID)) return;
      const bps = Number(royaltyBps);
      if (!Number.isFinite(bps) || bps < 0 || bps > 10000) return;

      reset();
      setRegisteringUri(entry.sourceUri);

      writeContract({
        address: registryAddress,
        abi: DesignRegistryAbi,
        functionName: "register",
        args: [
          address,
          entry.canonicalHash,
          ZERO_BYTES32,
          form.arweaveTx,
          form.ceramicStreamId,
          {
            bps,
            recipient: address,
            parentSplitBps: 0,
          },
          form.screeningUID,
          [],
        ],
      });
    },
    [address, registryAddress, royaltyBps, writeContract, reset]
  );

  const counts = useMemo(() => {
    if (!manifest) return { total: 0, pending: 0, claimed: 0, error: 0 };
    let pending = 0;
    let claimed = 0;
    let error = 0;
    for (const e of manifest.entries) {
      if (registered[e.sourceUri]) {
        claimed++;
        continue;
      }
      if (e.status === "pending") pending++;
      else if (e.status === "claimed") claimed++;
      else if (e.status === "error") error++;
    }
    return { total: manifest.entries.length, pending, claimed, error };
  }, [manifest, registered]);

  return (
    <div className="min-h-screen bg-base">
      <Navbar />
      <main className="mx-auto max-w-[1280px] px-6 pt-24 pb-16">
        <div className="mb-8">
          <h1 className="text-3xl font-bold text-text-primary mb-2">Pending Claims</h1>
          <p className="text-text-secondary">
            Load a manifest produced by{" "}
            <code className="text-xs">seqora-synbiohub-ingest</code> and promote its
            entries into on-chain design registrations.
          </p>
        </div>

        <div className="grid gap-8 lg:grid-cols-3">
          <div className="lg:col-span-2 space-y-6">
            {!manifest ? (
              <ManifestLoader
                onFile={handleFile}
                onPaste={handlePaste}
                error={parseError}
              />
            ) : (
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2 text-text-secondary text-sm">
                  <FileJson size={14} className="text-primary" />
                  <span>
                    Loaded <strong className="text-text-primary">{counts.total}</strong>{" "}
                    entries from{" "}
                    <code className="text-xs">{manifest.sourceInstance}</code>
                  </span>
                </div>
                <button
                  onClick={() => {
                    setManifest(null);
                    setParseError(null);
                  }}
                  className="text-xs text-text-tertiary hover:text-text-primary underline"
                >
                  Load different manifest
                </button>
              </div>
            )}

            {manifest && !isConnected && (
              <div className="rounded-xl border border-border bg-surface p-6 text-center">
                <AlertCircle size={24} className="mx-auto mb-2 text-text-tertiary" />
                <p className="text-text-secondary text-sm">
                  Connect your wallet to promote pending entries on-chain.
                </p>
              </div>
            )}

            {manifest && (
              <div className="space-y-3">
                {manifest.entries.map((entry) => (
                  <EntryCard
                    key={entry.sourceUri}
                    entry={entry}
                    royaltyBps={royaltyBps}
                    locallyRegistered={Boolean(registered[entry.sourceUri])}
                    registeringUri={registeringUri}
                    onRegister={handleRegister}
                    txHash={registered[entry.sourceUri] ?? (registeringUri === entry.sourceUri ? txHash : undefined)}
                    isPending={isPending}
                    isConfirming={isConfirming}
                    chainId={chainId}
                  />
                ))}
              </div>
            )}

            {writeError && (
              <div className="rounded-xl border border-red-500/30 bg-red-500/10 p-4 text-red-400 text-sm">
                <AlertCircle size={16} className="inline mr-2" />
                {writeError.message.slice(0, 200)}
              </div>
            )}
          </div>

          <div className="space-y-4">
            <div className="rounded-xl border border-border bg-surface p-6">
              <h3 className="text-text-primary font-semibold mb-3">Summary</h3>
              <div className="space-y-3 text-sm">
                <SummaryRow label="Total" value={counts.total} />
                <SummaryRow label="Pending" value={counts.pending} />
                <SummaryRow label="Claimed" value={counts.claimed} tone="primary" />
                <SummaryRow label="Errors" value={counts.error} tone={counts.error > 0 ? "error" : undefined} />
              </div>
            </div>

            <div className="rounded-xl border border-border bg-surface p-6">
              <h3 className="text-text-primary font-semibold mb-3">Royalty</h3>
              <label className="block text-xs font-medium text-text-secondary mb-2">
                Rate applied to every registration
              </label>
              <div className="flex items-center gap-2">
                <input
                  type="number"
                  min="0"
                  max="10000"
                  value={royaltyBps}
                  onChange={(e) => setRoyaltyBps(e.target.value)}
                  className="w-24 rounded-lg border border-border bg-base px-3 py-2 text-text-primary focus:outline-none focus:border-primary/60 text-sm"
                />
                <span className="text-text-secondary text-xs">
                  bps ({(Number(royaltyBps) / 100).toFixed(2)}%)
                </span>
              </div>
              <p className="text-text-tertiary text-xs mt-3">
                Royalty recipient is the connected wallet. Fork splits are not yet
                wired from manifest metadata.
              </p>
            </div>

            <a
              href="/register"
              className="block w-full rounded-xl border border-border bg-surface py-3 text-center font-medium text-sm text-text-secondary hover:text-text-primary hover:border-primary/40 transition-colors"
            >
              Single-design register →
            </a>
          </div>
        </div>
      </main>
    </div>
  );
}

function ManifestLoader({
  onFile,
  onPaste,
  error,
}: {
  onFile: (f: File) => void;
  onPaste: (raw: string) => void;
  error: string | null;
}) {
  const [pasted, setPasted] = useState("");

  return (
    <div className="space-y-4">
      <label className="flex flex-col items-center justify-center rounded-xl border-2 border-dashed border-border bg-surface p-8 cursor-pointer hover:border-primary/40 transition-colors">
        <Upload size={24} className="text-text-tertiary mb-2" />
        <span className="text-text-secondary text-sm">
          Drop an <code className="text-xs">ingest-manifest.json</code> or click to browse
        </span>
        <input
          type="file"
          accept="application/json,.json"
          className="hidden"
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) onFile(f);
          }}
        />
      </label>

      <details className="rounded-xl border border-border bg-surface">
        <summary className="cursor-pointer text-sm text-text-secondary px-4 py-3">
          …or paste manifest JSON
        </summary>
        <div className="px-4 pb-4">
          <textarea
            value={pasted}
            onChange={(e) => {
              setPasted(e.target.value);
              onPaste(e.target.value);
            }}
            placeholder='{"version": 1, "entries": [ … ]}'
            rows={8}
            className="w-full rounded-lg border border-border bg-base px-3 py-2 text-text-primary placeholder:text-text-tertiary focus:outline-none focus:border-primary/60 font-mono text-xs"
          />
        </div>
      </details>

      {error && (
        <div className="rounded-xl border border-red-500/30 bg-red-500/10 p-3 text-red-400 text-sm">
          <AlertCircle size={14} className="inline mr-2" />
          {error}
        </div>
      )}
    </div>
  );
}

function SummaryRow({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone?: "primary" | "error";
}) {
  const cls =
    tone === "primary"
      ? "text-primary"
      : tone === "error"
        ? "text-red-400"
        : "text-text-secondary";
  return (
    <div className="flex justify-between">
      <span className="text-text-tertiary">{label}</span>
      <span className={cls}>{value}</span>
    </div>
  );
}
