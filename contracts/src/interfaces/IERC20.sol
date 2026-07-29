// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @title IERC20 — Minimal ERC-20 interface used by RAIL0.
/// @dev   Some tokens (e.g. USDT on Ethereum mainnet) do not return a bool from
///        `transfer` / `transferFrom`. RAIL0 calls these via low-level `call` and
///        accepts both bool-returning and non-returning tokens. That is also why this
///        is a local minimal interface rather than OpenZeppelin's: OZ declares
///        `transfer` as returning `bool`, which is precisely the assumption RAIL0
///        works around, and importing it would hide that.
///
///        NOTE: only `transfer` is referenced today — `_safeTransfer` builds its
///        calldata with `abi.encodeCall(IERC20.transfer, …)`, which is a type-safe way
///        to get the selector rather than a call through this interface. `balanceOf`,
///        `allowance`, `approve`, `transferFrom` and both events are currently unused.
///        They are kept deliberately: an interface costs nothing at runtime (it emits
///        no bytecode), and declaring the shape RAIL0 assumes of an allowlisted token
///        documents the trust boundary. Prune only if that stops being true.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}
