// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CopraToken.sol";
import "../src/CopraOracle.sol";
import "../src/CopraVault.sol";

/**
 * @title DeployCopra
 * @notice Forge deployment script for Copra Protocol on Base / Base Sepolia.
 *
 * Usage:
 * forge script script/DeployCopra.s.sol:DeployCopra --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
 */
contract DeployCopra is Script {
    // Official Base Sepolia USDC address: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
    address public constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint8 public constant USDC_DECIMALS = 6;
    uint256 public constant INITIAL_PRICE = 142000000; // $1.42 USD (8 decimals)

    function run() external {
        uint256 deployerPrivateKey =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployerAddress = vm.addr(deployerPrivateKey);

        console.log("Deploying Copra Protocol from:", deployerAddress);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Oracle
        CopraOracle oracle = new CopraOracle(deployerAddress, INITIAL_PRICE);
        console.log("CopraOracle deployed at:", address(oracle));

        // 2. Deploy Vault
        CopraVault vault = new CopraVault(
            BASE_SEPOLIA_USDC,
            USDC_DECIMALS,
            address(oracle),
            deployerAddress // Fee recipient receives mint/redeem fee earnings
        );
        console.log("CopraVault deployed at:", address(vault));

        // 3. Deploy CopraToken ($COPRA) pointing to Vault
        CopraToken token = new CopraToken(address(vault));
        console.log("CopraToken deployed at:", address(token));

        // 4. Bind Token to Vault
        vault.setCopraToken(address(token));
        console.log("Token successfully bound to Vault!");

        vm.stopBroadcast();
    }
}
