# GCPI Collectors and Notaries: Reference Implementation

**Issue:** #92 · **Methodology:** [GCPI-001](../docs/specs/GCPI-001.md) §5.2–§5.4, §6.2, §14 · **Run:** 19 October 2026
**Builds on:** [contracts](CONTRACTS.md), [source authentication](AUTHENTICATION.md) (#89), [sources](SOURCES.md) (#87)
**Code:** [`collector/`](collector/) · **Tests:** [`test_collector.py`](../test/gcpi/test_collector.py), [`test_collector_e2e.py`](../test/gcpi/test_collector_e2e.py) · **Reproduce:** [below](#reproducing)

---

## Result

The contract side of item 1 in [what remains of #92](CONTRACTS.md#what-remains-of-92) now has software on the other end:

- **A notary service** ([`notary.py`](collector/notary.py)) retrieves the source itself, checks the observation it is asked to attest, and signs the commitment.
- **A collector** ([`collect.py`](collector/collect.py)) builds an observation, keeps its source record, gathers *k* signatures and submits them.
- **The first source adapter** ([`sources.py`](collector/sources.py)) is CDB's monthly average for Kochi milling copra (`cdb-market-price`), with FX from the ECB.

On anvil, the verifier accepts the collector's observation with 2 of 3 notaries. The notaries sign EIP-712 typed data built locally, and the contract recovers them from its own digest. When the publisher revises a value, every notary reproduces the new value and none of them signs it.

**What this is not:** independently operated. Two or more operators running this code, or their own, is still the people part of #92.

**Against the live site** (2026-10-19). `collect.py observe --period 2026-09` reads Kochi milling copra as `16346.666666` Rs/quintal, the only `Milling Copra | September` row under the report's `Product | Date | Kochi` header, with 95.4712 INR/USD from 21 ECB days. Two retrievals give the same observation apart from `published`. 2026-08, 2026-01, 2025-06 and 2024-12 parse too. With live retrievals in place of the fixtures, the e2e flow submits: three notaries each fetch CDB and the ECB themselves, all reproduce the collector's observation, and the verifier on anvil accepts it with two signatures. CDB publishes a monthly average with as many decimals as it computed (`16346.666666`, six here), and the adapter takes those bytes exactly. To repeat it: `GCPI_LIVE=1 python3 -m unittest discover -s test/gcpi -p test_collector_e2e.py`.

## How a notary attests

**Model: own retrieval.** A notary signs only after fetching the listed source itself, over TLS to the publisher's host, running the pinned adapter, and getting exactly the observation it was sent, every field except `published`. Its signature says: "I fetched this from the listed source and it served this value".

How this relates to §5.3.1, which says notaries attest "through TLS attestation with selective disclosure":
- **The notary is the TLS client,** so it knows the value first hand. The trust is TLSNotary proxy mode's (§5.3.6 #2): fewer than *k* notaries collude, and no network attacker sits between a notary and the publisher.
- **It works where TLSNotary cannot.** TLSNotary is TLS 1.2 only, and PSA serves TLS 1.3 only ([AUTHENTICATION](AUTHENTICATION.md#what-each-source-offers-an-attestation)).
- **It leaves nothing a third party can check** beyond the signature. Neither does a TLSNotary notary's signature, which is all a contract verifies.
- **The contracts do not change.** They check signatures, not sessions ([CONTRACTS](CONTRACTS.md)). A TLSNotary backend can replace the retrieval step later.
- **A publisher that blocks data-centre addresses blocks notaries.** Collector and notaries then fail to reach quorum, and the market is missing for the period, never priced.

**A notary refuses** (HTTP 422, with a code) when:

| Code | Why |
|---|---|
| `malformed` | The engine's structural check fails (gcpi/ENGINE.md §1) |
| `not_served` | It runs no adapter for that source and market |
| `published_in_future` | `published` is later than its own clock |
| `published_too_old` | `published` is more than 24 hours before the request. `published` is the collector's first retrieval (§5.2), so the notary's must follow it closely. The retrieval it compares against is never later than the request, and at most 10 minutes earlier (see Exposure), so it is never more than 24 hours after `published` either. |
| `period_not_ended` | The month is not over, so a monthly average is still partial |
| `out_of_range` | The period is before the verifier's first |
| `window_closed` | The verifier no longer accepts the period: it closed `CHALLENGE_WINDOW` (3 days) after the freshness window |
| `chain_clock_behind` | The chain's clock has not passed both the period's start and `published`. Signing now could be slashed as premature ([CONTRACTS](CONTRACTS.md)). |
| `source` | Its own retrieval failed or the adapter did not recognise the response |
| `mismatch` | Its retrieval gave a different observation; the fields are listed |
| `unusable` | The engine would make the observation INVALID |
| `would_equivocate` | It already signed a different normalized price or basis for this market, source and period |

**Never equivocating.** Equivocation is the slashable fault a revision would cause (§5.4). A notary therefore logs every signature's market, source, period, normalized price and basis, and refuses a conflicting one. The log is a JSON-lines file, written and `fsync`ed (with its directory, when the write creates it) before the signature is made, and read back at start. Losing it loses that protection, so it belongs on durable storage. Signing the same value again, retrieved later, is not a conflict.

**What is signed is built locally.** The EIP-712 typed data comes from the chain id and verifier address the notary was started with, not from an RPC call to `attestationDigest`. A node that lied about the digest could otherwise make a notary sign a commitment it never checked. At start, the notary checks that the RPC serves the configured chain.

**Exposure.** `/attest` takes no credentials, by design: anyone may run a collector, so anyone may ask. What a request can cost is bounded instead (#112). A notary attests only the few periods the verifier still accepts, and reuses its own retrieval of a market and period for 10 minutes (`RETRIEVAL_TTL`), failures included, with concurrent requests sharing one retrieval. So the publisher and the ECB see at most one retrieval per open period every 10 minutes, however many requests arrive and from however many addresses. A revision inside those 10 minutes is a `mismatch`, never a signature for both values. A proxy in front still limits the requests themselves, each of which costs an RPC call. It listens on `127.0.0.1:8645` unless `--listen HOST:PORT` (an IPv6 host in brackets) says otherwise.

## How a collector submits

1. **Observe** an ended month, stamping `published` with the time of this retrieval (§5.2: the first attested retrieval, never an HTTP header).
2. **Keep the record** (§5.2 step 8): `--out DIR` writes `<commitment>.json`, holding the observation and the source record its `record` field hashes.
3. **Wait** until the chain's clock passes `published` and the period's start.
4. **Ask each notary** to attest. A signature counts only if it recovers its claimed signer for this commitment and that signer `counts()` on-chain now. Refusals and bad answers are skipped and reported.
5. **Submit** the *k* lowest signers, in the ascending order `submit()` requires, with `submitBond`. The call is simulated first, so a revert costs nothing. Fewer than *k* usable attestations, or any failure, means nothing is sent.

`refund` returns the submit bond once the period has closed.

## The CDB adapter and the FX rule

**Source record.** The record covers the value's bytes and their position, not the whole page (§5.2). It is the SHA-256 of canonical JSON (the engine's encoding) holding:
- the form query: product, market, monthly report, year, month;
- the row and column labels, and the value's text exactly as served (`"13456.78"`);
- the ECB days used for FX.

CDB's page carries ASP.NET view state that changes on every request, so retrievals agree on the record but not on the page.

**Parsing.** The form is driven as [`cdb_copra.py`](research/cdb_copra.py) drives it, asking for one month. The adapter takes the one cell that follows "Milling Copra" and the month's name. No such cell, two of them, or a value that is not a plain decimal is a failure, never a guess. The value becomes engine integers exactly: `3525.00` is price 352500, exponent 2.

| Field | Value |
|---|---|
| `market` | `IN` (the India sub-index; a deployment's methodology must list it, as the [testnet one](engine/methodology/gcpi-1-draft.1-in-testnet.json) does) |
| `source`, `basis` | `cdb-market-price`, `kochi` |
| `currency`, `unit` | `INR`, `quintal` |
| `fx`, `fx_exp`, `fx_source` | ECB monthly mean, 4 decimals, `ecb-monthly-mean` |

**FX: `ecb-monthly-mean`, a provisional input to §6.2,** which does not yet fix an FX rule:
- the mean, over the ECB's reference days in the month, of (INR per EUR) / (USD per EUR);
- computed exactly and rounded half up to 4 decimals;
- read from the ECB's full history file, which does not change for past days;
- at least 10 reference days in the month, or the observation is refused; a day the ECB marks `N/A` is left out.

This is the backtest's FX ([`load.py`](backtest/load.py) `load_fx`) made exact. Choosing it, or another rule, belongs in a methodology version.

## Running one

Both read their signer from the environment: `NOTARY_KEY` or `NOTARY_KEYSTORE` for a notary, `COLLECTOR_KEY` or `COLLECTOR_KEYSTORE` for a collector, never both. A keystore needs `NOTARY_PASSWORD_FILE` or `COLLECTOR_PASSWORD_FILE` too, the file holding its password. Not `ETH_PASSWORD`: cast reads that as a password file for every command, and then refuses even a `cast call`.

```
# a notary: bond once, then serve
cast send $VERIFIER "bond()" --value $NOTARY_BOND --private-key $NOTARY_KEY --rpc-url $RPC
python3 gcpi/collector/notary.py --rpc-url $RPC --verifier $VERIFIER --chain-id 84532 --log /var/lib/gcpi/notary.jsonl

# a collector
python3 gcpi/collector/collect.py observe --period 2026-09 --out records/          # no chain, no signer
python3 gcpi/collector/collect.py submit --period 2026-09 --notary https://n1.example https://n2.example \
    --rpc-url $RPC --verifier $VERIFIER --chain-id 84532 --out records/ [--dry-run]
```

Python 3 standard library and Foundry's `cast`, nothing else.

## What remains

1. **Independent operators** for at least two collectors and *k* notaries, and their adversarial runs (#92). That is item 2 of [what remains of #92](CONTRACTS.md#what-remains-of-92) too: *n*, *k* and who the operators are.
2. **Adapters for the headline markets.** PSA is withdrawn until it explains its 2024 break, and Indonesia has no accepted source ([SOURCES](SOURCES.md)).
3. **The §6.2 FX rule,** decided in a methodology version, whether it is `ecb-monthly-mean` or another.
4. **A TLSNotary backend,** once it supports TLS 1.3 and leaves alpha.

## Reproducing

```
python3 -m unittest discover -s test/gcpi -p 'test_collector*.py'   # parsers, refusals, collector; e2e needs anvil
```
