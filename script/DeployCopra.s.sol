// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CopraToken.sol";
import "../src/CopraOracle.sol";
import "../src/CopraVault.sol";
import "../src/testnet/TestnetUSDC.sol";

/**
 * @title DeployCopra
 * @notice Forge deployment script for Copra Protocol on Base Sepolia testnet sandbox.
 *
 * Usage:
 * forge script script/DeployCopra.s.sol:DeployCopra --rpc-url $BASE_SEPOLIA_RPC --broadcast
 */
contract DeployCopra is Script {
    uint8 public constant USDC_DECIMALS = 6;
    uint256 public constant INITIAL_PRICE = 142000000; // $1.42 USD (8 decimals)

    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(1));
        address deployerAddress = vm.addr(deployerPrivateKey);

        console.log("--------------------------------------------------");
        console.log("Deploying Copra Protocol to Base Sepolia Testnet");
        console.log("Deployer Address:", deployerAddress);
        console.log("--------------------------------------------------");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Testnet USDC with Faucet
        TestnetUSDC usdc = new TestnetUSDC();
        console.log("1. TestnetUSDC deployed at:", address(usdc));

        // 2. Deploy Oracle ($1.42 initial spot price)
        CopraOracle oracle = new CopraOracle(deployerAddress, INITIAL_PRICE);
        console.log("2. CopraOracle deployed at:", address(oracle));

        // 3. Deploy Vault (backed by TestnetUSDC, 0.25% fee, deployer as feeRecipient and owner)
        CopraVault vault =
            new CopraVault(address(usdc), USDC_DECIMALS, address(oracle), deployerAddress, deployerAddress);
        console.log("3. CopraVault deployed at:", address(vault));

        // 4. Deploy CopraToken ($COPRA) pointing to Vault
        CopraToken token = new CopraToken(address(vault));
        console.log("4. CopraToken deployed at:", address(token));

        // 5. Bind Token to Vault
        vault.setCopraToken(address(token));
        console.log("5. CopraToken successfully bound to Vault!");

        vm.stopBroadcast();

        console.log("--------------------------------------------------");
        console.log("Base Sepolia Deployment Complete!");
        console.log("--------------------------------------------------");
    }
}
