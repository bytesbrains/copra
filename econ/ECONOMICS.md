# COPRA-001 Economics: Simulation and Open-Question Resolutions

**Issue:** #96 · **Spec:** [COPRA-001](../docs/specs/COPRA-001.md) §16 · **Run:** 22 October 2026
**Builds on:** [Phase 2 backtest](../gcpi/BACKTEST.md) (#88), [spec decisions](../docs/specs/GCPI-001.md#21-v1-decision-record) (#90) · **Feeds:** #97 (v2 contracts)
**Code:** [`sim.py`](sim.py), [`experiments.py`](experiments.py), [`paths.py`](paths.py) · **Data:** [`data/paths.csv`](data/paths.csv), [`data/results.json`](data/results.json) · **Tests:** [`test/econ/`](../test/econ/) · **Reproduce:** [below](#reproducing)

---

## Recommendations

For #96 to decide. Each choice links to its evidence. All are adopted in COPRA-001 v0.2 unless noted.

| # | Question | Recommendation | Evidence |
|---|---|---|---|
| 1 | Redemption allocation | **Keep proportional** (v0.1 rule), plus the missing cover rule: a position that cannot cover its share has the uncovered debt redistributed as bad debt (§11.1) | [§4](#4-allocation-proportional-lowest-first-or-collateral-proportional) |
| 2 | Funding rate | **No funding rate in v0.2.** Break-even needs a market premium of about 1% a year, which §10.3's premium mechanism supplies when demand exceeds supply | [§5](#5-funding-what-minters-earn) |
| 3 | Stability pool | **No stability pool.** It holds the same thin-market problem as external liquidators and does not cover wipeout months | [§6](#6-liquidators-and-the-stability-pool) |
| 4 | Monthly cadence | **Yes, sizable.** MCR 250%, LR 160%; zero shortfall in 142 rolling windows including 1973, plus a 6-month outage during the 1973 rise | [§3](#3-ratio-sizing) |
| 5 | Collateral assets | **USDC only.** A second stablecoin needs its own pricing and depeg rules; the Circle dependency stays disclosed, not engineered away | [§7](#7-collateral-and-fee-recipient) |
| 6 | Parameter values | **Table below**, derived from R(h) with 1973 included, L = M = 1 | [§8](#8-parameter-values) |
| 7 | Fee recipient | **Fixed at deployment**, disclosed in the deployment record. Its mutability was the only discretionary control in the design | [§7](#7-collateral-and-fee-recipient) |
| 8 | Regulatory | **Deferred to #98** (counsel), unchanged | — |
| 9 | Bootstrapping | **Sequencing and keeper plan below**; minter, LP and liquidator commitments still pending (§19) | [§9](#9-bootstrapping) |

**The headline result:** the mechanism is safer than its margins suggest and cheaper than its formula fears. Liquidation — not the ratios — defends solvency: even (180%, 140%) never reaches shortfall on any path, because positions liquidate before they go underwater. The ratios buy something else: minter survival. Below MCR/LR = 1.48 a 1973-scale month liquidates every minimum-compliant minter at once. The recommended (250%, 160%) keeps that from happening on any historical path, outage included.

---

## 1. Paths

There is no true "historical GCPI" to replay: the v1 basket has no open input yet (BACKTEST.md). The four paths are the closest open copra-price history, each a different regime. They test the mechanism against copra dynamics, not the exact headline.

| Path | Source | Months | Use |
|---|---|---|---|
| `export_copra` | World Bank export copra, CIF N.W. Europe, 2020 vintage | 1960-01 → 2014-12 (660) | Long run; the only path with a 1973-scale shock (+301% in 1973, +47.7% in November alone) |
| `coconut_oil` | World Bank coconut oil, current edition | 1960-01 → 2026-09 (801) | Correlated commodity; robustness check |
| `cdb_kochi` | CDB Kochi milling copra, USD, from `dataset.csv` | 2009-01 → 2026-10 (214) | Recent-regime domestic path |
| `psa_resecada` | PSA Resecada farmgate, USD, pre-break, from `dataset.csv` | 2010-01 → 2023-12 (168) | Recent-regime Philippine path |

World Bank data is CC BY-4.0 with attribution. The CDB/PSA columns repeat the derived monthly facts already published in `dataset.csv`. `paths.py` rebuilds `paths.csv` from `dataset.csv` plus the two World Bank workbooks (see `gcpi/backtest/fetch.py` FILES).

---

## 2. Method

`sim.py` is the v0.1 mechanism in monthly steps: positions with (collateral, debt), liquidation with bonus and gas, bad-debt redistribution, forward-priced redemption settling at the first valid period s ≥ k+1, pro-rata shortfall, and the three §12 states. Reference month i finalizes at the end of wall-clock month i+2 (the "up to about two months" lag, §8.2); the usable price is the latest finalized VALID price within `MAX_PRICE_AGE`.

The core design is **rolling cohorts**: a fresh system of 100 positions is opened every 12 months on each path and run for 36 months — 142 windows in all. A single genesis over the whole path collapses supply in the first crisis and then measures nothing; rolling windows measure what sizing needs, which is how a cohort minted at (MCR, LR) fares. Position profiles are adversarial (all at MCR) or mixed (MCR to 2×MCR). Minter behavior is passive (never touch the position) or maintainer (top up to MCR within a month below 1.1×MCR, withdraw above 1.3×MCR). Redemption demand is a 0.5%/month trickle, with 12-month 5%/month surges in the allocation experiment. Minter returns assume minted $COPRA is sold at GCPI with no premium, so the multiple is the pure short payoff plus fees; any market premium adds to it.

Assumptions that flatter or hurt the results, stated plainly:

- **Liquidators act within the month** at the usable price whenever profit clears $2 gas, and repay in full. A month is generous for a known price on Base; the risk is aggregate float (§6), not speed.
- **No market prices.** There is no DEX, no premium dynamics, no $COPRA discount in a panic (which would help liquidators, so omitting it is conservative for system health and neutral for minter returns).
- **Redemption demand is a schedule, not an equilibrium.** The trickle and surges are stress flows; they do not respond to the premium or the wait.
- **Floats, not fixed-point.** Consensus arithmetic is #97's problem; nothing here depends on rounding.
- **The paths are proxies.** A two-market chain-linked headline would be smoother than any single source, so single-source paths overstate jumps — conservative for sizing.

`test/econ/test_sim.py` pins the mechanism on hand-computed cases: liquidation math, the bad-debt split, dust left unliquidated, all three allocation rules, the cover failure, forward pricing (never at k), shortfall pro-rata, expiry, maintainer top-ups and withdrawals, and USD/$COPRA conservation over a scripted run.

---

## 3. Ratio sizing

Seven (MCR, LR) pairs × two profiles × two behaviors × 142 windows = 3,976 window-runs. Three facts stand out.

**No shortfall anywhere, at any calibration.** All 3,976 windows, including every window covering 1973–74, end without a single shortfall month and without a dollar of bad debt. Solvency does not come from the ratios. It comes from liquidation running before insolvency: a position crosses LR while it still covers its debt with the bonus, and each liquidation removes debt faster than the price can grow it. Even (180%, 140%), all positions at MCR, passive minters, survives every window.

**The ratios buy minter survival, and the operative constraint is MCR/LR ≥ 1 + R(1).** Maintainers who defend exactly MCR cluster at the cliff edge: a single-month usable jump larger than MCR/LR − 1 liquidates all of them at once. November 1973 jumped 47.7%, and the grid splits exactly on it:

| MCR/LR | Pairs | 1973-window outcome |
|---|---|---|
| ≥ 1.48 | (2.5, 1.55), (3.0, 1.75), (3.0, 2.0) | No liquidations on any path |
| < 1.48 | (2.0, 1.4), (2.0, 1.55), (2.5, 1.75), (1.8, 1.4) | Every minimum-compliant position liquidated in one month |

This is §13.2's second formula with M = 1, validated against history rather than assumed: `MCR ≥ LR × (1 + R(1))`. The failure mode when it is violated is contained — minters are wiped, holders are whole, no shortfall — but a supply wipeout is a protocol failure in practice even when the ledger balances.

**1973 counts.** The decade of recent data (max R(1) 29.4%) would allow MCR/LR ≥ 1.30. The half-century demands 1.48. 1973 is copra on an export basis, the same commodity and the same kind of shock the index must survive; designing for the decade because it is recent is recency bias with a formula. The cost of including it is about 60 points of MCR (250% vs ~190%). That is the price of surviving the shock traders still talk about.

The first formula, `LR ≥ (1 + bonus) × (1 + R(L))` with L = 1, is validated the other way: E2 freezes liquidations for a 6-month outage as the 1973 rise begins, then lands the jump all at once. At LR 160% (≥ 1.05 × 1.477 = 1.551) every liquidation still covers — 100 liquidations, zero bad debt, zero shortfall. At LR 155% with thin MCR the same outage produces $7,842 of bad debt on a ~$1M system (0.7% of collateral), redistributed and contained, still no shortfall.

Recommended: **MCR 250%, LR 160%**. Both formulas hold with 1973 included and L = M = 1: 1.60 ≥ 1.551, and 2.50/1.60 = 1.5625 ≥ 1.477 with 6% margin. An owner gets a month to react, a liquidator gets a month to execute, and a 1973-scale month liquidates few positions rather than all of them.

---

## 4. Allocation: proportional, lowest-first, or collateral-proportional

Three rules ran against each other over the same 142 windows with a 5%/month 12-month surge in each: v0.1 proportional (debt and collateral takes ∝ debt), lowest-first (redeem the riskiest positions first, à la Liquity), and collateral-proportional (debt takes ∝ debt, collateral takes ∝ collateral — every position pays the same haircut rate). The last entered because the sim found a gap in v0.1 (below).

**On system safety the three rules are indistinguishable.** Zero shortfall windows under every rule at both calibrations ((2.5, 1.75) maintainer, (2.0, 1.55) passive). Worst TCRs differ by 1–5 points with no consistent winner. Liquidation counts differ by ~10%, again with no consistent winner: lowest-first pre-empts some liquidations by redeeming weak positions first under maintainers, collateral-proportional edges the passive cells.

**Lowest-first does not improve worst-case health, because redeemed-out collateral leaves the system.** Closing a weak position via redemption returns its leftover collateral to its owner, draining the buffer that proportional redemption keeps inside. On cdb passive the worst TCR is 1.753 under lowest-first against 1.886 under proportional. And lowest-first pays the riskiest minters most: fees follow redemptions, so the bottom tercile earns roughly twice the fees of the top tercile (export maintainer: 590/410/1), rewarding exactly the risk-taking the rule claims to discourage. Against that: a sorted position list with gas-bounded insertion, the most complex of the three to build safely.

**Proportional and collateral-proportional are economically identical and the measurements agree** (same liquidation counts, multiples within noise). The difference is only the failure mode: debt-proportional takes can exceed an underwater position's collateral, which v0.1 does not address. In practice only unliquidatable dust fails to cover — anything bigger was liquidated before settlement — but E2's outage cascade reaches it, and "in practice" is not a rule.

Recommendation: **keep proportional**, and close the gap explicitly: a position covers its share up to its collateral, and any uncovered debt redistributes as bad debt under §11.1. Collateral-proportional stays documented as the tested-equivalent alternative if reviewers prefer a rule that covers by construction. Lowest-first is rejected: no measured safety gain, perverse fee incidence, most complexity.

---

## 5. Funding: what minters earn

Maintainers who sell at GCPI with no premium lose about **1% a year** on average: mean 36-month multiples of 0.96–0.99 across paths and calibrations, profitable in roughly 35–40% of windows. The loss is the short payoff itself — nominal drift against the position, volatility drag on a maintained short, and the ~2% lag transfer on each redeemed unit (below) — net of redeem fees, which are negligible at the 0.5% trickle (about 0.02% of deposits). The worst windows are wipeouts: 0.54 at (2.5, 1.75) through 1973, 0.37 at (1.8, 1.4).

Three conclusions follow. First, break-even needs a persistent market premium of about 1% a year harvested by mint-and-sell — a modest number §10.3's premium mechanism plausibly supplies whenever holding demand exceeds minting supply. It does not need a protocol rate. Second, no premium covers the tail: a 1973-scale year liquidates minimum-compliant minters however the fee is set, so minters must be hedgers, for whom the loss offsets inventory gains, or deliberate risk-takers — which is the §17 story, unchanged. Third, a funding rate cannot be measured without a trusted market price of $COPRA on-chain, and every candidate (DEX spot, TWAP) is manipulable at low cost in the thin pools a new token has. A rate that pays on a manipulable input is a theft mechanism with extra steps.

**No funding rate in v0.2.** Revisit only with evidence that supply is inadequate at the premium the market actually pays — and even then, the measurement problem has to be solved first, not assumed away.

### The lag transfer (sizes REDEEM_FEE)

Every redemption settles at P[k+1] while ratios were managed against P[k−2]: the two-month lag is a structural transfer from minters to redeemers equal to the three-month drift, +1.9% to +2.4% on average across paths (p95 +31% to +38%, max +95.5% in November 1973). It is predictable in direction: after a trailing 3-month rise above 10%, redeemers gain +19% to +21% against usable; after a fall below −10%, they lose −12% to −17%. No fixed fee covers the conditional tail — that is the premium's job, since an efficient market prices the stale oracle into $COPRA. The fee covers the mean: see §8.

---

## 6. Liquidators and the stability pool

Two questions: can each liquidation execute, and can all of them at once.

**Each liquidation executes.** Gas on Base is dollars; the 5% bonus covers it from about $40 of debt value up. `MIN_DEBT` of 100 $COPRA (~$150 at $1.50/kg) keeps every position several multiples above that. No window at any calibration leaves a position unliquidated for lack of profit — the only unliquidatables the study ever produced were a sim bug's husks (fixed; see Limits).

**All of them at once is the real risk, and a stability pool does not fix it.** In wipeout months the float needed is the whole supply: cells violating MCR/LR ≥ 1.48 show single months liquidating 100% of supply (Nov 1973 three times over). At the recommended ratios no window needs any float outside a 6-month outage during 1973, and even there liquidation contains everything. A stability pool holds only deposited $COPRA — a fraction of supply, deposited by holders facing the same crash — so it cannot cover the months that matter, while adding deposit-timing games around predictable monthly finalizations and leaving the empty-pool case to external liquidators anyway. The slow oracle is the actual backstop: the price is known a month in advance of nothing, but execution has a month of slack at a fixed price, with flash swaps for the sourcing.

**No stability pool in v0.2.** Rely on the bonus, the month-long execution window, and committed keepers (§9). Flagged as residual risk: a 1973-scale jump needs whole-supply float within one period, and that float must come from the market.

---

## 7. Collateral and fee recipient

**USDC only.** A second stablecoin does not remove dependency risk, it multiplies the rules: the protocol would need to price the stables against each other, haircut depegs (USDC itself fell 13% intraday in March 2023 and recovered in days — any rule written for that week would have been wrong the next), and choose which asset pays each redemption. All USD stables share banking-system tail risk anyway, so the diversification is thinner than it looks, while a freeze of any one collateral asset mid-redemption is a new failure mode with no historical data to size. The Circle pause/blacklist dependency stays exactly where v1 disclosed it (threat model, "Trust Assumptions"), and §14's new-deployment path is the escape hatch if it materializes. Revisit with real depeg-and-recovery data, not before.

**The fee recipient is fixed at deployment.** The draft's two-step transfer made it the only mutable setting in an otherwise immutable design: no risk function, but a live address with expectations, a coercion target, and an invitation to governance creep. Fixing it costs nothing — the recipient's only power is receiving volume-based fees — and completes Invariant 9 (no discretionary control). Which address is a deployment-time decision recorded with the deployment, not a spec decision. The alternative of burning the protocol share destroys the funding for settlement keepers and public goods for no safety gain.

---

## 8. Parameter values

From R(h) with 1973 included (R(1) max 47.7%), L = M = 1, 5% bonus:

| Parameter | Value | Derivation |
|---|---|---|
| `MCR` | 250% | ≥ 1.60 × 1.477 = 2.363; round up. Validated: no mass liquidation in any window |
| `LR` | 160% | ≥ 1.05 × 1.477 = 1.551; round up. Validated: every E2 outage-cascade liquidation covers |
| `LIQ_BONUS_BPS` | 500 (5%) | Covers gas many times over at `MIN_DEBT`; execution has a month of slack, no rush premium needed |
| `MIN_DEBT` | 100 $COPRA | ~$150 at $1.50/kg; bonus $7.50 against ~$2 gas. Nothing smaller is worth liquidating |
| `MAX_PRICE_AGE` | 45 days | 1.5× the normal ~30-day finalization interval: a single missed monthly finalization stays usable, anything longer fails closed. From BACKTEST delays, revisited once GCPI records release times |
| `REDEEM_EXPIRY` | 6 periods | Covers a 3-month outage with settlement to spare (E: delays reach 6 months, nothing cancels); a 6-month outage cancels some requests safely and holders re-request |
| `MINT_FEE_BPS` | 50 (0.5%) | In line with one-time borrowing fees (e.g. Liquity 0.5% base); prices spam, funds the reserve and the recipient |
| `MINT_FEE_PROTOCOL_SHARE` | 5000 (50% of the fee) | Neutral default; the rest feeds the settlement reserve. Arbitrary but immutable |
| `REDEEM_FEE_BPS` | 100 (1%) | Exceeds the one-period mean edge (0.4–0.7%); about half the full-horizon mean (~2%), the rest via the premium. The conditional tail (+20% after rises) belongs to the premium, not the fee |

A recent-only calibration (1973 excluded) would read MCR ~190%, LR ~140%. It is rejected: the sim's thin cells confirm those ratios wipe minimum-compliant minters in 1973 windows. The ~60 points of MCR are the cost of surviving the half-century instead of the decade.

---

## 9. Bootstrapping

The design needs no protocol capital, but §17's gap stands: it does not create participants. What this study adds is sequencing and the keeper spec; commitments remain pending acceptance criteria.

1. **Minters first.** Supply exists only if minters mint. The candidates are unchanged — copra hedgers (producers, exporters, inventory holders via UCAP/PCA-adjacent outreach) and premium harvesters — but the pitch now has numbers: ~1%/yr expected cost at zero premium, months to react, liquidation only below 160% at a known monthly price. Testnet rehearsal on Base Sepolia against the mock GCPI (#97) precedes any mainnet conversation.
2. **A $COPRA/USDC pool second**, seeded by participants holding both assets once supply exists. The pool is the fast exit; protocol redemption (3–4 months, measured: 3 normal, 6 under a 3-month outage) is the backstop that bounds its discount.
3. **At least one keeper third**, running open-source liquidation-and-settlement software on the schedule GCPI publishes. copra.dev running the first keeper is permitted (the calls are permissionless; it confers no privilege) but must be disclosed as centralization until independent keepers join, with the E2 whole-supply-float month as the load case to engineer for.

Commitments from all three are still required by §19 before mainnet. This question is answered with a plan, not with participants.

---

## Found along the way

- **The minter-return ledger initially omitted the short.** Proceeds from selling minted $COPRA were off-ledger, which made every window a ~25% loss and hid the real ~1%/yr drag. The multiple now counts deposits against equity plus withdrawals plus proceeds. A test pins the flat-price (1.0) and falling-price (1.25 at −50%) cases.
- **Bad-debt redistribution duplicated debt.** The liquidated position kept its husk debt after the same debt moved to others, creating unliquidatable ghosts. Caught by the E2 probe, fixed, and pinned by a test that fails without the fix.
- **Proportional allocation had no cover rule.** An underwater position's debt-proportional collateral take can exceed its collateral; v0.1 §8.3 is silent. The sim redistributes the uncovered remainder as bad debt, which v0.2 adopts.
- **Single-genesis runs measure nothing.** The first design opened one system in 1960 and watched it die in 1973. Rolling cohorts replaced it.
- **Maintainers who defend exactly MCR cluster at the cliff.** Topping to precisely 250% leaves the whole system one 47.7% month from joint liquidation. The MCR/LR ≥ 1.48 rule is the structural answer; prudent minters will hold their own buffer above it.

## Limits

- **Proxy paths, not the headline.** Single sources jump harder than a chain-linked two-market index would; sizing is conservative by an unmeasured amount. Re-run against the real headline history once it exists — the harness takes any monthly CSV.
- **Scheduled demand, not equilibrium.** Redemption flows do not respond to premium, wait, or panic. A run on redemptions deeper than 5%/month for a year is untested; the allocation comparison, not the level, is the robust finding.
- **Full, fast liquidation.** Liquidators repay in full within the month. Partial or slower liquidation would deepen troughs but cannot create shortfall the full case avoids — the direction is conservative, the depth is approximate.
- **No market feedback.** $COPRA discounts, premium dynamics, and pool depth are outside the model; §5's premium story is arithmetic (break-even ≈ 1%/yr), not a market simulation.
- **Outages are injected, not sampled.** The 3- and 6-month E/E2 outages are placed at the worst moment by construction; their frequency is not estimated.

---

## Reproducing

```bash
python3 econ/paths.py /tmp/econ-cache            # needs wb_2020.xlsx + wb_current.xlsx (fetch.py FILES)
python3 econ/experiments.py                      # ~15 s; rewrites data/results.json; prints A–E
python3 -m unittest discover -s test/econ        # 24 tests on hand-computed cases
```
