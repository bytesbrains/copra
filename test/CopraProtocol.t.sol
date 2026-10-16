// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CopraToken.sol";
import "../src/CopraOracle.sol";
import "../src/CopraVault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract CopraProtocolTest is Test {
    CopraToken public copraToken;
    CopraOracle public oracle;
    CopraVault public vault;
    MockUSDC public usdc;

    address public feeRecipient = address(0xFEED);
    address public oracleUpdater = address(0x04AC1E);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    uint256 public constant INITIAL_PRICE = 140000000; // $1.40 USD (8 decimals)

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new CopraOracle(oracleUpdater, INITIAL_PRICE);
        vault = new CopraVault(address(usdc), 6, address(oracle), feeRecipient);

        copraToken = new CopraToken(address(vault));
        vault.setCopraToken(address(copraToken));

        // Fund Alice and Bob with USDC
        usdc.mint(alice, 10000 * 1e6); // 10,000 USDC
        usdc.mint(bob, 10000 * 1e6);
    }

    function test_InitialState() public view {
        assertEq(copraToken.name(), "Copra Protocol");
        assertEq(copraToken.symbol(), "COPRA");
        assertEq(copraToken.vault(), address(vault));
        assertEq(vault.feeRecipient(), feeRecipient);
    }

    function test_MintCopra() public {
        // Alice wants to mint 100 COPRA
        // At $1.40 per COPRA, 100 COPRA = $140.00
        // + 0.5% fee = $0.70 => Total = $140.70 = 140_700_000 micro-USDC (6 decimals)
        uint256 mintAmount = 100 * 1e18;
        (uint256 requiredUSDC, uint256 fee) = vault.quoteMint(mintAmount);

        assertEq(requiredUSDC, 140_700_000); // $140.70
        assertEq(fee, 700_000); // $0.70

        vm.startPrank(alice);
        usdc.approve(address(vault), requiredUSDC);
        vault.mint(mintAmount);
        vm.stopPrank();

        assertEq(copraToken.balanceOf(alice), mintAmount);
        assertEq(usdc.balanceOf(address(vault)), requiredUSDC);
        assertEq(vault.accumulatedFees(), fee);
    }

    function test_RedeemCopra() public {
        // Alice mints 100 COPRA
        uint256 mintAmount = 100 * 1e18;
        (uint256 requiredUSDC,) = vault.quoteMint(mintAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), requiredUSDC);
        vault.mint(mintAmount);

        // Alice transfers 50 COPRA to Bob
        copraToken.transfer(bob, 50 * 1e18);
        vm.stopPrank();

        // Bob redeems 50 COPRA for USDC
        // 50 COPRA at $1.40 = $70.00
        // Minus 0.5% protocol fee ($0.35) = $69.65 USDC (69_650_000)
        (uint256 redeemCollateral, uint256 fee) = vault.quoteRedeem(50 * 1e18);
        assertEq(redeemCollateral, 69_650_000); // $69.65
        assertEq(fee, 350_000); // $0.35

        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        vm.startPrank(bob);
        vault.redeem(50 * 1e18);
        vm.stopPrank();

        assertEq(copraToken.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, redeemCollateral);
    }

    function test_ClaimProtocolFees() public {
        uint256 mintAmount = 1000 * 1e18; // $1400 worth
        (uint256 requiredUSDC, uint256 expectedFee) = vault.quoteMint(mintAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), requiredUSDC);
        vault.mint(mintAmount);
        vm.stopPrank();

        assertEq(vault.accumulatedFees(), expectedFee);

        uint256 recipientBefore = usdc.balanceOf(feeRecipient);
        vault.claimFees();
        assertEq(usdc.balanceOf(feeRecipient) - recipientBefore, expectedFee);
        assertEq(vault.accumulatedFees(), 0);
    }

    function test_OraclePriceUpdate() public {
        // Commodity price rises from $1.40 to $1.54 (+10%)
        uint256 newPrice = 154000000;
        vm.prank(oracleUpdater);
        oracle.updatePrice(newPrice);

        (uint256 price,) = oracle.getCopraPriceUSD();
        assertEq(price, newPrice);

        // Mint quotes now reflect higher coconut price
        (uint256 requiredUSDC,) = vault.quoteMint(100 * 1e18);
        // 100 * 1.54 = $154 + 0.5% ($0.77) = $154.77
        assertEq(requiredUSDC, 154_770_000);
    }

    function test_OracleRevertOnUnauthorized() public {
        vm.expectRevert(CopraOracle.OnlyUpdater.selector);
        vm.prank(alice);
        oracle.updatePrice(150000000);
    }
}
