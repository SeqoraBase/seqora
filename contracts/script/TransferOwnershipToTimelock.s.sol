// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title TransferOwnershipToTimelock
/// @notice Phase-1 of the governance handover. Transfers ownership of the 5 owner-gated Seqora
///         contracts to the deployed TimelockController AND schedules a batched acceptOwnership
///         operation on the Timelock. After `TIMELOCK_MIN_DELAY` elapses, run
///         `ExecuteTimelockHandover.s.sol` to finalize.
/// @dev Seqora owner-gated contracts use OZ Ownable2Step, so `transferOwnership` only sets the
///      pending owner. The Timelock (as the pending owner) must subsequently call
///      `acceptOwnership` on each contract, and that call must itself flow through the Timelock
///      delay — which is exactly the point. DesignRegistry is ownerless and intentionally omitted.
///
///   forge script script/TransferOwnershipToTimelock.s.sol:TransferOwnershipToTimelock \
///     --rpc-url base --broadcast -vvvv
///
///   Required env vars:
///     DEPLOYER_PRIVATE_KEY     — current owner of all 5 contracts
///     TIMELOCK                 — deployed TimelockController address
///     TIMELOCK_MIN_DELAY       — schedule delay in seconds (must be >= timelock minDelay)
///     TIMELOCK_SALT            — unique salt for this handover (bytes32, any value you choose)
///     SCREENING_ATTESTATIONS   — Base mainnet address
///     LICENSE_REGISTRY         — Base mainnet address (proxy)
///     ROYALTY_ROUTER           — Base mainnet address
///     PROVENANCE_REGISTRY      — Base mainnet address
///     BIOSAFETY_COURT          — Base mainnet address (proxy)
contract TransferOwnershipToTimelock is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address timelock = vm.envAddress("TIMELOCK");
        uint256 minDelay = vm.envUint("TIMELOCK_MIN_DELAY");
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

        require(timelock != address(0), "TransferOwnership: timelock cannot be zero");
        require(timelock.code.length > 0, "TransferOwnership: timelock is not a contract");
        require(salt != bytes32(0), "TransferOwnership: salt must be non-zero");

        // Pre-flight: deployer must currently own each contract.
        for (uint256 i = 0; i < contracts.length; i++) {
            require(
                Ownable(contracts[i]).owner() == deployer,
                string.concat("TransferOwnership: deployer does not own ", names[i])
            );
        }

        console2.log("Deployer:", deployer);
        console2.log("Timelock:", timelock);
        console2.log("Salt    :", vm.toString(salt));
        console2.log("");

        // Build the batch that the Timelock will execute after the delay: one acceptOwnership
        // call per contract. Targets and payloads line up 1:1 with `contracts`.
        address[] memory targets = new address[](contracts.length);
        uint256[] memory values = new uint256[](contracts.length);
        bytes[] memory payloads = new bytes[](contracts.length);
        for (uint256 i = 0; i < contracts.length; i++) {
            targets[i] = contracts[i];
            values[i] = 0;
            payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        }

        vm.startBroadcast(deployerKey);

        // Step 1: transferOwnership on each contract — makes timelock the pending owner.
        for (uint256 i = 0; i < contracts.length; i++) {
            Ownable(contracts[i]).transferOwnership(timelock);
            console2.log(names[i], "pending owner set to timelock");
        }

        // Step 2: schedule the batched acceptOwnership operation on the Timelock. After
        // `minDelay`, any address can call executeBatch to finalize.
        TimelockController(payable(timelock)).scheduleBatch(targets, values, payloads, bytes32(0), salt, minDelay);

        vm.stopBroadcast();

        // Post-flight: each contract should now have deployer as owner and timelock as pending owner.
        for (uint256 i = 0; i < contracts.length; i++) {
            require(
                Ownable(contracts[i]).owner() == deployer,
                string.concat("Post-check: ", names[i], " owner unexpectedly changed")
            );
            require(
                Ownable2Step(contracts[i]).pendingOwner() == timelock,
                string.concat("Post-check: ", names[i], " pending owner is not timelock")
            );
        }

        bytes32 opId =
            TimelockController(payable(timelock)).hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        console2.log("\n--- Handover scheduled ---");
        console2.log("Operation ID  :", vm.toString(opId));
        console2.log("Ready at (ts) :", block.timestamp + minDelay);
        console2.log("Run script/ExecuteTimelockHandover.s.sol after that timestamp to finalize.");
    }
}
