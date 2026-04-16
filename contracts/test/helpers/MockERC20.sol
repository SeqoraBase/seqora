// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockERC20
/// @notice Minimal ERC-20 for RoyaltyRouter tests. Standard behaviour + `mint` helper + toggles.
/// @dev Not production-safe. Used only inside `contracts/test/`.
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // --- hostile-token switches (default off = well-behaved) ---
    bool public failTransfer;
    bool public failTransferFrom;
    bool public returnFalseOnTransfer;
    bool public returnFalseOnTransferFrom;
    /// @dev If set, `transferFrom` re-enters `target` with `reentryData` before doing the transfer.
    address public reentryTarget;
    bytes public reentryData;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    // -------------------------------------------------------------------------
    // Test control surface
    // -------------------------------------------------------------------------

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        _balances[from] -= amount;
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function setFailTransfer(bool v) external {
        failTransfer = v;
    }

    function setFailTransferFrom(bool v) external {
        failTransferFrom = v;
    }

    function setReturnFalseOnTransfer(bool v) external {
        returnFalseOnTransfer = v;
    }

    function setReturnFalseOnTransferFrom(bool v) external {
        returnFalseOnTransferFrom = v;
    }

    function armReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function disarmReentry() external {
        reentryTarget = address(0);
        delete reentryData;
    }

    // -------------------------------------------------------------------------
    // ERC-20
    // -------------------------------------------------------------------------

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address a) external view returns (uint256) {
        return _balances[a];
    }

    function allowance(address o, address s) external view returns (uint256) {
        return _allowances[o][s];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (failTransfer) revert("MockERC20: transfer failed");
        if (returnFalseOnTransfer) return false;
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (reentryTarget != address(0)) {
            // Reentrancy hook — fire before the transfer so guards trigger.
            address target = reentryTarget;
            bytes memory data = reentryData;
            // Single-shot; disarm so the recursive call can succeed or hit its own guard.
            reentryTarget = address(0);
            delete reentryData;
            (bool ok, bytes memory ret) = target.call(data);
            // Bubble revert data if any.
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        if (failTransferFrom) revert("MockERC20: transferFrom failed");
        if (returnFalseOnTransferFrom) return false;

        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "MockERC20: insufficient allowance");
            _allowances[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 bal = _balances[from];
        require(bal >= amount, "MockERC20: insufficient balance");
        unchecked {
            _balances[from] = bal - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
