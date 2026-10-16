# Copra Protocol Whitepaper

**Title**: Copra Protocol: An Autonomous On-Chain Currency Pegged to the Global Coconut Commodity Benchmark  
**Author**: Copra Protocol Core Contributors  
**Domain**: [https://copra.dev](https://copra.dev)  
**Ticker**: `$COPRA`  
**Version**: 1.0 (October 2026)  

---

## Abstract

We introduce **Copra Protocol**, a decentralized, autonomous Real-World Asset (RWA) currency that maps the macro value and production yield of the global coconut economy to an on-chain digital asset ($COPRA). Unlike speculative meme coins or fiat stablecoins, $COPRA is anchored to the global spot price of copra—the dried coconut meat that serves as the international price benchmark for the $15 billion coconut derivatives market. Backed 100% by transparent on-chain reserves and governed by zero-admin immutable smart contracts, Copra Protocol eliminates counterparty risk, provides a mathematical hard floor through permissionless redemptions, and creates an autonomous cash-flow engine for protocol participants.

---

## 1. Introduction & Background

### 1.1 The Macro Coconut Economy
The coconut palm (*Cocos nucifera*) represents one of the world's most resilient and productive agricultural systems:
- Over 62 million metric tons of coconuts are harvested annually.
- Over 75% of global supply originates from Indonesia, the Philippines, and India.
- Unlike annual row crops (such as wheat, corn, or soy) that require annual replanting and deplete topsoil, the coconut palm is a **perennial biological engine** with a productive lifespan exceeding 60 years.
- Mature palms produce harvestable clusters every 45 to 60 days year-round, generating an annuity-like biological cash flow.

### 1.2 The Problem in Commodity Crypto
Existing commodity tokens suffer from two extremes:
1. **Physical Custody Risks**: Tokens backed by vaulted physical goods (gold, agricultural grain) require trusted third-party warehouse operators, legal SPVs, inspection audits, and off-chain legal overhead.
2. **Purely Speculative Tokens**: Tokens with agricultural branding that have zero connection to real-world commodity pricing or production data.

Copra Protocol solves this by implementing an **Autonomous Peg Stability Module (PSM)**: $COPRA is fully backed by on-chain stable collateral (USDC) while its unit price dynamically tracks the verified international copra commodity benchmark.

---

## 2. Economic & Mathematical Architecture

### 2.1 The Unit of Account
The base benchmark unit is **1 kg of standardized commercial-grade Copra** as reported by the International Coconut Community (ICC) and World Bank Commodity trade bulletins.

### 2.2 Collateralization & Reserve Invariant
Every unit of $COPRA in circulation is backed by at least 100% stable reserve collateral locked inside the `CopraVault`:

```
Reserve_USDC >= Total_Supply(COPRA) × Copra_Price_USD
```

Because 100% backing is maintained programmatically, the protocol carries **zero liquidation cascades** and **zero bad debt risk**.

### 2.3 The Mint Function
Anyone may mint new $COPRA by depositing collateral at the prevailing oracle price plus a 0.5% protocol fee:

```
Collateral_In = [(Amount_COPRA × Price_USD) / 10^8] × (1 + Fee_BPS / 10000)
```

Where:
- `Fee_BPS` = 50 (0.50%)
- `Price_USD` = 8-decimal commodity price from the oracle

### 2.4 The Direct Redemption Hard Peg
Holders of $COPRA can burn tokens to withdraw the exact underlying dollar value in collateral minus a 0.5% redemption fee:

```
Collateral_Out = [(Amount_COPRA × Price_USD) / 10^8] × (1 - Fee_BPS / 10000)
```

This guarantees an inviolable **hard price floor**:
- If $COPRA ever trades below its benchmark price on secondary markets (such as Uniswap or Aerodrome), arbitrageurs immediately buy discounted $COPRA on the market and burn it in the vault for a risk-free profit.
- This automated arbitrage mechanism continuously pulls the secondary market price back to parity without human intervention.

---

## 3. Autonomous Oracle Design

The price feed contract (`CopraOracle.sol`) enforces rigorous stability parameters:
1. **Maximum Price Shift Guardrail**: Any single price update cannot deviate by more than 20% (2,000 basis points) from the previous price, preventing flash loan or manipulation attacks.
2. **Heartbeat Verification**: A strict 7-day heartbeat requirement ensures that stale pricing data causes transactions to safely revert until fresh data is verified.
3. **Decentralized Feed Architecture**: Prepared for integration with Chainlink Functions and UMA Optimistic Oracle for automated multi-source consensus.

---

## 4. Autonomous Fee Capture

The protocol implements a zero-governance fee distribution engine:
- A 0.5% fee is clipped on every mint and redemption.
- Fees accumulate directly in the reserve collateral token (USDC) inside the smart contract.
- The creator wallet (`feeRecipient`) can withdraw accumulated fees at any time via `claimFees()`.
- No admin key can alter the fee rate, pause the vault, or confiscate deposited user collateral.

---

## 5. Security & Immutability

1. **Non-Upgradeable**: Contracts do not use proxy patterns. The bytecode is deployed once and remains fixed forever.
2. **Reentrancy Protection**: All state-modifying functions utilize OpenZeppelin's `ReentrancyGuard`.
3. **Safe ERC-20 Transfers**: Collateral transfers use OpenZeppelin's `SafeERC20` to guarantee compatibility with non-standard token implementations.
4. **Zero Administrative Keys**: Once initialized, neither the deployer nor any multi-sig can seize user collateral or halt redemptions.

---

## 6. Conclusion

Copra Protocol demonstrates how Real-World Assets can be linked to decentralized finance without sacrificing autonomy or decentralization. By anchoring on-chain currency to the renewable, perennial output of the global coconut palm, Copra Protocol introduces a sovereign, self-balancing commodity primitive for the modern Web3 ecosystem.
