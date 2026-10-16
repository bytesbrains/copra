// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title CopraToken ($COPRA)
 * @author Copra Protocol (https://copra.dev)
 * @notice The sovereign agricultural commodity-backed token of Copra Protocol.
 *         Minting and burning permissions are exclusively restricted to the immutable CopraVault.
 */
contract CopraToken is ERC20, ERC20Burnable {
    /// @notice The immutable address of the CopraVault authorized to mint/burn
    address public immutable vault;

    error OnlyVault();
    error ZeroAddress();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /**
     * @notice Initializes the Copra token with the authorized vault address.
     * @param _vault The address of the CopraVault contract.
     */
    constructor(address _vault) ERC20("Copra Protocol", "COPRA") {
        if (_vault == address(0)) revert ZeroAddress();
        vault = _vault;
    }

    /**
     * @notice Mints new COPRA tokens. Only callable by the vault contract.
     * @param to The recipient address.
     * @param amount The quantity of COPRA to mint (18 decimals).
     */
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    /**
     * @notice Burns COPRA tokens from an account. Only callable by the vault contract.
     * @param from The address whose tokens will be burned.
     * @param amount The quantity of COPRA to burn.
     */
    function burnFromVault(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
