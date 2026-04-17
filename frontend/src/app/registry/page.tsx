"use client";

import { useState } from "react";
import { useReadContract, useChainId } from "wagmi";
import { formatUnits } from "viem";
import { Search, ExternalLink, Dna } from "lucide-react";
import Navbar from "@/components/Navbar";
import { DesignRegistryAbi, getAddress } from "@/lib/contracts";

type Design = {
  registrant: `0x${string}`;
  canonicalHash: `0x${string}`;
  ga4ghSeqhash: `0x${string}`;
  arweaveTx: string;
  ceramicStreamId: string;
  royalty: {
    bps: number;
    recipient: `0x${string}`;
  };
  screeningAttestationUID: `0x${string}`;
  parentTokenIds: `0x${string}`[];
  registeredAt: bigint;
};

function DesignCard({ tokenId, design }: { tokenId: string; design: Design }) {
  const shortHash = `${design.canonicalHash.slice(0, 10)}...${design.canonicalHash.slice(-8)}`;
  const shortRegistrant = `${design.registrant.slice(0, 6)}...${design.registrant.slice(-4)}`;

  return (
    <div className="rounded-xl border border-border bg-surface p-6 hover:border-primary/40 transition-colors">
      <div className="flex items-start justify-between mb-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-lg bg-primary/10 flex items-center justify-center">
            <Dna size={20} className="text-primary" />
          </div>
          <div>
            <h3 className="text-text-primary font-semibold text-sm">
              Token #{tokenId.slice(0, 8)}...
            </h3>
            <p className="text-text-tertiary text-xs">{shortRegistrant}</p>
          </div>
        </div>
        <span className="text-xs text-primary bg-primary/10 px-2 py-1 rounded-full">
          {design.royalty.bps / 100}% royalty
        </span>
      </div>

      <div className="space-y-2 text-sm">
        <div className="flex justify-between">
          <span className="text-text-tertiary">Canonical Hash</span>
          <span className="text-text-secondary font-mono text-xs">{shortHash}</span>
        </div>
        {design.arweaveTx && (
          <div className="flex justify-between items-center">
            <span className="text-text-tertiary">Arweave</span>
            <a
              href={`https://arweave.net/${design.arweaveTx}`}
              target="_blank"
              rel="noopener noreferrer"
              className="text-primary text-xs flex items-center gap-1 hover:underline"
            >
              View <ExternalLink size={12} />
            </a>
          </div>
        )}
        {design.parentTokenIds.length > 0 && (
          <div className="flex justify-between">
            <span className="text-text-tertiary">Forked from</span>
            <span className="text-text-secondary text-xs">
              {design.parentTokenIds.length} parent(s)
            </span>
          </div>
        )}
        <div className="flex justify-between">
          <span className="text-text-tertiary">Registered</span>
          <span className="text-text-secondary text-xs">
            {new Date(Number(design.registeredAt) * 1000).toLocaleDateString()}
          </span>
        </div>
      </div>
    </div>
  );
}

function DesignLookup() {
  const [tokenId, setTokenId] = useState("");
  const chainId = useChainId();
  const registryAddress = getAddress("DesignRegistry", chainId);

  const { data: design, isLoading, isError } = useReadContract({
    address: registryAddress,
    abi: DesignRegistryAbi,
    functionName: "getDesign",
    args: tokenId ? [BigInt(tokenId)] : undefined,
    query: { enabled: tokenId.length >= 10 },
  });

  const { data: isRegistered } = useReadContract({
    address: registryAddress,
    abi: DesignRegistryAbi,
    functionName: "isRegistered",
    args: tokenId ? [BigInt(tokenId)] : undefined,
    query: { enabled: tokenId.length >= 10 },
  });

  return (
    <div className="space-y-6">
      <div className="relative">
        <Search
          size={18}
          className="absolute left-4 top-1/2 -translate-y-1/2 text-text-tertiary"
        />
        <input
          type="text"
          placeholder="Enter token ID (canonical hash)..."
          value={tokenId}
          onChange={(e) => setTokenId(e.target.value)}
          className="w-full rounded-xl border border-border bg-surface pl-12 pr-4 py-3 text-text-primary placeholder:text-text-tertiary focus:outline-none focus:border-primary/60 transition-colors font-mono text-sm"
        />
      </div>

      {isLoading && (
        <div className="text-center py-8 text-text-tertiary">Loading...</div>
      )}

      {isError && tokenId.length >= 10 && (
        <div className="text-center py-8 text-red-400">
          Error fetching design. Check the token ID and try again.
        </div>
      )}

      {design && isRegistered && (
        <DesignCard tokenId={tokenId} design={design as unknown as Design} />
      )}

      {!isRegistered && tokenId.length >= 10 && !isLoading && (
        <div className="text-center py-8 text-text-tertiary">
          No design registered with this token ID.
        </div>
      )}
    </div>
  );
}

export default function RegistryPage() {
  return (
    <div className="min-h-screen bg-base">
      <Navbar />
      <main className="mx-auto max-w-[1280px] px-6 pt-24 pb-16">
        <div className="mb-12">
          <h1 className="text-3xl font-bold text-text-primary mb-2">
            Design Registry
          </h1>
          <p className="text-text-secondary">
            Browse and search registered synthetic biology designs on-chain.
          </p>
        </div>

        <div className="grid gap-8 lg:grid-cols-3">
          <div className="lg:col-span-2">
            <DesignLookup />
          </div>

          <div className="space-y-4">
            <div className="rounded-xl border border-border bg-surface p-6">
              <h3 className="text-text-primary font-semibold mb-3">
                Quick Stats
              </h3>
              <div className="space-y-3 text-sm">
                <div className="flex justify-between">
                  <span className="text-text-tertiary">Network</span>
                  <span className="text-text-secondary">Base Sepolia</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-text-tertiary">Status</span>
                  <span className="text-primary">Testnet</span>
                </div>
              </div>
            </div>

            <a
              href="/register"
              className="block w-full rounded-xl bg-primary py-3 text-center font-semibold text-sm transition-all hover:bg-primary-hover"
              style={{ color: "#0A0B0F" }}
            >
              Register New Design
            </a>
          </div>
        </div>
      </main>
    </div>
  );
}
