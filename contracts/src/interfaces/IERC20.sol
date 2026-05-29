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

/// @title IEIP3009 — Subset of EIP-3009 used by RAIL0.
/// @dev   RAIL0 uses two EIP-3009 functions:
///        • `transferWithAuthorization` — called by the payer (sender) for authorize/charge.
///          The payer signs off-chain; anyone submits.
///        • `receiveWithAuthorization`  — called by the payee (recipient) for refund.
///          The payee signs off-chain; anyone submits. msg.sender must equal `to` (the
///          RAIL0 contract), so the token verifies that the contract is the intended
///          recipient before pulling funds from the payee's wallet.
///        Both functions require the same EIP-712 `TransferWithAuthorization` typed-data
///        signature — the only difference is who submits the transaction.
///        USDC supports both functions on every chain it deploys to.
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

    function receiveWithAuthorization(
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
