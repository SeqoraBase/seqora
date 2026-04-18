// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BiosafetyCourt } from "../src/BiosafetyCourt.sol";

/// @title RotateSafetyCouncil
/// @notice Pre-handover rotation: points `BiosafetyCourt.safetyCouncil` at a distinct Safe so the
///         dual-key invariant holds before ownership moves to the Timelock.
/// @dev Mainnet was initialized with `safetyCouncil == governance == deployer EOA` (the M-01 guard
///      was added after launch, so initialize() didn't revert at the time). Before we can run the
///      Timelock handover safely, we must rotate `safetyCouncil` to an address distinct from the
///      current owner — otherwise the handover's `_transferOwnership` guard (which refuses
///      `newOwner == safetyCouncil`) will not fire, but dual-key is still collapsed.
///
///   forge script script/RotateSafetyCouncil.s.sol:RotateSafetyCouncil \
///     --rpc-url base --broadcast -vvvv
///
///   Required env vars:
///     DEPLOYER_PRIVATE_KEY  — current owner of BiosafetyCourt
///     BIOSAFETY_COURT       — Base mainnet proxy address
///     NEW_SAFETY_COUNCIL    — incoming Safety Council Safe / multisig (≠ current owner)
contract RotateSafetyCouncil is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address courtAddr = vm.envAddress("BIOSAFETY_COURT");
        address newCouncil = vm.envAddress("NEW_SAFETY_COUNCIL");

        require(courtAddr != address(0), "RotateSafetyCouncil: BIOSAFETY_COURT cannot be zero");
        require(courtAddr.code.length > 0, "RotateSafetyCouncil: BIOSAFETY_COURT is not a contract");
        require(newCouncil != address(0), "RotateSafetyCouncil: NEW_SAFETY_COUNCIL cannot be zero");
        require(newCouncil.code.length > 0, "RotateSafetyCouncil: NEW_SAFETY_COUNCIL must be a contract (Safe)");

        BiosafetyCourt court = BiosafetyCourt(payable(courtAddr));
        address currentOwner = Ownable(courtAddr).owner();
        address currentCouncil = court.safetyCouncil();

        require(currentOwner == deployer, "RotateSafetyCouncil: deployer does not own BiosafetyCourt");
        require(newCouncil != currentOwner, "RotateSafetyCouncil: new council equals owner (guard will revert)");
        require(newCouncil != currentCouncil, "RotateSafetyCouncil: new council equals current council (no-op)");

        console2.log("Deployer       :", deployer);
        console2.log("BiosafetyCourt :", courtAddr);
        console2.log("Current owner  :", currentOwner);
        console2.log("Current council:", currentCouncil);
        console2.log("New council    :", newCouncil);

        vm.startBroadcast(deployerKey);
        court.setSafetyCouncil(newCouncil);
        vm.stopBroadcast();

        require(court.safetyCouncil() == newCouncil, "Post-check: safetyCouncil did not update");
        require(Ownable(courtAddr).owner() == deployer, "Post-check: owner unexpectedly changed");

        console2.log("\n--- Safety Council rotated ---");
        console2.log("New safetyCouncil:", newCouncil);
        console2.log("Next step: run TransferOwnershipToTimelock.s.sol");
    }
}
