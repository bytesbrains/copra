# GCPI Phase 5: On-Chain Contracts

**Issue:** #92 · **Methodology:** [GCPI-001](../docs/specs/GCPI-001.md) §5.3–§5.4, §8–§11, §14, §16 Phases 4–5 · **Run:** 19 October 2026
**Builds on:** [reference engine](ENGINE.md) (#91), [source authentication](AUTHENTICATION.md) (#89), [v1 decisions](../docs/specs/GCPI-001.md#21-v1-decision-record) (#90) · **Feeds:** #93 (shadow publication), #97 (COPRA-001 v2)
**Code:** [`src/gcpi/`](../src/gcpi/) · **Tests:** [`test/gcpi/*.t.sol`](../test/gcpi/) · **Deploy:** [`script/DeployGCPI.s.sol`](../script/DeployGCPI.s.sol) · **Reproduce:** [below](#reproducing)

---

## Result

| Done when (#92) | Status |
|---|---|
| On-chain results match the reference engine for every test vector | **Met.** Each published vector runs through the real contracts: observations are submitted with notary signatures at their publication time, and each period is finalized as soon as its window closes. The on-chain state, encoded as the engine encodes its output, has the vector's SHA-256 for all 21 output vectors. Three of the six error vectors revert with the engine's error code. The other three cannot be expressed through a typed ABI (a JSON number, a decimal with a leading zero, an unknown field), and a test pins that it is exactly those three. |
| Unit, property-based and fuzz tests, plus an independent security review | **Tests met; the review is not done.** 61 Forge tests, fuzz tests among them, cover the arithmetic, the attestation rules and §14's threats ([table](#threat-model-14)). Two mutation checks were run by hand: a band off by one basis point and a tie decided the other way. Both fail the vectors. No independent review has taken place. |
| Correctness does not depend on any single collector or submitter | **Met by the contracts; not yet shown with real collectors.** Anyone may submit an attested observation and anyone may finalize. Acceptance needs *k* distinct notaries from the list fixed at deployment, and the caller of `finalize()` cannot change the result. Tests show that the finalizer, the submission order and a three-year keeper outage all leave the output unchanged. No independently operated collector exists yet ([what remains](#what-remains-of-92)). |

## The contracts

| Contract | GCPI-001 | What it does |
|---|---|---|
| [`ObservationVerifier`](../src/gcpi/ObservationVerifier.sol) | §11.1, §5.3–§5.4 | Accepts an observation when *k* of the *n* listed notaries sign its commitment. It refuses duplicates and closes each period's window. It holds the submitter and notary bonds and slashes the faults a contract can prove. |
| [`GCPIEngine`](../src/gcpi/GCPIEngine.sol) | §11.2, §7–§9 | The reference engine, one period per `finalize()`. It runs normalization, market decisions, coverage, chain-linking and the circuit breaker, and it holds the incentive pool. |
| [`GCPIRegistry`](../src/gcpi/GCPIRegistry.sol) | §11.3, COPRA-001 §4.1 | Write-once period records `(status, price, finalizedAt, inputCommitment)`, by period id. It is deployed by the engine, which is its only writer. |
| [`GCPIMath`](../src/gcpi/GCPIMath.sol) | §6.3 | ln, exp, the band tests, the calendar and the commitments, ported line by line from `engine.py` |

**None of them can be changed.** There is no owner, no upgrade path, no pause and no setter. The methodology, the notary list, *k*, the windows, the bonds and the reward are constructor arguments. `test_TrustAssumption_NoContractHasAPrivilegedFunction` reads every state-changing function from the compiled ABIs:
- `GCPIEngine`: `finalize`, `advance`, `claimReward`.
- `GCPIRegistry`: `publish`, which only the engine can call, once per period.
- `ObservationVerifier`: `submit`, `refundBond`, `bond`, `beginUnbonding`, `withdrawBond`, `slashEquivocation`, `slashPremature`.

A change of any parameter is a new methodology version and a new deployment (§13).

**The methodology hash is computed on-chain.** The engine builds the methodology's canonical JSON in its constructor and hashes it. For [`gcpi-001-v1-draft.json`](engine/methodology/gcpi-001-v1-draft.json) it gives `0a7ac0a0…3e1d`, the same as `engine.py`.

## How the on-chain engine stays equal to engine.py

`engine.py` is a pure function over every observation from `first` to `last`. The contract computes the same thing one period at a time. This works because of rules the engine already has (ENGINE §5–§6):
- **A period's observations are fixed before it is computed.** `finalize()` for period *t* is refused until *t*'s window has closed: the 90-day publication lag, then the 3-day challenge window (§5.3.3). After that the verifier accepts nothing more for *t*. That window is the engine's own freshness rule, so every observation the engine would count as fresh can still arrive in time.
- **A market's decision at *t* depends only on periods up to *t*.** Pending observations are settled by later publications of the same market and never revised after that.
- **Index periods are computed in order.** Each one is computed once all its markets are decided. While a market is pending, every later index period waits, as in the engine. Its record then reads `market_pending` or `earlier_period_pending`, exactly as the engine reports it.
- **No call does unbounded work.** A market pending for years releases every index period after it at once. A call computes at most 24 of them (`MAX_INDEX_PER_CALL`), and anyone may call `advance()` for the rest. The inputs are already fixed, so when they are computed changes nothing. The `long_pending` vector crosses the cap.
- **A record is written to the registry when it becomes final, and never again.** A record held by the circuit breaker is not final. It reaches the registry when a later period confirms or rejects it.

So the contracts after finalizing period *L* hold what `engine.py` returns for `last = L`. That is what the vector test compares.

## Authentication as implemented (§5.3.1)

- **An attestation is a notary's EIP-712 signature over the observation's commitment** (ENGINE §7). The domain binds it to one verifier on one chain, so a signature cannot be replayed on another deployment or chain.
- **A submission carries at least *k* signatures, in ascending signer order.** That makes the signers distinct without a set. Each signer must be listed, bonded, not unbonding and never slashed. Any number of keys outside the list adds nothing (§14, "multiple fake collectors").
- **What the signature means is off-chain.** A notary signs after taking part in the TLS session that retrieved the value (§5.3.1, TLSNotary's model). The contract checks the signatures, not the session.
- **Disputes need no vote (§5.3.2).** Two attested observations of one market and period that disagree are both kept, and the engine makes the market DISPUTED for the period.
- **A submission must not claim a publication time in the future.** No notary can have retrieved a publication that has not happened yet.
- **A submission must not be for a period that has not begun.** Attesting one is a slashable fault, so it is refused rather than stored, where it would hold one of the period's 16 slots until the period closed.

**Bonds (§5.4).**
- **Submitters** post `submitBond`, returned by `refundBond` once the period closes. It is an anti-spam lockup only, and nothing slashes it.
- **Notaries** post `notaryBond`. It is slashed only for two faults a contract can prove:
  - **Equivocation:** one notary signed two observations of the same market, source and period with different normalized prices or bases. Two retrievals of the same value, or the same value written differently, are not equivocation.
  - **Premature attestation:** a signed period that has not begun, or a publication time still in the future. "Future" is measured against `block.timestamp`, which only moves forward, so a signature that was not premature when it was made can never become slashable later. The contract's clock can lag real time by a block, though, so a notary signs only after a block whose timestamp has passed both the period's start and the publication time.
- **Slashing pays the reporter half the bond** and keeps the rest in the contract for good. The notary never counts again.
- **Leaving is delayed.** A notary that unbonds stops counting at once, stays slashable through the delay, and can withdraw afterwards.
- **Stake never weighs on a value.** A signature either counts or it does not.

**Incentive pool (§10.4).** Anyone can fund the engine by sending it ETH. Each `finalize()` credits its caller at most `rewardPerPeriod`, which the caller claims later. When the pool is empty, the reward is zero and finalization works exactly as before. A period nobody finalizes has no record, so a consumer sees "not published", never a price.

## Where the contracts differ from engine.py

Only the last row can change a result, and only from one non-price status to another. All of them are tested.

| Contract | engine.py | Why |
|---|---|---|
| An observation of a series the methodology does not list is refused (`UnknownSeries`) | Ignored | Same effect, without storing it |
| Markets and corroborator keys must be given in ascending order | Sorted by the engine | Makes the market index canonical. Order is not part of the methodology hash. |
| Weights < 2⁶⁴, at most 64 markets and 128 series, bands and breaker ≤ 10⁶ bp, lag ≤ 36,500 days, first period ≥ 1970-01, unbonding delay ≤ 10 years | Unbounded | Keeps every product below 2²⁵⁶ and every timestamp unsigned |
| At most 16 observations per series and period | Unbounded | Bounds the gas of one `finalize()`. Each extra observation already needs *k* notaries. |
| Band and closeness tests compare 512-bit products | Unbounded integers | Python's products can pass 2²⁵⁶ at large index levels. Both give the exact answer. |
| `published` must not be later than the submission | No clock | The contract has a clock, and a future publication is a notary fault |
| An observation can be submitted only once its period has begun | No clock | Attesting a period that has not begun is a notary fault. The observation can still be submitted from the period's start, and its result depends on `published`, not on when it was submitted, so nothing changes. The replay submits `published_early` at its period's start. |
| An observation can be submitted only until its period closes, 3 days after the freshness window | A late observation makes its market STALE | A window must close for the period to be computed at all. So a market whose only observation arrives after the close is ABSENT on-chain, where engine.py says STALE. The period is non-valid either way, but its status can differ (STALE against INSUFFICIENT_COVERAGE or UNAVAILABLE). No vector has such an observation. |

## Threat model (§14)

| Threat | Defense here | Test |
|---|---|---|
| Fabricated quotation | *k* of *n* listed notaries must sign | `test_SybilCollectorsCountForNothing`, `test_OneNotaryIsNotEnough` |
| Multiple fake collectors | Only listed, bonded notaries count; submitters carry no weight | `test_SybilCollectorsCountForNothing`, `test_TheSameNotaryTwiceIsOneNotary` |
| Stale-price replay | EIP-712 domain per deployment and chain; windows; freshness | `test_AnAttestationCannotBeReplayedOnAnotherDeployment`, `test_APeriodClosesAfterTheLagAndTheChallengeWindow`, vector `stale` |
| Duplicate source reporting | One commitment, one observation | `test_ADuplicateIsRefused`, vector `disputed_and_duplicate` |
| Extreme false quotation | The engine's bands and quarantine | `test_AColludingQuorumAloneIsStillHeldByTheAnomalyRules`, vector `spike_rejected` |
| Colluding attestors | A counter-attestation makes the market DISPUTED; equivocation is slashed | `test_AColludingQuorumAgainstAnHonestOneMakesTheMarketMissing`, `test_EquivocationIsSlashed` |
| Contract arithmetic exploit | Exact integer port; 512-bit comparisons; bounded inputs | `GCPIMathTest`, all vectors |
| Malicious transaction ordering | Order-independent collection; a fixed window per period | `testFuzz_SubmissionOrderDoesNotMatter` |
| Keeper outage | Permissionless `finalize()`; nothing is published until it runs | `test_AKeeperOutagePublishesNothingThenTheSameRecords`, `test_AnEmptyPoolPaysNothingAndFinalizationStillWorks` |
| Missing regional market, collector outage | Coverage rule; an explicit non-price status | `test_ACollectorOutageIsUnavailableNotAPrice`, vectors `missing_market`, `missing_all` |
| Privileged override | No owner, setter or upgrade | `test_TrustAssumption_NoContractHasAPrivilegedFunction` |

Not covered by the contracts:
- **Compromised source website and manipulated FX** rest on §7 corroboration and on the notaries. FX is still an input, not a rule (ENGINE limitations).
- **Data archive loss** is addressed by the `ObservationSubmitted` event, which carries every field of every accepted observation. Anyone can rebuild the inputs from chain history.

## Cost

Measured by `test_GasOfAV1Finalization`, v1 methodology (two markets and coconut oil), one observation per series:

| Call | Gas |
|---|---|
| `submit`, 2-of-3 attestation | about 438,000 |
| `finalize`, one period | about 689,000 |

That is about 2 million gas per monthly period with one observation per series. On Base at 0.01 gwei that is about 0.00002 ETH. Most of the submission cost is storing the observation's strings, which keeps every field readable on-chain.

## Found along the way

- **The two reference engines disagreed on some inputs.** Python's `$` matches before a final newline, JavaScript's does not. So `"PH\n"`, `"2020-01\n"` and `"100\n"` passed `engine.py` and produced output, while `engine.cjs` rejected them. `engine.py` now anchors with `\Z`, and both suites test it. No vector changed.
- **No vector exercised a tie, or disabled bands.** Flipping the tie rule ("a tie goes to the reference", ENGINE §5) changed no vector's output in any of the three implementations. Two vectors were added:
  - `closer_tie`, a pending value and the reference relatively equidistant from the next one.
  - `bands_disabled`, the Phase 2 research rules.

  A third, `long_pending`, crosses the on-chain cap on work per call. All three pass in Python, JavaScript and Solidity, which brings the count to 27.

## What remains of #92

These are not in this change. Each needs people or decisions, not just code:

1. **Collectors and notaries.** #92 asks for at least two independently operated collectors and for adversarial runs with them. What is needed:
   - A notary service that signs the commitment after a TLSNotary session.
   - A collector that builds observations and gathers *k* signatures.

   The contract side of both is done, and a reference implementation of both now exists ([COLLECTORS](COLLECTORS.md)): notaries that sign only what they retrieved themselves, a collector, and a CDB adapter. Nobody operates either yet. The CDB adapter has been run against the live site, and the collector and three notaries on anvil reach quorum from live retrievals (COLLECTORS, "Against the live site").
2. ***n*, *k*, the notary operators and the bond sizes** (§5.3.6, §5.4: "set in Phase 4"). The deploy script's defaults are placeholders: 0.0001 ETH per submission, 0.01 ETH per notary, a 30-day unbonding delay and no reward.
3. **A Base Sepolia deployment.** `DeployGCPI` refuses Base mainnet (#93 comes first). It also refuses a methodology whose base period has closed, and the v1 draft's 2016-02 base is such a placeholder (ENGINE choice 8). The testnet methodology [`gcpi-1-draft.1-in-testnet.json`](engine/methodology/gcpi-1-draft.1-in-testnet.json) is the India sub-index with base 2026-09 ([ENGINE](ENGINE.md#1-inputs)). It deploys until 2027-01-02 (`test_DeploysTheTestnetSubIndexUntilItsBaseCloses`), and the anvil e2e runs on it.

   **Deployed 2026-10-19** ([`deployments/base-sepolia-gcpi.json`](../deployments/base-sepolia-gcpi.json)): verifier [`0x7F69…0224`](https://sepolia.basescan.org/address/0x7F697F7970124eDB2417746C665387B894330224), engine [`0x87c7…75F0`](https://sepolia.basescan.org/address/0x87c7D995670E671C00f42B544f2CDFfB988275F0), registry [`0xB79a…72A5`](https://sepolia.basescan.org/address/0xB79a2931931587D5cA6B036C8663D0b50b3c72A5). It has three notaries with *k* = 2, and bonds sized for testnet funds: 0.00001 ETH per submission, 0.0001 ETH per notary, one-day unbonding, no reward. **copra.dev runs all three notaries,** so this deployment shows the mechanics, not independence (item 1). Its first observation is IN 2026-09, Kochi milling copra at 16346.666666 Rs/quintal and 95.4712 INR/USD. Each notary retrieved that value live from CDB and the ECB, all three attested, and it was submitted in [`0x2dab…6157`](https://sepolia.basescan.org/tx/0x2dab7cf821554e6808bad9389c47febda8ce6bd7f746c2cca95e1c7f93066157). Its source record is [`records/base-sepolia/3172…f052.json`](records/base-sepolia/3172036d2203034bb13b91589360ab42c90b4a1ad794899ac1d4240f459df052.json). 2026-09 can be finalized once its window closes on 2027-01-02.
4. **An independent security review** (§16 Phase 5, §17).
5. **An economic analysis of the incentive pool:** how large, how much per period, and who funds it (§19 Q9).

## Reproducing

```
forge test --match-path 'test/gcpi/*'                    # contracts: vectors, adversarial, fuzz, deploy
python3 -m unittest discover -s test/gcpi                # engine.py, including the two new vectors
node --test test/gcpi/*.test.cjs                         # engine.cjs on every vector
python3 gcpi/engine/make_vectors.py                      # regenerates vectors/; no file may change
```
