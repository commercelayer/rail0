// SPDX-License-Identifier: MIT
pragma solidity =0.8.31;

/// @title IEIP3009 — Subset of EIP-3009 used by RAIL0.
/// @dev   RAIL0 uses ONE EIP-3009 function, `receiveWithAuthorization`, for every
///        signature-funded operation: authorize and charge (the payer signs, to pull the
///        payer's funds) and refund (the payee signs, to pull the payee's). In all three
///        the caller is RAIL0 itself — it is this contract that calls the token, so the
///        token sees `msg.sender == address(RAIL0)`. The payer/payee only ever sign
///        off-chain.
///
///        The RECEIVE variant, in all three, is the security property. The token requires
///        `to == msg.sender`, and every RAIL0 signature names this contract as `to`, so a
///        signature is only ever spendable THROUGH this contract: lifted from a pending
///        transaction it is worthless to anyone else.
///
///        `transferWithAuthorization` is deliberately ABSENT from this interface — not
///        merely unused. The EIP places no restriction on who submits it, so a signature
///        made for it can be taken from the mempool and sent straight to the token by
///        anyone: the funds land here with no `PaymentState` ever created, and no payout
///        path can reach them. That is issue #35, and authorize/charge used to be written
///        that way. Keeping the declaration out means no call site can reach for it again
///        without re-adding it here, where this comment is.
///
///        The two functions require DIFFERENT typed data, despite the shared field list.
///        Each has its own EIP-712 typehash — verified against deployed USDC:
///
///          TransferWithAuthorization  0x7c7c6cdb…1c1a2267
///          ReceiveWithAuthorization   0xd099cc98…aae413de8
///
///        So switching which function a call site uses REQUIRES changing what the signer
///        signs — a `TransferWithAuthorization` signature presented to
///        `receiveWithAuthorization` recovers a different signer and the token reverts.
///        Off-chain integrators sign `ReceiveWithAuthorization` for all three operations.
///
///        USDC (FiatTokenV2_2) exposes `receiveWithAuthorization` on every chain it
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
