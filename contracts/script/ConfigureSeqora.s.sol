// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { ScreeningAttestations } from "../src/ScreeningAttestations.sol";
import { RoyaltyRouter } from "../src/RoyaltyRouter.sol";
import { LicenseRegistry } from "../src/LicenseRegistry.sol";
import { SeqoraTypes } from "../src/libraries/SeqoraTypes.sol";

/// @title ConfigureSeqora
/// @notice Post-deployment configuration: register attester, allowlist tokens, wire fee router.
/// @dev Run AFTER DeploySeqora. Fill in deployed addresses below.
///
///   forge script script/ConfigureSeqora.s.sol:ConfigureSeqora \
///     --rpc-url base --broadcast -vvvv
contract ConfigureSeqora is Script {
    // Base mainnet token addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Deployed contract addresses — fill these after running DeploySeqora
        address screening = vm.envAddress("SCREENING_ATTESTATIONS");
        address royaltyRouter = vm.envAddress("ROYALTY_ROUTER");
        address licenseRegistry = vm.envAddress("LICENSE_REGISTRY");

        // Attester address — the EOA or contract that will submit screening attestations
        address attester = vm.envAddress("ATTESTER");

        vm.startBroadcast(deployerKey);

        // 1. Register the initial screening attester
        ScreeningAttestations(screening).registerAttester(attester, SeqoraTypes.ScreenerKind.Other);
        console2.log("Registered attester:", attester);

        // 2. Allowlist tokens on RoyaltyRouter
        RoyaltyRouter(payable(royaltyRouter)).setSupportedToken(USDC, true);
        RoyaltyRouter(payable(royaltyRouter)).setSupportedToken(WETH, true);
        console2.log("Allowlisted USDC:", USDC);
        console2.log("Allowlisted WETH:", WETH);

        // 3. Wire RoyaltyRouter as the fee router on LicenseRegistry
        LicenseRegistry(licenseRegistry).setFeeRouter(royaltyRouter);
        console2.log("Set feeRouter on LicenseRegistry:", royaltyRouter);

        vm.stopBroadcast();

        console2.log("\nPost-deploy config complete.");
    }
}
