// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title ITIP20 — Subset of the TIP-20 interface used by RAIL0.
/// @dev   Full spec: https://docs.tempo.xyz/protocol/tip20/spec
interface ITIP20 {
    // ERC-20 core
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    // TIP-20 memo variants
    function transferWithMemo(address to, uint256 amount, bytes32 memo) external;
    function transferFromWithMemo(
        address from,
        address to,
        uint256 amount,
        bytes32 memo
    ) external returns (bool);

    // EIP-2612 Permit (TIP-1004, T2)
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    // Events
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event TransferWithMemo(
        address indexed from, address indexed to, uint256 amount, bytes32 indexed memo
    );
}
