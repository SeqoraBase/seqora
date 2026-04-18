"use client";

import { useState, useCallback } from "react";
import { useAccount, useChainId, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { Upload, CheckCircle, AlertCircle, Loader2 } from "lucide-react";
import Navbar from "@/components/Navbar";
import { DesignRegistryAbi, getAddress } from "@/lib/contracts";
import { basescanTxUrl } from "@/lib/explorer";

const ZERO_BYTES32 =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

// Lightweight bytes32 shape check: 0x + 64 hex chars.
function isBytes32(value: string): value is `0x${string}` {
  return /^0x[0-9a-fA-F]{64}$/.test(value);
}

function isNonZeroBytes32(value: string): value is `0x${string}` {
  return isBytes32(value) && value.toLowerCase() !== ZERO_BYTES32;
}

export default function RegisterPage() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const registryAddress = getAddress("DesignRegistry", chainId);

  const [canonicalHash, setCanonicalHash] = useState("");
  const [arweaveTx, setArweaveTx] = useState("");
  const [ceramicStreamId, setCeramicStreamId] = useState("");
  const [royaltyBps, setRoyaltyBps] = useState("500");
  const [screeningUID, setScreeningUID] = useState("");
  const [sbolFile, setSbolFile] = useState<File | null>(null);
  const [hashing, setHashing] = useState(false);
  const [hashError, setHashError] = useState<string | null>(null);

  const { writeContract, data: txHash, isPending, error: writeError } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  const handleFileUpload = useCallback(async (file: File) => {
    setSbolFile(file);
    setCanonicalHash("");
    setHashError(null);
    setHashing(true);
    try {
      const body = new FormData();
      body.append("sbol", file);
      const res = await fetch("/api/canonicalize", { method: "POST", body });
      const json = (await res.json()) as { canonicalHash?: string; error?: string };
      if (!res.ok || !json.canonicalHash) {
        setHashError(json.error ?? `canonicalize failed (HTTP ${res.status})`);
        return;
      }
      setCanonicalHash(json.canonicalHash);
    } catch (err) {
      setHashError(err instanceof Error ? err.message : "canonicalize request failed");
    } finally {
      setHashing(false);
    }
  }, []);

  const screeningUIDValid = isNonZeroBytes32(screeningUID);
  const canonicalHashValid = isBytes32(canonicalHash);
  const canSubmit =
    !!address &&
    canonicalHashValid &&
    screeningUIDValid &&
    !hashing &&
    !isPending &&
    !isConfirming;

  const handleSubmit = useCallback(
    (e: React.FormEvent) => {
      e.preventDefault();
      if (!address || !canonicalHashValid || !screeningUIDValid) return;

      writeContract({
        address: registryAddress,
        abi: DesignRegistryAbi,
        functionName: "register",
        args: [
          address,
          canonicalHash as `0x${string}`,
          ZERO_BYTES32,
          arweaveTx,
          ceramicStreamId,
          {
            bps: Number(royaltyBps),
            recipient: address,
            parentSplitBps: 0,
          },
          screeningUID as `0x${string}`,
          [],
        ],
      });
    },
    [
      address,
      canonicalHash,
      canonicalHashValid,
      arweaveTx,
      ceramicStreamId,
      royaltyBps,
      screeningUID,
      screeningUIDValid,
      registryAddress,
      writeContract,
    ]
  );

  return (
    <div className="min-h-screen bg-base">
      <Navbar />
      <main className="mx-auto max-w-2xl px-6 pt-24 pb-16">
        <div className="mb-8">
          <h1 className="text-3xl font-bold text-text-primary mb-2">
            Register Design
          </h1>
          <p className="text-text-secondary">
            Register a new synthetic biology design on-chain. Upload your SBOL
            file to generate a canonical hash.
          </p>
        </div>

        {!isConnected ? (
          <div className="rounded-xl border border-border bg-surface p-8 text-center">
            <AlertCircle size={32} className="mx-auto mb-3 text-text-tertiary" />
            <p className="text-text-secondary mb-4">
              Connect your wallet to register a design.
            </p>
          </div>
        ) : (
          <form onSubmit={handleSubmit} className="space-y-6">
            {/* SBOL File Upload */}
            <div>
              <label className="block text-sm font-medium text-text-primary mb-2">
                SBOL File
              </label>
              <label className="flex flex-col items-center justify-center rounded-xl border-2 border-dashed border-border bg-surface p-8 cursor-pointer hover:border-primary/40 transition-colors">
                <Upload size={24} className="text-text-tertiary mb-2" />
                <span className="text-text-secondary text-sm">
                  {sbolFile ? sbolFile.name : "Drop SBOL file or click to browse"}
                </span>
                {hashing && (
                  <span className="text-text-tertiary text-xs mt-2 flex items-center gap-1.5">
                    <Loader2 size={12} className="animate-spin" />
                    Canonicalizing (URDNA2015 → keccak256)...
                  </span>
                )}
                {!hashing && canonicalHash && (
                  <span className="text-primary text-xs mt-2 font-mono">
                    {canonicalHash.slice(0, 18)}...
                  </span>
                )}
                <input
                  type="file"
                  accept=".xml,.sbol,.rdf,.ttl"
                  className="hidden"
                  onChange={(e) => {
                    const file = e.target.files?.[0];
                    if (file) handleFileUpload(file);
                  }}
                />
              </label>
              {hashError && (
                <p className="mt-2 text-xs text-red-400">
                  <AlertCircle size={12} className="inline mr-1" />
                  {hashError}
                </p>
              )}
            </div>

            {/* Canonical Hash (manual override) */}
            <div>
              <label className="block text-sm font-medium text-text-primary mb-2">
                Canonical Hash
              </label>
              <input
                type="text"
                value={canonicalHash}
                onChange={(e) => setCanonicalHash(e.target.value)}
                placeholder="0x... (auto-generated from file or enter manually)"
                className="w-full rounded-xl border border-border bg-surface px-4 py-3 text-text-primary placeholder:text-text-tertiary focus:outline-none focus:border-primary/60 font-mono text-sm"
              />
            </div>

            {/* Arweave TX */}
            <div>
              <label className="block text-sm font-medium text-text-primary mb-2">
                Arweave TX ID
                <span className="text-text-tertiary font-normal ml-1">
                  (optional)
                </span>
              </label>
              <input
                type="text"
                value={arweaveTx}
                onChange={(e) => setArweaveTx(e.target.value)}
                placeholder="Arweave transaction ID for canonical SBOL storage"
                className="w-full rounded-xl border border-border bg-surface px-4 py-3 text-text-primary placeholder:text-text-tertiary focus:outline-none focus:border-primary/60 text-sm"
              />
            </div>

            {/* Ceramic Stream ID */}
            <div>
              <label className="block text-sm font-medium text-text-primary mb-2">
                Ceramic Stream ID
                <span className="text-text-tertiary font-normal ml-1">
                  (optional)
                </span>
              </label>
              <input
                type="text"
                value={ceramicStreamId}
                onChange={(e) => setCeramicStreamId(e.target.value)}
                placeholder="Ceramic stream for mutable metadata"
                className="w-full rounded-xl border border-border bg-surface px-4 py-3 text-text-primary placeholder:text-text-tertiary focus:outline-none focus:border-primary/60 text-sm"
              />
            </div>

            {/* Royalty BPS */}
            <div>
              <label className="block text-sm font-medium text-text-primary mb-2">
                Royalty Rate
              </label>
              <div className="flex items-center gap-3">
                <input
                  type="number"
                  min="0"
                  max="10000"
                  value={royaltyBps}
                  onChange={(e) => setRoyaltyBps(e.target.value)}
                  className="w-32 rounded-xl border border-border bg-surface px-4 py-3 text-text-primary focus:outline-none focus:border-primary/60 text-sm"
                />
                <span className="text-text-secondary text-sm">
                  bps ({(Number(royaltyBps) / 100).toFixed(2)}%)
                </span>
              </div>
            </div>

            {/* Screening UID */}
            <div>
              <label className="block text-sm font-medium text-text-primary mb-2">
                Screening Attestation UID
              </label>
              <input
                type="text"
                value={screeningUID}
                onChange={(e) => setScreeningUID(e.target.value)}
                placeholder="0x... (EAS attestation UID from approved screener)"
                className="w-full rounded-xl border border-border bg-surface px-4 py-3 text-text-primary placeholder:text-text-tertiary focus:outline-none focus:border-primary/60 font-mono text-sm"
              />
              <p className="mt-2 text-xs text-text-tertiary">
                Required. Obtain a valid EAS attestation UID from an approved
                biosafety screener before registering — the contract rejects
                zero / missing UIDs with <code>AttestationInvalid</code>.
              </p>
              {screeningUID.length > 0 && !screeningUIDValid && (
                <p className="mt-1 text-xs text-red-400">
                  Must be a non-zero 32-byte hex value (0x + 64 hex chars).
                </p>
              )}
            </div>

            {/* Submit */}
            <button
              type="submit"
              disabled={!canSubmit}
              className="w-full rounded-xl bg-primary py-3.5 font-semibold text-sm transition-all hover:bg-primary-hover disabled:opacity-50 disabled:cursor-not-allowed"
              style={{ color: "#0A0B0F" }}
            >
              {hashing ? (
                <span className="flex items-center justify-center gap-2">
                  <Loader2 size={16} className="animate-spin" /> Canonicalizing...
                </span>
              ) : isPending ? (
                <span className="flex items-center justify-center gap-2">
                  <Loader2 size={16} className="animate-spin" /> Confirm in
                  Wallet...
                </span>
              ) : isConfirming ? (
                <span className="flex items-center justify-center gap-2">
                  <Loader2 size={16} className="animate-spin" /> Confirming...
                </span>
              ) : !canonicalHashValid ? (
                "Enter canonical hash"
              ) : !screeningUIDValid ? (
                "Enter screening attestation UID"
              ) : (
                "Register Design"
              )}
            </button>

            {/* Status Messages */}
            {writeError && (
              <div className="rounded-xl border border-red-500/30 bg-red-500/10 p-4 text-red-400 text-sm">
                <AlertCircle size={16} className="inline mr-2" />
                {writeError.message.slice(0, 200)}
              </div>
            )}

            {isSuccess && txHash && (
              <div className="rounded-xl border border-primary/30 bg-primary/10 p-4 text-primary text-sm">
                <CheckCircle size={16} className="inline mr-2" />
                Design registered!{" "}
                <a
                  href={basescanTxUrl(chainId, txHash)}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="underline"
                >
                  View transaction
                </a>
              </div>
            )}
          </form>
        )}
      </main>
    </div>
  );
}
