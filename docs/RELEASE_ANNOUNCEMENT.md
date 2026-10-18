# Copra Protocol ($COPRA) — Public Open-Source Release & Distribution Kit

## 1. OpenGraph & Social Card Assets

| Asset | Path | Dimensions / Purpose |
| :--- | :--- | :--- |
| **Banner** | [`assets/copra-banner.jpg`](../assets/copra-banner.jpg) | `1774×887` master artwork: the README header and the GitHub repository's social preview |
| **OpenGraph Social Banner** | [`assets/og-image.jpg`](../assets/og-image.jpg) / [`web/og-image.jpg`](../web/og-image.jpg) | `1200×630` crop of the banner (257 KB, under WhatsApp's ~300 KB preview limit): the social card for X, Farcaster, Telegram, WhatsApp and Discord |
| **Primary Protocol Logo** | [`assets/copra_logo_512.png`](../assets/copra_logo_512.png) | `512×512` high-resolution token & brand icon |
| **Token Icon (256px)** | [`assets/copra_logo_256.png`](../assets/copra_logo_256.png) | `256×256` wallet & block explorer icon |
| **Web App Manifest** | [`web/site.webmanifest`](../web/site.webmanifest) | PWA metadata and icon definitions for `copra.dev` |

---

## 2. X (Twitter) Launch Thread

**Post 1 — Announcement**
Introducing Copra Protocol ($COPRA) — the autonomous coconut commodity currency on @base.

1 $COPRA is denominated in 1 kg of copra (dried coconut kernel), priced by an on-chain oracle, and minted against its full value in on-chain USDC reserves.

Live on Base Sepolia: https://copra.dev
Codebase (MIT): https://github.com/bytesbrains/copra

**Post 2 — Why Copra?**
Unlike fiat currencies that inflate or speculative tokens backed by nothing, coconut palms are a perennial biological engine—yielding harvests every 45–60 days for 60+ years across 90+ tropical nations.

Copra is the global benchmark commodity behind coconut oil, lauric acid, and agricultural trade.

**Post 3 — How the Peg Works**
Permissionless Peg Stability Module (PSM) in `CopraVault.sol`:
- Mint $COPRA at the oracle benchmark price by depositing USDC (+0.25% protocol fee)
- Redeem $COPRA for USDC at the benchmark price directly from the vault while it holds enough collateral (-0.25% protocol fee)
- 20% max single-update oracle shift collar & 7-day heartbeat safeguard

**Post 4 — Try the Live Testnet**
1. Visit https://copra.dev and connect your wallet on Base Sepolia
2. Claim 1,000 Testnet USDC from the built-in faucet
3. Mint & redeem $COPRA directly against the on-chain vault

---

## 3. Farcaster (`/base` / `/defi`) Launch Cast

Copra Protocol ($COPRA) is now open-source and live on Base Sepolia.

$COPRA tracks 1 kg of global benchmark copra (dried coconut kernel) minted against its full value in on-chain USDC, in a non-upgradeable Peg Stability Module:
- Permissionless minting & direct vault redemptions
- Automated commodity oracle feeder with 20% volatility guardrails and 7-day heartbeat enforcement
- Built-in Base Sepolia Testnet USDC faucet on the web interface

App: https://copra.dev
GitHub: https://github.com/bytesbrains/copra
Contracts (Base Sepolia, live set; always current at CopraRegistry `0x379cB5FED578D6F485ab1834C81E4F1CF4EABb25`):
- CopraToken: `0x53f5Ef67439E8565559f9C450cFF5CB49b4b996C`
- CopraVault: `0xbB1CDe2B3c2f8F1D6AAFc1718a92192cb3335f54`
- CopraOracle: `0x4F409293636dCf579f12e7627137e62A8a790b9A`
