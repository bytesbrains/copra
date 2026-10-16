<div align="center">
  <img src="assets/copra_logo_256.png" alt="Copra Protocol Logo" width="128" />
  <h1>Copra Protocol ($COPRA)</h1>
  <p><strong>The Global Coconut Commodity Currency</strong></p>
  <p><a href="https://copra.dev">copra.dev</a> • Target Network: <strong>Base L2</strong></p>
</div>

Copra Protocol is an autonomous, ownerless cryptocurrency pegged to the real-world international benchmark value of copra—the dried coconut meat that serves as the global price anchor for the multi-billion dollar coconut economy.

---

## 1. Executive Summary

Unlike speculative meme tokens or gold-backed stablecoins, **Copra Protocol** bridges decentralized finance with a renewable, perennial biological asset:

- **Perennial Biological Engine**: Coconut palms produce continuous yields every 45 to 60 days for over 60 years.
- **100% On-Chain Collateral Backing**: Every $COPRA in circulation is backed 100% by stable reserves (USDC) locked in the protocol vault.
- **Autonomous Peg Stability**: Anyone can mint $COPRA by depositing collateral at the current commodity benchmark price, or burn $COPRA to reclaim full collateral value directly from the vault.
- **Zero Governance**: The protocol has no admin keys, no pause buttons, and no DAO politics. Once deployed, it runs indefinitely as immutable code on Base.

---

## 2. Core Smart Contract Architecture

The protocol codebase is located in [src/](file:///Users/nandal/Desktop/desk/repos/cocobuck/src/):

- [CopraToken.sol](file:///Users/nandal/Desktop/desk/repos/cocobuck/src/CopraToken.sol): Standard ERC-20 token ($COPRA) with minting and burning permissions restricted exclusively to the autonomous vault.
- [CopraVault.sol](file:///Users/nandal/Desktop/desk/repos/cocobuck/src/CopraVault.sol): The collateral reserve and Peg Stability Module (PSM). Handles permissionless minting, burning, direct redemptions, and autonomous fee capture.
- [CopraOracle.sol](file:///Users/nandal/Desktop/desk/repos/cocobuck/src/CopraOracle.sol): Decentralized oracle adapter streaming international copra commodity prices (USD, 8 decimals) with price volatility guardrails.

---

## 3. Mathematical Peg Mechanics

### Direct Minting
A user deposits collateral (e.g., USDC) to mint $COPRA:
```
Collateral Required = (COPRA_Amount × Copra_Price_USD) / 1e8 + Protocol_Fee (0.5%)
```

### Direct Redemption (Hard Peg Floor)
A holder can burn $COPRA to claim underlying collateral at any time:
```
Collateral Returned = (COPRA_Amount × Copra_Price_USD) / 1e8 - Protocol_Fee (0.5%)
```

### Self-Balancing Arbitrage
- **If Market Price < Benchmark Price**: Arbitrageurs buy cheap $COPRA on decentralized exchanges and burn it in the vault for full dollar value, pushing the market price back up to peg.
- **If Market Price > Benchmark Price**: Arbitrageurs deposit collateral to mint new $COPRA at the benchmark price and sell it on DEXs for profit, driving the price back down to peg.

---

## 4. Creator Economics & Autonomous Fee Capture

The creator does not need administrative control to earn revenue. The smart contracts autonomously capture a **0.5% protocol fee** on all mints and redemptions:

- Fees accumulate directly in reserve collateral (USDC) inside `CopraVault.sol`.
- The designated `feeRecipient` wallet can call `claimFees()` at any time to withdraw accumulated earnings.
- As global trading and minting volume expands, the fee recipient earns perpetual, passive, dollar-denominated cash flow.

---

## 5. Development & Testing

Built with Foundry. All tests pass with zero warnings.

### Run Tests
```bash
forge test -v
```

### Test Suite Output
```text
Ran 6 tests for test/CopraProtocol.t.sol:CopraProtocolTest
[PASS] test_ClaimProtocolFees()
[PASS] test_InitialState()
[PASS] test_MintCopra()
[PASS] test_OraclePriceUpdate()
[PASS] test_OracleRevertOnUnauthorized()
[PASS] test_RedeemCopra()
Suite result: ok. 6 passed; 0 failed; 0 skipped
```

---

## 6. Zero-Cost Testnet Deployment (Base Sepolia)

1. Obtain free Base Sepolia testnet ETH from [faucets.chain.link](https://faucets.chain.link) or [base.org/faucets](https://www.base.org/faucets).
2. Set your environment variables:
   ```bash
   export PRIVATE_KEY="your_wallet_private_key"
   export BASE_SEPOLIA_RPC="https://sepolia.base.org"
   ```
3. Run the deployment script:
   ```bash
   forge script script/DeployCopra.s.sol:DeployCopra --rpc-url $BASE_SEPOLIA_RPC --broadcast
   ```

---

## 7. Web Interface for copra.dev

A clean, responsive dApp is included in [web/index.html](file:///Users/nandal/Desktop/desk/repos/cocobuck/web/index.html).

### Host on Vercel or Cloudflare Pages for Free:
- Point your domain `copra.dev` nameservers to Cloudflare or Vercel.
- Deploy the `/web` folder as the root directory.
- Instant, zero-cost static hosting with automatic HTTPS.
