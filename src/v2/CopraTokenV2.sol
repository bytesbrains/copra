// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title CopraTokenV2 ($COPRA)
 * @author Copra Protocol (https://copra.dev)
 * @notice The COPRA-001 $COPRA token: 1 token tracks 1 GCPI reference kilogram. Only the
 *         position manager that created this token may mint or burn, through mint, repay,
 *         liquidation and redemption settlement. Transfers are never blocked, paused or
 *         restricted, in any protocol state (§6). The v1 CopraToken is untouched by this
 *         deployment; holders migrate by their own choice (§14.1).
 */
contract CopraTokenV2 is ERC20 {
    /// @notice The position manager that deployed this token; the only minter and burner.
    address public immutable manager;

    error OnlyManager();
    error ZeroAddress();

    modifier onlyManager() {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    constructor() ERC20("Copra Protocol v2", "COPRA") {
        manager = msg.sender;
        if (manager == address(0)) revert ZeroAddress();
    }

    /**
     * @notice Mints $COPRA to `to`. Only the manager, which mints only against a position
     *         whose ratio is at least MCR (Invariant 1).
     */
    function mint(address to, uint256 amount) external onlyManager {
        _mint(to, amount);
    }

    /**
     * @notice Burns $COPRA from `from`. Only the manager, through repay, liquidation and
     *         redemption settlement. Burning from the manager itself settles escrowed tokens.
     */
    function burnFromManager(address from, uint256 amount) external onlyManager {
        _burn(from, amount);
    }
}
