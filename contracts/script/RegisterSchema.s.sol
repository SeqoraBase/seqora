// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { IEAS } from "eas-contracts/IEAS.sol";
import { ISchemaRegistry } from "eas-contracts/ISchemaRegistry.sol";
import { ISchemaResolver } from "eas-contracts/resolver/ISchemaResolver.sol";

/// @title RegisterSchema
/// @notice Registers the Seqora screening schema on EAS (Base Sepolia).
/// @dev Usage:
///   forge script script/RegisterSchema.s.sol:RegisterSchema \
///     --rpc-url base_sepolia --broadcast -vvvv
///
///   Required env: DEPLOYER_PRIVATE_KEY, BASE_SEPOLIA_RPC_URL
///   Output: the schema UID — paste into .env as SCREENING_SCHEMA_UID
contract RegisterSchema is Script {
    address constant EAS = 0x4200000000000000000000000000000000000021;

    // Seqora screening schema — must match abi.decode in ScreeningAttestations.isScreened()
    string constant SCHEMA =
        "bytes32 canonicalHash, address registrant, uint8 screenerKind, uint64 screenedAt, bytes32 reportHash";

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        IEAS eas = IEAS(EAS);
        ISchemaRegistry registry = eas.getSchemaRegistry();
        console2.log("SchemaRegistry:", address(registry));

        vm.startBroadcast(deployerKey);

        bytes32 uid = registry.register(SCHEMA, ISchemaResolver(address(0)), true);

        vm.stopBroadcast();

        console2.log("Schema UID:", vm.toString(uid));
        console2.log("Add to .env: SCREENING_SCHEMA_UID=", vm.toString(uid));
    }
}
