// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IEAS } from "eas-contracts/IEAS.sol";

import { ScreeningAttestations } from "../src/ScreeningAttestations.sol";
import { IScreeningAttestations } from "../src/interfaces/IScreeningAttestations.sol";
import { DesignRegistry } from "../src/DesignRegistry.sol";
import { IDesignRegistry } from "../src/interfaces/IDesignRegistry.sol";
import { LicenseRegistry } from "../src/LicenseRegistry.sol";
import { RoyaltyRouter } from "../src/RoyaltyRouter.sol";
import { ProvenanceRegistry } from "../src/ProvenanceRegistry.sol";
import { BiosafetyCourt } from "../src/BiosafetyCourt.sol";

/// @title DeploySeqora
/// @notice Deploys all 6 v1 contracts to Base mainnet in dependency order.
/// @dev Usage:
///   1. Copy .env.example → .env and fill in values.
///   2. forge script script/DeploySeqora.s.sol:DeploySeqora \
///        --rpc-url base --broadcast --verify -vvvv
///
///   Required env vars:
///     DEPLOYER_PRIVATE_KEY   — funded Base deployer
///     BASE_RPC_URL           — RPC endpoint
///     BASESCAN_API_KEY       — for contract verification (Etherscan API V2)
///     SCREENING_SCHEMA_UID   — EAS schema UID (register first via EAS UI)
///     GOVERNANCE             — governance/owner address (multisig or EOA)
///     TREASURY               — treasury recipient
///     SAFETY_COUNCIL         — safety council address (BiosafetyCourt dual-key)
///     BASE_URI               — ERC-1155 metadata URI template
contract DeploySeqora is Script {
    // Base mainnet canonical addresses
    // EAS: https://docs.attest.org/docs/quick--start/contracts#base
    address constant EAS = 0x4200000000000000000000000000000000000021;
    // PoolManager: https://docs.uniswap.org/contracts/v4/concepts/PoolManager
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    // RoyaltyRouter hook permission bits: beforeSwap | afterSwap | beforeSwapReturnDelta
    uint160 constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address governance = vm.envAddress("GOVERNANCE");
        address treasury = vm.envAddress("TREASURY");
        address safetyCouncil = vm.envAddress("SAFETY_COUNCIL");
        bytes32 schemaUID = vm.envBytes32("SCREENING_SCHEMA_UID");
        string memory baseUri = vm.envString("BASE_URI");

        console2.log("Deployer:", deployer);
        console2.log("Governance:", governance);
        console2.log("Treasury:", treasury);

        vm.startBroadcast(deployerKey);

        // 1. ScreeningAttestations — no dependencies
        ScreeningAttestations screening = new ScreeningAttestations(IEAS(EAS), schemaUID, governance);
        console2.log("ScreeningAttestations:", address(screening));

        // 2. DesignRegistry — depends on ScreeningAttestations
        DesignRegistry designRegistry = new DesignRegistry(baseUri, IScreeningAttestations(address(screening)));
        console2.log("DesignRegistry:", address(designRegistry));

        // 3. LicenseRegistry — UUPS proxy, depends on DesignRegistry
        LicenseRegistry licenseImpl = new LicenseRegistry();
        bytes memory licenseInit =
            abi.encodeCall(LicenseRegistry.initialize, (IDesignRegistry(address(designRegistry)), governance));
        ERC1967Proxy licenseProxy = new ERC1967Proxy(address(licenseImpl), licenseInit);
        console2.log("LicenseRegistry (impl):", address(licenseImpl));
        console2.log("LicenseRegistry (proxy):", address(licenseProxy));

        // 4. RoyaltyRouter — CREATE2 salt mining for hook address
        bytes memory routerCreationCode = abi.encodePacked(
            type(RoyaltyRouter).creationCode,
            abi.encode(IDesignRegistry(address(designRegistry)), treasury, IPoolManager(POOL_MANAGER), governance)
        );
        // Forge routes inline assembly create2 through the deterministic CREATE2 deployer.
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address routerAddr, bytes32 routerSalt) = _mineSalt(create2Deployer, routerCreationCode, HOOK_FLAGS);
        RoyaltyRouter router;
        assembly ("memory-safe") {
            router := create2(0, add(routerCreationCode, 0x20), mload(routerCreationCode), routerSalt)
        }
        require(address(router) == routerAddr, "CREATE2 mismatch");
        console2.log("RoyaltyRouter:", address(router));

        // 5. ProvenanceRegistry — depends on DesignRegistry
        ProvenanceRegistry provenance = new ProvenanceRegistry(IDesignRegistry(address(designRegistry)), governance);
        console2.log("ProvenanceRegistry:", address(provenance));

        // 6. BiosafetyCourt — UUPS proxy, depends on DesignRegistry
        BiosafetyCourt courtImpl = new BiosafetyCourt();
        bytes memory courtInit = abi.encodeCall(
            BiosafetyCourt.initialize, (IDesignRegistry(address(designRegistry)), treasury, safetyCouncil, governance)
        );
        ERC1967Proxy courtProxy = new ERC1967Proxy(address(courtImpl), courtInit);
        console2.log("BiosafetyCourt (impl):", address(courtImpl));
        console2.log("BiosafetyCourt (proxy):", address(courtProxy));

        vm.stopBroadcast();

        // Summary
        console2.log("\n--- Deployment Summary (Base) ---");
        console2.log("ScreeningAttestations :", address(screening));
        console2.log("DesignRegistry        :", address(designRegistry));
        console2.log("LicenseRegistry proxy :", address(licenseProxy));
        console2.log("RoyaltyRouter         :", address(router));
        console2.log("ProvenanceRegistry    :", address(provenance));
        console2.log("BiosafetyCourt proxy  :", address(courtProxy));
    }

    function _mineSalt(address deployer, bytes memory creationCode, uint160 targetFlags)
        internal
        pure
        returns (address addr, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 s; s < 500_000; s++) {
            bytes32 candidate = bytes32(s);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, candidate, initCodeHash))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == targetFlags) {
                return (predicted, candidate);
            }
        }
        revert("No valid CREATE2 salt found");
    }
}
