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

/// @title IEIP3009 — Subset of EIP-3009 (TransferWithAuthorization) used by RAIL0.
/// @dev   Buyer-initiated payments require this interface on the token. The buyer signs
///        an EIP-712 `TransferWithAuthorization` digest off-chain; RAIL0 calls
///        `transferWithAuthorization` to pull funds. No allowance state is touched.
///        USDC supports EIP-3009 on every chain it deploys to. Plasma's USDT0 supports it.
interface IEIP3009 {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
}
