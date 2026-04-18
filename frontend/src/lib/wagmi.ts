import { WagmiAdapter } from "@reown/appkit-adapter-wagmi";
import {
  base as appKitBase,
  baseSepolia as appKitBaseSepolia,
} from "@reown/appkit/networks";
import { createConfig, http } from "wagmi";
import { coinbaseWallet, injected, metaMask } from "wagmi/connectors";
import { base, baseSepolia } from "wagmi/chains";

const isTestnet = process.env.NEXT_PUBLIC_CHAIN === "testnet";
export const activeChain = isTestnet ? baseSepolia : base;

// Phantom is intentionally NOT listed here: its EVM provider surfaces Solana
// accounts and prompts Solana-only users to sign EVM transactions.
const walletConnectors = [
  metaMask(),
  coinbaseWallet({ appName: "Seqora", preference: { options: "all" } }),
  injected({ shimDisconnect: false, target: "rabby" }),
  injected({ shimDisconnect: true }),
];

const activeAppKitNetwork = isTestnet ? appKitBaseSepolia : appKitBase;
const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID;

export const wagmiAdapter = projectId
  ? new WagmiAdapter({
      connectors: walletConnectors,
      multiInjectedProviderDiscovery: false,
      projectId,
      networks: [activeAppKitNetwork],
      ssr: true,
      transports: { [activeAppKitNetwork.id]: http() },
    })
  : undefined;

export const appKitConfig = wagmiAdapter
  ? {
      adapters: [wagmiAdapter],
      projectId: projectId!,
      metadata: {
        name: "Seqora",
        description: "On-chain registry for engineered DNA designs",
        url: "https://seqora.xyz",
        icons: [],
      },
      networks: [activeAppKitNetwork] as [typeof activeAppKitNetwork],
      themeMode: "dark" as const,
      features: {
        analytics: true,
        email: false,
        socials: [],
      },
    }
  : null;

const fallbackConfig = isTestnet
  ? createConfig({
      chains: [baseSepolia],
      connectors: walletConnectors,
      multiInjectedProviderDiscovery: false,
      ssr: true,
      transports: { [baseSepolia.id]: http() },
    })
  : createConfig({
      chains: [base],
      connectors: walletConnectors,
      multiInjectedProviderDiscovery: false,
      ssr: true,
      transports: { [base.id]: http() },
    });

export const config = wagmiAdapter?.wagmiConfig ?? fallbackConfig;
