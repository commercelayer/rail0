// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Script, console2 } from "forge-std/Script.sol";
import { RAIL0 } from "../src/RAIL0.sol";

/// @title  Deploy — deploy RAIL0 with a fixed token allowlist.
/// @dev    The `acceptedTokens` allowlist is set in the constructor and immutable.
///         Adding any new token later requires a fresh deployment, so list every
///         stablecoin you want this deployment to accept up front.
///
///         Usage:
///           # 1. Set the allowlist (comma-separated, no spaces).
///           export RAIL0_ACCEPTED_TOKENS=0x...,0x...
///
///           # 2. Run from contracts/ with a previously-imported cast wallet.
///           forge script script/Deploy.s.sol \
///             --rpc-url $RPC \
///             --account <name> \
///             --broadcast
///
///           # 3. (optional) Verify on a block explorer if available:
///           forge verify-contract <deployed-address> src/RAIL0.sol:RAIL0 \
///             --constructor-args $(cast abi-encode "constructor(address[])" "[$RAIL0_ACCEPTED_TOKENS]") \
///             --rpc-url $RPC --verifier <sourcify|etherscan> --verifier-url <...>
contract Deploy is Script {
    function run() external returns (RAIL0 rail0) {
        address[] memory tokens = vm.envAddress("RAIL0_ACCEPTED_TOKENS", ",");
        require(tokens.length > 0, "Deploy: RAIL0_ACCEPTED_TOKENS must list at least one token");

        vm.startBroadcast();
        rail0 = new RAIL0(tokens);
        vm.stopBroadcast();

        console2.log("RAIL0 deployed at:", address(rail0));
        console2.log("VERSION:", rail0.VERSION());
        console2.log("Accepted tokens:");
        for (uint256 i = 0; i < tokens.length; i++) {
            console2.log("  -", tokens[i]);
        }
    }
}
