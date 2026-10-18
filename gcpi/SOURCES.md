# GCPI Phase 1: Source Research Report

**Issue:** #87 · **Methodology:** [GCPI-001](../docs/specs/GCPI-001.md) §16 Phase 1 · **Checked:** 18 October 2026
**Registry:** [`sources.json`](sources.json) (16 entries, including every rejected candidate with its reason)
**Reproduce:** [`research/`](research/) (stdlib Python; see [Reproducing these numbers](#reproducing-these-numbers))

---

## Verdict

**A global copra index is not yet defensible. A narrower one is.**

1. **No public export-basis copra price exists.** The World Bank dropped copra from its commodity data. ICC publishes only domestic copra prices. CIF Rotterdam quotations come from Oil World, which is subscription-only. Nothing published is an FOB or CIF copra price that GCPI could read and redistribute.
2. **The four core markets are two markets.** On ten years of ICC weekly data, the Philippines and Indonesia move together (r = +0.79 for monthly changes). India and Sri Lanka move with neither of them (r between −0.14 and −0.04), and trade 35–85% higher. An average across all four mixes an export-linked price with two protected domestic prices.
3. **Only the Philippines has a primary, open, machine-readable copra series with long history:** PSA's monthly farmgate Resecada price, 2010 onwards, about two months late. Indonesia has no primary public source at all.
4. **No publisher offers a signed or machine-readable feed.** The options are an API (PSA), a postback form (CDB), daily PDFs (CDA) and a Cloudflare-blocked site (PCA). Authentication (#89) starts from HTTPS and PDFs.

**Recommended for #90 to decide:** a headline index on the export-linked basis, anchored on the Philippines (PSA), with India (CDB) and Sri Lanka (CDA) as published per-country sub-indices that do not enter the headline. Its cadence is **monthly** unless a weekly primary source for the Philippines or Indonesia is obtained. A weekly or "global" headline is not supported by the sources that exist today.

---

## What exists

| Market | Primary source | Cadence | History | Grade and basis | Licence | Role |
|---|---|---|---|---|---|---|
| Philippines | PSA OpenSTAT | Monthly, ~2 months late | 2010-01 → 2026-06, no gaps | Resecada and Corriente, farmgate, PHP/kg | Not stated | **Headline candidate** |
| Philippines | PCA | Daily (press reports) | Unknown | Farmgate and millgate | None found | Rejected: blocked, nothing published |
| Indonesia | None found | | | | | ICC survey only |
| India | CDB | Daily, monthly | 2008-01 → 2026-10 | Milling copra, wholesale, Rs/quintal | Not stated | **Sub-index candidate** |
| India | AGMARKNET (data.gov.in) | Daily | API serves today only | Per-mandi variety, min/max/modal + arrivals | GODL-India (open) | Corroboration |
| Sri Lanka | CDA daily bulletin | Daily (business days) | 2026 only linked | Unspecified grade, wholesale, Rs/250 kg, traded/nominal flag | Not stated | **Sub-index candidate** |
| PNG, Solomon Is., Vanuatu | KIK, CEMA/CBSI, VBOS | Quarterly | Varies | Depot prices or export unit values | Not stated | Rejected for v1; expansion |
| Multi-country | ICC Weekly Price Update | Weekly | 2016-01 → 2026-10, all 130 months | Domestic, converted to US$/MT by ICC | All rights reserved | History only |
| Global | World Bank CMO monthly | Monthly | 1960 → 2026-09 | **Coconut oil only**, CFR Europe | Unconfirmed | Corroboration |
| Global | FAOSTAT QCL | Annual | 1961 → 2023/2024 | Coconut oil and coconuts, **no copra item** | CC BY 4.0 | Weights (with conversion) |
| Global | Oil World | Weekly | | Copra and oil, CIF Rotterdam | Subscription | Rejected: not redistributable |
| Exchanges | None | | | | | No copra futures found |

---

## Findings

### 1. There is no public export price to anchor to

- **World Bank:** the 2016 monthly file had a copra column. The 2025 and 2026 files have only coconut oil, and its basis changed four times: c.i.f. Rotterdam, then CIF NW Europe (1999–2020), crude CIF Rotterdam (2021–2024), then CFR Europe (from January 2025). ([`worldbank_cmo.py`](research/worldbank_cmo.py))
- **ICC:** in all 130 monthly reports from 2016-01 to 2026-10 there is no FOB, CIF or Europe copra line. Every copra quote is domestic. ([`icc_archive.py`](research/icc_archive.py))
- **Oil World:** the Sri Lanka CDA bulletin credits its CIF Rotterdam coconut oil quote to Oil World, a subscription service. A paid, non-redistributable price cannot be an input to an index that third parties must be able to reproduce (GCPI-001 §12.3).
- **Exchanges:** no active copra futures contract was found.

This settles part of GCPI-001 §19 Q1 by elimination. The reference basis must be **domestic**. A delivery-basis normalization to FOB (§2.3) would need an export price that is not publicly available.

### 2. The core markets split into two regimes

Monthly log changes of ICC's weekly copra prices, 2016-01 to 2026-10, in US$:

| | Indonesia | Philippines | Sri Lanka |
|---|---|---|---|
| **India** | −0.14 | −0.01 | +0.33 |
| **Indonesia** | | **+0.79** | −0.00 |
| **Philippines** | | | −0.04 |

Mean level, 2025-09 to 2026-10 (US$/t): Philippines 1,094 · Indonesia 1,031 · Sri Lanka 1,474 · India 1,884.

The Philippines and Indonesia export most of their copra as coconut oil and price off world demand. India and Sri Lanka price off domestic demand, and India sets a minimum support price for milling copra. (The explanation is context, not measured here; the correlation and levels are measured.)

Consequences:
- A production-weighted average of all four (GCPI-001 §4) would be dominated by the Philippines and Indonesia, and its India and Sri Lanka components would add noise unrelated to the export market.
- GCPI-001 §7.5's corroboration example assumes the four markets move together. They do not, so cross-market anomaly checks across all four would raise false positives. Corroboration should compare the Philippines with Indonesia, and use coconut oil as the export-market signal.
- Caveat: these are US$ series converted by ICC at an undisclosed rate, so currency moves are mixed in. Phase 2 (#88) should repeat this in local currency from primary sources.

### 3. Source by source

**Philippines, PSA** (`psa-farmgate-copra`). Monthly national and provincial farmgate prices for Copra Resecada (dried, milling) and Copra Corriente, from a public JSON API with no key. History runs 2010-01 to 2026-06 with no gaps. Data quality flag: Corriente, the wetter and cheaper grade, is priced above Resecada in 15 months, all in 2024–2026 and none in 2010–2023. That points to a sampling or definition change that Phase 2 must explain before the series is used. ([`psa_copra.py`](research/psa_copra.py))

**Philippines, PCA** (`pca-price-monitoring`). Press reports cite PCA daily farmgate and millgate monitoring, but the site serves a Cloudflare challenge to every non-browser client and publishes no price page or file. In July 2026 PCA also sought powers to influence copra prices. A publisher that intervenes in the market it reports is a conflict GCPI should disclose if PCA ever becomes a source.

**Indonesia** (`indonesia-primary`). No primary public copra price was found. ICC's Indonesian series is its own stakeholder survey, renamed twice (North Sulawesi → Domestic → Industry Use). BPS publishes annual rural producer prices for smallholder estate crops, but whether copra is in its tables is unconfirmed. That is Phase 2 work.

**India, CDB** (`cdb-market-price`). Milling copra prices in Rs/quintal for Kochi, Alappuzha and Kozhikode from 2008 (Kangayam from 2012), through a postback form with daily-to-annual views. Trap: the daily view fills every calendar day, Sundays included, and 50 of 61 Kochi values in August–September 2026 equal the previous day. A daily value therefore does not show that anything traded that day. Freshness (GCPI-001 §8.2) has to come from elsewhere, or the series must be used weekly or monthly. There is a stated gap from 23 March to 31 May 2020 (COVID lockdown). ([`cdb_copra.py`](research/cdb_copra.py))

**India, AGMARKNET** (`agmarknet`). Daily mandi min/max/modal prices with arrival volumes, under an open licence. The data.gov.in API serves only the current day, and copra appears only in some Kerala mandis. Copra history and grade consistency are unmeasured, so it is a corroboration source until Phase 2 measures it.

**Sri Lanka, CDA** (`cda-daily-bulletin`). A daily bulletin of copra prices in Rs/250 kg as a range, with a **T (traded) / N (nominal)** flag and the day's US$ rate. That flag is the freshness signal CDB lacks. Only the current year's bulletins are linked, and no older ones were found, so Sri Lanka's backtest depends on ICC history or CDA archives obtained on request.

**Pacific** (`png-kik-market-report`, `solomon-cema-cbsi`, `vanuatu-vbos-qsi`). All quarterly. They are depot prices (PNG) or export unit values (Solomon Islands, Vanuatu), not quotations. They are expansion candidates for a later methodology version.

### 4. Licences

| Redistribution | Sources |
|---|---|
| Open | AGMARKNET (GODL-India), FAOSTAT (CC BY 4.0, no use promoting a commercial enterprise) |
| Unclear (no terms stated) | PSA, CDB, CDA, KIK, CEMA/CBSI, VBOS, World Bank coconut oil file |
| Restricted | ICC (all rights reserved), Oil World (subscription) |

Every recommended input is in the "unclear" row. GCPI-001 §12.2 requires an open historical dataset, so before v1 freezes, each recommended publisher needs written confirmation that its prices may be republished. FAOSTAT's clause against promoting a commercial enterprise needs a legal read for an index that $COPRA consumes (#98).

### 5. Authentication (input to #89)

No source offers a signed feed. What exists:
- **HTTPS JSON API:** PSA. This is the best case for TLS attestation (zkTLS/TLSNotary): small, structured responses.
- **HTTPS HTML form:** CDB. Attestable, but each request needs ASP.NET view state.
- **HTTPS PDF:** CDA, ICC, KIK, VBOS. A price inside a PDF is hard to extract in-proof.
- **Blocked:** PCA. A Cloudflare JavaScript challenge defeats both plain collectors and TLS attestation.

Asking PSA, CDB and CDA for a signed or at least stable machine-readable feed is the highest-leverage step for #89.

---

## Answers to the issue's questions

**Which delivery basis has enough directly comparable sources to be the headline?** Domestic, because no export basis is publicly available, and within domestic, the **export-linked markets** (Philippines, Indonesia). Today only the Philippines has a primary source, so the headline is effectively a Philippine index until an Indonesian primary source exists. Grade should be **dried milling copra (Resecada-class)**, which PSA reports separately. India and Sri Lanka become per-country sub-indices, as the review recommended.

**Which source gives copra production volumes for the §4 weights?** None openly. FAOSTAT has no copra item. It has coconut oil production (2023 shares: Philippines 38.8%, Indonesia 20.7%, India 17.6%, Sri Lanka 1.4%), which could stand in for copra milled after a documented extraction-rate conversion (§4.1 forbids an undocumented substitution). ICC's yearbook reports copra production directly but is all rights reserved. With a headline of one or two export-linked markets, weights matter less: two markets need one ratio, not a weighting scheme.

**Are coconut oil quotes available as corroboration (§7.5)?** Yes. The World Bank's monthly coconut oil series (CFR Europe, 1960 onwards, published early each following month) and ICC's weekly CIF Rotterdam coconut oil line both exist. Both are excluded from the index by §2.2 and suit corroboration. The World Bank series' four basis changes must be handled as breaks.

---

## Recommended source set

For #90 to accept, amend or reject:

| Component | Source | Status before v1 can use it |
|---|---|---|
| Headline: Philippines, Resecada, farmgate | PSA OpenSTAT | Explain the 2024–2026 grade inversion (#88); confirm republication terms |
| Headline: Indonesia | None | Find a primary source, or the headline stays single-country |
| Sub-index: India, milling copra | CDB (Kochi, Kozhikode, Alappuzha) | Confirm terms; use weekly or monthly values, not daily |
| Sub-index: Sri Lanka | CDA daily bulletin | Confirm terms; obtain archive before 2026 |
| Corroboration | World Bank coconut oil; AGMARKNET (India) | Handle basis breaks; measure AGMARKNET copra history |
| Weights | FAOSTAT coconut oil + documented conversion | Only needed if the headline has more than one market |
| Backtest history only | ICC Weekly Price Update 2016– | Ask ICC for permission to republish |

**Cadence (input to #90):** monthly is the most the headline sources support today. A weekly headline needs a weekly primary source for the Philippines (PCA or UCAP publishing one) or Indonesia.

## What would make a global index defensible

1. **A redistributable export-basis copra price.** ICC or UCAP publishing FOB copra under an open licence would let §2.3 normalize all markets to one basis.
2. **A primary Indonesian copra series.**
3. **Written republication permission** from PSA, CDB, CDA and ICC.
4. **A machine-readable feed from PCA**, which today is both blocked and unpublished.

Until then, calling the headline "global" would overstate it.

## Implications for the other issues

- **#88 (backtest):** test the export-linked headline and the sub-indices separately; repeat the regime analysis in local currency; explain the PSA grade inversion; treat CDB daily values as carried forward.
- **#89 (authentication):** PSA's JSON API is the realistic first target for TLS attestation. PDF sources need a different approach, and PCA is out of reach.
- **#90 (spec decisions):** Q1 basis and grade as above; cadence monthly unless a weekly primary appears; §7.5 corroboration within the export-linked pair plus coconut oil, not across all four markets.
- **#96 (COPRA-001 economics):** a monthly GCPI with a two-month publication lag means a redemption settles about three to four months after request: the next month must end, then be published (COPRA-001 §8.2). The ratios in COPRA-001 §13.2 must be sized for that.
- **#98 (legal):** licence confirmations above, and FAOSTAT's commercial-promotion clause.

---

## Reproducing these numbers

Each script is stdlib Python 3 and prints what this report quotes. Downloaded files are cached locally and never committed; ICC's PDFs are all rights reserved.

```bash
python3 gcpi/research/icc_archive.py /tmp/gcpi-icc 2016-01 2026-10   # needs pdftotext (poppler)
python3 gcpi/research/psa_copra.py
python3 gcpi/research/cdb_copra.py 2005 2026 01/08/2026-30/09/2026
python3 gcpi/research/worldbank_cmo.py CMO-Historical-Data-Monthly.xlsx
```

`test/gcpi/test_sources.py` checks the registry:
- Every candidate the issue names has an entry.
- Every entry has the fields the issue asks for.
- Every rejection gives a reason.
- No restricted source is marked as an index input.

## Method and limits

- Sources were checked on 18 October 2026, by fetching the publisher's own page, file or API wherever it answered. Fields not confirmed that way say "unverified" in the registry. PCA, PSA's web pages and FAOSTAT's API refused automated access that day.
- The cross-market statistics use ICC's US$ series, which mixes in currency moves at an undisclosed conversion rate. They show the size of the effect, not a calibrated parameter.
- Licence status reflects published terms only. No publisher was contacted.
