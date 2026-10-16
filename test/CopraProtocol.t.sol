// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CopraToken.sol";
import "../src/CopraOracle.sol";
import "../src/CopraVault.sol";
import "../src/testnet/TestnetUSDC.sol";
import "../script/DeployCopra.s.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

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

    function test_DeployCopra_RequiresExplicitPrivateKey() public {
        DeployCopra deployer = new DeployCopra();

        // Zero PRIVATE_KEY must revert instead of silently falling back to a known key
        vm.setEnv("PRIVATE_KEY", "0");
        vm.expectRevert("DeployCopra: invalid PRIVATE_KEY");
        deployer.run();

        // Valid PRIVATE_KEY succeeds
        vm.setEnv("PRIVATE_KEY", "123456");
        deployer.run();
    }

    // ---------------------------------------------------------------------
    // Oracle guardrails
    // ---------------------------------------------------------------------

    function _mintAs(address user, uint256 copraAmount) internal {
        (uint256 requiredUSDC,) = vault.quoteMint(copraAmount);
        vm.startPrank(user);
        usdc.approve(address(vault), requiredUSDC);
        vault.mint(copraAmount);
        vm.stopPrank();
    }

    function test_Oracle_FreshAtExactHeartbeat() public {
        vm.warp(block.timestamp + oracle.HEARTBEAT());
        (uint256 price,) = oracle.getCopraPriceUSD();
        assertEq(price, INITIAL_PRICE);
    }

    function test_Oracle_StalePriceAfterHeartbeat() public {
        vm.warp(block.timestamp + oracle.HEARTBEAT() + 1);
        vm.expectRevert(CopraOracle.StalePrice.selector);
        oracle.getCopraPriceUSD();
    }

    function test_Vault_MintAndRedeemRevertOnStalePrice() public {
        _mintAs(alice, 10 * 1e18);
        vm.warp(block.timestamp + oracle.HEARTBEAT() + 1);

        vm.expectRevert(CopraOracle.StalePrice.selector);
        vault.quoteMint(1e18);

        vm.prank(alice);
        vm.expectRevert(CopraOracle.StalePrice.selector);
        vault.mint(1e18);

        vm.prank(alice);
        vm.expectRevert(CopraOracle.StalePrice.selector);
        vault.redeem(10 * 1e18);
    }

    function test_Oracle_UpdateRefreshesStalePrice() public {
        vm.warp(block.timestamp + oracle.HEARTBEAT() + 1);
        vm.prank(oracleUpdater);
        oracle.updatePrice(INITIAL_PRICE);

        (uint256 price, uint256 updatedAt) = oracle.getCopraPriceUSD();
        assertEq(price, INITIAL_PRICE);
        assertEq(updatedAt, block.timestamp);
    }

    function test_Oracle_PriceShiftAllowedAtExactly20Percent() public {
        // +2000 bps: $1.40 -> $1.68
        vm.prank(oracleUpdater);
        oracle.updatePrice(168000000);
        (uint256 price,) = oracle.getCopraPriceUSD();
        assertEq(price, 168000000);

        // -2000 bps from a fresh oracle: $1.40 -> $1.12
        CopraOracle down = new CopraOracle(oracleUpdater, INITIAL_PRICE);
        vm.prank(oracleUpdater);
        down.updatePrice(112000000);
        (price,) = down.getCopraPriceUSD();
        assertEq(price, 112000000);
    }

    function test_Oracle_PriceShiftAbove20PercentReverts() public {
        // 2001 bps of $1.40 = 28_014_000 (8 decimals)
        vm.startPrank(oracleUpdater);
        vm.expectRevert(CopraOracle.PriceChangeExceeded.selector);
        oracle.updatePrice(INITIAL_PRICE + 28014000);

        vm.expectRevert(CopraOracle.PriceChangeExceeded.selector);
        oracle.updatePrice(INITIAL_PRICE - 28014000);
        vm.stopPrank();

        (uint256 price,) = oracle.getCopraPriceUSD();
        assertEq(price, INITIAL_PRICE);
    }

    /// @dev The collar compares (diff * 10000) / price with integer division, so the real threshold
    ///      is diff * 10000 >= 2001 * price: shifts up to 2000.99 bps are accepted. Pin it exactly.
    function test_Oracle_PriceShiftThresholdIsExact() public {
        uint256 firstRejected = (INITIAL_PRICE * (oracle.MAX_PRICE_CHANGE_BPS() + 1) + 9999) / 10000;
        assertEq(firstRejected, 28014000);

        vm.prank(oracleUpdater);
        vm.expectRevert(CopraOracle.PriceChangeExceeded.selector);
        oracle.updatePrice(INITIAL_PRICE + firstRejected);

        vm.prank(oracleUpdater);
        oracle.updatePrice(INITIAL_PRICE + firstRejected - 1);
        (uint256 price,) = oracle.getCopraPriceUSD();
        assertEq(price, INITIAL_PRICE + firstRejected - 1);
    }

    function test_Oracle_ZeroPriceReverts() public {
        vm.expectRevert(CopraOracle.PriceTooLow.selector);
        new CopraOracle(oracleUpdater, 0);

        vm.prank(oracleUpdater);
        vm.expectRevert(CopraOracle.PriceTooLow.selector);
        oracle.updatePrice(0);
    }

    // ---------------------------------------------------------------------
    // Vault & token guardrails
    // ---------------------------------------------------------------------

    function test_Vault_SetCopraTokenOnlyOnce() public {
        vm.expectRevert(CopraVault.VaultAlreadyInitialized.selector);
        vault.setCopraToken(address(0xBEEF));
        assertEq(address(vault.copraToken()), address(copraToken));
    }

    function test_Vault_SetCopraTokenRejectsZeroAddress() public {
        CopraVault fresh = new CopraVault(address(usdc), 6, address(oracle), feeRecipient, address(this));
        vm.expectRevert(CopraVault.ZeroAddress.selector);
        fresh.setCopraToken(address(0));
    }

    function test_Vault_ZeroAmountReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(CopraVault.ZeroAmount.selector);
        vault.mint(0);

        vm.expectRevert(CopraVault.ZeroAmount.selector);
        vault.redeem(0);
        vm.stopPrank();

        assertEq(vault.accumulatedFees(), 0);
        vm.expectRevert(CopraVault.ZeroAmount.selector);
        vault.claimFees();
    }

    function test_Token_OnlyVaultCanMintOrBurn() public {
        _mintAs(alice, 10 * 1e18);

        vm.startPrank(alice);
        vm.expectRevert(CopraToken.OnlyVault.selector);
        copraToken.mint(alice, 1e18);

        vm.expectRevert(CopraToken.OnlyVault.selector);
        copraToken.burnFromVault(alice, 1e18);
        vm.stopPrank();

        // The vault's owner is not the vault either
        vm.expectRevert(CopraToken.OnlyVault.selector);
        copraToken.mint(address(this), 1e18);

        assertEq(copraToken.balanceOf(alice), 10 * 1e18);
    }

    // ---------------------------------------------------------------------
    // Solvency regressions (found by testFuzz_MintAndRedeemSolvency)
    // ---------------------------------------------------------------------

    /// @dev The redeem fee is credited to accumulatedFees, so it must be backed by collateral too.
    ///      Before the fix this redeem succeeded and left 0.5005 USDC against 0.7005 USDC of fees.
    function test_Vault_RedeemCannotLeaveFeesUnbacked() public {
        _mintAs(alice, 100 * 1e18); // 140.35 USDC: 140.00 backing + 0.35 fee

        vm.prank(oracleUpdater);
        oracle.updatePrice(140200000); // +0.14%: return 139.8495 fits, return + fee 140.20 does not

        vm.prank(alice);
        vm.expectRevert(CopraVault.InsufficientVaultCollateral.selector);
        vault.redeem(100 * 1e18);

        // Pinned: nothing moved. The unfixed vault paid out 139.8495 here, leaving 0.5005 USDC
        // against 0.7005 USDC of fees.
        assertEq(usdc.balanceOf(address(vault)), 140_350_000);
        assertEq(vault.accumulatedFees(), 350_000);
        assertEq(copraToken.balanceOf(alice), 100 * 1e18);

        vault.claimFees();
        assertEq(usdc.balanceOf(feeRecipient), 350_000);
    }

    /// @dev quoteMint rounds collateral up, so no non-zero mint is free.
    function test_Vault_DustMintIsNotFree() public {
        uint256 dust = 714285714285; // worth just under 1 micro-USDC at $1.40
        (uint256 required,) = vault.quoteMint(dust);
        assertEq(required, 1);

        // The vault now pulls 1 unit, which a caller with no allowance cannot pay
        address broke = address(0xD00D);
        vm.prank(broke);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1));
        vault.mint(dust);
        assertEq(copraToken.balanceOf(broke), 0);

        // Exact amounts are unaffected by the rounding direction
        (required,) = vault.quoteMint(1e18);
        assertEq(required, 1_403_500);
    }

    function testFuzz_QuoteMintCoversRedeemValue(uint256 copraAmount, uint256 priceSeed) public {
        copraAmount = bound(copraAmount, 1, 1e30);
        uint256 target = _boundedPriceMove(priceSeed);
        vm.prank(oracleUpdater);
        oracle.updatePrice(target);

        (uint256 required, uint256 mintFee) = vault.quoteMint(copraAmount);
        (uint256 returned, uint256 redeemFee) = vault.quoteRedeem(copraAmount);
        // Same price: the backing paid in on mint always covers what redeem pays out plus its fee.
        assertGe(required - mintFee, returned + redeemFee);
        assertGt(required, 0);
    }

    // ---------------------------------------------------------------------
    // Solvency fuzzing
    // ---------------------------------------------------------------------

    /// @dev Bound a new oracle price to within the 20% collar of the current one.
    function _boundedPriceMove(uint256 seed) internal view returns (uint256) {
        (uint256 current,) = oracle.getCopraPriceUSD();
        uint256 band = (current * oracle.MAX_PRICE_CHANGE_BPS()) / 10000;
        return bound(seed, current - band, current + band);
    }

    /// @dev Redeem `user`'s whole balance, or assert the vault refused it to protect collateral.
    function _redeemAllOrRefuse(address user) internal returns (bool redeemed) {
        uint256 bal = copraToken.balanceOf(user);
        if (bal == 0) return true;

        (uint256 collateralToReturn, uint256 fee) = vault.quoteRedeem(bal);
        uint256 available = usdc.balanceOf(address(vault)) - vault.accumulatedFees();

        vm.prank(user);
        if (collateralToReturn + fee > available) {
            vm.expectRevert(CopraVault.InsufficientVaultCollateral.selector);
            vault.redeem(bal);
            return false;
        }
        vault.redeem(bal);
        assertEq(copraToken.balanceOf(user), 0);
        return true;
    }

    function testFuzz_MintAndRedeemSolvency(
        uint256 aliceMint,
        uint256 bobMint,
        uint256 mintPriceSeed,
        uint256 redeemPriceSeed,
        uint256 feeBps
    ) public {
        vault.setProtocolFee(bound(feeBps, 0, vault.MAX_FEE_BPS()));

        uint256 mintTarget = _boundedPriceMove(mintPriceSeed); // computed before prank: it calls the oracle
        vm.prank(oracleUpdater);
        oracle.updatePrice(mintTarget);
        (uint256 mintPrice,) = oracle.getCopraPriceUSD();

        // <= 5,000 COPRA each: worst case 5,000 * $1.68 * 1.01 < 10,000 USDC funded in setUp
        aliceMint = bound(aliceMint, 1, 5000 * 1e18);
        bobMint = bound(bobMint, 1, 5000 * 1e18);
        _mintAs(alice, aliceMint);
        _mintAs(bob, bobMint);
        assertGe(usdc.balanceOf(address(vault)), vault.accumulatedFees());

        uint256 redeemTarget = _boundedPriceMove(redeemPriceSeed); // computed before prank: it calls the oracle
        vm.prank(oracleUpdater);
        oracle.updatePrice(redeemTarget);
        (uint256 redeemPrice,) = oracle.getCopraPriceUSD();

        bool aliceOut = _redeemAllOrRefuse(alice);
        assertGe(usdc.balanceOf(address(vault)), vault.accumulatedFees());
        bool bobOut = _redeemAllOrRefuse(bob);
        assertGe(usdc.balanceOf(address(vault)), vault.accumulatedFees());

        // If the commodity did not appreciate, every holder must be able to exit in full.
        if (redeemPrice <= mintPrice) {
            assertTrue(aliceOut && bobOut, "redemption refused without a price rise");
            assertEq(copraToken.totalSupply(), 0);
        }

        // Fees stay claimable after everyone who could exit has exited.
        if (vault.accumulatedFees() > 0) {
            uint256 fees = vault.accumulatedFees();
            uint256 before = usdc.balanceOf(feeRecipient);
            vault.claimFees();
            assertEq(usdc.balanceOf(feeRecipient) - before, fees);
        }
    }
}
