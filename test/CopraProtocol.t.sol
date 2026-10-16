// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CopraToken.sol";
import "../src/CopraOracle.sol";
import "../src/CopraVault.sol";
import "../src/testnet/TestnetUSDC.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

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
        vault = new CopraVault(address(usdc), 6, address(oracle), feeRecipient, address(this));

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
        assertEq(vault.protocolFeeBps(), 25); // 0.25% default
        assertEq(vault.owner(), address(this));
    }

    function test_MintCopra() public {
        // Alice wants to mint 100 COPRA
        // At $1.40 per COPRA, 100 COPRA = $140.00
        // + 0.25% fee = $0.35 => Total = $140.35 = 140_350_000 micro-USDC (6 decimals)
        uint256 mintAmount = 100 * 1e18;
        (uint256 requiredUSDC, uint256 fee) = vault.quoteMint(mintAmount);

        assertEq(requiredUSDC, 140_350_000); // $140.35
        assertEq(fee, 350_000); // $0.35

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
        // Minus 0.25% protocol fee ($0.175) = $69.825 USDC (69_825_000)
        (uint256 redeemCollateral, uint256 fee) = vault.quoteRedeem(50 * 1e18);
        assertEq(redeemCollateral, 69_825_000); // $69.825
        assertEq(fee, 175_000); // $0.175

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

    function test_SetFeeRecipient() public {
        address newRecipient = address(0xCAFE);
        vault.setFeeRecipient(newRecipient);
        assertEq(vault.feeRecipient(), newRecipient);

        // Non-owner cannot update
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setFeeRecipient(alice);

        // Zero address reverts
        vm.expectRevert(CopraVault.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    function test_SetProtocolFee() public {
        // Update fee to 0.50% (50 bps)
        vault.setProtocolFee(50);
        assertEq(vault.protocolFeeBps(), 50);

        // Max fee is 100 bps (1.00%)
        vault.setProtocolFee(100);
        assertEq(vault.protocolFeeBps(), 100);

        // Exceeding max fee reverts
        vm.expectRevert(CopraVault.FeeExceedsMax.selector);
        vault.setProtocolFee(101);

        // Non-owner cannot update
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setProtocolFee(20);
    }

    function test_Ownable2StepTransfer() public {
        address newOwner = address(0x999);
        vault.transferOwnership(newOwner);
        assertEq(vault.pendingOwner(), newOwner);
        assertEq(vault.owner(), address(this));

        // Accept ownership from new owner
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
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
        // 100 * 1.54 = $154 + 0.25% ($0.385) = $154.385
        assertEq(requiredUSDC, 154_385_000);
    }

    function test_OracleRevertOnUnauthorized() public {
        vm.expectRevert(CopraOracle.OnlyUpdater.selector);
        vm.prank(alice);
        oracle.updatePrice(150000000);
    }

    function test_TestnetUSDC_Faucet() public {
        TestnetUSDC testUsdc = new TestnetUSDC();
        assertEq(testUsdc.decimals(), 6);
        assertEq(testUsdc.symbol(), "USDC");

        // Alice claims 1000 USDC from faucet
        testUsdc.faucet(alice, 1000 * 1e6);
        assertEq(testUsdc.balanceOf(alice), 1000 * 1e6);

        // Claiming above max reverts
        vm.expectRevert("Amount exceeds max faucet claim");
        testUsdc.faucet(alice, 10001 * 1e6);
    }
}
