// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title PackedUserOperation — ERC-4337 v0.7 user operation layout.
/// @dev   `accountGasLimits` packs `verificationGasLimit` (high 128 bits) and
///        `callGasLimit` (low 128 bits). `gasFees` packs `maxPriorityFeePerGas`
///        (high) and `maxFeePerGas` (low).
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

/// @title IEntryPoint — Subset of ERC-4337 v0.7 EntryPoint used by RAIL0Sponsor.
interface IEntryPoint {
    function depositTo(address account) external payable;
    function withdrawTo(address payable withdrawAddress, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @title IPaymaster — ERC-4337 v0.7 paymaster interface.
/// @dev   Function names are dictated by the standard; the EntryPoint calls these
///        exact selectors on every paymaster.
interface IPaymaster {
    enum PostOpMode {
        opSucceeded,
        opReverted,
        postOpReverted
    }

    /// @return context Encoded data passed to `postOp`.
    /// @return validationData Packed `(sigFailed | validUntil << 160 | validAfter << 208)`.
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData);

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external;
}
