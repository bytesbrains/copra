# GCPI Phase 3: Deterministic Reference Engine

**Issue:** #91 · **Methodology:** [GCPI-001](../docs/specs/GCPI-001.md) §6.3, §7.3–§7.6, §8.1–§8.5, §9, §12, §16 Phase 3 · **Run:** 19 October 2026
**Builds on:** [Phase 2 backtest](BACKTEST.md) (#88), [v1 decisions](../docs/specs/GCPI-001.md#21-v1-decision-record) (#90) · **Feeds:** #92 (contracts and collectors), #93 (shadow publication)
**Code:** [`engine/engine.py`](engine/engine.py) and [`engine/engine.cjs`](engine/engine.cjs) · **Vectors:** [`engine/vectors/`](engine/vectors/) · **Reproduce:** [below](#reproducing)

---

## Result

| Done when (#91) | Status |
|---|---|
| Two independent implementations produce byte-identical results on every test vector | **Met.** Python (`engine.py`) and JavaScript with BigInt (`engine.cjs`) give the same canonical bytes on all 27 vectors and on the ln/exp table. They also agree on 129 months of real Phase 2 inputs under both methodologies below. |
| The engine reproduces the Phase 2 backtest values exactly | **Met, as far as fixed point allows.** Under the Phase 2 rules, the engine gives a value in the same 128 headline months as the backtest. Every level is within 4.4 × 10⁻¹⁶ of the backtest's float level, which is float rounding. Every discrete statistic is identical: band counts, coverage, the months of each R(h) maximum. The R(h) values agree within 10⁻¹². On the committed open dataset, which CI checks, the band counts for CDB and PSA match `results.json` exactly. |

"Exactly" cannot mean bit-equal to the backtest. The backtest is floating point, which §6.3 rules out of the consensus path. What the engine fixes is its *own* output, to the last unit. Agreement with the float backtest is the check that the integer method is the same method.

**Under the v1 draft methodology**, the 2016–2026 headline has **125 VALID months out of 129**:
- **Missing data:** 2023-01 and 2025-07 lack a market (INSUFFICIENT_COVERAGE), and 2026-01 has no data at all (UNAVAILABLE). These are BACKTEST §6's three months.
- **Held, then confirmed:** 2025-04. The Philippines rose 20.8%; Indonesia and coconut oil rose about 5.5%, the same direction but below the 10% a strong corroboration needs. May confirmed it, so the month became VALID one month late. This is the genuine 2024–25 rise, and the engine accepted it without anyone intervening.
- **Held, then rejected:** 2026-06. The Philippines fell 20.7% (Indonesia −1.0%, oil −8.9%). In July it rebounded 17.4%, back near May's level, so June was rejected (INVALID_INPUT). That is one month lost, and the price itself was never capped.

No market observation was quarantined. Through 2022 the v1 headline is within 0.02% of the Phase 2 headline (the weights are rounded to 0.65 / 0.35). It then sits 2.9% and later 7.7% below it. All of that comes from the two non-valid months. Phase 2 chained *through* each one using the only market present, which loses the absent market's move across the gap. v1 links across the gap from the last VALID month, with both markets.

## What the engine is

The engine is a pure function: **(methodology, observations, first, last) → one record per period** from the base period to `last`. It has no clock, no network and no randomness. The order of the input does not matter. An observation for a market the methodology does not list is ignored. It runs after authentication (§5.3, Phase 4): every observation it receives is assumed attested, and the engine decides what the attested numbers mean. Both implementations use only their language's standard library.

```
python3 gcpi/engine/engine.py input.json      # prints canonical output
node gcpi/engine/engine.cjs input.json        # the same bytes
```

The rules below are normative. Where GCPI-001 left a rule open, this engine had to choose one. Those choices are listed in [Choices the spec left open](#choices-the-spec-left-open), and the v1 RFC should ratify or change them.

## 1. Inputs

**Methodology** (one index). The v1 draft is [`methodology/gcpi-001-v1-draft.json`](engine/methodology/gcpi-001-v1-draft.json):

| Field | v1 draft | Meaning |
|---|---|---|
| `markets` | `{"PH": "65", "ID": "35"}` | Positive integer weights. Only their ratios matter. |
| `signals` | `["COCONUT_OIL"]` | Series used for corroboration only, never weighted (§7.5, §2.2) |
| `corroborators` | PH ↔ ID, both ↔ COCONUT_OIL | Who may corroborate whom (§7.5) |
| `min_coverage_bp` | `7000` | §8.3 |
| `bands_bp` | `[1000, 2000, 4000]` | §7.3 ×2. `null` disables market checks (research only). |
| `circuit_breaker_bp` | `4000` | §9.1. `null` disables it. |
| `max_publication_lag_days` | `90` | §8.2 freshness window after period end |
| `base_period` | `2016-02` | §8.4 *b*. A placeholder: see the open choices. |

**Testnet methodology** (#92): [`methodology/gcpi-1-draft.1-in-testnet.json`](engine/methodology/gcpi-1-draft.1-in-testnet.json) is what Base Sepolia runs. It is the India sub-index alone, because CDB is the only source with an adapter ([COLLECTORS](COLLECTORS.md)). It has no signals and no corroborators, as §7.5 lists none for a sub-index, so a 10–40% move waits for India's next publication (open choice 1). Its base period is 2026-09, the newest month CDB has published, so a deployment made before 2027-01-02, when that period's window closes, can still finalize a VALID base. The bands, circuit breaker, coverage and freshness window are the v1 draft's. It is a draft (§13.5): no comment period, no review, and nothing that settles value may read it.

**Observation.** Every field is a string. Integers are canonical decimal strings: no sign, no leading zeros.

| Field | Example | Meaning |
|---|---|---|
| `market` | `PH` | A market or signal id |
| `period` | `2025-04` | The month the price *reports* (§8.2), not the month it was published |
| `source` | `psa-farmgate-copra` | Source id, [`sources.json`](sources.json) |
| `price`, `price_exp` | `3050`, `2` | Value = price × 10^−price_exp. Mantissa < 10³⁰, exponent ≤ 18. |
| `currency` | `PHP` | ISO 4217 |
| `unit` | `kg` | `kg`, `quintal` (100 kg) or `t` (1000 kg) |
| `fx`, `fx_exp` | `507000`, `4` | Local currency per USD, same encoding. Empty exactly when the currency is USD. |
| `fx_source` | `ecb-monthly-mean` | |
| `published` | `1719792000` | Unix seconds, UTC |
| `record` | 64 hex | SHA-256 of the attested source record |
| `basis` | `cfr-europe` | Delivery basis. A change between two periods is a break (§7.5). |

A **structurally** malformed input aborts the run with a stable error code that both implementations produce: `observation_integer`, `observation_fields`, `market_weight`, and so on. Examples are the error vectors. A **semantically** unusable observation (zero price, missing FX, out of bounds, published early) does not abort the run. It makes that market INVALID for that period.

## 2. Arithmetic (§6.3)

| Item | Rule |
|---|---|
| Output scale | **WAD**: prices and levels are integers in 10⁻¹⁸ USD/kg |
| Internal scale | **S = 10³⁶** for ln and exp |
| Rounding | Every division is either **toward zero** (`tdiv`, as Solidity and BigInt do natively) or **half up** on non-negative values (`hdiv`). Half up is used exactly where noted. |
| Input bounds | Normalized price in [10¹², 10²⁴] (10⁻⁶ to 10⁶ USD/kg). Mantissas < 10³⁰, exponents ≤ 18. Outside these, the observation is INVALID. |
| Band tests | `(|P − P_ref| × 10⁴)² ≤ thr² × k × P_ref²`, with no division and no square root. `k` = periods elapsed, so thresholds scale by √k. Bounds are inclusive. |

**ln(x)**, x > 0 at scale S. Halve (or double) x until it lies in [S, 2S), counting k. Compute z = (x − S)·S / (x + S), truncated, and z² = z·z / S. Sum the atanh series z + z³/3 + z⁵/5 + …, each power truncated by S and each term truncated by its odd divisor, until a term is 0. The result is 2·sum + k·LN2, where **LN2 = 693147180559945309417232121458176568** (ln 2 × 10³⁶, truncated).

**exp(m)**, m signed at scale S. Set k = tdiv(m, LN2) and r = m − k·LN2. Sum the Taylor series 1 + r + r²/2! + …, each term computed as tdiv(term × r, n × S), until a term is 0. Shift the sum left by k, or right by −k.

Against 90-digit decimals, ln is within 10⁻³³ absolute and exp within 10⁻³³ relative error (`test_engine.py`), 15 orders of magnitude finer than the output. All intermediates stay below 2²⁵⁵ under the bounds above. The one product that can approach it is level × exp, if a level ever exceeds about 10²⁸. A Solidity port (#92) should use a full-precision mulDiv there.

## 3. Normalization (§6.1, §8.2)

```
P = hdiv(price × 10¹⁸ × 10^fx_exp,  10^price_exp × unit_kg × fx)        # USD/kg at WAD; fx = 1 for USD
```

There is one division, rounded half up. The observation is **INVALID** if:
- the unit is unknown;
- FX is missing for a local currency, or present for USD;
- a value is out of bounds;
- it was `published` before its period began, since no source can report a month that has not happened (§5.4).

It is **STALE** if it was published more than `max_publication_lag_days` after its period ended.

## 4. One market, one period

Observations are de-duplicated by commitment (§7), so resubmitting the same attested observation changes nothing. Among the remaining usable observations for a market and period:
- **one normalized price (and basis):** the market has a value;
- **more than one:** **DISPUTED** (§5.3.2). The market is missing, and no vote or rule picks a winner.

If no observation is usable, the market is STALE if any observation was late, otherwise INVALID. With no observation at all it is ABSENT.

## 5. Market decisions (§7.3–§7.7)

Each market keeps a **reference**: its last accepted price and that price's period. It also keeps a list of **pending** observations. The first value ever seen is accepted. For each later value V at period t, compared with a price R from period r, with k = t − r:

| Band of V against R | Passes when |
|---|---|
| normal | always |
| corroborate | a corroborator moved in the **same direction** between r and t (non-zero, same basis at both ends) |
| confirm | a corroborator moved in the same direction **and beyond the normal band** (a strong corroboration) |
| quarantine | never directly |

Checks run in this order:
1. Check V against the reference and against the newest pending value.
2. **If only one check passes,** it wins. **If both pass,** V goes to whichever level it is *relatively closer* to. The comparison `|V−Vp|·R < |V−R|·Vp` is exact; a tie goes to the reference.
3. **Confirming a pending value** accepts it and rejects any older pending values. V is then accepted, and the reference becomes V.
4. **Passing against the reference** rejects every pending value (**REJECTED_ANOMALY**) and accepts V.
5. **If neither check passes,** V joins the pending list.

So a pending value is decided only by **a later publication of the same market**, never by a timeout (§7.6). A genuine shock that persists is confirmed by the next month (`genuine_shock`), and a spike that reverts is rejected (`spike_rejected`). Repeating the same observation is not confirmation, because duplicates collapse into one. Corroborators are read from their own usable observations, not from their decisions, so no market's decision depends on another market's.

## 6. The index (§8.1, §8.3, §8.4, §9)

**Periods finalize in order.** Period t is decided once its markets and every earlier period's markets are decided. While any market is pending in t, t is PENDING_CONFIRMATION, and every later period is PENDING_CONFIRMATION (`earlier_period_pending`). So a period's result never depends on anything decided after it, and an index finalized period by period on-chain gets the same answer as a replay.

1. **Base period b:** VALID only if every market is accepted. The level is hdiv(Σ wᵢ·Pᵢ, Σ wᵢ). If the base is not VALID, no later period can be (`no_base`).
2. **Coverage:** Σ accepted weights × 10⁴ ≥ `min_coverage_bp` × Σ all weights, compared exactly in integers.
3. **Chain link from s,** the last VALID period, over the markets M accepted in both s and t. With lᵢ = ln(Pᵢ,t · S / Pᵢ,s):
   ```
   I_t = hdiv(I_s × exp(tdiv(Σ_M wᵢ·lᵢ, Σ_M wᵢ)), S)
   ```
4. **Circuit breaker:** a candidate outside `circuit_breaker_bp` × √(t − s) of I_s is held (PENDING_CONFIRMATION, `circuit_breaker`), and its candidate value is published *as a candidate* (§9.4: not presented as a verified price). The next covered period resolves it with the same rule as §5, without corroboration. A candidate linked from the held one within the normal band, and closer to it than to I_s, confirms it. One within the breaker of I_s rejects it.
5. **Status when not VALID.** The first matching cause applies:

| Cause in any market of t | Status | `reason` |
|---|---|---|
| PENDING | PENDING_CONFIRMATION | `market_pending` |
| INVALID / DISPUTED / REJECTED_ANOMALY | INVALID_INPUT | `market_invalid` / `market_disputed` / `market_rejected` |
| STALE | STALE | `market_stale` |
| every market ABSENT | UNAVAILABLE | `no_observations` |
| otherwise | INSUFFICIENT_COVERAGE | `coverage` |

A non-valid period publishes no level (Invariant 5). Every record carries:
- `accepted` (the active set) and `coverage_bp`;
- `linked_from` and `matched`;
- `comparable` (§8.4 item 5): true only when linked from the immediately preceding period, with the same active set in both;
- `decided_at`;
- for each market: its decision, band, price and observation commitments.

## 7. Encoding and commitments (§12)

- **Canonical JSON:** sorted keys, no whitespace, printable ASCII only, and **no JSON numbers**: every integer is a decimal string. It is the encoding of the output, and of the methodology for `methodology_hash` = SHA-256(canonical(methodology)).
- **Observation commitment:** SHA-256 of `"GCPI-OBS-v1"` followed by the fields in the table's order. A string is encoded as a uint32 big-endian length followed by its bytes. An integer is encoded as 32 bytes, big-endian. An empty `fx`/`fx_exp` is the empty string. The byte layout maps directly onto Solidity's `abi.encodePacked` and the SHA-256 precompile.
- **Input commitment** per period: SHA-256 of `"GCPI-INPUT-v1"`, a 32-byte count, then the sorted 32-byte commitments of every observation of a configured market or signal in that period.

## 8. Test vectors

[`engine/vectors/`](engine/vectors/) holds 27 inputs with their expected canonical output and its SHA-256, plus [`arithmetic.json`](engine/vectors/arithmetic.json), a table of ln and exp results. `make_vectors.py` regenerates them. `test_engine.py` checks every vector's *intended* outcome independently of the stored bytes, so a regenerated vector cannot quietly pin a wrong answer.

| Vector | Shows |
|---|---|
| `normal` | Small moves: all VALID and comparable. Levels match the chain-link formula in 90-digit decimal to 1 wei. |
| `missing_market`, `missing_all` | INSUFFICIENT_COVERAGE and UNAVAILABLE. The next period links from the last VALID one and is not comparable. |
| `no_renormalization_jump` | A three-market basket. A market at a 3× premium drops out and comes back, and the level does not move (§8.4). |
| `genuine_shock` | +50% in every market and in oil: quarantined, then confirmed the next month |
| `spike_rejected` | A one-month +60% spike that reverts: rejected, and the month is INVALID_INPUT |
| `corroborate_band`, `confirm_band` | Accepted with same-direction or strong corroboration. Otherwise held and confirmed by the next month. |
| `oil_basis_break` | A corroborator across a delivery-basis change does not count |
| `unresolved_pending` | Pending with no later publication: the period and all later ones wait |
| `fx_conversion`, `fx_invalid` | PHP/kg, INR/quintal and USD/t. FX missing or misplaced. |
| `rounding` | A half-wei price and a base level that both round up. A change of exactly 10% is normal; 10% plus one wei is not. |
| `stale`, `published_early` | Freshness window, and a period that had not begun |
| `disputed_and_duplicate` | Two conflicting attested values: DISPUTED. A resubmitted observation counts once. |
| `circuit_breaker` | An index move held and then confirmed, and another held and then rejected |
| `no_base` | A base period without full coverage |
| `closer_tie` | A value relatively equidistant from the reference and the pending value: the tie goes to the reference (#92) |
| `bands_disabled` | The Phase 2 research rules: no bands and no breaker, so a spike is accepted as published (#92) |
| `long_pending` | A market pending for 30 months: every period in between waits, then all are decided at once (#92) |
| `error_*` (6) | Structural errors: the same error code from both implementations |

## Reproducing

```
node --test test/gcpi/*.test.cjs                         # JavaScript engine against every vector
python3 -m unittest discover -s test/gcpi                # Python engine, arithmetic, intended outcomes, open-data Phase 2 checks
python3 gcpi/backtest/fetch.py /tmp/gcpi-cache           # inputs, as for BACKTEST.md
python3 gcpi/engine/reproduce.py /tmp/gcpi-cache         # Phase 2 and v1 on the ICC headline; prints statistics only
```

`reproduce.py` first checks that the cache rebuilds the committed `results.json` headline statistics, and stops if it does not. It prints no level series, because ICC's data is all rights reserved (BACKTEST.md). The Phase 2 methodology uses the backtest's float weights *exactly*: a float is a dyadic rational, and 1 − w is exact in binary floating point.

## Choices the spec left open

GCPI-001 fixes the bands, weights, coverage and aggregation. The engine had to fix the rules below as well. They are part of this draft and are proposed to the v1 RFC (§13.6), not decided:

1. **Corroboration** means a same-direction move of a listed corroborator over the same span. **"Strong"** means beyond the normal band. Sub-indices (India, Sri Lanka) have no corroborators listed in §7.5, so their 10–40% moves can only be confirmed by their own next publication.
2. **Confirmation** comes only from the market's next usable publication passing against the pending value. When a value passes against both levels, the closer one wins.
3. **Any pending market holds its period,** even if coverage would be met without it. Periods finalize in order.
4. **Circuit breaker** at the top band, 40% × √k, confirmed with the normal band. With market bands in place, it fired in no month of 2016–2026.
5. **Freshness:** 90 days after period end. Phase 2 measured PSA at about 59 days, from one snapshot.
6. **DISPUTED** means any difference in normalized value between attested observations, including a difference in FX.
7. **Rejections** (anomaly or circuit breaker) report INVALID_INPUT, the closest of §9.4's six states.
8. **Base period:** 2016-02 is a research placeholder. The real one depends on which Philippine and Indonesian sources v1 ends up with ([§21](../docs/specs/GCPI-001.md#21-v1-decision-record), blockers 1 and 2).

## Limitations

- **The Solidity port is a third implementation** ([CONTRACTS](CONTRACTS.md), #92). It matches every vector byte for byte. Porting it found a case where Python and JavaScript disagreed, a trailing newline, now fixed. It also found that no vector pinned the tie rule, and `closer_tie` now does.
- **FX is an input, not a rule.** Each observation carries its rate. §6.2's FX rule (which feed, which date, maximum age) is collection-side and still to be set in #92.
- **The v1 run uses ICC,** whose data cannot back v1 (BACKTEST.md). It tests the engine on real price behaviour, not on v1's eventual sources.
- **Observation `published` times in `reproduce.py` are synthetic** (the first day of the next month). The backtest has no per-observation publication record.
