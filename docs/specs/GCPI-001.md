# GCPI — Global Copra Price Index

## Decentralized Commodity Reference Protocol

**Specification:** GCPI-001\
**Version:** 1.0 Draft\
**Network:** Base L2 (initial deployment)\
**Reference unit:** USD per kilogram of standardized milling copra\
**License proposal:** CC0 for methodology; Apache-2.0 or MIT for implementation\
**Status:** Proposed architecture — subject to data-source validation, historical backtesting, economic modeling, and security review\
**Companion:** [COPRA-001](COPRA-001.md), the $COPRA reserve and redemption protocol that consumes this index\
**Decisions:** §21 records the v1 choices settled from the source research, backtest and authentication research ([SOURCES](../../gcpi/SOURCES.md) #87, [BACKTEST](../../gcpi/BACKTEST.md) #88, [AUTHENTICATION](../../gcpi/AUTHENTICATION.md) #89), decided in #90. They are draft decisions: v1 is released only through §13.6–§13.9.

---

# 1. Purpose and Mission

The Global Copra Price Index (GCPI) is an open, permissionless, deterministic commodity price reference protocol.

Its purpose is to calculate and publish a globally representative reference price for dried coconut meat (copra), using independently published market observations from major copra-producing and trading economies.

GCPI must not be controlled by any individual, company, government, administrator, token issuer, or single oracle provider.

The protocol should operate according to publicly documented mathematical rules, allowing independent participants to retrieve source data, reproduce calculations, verify results, and submit valid observations.

GCPI is intended to serve as a public commodity reference, with $COPRA as its first consumer.

## 1.1 Fundamental principles

1. **No discretionary price authority.** No participant can manually set or override GCPI.
2. **No privileged execution.** Any eligible participant can submit observations, validate calculations, and trigger publication.
3. **Global representation.** The index must reflect multiple geographically independent copra markets.
4. **Source transparency.** Every contributing price must have an attributable, publicly inspectable source.
5. **Historical accountability.** All accepted and rejected observations, including reasons for rejection, must be auditable.
6. **Deterministic computation.** Identical validated inputs must produce identical outputs.
7. **Fault containment.** Failure of an individual source or collector must not corrupt the index.
8. **No fabricated prices.** The protocol must distinguish current, stale, unavailable, and unverified prices.
9. **Neutral infrastructure.** The index must not favor a country, market, participant, or $COPRA holder.
10. **Open participation.** Independent implementations must be able to reproduce and verify the reference price.

## 1.2 Scope

GCPI is responsible for commodity price observation, normalization, validation, aggregation, and publication.

GCPI is not responsible for maintaining the market price of $COPRA, managing collateral, guaranteeing redemptions, or underwriting commodity exposure.

Those responsibilities belong to separate financial contracts.

---

# 2. Commodity Reference Definition

Before collecting prices, GCPI must define exactly what one reference kilogram represents.

## 2.1 Reference commodity

The initial reference commodity shall be:

**One kilogram of standardized, dried milling copra suitable for commercial coconut-oil processing.**

The final technical definition must establish:

- Maximum moisture content.
- Permitted foreign matter.
- Mold and contamination limits.
- Accepted processing condition.
- Relevant oil-content requirements, if appropriate.
- Weight and measurement conventions.
- Delivery and commercial pricing basis.

These requirements must be derived from recognized published industry standards and verified against available market quotations.

## 2.2 Excluded products

The index must not directly mix prices for:

- Fresh whole coconuts.
- Coconut oil.
- Desiccated coconut.
- Coconut milk or cream.
- Coconut shell products.
- Ball copra where its grading or intended market differs materially from milling copra.

Such prices may be published as supplementary indicators, but must not silently enter the primary index.

## 2.3 Delivery-basis normalization

A farmgate price is not directly equivalent to an export FOB or destination CIF price.

GCPI must define one common reference basis.

For example:

```
Normalized Price = Published Price + Approved Quality Adjustment + Approved Delivery-Basis Adjustment
```

Every adjustment must be independently reproducible using published input data and fixed rules.

If an adjustment cannot be verified, the observation must be excluded rather than estimated arbitrarily.

For the initial version, directly comparable quotations should be preferred over complex normalization.

## 2.4 v1 reference definition (decided, #90; §19 Q1)

- **Basis: domestic.** No public, redistributable export-basis (FOB or CIF) copra price exists: the World Bank published copra only for 1960–2014, ICC publishes only domestic prices, and Oil World is subscription-only ([SOURCES §1](../../gcpi/SOURCES.md#1-there-is-no-public-export-price-to-anchor-to)). A §2.3 normalization to an export basis therefore has nothing to normalize to. **v1 applies no delivery-basis and no quality adjustment.** Every observation enters at the basis its source publishes (farmgate or wholesale), and the methodology version records that basis per source.
- **Markets: the export-linked producers.** The headline is the **Philippines and Indonesia**. Their copra moves together (r = +0.75 for monthly changes, 2016–2026) and with world coconut oil (+0.78, +0.72). India and Sri Lanka move with them only weakly (+0.12 to +0.34) and trade at drifting premia of 1.7–1.9× ([BACKTEST §1](../../gcpi/BACKTEST.md#1-correlations-and-spreads)). **India and Sri Lanka are published as separate per-country sub-indices**, under the same rules, and never enter the headline.
- **Grade: dried milling copra,** as each listed source defines its milling grade (Philippines: Resecada, not Corriente). The methodology version records each source's own definition verbatim.
- **Not set in v1: numeric quality limits** (moisture, foreign matter, oil content). No open source publishes them per quotation, so a number here could not be checked against any observation. Until one can, §17's "the reference commodity is unambiguously defined" is not met.
- **Naming.** Every published value carries its basket. The v1 headline is not described as a global price: two producers are not the world ([SOURCES](../../gcpi/SOURCES.md#what-would-make-a-global-index-defensible)).

---

# 3. Global Market Coverage

## 3.1 Initial candidate markets

| Market                   | Candidate public sources                                              | Initial role |
| ------------------------ | --------------------------------------------------------------------- | ------------ |
| Philippines              | Philippine Coconut Authority, ICC, industry price publications        | Headline     |
| Indonesia                | ICC and published Indonesian commodity reports                        | Headline     |
| India                    | Coconut Development Board, AGMARKNET, recognized wholesale quotations | Sub-index    |
| Sri Lanka                | Coconut Development Authority                                         | Sub-index    |
| Papua New Guinea         | Official commodity and export reports                                 | Expansion    |
| Solomon Islands          | Government and commodity-sector reports                               | Expansion    |
| Vanuatu                  | Government and commodity-sector reports                               | Expansion    |
| Other qualifying markets | Publicly verifiable official or recognized industry publications      | Expansion    |

This list is a discovery target, not a declaration that every source currently provides suitable automated access. Roles are as decided in §2.4. Phase 1 found no open, reliable source for either headline market today (§21).

## 3.2 Market inclusion criteria

A market qualifies only if:

1. Its observations refer to the defined reference commodity or can be normalized using approved rules.
2. It has a verifiable publication authority.
3. It provides reliable publication timestamps.
4. Historical observations are available for testing.
5. Prices can be independently retrieved or authenticated.
6. The data has sufficient geographic and commercial relevance.
7. Inclusion does not create duplicate exposure to the same underlying trade quotation.

## 3.3 Global expansion

GCPI must not permanently restrict participation to four countries.

However, automatic inclusion of arbitrary new markets would create a manipulation vector.

The initial immutable market registry must therefore be based on an openly audited source inventory.

A future expanded index version may add sources under a predetermined admission procedure, but it must receive a distinct methodology identifier.

**No source should be added to an existing immutable index through discretionary administrator action.**

---

# 4. Market Weighting

## 4.1 Primary weighting methodology

GCPI should initially use a fixed, production-weighted arithmetic average.

The proposed weight of each country is based on its average relevant copra production over the preceding three published statistical years.

For market i:

```
W_i = Average Copra Production_i / Total Eligible Copra Production
```

The production dataset, reference years, exclusions, and calculations must be published.

Coconut production volumes must not be substituted for copra production without a documented, defensible conversion methodology.

## 4.2 Weight independence

Weights must not change in response to current prices.

They must not be adjusted by oracle operators, token holders, developers, or liquidity providers.

## 4.3 Weight revisions

For the initial immutable version, the approved weights shall remain fixed.

A later methodology version may introduce updated weights using a separately audited statistical dataset.

A fixed-weight index and a periodically reweighted index must be identified as different methodologies when their outputs can diverge.

This avoids hidden governance over the reference price.

## 4.4 v1 weights (decided, #90; §19 Q3)

**Production weights, fixed: Philippines 0.65, Indonesia 0.35.**

- **Data:** FAOSTAT coconut oil production, 2021–2023 average: Philippines 49.0%, Indonesia 26.3% of the four core markets. Within the pair that is 0.651 and 0.349, rounded to two decimals.
- **Substitution (§4.1):** FAOSTAT has no copra item. Coconut oil production stands in for copra milled. Under a common oil extraction rate, the rate cancels from the within-pair shares, so no conversion figure enters the weights. If the two countries' rates differ, the weights inherit that difference. This is a documented limitation, not an estimate.
- **Sensitivity:** export weights give the Philippines 0.62. The two headlines never differ by more than 1.1% in level ([BACKTEST §3](../../gcpi/BACKTEST.md#3-weighting-production-vs-exports)). For this pair the choice barely matters. It would matter a great deal for a four-market basket (up to 26%), which is one more reason India is not in the headline.
- Sub-indices have one market each and need no weights.

---

# 5. Data Acquisition Network

## 5.1 Independent collectors

GCPI should use multiple independent data collectors.

Collectors may be operated by:

- Individuals.
- Universities.
- Research organizations.
- Commodity market participants.
- Independent infrastructure operators.
- Automated agents.
- Public archival services.

No collector should receive permanent exclusive submission rights.

## 5.2 Collector responsibilities

Each collector shall:

1. Retrieve the original published observation.
2. Record its publication timestamp.
3. Preserve the original value and currency.
4. Identify the commodity grade and quotation basis.
5. Record the exact source location and retrieval metadata.
6. Generate a cryptographic commitment to the source record.
7. Submit the observation through the defined protocol.
8. Make the supporting record independently retrievable.

Two rules follow from the research (#88, #89):

- **The publication time comes from the content or from the first attested retrieval, never from HTTP headers.** ICC's September 2026 PDF reported a `Last-Modified` of the day it was probed ([AUTHENTICATION](../../gcpi/AUTHENTICATION.md#what-each-source-offers-an-attestation)).
- **An input that its publisher can revise is pinned to a vintage.** The World Bank revised its 1999–2014 copra history by −14% to +10% in one edition and withdrew it in the next ([BACKTEST](../../gcpi/BACKTEST.md#data-quality-findings)). An unpinned input would let a finalized period change under it.
- **The commitment in step 6 covers the value's bytes and their position in the response,** not the whole response. Some pages change on every request (a CSRF token), so collectors agree on the price but not on a whole-response hash.

## 5.3 Source authenticity

Multiple collectors reading the same website do not create multiple independent price sources.

Three collectors can all reproduce the same erroneous government publication.

Therefore, GCPI must distinguish:

- **Collector agreement:** independent collectors agree about what was published.
- **Source authenticity:** the observation actually originated from the claimed publisher.
- **Market corroboration:** independent markets support the economic plausibility of the observation.

A hash proves that a record has not changed relative to the committed bytes. It does not prove that the record is authentic or economically correct.

Where publishers provide digitally signed feeds, GCPI should verify those signatures.

Where publishers do not, the protocol must explicitly document the remaining trust assumptions and use verifiable retrieval or attestation mechanisms.

**Decided for v1 (#90; §19 Q7),** from [AUTHENTICATION](../../gcpi/AUTHENTICATION.md):

**5.3.1 Mechanism (v1).** An observation is accepted when at least *k* of the *n* notaries listed in the methodology version attest, through TLS attestation with selective disclosure, to the same value bytes from the listed source location. A publisher signature against a key listed in the methodology version substitutes for notary attestations. The notary list, *k*, the source locations, the publisher keys and the parsers for non-structured formats are part of the methodology version. No contract owner or other key can change them. A vendor's attestor key may be one of the *n* if its operator is independent. A vendor's verifier contract that has an owner or can be upgraded may never be the gate: on Base on 18 October 2026, both Reclaim and Primus deployments were upgradeable proxies controlled by a single key.

**5.3.2 Disputes.** Within the challenge window, anyone may submit a second valid attestation set for the same source and period. If the two disagree, the market is missing for that period (§8.4) and the conflict is recorded. No vote decides between them. UMA's DVM, a token-holder vote, is not used: it is the "majority stake determines the price" that §5.4 forbids.

**5.3.3 Challenge window.** 3 days per period, which adds about 5% to a monthly finalization delay.

**5.3.4 PDF and XLSX sources.** The attestation covers the transcript and the file's hash. The value is extracted by a parser pinned in the methodology version, which anyone can rerun on the attested bytes. A disputed parse is a conflict under 5.3.2.

**5.3.5 Publisher signatures.** GCPI asks PSA, CDB and CDA to sign their releases. It is the only mechanism with no third party. Contacting publishers is a project decision, not part of this specification.

**5.3.6 Remaining trust assumptions.** GCPI v1 assumes that:
1. **Publishers** publish what they mean to. Authentication does not detect a wrong publication; §7 must.
2. **Fewer than *k* listed notaries collude** with a submitter. For proxy-mode attestation, also that no network-level attacker sits between a notary and the publisher.
3. **The Web PKI** issued the publisher's certificate correctly. A mis-issued certificate would let attestations of a fake server pass.
4. **The publisher's CDN** (Cloudflare for PSA and ICC on 18 October 2026) serves the publisher's content. TLS ends at the CDN.
5. **The pinned parser** for PDF and XLSX sources is correct. Anyone can check this by rerunning it on the attested bytes.
6. **At least one honest submitter** brings each market's observation each period. Otherwise the market is missing.
7. **Methodology governance** (§13.4–§13.11) changes the notary list, the sources and the keys only through a new version.

Not settled here, and left to Phase 4 (#92): *n*, *k*, and the notary operators. TLSNotary, the best-fitting design, supports only TLS 1.2, and PSA's OpenSTAT accepts only TLS 1.3. No mechanism recommended here can attest PSA today.

## 5.4 Permissionless submission

Anyone may submit a valid observation.

Collector registration must not be necessary for ordinary participation.

A security-bond or staking system may be introduced to discourage spam and fraudulent attestations, but it must not allow wealthy participants to determine the price by majority stake alone.

**Decided for v1 (#90):** submitters post a small anti-spam bond, returned at finalization. Notaries post a larger bond, slashable **only for objective, on-chain-provable faults**: signing two different values for the same source and period, or signing a period that has not happened. "This price is false" is never a slashing condition, because no contract can prove it without an arbiter. Stake never counts toward accepting a value. Bond sizes are set in Phase 4 (#92).

---

# 6. Price Normalization

All qualifying observations must be converted to the same reference unit.

**Canonical unit: USD per kilogram.**

## 6.1 Unit conversion

For a price published in USD per metric tonne:

```
P_USD/kg = P_USD/tonne / 1000
```

For a local-currency quotation:

```
P_USD/kg = P_Local/kg / FX_LocalPerUSD
```

## 6.2 Foreign exchange reference

Currency conversion must use a predefined FX observation rule.

The specification must establish:

- Accepted FX reference feeds.
- Applicable observation date.
- Maximum age of FX data.
- Required independent verification.
- Decimal precision.
- Fallback rules.
- Treatment of missing or disputed FX observations.

The protocol must never silently use a current FX rate to reinterpret a historical commodity quotation.

## 6.3 Deterministic arithmetic

All consensus-critical calculations must use fixed-point integer arithmetic.

Floating-point calculations must not be used inside the smart-contract consensus path.

The specification must define:

- Numeric scale.
- Rounding direction.
- Overflow handling.
- Maximum input values.
- Intermediate precision.
- Final output precision.

Reference implementations in different programming languages must produce byte-for-byte identical results.

**Defined by the reference engine (#91), as a draft for v1:**
- Prices and levels are integers in 10⁻¹⁸ USD/kg, and ln and exp are computed at 10³⁶.
- Every division rounds toward zero, except the few marked half up.
- Input bounds keep every intermediate below 2²⁵⁵.
- The Python and JavaScript implementations agree byte for byte on every published vector.

The full rules are in [ENGINE §2](../../gcpi/ENGINE.md#2-arithmetic-63).

---

# 7. Historical Price Validation

This is one of the most important GCPI safeguards.

Every market must maintain its own historical observation series.

## 7.1 Historical state

For each market, retain:

- Last accepted observation.
- Previous accepted observations.
- Original publication dates.
- Normalized prices.
- Rolling volatility statistics.
- Current source status.
- Pending anomalies.
- Rejected observations and rejection reasons.

## 7.2 Historical deviation

For each new observation:

```
D_i = abs(P_new - P_previous) / P_previous
```

This measures the absolute relative change.

However, historical deviation must be calculated using the elapsed time between publication dates.

A 10% change over one day and a 10% change over four weeks should not necessarily trigger the same validation outcome.

## 7.3 Proposed anomaly thresholds

The following are initial research parameters, not production-approved constants.

| Price deviation | Treatment                                            |
| --------------- | ---------------------------------------------------- |
| 0–5%            | Normal validation                                    |
| 5–10%           | Additional corroboration                             |
| 10–20%          | Strong confirmation required                         |
| Above 20%       | Quarantine pending deterministic recovery conditions |

These thresholds must be tested against historical copra prices and calibrated to the actual publication cadence.

**Decided for v1 (#90; §19 Q6): the bands above, scaled by √(weeks per period).** As written, they fit a weekly series: 86% of weekly Philippine changes fall in "normal". At monthly cadence they would send 43% of months to corroboration or stronger confirmation, almost all of them genuine moves. √(52/12) ≈ 2.08, fixed at **2** for monthly so that the bands are exact in fixed point:

| Monthly change | Treatment |
| -------------- | --------- |
| 0–10%          | Normal validation |
| 10–20%         | Additional corroboration |
| 20–40%         | Strong confirmation required |
| Above 40%      | Quarantine pending deterministic recovery conditions |

On 2016–2026 the scaled bands put 81% of headline months in "normal" and none in quarantine. Neither genuine shock (the 2017–19 fall of −62%, the 2024–25 rise of +145%) would have been quarantined. PSA's broken post-2024 series would still have been quarantined in 8 of 30 months under the bands as written ([BACKTEST §5](../../gcpi/BACKTEST.md#5-anomaly-thresholds)). The bands are fixed for the version; recalibrating them is a new version.

## 7.4 Rolling historical reference

The protocol should compare each observation against more than one previous value.

A proposed historical reference includes:

- Last accepted price.
- Median of the last five accepted observations.
- Rolling volatility estimate.
- Elapsed publication time.

The exact estimator and window length must be fixed in the methodology.

## 7.5 Cross-market corroboration

A sudden movement in one market should be compared with movements in other eligible markets.

Cross-market comparison should primarily use relative percentage changes, not absolute price levels, because different markets may have persistent regional price differences.

Example:

- Indonesia increases 25%.
- Philippines increases 22%.
- Sri Lanka increases 19%.
- India increases 21%.

This is stronger evidence of a global market movement than a 25% increase isolated to one market.

However, regional supply shocks are legitimate. The protocol must not require every country to move together.

**Decided for v1 (#90):** corroboration compares the **Philippines with Indonesia, and both with world coconut oil** (World Bank monthly, CFR Europe). It does not compare across all four core markets: India and Sri Lanka move with the export-linked pair only weakly, so a four-market check would raise false alarms. Each change of basis in the World Bank's coconut oil series (four so far) is treated as a break, not a price move. Coconut oil stays a corroboration signal and never enters the index (§2.2).

## 7.6 Quarantine and recovery

An anomalous observation enters a pending state.

It must not immediately affect the published index.

The observation may be admitted automatically when predefined confirmation conditions are satisfied, such as independently authenticated subsequent publications or corroborating market evidence.

Repeated readings of the same unverified erroneous value must not qualify as independent confirmation.

A pending observation must never be accepted merely because a timeout has expired.

## 7.7 Avoiding permanent historical anchoring

Historical validation must not permanently prevent genuine market repricing.

The methodology must support legitimate discontinuous movements when sufficient independent evidence exists.

Historical checks are safety controls, not artificial price ceilings.

---

# 8. Index Calculation

## 8.1 Primary formula

For each calculation period t:

```
GCPI_t = Σ(W_i × V_i,t × P_i,t) / Σ(W_i × V_i,t)
```

Where:

- W_i = fixed market weight.
- V_i,t = 1 if the observation is valid and eligible, otherwise 0.
- P_i,t = normalized market price in USD/kg.

Only observations satisfying all validation requirements may enter the calculation.

In v1 this formula sets only the level of the base period. Later periods are chain-linked from it (§8.4).

## 8.2 Freshness rules

Each source must have a documented publication schedule or expected cadence.

A proposed weekly-index policy is:

- Prefer observations published during the current calculation week.
- Permit recent observations within a maximum 14-day window where justified.
- Reject observations outside their approved freshness window.
- Preserve original publication timestamps.

An unchanged price must not be represented as a new observation merely because a collector retrieved it again.

**v1 (monthly, §8.6):** an observation belongs to the month it reports, not the month it was published. A period can finalize only after its sources publish it, which is up to about two months after month end. CDB's daily values must not be used as daily observations: 65–90% of them repeat the previous day ([BACKTEST](../../gcpi/BACKTEST.md#data-quality-findings)).

## 8.3 Minimum coverage

The proposed minimum publication requirements are:

- At least three independent eligible national markets.
- At least 70% of total configured market weight represented.
- No unresolved validation failure affecting the calculation.
- Required currency-conversion inputs available and valid.

The exact thresholds must be validated against historical availability.

**Decided for v1 (#90; §19 Q8):**
- **Headline: at least 70% of headline weight.** With weights of 0.65 and 0.35, that means both markets. Otherwise the period is non-valid.
- **Drop "at least three markets" for the headline,** which a two-market basket cannot meet.
- **A sub-index is valid only when its one market is valid.**

On 2016–2026 data both headline markets were present in 126 of 129 months. The longest run of non-valid months was one ([BACKTEST §6](../../gcpi/BACKTEST.md#6-minimum-coverage)). Expect about one non-valid month in 40.

## 8.4 Missing markets

When a market is temporarily unavailable, its weight may be removed from the current calculation and the remaining eligible weights renormalized.

However, this can create artificial index movements.

For example, excluding a consistently low-priced market can increase GCPI even when no actual market price has changed.

Therefore, GCPI must publish:

1. The calculated index value.
2. Effective market coverage.
3. Active source set.
4. Comparison with the previous source composition.
5. Whether the result is comparable with the previous index.

The production methodology should evaluate fixed-basket, matched-market, and chain-linked aggregation methods before selecting the final missing-data policy.

**Decided for v1 (#90; §19 Q5): matched-market chain-linking,** combined with the coverage rule of §8.3. This is the method the backtest tested ([BACKTEST §4](../../gcpi/BACKTEST.md#4-missing-market-handling)):

```
I_b = Σ(W_i × P_i,b) / Σ(W_i)                                  base period b, every market valid
I_t = I_s × exp( Σ_{i∈M}(W_i × ln(P_i,t / P_i,s)) / Σ_{i∈M}(W_i) )
```

Where:
- s = the last finalized VALID period before t.
- M = the markets valid in both t and s.
- b = the base period, fixed in the methodology version.

Why:
- **Renormalization moves the index when no price moves.** Dropping a market from a renormalized four-market level moved it by up to 47% in the backtest, and it snapped back when the market returned. Chain-linking does not jump.
- **Chain-linking also settles §19 Q4.** The index moves by each market's own change, so a persistent premium between markets never enters it.
- **Chain-linking is not a licence to estimate.** It loses the missing market's own moves for good. So when a large share of weight is missing, the period is non-valid (§8.3) rather than linked. For the v1 headline, the coverage rule makes any missing market a non-valid period. Linking then happens only across non-valid periods, from the last valid one.

Consequences that the methodology version must state:
- **The headline is a chain index in USD/kg at the base period, not the weighted mean of today's prices.** The two drift apart over time.
- **The reference engine (#91) fixes ln and exp in fixed point** (§6.3), with their precision and rounding, as part of the version. Independent implementations must match byte for byte. *Done: [ENGINE §2 and §6](../../gcpi/ENGINE.md#6-the-index-81-83-84-9).*
- **The comparability flag of item 5 above** is published every period.

## 8.5 Finalization

A calculation period may be finalized only when all required validation and coverage rules pass.

Finalization must be deterministic and permissionless.

Once finalized, the index record is immutable.

Later corrections must be published as separate correction records; historical outputs must not be silently overwritten.

## 8.6 Cadence (decided, #90)

**Monthly.** The calculation period is a calendar month, in UTC.

| Option | Decision | Why |
|---|---|---|
| Daily | **No** | No source supports it. CDB's daily values are mostly carried forward. CDA's daily bulletin exists only for 2026 and is a sub-index source. |
| Weekly | **Not in v1** | Only ICC publishes weekly headline-market prices, and ICC's data is all rights reserved. A weekly version needs an open weekly primary source for the Philippines or Indonesia, and is a new methodology version. |
| Monthly | **Yes** | The most that open headline sources support ([BACKTEST §7](../../gcpi/BACKTEST.md#7-cadence)). |

**What this costs consumers.** A monthly index published up to about two months late settles a COPRA-001 redemption about 3–4 months after the request. Monthly cadence also needs much more collateral than weekly cadence would: about 180–320% against 140–160% ([BACKTEST](../../gcpi/BACKTEST.md#ratios-implied-by-132)). Sizing that is COPRA-001's job (#96). GCPI's cadence is set by its sources, not by what a consumer would prefer.

---

# 9. Global Index Circuit Breaker

Historical source validation protects individual observations.

The global circuit breaker protects the final reference index.

## 9.1 Trigger

Calculate the change between the new candidate GCPI and the last finalized GCPI.

If the change exceeds a predefined threshold, place the candidate into a confirmation state.

## 9.2 Confirmation

Confirmation may require:

- Sufficient independent market coverage.
- Strong source authenticity.
- Consistent subsequent publications.
- No unresolved currency or unit conversion errors.

## 9.3 Important restriction

The circuit breaker must not permanently cap the price.

A genuine global commodity shortage may cause a large price increase.

The protocol must eventually reflect that increase when valid evidence supports it.

## 9.4 Circuit-breaker status

Possible states:

- VALID
- PENDING_CONFIRMATION
- INSUFFICIENT_COVERAGE
- STALE
- INVALID_INPUT
- UNAVAILABLE

A stale or unavailable index must not be presented as a newly verified price.

The reference engine (#91) defines when each state applies and in what order of priority ([ENGINE §6](../../gcpi/ENGINE.md#6-the-index-81-83-84-9)).

---

# 10. Decentralized Oracle Architecture

## 10.1 Separation of responsibilities

The proposed architecture consists of:

**Observation Layer**

Independent participants retrieve and preserve published commodity prices.

**Verification Layer**

Cryptographic proofs, independent attestations, and deterministic rules establish whether observations qualify.

**Calculation Layer**

A fixed reference algorithm produces the candidate GCPI.

**Settlement Layer**

An immutable smart contract verifies accepted inputs or a sound proof of the calculation, finalizes the index, and records its status.

**Consumer Layer**

External applications, including $COPRA, read finalized index values.

## 10.2 No privileged price setter

The index contract must not contain:

- Owner-only price updates.
- Administrator-adjustable market weights.
- Manual anomaly bypasses.
- Privileged source replacement.
- Hidden emergency price setters.
- Arbitrary upgrade functions.

## 10.3 Permissionless execution

Any participant must be able to submit a valid finalization transaction.

The contract must produce the same result regardless of which participant submits it.

A scheduled external automation service may trigger updates, but it must not be the sole authorized executor.

## 10.4 Execution incentives

Permissionless execution does not guarantee that someone will pay transaction fees.

The protocol must specify a sustainable incentive mechanism, such as bounded reimbursement from a pre-funded pool.

This introduces an additional requirement: the protocol must remain safe when the incentive pool is exhausted.

Lack of execution must result in an explicitly stale index, not an invented update.

---

# 11. On-Chain Contract Design

## 11.1 ObservationVerifier

Responsibilities:

- Verify source attestations or observation proofs.
- Enforce source eligibility.
- Reject duplicate submissions.
- Validate timestamps and numeric ranges.
- Preserve observation commitments.

## 11.2 GCPIEngine

Responsibilities:

- Apply fixed normalization and aggregation rules.
- Maintain historical market state.
- Evaluate anomalies.
- Enforce minimum coverage.
- Apply global circuit-breaker rules.
- Produce deterministic candidate prices.

If computation is performed off-chain, the on-chain verifier must verify a cryptographic proof of correct execution or another explicitly documented trust-minimized attestation mechanism.

A hash of an off-chain result alone is insufficient.

## 11.3 GCPIRegistry

Responsibilities:

- Store finalized reference values.
- Store calculation-period identifiers.
- Record methodology identifiers.
- Record source-set commitments.
- Publish index status.
- Emit events for consumers.

## 11.4 CopraToken integration

The $COPRA protocol reads finalized GCPI values.

It must reject price-sensitive operations when the index is stale or invalid, according to immutable risk rules.

The oracle must never be able to mint tokens, withdraw reserves, or change collateral policy merely because it supplies a price.

---

# 12. Data Transparency

Every finalized GCPI observation must have a public audit record.

## 12.1 Required record fields

- Calculation period.
- Finalization timestamp.
- GCPI value.
- Methodology version.
- Source market identifiers.
- Original published prices.
- Original currencies and units.
- Source publication timestamps.
- Source references.
- Exchange rates used.
- Quality and delivery adjustments.
- Effective weights.
- Excluded markets and reasons.
- Historical anomaly decisions.
- Source commitments.
- Calculation input commitment.
- Transaction identifier.
- Index status.

## 12.2 Open historical dataset

GCPI should maintain a public, append-only historical dataset.

Records should be available in machine-readable formats such as JSON and CSV, with canonical encoding for cryptographic verification.

Data should be replicated across independent archival systems, including content-addressed storage where practical.

On-chain commitments can establish integrity, but raw source records must remain accessible for meaningful independent audits.

## 12.3 Independent reproduction

A third party should be able to:

1. Retrieve a historical GCPI period.
2. Download its contributing observations.
3. Verify the source records and attestations.
4. Apply the documented normalization rules.
5. Recalculate the weighted index.
6. Obtain the exact finalized value.

If this cannot be done, the index has not met its transparency objective.

---

# 13. Immutability and Versioning

## 13.1 Immutable methodology

Each GCPI methodology version must have a unique identifier and a cryptographic commitment to its specification and executable calculation rules.

Once deployed, that methodology must not be modified.

## 13.2 Protocol evolution

New versions may be developed to improve:

- Market coverage.
- Source availability.
- Data verification.
- Statistical methodology.
- Contract efficiency.
- Resilience to new failure modes.

However, no new version may silently replace an existing immutable index.

Each version must have its own identifiable contract or immutable verification configuration.

## 13.3 Migration

Consumers may independently decide whether to adopt a new version.

The GCPI protocol must not give any administrator the authority to force all consumers onto a new methodology.

This approach allows innovation without granting hidden control over historical or current index values.

## 13.4 Governance: why it is part of the methodology

§13.1–§13.3 make each version immutable and let consumers choose. They do not say who writes the next version, or how it comes to be released. For a benchmark meant to be neutral, that process is where control would hide. Sources, weights, thresholds, notaries and parsers are all fixed per version (§3.3, §4.3, §5.3.1), so whoever writes the next version chooses them.

§13.4–§13.11 define that process. They follow the IOSCO *Principles for Financial Benchmarks* (2013) where those apply to a benchmark with no administrator: Principle 3 (conflicts of interest), 5 (oversight), 10 (periodic review), 12 (changes to the methodology) and 13 (transition) ([IOSCO FR07/13](https://www.iosco.org/library/pubdocs/pdf/IOSCOPD415.pdf)). Whether GCPI or anyone running it is a benchmark administrator in law is a question for the legal review (#98), not for this section.

**The process binds the reference repository's version series, not the world.** Anyone may fork this methodology and publish their own index. They may not call it a GCPI version unless it went through this process. A process with no authority behind it works only if it is checkable. So every step below leaves a public record, and a version whose record is incomplete is not a GCPI version.

## 13.5 Version identity and commitment (§13.1)

- **Identifier.** Released versions are numbered `GCPI-1`, `GCPI-2`, and so on, and are never reused. A sub-index carries its version and market: `GCPI-1/IN`. Drafts are `GCPI-1-draft.N` and must never be read by a contract that settles value.
- **Bundle.** A version is a set of files:
  - this specification at that version;
  - a parameter file (sources and their locations, weights, bands, coverage, base period, notary list, *k*, publisher keys, challenge window);
  - the reference engine source (#91) and its test vectors;
  - the pinned parsers for PDF and XLSX sources;
  - the review reports of §13.8.
- **Manifest.** The bundle's manifest lists every file's path and SHA-256. It is encoded canonically, as JSON under RFC 8785 (JCS).
- **Commitment.** The version's commitment is the SHA-256 of the manifest. A git commit hash is not the commitment: it names a repository state, and that state is not the same thing as the bundle.
- **On-chain record.** Each version's contracts store the identifier and the commitment immutably at deployment (§11.3). Every finalized period records both (§12.1).
- **What a change means.** Any change to any file in the bundle is a new version. Nothing of the bundle can be edited after release, including typo fixes. A correction to the prose that leaves every computed value unchanged may be published as an erratum beside the version. It does not change the commitment, and it cannot change a number.

## 13.6 Proposing a version: public RFC

- **Who:** anyone may propose a new version. Proposing requires no permission and no stake.
- **Where:** a pull request adding `gcpi/rfcs/NNNN-<title>.md` to the reference repository, opened together with a public discussion thread (#95). Comments are public and stay public.
- **What an RFC contains:**
  1. The problem it solves, with evidence.
  2. Every change, as a diff of the bundle.
  3. A backtest of the proposed version against the current one, on the open historical dataset (§12.2). It must show where their values would have diverged and by how much.
  4. Whether the new version continues the old series (comparable) or starts a new one. A version that changes sources, weights or aggregation starts a new series unless the RFC shows the two series cannot diverge (§4.3).
  5. The effect on known consumers. This includes $COPRA (§15), which binds one version at deployment (COPRA-001 §4.3) and is not moved by a new release.
  6. The author's conflicts of interest (§13.11).

## 13.7 Comment period

- **At least 30 days** from the moment the RFC is marked ready for comment.
- **Any substantive change to the proposal restarts the period**, with at least 14 days remaining.
- **The author publishes a response to every substantive comment.** Each response says whether the comment was accepted and why. That record is part of the bundle.
- **No expedited path.** No emergency shortens the period or changes a released version. That costs liveness, not safety: a version whose sources fail produces a non-valid status (§9.4, Invariant 10), never a wrong value. Only a new version can fix it.

## 13.8 Independent review

A version may be released only after **at least two independent reviewers** have each published a written report on the complete bundle.

- **Independent** means the reviewer:
  - is not the RFC's author;
  - is not employed, paid or funded by copra.dev, BytesBrains or the RFC's author;
  - holds no $COPRA, no COPRA-001 position and no other exposure to a GCPI consumer.
  Each reviewer states this in the report.
- **What a reviewer must do:**
  - Rebuild the test vectors from the bundle and confirm they match.
  - Reproduce the RFC's backtest from the open dataset.
  - Check the parameters against the evidence cited for them.
  - Report every finding.
- **A report that raises a blocking finding blocks release,** until a new revision answers it and a reviewer confirms the answer.
- **If no independent reviewer can be found, the version stays a draft.** It is not released with fewer reviewers.

## 13.9 Release and adoption

- **A version is released when its record is complete:**
  - the RFC;
  - a comment period that has run in full;
  - a response to every comment;
  - two independent review reports with no open blocking finding;
  - the bundle and its commitment, published.
  The reference repository's maintainers merge a release only when that record is complete. They may refuse to merge. They cannot release a version whose record is incomplete, because anyone can check the record.
- **Release is not adoption.** Releasing a version deploys its own immutable contracts (§13.2). It changes no other version, and it moves no consumer. Each consumer decides whether, and when, to bind the new version (§13.3).

## 13.10 Periodic review and retirement

- **Review.** At least once a year, every released version that is still producing values gets a public review. It covers:
  - source availability;
  - data breaks;
  - coverage achieved;
  - non-valid periods and their causes;
  - incidents.
  A review can only recommend. Anything it finds is acted on through an RFC.
- **Retirement.** A version is never switched off. If its sources stop publishing, it stops producing VALID periods and says why (§9.4). The repository may mark a version as superseded, with at least 6 months' notice and a link to its successor. That is a notice to consumers, not an action on the version, which keeps finalizing whatever its sources allow.

## 13.11 The reference registry, the site, and conflicts of interest

copra.dev runs this repository today, and will run its site (#94). copra.dev also builds $COPRA, the first consumer of GCPI (§15, COPRA-001). Minters and holders of $COPRA have opposite exposure to every GCPI value. Anyone with such a position has an interest in the index level, and in the next version's sources, weights and thresholds.

**copra.dev's registry and site are a soft default.** They decide what a visitor sees first. They decide no value and bind no consumer.

They **may**:
- List released versions, each with its identifier, commitment, contracts and review reports.
- Show one version by default, and say so wherever they do.
- Keep a version list on-chain, if that list can only be appended to.

They **may not**:
- Remove a released version from the list, or hide its values.
- Present the default as the only GCPI, or as endorsed by anyone but copra.dev.
- Call a version recommended without linking its review reports.
- Stand between a consumer and a version. Consumers read a version's own contracts, bound immutably (COPRA-001 §4.3). Nothing like $COPRA v1's owner-repointable `CopraRegistry` (`src/CopraRegistry.sol`) may sit in that path. An on-chain default pointer, if one exists, is advisory and must never be read for a price.

**Disclosure.** The site, every RFC and every version bundle carry this statement:

> copra.dev builds $COPRA, which settles against GCPI. copra.dev runs this repository and chooses which GCPI version its site shows first. That choice is not part of any methodology and binds no one. Every released version, its review reports and its full record are listed regardless of that choice.

- **RFC authors and reviewers** each declare their $COPRA holdings, any COPRA-001 positions, and who pays them.
- **A declared conflict does not disqualify an author.** It does disqualify a reviewer (§13.8).

---

# 14. Security and Adversarial Threat Model

The implementation must explicitly address the following attacks.

| Threat                         | Required defense                                                         |
| ------------------------------ | ------------------------------------------------------------------------ |
| Fabricated market quotation    | Source authentication and independent verification                       |
| Multiple fake collectors       | Sybil-resistant attestation rules; no simple account-count majority      |
| Compromised source website     | Cross-source corroboration and anomaly controls                          |
| Manipulated FX rate            | Independent FX verification and freshness rules                          |
| Stale-price replay             | Publication-time and period validation                                   |
| Duplicate source reporting     | Source lineage and deduplication                                         |
| Extreme false quotation        | Historical checks and quarantine                                         |
| Real global price shock        | Deterministic confirmation and recovery                                  |
| Missing regional market        | Coverage thresholds and explicit status                                  |
| Contract arithmetic exploit    | Fixed-point arithmetic, bounds checking, formal tests                    |
| Malicious transaction ordering | Order-independent finalization rules                                     |
| Keeper outage                  | Permissionless execution and safe stale-state behavior                   |
| Data archive loss              | Independent replication and integrity commitments                        |
| Colluding attestors            | Explicit trust model, economic security, and independent source evidence |

No finite set of anomaly thresholds guarantees protection against coordinated manipulation.

The system must be assessed under both accidental failure and deliberate adversarial conditions.

---

# 15. Relationship with $COPRA

GCPI is a reference price, not a collateral asset.

If GCPI publishes USD 1.42/kg, the reference value of one $COPRA may be defined as USD 1.42.

That does not establish that one $COPRA can always be redeemed for USD 1.42.

The token protocol must separately define:

- Collateral assets.
- Reserve valuation.
- Minting requirements.
- Redemption liabilities.
- Fees.
- Solvency rules.
- Liquidity management.
- Treatment of commodity appreciation.
- Treatment of commodity depreciation.
- Behavior during oracle outages.
- Handling of extreme redemption demand.

A perfectly accurate commodity oracle cannot guarantee solvency.

**The price-index protocol and the financial reserve protocol must be independently specified and audited.** The reserve protocol is specified in [COPRA-001](COPRA-001.md).

---

# 16. Recommended Development Roadmap

## Phase 1 — Source research and verification

Build a machine-readable registry of candidate price publications.

For every source, document:

- Official URL or API.
- Publication frequency.
- Available history.
- Commodity definition.
- Currency.
- Units.
- Pricing basis.
- Licensing and redistribution conditions.
- Source-authentication method.
- Observed outages and reporting delays.

**Exit criterion:** A defensible set of independent, comparable sources with sufficient historical coverage.

## Phase 2 — Historical research

Collect available historical observations.

Test:

- Country price correlations.
- Regional price spreads.
- Publication delays.
- Historical volatility.
- Missing-data frequency.
- Weighting methodologies.
- Effects of source composition.
- False anomaly triggers.
- Genuine market shocks.

**Exit criterion:** A documented benchmark methodology supported by historical evidence.

## Phase 3 — Deterministic reference engine

Implement an open-source calculation library.

The library must accept canonical observations and produce a deterministic result without discretionary inputs.

Publish test vectors for normal conditions, missing sources, extreme movements, currency conversion, and rounding.

**Exit criterion:** Independent implementations produce identical results.

**Status (#91):** met. See [ENGINE](../../gcpi/ENGINE.md):
- Python and JavaScript engines give byte-identical output on 27 published vectors and on the 2016–2026 backtest inputs.
- They reproduce the Phase 2 backtest values within float rounding.
- Under the v1 draft rules, 125 of 129 headline months would have been VALID.
- The engine had to fix eight rules that this specification leaves open. They are [listed for the v1 RFC](../../gcpi/ENGINE.md#choices-the-spec-left-open).

## Phase 4 — Decentralized collection and verification

Deploy independent collectors and source-verification mechanisms.

Test collusion, replay attacks, outages, and false publications.

**Exit criterion:** The system does not rely on a single collector or privileged submitter for correctness.

**Status (#92):** the on-chain side is built, and so is reference collector and notary software; nobody operates it yet. See [CONTRACTS](../../gcpi/CONTRACTS.md) and [COLLECTORS](../../gcpi/COLLECTORS.md):
- Anyone may submit an observation that *k* of the listed notaries attest, and anyone may finalize. The result does not depend on the submitter, the finalizer, the order or a keeper outage.
- A reference notary signs only an observation it retrieved itself, and never two values for one market, source and period. A reference collector gathers *k* attestations and submits. On anvil, the verifier accepts its observation with 2 of 3 notaries.
- Not yet: independently operated collectors and notaries, and *n*, *k*, the operators and the bond sizes ([what remains](../../gcpi/CONTRACTS.md#what-remains-of-92)).

## Phase 5 — Smart contracts and public testnet

Deploy immutable experimental contracts.

Perform:

- Unit and property-based testing.
- Fuzz testing.
- Adversarial testing.
- Economic incentive analysis.
- Independent security review.
- Public reproducibility testing.

**Exit criterion:** Verified on-chain behavior matches the reference implementation.

**Status (#92):** behavior matches; deployment and review are open. See [CONTRACTS](../../gcpi/CONTRACTS.md):
- `ObservationVerifier`, `GCPIEngine` and `GCPIRegistry` (§11) reproduce every published vector byte for byte, and they have no owner, setter or upgrade path.
- Unit, property-based, fuzz and adversarial tests are done.
- Not yet: the Base Sepolia deployment, the independent security review and the incentive analysis.

## Phase 6 — Shadow mainnet publication

Publish GCPI on Base without using it for live minting or redemption.

Compare its behavior against published commodity quotations over an extended observation period.

**Exit criterion:** Stable source coverage, reproducible calculations, documented incident handling, and satisfactory independent review.

## Phase 7 — $COPRA integration

Integrate the validated index with the separately audited $COPRA collateral and redemption system.

No live economic dependency should be activated before the oracle and reserve mechanisms have been tested together.

---

# 17. Acceptance Criteria

GCPI v1 may be considered ready for production consideration only when:

- The reference commodity is unambiguously defined.
- Every included source has documented provenance.
- Global weights are independently reproducible.
- Historical observations are sufficiently available for backtesting.
- All consensus calculations are deterministic.
- No privileged price-setting authority exists.
- Collector failure does not compromise correctness.
- Source failures produce deterministic outcomes.
- Historical anomaly rules are tested against real data.
- Genuine large price movements can be accepted without discretionary intervention.
- Stale data is never presented as a fresh price.
- All finalized results are independently reproducible.
- Contract code and verification mechanisms are publicly auditable.
- Permissionless finalization is demonstrated.
- The economic incentives for operation are documented.
- The $COPRA reserve mechanism is separately validated.
- An independent security review is completed.
- The version was released through §13.6–§13.9, including two independent reviews.

---

# 18. Non-Negotiable Protocol Invariants

The following invariants should govern every implementation.

**Invariant 1 — Determinism**

Identical validated inputs, state, and methodology version must always produce identical results.

**Invariant 2 — No discretionary price control**

No privileged actor may select, replace, or override the reference price.

**Invariant 3 — Source accountability**

Every accepted observation must be traceable to its underlying published record and verification evidence.

**Invariant 4 — Historical integrity**

Finalized historical index values must never be silently rewritten.

**Invariant 5 — Explicit uncertainty**

Insufficient evidence must result in a non-valid status rather than a fabricated value.

**Invariant 6 — Permissionless participation**

No exclusive party may control the right to submit valid observations or finalize eligible calculation periods.

**Invariant 7 — Methodology immutability**

A published methodology version must not change after deployment.

**Invariant 8 — Separation of powers**

Price observation and calculation authority must not imply authority over token issuance or collateral reserves.

**Invariant 9 — Reproducibility**

Independent implementations must be capable of reconstructing finalized index values from authenticated inputs.

**Invariant 10 — Safe failure**

When required assumptions fail, the protocol must transition into an explicitly defined safe state rather than continue publishing unsupported prices.

---

# 19. Open Questions Before Freezing v1

The following decisions must be resolved empirically, not by intuition:

1. Which exact copra grade and commercial delivery basis should represent the global benchmark?
2. Which publicly available sources provide sufficiently reliable, independently verifiable observations?
3. Should weights represent production, exports, or a combination of both?
4. How should the index handle persistent regional price spreads?
5. Should missing-source handling use renormalization, matched-market changes, or a chain-linked index?
6. Which historical volatility thresholds minimize false positives without suppressing genuine price movements?
7. What cryptographic or economic mechanism can authenticate source observations without a privileged oracle committee?
8. What minimum market coverage is achievable during real historical outages?
9. How will data collection, verification, and transaction execution be financed sustainably?
10. What regulatory obligations apply to the benchmark publisher, oracle infrastructure, and $COPRA token separately?

These questions should be answered before deploying immutable production contracts.

Status after #90. The details are in §21.

| Q | Status | Where |
|---|---|---|
| 1. Grade and basis | **Decided:** domestic basis, dried milling copra, export-linked headline. Numeric quality limits are still open. | §2.4 |
| 2. Reliable, verifiable sources | **Open, and blocking.** There is no open, reliable Philippine series (PSA broke in 2024; ICC is all rights reserved) and no primary Indonesian source. | §21 |
| 3. Weights | **Decided:** production, 0.65 / 0.35 | §4.4 |
| 4. Regional spreads | **Decided:** India and Sri Lanka become sub-indices; chain-linking keeps premia out of the index | §2.4, §8.4 |
| 5. Missing sources | **Decided:** matched-market chain-linking, plus the coverage rule | §8.4 |
| 6. Volatility thresholds | **Decided:** §7.3 bands ×2 at monthly cadence | §7.3 |
| 7. Authentication | **Decided:** k-of-n notaries fixed per version; disputes by counter-evidence. *n*, *k* and the operators are set in Phase 4 (#92). | §5.3 |
| 8. Minimum coverage | **Decided:** 70% of headline weight | §8.3 |
| 9. Financing | Open | §10.4 |
| 10. Regulation | Open: #98 | — |
| Cadence (not in the original list) | **Decided:** monthly | §8.6 |

---

# 20. Long-Term Vision

GCPI should become a neutral, globally accessible reference for the economic value of copra.

It should not belong to copra.dev, BytesBrains, a foundation, a token-holder committee, or any government.

Its rules should be publicly inspectable, its results independently reproducible, and its operation open to anyone who can satisfy the protocol's verification requirements.

The protocol should continue functioning when its original developers disappear, subject to the continued availability of trustworthy commodity data, participating infrastructure, the underlying blockchain, and sufficient execution incentives.

**GCPI should not ask the world to trust whoever publishes its price. It should provide the evidence and mathematics necessary for the world to verify that price independently.**

---

# 21. v1 Decision Record

Decided in #90 from the research in #87, #88 and #89. They are draft decisions. They bind nothing until a version containing them is released through §13.6–§13.9. Its RFC is where anyone can challenge them.

| Decision | v1 value | Evidence |
|---|---|---|
| Reference basis (Q1) | Domestic, as published; no basis or quality adjustment | [SOURCES §1](../../gcpi/SOURCES.md#1-there-is-no-public-export-price-to-anchor-to) |
| Grade (Q1) | Dried milling copra, each source's milling grade recorded verbatim | [SOURCES](../../gcpi/SOURCES.md#answers-to-the-issues-questions) |
| Headline basket | Philippines + Indonesia | [BACKTEST §1](../../gcpi/BACKTEST.md#1-correlations-and-spreads) |
| Sub-indices | India (CDB), Sri Lanka (CDA), each on its own | [BACKTEST §1](../../gcpi/BACKTEST.md#1-correlations-and-spreads) |
| Weights (Q3) | Production: 0.65 / 0.35, fixed | [BACKTEST §3](../../gcpi/BACKTEST.md#3-weighting-production-vs-exports) |
| Aggregation (Q5) | Matched-market chain-linking, weighted geometric mean of relatives | [BACKTEST §4](../../gcpi/BACKTEST.md#4-missing-market-handling) |
| Coverage (Q8) | At least 70% of headline weight; no market count | [BACKTEST §6](../../gcpi/BACKTEST.md#6-minimum-coverage) |
| Anomaly bands (Q6) | §7.3 ×2: 10 / 20 / 40% | [BACKTEST §5](../../gcpi/BACKTEST.md#5-anomaly-thresholds) |
| Corroboration | Philippines ↔ Indonesia, both ↔ world coconut oil | [SOURCES §2](../../gcpi/SOURCES.md#2-the-core-markets-split-into-two-regimes) |
| Cadence | Monthly, calendar month UTC | [BACKTEST §7](../../gcpi/BACKTEST.md#7-cadence) |
| Authentication (Q7) | k-of-n listed notaries; publisher signatures substitute; disputes make the market missing | [AUTHENTICATION](../../gcpi/AUTHENTICATION.md#recommendation) |
| Challenge window | 3 days per period | [AUTHENTICATION](../../gcpi/AUTHENTICATION.md#recommendation) |
| Governance | §13.4–§13.11 | IOSCO Principles 3, 5, 10, 12, 13 |

**What still blocks freezing v1.** These are data problems, not method problems:

1. **No open, reliable Philippine series.** PSA's series broke in January 2024 and is withdrawn until PSA explains it. ICC's is reliable but all rights reserved.
2. **No primary Indonesian source.** The coverage rule (§8.3) needs both headline markets, so without one no headline period can be VALID.
3. **Republication terms** have not been confirmed by PSA, CDB or CDA. FAOSTAT's licence clause needs a legal read (#98).
4. **Numeric quality limits** for the reference grade (§2.4).
5. **No attestation for PSA.** It is TLS 1.3 only, and TLSNotary is TLS 1.2 only.
6. **Two independent reviewers** (§13.8) have not yet been found.

*End of GCPI-001, Draft v1.0.*
