import { base, baseSepolia } from "wagmi/chains";

type ContractAddresses = {
  DesignRegistry: `0x${string}`;
  ScreeningAttestations: `0x${string}`;
  LicenseRegistry: `0x${string}`;
  RoyaltyRouter: `0x${string}`;
  ProvenanceRegistry: `0x${string}`;
  BiosafetyCourt: `0x${string}`;
};

const ZERO = "0x0000000000000000000000000000000000000000" as const;

export const addresses: Record<number, ContractAddresses> = {
  [baseSepolia.id]: {
    DesignRegistry: ZERO,
    ScreeningAttestations: ZERO,
    LicenseRegistry: ZERO,
    RoyaltyRouter: ZERO,
    ProvenanceRegistry: ZERO,
    BiosafetyCourt: ZERO,
  },
  [base.id]: {
    DesignRegistry: ZERO,
    ScreeningAttestations: ZERO,
    LicenseRegistry: ZERO,
    RoyaltyRouter: ZERO,
    ProvenanceRegistry: ZERO,
    BiosafetyCourt: ZERO,
  },
};

export function getAddress(
  contract: keyof ContractAddresses,
  chainId: number
): `0x${string}` {
  return addresses[chainId]?.[contract] ?? ZERO;
}
