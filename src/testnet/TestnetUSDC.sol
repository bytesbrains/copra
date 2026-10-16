// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title TestnetUSDC
 * @notice Testnet mock USDC token with public faucet for Copra Protocol testnet sandbox.
 */
contract TestnetUSDC is ERC20 {
    uint256 public constant MAX_FAUCET_AMOUNT = 10_000 * 1e6; // 10,000 USDC max per claim

    event FaucetDripped(address indexed recipient, uint256 amount);

    constructor() ERC20("USD Coin (Testnet)", "USDC") {
        _mint(msg.sender, 1_000_000 * 1e6); // 1,000,000 USDC initial pool to deployer
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Permissionless testnet faucet allowing testers to claim test USDC.
     * @param to The recipient address.
     * @param amount The amount in micro-USDC (up to 10,000 USDC).
     */
    function faucet(address to, uint256 amount) external {
        require(to != address(0), "Invalid recipient");
        require(amount > 0 && amount <= MAX_FAUCET_AMOUNT, "Amount exceeds max faucet claim");
        _mint(to, amount);
        emit FaucetDripped(to, amount);
    }
}
