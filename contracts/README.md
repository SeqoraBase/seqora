# Seqora Contracts

Production Solidity contracts for the Seqora protocol. Six v1 contracts with full test suites, built and tested with Foundry.

## Prerequisites

- [Foundry](https://getfoundry.sh/) (latest stable)
- Git (for submodule dependencies)

## Setup

```bash
git clone --recursive https://github.com/SeqoraBase/seqora.git
cd seqora/contracts
forge build
```

If you already cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

## Testing

```bash
make test               # or: forge test -vv
forge test -vvv         # verbose output with traces
forge test --mt test_X  # run a single test by name
```

## Coverage

```bash
make coverage           # or: forge coverage --ir-minimum --report summary
```

Target: 95% or higher on lines and branches for all production contracts.

## Formatting

```bash
make fmt                # auto-fix
make fmt-check          # CI enforces this
```

## Gas Snapshots

```bash
make snapshot           # generates .gas-snapshot
```

## Contract Architecture

| Contract | Type | Description |
|---|---|---|
| DesignRegistry | ERC-1155 (immutable) | Tokenizes SBOL3 designs. Content-addressed, fork-tracked. |
| ScreeningAttestations | Ownable2Step | EAS-backed biosafety attestation gate. |
| LicenseRegistry | ERC-721 + UUPS | Story Protocol-compatible license NFTs with PIL flags. |
| RoyaltyRouter | IHooks (Uni v4) | EIP-2981 + Uniswap v4 hook enforcing royalty splits at swap. |
| ProvenanceRegistry | EIP-712 (immutable) | Signed model cards + wet-lab attestations for chain of custody. |
| BiosafetyCourt | UUPS | Kleros-style disputes, staked reviewer bonds, Safety Council freeze. |

## Dependencies

| Library | Version | Purpose |
|---|---|---|
| OpenZeppelin Contracts | v5.1.0 | ERC standards, access control, upgradeability |
| OpenZeppelin Upgradeable | v5.1.0 | UUPS proxy parents |
| Solmate | v7 (branch) | Gas-optimized ERC20/auth primitives |
| forge-std | v1.15.0 | Testing framework |
| eas-contracts | master | EAS interface for ScreeningAttestations |
| Uniswap v4-core | main | PoolManager, IHooks for RoyaltyRouter |
| Uniswap v4-periphery | main | Hook utilities |

## Key Design Decisions

- **CEI pattern everywhere.** All state mutations follow checks-effects-interactions to prevent reentrancy.
- **Custom errors only.** No `require` with string messages. Gas-efficient, ABI-decodable errors throughout.
- **Ownable2Step with renounceOwnership disabled.** Two-step ownership transfer on all ownable contracts. Accidental renouncement is blocked.
- **UUPS upgradability is selective.** Only LicenseRegistry and BiosafetyCourt use UUPS proxies. DesignRegistry, ProvenanceRegistry, ScreeningAttestations, and RoyaltyRouter are immutable by design.
- **EIP-7201 namespaced storage.** All upgradeable contracts use OpenZeppelin v5 namespaced storage layout to prevent slot collisions.
- **Compiler settings:** `via_ir` enabled, optimizer at 200 runs, targeting the Cancun EVM version.

## Deployment

### Base Sepolia

1. Copy `.env.example` to `.env` and fill in values
2. Fund the deployer wallet with Base Sepolia ETH
3. Register the EAS screening schema:
   ```bash
   make deploy-schema
   ```
4. Copy the schema UID output into `.env` as `SCREENING_SCHEMA_UID`
5. Deploy all 6 contracts:
   ```bash
   make deploy
   ```
6. Run post-deploy configuration (register attester, allowlist tokens):
   ```bash
   # Add deployed addresses to .env first:
   # SCREENING_ATTESTATIONS, ROYALTY_ROUTER, LICENSE_REGISTRY, ATTESTER
   forge script script/ConfigureSeqora.s.sol:ConfigureSeqora \
     --rpc-url base_sepolia --broadcast -vvvv
   ```

### Scripts

| Script | Purpose |
|---|---|
| `RegisterSchema.s.sol` | Registers the Seqora screening schema on EAS |
| `DeploySeqora.s.sol` | Deploys all 6 contracts with proxies and CREATE2 mining |
| `ConfigureSeqora.s.sol` | Post-deploy: register attester, allowlist tokens, wire fee router |

## Audits

Internal audit reports generated during development are available on request. See [SECURITY.md](../SECURITY.md) for the vulnerability disclosure policy.
