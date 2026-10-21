// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./CopraManagerV2.sol";
import "./CopraTokenV2.sol";

/**
 * @title CopraRegistryV2
 * @author Copra Protocol (https://copra.dev)
 * @notice COPRA-001 §14.1: the on-chain pointer to the live v2 contract set. The v1 registry
 *         validates the v1 shape (collateral, oracle, vault, token) and cannot point at v2,
 *         so v2 gets its own registry with its own shape (collateral, GCPI adapter, position
 *         manager, token). Deployed once at a deterministic CREATE2 address; frontends and
 *         keepers resolve every other address through it. The owner can only repoint the set
 *         to a self-consistent deployment, never touch positions, prices or collateral.
 */
contract CopraRegistryV2 is Ownable2Step {
    address public collateral;
    address public gcpi;
    address public manager;
    address public token;

    /// @notice Incremented on every update; 0 means nothing has been registered yet.
    uint256 public version;
    uint256 public updatedAt;

    event DeploymentUpdated(uint256 indexed version, address collateral, address gcpi, address manager, address token);

    error ZeroAddress();
    error InconsistentDeployment();

    constructor(address _owner) Ownable(_owner) {}

    /**
     * @notice Points the registry at a new v2 contract set. The set must be wired to itself:
     *         the manager must use this collateral, GCPI adapter and token, and the token
     *         must trust the manager.
     */
    function setDeployment(address _collateral, address _gcpi, address _manager, address _token) external onlyOwner {
        if (_collateral == address(0) || _gcpi == address(0) || _manager == address(0) || _token == address(0)) {
            revert ZeroAddress();
        }
        CopraManagerV2 m = CopraManagerV2(_manager);
        if (
            address(m.collateralToken()) != _collateral || address(m.gcpi()) != _gcpi
                || address(m.copraToken()) != _token || CopraTokenV2(_token).manager() != _manager
        ) {
            revert InconsistentDeployment();
        }

        collateral = _collateral;
        gcpi = _gcpi;
        manager = _manager;
        token = _token;
        updatedAt = block.timestamp;
        version += 1;

        emit DeploymentUpdated(version, _collateral, _gcpi, _manager, _token);
    }

    /// @notice All addresses in one call, for frontends and scripts.
    function getDeployment() external view returns (address, address, address, address, uint256, uint256) {
        return (collateral, gcpi, manager, token, version, updatedAt);
    }
}
