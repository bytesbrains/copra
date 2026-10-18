# GCPI — Global Copra Price Index

## Decentralized Commodity Reference Protocol

**Specification:** GCPI-001\
**Version:** 1.0 Draft\
**Network:** Base L2 (initial deployment)\
**Reference unit:** USD per kilogram of standardized milling copra\
**License proposal:** CC0 for methodology; Apache-2.0 or MIT for implementation\
**Status:** Proposed architecture — subject to data-source validation, historical backtesting, economic modeling, and security review\
**Companion:** [COPRA-001](COPRA-001.md), the $COPRA reserve and redemption protocol that consumes this index

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

---

# 3. Global Market Coverage

## 3.1 Initial candidate markets

| Market                   | Candidate public sources                                              | Initial role |
| ------------------------ | --------------------------------------------------------------------- | ------------ |
| Philippines              | Philippine Coconut Authority, ICC, industry price publications        | Core         |
| Indonesia                | ICC and published Indonesian commodity reports                        | Core         |
| India                    | Coconut Development Board, AGMARKNET, recognized wholesale quotations | Core         |
| Sri Lanka                | Coconut Development Authority                                         | Core         |
| Papua New Guinea         | Official commodity and export reports                                 | Expansion    |
| Solomon Islands          | Government and commodity-sector reports                               | Expansion    |
| Vanuatu                  | Government and commodity-sector reports                               | Expansion    |
| Other qualifying markets | Publicly verifiable official or recognized industry publications      | Expansion    |

This list is a discovery target, not a declaration that every source currently provides suitable automated access.

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

## 5.4 Permissionless submission

Anyone may submit a valid observation.

Collector registration must not be necessary for ordinary participation.

A security-bond or staking system may be introduced to discourage spam and fraudulent attestations, but it must not allow wealthy participants to determine the price by majority stake alone.

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

## 8.2 Freshness rules

Each source must have a documented publication schedule or expected cadence.

A proposed weekly-index policy is:

- Prefer observations published during the current calculation week.
- Permit recent observations within a maximum 14-day window where justified.
- Reject observations outside their approved freshness window.
- Preserve original publication timestamps.

An unchanged price must not be represented as a new observation merely because a collector retrieved it again.

## 8.3 Minimum coverage

The proposed minimum publication requirements are:

- At least three independent eligible national markets.
- At least 70% of total configured market weight represented.
- No unresolved validation failure affecting the calculation.
- Required currency-conversion inputs available and valid.

The exact thresholds must be validated against historical availability.

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

## 8.5 Finalization

A calculation period may be finalized only when all required validation and coverage rules pass.

Finalization must be deterministic and permissionless.

Once finalized, the index record is immutable.

Later corrections must be published as separate correction records; historical outputs must not be silently overwritten.

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

## Phase 4 — Decentralized collection and verification

Deploy independent collectors and source-verification mechanisms.

Test collusion, replay attacks, outages, and false publications.

**Exit criterion:** The system does not rely on a single collector or privileged submitter for correctness.

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

---

# 20. Long-Term Vision

GCPI should become a neutral, globally accessible reference for the economic value of copra.

It should not belong to copra.dev, BytesBrains, a foundation, a token-holder committee, or any government.

Its rules should be publicly inspectable, its results independently reproducible, and its operation open to anyone who can satisfy the protocol's verification requirements.

The protocol should continue functioning when its original developers disappear, subject to the continued availability of trustworthy commodity data, participating infrastructure, the underlying blockchain, and sufficient execution incentives.

**GCPI should not ask the world to trust whoever publishes its price. It should provide the evidence and mathematics necessary for the world to verify that price independently.**

*End of GCPI-001, Draft v1.0.*
