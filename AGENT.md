# Agent Guidance for Copra Protocol

Welcome to **Copra Protocol** ([https://copra.dev](https://copra.dev)).

This document provides autonomous coding assistants and contributors with critical technical architecture, build instructions, invariant constraints, and conventions required when interacting with this repository.

---

## 1. Project Overview

- **Name**: Copra Protocol
- **Ticker**: `$COPRA`
- **Domain**: [copra.dev](https://copra.dev)
- **Target Network**: Base Layer-2
- **Core Thesis**: An autonomous cryptocurrency pegged to the real-world international benchmark spot price of copra (dried coconut meat). Minted against its full value in transparent on-chain stable collateral (USDC) at the price of the day; see README "Backing & Price Moves" for what happens when the price moves.

---

## 2. Directory Structure

- `src/`: Solidity smart contracts (Solc 0.8.28)
  - `CopraToken.sol`: ERC-20 token with mint/burn hooks restricted to the vault.
  - `CopraVault.sol`: Peg Stability Module (PSM) and collateral reserve engine.
  - `CopraOracle.sol`: Commodity price oracle. One immutable `feedUpdater`; at most 20% change per update and one update per `MIN_UPDATE_INTERVAL` (1 day), which must stay below `HEARTBEAT`.
  - `interfaces/ICopraOracle.sol`: Interface for benchmark pricing.
- `test/`: Foundry unit and integration tests (`CopraProtocol.t.sol`).
- `script/`: Deployment scripts (`DeployCopra.s.sol` for testnet, `DeployCopraMainnet.s.sol` for Base mainnet; see `docs/MAINNET_DEPLOY.md`).
- `scripts/`: Operational utilities (oracle feeder script, hook setup).
- `docs/`: Technical specifications (`WHITEPAPER.md`, `ARCHITECTURE.md`).
- `web/`: Frontend landing page and dApp interface.
- `.githooks/`: Pre-commit (gitleaks + forge fmt) and pre-push (`scripts/check-committed-files.sh` on the commits being pushed, then forge test) hooks. Enable with `scripts/setup_hooks.sh`.

---

## 3. Essential Machine Commands

### Build
```bash
forge build --sizes
```

### Test
```bash
forge test -vvv
```

### Code Formatting
```bash
forge fmt --check  # Check formatting
forge fmt          # Apply formatting
```

### Secret Scan
```bash
gitleaks detect --config .gitleaks.toml --verbose
```

---

## 4. Architectural Invariants (Must Never Be Broken)

1. **Full Backing at Mint**:
   `mint` must take at least the full value of the new $COPRA at the current price (rounded up) plus the fee. This is the only backing the vault guarantees: it is not a solvency invariant, because `vaultCollateralBalance >= totalSupply(COPRA) * copraPriceUSD / 1e8 + accumulatedFees` can stop holding once the price rises after deposits.
2. **Fees Stay Backed**:
   `redeem` must never pay out collateral that backs `accumulatedFees`: it reverts with `InsufficientVaultCollateral` instead (`test_Vault_RedeemCannotLeaveFeesUnbacked`). Redemption pays 100% of the commodity value minus the fee only while the vault can cover it at the current price; it is not guaranteed after a price rise. See README "Backing & Price Moves".
3. **Immutability & Bounded Privilege**:
   Contracts must not use upgradeable proxies, and no role may gain a function that moves user collateral or pauses the vault. The privileged roles that exist (oracle updater, vault owner, registry owner) are listed in README "Trust Assumptions". A change to any role's powers must update that section and the `test_TrustAssumption_*` tests.
4. **Reentrancy Protection**:
   All state-modifying functions handling token transfers must use `nonReentrant`.

---

## 5. Conventions & Rules for Agents

- **Zero Secrets**: Never write or commit private keys, mnemonic phrases, or live API credentials. Use environment variables via `.env` (gitignored).
- **Run Formatting**: Always execute `forge fmt` after modifying `.sol` files.
- **Maintain Test Integrity**: Any modification or addition to smart contracts must include corresponding unit tests in `test/`. All tests must pass before opening a PR.

---

## 6. Brand & Casing Conventions

Always adhere to these exact casing and styling rules:

| Entity | Casing Standard | Example |
| :--- | :--- | :--- |
| **Website & Domain Links** | All-lowercase (`copra.dev`) | `https://copra.dev`, `copra.dev/docs` |
| **Navbar & Header Wordmark** | Title Case (`Copra.dev`) | `Copra` in bold white + `.dev` in emerald accent |
| **Protocol / Product Name** | Title Case (`Copra Protocol` or `Copra`) | "Copra Protocol is an autonomous currency..." |
| **Token Ticker Symbol** | All-caps (`$COPRA` or `COPRA`) | "Mint $COPRA with USDC" |

Never write the full domain in all-caps (`COPRA.DEV`); reserve all-caps strictly for the financial token ticker `$COPRA`.
