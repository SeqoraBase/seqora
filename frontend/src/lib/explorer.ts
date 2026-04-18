import { base, baseSepolia } from "wagmi/chains";

/**
 * Returns a Basescan transaction URL for the given chain.
 * Falls back to mainnet Basescan for unknown chain ids.
 */
export function basescanTxUrl(chainId: number, txHash: string): string {
  const host =
    chainId === baseSepolia.id ? "sepolia.basescan.org" : "basescan.org";
  return `https://${host}/tx/${txHash}`;
}

/**
 * Human-readable network label for the given chain id.
 */
export function networkLabel(chainId: number): string {
  if (chainId === base.id) return "Base";
  if (chainId === baseSepolia.id) return "Base Sepolia";
  return `Chain ${chainId}`;
}

/**
 * Returns "Mainnet" or "Testnet" for the known Base chains.
 */
export function networkStatus(chainId: number): "Mainnet" | "Testnet" | "Unknown" {
  if (chainId === base.id) return "Mainnet";
  if (chainId === baseSepolia.id) return "Testnet";
  return "Unknown";
}
