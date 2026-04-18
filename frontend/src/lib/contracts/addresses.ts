import { getAddress as toChecksumAddress } from "viem";
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
    // EIP-55 checksummed forms, derived via viem's getAddress().
    DesignRegistry: toChecksumAddress(
      "0x8e8057b5dc94cec2155d0da07e6cc9231d851cad"
    ),
    ScreeningAttestations: toChecksumAddress(
      "0x47612f007bcb1f640c9e8643c3990df9c7ce6dab"
    ),
    LicenseRegistry: toChecksumAddress(
      "0x07323af159c3b2319c89b8dec7147df3eeb8115f"
    ),
    RoyaltyRouter: toChecksumAddress(
      "0x22ca9ccc81ea63881021d643d1e9490d060e40c8"
    ),
    ProvenanceRegistry: toChecksumAddress(
      "0xf687adfafa55299e84f4115be7ab97af25a08f20"
    ),
    BiosafetyCourt: toChecksumAddress(
      "0x96f33aa188ac9148ed89e55d6798e2c58ae2207c"
    ),
  },
};

export function getAddress(
  contract: keyof ContractAddresses,
  chainId: number
): `0x${string}` {
  return addresses[chainId]?.[contract] ?? ZERO;
}
