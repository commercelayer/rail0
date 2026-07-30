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
/// @dev   RAIL0 uses a single EIP-3009 function, `receiveWithAuthorization`, for every
///        signature-funded operation: authorize/charge (the payer signs) and refund
///        (the payee signs). The signer signs an EIP-712 `ReceiveWithAuthorization`
///        typed-data message over the TOKEN's domain — a typehash distinct from
///        `TransferWithAuthorization`, despite the identical field list.
///
///        The receive variant is deliberate: the token enforces `msg.sender == to`,
///        so a signature naming this contract as `to` can only be spent through this
///        contract. `transferWithAuthorization` has no submitter restriction — anyone
///        could lift a pending signature from the mempool and submit it straight to
///        the token, stranding the funds here with no payment state (#35). It is
///        intentionally absent from this interface so no call site can reach for it.
///
///        USDC (FiatTokenV2_2) supports `receiveWithAuthorization` on every chain it
///        deploys to.
interface IEIP3009 {
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
