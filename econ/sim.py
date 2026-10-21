#!/usr/bin/env python3
"""
COPRA-001 economics (#96): a discrete-time model of the v0.1 mechanism.

Replays a monthly reference-price path through positions, liquidations, bad-debt
redistribution, forward-priced redemption and shortfall, per COPRA-001 §5, §8, §9,
§11 and §12. Answers the quantitative open questions in §16 (allocation, ratios,
fees, cadence) with measurements instead of guesses.

Model of time: wall-clock months t = 0, 1, ... Reference month i finalizes at the end
of wall-clock month i + lag (default 2, "up to about two months", §8.2). A month is
VALID with its reference price, or non-valid (outage set by the experiment). The
usable price is the latest finalized VALID price whose finalization age is within
max_price_age. Redemption requests made in wall-clock month k settle at the first
finalized VALID month s >= k + 1 (§8.2).

What this is not: consensus arithmetic (floats, not the fixed-point mulDiv of §3;
that is #97's problem), market prices (no DEX, no premium dynamics), or GCPI itself
(the paths in data/paths.csv are open copra-price proxies, not the v1 basket).

Stdlib only.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass, field


@dataclass
class Params:
    mcr: float = 2.5          # minimum collateral ratio after mint/withdraw
    lr: float = 1.75          # liquidation ratio
    liq_bonus: float = 0.05   # liquidator bonus (fraction)
    min_debt: float = 100.0   # smallest position worth liquidating ($COPRA)
    redeem_fee: float = 0.005  # redemption fee kept by positions (fraction)
    lag: int = 2              # finalization lag in months
    max_price_age: int = 3    # oldest usable finalization, in months since it finalized
    redeem_expiry: int = 6    # months after request before a priceless request may cancel
    gas_usd: float = 2.0      # liquidation execution cost; a liquidation must clear it
    allocation: str = "proportional"  # "lowest_first" or "collateral_prop"
    topup_trigger: float = 0.0  # 0 = passive minters; else top up to mcr below mcr*trigger
    topup_delay: int = 1      # months a position must sit below the trigger first
    withdraw_buffer: float = 0.0  # 0 = never; else withdraw to mcr*buffer above it
    steady_mint: bool = False  # mint at mcr to replace redeemed supply


@dataclass
class Position:
    c: float       # collateral, USD
    d: float       # debt, $COPRA (= kg)
    cohort: int = 0
    below: int = 0  # consecutive months below the top-up trigger
    fee_kept: float = 0.0  # redeem fees retained by this position, USD


@dataclass
class Request:
    amount: float  # $COPRA escrowed
    k: int         # request wall-clock month


@dataclass
class State:
    params: Params
    positions: list = field(default_factory=list)
    pending: list = field(default_factory=list)  # Request
    finalized: dict = field(default_factory=dict)  # month -> price or None
    tcr_history: list = field(default_factory=list)
    # Cash-flow ledgers for minter-return accounting.
    deposits: dict = field(default_factory=dict)   # cohort -> USD deposited (net of top-ups)
    withdrawals: dict = field(default_factory=dict)  # cohort -> USD withdrawn
    liq_paid: dict = field(default_factory=dict)   # cohort -> USD bonus paid to liquidators
    redist_in: dict = field(default_factory=dict)  # cohort -> debt redistributed onto it
    fees_paid: dict = field(default_factory=dict)  # cohort -> USD redeem fees kept (cumulative)
    proceeds: dict = field(default_factory=dict)  # cohort -> USD from selling minted $COPRA
    # Cumulative loss ledger (spec §11): realized bad debt and shortfall haircuts.
    bad_debt_usd: float = 0.0
    shortfall_haircut_usd: float = 0.0
    # Redemption outcomes: wall - k for each settled request, and cancellations.
    settle_delays: list = field(default_factory=list)
    cancelled: int = 0


def value(debt, price):
    return debt * price


def cr(pos, price):
    if pos.d <= 0:
        return float("inf")
    return pos.c / value(pos.d, price)


def totals(state):
    c = sum(p.c for p in state.positions)
    d = sum(p.d for p in state.positions)
    return c, d


def tcr(state, price):
    c, d = totals(state)
    if d <= 0:
        return float("inf")
    return c / value(d, price)


def usable_price(state, wall):
    """Latest finalized VALID price within max_price_age, else None (§4.2)."""
    p = state.params
    best = None
    for i, px in state.finalized.items():
        fin_month = i + p.lag  # month i finalized at the end of this wall-clock month
        if px is not None and fin_month <= wall <= fin_month + p.max_price_age:
            if best is None or i > best[0]:
                best = (i, px)
    return best[1] if best else None


def liquidate(state, price):
    """Run liquidations to quiescence at the usable price (§9, §11.1).

    Returns (count, debt_repaid, collateral_seized, bad_debt_redistributed).
    A liquidation executes only if the liquidator's profit clears gas_usd.
    """
    p = state.params
    count, repaid, seized, redist = 0, 0.0, 0.0, 0.0
    tried = set()  # positions already found unprofitable this call
    while True:
        target = None
        for j, pos in enumerate(state.positions):
            if j not in tried and pos.d > 0 and cr(pos, price) < p.lr:
                target = j
                break
        if target is None:
            break
        pos = state.positions[target]
        x, take, bad = _liquidation_terms(pos, price, p)
        if take - value(x, price) <= p.gas_usd:
            tried.add(target)  # dust: the bonus cannot pay gas (§5.4)
            continue
        bonus = take - value(x, price)
        state.liq_paid[pos.cohort] = state.liq_paid.get(pos.cohort, 0.0) + bonus
        pos.c -= take
        pos.d -= x
        count += 1
        repaid += x
        seized += take
        tried = set()  # state changed; re-sweep from the top
        if bad > 0:
            state.bad_debt_usd += value(bad, price)
            _redistribute(state, bad, exclude=None)
            pos.d -= bad  # the redistributed debt leaves this position
            redist += bad
    unliq = [q for q in state.positions if q.d > 0 and cr(q, price) < p.lr]
    return {"count": count, "repaid": repaid, "seized": seized, "redistributed": redist,
            "unliq_count": len(unliq), "unliq_debt": sum(q.d for q in unliq)}


def _liquidation_terms(pos, price, p):
    """(debt repaid x, collateral taken, bad debt) for liquidating pos (§9.2, §11.1)."""
    dv = value(pos.d, price)
    if pos.c >= dv * (1 + p.liq_bonus):
        return pos.d, dv * (1 + p.liq_bonus), 0.0  # fully covered with the bonus
    if pos.c >= dv:
        return pos.d, pos.c, 0.0  # covered without the bonus
    x = pos.c / (price * (1 + p.liq_bonus))  # bad debt: repay what C covers...
    return x, pos.c, pos.d - x  # ...seize it all, redistribute the rest


def _credit_fee(state, pos, amt):
    pos.fee_kept += amt
    state.fees_paid[pos.cohort] = state.fees_paid.get(pos.cohort, 0.0) + amt


def _redistribute(state, debt, exclude):
    """Add bad debt across positions in proportion to collateral (§11.1)."""
    others = [q for q in state.positions if q is not exclude and q.c > 0]
    tot = sum(q.c for q in others)
    if tot <= 0 or debt <= 0:
        return
    for q in others:
        share = debt * q.c / tot
        q.d += share
        state.redist_in[q.cohort] = state.redist_in.get(q.cohort, 0.0) + share


def settle_request(state, req, price):
    """Settle one redemption at P_s (§8.3, §11.3). Returns the payout in USD."""
    p = state.params
    c, d = totals(state)
    if d <= 0 or req.amount <= 0:
        return 0.0
    amount = min(req.amount, d)
    haircut = min(1.0, tcr(state, price))
    gross = value(amount, price) * haircut
    if haircut < 1.0:
        state.shortfall_haircut_usd += value(amount, price) - gross
    fee = gross * p.redeem_fee
    payout = gross - fee
    fee_per_debt = price * haircut * p.redeem_fee
    if p.allocation == "lowest_first":
        _allocate_lowest_first(state, amount, payout, price, fee_per_debt)
    elif p.allocation == "collateral_prop":
        _allocate_collateral_prop(state, amount, payout, fee_per_debt)
    elif p.allocation == "proportional":
        _allocate_proportional(state, amount, payout, price, fee_per_debt)
    else:
        raise ValueError(f"unknown allocation {p.allocation!r}")
    # The fee stays in the system: collateral removed is payout, debt removed is amount.
    state.positions = [q for q in state.positions if q.d > 1e-9 or q.c > 1e-9]
    # A partial fill (amount < req.amount) still pays only what was settled.
    return payout


def _allocate_proportional(state, amount, payout, price, fee_per_debt):
    """Debt and collateral removed from every position in proportion to debt (§8.3).

    A position covers its share unless it is underwater (CR < haircut*(1-fee));
    anything liquidatable was liquidated before settlement, so in practice only
    unprofitable dust fails. Uncovered debt is bad debt and redistributes (§11.1).
    Shares are fixed up front: debt redistributed mid-pass must not change
    later shares.
    """
    _, d = totals(state)
    per_unit = payout / amount
    takes = [amount * pos.d / d for pos in state.positions]
    for pos, take_d in zip(state.positions, takes):
        need_c = take_d * per_unit
        if need_c > pos.c + 1e-9:
            covered_d = pos.c / per_unit if per_unit > 0 else 0.0
            bad = take_d - covered_d
            _credit_fee(state, pos, covered_d * fee_per_debt)
            pos.c, pos.d = 0.0, pos.d - take_d
            state.bad_debt_usd += value(bad, price)
            _redistribute(state, bad, exclude=pos)
            # The position's leftover debt with no collateral is bad debt too.
            if pos.d > 1e-9:
                state.bad_debt_usd += value(pos.d, price)
                _redistribute(state, pos.d, exclude=pos)
                pos.d = 0.0
        else:
            pos.d -= take_d
            pos.c -= min(need_c, pos.c)
            _credit_fee(state, pos, take_d * fee_per_debt)


def _allocate_collateral_prop(state, amount, payout, fee_per_debt):
    """Debt removed in proportion to debt, collateral in proportion to collateral.

    Every position pays the same haircut rate on its collateral, so every position
    covers by construction — including in shortfall, where debt-proportional takes
    can exceed an underwater position's collateral. A §16 Q1 candidate for v0.2.
    """
    c, d = totals(state)
    for pos in state.positions:
        take_d = amount * pos.d / d
        take_c = payout * pos.c / c
        pos.d -= take_d
        pos.c -= take_c
        _credit_fee(state, pos, take_d * fee_per_debt)


def _allocate_lowest_first(state, amount, payout, price, fee_per_debt):
    """Redeem against the lowest-ratio positions first (the §16 Q1 alternative)."""
    per_unit = payout / amount
    state.positions.sort(key=lambda q: cr(q, price))
    rest_d = amount
    for pos in state.positions:
        if rest_d <= 1e-9:
            break
        take_d = min(pos.d, rest_d)
        need_c = take_d * per_unit
        if need_c > pos.c:
            # Position cannot cover its share: take all collateral, the uncovered
            # debt is bad debt and redistributes (§11.1).
            covered_d = pos.c / per_unit if per_unit > 0 else 0.0
            bad = take_d - covered_d
            rest_d -= take_d
            _credit_fee(state, pos, covered_d * fee_per_debt)
            pos.c, pos.d = 0.0, 0.0
            if bad > 1e-9:
                state.bad_debt_usd += value(bad, price)
                _redistribute(state, bad, exclude=pos)
        else:
            pos.d -= take_d
            pos.c -= need_c
            rest_d -= take_d
            _credit_fee(state, pos, take_d * fee_per_debt)


def settlement_period(state, req, wall):
    """First finalized VALID month s >= k+1 (§8.2), or None if none has finalized."""
    p = state.params
    cands = [i for i, px in state.finalized.items()
             if i >= req.k + 1 and px is not None and i + p.lag <= wall]
    return min(cands) if cands else None


def step(state, wall, ref, valid, demand_fn):
    """Run one wall-clock month. ref is the reference price of the month finalizing
    now (wall - lag), or None past the path's end, in which case nothing finalizes.
    Returns the month's record."""
    p = state.params
    fin = wall - p.lag
    if fin >= 0 and ref is not None:
        state.finalized[fin] = ref if valid else None
    price = usable_price(state, wall)
    supply_before = totals(state)[1]
    shortfall = price is not None and tcr(state, price) < 1.0
    liq = {"count": 0, "repaid": 0.0, "seized": 0.0, "redistributed": 0.0,
           "unliq_count": 0, "unliq_debt": 0.0}
    if price is not None:
        liq = liquidate(state, price)
    # Settle eligible redemptions, oldest first (same price per period, §8.2.4).
    settled_n, settled_amt, settled_pay = 0, 0.0, 0.0
    still = []
    for req in state.pending:
        s = settlement_period(state, req, wall)
        if s is not None and price is not None:
            _, d_before = totals(state)
            pay = settle_request(state, req, state.finalized[s])
            settled_n += 1
            settled_amt += min(req.amount, d_before)
            settled_pay += pay
            state.settle_delays.append(wall - req.k)
        elif wall - req.k >= p.redeem_expiry and s is None:
            state.cancelled += 1  # escrow returns to the holder (§8.4)
        else:
            still.append(req)
    state.pending = still
    # New requests, capped at circulating (escrowed tokens cannot re-redeem).
    c, d = totals(state)
    escrowed = sum(r.amount for r in state.pending)
    circulating = max(0.0, d - escrowed)
    # Requests are allowed in every state (§12); settlement needs a price.
    req_amt = min(max(0.0, demand_fn(wall, price, state)), circulating)
    if req_amt > 0:
        state.pending.append(Request(req_amt, wall))
    # Maintainer top-ups (§13.2 reaction window M).
    topups = 0.0
    if price is not None and p.topup_trigger > 0:
        for pos in state.positions:
            if pos.d <= 0:
                continue
            if cr(pos, price) < p.mcr * p.topup_trigger:
                pos.below += 1
            else:
                pos.below = 0
            if pos.below >= p.topup_delay:
                need = value(pos.d, price) * p.mcr - pos.c
                if need > 0:
                    pos.c += need
                    pos.below = 0
                    topups += need
                    state.deposits[pos.cohort] = state.deposits.get(pos.cohort, 0.0) + need
    # Steady mint replaces redeemed supply at mcr (models ongoing minter demand).
    minted = 0.0
    if p.steady_mint and price is not None and not shortfall:
        if settled_amt >= p.min_debt:
            minted = settled_amt
            add_position(state, value(minted, price) * p.mcr, minted, cohort=1,
                         price=price)
    # Maintainers take profit above the buffer (withdrawals need a usable price
    # and no shortfall, §5.3; the top-up band below avoids churn).
    profit_taken = 0.0
    if price is not None and p.withdraw_buffer > 0 and not shortfall:
        for pos in state.positions:
            if pos.d > 0 and cr(pos, price) > p.mcr * p.withdraw_buffer:
                take = pos.c - value(pos.d, price) * p.mcr * p.withdraw_buffer
                if take > 0:
                    pos.c -= take
                    profit_taken += take
                    state.withdrawals[pos.cohort] = state.withdrawals.get(pos.cohort, 0.0) + take
    # Owners withdraw leftover collateral from debt-free positions; empty husks
    # (liquidated or redeemed to zero) leave the set.
    withdrawn = 0.0
    kept = []
    for pos in state.positions:
        if pos.d <= 1e-9 and pos.c > 1e-9:
            withdrawn += pos.c
            state.withdrawals[pos.cohort] = state.withdrawals.get(pos.cohort, 0.0) + pos.c
        elif pos.d > 1e-9 or pos.c > 1e-9:
            kept.append(pos)
    state.positions = kept
    c2, d2 = totals(state)
    rec = {"wall": wall, "price": price, "supply_before": supply_before,
           "tcr": tcr(state, price) if price else None,
           "shortfall": shortfall, "n_pos": len(state.positions),
           "collateral": c2, "debt": d2,
           "liq_count": liq["count"], "liq_repaid": liq["repaid"],
           "liq_seized": liq["seized"], "redistributed": liq["redistributed"],
           "unliq_count": liq["unliq_count"], "unliq_debt": liq["unliq_debt"],
           "requested": req_amt, "settled_n": settled_n, "settled_amt": settled_amt,
           "settled_pay": settled_pay, "pending_amt": sum(r.amount for r in state.pending),
           "topups": topups, "profit_taken": profit_taken, "minted": minted,
           "withdrawn": withdrawn}
    state.tcr_history.append(rec["tcr"])
    return rec


def add_position(state, collateral, debt, cohort=0, price=None):
    """Open a position. price records what the minter got for the minted $COPRA:
    sold at GCPI (no premium) by default, so minter returns are the short payoff
    plus fees. A market premium would add to proceeds."""
    assert debt >= state.params.min_debt, "positions open above MIN_DEBT (§5.4)"
    state.positions.append(Position(collateral, debt, cohort))
    state.deposits[cohort] = state.deposits.get(cohort, 0.0) + collateral
    if price is not None:
        state.proceeds[cohort] = state.proceeds.get(cohort, 0.0) + value(debt, price)
    return state.positions[-1]


def genesis(state, debt_total, n, cr_lo, cr_hi, price, cohort=0):
    """Open n equal-debt positions with ratios spread over [cr_lo, cr_hi]."""
    if n == 1:
        crs = [(cr_lo + cr_hi) / 2]
    else:
        crs = [cr_lo + (cr_hi - cr_lo) * i / (n - 1) for i in range(n)]
    for r in crs:
        add_position(state, value(debt_total / n, price) * r, debt_total / n, cohort,
                     price)


def cohort_returns(state, price):
    """Cash-on-cash multiple per cohort: (equity + withdrawals + mint proceeds, the
    $COPRA sale that makes the position a short) / deposits."""
    out = {}
    cohorts = set(list(state.deposits) + [p.cohort for p in state.positions])
    for ch in sorted(cohorts):
        mine = [p for p in state.positions if p.cohort == ch]
        eq = sum(p.c - value(p.d, price) for p in mine)
        dep = state.deposits.get(ch, 0.0)
        wd = state.withdrawals.get(ch, 0.0)
        proc = state.proceeds.get(ch, 0.0)
        out[ch] = {"equity": eq, "deposits": dep, "withdrawals": wd,
                   "proceeds": proc,
                   "multiple": (eq + wd + proc) / dep if dep > 0 else None,
                   "liq_paid": state.liq_paid.get(ch, 0.0),
                   "redist_in": state.redist_in.get(ch, 0.0),
                   "fees_kept": state.fees_paid.get(ch, sum(p.fee_kept for p in mine))}
    return out


def load_paths(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    out = {}
    for col in ("export_copra_usd_kg", "coconut_oil_usd_kg", "cdb_kochi_usd_kg",
                "psa_resecada_usd_kg"):
        out[col] = [(r["month"], float(r[col])) for r in rows if r[col]]
    return out
