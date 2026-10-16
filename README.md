<div align="center">
  <img src="assets/copra_logo_256.png" alt="Copra Protocol Logo" width="128" />
  <h1>Copra Protocol ($COPRA)</h1>
  <p><strong>The Global Coconut Commodity Currency</strong></p>
  <p><a href="https://copra.dev">copra.dev</a> • Target Network: <strong>Base L2</strong></p>
</div>

Copra Protocol is an autonomous cryptocurrency pegged to the real-world international benchmark value of copra—the dried coconut meat that serves as the global price anchor for the multi-billion dollar coconut economy.

---

## 1. Executive Summary

Unlike speculative meme tokens or gold-backed stablecoins, **Copra Protocol** bridges decentralized finance with a renewable, perennial biological asset:

- **Perennial Biological Engine**: Coconut palms produce continuous yields every 45 to 60 days for over 60 years.
- **On-Chain Collateral, Full at Mint**: Every $COPRA is minted against its full value in USDC at the current price, locked in the protocol vault. The collateral pool is fixed while the price floats, so coverage moves with the price. See [Backing & Price Moves](#backing--price-moves).
- **Autonomous Peg Stability**: Anyone can mint $COPRA by depositing collateral at the current commodity benchmark price, or burn $COPRA to reclaim its value at the current price directly from the vault, while the vault holds enough collateral.
- **Immutable, Non-Custodial Contracts**: No proxies, no upgrade path, no pause function, and no function that can withdraw user collateral. Three privileged roles do exist, and the oracle updater is the one you trust most. See [Trust Assumptions](#trust-assumptions).

---

## 2. Core Smart Contract Architecture

The protocol codebase is located in [src/](src/):

- [CopraToken.sol](src/CopraToken.sol): Standard ERC-20 token ($COPRA) with minting and burning permissions restricted exclusively to the autonomous vault.
- [CopraVault.sol](src/CopraVault.sol): The collateral reserve and Peg Stability Module (PSM). Handles permissionless minting, burning, direct redemptions, and autonomous fee capture.
- [CopraOracle.sol](src/CopraOracle.sol): Price oracle for the international copra benchmark (USD, 8 decimals). A single authorized updater posts prices, limited to a 20% change per update.
- [CopraRegistry.sol](src/CopraRegistry.sol): On-chain pointer to the live contract set, read by copra.dev, the oracle feeder and the release manifest.
- [TestnetUSDC.sol](src/testnet/TestnetUSDC.sol): Public Base Sepolia testnet collateral token with a permissionless `faucet()` for frictionless testing.

Further technical documentation:
- [Whitepaper](docs/WHITEPAPER.md)
- [Architecture & Security Model](docs/ARCHITECTURE.md)
- [Contributing Guidelines](CONTRIBUTING.md)
- [Security Policy](SECURITY.md)

### Trust Assumptions

Copra is **not ownerless**. Three privileged roles exist. On Base Sepolia, all three are held by the deployer, `0x91d3019b38185b517Bb98B7BB4953c137F5EEb8E`:

| Role | Can | Limits |
| :--- | :--- | :--- |
| **Oracle updater**<br>`CopraOracle.feedUpdater` (immutable) | Post the copra price that every mint and redeem uses | At most 20% change **per update**, but there is **no minimum interval** between updates, so a run of updates can reach any price, even within one block |
| **Vault owner**<br>`CopraVault`, `Ownable2Step` | Set the protocol fee and the fee recipient; transfer or renounce ownership | Fee capped at 1.00% (`MAX_FEE_BPS = 100`). `setCopraToken` is one-shot and already used |
| **Registry owner**<br>`CopraRegistry`, `Ownable2Step` | Choose which contract set copra.dev, the oracle feeder and the release manifest use | The set must be wired to itself (vault ↔ token ↔ oracle ↔ collateral). It cannot change contracts already deployed |

**The oracle updater is the main trust assumption.** No function lets any role withdraw user collateral, and `claimFees()` can only send `accumulatedFees` to `feeRecipient`. But redemptions pay out at the oracle price. An updater that is compromised or malicious can raise the price, redeem its own $COPRA and drain the vault, leaving other holders unable to redeem. If the updater stops posting, the price goes stale after 7 days, and mint and redeem revert until it resumes. Redemptions are always paid from the USDC the vault actually holds: if the price rises after deposits, the vault can be worth less than all $COPRA in circulation, and `redeem` reverts once the vault runs short.

These behaviors are pinned by tests (`test_TrustAssumption_*`, `test_Vault_MintAndRedeemRevertOnStalePrice` and `test_Vault_RedeemCannotLeaveFeesUnbacked` in [test/CopraProtocol.t.sol](test/CopraProtocol.t.sol)), so a change to them also has to change this section.

---

## 3. Mathematical Peg Mechanics

### Direct Minting
A user deposits collateral (e.g., USDC) to mint $COPRA:
```
Collateral Required = (COPRA_Amount × Copra_Price_USD) / 1e8 + Protocol_Fee (0.25%)
```

### Direct Redemption
A holder can burn $COPRA to claim collateral at the current benchmark price, as long as the vault holds enough:
```
Collateral Returned = (COPRA_Amount × Copra_Price_USD) / 1e8 - Protocol_Fee (0.25%)
```

### Backing & Price Moves
Collateral is a fixed pool of USDC. The value it has to cover is `totalSupply × price`, which moves with the oracle:

- **At mint**: each mint deposits the full value of the new $COPRA at that moment's price (rounded up), plus the fee.
- **Price falls**: the vault holds more USDC than all $COPRA is worth. The surplus stays in the vault.
- **Price rises**: the vault holds less USDC than all $COPRA is worth. `redeem` pays first-come-first-served at the new price and reverts with `InsufficientVaultCollateral` once the backing runs out, so the last holders to redeem cannot exit until the price falls or new mints add collateral.

There is no over-collateralization buffer and no redemption haircut today. Redemption is a price floor only while the vault is fully covered at the current price. `test_Vault_RedeemCannotLeaveFeesUnbacked` shows a redeem reverting after a 0.14% price rise.

### Self-Balancing Arbitrage
- **If Market Price < Benchmark Price**: Arbitrageurs buy cheap $COPRA on decentralized exchanges and burn it in the vault for its benchmark value, pushing the market price back up to peg.
- **If Market Price > Benchmark Price**: Arbitrageurs deposit collateral to mint new $COPRA at the benchmark price and sell it on DEXs for profit, driving the price back down to peg.

---

## 4. Creator Economics & Autonomous Fee Capture

The creator does not need administrative control over user reserves to earn revenue. The smart contracts autonomously capture a **0.25% protocol fee** (configurable up to an immutable 1.0% hard cap) on all mints and redemptions:

- Fees accumulate directly in reserve collateral (USDC) inside `CopraVault.sol`.
- The designated `feeRecipient` wallet receives accumulated earnings when `claimFees()` is triggered.
- `feeRecipient` is updateable by the contract owner via OpenZeppelin's `Ownable2Step`, enabling progressive decentralization (e.g., migrating from a creator wallet to a community staking pool or DAO treasury) with zero risk of typos or lockout.
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
Ran 10 tests for test/CopraProtocol.t.sol:CopraProtocolTest
[PASS] test_ClaimProtocolFees()
[PASS] test_InitialState()
[PASS] test_MintCopra()
[PASS] test_OraclePriceUpdate()
[PASS] test_OracleRevertOnUnauthorized()
[PASS] test_Ownable2StepTransfer()
[PASS] test_RedeemCopra()
[PASS] test_SetFeeRecipient()
[PASS] test_SetProtocolFee()
[PASS] test_TestnetUSDC_Faucet()
Suite result: ok. 10 passed; 0 failed; 0 skipped
```

---

## 6. Live Testnet Deployment (Base Sepolia)

The live contract set is published on-chain by **CopraRegistry** at a permanent address. The web app, the oracle feeder and release notes all resolve addresses from it, so redeploys never require editing them. A snapshot is kept in [deployments/base-sepolia.json](deployments/base-sepolia.json) (Chain ID `84532`), and each GitHub release ships a manifest read from the registry.

| Contract | Address | Explorer |
| :--- | :--- | :--- |
| **CopraRegistry (permanent)** | `0x379cB5FED578D6F485ab1834C81E4F1CF4EABb25` | [Basescan](https://sepolia.basescan.org/address/0x379cB5FED578D6F485ab1834C81E4F1CF4EABb25) |
| **CopraToken (`$COPRA`)** | `0x53f5Ef67439E8565559f9C450cFF5CB49b4b996C` | [Basescan](https://sepolia.basescan.org/address/0x53f5Ef67439E8565559f9C450cFF5CB49b4b996C) |
| **CopraVault (PSM)** | `0xbB1CDe2B3c2f8F1D6AAFc1718a92192cb3335f54` | [Basescan](https://sepolia.basescan.org/address/0xbB1CDe2B3c2f8F1D6AAFc1718a92192cb3335f54) |
| **CopraOracle** | `0x4F409293636dCf579f12e7627137e62A8a790b9A` | [Basescan](https://sepolia.basescan.org/address/0x4F409293636dCf579f12e7627137e62A8a790b9A) |
| **TestnetUSDC** | `0xd6bC2f148b750e47936f8720aF84DDFc061404DF` | [Basescan](https://sepolia.basescan.org/address/0xd6bC2f148b750e47936f8720aF84DDFc061404DF) |

### Deploy Your Own Instance
1. Obtain free Base Sepolia testnet ETH from [faucets.chain.link](https://faucets.chain.link) or [base.org/faucets](https://www.base.org/faucets).
2. Set your environment variables:
   ```bash
   export PRIVATE_KEY="your_wallet_private_key"
   export BASE_SEPOLIA_RPC="https://base-sepolia-rpc.publicnode.com"
   ```
3. Run the deployment script:
   ```bash
   forge script script/DeployCopra.s.sol:DeployCopra --rpc-url $BASE_SEPOLIA_RPC --broadcast
   ```

---

## 7. Web Interface for copra.dev

A clean, responsive dApp is included in [web/index.html](web/index.html) and deployed via Cloudflare Workers static assets ([wrangler.jsonc](wrangler.jsonc)).

---

## 8. Brand & Identity Guidelines

| Context | Canonical Format | Example |
| :--- | :--- | :--- |
| **Domain & Website Links** | `copra.dev` (lowercase) | [https://copra.dev](https://copra.dev) |
| **Navigation & Wordmark** | `Copra.dev` (Title Case + accent) | **Copra**<span style="color:#34d399">.dev</span> |
| **Protocol / Project Name** | `Copra Protocol` or `Copra` | *"Copra Protocol is an autonomous currency..."* |
| **Token Ticker Symbol** | `$COPRA` (All-caps) | *"1 $COPRA tracks 1 kg of Copra"* |

