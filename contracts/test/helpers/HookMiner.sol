// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Hooks } from "v4-core/libraries/Hooks.sol";

/// @title HookMiner
/// @notice Minimal CREATE2 salt miner for Uniswap v4 hook address permission bits.
/// @dev Extracted from `RoyaltyRouter.smoke.t.sol`. The public `HookMiner` is not exported from
///      v4-periphery (moved to template repos), so we keep this tiny internal helper alongside
///      the tests that need to deploy hooks at addresses whose trailing 14 bits encode a specific
///      permission set (`Hooks.ALL_HOOK_MASK`). Pure; no state.
library HookMiner {
    /// @notice Linear-scan the salt space starting from 0 until a salt whose CREATE2-predicted
    ///         address has trailing bits exactly equal to `targetFlags`.
    /// @dev Reverts if no match found within `maxIters` tries. 200_000 is plenty for the 8-bit
    ///      permission masks Seqora uses (0xC8), but callers can widen for exotic flag sets.
    /// @param deployer Address that will perform the CREATE2 (usually the test contract).
    /// @param creationCode `abi.encodePacked(type(Contract).creationCode, abi.encode(args...))`.
    /// @param targetFlags Permission bitmask the trailing 14 bits of the address must equal.
    /// @return addr The predicted CREATE2 deploy address.
    /// @return salt The winning salt.
    function find(address deployer, bytes memory creationCode, uint160 targetFlags)
        internal
        pure
        returns (address addr, bytes32 salt)
    {
        return find(deployer, creationCode, targetFlags, 0, 200_000);
    }

    /// @notice Same as `find` but with custom salt search range.
    function find(address deployer, bytes memory creationCode, uint160 targetFlags, uint256 startSalt, uint256 maxIters)
        internal
        pure
        returns (address addr, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 s = startSalt; s < startSalt + maxIters; s++) {
            bytes32 candidate = bytes32(s);
            address predicted = predict(deployer, candidate, initCodeHash);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == targetFlags) {
                return (predicted, candidate);
            }
        }
        revert("HookMiner: no salt found");
    }

    /// @notice CREATE2 address prediction. Pure keccak of the standard CREATE2 preimage.
    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, initCodeHash)))));
    }
}
