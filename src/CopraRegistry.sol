// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./CopraVault.sol";
import "./CopraToken.sol";

/**
 * @title CopraRegistry
 * @author Copra Protocol (https://copra.dev)
 * @notice Single, permanent on-chain pointer to the live Copra Protocol contract set.
 *         Deployed once at a deterministic CREATE2 address; the web app and the oracle feeder
 *         resolve every other address through it, so a protocol redeploy never requires a
 *         frontend or feeder change.
 */
contract CopraRegistry is Ownable2Step {
    address public collateral;
    address public oracle;
    address public vault;
    address public token;

    /// @notice Incremented on every update; 0 means nothing has been registered yet.
    uint256 public version;
    uint256 public updatedAt;

    event DeploymentUpdated(uint256 indexed version, address collateral, address oracle, address vault, address token);

    error ZeroAddress();
    error InconsistentDeployment();

    constructor(address _owner) Ownable(_owner) {}

    /**
     * @notice Points the registry at a new contract set. The set must be wired to itself:
     *         the vault must use this collateral, oracle and token, and the token must trust the vault.
     */
    function setDeployment(address _collateral, address _oracle, address _vault, address _token) external onlyOwner {
        if (_collateral == address(0) || _oracle == address(0) || _vault == address(0) || _token == address(0)) {
            revert ZeroAddress();
        }
        CopraVault v = CopraVault(_vault);
        if (
            address(v.collateralToken()) != _collateral || address(v.oracle()) != _oracle
                || address(v.copraToken()) != _token || CopraToken(_token).vault() != _vault
        ) {
            revert InconsistentDeployment();
        }

        collateral = _collateral;
        oracle = _oracle;
        vault = _vault;
        token = _token;
        updatedAt = block.timestamp;
        version += 1;

        emit DeploymentUpdated(version, _collateral, _oracle, _vault, _token);
    }

    /// @notice All addresses in one call, for frontends and scripts.
    function getDeployment() external view returns (address, address, address, address, uint256, uint256) {
        return (collateral, oracle, vault, token, version, updatedAt);
    }
}
