# RFC NNNN: <title>

**Proposes:** `GCPI-<n>` · **Replaces or continues:** `GCPI-<n-1>` (new series / comparable continuation) · **Discussion:** <link>
**Author:** <name> · **Status:** draft | ready for comment (since YYYY-MM-DD) | in review | released | withdrawn

The process is [GCPI-001 §13.6–§13.9](../../docs/specs/GCPI-001.md#136-proposing-a-version-public-rfc). Copy this file to `NNNN-<title>.md` and fill in every section. If a section does not apply, say why. Do not delete it.

> copra.dev builds $COPRA, which settles against GCPI. copra.dev runs this repository and chooses which GCPI version its site shows first. That choice is not part of any methodology and binds no one. Every released version, its review reports and its full record are listed regardless of that choice.

## 1. Problem

What is wrong with, or missing from, the current version. Give the evidence: data, incidents and periodic reviews (§13.10).

## 2. Changes

Every change to the bundle (§13.5): specification, parameter file, reference engine, parsers, notary list, keys. Link the diff.

## 3. Backtest against the current version

Both versions, run on the open historical dataset (§12.2). For each period, show where they diverge and by how much, and how VALID and non-valid periods compare. Include the commands that reproduce it.

## 4. Series continuity

Is this a comparable continuation of the current series, or a new series? Changing sources, weights or aggregation starts a new series, unless you show that the two series cannot diverge (§4.3).

## 5. Effect on consumers

Who reads the current version, including $COPRA (GCPI-001 §15). What happens to each consumer if it adopts this version, and what happens if it does not. Releasing a version moves no one (§13.9).

## 6. Conflicts of interest (§13.11)

The author's $COPRA holdings, any COPRA-001 positions, any other exposure to a GCPI consumer, and who pays the author for this work.

## 7. Comment record (§13.7)

| Date | Comment (link) | Response | Accepted? |
|---|---|---|---|

## 8. Independent reviews (§13.8)

| Reviewer | Independence statement | Report (link) | Blocking findings | Resolved (link) |
|---|---|---|---|---|

At least two reviews are required. A blocking finding blocks release until a new revision answers it and a reviewer confirms the answer.
