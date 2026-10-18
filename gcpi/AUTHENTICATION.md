# GCPI Source Authentication: Optimistic Oracle vs zkTLS vs Signed Feeds

**Issue:** #89 · **Methodology:** [GCPI-001](../docs/specs/GCPI-001.md) §5.3, §5.4, §11.1, §19 Q7 · **Checked:** 18 October 2026
**Builds on:** [Phase 1 sources](SOURCES.md) (#87), [Phase 2 backtest](BACKTEST.md) (#88) · **Feeds:** #90 (spec decisions), #92 (contracts and collectors)
**Evidence:** [`tls_probe.py`](research/tls_probe.py) → [`tls_probe.json`](research/tls_probe.json) · [`base_attestors.py`](research/base_attestors.py) → [`base_attestors.json`](research/base_attestors.json) · **Reproduce:** [below](#reproducing)

---

## Answer to Q7

**No mechanism available today authenticates GCPI's sources without trusting some party beyond the publisher.** That follows from how HTTPS works, not from any product. TLS authenticates the server to the client that connected. It gives that client nothing it can show anyone else: the session keys are symmetric, so a client can produce any "transcript" it likes. A third party can only be convinced in two ways. Either the publisher signs its data, or another party took part in the session (a notary, a proxy, a TEE) and vouches for it. Every zkTLS design is the second kind.

So Q7's real question is which parties GCPI trusts, how many, who chooses them, and what happens when they lie. The recommendation answers each.

## Recommendation

For #90 to decide.

| Layer | Recommendation | Trust that remains |
|---|---|---|
| **Signed feeds** | **Ask PSA, CDB and CDA to sign their releases.** Only this removes the third party. Verify signatures on-chain wherever a publisher agrees. | The publisher's key. Its number can still be wrong (PSA's 2024 break, [BACKTEST.md](BACKTEST.md#data-quality-findings)). |
| **Attested retrieval** | **k-of-n TLS attestations from notaries listed in the methodology version**, run by independent operators. Notaries are added or removed only by a new methodology version (§13, #90). No contract owner, vendor or key can change the list. | Fewer than k notaries collude with a submitter. Plus the Web PKI and, for PSA and ICC, Cloudflare (below). |
| **Disputes** | **By counter-evidence, never by vote.** If two valid attestation sets for the same source and period disagree, the market is missing for that period (§8.4) and the conflict is recorded. No arbiter decides which is right. | Griefing can force a market to missing, but only with a valid conflicting attestation, which needs k notaries. |
| **Stake** | **A bond against spam, returned at finalization. Slashing only for objective, on-chain-provable faults**: a notary signing two different values for the same source and period. Stake never weighs on the price. | Matches §5.4. |
| **PDF and XLSX sources** | Attest the transcript, commit to the file's hash, and extract the value with a **parser pinned in the methodology version**. Anyone can rerun it on the attested bytes. A disputed parse is a conflict, handled as above. | The pinned parser is correct. That is checkable by anyone, but not proven on-chain. |
| **Plausibility** | Unchanged: §7 history checks and §7.5 corroboration. Authentication proves *what was published*, not that it is economically right. | — |

Two things are **not recommended**:
- **UMA's DVM as the arbiter.** A token-holder vote is the "majority stake determines the price" §5.4 forbids. The one disputed price that matters would be settled by an external governance body.
- **Reclaim or Primus as deployed on Base.** Each verifier is an upgradeable proxy controlled by one key. Reclaim's accepts a single witness's signature. That is a privileged oracle committee of one.

**The latency fits the cadence.** A monthly index published about 59 days after month end ([BACKTEST.md §2](BACKTEST.md#2-publication-delays-and-missing-data)) can absorb a fixed challenge window. Recommend 3 days per period for #90, about 5% added to the finalization delay.

**Failure always produces a non-valid status.** No attestation, a conflict, a missing notary quorum or an expired window each make the market missing for the period. §8.3 coverage then decides whether the index is valid. Nothing produces a default value.

---

## What each source offers an attestation

Probed on 18 October 2026 with [`tls_probe.py`](research/tls_probe.py): TLS 1.2 and 1.3 handshakes, two uncompressed fetches a second apart, and response headers.

| Source (role) | TLS 1.2 | TLS 1.3 | Served by | Response | Same bytes twice | Attestation |
|---|---|---|---|---|---|---|
| PSA OpenSTAT, national query (headline candidate) | **no** | yes | Cloudflare | JSON, 24 KB | yes | **TLS 1.3 only: TLSNotary cannot attest it today** |
| CDB price report (sub-index) | yes | **no** | IIS | HTML form, 22 KB (results need two ASP.NET postbacks) | yes | TLS 1.2 attestable; value located by byte range |
| CDA bulletin page (sub-index) | yes | yes | Apache | HTML, 96 KB, links daily PDFs | **no**: 1 line, a CSRF token | Commit to the value's bytes, not the page |
| ICC monthly PDF (history only) | yes | yes | Cloudflare | PDF, 264 KB | yes | Transcript yes; value by pinned parser |
| AGMARKNET API (corroboration) | yes | yes | — | `400 Authorization field missing` | — | Needs an API key, redacted from the attestation; content not measured |
| PCA (rejected) | yes | yes | Cloudflare | `403` "Just a moment…" challenge | — | **None** |
| World Bank CMO (corroboration) | yes | yes | Apache | XLSX, 586 KB | yes | Transcript yes; value by pinned parser |
| ECB reference rates (§6.2 FX) | yes | yes | Myra | XML, 1.5 KB | yes | **Best case: small, structured, stable** |

What this changes:
- **Phase 1 named PSA "the realistic first target for TLS attestation".** That was premature: OpenSTAT refuses TLS 1.2, and TLSNotary implements only TLS 1.2 ([tlsn #859, "Support TLS 1.3"](https://github.com/tlsnotary/tlsn/issues/859), open). Reclaim and Primus state TLS 1.3 support, but that was not tested here, and their Base deployments are rejected above. **No mechanism recommended here can attest PSA today.** PSA is also withdrawn as an input until it explains its 2024 break (#88).
- **The cleanest target is FX, not copra.** The ECB's daily XML is 1.5 KB, structured, byte-stable, TLS 1.2 and 1.3. §14's "manipulated FX rate" threat is the easiest to close.
- **Cloudflare is in the trust path for PSA and ICC.** TLS ends at Cloudflare's edge, so an attestation proves what Cloudflare served under the publisher's certificate, not what the publisher's origin holds. That is acceptable, but it is a trust assumption, and it is stated below.
- **`Last-Modified` is not a publication time.** ICC's September 2026 PDF reports `Last-Modified: 18 Oct 2026 13:27 GMT`, the day of the probe. §5.2's publication timestamp must come from the content, or from the first attested retrieval, not from HTTP headers.
- **Whole-response hashes don't work everywhere.** CDA's page changes on every request (a Joomla CSRF token), so collectors reading it agree on the price but not on the hash. §5.2 step 6's commitment should cover the value's bytes and their position in the response. Selective disclosure in TLS attestation does exactly that.

---

## The options

### 1. Publisher-signed feeds

The only option with no third party. A publisher signs each release, and GCPI verifies the signature on-chain against a key fixed in the methodology version. An `ecrecover` costs 3,000 gas, so verification is negligible.

- **Trust:** the publisher's key and the publisher's number. Authenticity is not correctness. PSA would sign its post-2024 series as readily as its earlier one.
- **Cost per period:** negligible on-chain. The publisher has to do the work.
- **Latency:** none beyond the publisher's own.
- **Maturity:** none of GCPI's sources signs anything today (Phase 1, [SOURCES.md §5](SOURCES.md#5-authentication-input-to-89)). Standard formats exist, for example HTTP Message Signatures (RFC 9421) or a detached signature beside each file.
- **Failure:** no signature, or a bad one, means the observation is not accepted, so the market is missing.

**Recommendation:** request it from PSA, CDB and CDA ([draft below](#appendix-request-to-publishers)). It was not sent: contacting publishers is the project's decision, not this report's.

### 2. Optimistic oracle (UMA OOv3 on Base)

Anyone asserts with a bond, anyone disputes within a liveness window, and disputes go to UMA's DVM, a token-holder vote. Read from Base mainnet at block 52,779,095 with [`base_attestors.py`](research/base_attestors.py):

| Parameter | Value |
|---|---|
| Contract | `0x2aBf1Bd76655de80eDB3086114315Eec75AF500c` ([UMA's Base deployment](https://github.com/UMAprotocol/protocol/blob/master/packages/core/networks/8453.json)) |
| Default liveness | 7,200 s (2 hours) |
| Minimum bond, USDC | 500 USDC (final fee 250 USDC) |
| Share of a losing bond burned | 50% |
| Owner | UMA `GovernorSpoke`, i.e. UMA governance on Ethereum |

- **Trust:** an undisputed assertion needs only one honest watcher. A disputed one is settled by UMA token holders, in a 24-hour commit and 24-hour reveal vote ([UMA docs](https://docs.uma.xyz/using-uma/voting-walkthrough)). In March 2025, a disputed Polymarket market of about $7 million resolved in a way Polymarket said was against expectations. One researcher reported that a single holder cast about 25% of the vote; others called it negligence rather than an attack ([The Block](https://www.theblock.co/post/348171/polymarket-says-governance-attack-by-uma-whale-to-hijack-a-bets-resolution-is-unprecedented)). Either way, the outcome turned on how the tokens voted. UMA has since let integrations restrict who may propose ([UMIP-189, managed proposers](https://blog.uma.xyz/articles/managed-proposers)), which is a whitelist.
- **Cost per period:** 500 USDC per assertion locked for the liveness window. A losing side loses its bond, with 50% burned. Gas on Base is small.
- **Latency:** 2 hours undisputed. About 2–4 days if disputed.
- **Maturity:** production on Base.
- **Failure:** an assertion that resolves false is not accepted, so the market is missing. A wrong DVM vote is accepted as true, and nothing in GCPI could catch it except §7.
- **What it does well:** the assert, bond and challenge pattern is right. OOv3 even lets an integrator replace the DVM: an [escalation manager](https://docs.uma.xyz/developers/optimistic-oracle-v3/escalation-managers) with `discardOracle` set makes a disputed assertion resolve false, which is the conflict rule recommended here. Used that way, though, UMA contributes only a bond escrow and a timer. It adds a dependency on contracts whose parameters UMA governance can change, so the same rule written into GCPI's own contracts is simpler.

**Recommendation:** adopt the pattern (bond, window, a dispute leads to missing). Do not adopt the DVM.

### 3. zkTLS and TLS attestation

A notary, proxy or TEE takes part in the TLS session and attests to what the server sent. Selective disclosure reveals only the needed bytes. The variants differ in who must be honest.

| Design | Who must be honest | State checked here |
|---|---|---|
| **TLSNotary, MPC-TLS** | The notary, not colluding with the prover. "No single party ever holds the full session keys" ([TLSNotary](https://tlsnotary.org/blog/2026/04/22/proxy-mode/)) | v0.1.0-alpha.15 (21 May 2026). "Should not be used in production" (README). **TLS 1.2 only.** No on-chain verifier: a notary's signature is what a contract would check. |
| **TLSNotary, proxy mode** | The notary, plus no DNS or BGP attacker between the notary and the server. The server sees the notary's IP and may block data-centre ranges. | Added in alpha.15. TLS 1.2 PRF. No published benchmarks yet. |
| **Reclaim** (proxy witness) | The witnesses. The design samples several; the [2026 paper](https://eprint.iacr.org/2026/2187) analyses it with two attestors in TEEs. | **On Base: 1 witness, 1 signature required, verifier upgradeable by a single key** (below). |
| **Primus** (MPC / TEE attestors) | The attestors (Phala TEE nodes) | Attestors join by whitelist: "you must first contact the primuslabs team" ([docs](https://docs.primuslabs.xyz/primus-network/attestor-node-guides/)). **On Base: upgradeable proxies owned by a single key.** |

Read from Base mainnet with [`base_attestors.py`](research/base_attestors.py):

| Contract | Owner | Upgradeable | Witnesses / signatures required |
|---|---|---|---|
| Reclaim `0xACE0…128d` | `0xc157…06d5`, single key | yes (UUPS) | 1 / 1 (`reclaim-node.questbook.app`) |
| Reclaim `0x15d2…D042` | same key | yes (UUPS) | 1 / 1 |
| Primus task `0x151c…9707` | `0xeF47…c021`, single key | yes (ERC-1967) | — |
| Primus node `0x9C1b…7642` | same key | yes (ERC-1967) | — |

In Reclaim's verifier, `addNewEpoch`, which sets the witness list and quorum, and `_authorizeUpgrade` are both `onlyOwner` ([source](https://github.com/reclaimprotocol/reclaim-solidity-sdk/blob/main/contracts/Reclaim.sol)). Whoever holds that key decides which signatures count as truth. That is exactly what §10.2 excludes ("privileged source replacement", "arbitrary upgrade functions").

- **Cost per period:** off-chain, one attested session per collector per source. On-chain, k signature checks (3,000 gas each) and a commitment per observation.
- **Latency:** seconds to minutes at retrieval (Reclaim reports 7.28 s for a 1,200 kB response on a phone). That is negligible next to a monthly cadence.
- **Failure:** no quorum means the observation is not accepted, so the market is missing.

**Recommendation:** use TLS attestation as the retrieval layer, but with GCPI's own notary list, k-of-n, fixed per methodology version and verified by GCPI's own immutable contract. A vendor's attestor key can be one of the n notaries if its operator is independent. A vendor's upgradeable verifier contract can never be the gate. TLSNotary's model (MPC-TLS, notary signature only) fits best, once it supports TLS 1.3 and leaves alpha. Until then, Phase 4 (#92) runs it on testnet, which is what Phase 4 is for.

### 4. Bonded collectors with slashing

Collectors post stake, and fraud is slashed.

- **Where it works:** the fault is objective and provable on-chain. Examples are one key signing two different values for the same source and period (equivocation), a signature on a period that hasn't happened, or a malformed observation. Slashing for these needs no judgment.
- **Where it fails §5.4:** "is this price false?" is not objectively provable on-chain. Answering it with stake means a vote by stake. Slashing for it also needs an arbiter, which brings back option 2's DVM problem.
- **Cost:** capital lockup only.

**Recommendation:** a small anti-spam bond for submitters, returned at finalization. A larger bond for notaries, slashable only for equivocation. Stake never counts toward accepting a value.

---

## Proposed text for GCPI-001 §5.3

For #90 to adopt. It states the remaining trust assumptions explicitly, as the issue asks.

> **5.3.1 Mechanism (v1).** An observation is accepted when at least *k* of the *n* notaries listed in the methodology version attest, through TLS attestation with selective disclosure, to the same value bytes from the listed source location. A publisher signature against a key listed in the methodology version substitutes for notary attestations. The notary list, *k*, the source locations, the publisher keys and the parsers for non-structured formats are part of the methodology version. No contract owner or other key can change them.
>
> **5.3.2 Disputes.** Within the challenge window, anyone may submit a second valid attestation set for the same source and period. If the two disagree, the market is missing for that period (§8.4) and the conflict is recorded. No vote decides between them.
>
> **5.3.3 Remaining trust assumptions.** GCPI v1 assumes that:
> 1. **Publishers** publish what they mean to. Authentication does not detect a wrong publication; §7 must.
> 2. **Fewer than *k* listed notaries collude** with a submitter. For proxy-mode attestation, also that no network-level attacker sits between a notary and the publisher.
> 3. **The Web PKI** issued the publisher's certificate correctly. A mis-issued certificate would let attestations of a fake server pass.
> 4. **The publisher's CDN** (Cloudflare for PSA and ICC on 18 October 2026) serves the publisher's content. TLS ends at the CDN.
> 5. **The pinned parser** for PDF and XLSX sources is correct. Anyone can check this by rerunning it on the attested bytes.
> 6. **At least one honest submitter** brings each market's observation each period. Otherwise the market is missing.
> 7. **Methodology governance** (#90) changes the notary list, the sources and the keys only through a new version.

---

## Reproducing

```bash
python3 gcpi/research/tls_probe.py gcpi/research/tls_probe.json            # two requests per endpoint
python3 gcpi/research/base_attestors.py https://mainnet.base.org gcpi/research/base_attestors.json
```

Both scripts are stdlib Python. `base_attestors.py` reads only public chain state and accepts any Base RPC. `test/gcpi/test_authentication.py` pins the probe's verdicts and the ABI decoding, including one epoch response captured from Base.

## Limits

- **Reclaim's and Primus's TLS 1.3 support and proof sizes were not tested.** Only their deployed contracts on Base were read.
- **TLSNotary was not run against any source.** Running collectors is Phase 4 (#92). The probe measures what such a run would need.
- **CDB's results page** needs two ASP.NET postbacks. Only the form was probed; the results come from the same server.
- **The publisher request is a draft.** No publisher was contacted.

---

## Appendix: request to publishers

A draft for PSA, CDB and CDA. It was not sent.

> GCPI is an open, reproducible copra price index. We use your published [series] as a primary input and cite it as the source. To let anyone verify that a price really came from you, we would ask you to publish, beside each release, a digital signature over the released data, made with a key you publish once (for example on your website and in your annual report). Any standard scheme works (an Ed25519 or ECDSA signature file, or HTTP Message Signatures, RFC 9421). It costs a few lines in your publishing process and requires no change to the data itself. We would also welcome written confirmation of the terms under which the series may be republished.
