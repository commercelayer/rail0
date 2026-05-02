// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IERC20 — Minimal ERC-20 interface used by RAIL0.
/// @dev   Some tokens (e.g. USDT on Ethereum mainnet) do not return a bool from
///        `transfer` / `transferFrom`. RAIL0 calls these via low-level `call` and
///        accepts both bool-returning and non-returning tokens.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}

/// @title IERC20Permit — EIP-2612 permit interface.
/// @dev   Optional. Tokens without permit cause `permitAnd*` wrappers to skip the
///        permit step (caught via try/catch) and fall back to standing approval.
interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
