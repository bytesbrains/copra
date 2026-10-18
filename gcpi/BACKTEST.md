# GCPI Phase 2: Historical Dataset and Methodology Backtest

**Issue:** #88 · **Methodology:** [GCPI-001](../docs/specs/GCPI-001.md) §16 Phase 2 · **Run:** 18 October 2026
**Builds on:** [Phase 1 source report](SOURCES.md) (#87) · **Feeds:** #90 (spec decisions), #96 (COPRA-001 economics)
**Dataset and results:** [`backtest/data/`](backtest/data/) · **Code:** [`backtest/`](backtest/) · **Reproduce:** [below](#reproducing)

---

## Recommended methodology

For #90 to decide. Each choice links to its evidence.

| Choice | Recommendation | Evidence |
|---|---|---|
| Headline basket | **Philippines + Indonesia** (the export-linked pair). India and Sri Lanka as published sub-indices, outside the headline. | [§1](#1-correlations-and-spreads) |
| Aggregation | **Matched-market chain-linking**, not renormalized levels. | [§4](#4-missing-market-handling) |
| Weights | **Production** (FAOSTAT coconut oil, 3-year average): Philippines 0.65, Indonesia 0.35. The choice barely matters for this pair. | [§3](#3-weighting-production-vs-exports) |
| Coverage | **At least 70% of headline weight**, which for this pair means both markets. Otherwise the period is non-valid. Drop "at least three markets", which a two-market headline cannot meet. | [§6](#6-minimum-coverage) |
| Anomaly bands | **§7.3's bands, scaled by √(weeks per period)**: as written for a weekly index, about ×2 for a monthly one. | [§5](#5-anomaly-thresholds) |
| Cadence | **Monthly** today. Weekly only if an open weekly source for the Philippines or Indonesia exists. No daily. | [§7](#7-cadence) |
| Philippine source | **Not PSA, until PSA explains its 2024 break.** No open, reliable Philippine source exists today. | [Data quality](#data-quality-findings) |

**The blocker is the data, not the method.** The methodology above works on the history that exists. But the only open Philippine series (PSA) broke in 2024, and the reliable one (ICC) is all rights reserved. Until PSA explains or corrects its series, or ICC or UCAP license theirs, v1 has no Philippine input it can both trust and publish.

---

## Data

| Series | Source | Coverage | Use here |
|---|---|---|---|
| Philippines, domestic copra (Quezon), weekly | ICC Weekly Price Update | 2016-01 → 2026-10 | Headline |
| Indonesia, domestic copra, weekly | ICC (its own survey) | 2016-01 → 2026-10 | Headline |
| India, milling copra (Kochi, Alappuzha, Kozhikode), monthly and daily | CDB | 2008-01 → 2026-10 | Sub-index |
| Sri Lanka, domestic copra, weekly | ICC (from CDA) | 2016-01 → 2026-10 | Sub-index |
| Philippines, farmgate Resecada and Corriente, monthly | PSA OpenSTAT | 2010-01 → 2026-06 | Tested; break from 2024 |
| Copra, Philippines/Indonesia, CIF N.W. Europe, monthly | World Bank (2020 edition, archived) | 1960-01 → 2014-12 | Long-run risk and return |
| Coconut oil, monthly | World Bank (2020 and 2026 editions) | 1960-01 → 2026-09 | Corroboration, return |
| FX: PHP, INR, IDR per USD | ECB reference rates | 1999 → 2026-10 | Conversion |
| US CPI-U | FRED (CPIAUCSL) | 1947 → 2026-09 | Real return |
| Coconut oil production; copra and coconut oil export value | FAOSTAT | 2021–2023 | Weights |

**What is published:** [`dataset.csv`](backtest/data/dataset.csv) holds PSA's and CDB's monthly prices in local currency and USD, the ECB rates used, and a flag for PSA's post-break months. [`results.json`](backtest/data/results.json) holds every statistic in this report. ICC series are **not** published (all rights reserved); ICC data appears only through statistics. `fetch.py` rebuilds every input from the publishers.

---

## Data quality findings

These came out of building the dataset. Two of them change Phase 1's conclusions.

**1. PSA's copra series broke in January 2024.** Through 2023, PSA's monthly farmgate prices track ICC's Philippine series closely (r = +0.91 for Resecada, +0.94 for the mean of both grades). From 2024 the relationship collapses (r = +0.37 Resecada, +0.17 Corriente). In November 2024 Resecada fell 25% while ICC's Philippine price rose 8% and PSA's own Corriente rose 38%. The grades invert in 15 months, all from 2024 onward. Under §7.3's bands, PSA's Resecada would be quarantined in 8 of 30 months since 2024, against 5 in the 14 years before. **#87 recommended PSA as the headline anchor. That recommendation is withdrawn** until PSA explains the change.

**2. ICC's archive has date and filing errors.**
- Reports from 2016-10 to 2017-02 write dates month-first ("10/07/2016" is 7 October). Phase 1's parser read them day-first, which silently put weeks in the wrong months, and in some cases invented months like "2016-14".
- The January 2026 file contains the August 2026 report, so January 2026 is missing from ICC's archive.
- Both are fixed. The parser reads each date in the order that matches the report's own title month, rejects dates that fit neither, and reports misfiled files. **This changed Phase 1's correlations** ([corrections](#corrections-to-phase-1)).

**3. The World Bank revised and withdrew its copra history.** The 2017 edition had copra to 2017-05. The 2020 edition revises 1999–2014 by −14% to +10% (matching its January 1999 basis change to CIF N.W. Europe), marks 2015 onward as ".." (not available), and the 2021 edition drops the column. Its real coverage is 1960–2014. Phase 1's script counted ".." as data and reported copra into 2017 and 2020; that is fixed. **Lesson for GCPI:** a historical input that can be revised must be pinned to a vintage, or a "finalized" period can change under it.

**4. CDB's daily series is mostly carried forward.** In every year 2008–2026, 65–90% of Kochi's daily values repeat the previous day. 27% of calendar weeks end where they began.

---

## 1. Correlations and spreads

Monthly log changes, USD, 2016–2026 (ICC for the Philippines, Indonesia and Sri Lanka; CDB for India):

| | Indonesia | India | Sri Lanka |
|---|---|---|---|
| **Philippines** | **+0.75** (n 123) | +0.34 (123) | +0.13 (121) |
| **Indonesia** | | +0.29 (127) | +0.26 (123) |
| **India** | | | +0.12 (123) |

Against world prices (same month):

| Series | Coconut oil | Copra CIF N.W. Europe |
|---|---|---|
| Philippines (ICC) | +0.78 | n/a (overlap ends 2014) |
| Philippines (PSA, 2010–2023) | +0.81 | +0.84 |
| Indonesia (ICC) | +0.72 | n/a |
| India (CDB) | +0.28 | +0.39 |
| Sri Lanka (ICC) | +0.16 | n/a |

At a one-month lag, every correlation falls to between +0.18 and +0.41. Domestic prices react to world prices within the month.

**Spreads to the Philippines:** Indonesia averages 0.94× (range 0.77–1.11). India averages 1.94× (0.83–3.79). Sri Lanka averages 1.69× (0.89–2.59). The India and Sri Lanka spreads are large and drift from year to year; India's ran above 3× in 2018–2020.

**Conclusion:** the Philippines and Indonesia are one export-linked market that moves with world coconut oil. India and Sri Lanka have weaker links, larger spreads and drifting premia. A headline that mixes them measures the premia as much as copra. This holds after the corrections below. Only its strength changed: Phase 1 said India and Sri Lanka move "with neither"; the corrected figures are +0.12 to +0.34.

## 2. Publication delays and missing data

| Source | Delay | Missing |
|---|---|---|
| PSA monthly | 59 days after month end (2026-06 data published 2026-08-28) | None in 2010–2026 |
| ICC weekly | Report dated each Saturday, online within about a week | Philippines 9, Sri Lanka 9, Indonesia 5, India 6 gaps over 14 days; longest 42–49 days. Plus the January 2026 misfile. |
| CDB | Same day | Monthly: Kochi and Alappuzha none since 2008, Kozhikode 1 month. Daily: none reported 2020-03-23..05-31 (stated on the page). |
| World Bank | About 2 days after month end | None, 1960–2014 copra and 1960–2026 coconut oil |

PSA's delay is one observation. OpenSTAT keeps no release history, so its variation cannot be measured. **GCPI should record every source's release time from now on.** The finalization-delay distribution COPRA-001 needs does not exist in any archive.

## 3. Weighting: production vs exports

Three-year averages, 2021–2023 (FAOSTAT):

| | Coconut oil production share | Copra + coconut oil export value share |
|---|---|---|
| Philippines | 49.0% | 58.1% |
| Indonesia | 26.3% | 36.2% |
| India | 22.3% | 2.7% |
| Sri Lanka | 2.3% | 3.0% |

- **For the recommended headline, the choice does not matter.** Within the pair, production gives the Philippines 0.65 and exports give 0.62. The two indices never differ by more than 1.1% in level, and their R(1) and R(3) differ by under 0.5 points. Even equal weights stay within 4.7%.
- **For a four-market headline, it matters a great deal.** India's weight is 22% by production but 2.7% by exports, and the two four-market indices diverge by up to 26%. That is another reason to keep India out of the headline. Its copra is consumed at home, so a production weight would let a protected domestic market move a "global" index.

## 4. Missing-market handling

Each market was removed for 1 and 3 months at every possible start in 2016–2026. The table shows the largest gap to the same index without the outage: during the outage, and 12 months after it ends.

| Basket, missing market | Renormalized (during / after) | Chain-linked (during / after) |
|---|---|---|
| Four markets, India 3 months | **46.7%** / 0% | 8.4% / 9.9% |
| Four markets, Philippines 3 months | **32.2%** / 0% | 12.0% / 14.5% |
| Four markets, Indonesia 3 months | 29.8% / 0% | 6.9% / 8.1% |
| Four markets, Sri Lanka 3 months | 2.4% / 0% | 1.2% / 1.1% |
| Headline, Indonesia 1 month | 8.6% / 0% | 4.7% / 9.2% |
| Headline, Philippines 1 month | 18.2% / 0% | 8.7% / 17.1% |

- **Renormalization** jumps by the missing market's weighted spread, up to 47%, and snaps back when the market returns. That is §8.4's warning, measured: an index that moves 47% with no price moving.
- **Chain-linking** does not jump, but the missing market's own moves during the outage are lost for good. The error persists after the market returns.
- **Neither is acceptable when a large market is missing.** Chain-linking is right for small gaps in small markets. When a large share of weight is missing, the period should be non-valid (§6), not estimated. This is GCPI-001's "no fabricated prices" principle applied to aggregation.

**Recommendation:** chain-link, as the review proposed, together with the coverage rule in §6. Publish the active source set and a comparability flag every period (§8.4).

## 5. Anomaly thresholds

Share of periods in each §7.3 band, by absolute relative change:

| Series | Normal ≤5% | Corroborate ≤10% | Confirm ≤20% | Quarantine >20% |
|---|---|---|---|---|
| Philippines, **weekly** (ICC) | 85.8% | 12.4% | 1.4% | 0.4% |
| Headline, **monthly**, bands as written | 57.1% | 23.8% | 17.5% | 1.6% |
| Headline, monthly, bands ×2 | 81.0% | 17.5% | 1.6% | 0.0% |
| Export copra, monthly 1960–2014, as written | 57.4% | 26.7% | 14.3% | 1.7% |
| Export copra, monthly, bands ×2 | 84.1% | 14.3% | 1.5% | 0.2% |

**Genuine shocks:**

| Episode | Series | Path | Largest monthly rise / fall | Quarantined months (as written) |
|---|---|---|---|---|
| 2017–2019 fall | Headline | 1.04 → 0.40 US$/kg (−62%) | +26.0% / −14.9% | 1 |
| | Coconut oil | 1.87 → 0.64 (−66%) | +21.4% / −13.2% | 1 |
| 2024–2025 rise | Headline | 0.66 → 1.61 (+145%) | +15.3% / −11.8% | 0 |
| | Coconut oil | 1.13 → 2.84 (+151%) | +18.4% / −5.3% | 0 |

- **§7.3's bands fit a weekly index.** At monthly cadence they would send 43% of periods to corroboration or stronger confirmation, almost all of them genuine. Scaling by √(weeks per period), about 2.1 for monthly, restores the weekly profile.
- **Neither shock needs quarantine to be survivable.** The 2024–25 doubling was a run of +5–15% months, never one +100% month. Even at monthly cadence it stays inside "confirm". A single quarantine-band month occurred in the 2017–19 recovery, and the coconut oil corroboration (§7.5) moved with it.
- **The bands do catch bad data.** PSA's post-2024 series would be quarantined in 8 of 30 months.

## 6. Minimum coverage

- **§8.3's "at least three markets"** is impossible for a two-market headline. On the four-market basket it was met in 126 of 129 months, but that basket is not recommended (§1, §3).
- **"At least 70% of weight"** on the headline requires both the Philippines and Indonesia. Both were present in 126 of 129 months. The three non-valid months were 2023-01, 2025-07 and 2026-01 (ICC's misfiled report). The longest run is one month.

**Recommendation:** for the headline, require 70% of weight and drop the market count. Expect about one non-valid month in 40.

## 7. Cadence

| Source | Supports |
|---|---|
| CDB | Weekly at most: 65–90% of daily values are carried forward; 27% of weeks show no change |
| ICC | Weekly, but all rights reserved |
| CDA | Daily, with traded/nominal flags, but only 2026 is available |
| PSA | Monthly, about 2 months late, and broken since 2024 |
| World Bank coconut oil | Monthly, corroboration only |

**No source supports a daily copra index.** A weekly headline exists only in ICC's data. With open sources alone, the headline is monthly.

---

## Outputs for COPRA-001

### R(h): the GCPI rise over h periods

Relative rise over h consecutive periods. COPRA-001 §13.2 takes the larger of a tolerance quantile and the historical maximum.

| Series | h | p95 | p99 | Max (start) |
|---|---|---|---|---|
| Headline, monthly, 2016–2026 | 1 | 13.5% | 23.3% | 29.4% (2020-10) |
| | 2 | 22.7% | 38.5% | 43.0% (2019-10) |
| | 3 | 31.7% | 43.0% | 47.7% (2019-10) |
| | 6 | 54.1% | 64.0% | 68.7% (2024-10) |
| Export copra, monthly, 1960–2014 | 1 | 13.3% | 23.9% | 47.7% (1973-11) |
| | 2 | 23.7% | 37.3% | 76.1% (1973-10) |
| | 3 | 35.3% | 52.2% | 95.5% (1973-09) |
| | 6 | 59.4% | 96.4% | 136.0% (1973-09) |
| Philippines, weekly, 2016–2026 | 1 week | 5.3% | 7.7% | 12.0% |
| | 2 weeks | 9.6% | 13.4% | 20.7% |
| | 4 weeks | 15.2% | 26.0% | 34.2% |

PSA's 2010–2023 series (R(1) p99 26.0%, max 40.5%) is consistent with the headline. Its post-2024 months are excluded as a data break.

### Ratios implied by §13.2

`LR ≥ (1 + bonus)(1 + R(L))`, `MCR ≥ LR × (1 + R(M))`, using historical maxima, `M` = 1 period:

| Cadence and history | L | Bonus 5% | Bonus 10% |
|---|---|---|---|
| Monthly, 2016–2026 | 1 | LR 136%, MCR 176% | LR 142%, MCR 184% |
| | 3 | LR 155%, MCR 201% | LR 162%, MCR 210% |
| Monthly, 1960–2014 (incl. 1973) | 1 | LR 155%, MCR 229% | LR 162%, MCR 240% |
| | 3 | LR 205%, MCR 303% | LR 215%, MCR 318% |
| Weekly, 2016–2026 | 2 | LR 127%, MCR 142% | LR 133%, MCR 149% |

This is COPRA-001's "cost of a slow oracle" in numbers. A weekly index needs about 140–160% collateral where a monthly one needs 180–320%. Whether to size for 1973 is a judgment for #96. The decade of data contains no shock that large; the half-century does.

### Finalization delays: `MAX_PRICE_AGE` and `REDEEM_EXPIRY`

- **`MAX_PRICE_AGE`:** finalizations are monthly. The only measured delay is PSA's 59 days, from one snapshot; no archive records its variation. Recommend one period plus a 50% grace (about 45 days between finalizations), revisited once GCPI has recorded its own release times.
- **`REDEEM_EXPIRY`:** the longest headline outage was one non-valid month; ICC's longest weekly gap was 49 days. Recommend at least 3 periods.
- **Redemption delay:** COPRA-001 §8.2 settles at the first valid period after the request. A monthly GCPI published 59 days late means about 3–4 months from request to payout.

### Long-run real return

| Series | Period | Nominal p.a. | Real p.a. (US CPI) |
|---|---|---|---|
| Copra CIF N.W. Europe | 1960–2014 | +2.0% | **−1.8%** |
| Copra CIF N.W. Europe | 1990–2014 | +3.9% | +1.4% |
| Coconut oil | 1960–2026 | +2.5% | **−1.1%** |
| Coconut oil | 2000–2026 | +4.4% | +1.8% |
| Philippines farmgate (PSA, USD) | 2010–2023 | +2.5% | −0.0% |

Over rolling 10-year windows, copra's real return was positive only 32% of the time (median −2.1% a year). Over 20-year windows it was positive 22% of the time (median −2.7%).

**Copra has not beaten inflation over the long run.** Whether it does depends on the start date. Nothing should call $COPRA inflation-beating or an inflation hedge. This PR removes the one line that implied it (`docs/RELEASE_ANNOUNCEMENT.md`: "Unlike fiat currencies that inflate…").

---

## Corrections to Phase 1

[SOURCES.md](SOURCES.md) is corrected in this PR:
- **Correlations:** the date bug above inflated the disconnection. Corrected (ICC, monthly, USD): Philippines–Indonesia +0.75 (was +0.79); India–Philippines +0.32 (was −0.01); India–Indonesia +0.29 (was −0.14); Sri Lanka pairs +0.13 to +0.26 (were about 0). The two-regime conclusion stands, but more weakly.
- **World Bank copra:** published 1960–2014, revised in 2020, dropped in 2021. It was not "present in 2016, absent from 2025".
- **PSA:** no longer recommended as the anchor (data quality finding 1).

---

## Reproducing

```bash
python3 gcpi/backtest/fetch.py /tmp/gcpi-cache                       # about 330 MB; needs pdftotext
python3 gcpi/backtest/backtest.py /tmp/gcpi-cache gcpi/backtest/data  # about a minute
```

`test/gcpi/test_backtest.py` pins the functions behind every number on synthetic data with known answers: chain-linking, renormalization, outage effects, R(h), bands, coverage, staleness and real returns. `test/gcpi/test_research.py` pins the ICC date and misfiling fixes, and the World Bank ".." handling.

## Limits

- **The headline depends on ICC,** which converts to USD at an undisclosed rate and does not license redistribution. The method is tested; the input is not yet usable for v1.
- **Ten years of headline data** contain no 1973-scale shock. The export series that does is a different basis that ended in 2014.
- **Delay distributions** rest on one PSA snapshot and ICC's archive cadence. Real finalization delays will only exist once GCPI records them.
- **No backtest of authentication or collector behaviour.** That is #89 and #92.
