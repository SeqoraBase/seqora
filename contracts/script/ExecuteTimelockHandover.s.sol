// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title ExecuteTimelockHandover
/// @notice Phase-2 of the governance handover. Executes the batched acceptOwnership operation
///         scheduled by TransferOwnershipToTimelock, after `TIMELOCK_MIN_DELAY` has elapsed.
/// @dev Executor role was granted to `address(0)` at Timelock deploy time → any EOA can call
///      executeBatch. Use the deployer key for traceability, but it's not required.
///
///   forge script script/ExecuteTimelockHandover.s.sol:ExecuteTimelockHandover \
///     --rpc-url base --broadcast -vvvv
///
///   Required env vars: same set as TransferOwnershipToTimelock (TIMELOCK, TIMELOCK_SALT, and
///   the 5 contract addresses). Uses DEPLOYER_PRIVATE_KEY as the executor for gas payment.
contract ExecuteTimelockHandover is Script {
    function run() external {
        uint256 executorKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address timelock = vm.envAddress("TIMELOCK");
        bytes32 salt = vm.envBytes32("TIMELOCK_SALT");

        address[5] memory contracts = [
            vm.envAddress("SCREENING_ATTESTATIONS"),
            vm.envAddress("LICENSE_REGISTRY"),
            vm.envAddress("ROYALTY_ROUTER"),
            vm.envAddress("PROVENANCE_REGISTRY"),
            vm.envAddress("BIOSAFETY_COURT")
        ];
        string[5] memory names =
            ["ScreeningAttestations", "LicenseRegistry", "RoyaltyRouter", "ProvenanceRegistry", "BiosafetyCourt"];

        address[] memory targets = new address[](contracts.length);
        uint256[] memory values = new uint256[](contracts.length);
        bytes[] memory payloads = new bytes[](contracts.length);
        for (uint256 i = 0; i < contracts.length; i++) {
            targets[i] = contracts[i];
            values[i] = 0;
            payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        }

        TimelockController tc = TimelockController(payable(timelock));
        bytes32 opId = tc.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        require(tc.isOperationReady(opId), "ExecuteHandover: operation not ready (delay not elapsed or not scheduled)");

        console2.log("Executor    :", vm.addr(executorKey));
        console2.log("Timelock    :", timelock);
        console2.log("Operation ID:", vm.toString(opId));

        vm.startBroadcast(executorKey);
        tc.executeBatch(targets, values, payloads, bytes32(0), salt);
        vm.stopBroadcast();

        // Post-flight: each contract's owner must now be the timelock and pendingOwner cleared.
        for (uint256 i = 0; i < contracts.length; i++) {
            require(
                Ownable(contracts[i]).owner() == timelock,
                string.concat("Post-check: ", names[i], " owner is not timelock")
            );
            require(
                Ownable2Step(contracts[i]).pendingOwner() == address(0),
                string.concat("Post-check: ", names[i], " pendingOwner not cleared")
            );
            console2.log(names[i], "-> owned by timelock");
        }

        console2.log("\n--- Handover complete ---");
    }
}
