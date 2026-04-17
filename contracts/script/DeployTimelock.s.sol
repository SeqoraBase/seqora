// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title DeployTimelock
/// @notice Deploys an OpenZeppelin TimelockController to serve as the governance owner for all
///         owner-gated Seqora v1 contracts (ScreeningAttestations, LicenseRegistry, RoyaltyRouter,
///         ProvenanceRegistry, BiosafetyCourt). DesignRegistry is ownerless by design and is not
///         covered by this script.
/// @dev Usage:
///   forge script script/DeployTimelock.s.sol:DeployTimelock \
///     --rpc-url base --broadcast --verify -vvvv
///
///   Required env vars:
///     DEPLOYER_PRIVATE_KEY   — funded Base deployer
///     TIMELOCK_MIN_DELAY     — min delay in seconds (e.g. 172800 for 48h)
///     TIMELOCK_PROPOSER      — address granted PROPOSER_ROLE + CANCELLER_ROLE
///                              (typically the deployer EOA or a multisig)
///
///   Role layout chosen:
///     - admin = address(0)               → Timelock is self-administering; no role grants
///                                          without a Timelock'd proposal.
///     - proposers = [TIMELOCK_PROPOSER]  → proposer also gets CANCELLER_ROLE by constructor.
///     - executors = [address(0)]         → open execution after the delay; the delay itself is
///                                          the security boundary. OZ docs note this is safe.
contract DeployTimelock is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 minDelay = vm.envUint("TIMELOCK_MIN_DELAY");
        address proposer = vm.envAddress("TIMELOCK_PROPOSER");

        require(minDelay >= 1 hours, "DeployTimelock: minDelay < 1h looks like a mistake");
        require(proposer != address(0), "DeployTimelock: proposer cannot be zero");

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        // Open execution: grant EXECUTOR_ROLE to address(0) so any account can execute after the
        // delay. Security rests on the delay + proposer-only scheduling, not on the executor set.
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        console2.log("Deployer           :", vm.addr(deployerKey));
        console2.log("Min delay (seconds):", minDelay);
        console2.log("Proposer           :", proposer);
        console2.log("Executors          : [address(0)] (open execution)");
        console2.log("Admin              : address(0) (self-administering)");

        vm.startBroadcast(deployerKey);
        TimelockController timelock = new TimelockController(minDelay, proposers, executors, address(0));
        vm.stopBroadcast();

        console2.log("\n--- TimelockController deployed ---");
        console2.log("Timelock address:", address(timelock));
    }
}
