# COPRA-001 — $COPRA Reserve and Redemption Protocol

## Overcollateralized Synthetic Copra, Settled Against GCPI

**Specification:** COPRA-001\
**Version:** 0.2 Draft\
**Date:** 22 October 2026\
**Network:** Base L2\
**Price input:** [GCPI-001](GCPI-001.md), the Global Copra Price Index\
**Replaces:** the v1 `CopraVault` design (fixed USDC pool redeemed at the oracle price)\
**Status:** Proposed design — parameters calibrated by economic simulation over GCPI history ([ECONOMICS](../../econ/ECONOMICS.md), #96), and the §16 questions resolved except regulation (#98). The design requires independent security review before deployment

---

# 1. Purpose

$COPRA is an ERC-20 token whose value tracks the GCPI price of one reference kilogram of copra.

It lets people hold wealth denominated in copra, transfer it, trade it, and exit at the copra price, without the protocol holding physical copra and without the protocol or its developers supplying capital.

GCPI-001 §15 requires the reserve protocol to be specified and audited separately from the index. This document is that specification.

## 1.1 Design constraints

1. **No physical commodity.** The protocol holds no copra, warehouse receipts, or off-chain inventory.
2. **No protocol-owned capital.** No developer, company, or treasury funds a backstop. Every unit of collateral is supplied by a participant who chose the risk.
3. **Neutrality.** The protocol and its developers hold no position in the copra price and earn nothing from its direction. Fees depend on volume, never on price movement.
4. **Price tracking in both directions.** A holder gains when GCPI rises and loses when it falls.
5. **Fair exit.** No holder's ability to exit depends on redeeming before other holders.
6. **Slow oracle.** GCPI is published per calculation period: monthly in v1 (GCPI-001 §8.6), up to about two months after the month ends. The design must stay safe when the price is weeks to months old.
7. **Immutability.** No proxies, no upgrade path, no pause, no administrator who can move collateral or change risk parameters.

## 1.2 Why v1 cannot meet them

The v1 vault holds a fixed pool of USDC and redeems every $COPRA at the current oracle price (README, "Backing & Price Moves").

| Price move | v1 outcome | Constraint broken |
| --- | --- | --- |
| GCPI rises | Liabilities exceed the pool. Early redeemers are paid in full, and later redeemers get `InsufficientVaultCollateral`. | 4, 5 |
| GCPI falls | The pool exceeds liabilities. The surplus belongs to nobody and stays in the vault. | — (value stranded) |
| A published source moves before the index finalizes | Anyone can mint or redeem at a price already known to be wrong, at the expense of other holders | 5 |

The root cause is that nobody holds the other side of the copra exposure. A USDC pool does not move with copra. This specification assigns that exposure to participants who take it voluntarily and are paid for it.

## 1.3 What this protocol does not promise

- It does not promise that $COPRA beats inflation. Copra is a cyclical agricultural commodity, and its long-run real return is an empirical question for the GCPI backtest, not an assumption of this design.
- It does not promise redemption at the GCPI price under every condition. §11 defines the conditions under which redemption is reduced pro rata, and §12 defines when it is delayed.
- It does not provide physical delivery.

A holder's return is the change in GCPI, minus fees, minus any premium paid to acquire $COPRA in the market.

---

# 2. Model Overview

$COPRA is minted only against **positions**. A position is owned by one address and holds:

- **Collateral** `C_j`: USDC deposited by the owner.
- **Debt** `D_j`: the amount of $COPRA the position has minted and not yet repaid.

The owner of a position must keep its collateral worth more than its debt at the GCPI price. A minter who keeps the $COPRA they mint has no net copra exposure, because their tokens and their debt move together. A minter who sells or transfers the $COPRA is short copra: they gain when GCPI falls and lose when it rises. The buyer of that $COPRA is long copra.

Every $COPRA in existence is backed by the collateral of the positions whose debt created it, at a ratio above 100%.

```
totalSupply($COPRA)  =  Σ D_j
circulating supply   =  Σ D_j − escrowed $COPRA (pending redemptions, §8)
```

## 2.1 Participants

| Participant | Action | Incentive | Risk |
| --- | --- | --- | --- |
| Holder | Buys, holds, transfers, pays with, or redeems $COPRA | Copra-denominated wealth and trading | GCPI falls |
| Minter | Opens a position, deposits USDC, mints $COPRA | Short copra exposure: a hedge for copra inventory, a view that copra will fall, or a market premium (§10.3) | GCPI rises, and liquidation |
| Liquidator | Repays unsafe positions and receives collateral at a discount | Liquidation bonus | Execution and price risk on the $COPRA used to repay |
| Redemption settler | Settles queued redemptions once their price is final | Gas reimbursement from the redemption fee (§10.2) | Gas |
| DEX liquidity provider | Supplies $COPRA and USDC to trading pools | Trading fees | Impermanent loss |
| Arbitrageur | Mints when $COPRA trades above GCPI and redeems when it trades below | The spread | Being wrong about the next GCPI value |

No participant role is privileged. Every action is available to any address that meets its conditions.

Copra producers, exporters, and traders holding inventory are natural minters. A fall in copra prices reduces the value of their stock, and a short $COPRA position offsets that loss.

---

# 3. Units and Arithmetic

| Quantity | Unit | Decimals |
| --- | --- | --- |
| $COPRA amount and position debt | 1 token = 1 GCPI reference kilogram | 18 |
| Collateral | USDC | 6 |
| GCPI price `P_t` | USD per reference kilogram | 8 |
| Ratios and fees | Basis points | 0 (integer bps, denominator 10,000) |

The USDC value of a debt `D` at price `P` is:

```
Value(D, P) = D × P / 10^8 / 10^12
```

All consensus-critical arithmetic is fixed-point integer arithmetic with full-precision multiply-divide (`mulDiv`).

**Rounding rule:** every rounding favors the system and its remaining holders, except position debt balances, which round down so every position stays repayable (below).

- Debt value in ratio checks rounds up.
- Collateral value in ratio checks rounds down.
- Payouts to redeemers, liquidators, and withdrawing owners round down.
- Position debt balances round down: realized debt tracks the debt that exists within scale dust (about a wei per token of outstanding base per operation), so every position stays repayable and closeable up to dust. Rounding up instead would strand unrepayable dust above `totalSupply`. The dust-scale remainder stays accounted in `totalDebt` and remains redeemable. Collateral removed from positions rounds up.

---

# 4. Price Input

## 4.1 GCPI interface

The protocol reads finalized GCPI period records. It requires, for every period `t`:

- The period identifier `t`, increasing by one per calculation period.
- The period's time window, derivable on-chain for any `t` (for example a fixed genesis time and cadence), so that the period containing a given timestamp is known before that period finalizes.
- The finalized price `P_t`.
- The period status (GCPI-001 §9.4).
- The finalization timestamp.

The v1 `ICopraOracle` interface returns only a price and a timestamp, which is not sufficient. Forward-priced settlement (§8) must name a specific future period. COPRA-001 therefore reads GCPI period records directly, through a read-only adapter bound immutably at deployment.

## 4.2 Usable price

The **usable price** at any moment is the price of the latest finalized period, provided that:

1. Its status is `VALID`.
2. Its finalization is no older than `MAX_PRICE_AGE`.

If either condition fails, the protocol has **no usable price** and enters the price-unavailable state (§12).

The protocol never substitutes a default, a last-known value beyond `MAX_PRICE_AGE`, or a value from any other source.

## 4.3 Separation from GCPI

COPRA-001 contracts have no ability to submit, finalize, influence, or select GCPI values. GCPI contracts have no ability to mint $COPRA, move collateral, or change any COPRA-001 parameter (GCPI-001 Invariant 8).

The GCPI methodology version is fixed at deployment. Adopting a new GCPI version requires a new COPRA-001 deployment (§14).

---

# 5. Positions

## 5.1 Collateral ratio

For position `j` at price `P`:

```
CR_j = C_j / Value(D_j, P)
```

A position with zero debt has an infinite collateral ratio.

The **system collateral ratio** is:

```
TCR = Σ C_j / Value(Σ D_j, P)
```

## 5.2 Thresholds

| Threshold | Meaning |
| --- | --- |
| `MCR` (minimum collateral ratio) | The ratio a position must meet after any action that adds debt or removes collateral |
| `LR` (liquidation ratio) | Below this ratio, anyone may liquidate the position. `LR < MCR`. |

The gap between `MCR` and `LR` is the owner's reaction buffer. The gap between `LR` and 100% is the liquidator's buffer. §13 defines how both are sized.

## 5.3 Operations

| Operation | Effect | Allowed when |
| --- | --- | --- |
| `open` | Creates a position owned by the caller | Always |
| `deposit(j, amount)` | Adds USDC to position `j`'s collateral. Anyone may deposit to any position. | Always |
| `mint(j, amount)` | Adds `amount` to `D_j` and mints `amount` $COPRA to the owner. Charges the mint fee from collateral (§10.1). | Owner only. Usable price exists, system is not in shortfall (§11.3), `D_j ≥ MIN_DEBT` after, and `CR_j ≥ MCR` after. |
| `repay(j, amount)` | Burns `amount` $COPRA from the caller and reduces `D_j` | Always. Anyone may repay any position. |
| `withdraw(j, amount)` | Sends USDC from `C_j` to the owner | Owner only. If `D_j = 0`: always. Otherwise: usable price exists, system is not in shortfall, and `CR_j ≥ MCR` after. |
| `close(j)` | Repays all debt from the caller and withdraws all collateral | Owner only, always (it is `repay` then `withdraw` with zero debt) |

**Risk-reducing actions are never blocked.** `deposit`, `repay`, and withdrawal from a debt-free position are available in every protocol state, including when no usable price exists.

A position's debt is never transferable. $COPRA tokens are freely transferable, and transferring them never moves the debt that created them.

## 5.4 Minimum debt

A position with non-zero debt must hold at least `MIN_DEBT`. This keeps every liquidatable position large enough that liquidating it is worth the gas.

---

# 6. Token

$COPRA is a standard ERC-20 with 18 decimals.

- Only the COPRA-001 position manager may mint.
- Only the position manager may burn, through `repay`, liquidation, and redemption settlement.
- Transfers are never blocked, paused, or restricted, in any protocol state.

---

# 7. Exit Paths

A holder can exit in two ways:

1. **Market exit.** Sell $COPRA on any market, at the market price, immediately.
2. **Protocol redemption.** Exchange $COPRA for USDC from minters' collateral at a future GCPI price (§8).

Protocol redemption is the price floor. If $COPRA trades below GCPI, arbitrageurs buy it in the market and redeem it, which pushes the market price back toward GCPI.

Minting is the price ceiling. If $COPRA trades above GCPI, minters mint at GCPI-based collateral requirements and sell into the market.

---

# 8. Forward-Priced Redemption

## 8.1 The problem it solves

GCPI lags its sources. A national publisher may announce a price fall days before the GCPI period containing it finalizes. If redemption paid the current usable price, anyone could redeem at a price already known to be too high, and minters would pay the difference.

## 8.2 Rule

A redemption is settled at the price of a period **whose source observations had not yet been published when the redemption was requested.**

1. `requestRedeem(amount)` transfers `amount` $COPRA from the caller into escrow and records the request in period `k`, the GCPI period whose time window contains the timestamp of the block that includes the request. `k` is defined by time, not by finalization: the latest finalized period lags `k`, and using it would let a request settle at a period whose sources are already being published.
2. The request settles at the first period `s ≥ k + 1` that finalizes with status `VALID`.
3. Once period `s` is finalized, anyone may call `settle` for requests that settle at `s`.
4. Every request settling at period `s` receives the same price `P_s`, regardless of the order in which settlements are executed.

Settlement at `k + 1` rather than `k` is required because sources for period `k` are published during period `k`, so a request made late in period `k` could already know most of `P_k`.

GCPI v1 is monthly and published up to about two months after the month ends (GCPI-001 §8.6), so a redemption settles about three to four months after it is requested. A weekly GCPI would settle in one to two weeks. The cadence is a GCPI-001 decision, and this delay is its direct consequence for holders.

## 8.3 Settlement

For a request of `amount` settling at `P_s`:

```
Gross     = Value(amount, P_s)
Fee       = Gross × REDEEM_FEE_BPS / 10000
Payout    = Gross − Fee
```

- The escrowed `amount` of $COPRA is burned.
- Total debt `Σ D_j` decreases by `amount`.
- Total collateral `Σ C_j` decreases by `Payout`.
- The fee is not removed from collateral. It stays with the positions redeemed against, as compensation to the minters whose positions were partly closed without their action.

**Allocation across positions:** the debt reduction and collateral reduction are applied to all positions in proportion to their debt, using global accumulators so that settlement cost does not grow with the number of positions. Each position pays out the same collateral per unit of debt redeemed, so positions with a higher ratio see their ratio rise.

**Cover rule:** a position covers its share up to its collateral. Anything liquidatable was liquidated before settlement, so only unliquidatable dust fails to cover; its uncovered debt is bad debt and redistributes under §11.1, and the position closes. The alternatives (lowest-ratio-first, collateral-proportional takes) were simulated against this rule over 142 rolling windows and neither improves safety ([ECONOMICS](../../econ/ECONOMICS.md#4-allocation-proportional-lowest-first-or-collateral-proportional), §16 item 1).

If the system is in shortfall when the request settles, the payout is reduced pro rata (§11.3).

## 8.4 Cancellation

A redemption request cannot be cancelled once any period at or after `k + 1` has finalized with status `VALID`. From that moment its settlement price is fixed, and a cancellation would be a free option against minters.

If no qualifying period has finalized within `REDEEM_EXPIRY` after the request, the requester may cancel and recover the escrowed $COPRA. At that point no settlement price exists, so cancellation gives no informational advantage.

---

# 9. Liquidation

## 9.1 Condition

Position `j` is liquidatable when a usable price exists and `CR_j < LR` at that price.

No liquidation is possible without a usable price.

## 9.2 Execution

Anyone may liquidate. The liquidator supplies $COPRA to repay some or all of the position's debt.

For a repayment `x`:

```
Seized = min( Value(x, P) × (1 + LIQ_BONUS_BPS / 10000),  C_j )
```

- The `x` $COPRA is burned and `D_j` decreases by `x`.
- `Seized` USDC moves from `C_j` to the liquidator.
- A partial liquidation must leave either zero debt or at least `MIN_DEBT`, and must not leave `CR_j` below its value before the liquidation.
- After a full liquidation, any remaining collateral stays in the position for its owner to withdraw.

Liquidation uses the usable price of a finalized period. The liquidator acts on a known price and takes no forward-price risk.

Liquidations do not affect GCPI. Unlike systems whose collateral is a volatile crypto asset, a liquidation here sells nothing that feeds back into the price, so liquidations cannot cascade through the oracle.

## 9.3 Liquidator capital

Liquidators need $COPRA to repay debt. They may buy it in the market, including within the same transaction through a flash swap. The protocol does not supply it.

---

# 10. Fees

All fee rates are immutable constants of the deployment.

## 10.1 Mint fee

`MINT_FEE_BPS` of `Value(amount, P)` is charged from the position's collateral when `amount` is minted. It is split:

- `MINT_FEE_PROTOCOL_SHARE` to the protocol fee recipient.
- The remainder to the redemption settlement reserve (§10.2).

## 10.2 Redemption fee

`REDEEM_FEE_BPS` of the gross redemption value stays with the positions redeemed against (§8.3).

The redemption settlement reserve reimburses settlers' gas per settled batch, up to a fixed cap per batch. When the reserve is empty, settlement continues to be permissionless and unreimbursed. Holders always have the option of settling their own requests.

## 10.3 Market premium

The protocol defines no funding rate in this version (§16 item 2).

If demand to hold $COPRA exceeds demand to mint it, $COPRA trades above GCPI. A minter can then mint against GCPI and sell at the market premium, so the premium itself pays minters for taking the short side. Supply grows until the premium no longer covers the minters' risk. Simulation puts the break-even premium at about 1% a year at zero premium ([ECONOMICS](../../econ/ECONOMICS.md#5-funding-what-minters-earn)): drift, volatility drag and the ~2% lag transfer on each redemption, net of redeem fees.

A funding rate paid from holders to minters, as in perpetual futures, would need a market price of $COPRA on-chain. A DEX price is manipulable in the thin pools a new token has, so a funding rate is deferred to a later version — and only with evidence that supply is inadequate at the market premium, and a measurement that is not manipulable.

## 10.4 Protocol fee recipient

The protocol fee recipient is an immutable address set at deployment and disclosed in the deployment record (§16 item 7). It confers no power: it cannot change any rate, threshold, price input, or position. Changing the recipient is a new deployment (§14).

Protocol revenue depends only on minting volume, never on the direction of GCPI.

---

# 11. Losses

## 11.1 Bad debt

A position has bad debt when `C_j < Value(D_j, P)`. Liquidating it is unprofitable at full repayment, so the liquidation rule changes:

- The liquidator may repay only the debt the collateral covers with the bonus: `x = C_j / (P × (1 + LIQ_BONUS))`, and receives all of `C_j`.
- The remaining debt `D_j − x`, now with no collateral, is **redistributed**: it is added to every other position's debt in proportion to that position's collateral, using global accumulators.

Redistribution keeps every outstanding $COPRA backed by some position. The loss falls on minters, the side of the market that chose copra-price risk, not on holders. The same rule absorbs the uncovered remainder when a position cannot cover its redemption share (§8.3 cover rule).

## 11.2 System health

Redistribution lowers other positions' ratios and may make some of them liquidatable in turn. This continues until every remaining position is above `LR`, or the system is in shortfall.

## 11.3 Shortfall

The system is in **shortfall** when `TCR < 100%` at the usable price.

In shortfall:

- `mint` is disabled.
- `withdraw` is disabled for positions with debt.
- Liquidations continue.
- Redemptions settle at a pro-rata payout per unit:

```
PayoutPerUnit = P_s × min( 1, TCR_s ) × (1 − REDEEM_FEE_BPS / 10000)
```

where `TCR_s = Σ C_j / Value(Σ D_j, P_s)` is the system ratio at settlement (§5.1). Every holder redeeming at the same period receives the same rate. No holder can be paid in full at the expense of another.

The system leaves shortfall when `TCR ≥ 100%` at a later usable price, through a price fall, deposits, or repayments.

Shortfall is the failure of this design's safety margins. §13 sizes the margins so that, on historical data, shortfall requires a GCPI move larger than any observed over the liquidation window.

---

# 12. Protocol States

| State | Condition | `mint` | `withdraw` (with debt) | `repay`, `deposit`, debt-free `withdraw` | Liquidation | Redemption request | Redemption settlement | Transfers |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **NORMAL** | Usable price, `TCR ≥ 100%` | Yes | Yes | Yes | Yes | Yes | Yes, at `P_s` | Yes |
| **PRICE_UNAVAILABLE** | No usable price (GCPI not `VALID`, or older than `MAX_PRICE_AGE`) | No | No | Yes | No | Yes (queued) | Only for requests whose period `s` is already final | Yes |
| **SHORTFALL** | Usable price, `TCR < 100%` | No | No | Yes | Yes | Yes | Yes, pro rata (§11.3) | Yes |

State is computed from the price input and positions on every call. No address can force, enter, or exit a state.

---

# 13. Parameters

## 13.1 Parameter list

| Parameter | Role | Value | Calibration |
| --- | --- | --- | --- |
| `MCR` | Minimum ratio after minting or withdrawing | 250% | §13.2; no mass liquidation in any of 142 windows |
| `LR` | Liquidation threshold | 160% | §13.2; every outage-cascade liquidation covers |
| `LIQ_BONUS_BPS` | Liquidator discount | 500 (5%) | Gas and execution cost on Base; a month of slack, no rush premium |
| `MIN_DEBT` | Smallest non-zero position debt | 100 $COPRA | Bonus $7.50 at $1.50/kg against ~$2 gas |
| `MAX_PRICE_AGE` | Oldest usable GCPI finalization | 45 days | 1.5× the normal ~30-day finalization interval; revisited once GCPI records release times |
| `REDEEM_EXPIRY` | Wait before a redemption without a settlement price may be cancelled | 6 periods | Covers a 3-month outage with settlement to spare; longer outages cancel safely |
| `MINT_FEE_BPS` | Mint fee | 50 (0.5%) | In line with one-time borrowing fees |
| `MINT_FEE_PROTOCOL_SHARE` | Protocol share of the mint fee, in bps of the fee | 5000 (50%) | Neutral default; the rest feeds the settlement reserve |
| `REDEEM_FEE_BPS` | Redemption fee, retained by positions | 100 (1%) | Exceeds the one-period mean edge (0.4–0.7%); the full-horizon remainder via the premium |

Derivations in [ECONOMICS](../../econ/ECONOMICS.md#8-parameter-values). A deployment that changes any value re-runs the calibration or documents why it does not apply.

## 13.2 Sizing the ratios

Let `R(h)` be the GCPI rise over `h` calculation periods, measured on the GCPI backtest. `R(h)` is the historical maximum including the 1973 shock (R(1) = 47.7%): 1973 is copra on an export basis, and designing for the decade because it is recent would leave the 1973-scale shock unsized.

Let `L = 1` be the liquidation window: with monthly finalization and permissionless liquidation, a position crossing `LR` is liquidated within one period.

Let `M = 1` be the owner's reaction window: one period to top up or repay.

Then:

```
LR  ≥  (1 + LIQ_BONUS) × (1 + R(L))
MCR ≥  LR × (1 + R(M))
```

The first condition keeps a position that crosses `LR` able to pay the liquidator in full after a further `R(L)` rise. The second keeps a freshly minted position out of liquidation for `M` periods of adverse movement. With the values above: 1.60 ≥ 1.05 × 1.477 = 1.551, and 2.50 ≥ 1.60 × 1.477 = 2.363. The second formula was validated by simulation: every tested pair with MCR/LR below 1.477 suffers joint liquidation of minimum-compliant positions in 1973 windows, and every pair above it liquidates nothing ([ECONOMICS](../../econ/ECONOMICS.md#3-ratio-sizing)).

These ratios are the direct cost of a slow oracle. A weekly GCPI would need about 140–160% MCR where the monthly index needs 250% MCR, which makes minting more expensive and supply thinner.

---

# 14. Immutability and Versioning

- COPRA-001 contracts are not upgradeable and have no pause.
- Every parameter in §13, including the fee recipient (§10.4), is an immutable constant of the deployment.
- The GCPI adapter and methodology version are bound immutably at deployment.
- A new parameter set, a new GCPI version, or a new collateral asset is a new deployment with a new token address. Existing positions and tokens are unaffected, and holders migrate by their own choice.

## 14.1 Migration from v1

- The v1 contracts (`CopraVault`, `CopraToken`, `CopraOracle`) are immutable and remain as deployed. v1 holders exit through v1 `redeem`.
- COPRA-001 is a new deployment with a new $COPRA token. The v1 `CopraToken` is bound to the v1 vault and cannot be reused.
- The v1 `CopraRegistry` validates the v1 contract shape (`collateral`, `oracle`, `vault`, `token`). COPRA-001 needs either a registry version that understands its contracts or a new registry.
- v1 exists only on Base Sepolia, so no mainnet holders need to migrate.
- When COPRA-001 replaces v1, the README ("Trust Assumptions", "Backing & Price Moves"), the Whitepaper, `docs/ARCHITECTURE.md`, and the AGENT.md invariants must be rewritten to match.

---

# 15. Threat Model

| Threat | Defense |
| --- | --- |
| Redeeming at a price already known to be stale | Forward-priced settlement at a period whose sources were unpublished at request time (§8) |
| Cancelling a redemption after seeing its price | Cancellation forbidden once a settlement price exists (§8.4) |
| GCPI manipulation | Out of scope for COPRA-001; addressed by GCPI-001. COPRA-001 accepts only `VALID` finalized periods. |
| GCPI outage | Price-unavailable state; risk-reducing actions stay open (§12) |
| Rapid GCPI rise exceeding liquidation buffers | Ratios sized from the backtest (§13.2); bad-debt redistribution (§11.1); pro-rata shortfall (§11.3) |
| Liquidation cascade | Liquidations do not feed GCPI (§9.2) |
| Dust positions too small to liquidate | `MIN_DEBT` (§5.4) |
| Settlement-order manipulation | All requests at the same period settle at the same price; allocation across positions is proportional, not ordered (§8.3) |
| DEX price manipulation | No protocol function reads a DEX price |
| USDC pause or blacklist | As in v1: a pause stops every collateral movement until lifted, and blacklisting the position manager freezes all collateral (README, "Trust Assumptions") |
| Accumulator rounding drift | Rounding rule (§3); invariant tests that `Σ D_j` equals `totalSupply` (escrow included) and that `Σ C_j` equals the manager's USDC balance minus fee balances |
| Base sequencer downtime | No state changes occur; on resumption, `MAX_PRICE_AGE` applies before any price-sensitive action |
| Developers or fee recipient acting against holders | No privileged function touches positions, prices, or parameters (§10.4, §14) |

---

# 16. Open Questions

Resolved in v0.2 by #96 except item 8. Each resolution points to its evidence.

1. **Allocation of redemptions. Resolved: proportional, with the §8.3 cover rule.** Lowest-ratio-first was simulated against proportional over 142 rolling windows with redemption surges: no safety gain (worst TCR equal or worse, because redeemed-out collateral leaves the system), fees concentrated on the riskiest minters, and a sorted position list to build. Collateral-proportional takes are a tested-equivalent alternative ([ECONOMICS](../../econ/ECONOMICS.md#4-allocation-proportional-lowest-first-or-collateral-proportional)).
2. **Funding rate. Resolved: none in v0.2.** Break-even needs about 1% a year of market premium, which §10.3 supplies when demand exceeds supply. No premium covers 1973-scale tails, and no on-chain market price is measurable without manipulation in thin pools ([ECONOMICS](../../econ/ECONOMICS.md#5-funding-what-minters-earn)).
3. **Stability pool. Resolved: none.** Wipeout months need up to 100% of supply as liquidator float, which deposited $COPRA cannot cover; the pool adds timing games and keeps the empty-pool case. Rely on the bonus, the month-long execution window, and committed keepers ([ECONOMICS](../../econ/ECONOMICS.md#6-liquidators-and-the-stability-pool)).
4. **GCPI cadence. Resolved: monthly is sizable.** MCR 250%, LR 160% (§13.2): zero shortfall in 142 rolling windows including 1973, plus a 6-month outage during the 1973 rise. Redemption settles in 3–4 months, 6 under a 3-month outage ([ECONOMICS](../../econ/ECONOMICS.md#3-ratio-sizing)).
5. **Collateral assets. Resolved: USDC only.** A second stablecoin needs its own pricing, depeg rules and payout choice, for diversification that shares the same banking-system tail risk. The Circle dependency stays disclosed; §14 is the escape hatch ([ECONOMICS](../../econ/ECONOMICS.md#7-collateral-and-fee-recipient)).
6. **Parameter values. Resolved: §13 table**, derived from R(h) with 1973 included and L = M = 1 ([ECONOMICS](../../econ/ECONOMICS.md#8-parameter-values)).
7. **Protocol fee recipient. Resolved: fixed at deployment** (§10.4), disclosed in the deployment record. Which address is a deployment decision, not a spec decision ([ECONOMICS](../../econ/ECONOMICS.md#7-collateral-and-fee-recipient)).
8. **Regulatory classification. Open, deferred to #98.** Whether $COPRA, the minter position (effectively a short commodity-index position), or the protocol is a regulated derivative or security in the jurisdictions where it will be used. This must be answered by counsel before mainnet.
9. **Bootstrapping. Answered with a plan (§17); participants still pending.** Minters first (hedgers and premium harvesters, with numbers), then the pool, then keepers. Commitments remain a §19 acceptance criterion.

---

# 17. Bootstrapping

The protocol supplies no capital and no participants. At launch:

- **Supply requires minters.** Without minters, no $COPRA exists. If demand arrives before minters, $COPRA trades at a premium, which is the signal and the payment for minters (§10.3). Nobody loses money in this failure mode.
- **Trading requires liquidity providers.** A $COPRA/USDC pool must be seeded by participants holding both assets.
- **Safety requires liquidators.** Liquidation is open to anyone, and on a small system a single active liquidator may be the only one. Positions remain safe only while someone liquidates them.

The candidates to recruit first are copra market participants who want a short hedge, and market makers who want the minting and redemption spread.

Sequencing (#96): minters first (the pitch now has numbers — about 1%/yr expected cost at zero premium, a month to react, liquidation only below 160% at a known monthly price), then a $COPRA/USDC pool seeded by participants once supply exists, then at least one keeper running open-source liquidation-and-settlement software. Testnet rehearsal on Base Sepolia against the mock GCPI (#97) precedes any mainnet conversation. copra.dev running the first keeper is permitted — the calls are permissionless — but must be disclosed as centralization until independent keepers join.

---

# 18. Invariants

**Invariant 1 — Full backing at creation.** Every $COPRA is minted against a position whose ratio is at least `MCR` at the usable price.

**Invariant 2 — Supply accounting.** The ERC-20 `totalSupply` of $COPRA, which includes tokens escrowed in pending redemptions, equals the sum of all position debt `Σ D_j` up to scale dust: each settlement or redistribution moves the realized sums by less than one scale unit over the outstanding bases (about a wei per token of base) plus a few wei per position, and the remainder stays accounted in `totalDebt` and remains redeemable (§3).

**Invariant 3 — Collateral accounting.** The position manager's USDC balance equals the sum of position collateral plus unclaimed fee balances, up to the same scale dust in collateral units (about a unit per token of outstanding base per operation, plus a few units per position), which stays in the pool (§3).

**Invariant 4 — No protocol capital.** No function requires or accepts capital from the protocol, its developers, or the fee recipient to remain solvent.

**Invariant 5 — Neutrality.** No address earns from the direction of GCPI by virtue of a role. Protocol revenue depends only on volume.

**Invariant 6 — Forward pricing.** No redemption settles at a price whose source observations were published before the request.

**Invariant 7 — Equal treatment.** All redemptions settling at the same period receive the same payout per unit, including in shortfall.

**Invariant 8 — Risk reduction is always available.** `deposit`, `repay`, debt-free `withdraw`, and token transfers are never blocked.

**Invariant 9 — No discretionary control.** No address can change a price input, risk parameter, fee rate, or position, or move collateral other than through the rules in this specification.

**Invariant 10 — Safe failure.** Without a usable price, no action that depends on a price executes.

---

# 19. Acceptance Criteria

COPRA-001 may be considered for mainnet only when:

- GCPI-001 meets its own acceptance criteria (GCPI-001 §17), including shadow publication.
- Every §13 parameter is derived from the GCPI backtest, with the derivation published. Met by [ECONOMICS](../../econ/ECONOMICS.md#8-parameter-values).
- Simulation over historical GCPI paths, including the largest observed rises, shows no shortfall at the chosen parameters, or documents its frequency and size. Met by [ECONOMICS](../../econ/ECONOMICS.md): no shortfall at (250%, 160%) in 142 rolling windows and a 6-month outage during the 1973 rise.
- Invariants 2, 3, 6 and 7 are covered by property-based and fuzz tests.
- Forward-price settlement is shown to be order-independent.
- Bad-debt redistribution and shortfall payouts are tested on adversarial position sets.
- An independent security review is complete.
- The regulatory question (§16, item 8) has a written answer from counsel.
- Initial minters, liquidity providers, and at least one liquidator are committed.

*End of COPRA-001, Draft v0.2.*
