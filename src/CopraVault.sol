// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ICopraOracle.sol";
import "./CopraToken.sol";

/**
 * @title CopraVault
 * @author Copra Protocol (https://copra.dev)
 * @notice Autonomous Peg Stability and Collateral Reserve Engine for $COPRA.
 *         Allows permissionless minting and redemption of $COPRA at the real-world
 *         Copra commodity benchmark price, backed 100% by on-chain stable collateral.
 */
contract CopraVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The $COPRA ERC-20 token contract
    CopraToken public copraToken;

    /// @notice The collateral token (e.g., USDC)
    IERC20 public immutable collateralToken;

    /// @notice Decimals of the collateral token (e.g., 6 for USDC, 18 for DAI)
    uint8 public immutable collateralDecimals;

    /// @notice Price oracle providing benchmark copra rates in USD (8 decimals)
    ICopraOracle public immutable oracle;

    /// @notice The fee recipient address (creator / fee-staking pool)
    address public immutable feeRecipient;

    /// @notice Protocol minting & redemption fee in basis points (50 bps = 0.5%)
    uint256 public constant PROTOCOL_FEE_BPS = 50;
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Total protocol fees accumulated in collateral
    uint256 public accumulatedFees;

    event Minted(address indexed user, uint256 copraAmount, uint256 collateralPaid, uint256 feePaid);
    event Redeemed(address indexed user, uint256 copraAmount, uint256 collateralReturned, uint256 feePaid);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event TokenBound(address indexed tokenAddress);

    error VaultAlreadyInitialized();
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientVaultCollateral();

    /**
     * @param _collateral Address of the reserve collateral token (e.g. USDC).
     * @param _collateralDecimals Decimals of the collateral token (e.g. 6).
     * @param _oracle Address of the CopraOracle contract.
     * @param _feeRecipient Address that receives protocol mint/redeem fee earnings.
     */
    constructor(
        address _collateral,
        uint8 _collateralDecimals,
        address _oracle,
        address _feeRecipient
    ) {
        if (_collateral == address(0) || _oracle == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        collateralToken = IERC20(_collateral);
        collateralDecimals = _collateralDecimals;
        oracle = ICopraOracle(_oracle);
        feeRecipient = _feeRecipient;
    }

    /**
     * @notice One-time binding of the CopraToken contract address.
     * @param _copraToken Address of the deployed CopraToken contract.
     */
    function setCopraToken(address _copraToken) external {
        if (address(copraToken) != address(0)) revert VaultAlreadyInitialized();
        if (_copraToken == address(0)) revert ZeroAddress();
        copraToken = CopraToken(_copraToken);
        emit TokenBound(_copraToken);
    }

    /**
     * @notice Calculate the required collateral for a given amount of $COPRA.
     * @param copraAmount Amount of $COPRA (18 decimals).
     * @return collateralRequired Total collateral needed including protocol fee.
     * @return fee Portion of collateral allocated to protocol fee.
     */
    function quoteMint(uint256 copraAmount) public view returns (uint256 collateralRequired, uint256 fee) {
        (uint256 priceUSD, ) = oracle.getCopraPriceUSD();
        // priceUSD has 8 decimals. copraAmount has 18 decimals.
        // Base collateral value in USD (18 decimals) = (copraAmount * priceUSD) / 1e8
        uint256 valueUSD18 = (copraAmount * priceUSD) / 1e8;
        
        // Convert to collateral decimals
        uint256 baseCollateral;
        if (collateralDecimals < 18) {
            baseCollateral = valueUSD18 / (10 ** (18 - collateralDecimals));
        } else if (collateralDecimals > 18) {
            baseCollateral = valueUSD18 * (10 ** (collateralDecimals - 18));
        } else {
            baseCollateral = valueUSD18;
        }

        fee = (baseCollateral * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        collateralRequired = baseCollateral + fee;
    }

    /**
     * @notice Calculate the collateral returned when redeeming $COPRA.
     * @param copraAmount Amount of $COPRA to burn (18 decimals).
     * @return collateralToReturn Net collateral sent to user.
     * @return fee Portion deducted for protocol fee.
     */
    function quoteRedeem(uint256 copraAmount) public view returns (uint256 collateralToReturn, uint256 fee) {
        (uint256 priceUSD, ) = oracle.getCopraPriceUSD();
        uint256 valueUSD18 = (copraAmount * priceUSD) / 1e8;

        uint256 baseCollateral;
        if (collateralDecimals < 18) {
            baseCollateral = valueUSD18 / (10 ** (18 - collateralDecimals));
        } else if (collateralDecimals > 18) {
            baseCollateral = valueUSD18 * (10 ** (collateralDecimals - 18));
        } else {
            baseCollateral = valueUSD18;
        }

        fee = (baseCollateral * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        collateralToReturn = baseCollateral - fee;
    }

    /**
     * @notice Permissionlessly mint $COPRA by depositing collateral at the current benchmark price.
     * @param copraAmount The quantity of $COPRA tokens to mint (18 decimals).
     */
    function mint(uint256 copraAmount) external nonReentrant {
        if (copraAmount == 0) revert ZeroAmount();
        (uint256 collateralRequired, uint256 fee) = quoteMint(copraAmount);

        accumulatedFees += fee;
        collateralToken.safeTransferFrom(msg.sender, address(this), collateralRequired);
        copraToken.mint(msg.sender, copraAmount);

        emit Minted(msg.sender, copraAmount, collateralRequired, fee);
    }

    /**
     * @notice Permissionlessly redeem $COPRA for underlying collateral at the real-time commodity price.
     *         This guarantees the hard peg floor: anyone can exit at 100% commodity asset value.
     * @param copraAmount The quantity of $COPRA tokens to burn (18 decimals).
     */
    function redeem(uint256 copraAmount) external nonReentrant {
        if (copraAmount == 0) revert ZeroAmount();
        (uint256 collateralToReturn, uint256 fee) = quoteRedeem(copraAmount);

        uint256 availableCollateral = collateralToken.balanceOf(address(this)) - accumulatedFees;
        if (collateralToReturn > availableCollateral) revert InsufficientVaultCollateral();

        accumulatedFees += fee;
        copraToken.burnFromVault(msg.sender, copraAmount);
        collateralToken.safeTransfer(msg.sender, collateralToReturn);

        emit Redeemed(msg.sender, copraAmount, collateralToReturn, fee);
    }

    /**
     * @notice Allows the feeRecipient to withdraw their earned protocol fees.
     */
    function claimFees() external nonReentrant {
        uint256 feesToClaim = accumulatedFees;
        if (feesToClaim == 0) revert ZeroAmount();

        accumulatedFees = 0;
        collateralToken.safeTransfer(feeRecipient, feesToClaim);

        emit FeesClaimed(feeRecipient, feesToClaim);
    }
}
