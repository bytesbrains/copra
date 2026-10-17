// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/ICopraOracle.sol";
import "./CopraToken.sol";

/**
 * @title CopraVault
 * @author Copra Protocol (https://copra.dev)
 * @notice Autonomous Peg Stability and Collateral Reserve Engine for $COPRA.
 *         Allows permissionless minting and redemption of $COPRA at the real-world
 *         Copra commodity benchmark price. Each mint deposits the full value at the current
 *         price in on-chain stable collateral; coverage then moves with the price.
 */
contract CopraVault is ReentrancyGuard, Ownable2Step {
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
    address public feeRecipient;

    /// @notice Maximum allowable protocol fee (100 bps = 1.0%)
    uint256 public constant MAX_FEE_BPS = 100;
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Protocol minting & redemption fee in basis points (default 25 bps = 0.25%)
    uint256 public protocolFeeBps;

    /// @notice Total protocol fees accumulated in collateral
    uint256 public accumulatedFees;

    event Minted(address indexed user, uint256 copraAmount, uint256 collateralPaid, uint256 feePaid);
    event Redeemed(address indexed user, uint256 copraAmount, uint256 collateralReturned, uint256 feePaid);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event TokenBound(address indexed tokenAddress);

    error VaultAlreadyInitialized();
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientVaultCollateral();
    error FeeExceedsMax();
    /// @notice The price or fee moved past the caller's bound between their quote and execution.
    error SlippageExceeded(uint256 actual, uint256 limit);

    /**
     * @param _collateral Address of the reserve collateral token (e.g. USDC).
     * @param _collateralDecimals Decimals of the collateral token (e.g. 6).
     * @param _oracle Address of the CopraOracle contract.
     * @param _feeRecipient Address that receives protocol mint/redeem fee earnings.
     * @param _owner Initial owner of the vault contract (capable of updating feeRecipient, protocolFee, and binding token).
     */
    constructor(address _collateral, uint8 _collateralDecimals, address _oracle, address _feeRecipient, address _owner)
        Ownable(_owner)
    {
        if (_collateral == address(0) || _oracle == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        collateralToken = IERC20(_collateral);
        collateralDecimals = _collateralDecimals;
        oracle = ICopraOracle(_oracle);
        feeRecipient = _feeRecipient;
        protocolFeeBps = 25; // 0.25% (25 bps) default
    }

    /**
     * @notice One-time binding of the CopraToken contract address.
     * @param _copraToken Address of the deployed CopraToken contract.
     */
    function setCopraToken(address _copraToken) external onlyOwner {
        if (address(copraToken) != address(0)) revert VaultAlreadyInitialized();
        if (_copraToken == address(0)) revert ZeroAddress();
        copraToken = CopraToken(_copraToken);
        emit TokenBound(_copraToken);
    }

    /**
     * @notice Updates the fee recipient address.
     * @param _newRecipient The new address to receive protocol fees.
     */
    function setFeeRecipient(address _newRecipient) external onlyOwner {
        if (_newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, _newRecipient);
        feeRecipient = _newRecipient;
    }

    /**
     * @notice Updates the protocol fee in basis points.
     * @param _newFeeBps New fee in basis points (must be <= MAX_FEE_BPS = 100 bps / 1.0%).
     */
    function setProtocolFee(uint256 _newFeeBps) external onlyOwner {
        if (_newFeeBps > MAX_FEE_BPS) revert FeeExceedsMax();
        emit ProtocolFeeUpdated(protocolFeeBps, _newFeeBps);
        protocolFeeBps = _newFeeBps;
    }

    /**
     * @notice Calculate the required collateral for a given amount of $COPRA.
     * @param copraAmount Amount of $COPRA (18 decimals).
     * @return collateralRequired Total collateral needed including protocol fee.
     * @return fee Portion of collateral allocated to protocol fee.
     */
    function quoteMint(uint256 copraAmount) public view returns (uint256 collateralRequired, uint256 fee) {
        (uint256 priceUSD,) = oracle.getCopraPriceUSD();
        // priceUSD has 8 decimals. copraAmount has 18 decimals.
        // Rounds UP: every minted unit must be fully backed, so dust mints cannot cost 0 collateral.
        uint256 valueUSD18 = Math.mulDiv(copraAmount, priceUSD, 1e8, Math.Rounding.Ceil);

        // Convert to collateral decimals
        uint256 baseCollateral;
        if (collateralDecimals < 18) {
            baseCollateral = Math.ceilDiv(valueUSD18, 10 ** (18 - collateralDecimals));
        } else if (collateralDecimals > 18) {
            baseCollateral = valueUSD18 * (10 ** (collateralDecimals - 18));
        } else {
            baseCollateral = valueUSD18;
        }

        fee = (baseCollateral * protocolFeeBps) / BPS_DENOMINATOR;
        collateralRequired = baseCollateral + fee;
    }

    /**
     * @notice Calculate the collateral returned when redeeming $COPRA.
     * @param copraAmount Amount of $COPRA to burn (18 decimals).
     * @return collateralToReturn Net collateral sent to user.
     * @return fee Portion deducted for protocol fee.
     */
    function quoteRedeem(uint256 copraAmount) public view returns (uint256 collateralToReturn, uint256 fee) {
        (uint256 priceUSD,) = oracle.getCopraPriceUSD();
        uint256 valueUSD18 = (copraAmount * priceUSD) / 1e8;

        uint256 baseCollateral;
        if (collateralDecimals < 18) {
            baseCollateral = valueUSD18 / (10 ** (18 - collateralDecimals));
        } else if (collateralDecimals > 18) {
            baseCollateral = valueUSD18 * (10 ** (collateralDecimals - 18));
        } else {
            baseCollateral = valueUSD18;
        }

        fee = (baseCollateral * protocolFeeBps) / BPS_DENOMINATOR;
        collateralToReturn = baseCollateral - fee;
    }

    /**
     * @notice Permissionlessly mint $COPRA by depositing collateral at the current benchmark price.
     *         The cost is computed when the transaction executes, so a price update or fee change
     *         landing after the caller's quote changes it; maxCollateralIn bounds what they pay.
     * @param copraAmount The quantity of $COPRA tokens to mint (18 decimals).
     * @param maxCollateralIn The most collateral, fee included, the caller accepts to pay (usually
     *        quoteMint(copraAmount).collateralRequired). Reverts with SlippageExceeded above it.
     */
    function mint(uint256 copraAmount, uint256 maxCollateralIn) external nonReentrant {
        if (copraAmount == 0) revert ZeroAmount();
        (uint256 collateralRequired, uint256 fee) = quoteMint(copraAmount);
        if (collateralRequired > maxCollateralIn) revert SlippageExceeded(collateralRequired, maxCollateralIn);

        accumulatedFees += fee;
        collateralToken.safeTransferFrom(msg.sender, address(this), collateralRequired);
        copraToken.mint(msg.sender, copraAmount);

        emit Minted(msg.sender, copraAmount, collateralRequired, fee);
    }

    /**
     * @notice Permissionlessly redeem $COPRA for underlying collateral at the real-time commodity price.
     *         Pays first-come-first-served from the collateral the vault holds: after a price rise
     *         the vault can hold less than all $COPRA is worth, and this reverts with
     *         InsufficientVaultCollateral once it runs short.
     * @param copraAmount The quantity of $COPRA tokens to burn (18 decimals).
     * @param minCollateralOut The least collateral, after the fee, the caller accepts to receive
     *        (usually quoteRedeem(copraAmount).collateralToReturn). Reverts with SlippageExceeded below it.
     */
    function redeem(uint256 copraAmount, uint256 minCollateralOut) external nonReentrant {
        if (copraAmount == 0) revert ZeroAmount();
        (uint256 collateralToReturn, uint256 fee) = quoteRedeem(copraAmount);
        if (collateralToReturn < minCollateralOut) revert SlippageExceeded(collateralToReturn, minCollateralOut);

        // The redeem fee stays in the vault as accumulatedFees, so it must be covered by backing
        // collateral too; otherwise the vault ends up owing more fees than it holds.
        uint256 availableCollateral = collateralToken.balanceOf(address(this)) - accumulatedFees;
        if (collateralToReturn + fee > availableCollateral) revert InsufficientVaultCollateral();

        accumulatedFees += fee;
        copraToken.burnFromVault(msg.sender, copraAmount);
        collateralToken.safeTransfer(msg.sender, collateralToReturn);

        emit Redeemed(msg.sender, copraAmount, collateralToReturn, fee);
    }

    /**
     * @notice Allows withdrawal of accumulated protocol fees directly to feeRecipient.
     *         Permissionless to trigger, but collateral is strictly sent to feeRecipient.
     */
    function claimFees() external nonReentrant {
        uint256 feesToClaim = accumulatedFees;
        if (feesToClaim == 0) revert ZeroAmount();

        accumulatedFees = 0;
        collateralToken.safeTransfer(feeRecipient, feesToClaim);

        emit FeesClaimed(feeRecipient, feesToClaim);
    }
}
