// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @title IEIP3009 — Subset of EIP-3009 used by RAIL0.
/// @dev   RAIL0 uses two EIP-3009 functions. In BOTH cases the caller is RAIL0 itself:
///        it is this contract that calls the token, so the token sees
///        `msg.sender == address(RAIL0)`. The payer/payee only ever sign off-chain.
///
///        • `transferWithAuthorization` — used by authorize/charge to pull the PAYER's
///          funds. Signed by the payer. The EIP places NO restriction on who submits it.
///        • `receiveWithAuthorization`  — used by refund to pull the PAYEE's funds.
///          Signed by the payee. The token additionally requires `to == msg.sender`, so
///          it verifies RAIL0 is the intended recipient before moving funds.
///
///        The two require DIFFERENT typed data, despite the shared field list. Each has
///        its own EIP-712 typehash — verified against deployed USDC:
///
///          TransferWithAuthorization  0x7c7c6cdb…1c1a2267
///          ReceiveWithAuthorization   0xd099cc98…aae413de8
///
///        This comment previously claimed the caller was the payer and that both
///        functions took the same signature. Both were wrong, and the second is very
///        likely why authorize/charge use the submitter-unrestricted variant — see
///        issue #35, where that is a front-running hazard. Anyone changing which
///        function a call site uses must also change what the signer signs.
///
///        USDC (FiatTokenV2_2) exposes both on every chain it deploys to.
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
