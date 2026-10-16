# Agent Guidance for Copra Protocol

Welcome to **Copra Protocol** ([https://copra.dev](https://copra.dev)).

This document provides autonomous coding assistants and contributors with critical technical architecture, build instructions, invariant constraints, and conventions required when interacting with this repository.

---

## 1. Project Overview

- **Name**: Copra Protocol
- **Ticker**: `$COPRA`
- **Domain**: [copra.dev](https://copra.dev)
- **Target Network**: Base Layer-2
- **Core Thesis**: An autonomous cryptocurrency pegged to the real-world international benchmark spot price of copra (dried coconut meat). Backed 100% by transparent on-chain stable collateral (USDC).

---

## 2. Directory Structure

- `src/`: Solidity smart contracts (Solc 0.8.28)
  - `CopraToken.sol`: ERC-20 token with mint/burn hooks restricted to the vault.
  - `CopraVault.sol`: Peg Stability Module (PSM) and collateral reserve engine.
  - `CopraOracle.sol`: Commodity price oracle. One immutable `feedUpdater`; at most 20% change per update.
  - `interfaces/ICopraOracle.sol`: Interface for benchmark pricing.
- `test/`: Foundry unit and integration tests (`CopraProtocol.t.sol`).
- `script/`: Deployment scripts (`DeployCopra.s.sol`).
- `scripts/`: Operational utilities (oracle feeder script, hook setup).
- `docs/`: Technical specifications (`WHITEPAPER.md`, `ARCHITECTURE.md`).
- `web/`: Frontend landing page and dApp interface.
- `.githooks/`: Pre-commit (gitleaks + forge fmt) and pre-push (forge test) hooks.

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

1. **Collateral Solvency Invariant**:
   `vaultCollateralBalance >= (totalSupply(COPRA) * copraPriceUSD / 1e8) + accumulatedFees`
2. **Hard Peg Floor**:
   Any user must always be able to call `vault.redeem(copraAmount)` and receive 100% of the commodity dollar value in collateral minus the protocol fee.
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
