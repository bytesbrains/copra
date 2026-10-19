#!/usr/bin/env python3
"""
GCPI Phase 3 (#91): the reference engine, Python implementation.

Takes a methodology and canonical observations, and returns one record per calculation period: status
(GCPI-001 §9.4), level, coverage, active set, and every market decision behind it. Integer arithmetic
only. gcpi/ENGINE.md is the normative description; engine.cjs is the second, independent
implementation, and both must produce byte-identical canonical output on every vector in vectors/.

Usage: engine.py <input.json>   prints the canonical output
Stdlib only.
"""

import hashlib
import json
import re
import sys

WAD = 10 ** 18                   # output scale: prices and levels in 1e-18 USD/kg
S = 10 ** 36                     # internal scale of ln and exp
LN2 = 693147180559945309417232121458176568   # ln 2 at scale S, truncated
P_MIN, P_MAX = 10 ** 12, 10 ** 24            # normalized price bounds: 1e-6 to 1e6 USD/kg
MAX_MANTISSA, MAX_EXP = 10 ** 30, 18
UNIT_KG = {"kg": 1, "quintal": 100, "t": 1000}
BANDS = ("normal", "corroborate", "confirm", "quarantine")
SECONDS_PER_DAY = 86400

PERIOD = re.compile(r"^[0-9]{4}-(0[1-9]|1[0-2])\Z")
UINT = re.compile(r"^(0|[1-9][0-9]*)\Z")
HEX32 = re.compile(r"^[0-9a-f]{64}\Z")
ID = re.compile(r"^[A-Za-z0-9_.-]{1,64}\Z")
CODE = re.compile(r"^[A-Z]{3}\Z")


class EngineError(Exception):
    """A structurally malformed input. Carries a stable code that both implementations agree on."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


# ------------------------------------------------------------------------------------------------
# Integer helpers. Every division in the engine is one of these two.

def tdiv(a, b):
    """Division rounded toward zero, as in Solidity and JavaScript BigInt."""
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def hdiv(a, b):
    """Division of non-negative integers, rounded half up."""
    return (2 * a + b) // (2 * b)


def ln(x):
    """Natural log of x / S, at scale S. x > 0."""
    k = 0
    while x >= 2 * S:
        x //= 2
        k += 1
    while x < S:
        x *= 2
        k -= 1
    z = (x - S) * S // (x + S)
    z2 = z * z // S
    total, power, n = z, z, 1
    while True:
        power = power * z2 // S
        n += 2
        term = power // n
        if term == 0:
            break
        total += term
    return 2 * total + k * LN2


def exp(m):
    """e^(m / S), at scale S. m may be negative."""
    k = tdiv(m, LN2)
    r = m - k * LN2
    total, term, n = S, S, 0
    while True:
        n += 1
        term = tdiv(term * r, n * S)
        if term == 0:
            break
        total += term
    return total << k if k >= 0 else total >> -k


def ym_index(ym):
    return int(ym[:4]) * 12 + int(ym[5:]) - 1


def ym_name(i):
    return f"{i // 12:04d}-{i % 12 + 1:02d}"


def days_from_civil(y, m, d):
    """Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm)."""
    y -= m <= 2
    era = y // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def period_start(i):
    """Unix seconds of the first instant of period i, UTC."""
    return days_from_civil(i // 12, i % 12 + 1, 1) * SECONDS_PER_DAY


# ------------------------------------------------------------------------------------------------
# Canonical encoding.

def canonical(value):
    """Canonical JSON: sorted keys, no whitespace, printable ASCII, and no numbers (integers are strings)."""
    def check(v):
        if isinstance(v, bool) or v is None:
            return
        if isinstance(v, str):
            # Printable ASCII only, so that the only escapes are \" and \\, which every JSON encoder agrees on.
            if any(not 0x20 <= ord(c) <= 0x7e for c in v):
                raise EngineError("non_ascii")
            return
        if isinstance(v, list):
            for x in v:
                check(x)
            return
        if isinstance(v, dict):
            for k, x in v.items():
                check(k)
                check(x)
            return
        raise EngineError("non_canonical_value")
    check(value)
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _str(s):
    b = s.encode("ascii")
    return len(b).to_bytes(4, "big") + b


def _uint(n):
    return n.to_bytes(32, "big")


OBS_FIELDS = ("market", "period", "source", "price", "price_exp", "currency", "unit", "fx", "fx_exp",
              "fx_source", "published", "record", "basis")
INT_FIELDS = {"price", "price_exp", "fx", "fx_exp", "published"}


def commitment(obs):
    """SHA-256 of the observation's fields in OBS_FIELDS order: strings length-prefixed (uint32 big
    endian), integers as 32-byte big endian, an absent fx or fx_exp as the empty string."""
    out = _str("GCPI-OBS-v1")
    for f in OBS_FIELDS:
        v = obs[f]
        out += _uint(int(v)) if f in INT_FIELDS and v != "" else _str(v)
    return hashlib.sha256(out).hexdigest()


def input_commitment(commitments):
    out = _str("GCPI-INPUT-v1") + _uint(len(commitments))
    for c in sorted(commitments):
        out += bytes.fromhex(c)
    return hashlib.sha256(out).hexdigest()


# ------------------------------------------------------------------------------------------------
# Input checking. Structural faults raise EngineError; semantic faults make an observation INVALID.

def _need(cond, code):
    if not cond:
        raise EngineError(code)


def check_methodology(m):
    _need(isinstance(m, dict), "methodology")
    _need(isinstance(m.get("id"), str) and ID.match(m["id"]) is not None, "methodology_id")
    markets = m.get("markets")
    _need(isinstance(markets, dict) and markets, "markets")
    for k, w in markets.items():
        _need(ID.match(k) is not None and isinstance(w, str) and UINT.match(w) is not None and int(w) > 0, "market_weight")
    signals = m.get("signals")
    _need(isinstance(signals, list) and all(isinstance(s, str) and ID.match(s) for s in signals), "signals")
    _need(len(set(signals)) == len(signals) and not set(signals) & set(markets), "signals")
    corr = m.get("corroborators")
    _need(isinstance(corr, dict) and set(corr) <= set(markets), "corroborators")
    for k, cs in corr.items():
        _need(isinstance(cs, list) and all(c in markets or c in signals for c in cs) and k not in cs
              and len(set(cs)) == len(cs), "corroborators")
    for f in ("min_coverage_bp", "max_publication_lag_days"):
        _need(isinstance(m.get(f), str) and UINT.match(m[f]) is not None, f)
    _need(int(m["min_coverage_bp"]) <= 10000, "min_coverage_bp")
    bands = m.get("bands_bp")
    _need(bands is None or (isinstance(bands, list) and len(bands) == 3 and all(
        isinstance(b, str) and UINT.match(b) for b in bands) and 0 < int(bands[0]) < int(bands[1]) < int(bands[2])), "bands_bp")
    cb = m.get("circuit_breaker_bp")
    _need(cb is None or (isinstance(cb, str) and UINT.match(cb) is not None and int(cb) > 0 and bands is not None),
          "circuit_breaker_bp")
    _need(isinstance(m.get("base_period"), str) and PERIOD.match(m["base_period"]) is not None, "base_period")
    _need(set(m) == {"id", "markets", "signals", "corroborators", "min_coverage_bp", "max_publication_lag_days",
                     "bands_bp", "circuit_breaker_bp", "base_period"}, "methodology_fields")


def check_observation(o):
    _need(isinstance(o, dict) and set(o) == set(OBS_FIELDS), "observation_fields")
    _need(all(isinstance(o[f], str) for f in OBS_FIELDS), "observation_types")
    for f in ("market", "source", "fx_source", "basis"):
        _need(o[f] == "" or ID.match(o[f]) is not None, "observation_id")
    _need(ID.match(o["market"]) is not None, "observation_id")
    _need(PERIOD.match(o["period"]) is not None, "observation_period")
    for f in INT_FIELDS:
        _need(UINT.match(o[f]) is not None or (f in ("fx", "fx_exp") and o[f] == ""), "observation_integer")
    _need((o["fx"] == "") == (o["fx_exp"] == ""), "observation_fx")
    _need(HEX32.match(o["record"]) is not None, "observation_record")
    _need(CODE.match(o["currency"]) is not None, "observation_currency")


def normalize(o, lag_days):
    """USD/kg at WAD, or the reason the observation is not usable."""
    price, pexp = int(o["price"]), int(o["price_exp"])
    if o["unit"] not in UNIT_KG:
        return None, "unit"
    if price == 0 or price >= MAX_MANTISSA or pexp > MAX_EXP:
        return None, "price_range"
    if o["currency"] == "USD":
        if o["fx"] != "":
            return None, "fx_unexpected"
        fx, fexp = 1, 0
    else:
        if o["fx"] == "":
            return None, "fx_missing"
        fx, fexp = int(o["fx"]), int(o["fx_exp"])
        if fx == 0 or fx >= MAX_MANTISSA or fexp > MAX_EXP:
            return None, "fx_range"
    p = hdiv(price * WAD * 10 ** fexp, 10 ** pexp * UNIT_KG[o["unit"]] * fx)
    if not P_MIN <= p <= P_MAX:
        return None, "price_range"
    start = period_start(ym_index(o["period"]))
    published = int(o["published"])
    if published < start:
        return None, "published_early"
    deadline = period_start(ym_index(o["period"]) + 1) + lag_days * SECONDS_PER_DAY
    if published > deadline:
        return p, "stale"
    return p, None


# ------------------------------------------------------------------------------------------------
# Bands. thr is in basis points; k is the number of periods elapsed, and thresholds scale by √k.

def within(p_ref, p_new, thr, k):
    """|p_new / p_ref - 1| <= thr / 10000 × √k, exactly."""
    d = abs(p_new - p_ref) * 10000
    return d * d <= thr * thr * k * p_ref * p_ref


def band(p_ref, p_new, bands, k):
    for name, thr in zip(BANDS, bands):
        if within(p_ref, p_new, thr, k):
            return name
    return BANDS[3]


def closer(v, a, b):
    """True if v is relatively closer to a than to b: |v - a| / a < |v - b| / b, exactly. A tie is False."""
    return abs(v - a) * b < abs(v - b) * a


def sign(x):
    return (x > 0) - (x < 0)


# ------------------------------------------------------------------------------------------------
# Pass 1: per-period observation sets, then each market's decisions on its own.

def collect(m, observations):
    """{series: {period: {"price": p or None, "state": ..., "commitments": [...]}}} for every configured
    market and signal. state is one of OK, INVALID, DISPUTED, STALE."""
    lag = int(m["max_publication_lag_days"])
    series = set(m["markets"]) | set(m["signals"])
    raw = {}
    for o in observations:
        if o["market"] not in series:
            continue
        raw.setdefault(o["market"], {}).setdefault(ym_index(o["period"]), {})[commitment(o)] = o
    out = {}
    for s, periods in raw.items():
        out[s] = {}
        for t, obs in periods.items():
            results = [(c, *normalize(o, lag), o["basis"]) for c, o in obs.items()]
            usable = [r for r in results if r[2] is None]
            stale = [r for r in results if r[2] == "stale"]
            entry = {"commitments": sorted(obs)}
            if usable:
                values = {(r[1], r[3]) for r in usable}
                if len(values) > 1:
                    entry.update(state="DISPUTED", price=None, basis=None)
                else:
                    (p, b), = values
                    entry.update(state="OK", price=p, basis=b)
            elif stale:
                entry.update(state="STALE", price=None, basis=None)
            else:
                entry.update(state="INVALID", price=None, basis=None)
            out[s][t] = entry
    return out


def corroborated(m, data, market, a, t, direction, strong):
    """True if a corroborator moved in `direction` between periods a and t (same basis at both ends).
    `strong` also requires the move to exceed the normal band."""
    k = t - a
    for c in m["corroborators"].get(market, []):
        ea, et = data.get(c, {}).get(a), data.get(c, {}).get(t)
        if not ea or not et or ea["state"] != "OK" or et["state"] != "OK" or ea["basis"] != et["basis"]:
            continue
        if sign(et["price"] - ea["price"]) != direction or direction == 0:
            continue
        if strong and within(ea["price"], et["price"], int(m["bands_bp"][0]), k):
            continue
        return True
    return False


def passes(m, data, market, ref_t, ref_p, t, p):
    """(passes, band) for an observation p at t checked against a reference price at ref_t."""
    if m["bands_bp"] is None:
        return True, None
    bands = [int(b) for b in m["bands_bp"]]
    b = band(ref_p, p, bands, t - ref_t)
    if b == "normal":
        return True, b
    if b == "quarantine":
        return False, b
    return corroborated(m, data, market, ref_t, t, sign(p - ref_p), b == "confirm"), b


def decide_market(m, data, market, periods):
    """{period: decision} for one market. A decision is {"decision", "band", "decided_at", "price"}."""
    obs = data.get(market, {})
    out = {}
    ref = None          # (period, price) of the last accepted observation
    pending = []        # [(period, price)], oldest first
    for t in periods:
        e = obs.get(t)
        if e is None:
            out[t] = {"decision": "ABSENT", "band": None, "decided_at": t, "price": None}
            continue
        if e["state"] != "OK":
            out[t] = {"decision": e["state"], "band": None, "decided_at": t, "price": None}
            continue
        p = e["price"]
        if ref is None:
            ref = (t, p)
            out[t] = {"decision": "ACCEPTED", "band": "first", "decided_at": t, "price": p}
            continue
        ok_ref, b_ref = passes(m, data, market, *ref, t, p)
        ok_pend, b_pend = passes(m, data, market, *pending[-1], t, p) if pending else (False, None)
        if ok_pend and (not ok_ref or closer(p, pending[-1][1], ref[1])):
            # The newest pending observation is confirmed; the older ones were not.
            for q, _ in pending[:-1]:
                out[q].update(decision="REJECTED_ANOMALY", decided_at=t)
            out[pending[-1][0]].update(decision="ACCEPTED", decided_at=t)
            pending = []
            ref = (t, p)
            out[t] = {"decision": "ACCEPTED", "band": b_pend, "decided_at": t, "price": p}
        elif ok_ref:
            # Back in line with the last accepted price: anything pending was not confirmed.
            for q, _ in pending:
                out[q].update(decision="REJECTED_ANOMALY", decided_at=t)
            pending = []
            ref = (t, p)
            out[t] = {"decision": "ACCEPTED", "band": b_ref, "decided_at": t, "price": p}
        else:
            pending.append((t, p))
            out[t] = {"decision": "PENDING", "band": b_ref, "decided_at": None, "price": p}
    return out


# ------------------------------------------------------------------------------------------------
# Pass 2: the index, in the order its periods become decidable.

MARKET_REASON = [("PENDING", "PENDING_CONFIRMATION", "market_pending"),
                 ("INVALID", "INVALID_INPUT", "market_invalid"),
                 ("DISPUTED", "INVALID_INPUT", "market_disputed"),
                 ("REJECTED_ANOMALY", "INVALID_INPUT", "market_rejected"),
                 ("STALE", "STALE", "market_stale")]


def link(m, level_s, accepted_s, prices_s, accepted_t, prices_t):
    """Level at t chained from s by the weighted mean log relative of the markets valid in both."""
    matched = sorted(set(accepted_s) & set(accepted_t))
    if not matched:
        return None, matched
    num = sum(int(m["markets"][k]) * ln(prices_t[k] * S // prices_s[k]) for k in matched)
    den = sum(int(m["markets"][k]) for k in matched)
    return hdiv(level_s * exp(tdiv(num, den)), S), matched


def run(inp):
    _need(isinstance(inp, dict) and set(inp) == {"methodology", "first", "last", "observations"}, "input_fields")
    m = inp["methodology"]
    check_methodology(m)
    for f in ("first", "last"):
        _need(isinstance(inp[f], str) and PERIOD.match(inp[f]) is not None, f)
    first, last, base = ym_index(inp["first"]), ym_index(inp["last"]), ym_index(m["base_period"])
    _need(first <= base <= last, "period_range")
    _need(isinstance(inp["observations"], list), "observations")
    for o in inp["observations"]:
        check_observation(o)
        _need(first <= ym_index(o["period"]) <= last, "observation_out_of_range")

    data = collect(m, inp["observations"])
    periods = list(range(first, last + 1))
    markets = sorted(m["markets"])
    decisions = {k: decide_market(m, data, k, periods) for k in markets}
    weights = {k: int(m["markets"][k]) for k in markets}
    total_w = sum(weights.values())
    cb = int(m["circuit_breaker_bp"]) if m["circuit_breaker_bp"] is not None else None
    normal = int(m["bands_bp"][0]) if m["bands_bp"] is not None else None

    index_periods = list(range(base, last + 1))

    def accepted_at(t):
        return [k for k in markets if decisions[k][t]["decision"] == "ACCEPTED"]

    def prices_at(t):
        return {k: decisions[k][t]["price"] for k in accepted_at(t)}

    def nonvalid(t):
        ds = [decisions[k][t]["decision"] for k in markets]
        for d, status, reason in MARKET_REASON:
            if d in ds:
                return status, reason
        if all(d == "ABSENT" for d in ds):
            return "UNAVAILABLE", "no_observations"
        return "INSUFFICIENT_COVERAGE", "coverage"

    def record(status, reason, at, level=None, linked_from=None, matched=(), candidate=None):
        return {"status": status, "reason": reason, "level": level, "candidate": candidate,
                "linked_from": linked_from, "matched": list(matched), "decided_at": at}

    # Periods finalize in order: period t is decided once its own markets and every earlier period's
    # markets are decided (`at`). An index-level pending candidate does not block later periods.
    rec, valid, pend, at = {}, [], [], first
    for t in index_periods:
        ds = [decisions[k][t]["decided_at"] for k in markets]
        if at is None or None in ds:
            at = None
            rec[t] = record("PENDING_CONFIRMATION", "market_pending" if None in ds else "earlier_period_pending", None)
            continue
        at = max([at, t] + ds)
        acc = accepted_at(t)
        if t == base:
            if len(acc) == len(markets):
                level = hdiv(sum(weights[k] * decisions[k][t]["price"] for k in markets), total_w)
                rec[t] = record("VALID", "base", at, level)
                valid.append(t)
            else:
                status, reason = nonvalid(t)
                rec[t] = record(status, "base_coverage" if status == "INSUFFICIENT_COVERAGE" else reason, at)
            continue
        if not valid:
            rec[t] = record("UNAVAILABLE", "no_base", at)
            continue
        if not acc or sum(weights[k] for k in acc) * 10000 < int(m["min_coverage_bp"]) * total_w:
            rec[t] = record(*nonvalid(t), at)
            continue
        s = valid[-1]
        level, matched = link(m, rec[s]["level"], accepted_at(s), prices_at(s), acc, prices_at(t))
        if level is None:
            rec[t] = record("INSUFFICIENT_COVERAGE", "no_matched_market", at)
            continue
        ok_ref = cb is None or within(rec[s]["level"], level, cb, t - s)
        ok_pend = False
        if pend:
            p, lvl_p = pend[-1]
            level_p, matched_p = link(m, lvl_p, accepted_at(p), prices_at(p), acc, prices_at(t))
            ok_pend = level_p is not None and within(lvl_p, level_p, normal, t - p)
        if ok_pend and (not ok_ref or closer(level_p, lvl_p, rec[s]["level"])):
            # The newest pending candidate is confirmed; the older ones were not.
            for q, _ in pend[:-1]:
                rec[q].update(status="INVALID_INPUT", reason="circuit_breaker_rejected", candidate=None, decided_at=at)
            rec[p].update(status="VALID", reason="confirmed", level=lvl_p, candidate=None, decided_at=at)
            valid.append(p)
            pend = []
            rec[t] = record("VALID", "linked", at, level_p, p, matched_p)
            valid.append(t)
        elif ok_ref:
            for q, _ in pend:
                rec[q].update(status="INVALID_INPUT", reason="circuit_breaker_rejected", candidate=None, decided_at=at)
            pend = []
            rec[t] = record("VALID", "linked", at, level, s, matched)
            valid.append(t)
        else:
            pend.append((t, level))
            rec[t] = record("PENDING_CONFIRMATION", "circuit_breaker", None, linked_from=s, matched=matched, candidate=level)

    out = []
    for t in index_periods:
        r = rec[t]
        acc = accepted_at(t)
        prev = r["linked_from"]
        comparable = (r["status"] == "VALID" and prev == t - 1 and r["matched"] == acc == accepted_at(prev))
        commits = [c for s in sorted(data) for c in data[s].get(t, {}).get("commitments", [])]
        out.append({
            "period": ym_name(t),
            "status": r["status"],
            "reason": r["reason"],
            "level": str(r["level"]) if r["level"] is not None else None,
            "candidate": str(r["candidate"]) if r["candidate"] is not None else None,
            "coverage_bp": str(sum(weights[k] for k in acc) * 10000 // total_w),
            "accepted": acc,
            "linked_from": ym_name(prev) if prev is not None else None,
            "matched": r["matched"],
            "comparable": comparable,
            "decided_at": ym_name(r["decided_at"]) if r["decided_at"] is not None else None,
            "input_commitment": input_commitment(commits),
            "markets": {k: {
                "decision": decisions[k][t]["decision"],
                "band": decisions[k][t]["band"],
                "price": str(decisions[k][t]["price"]) if decisions[k][t]["price"] is not None else None,
                "decided_at": ym_name(decisions[k][t]["decided_at"]) if decisions[k][t]["decided_at"] is not None else None,
                "observations": data.get(k, {}).get(t, {}).get("commitments", []),
            } for k in markets},
        })
    return {"engine": "GCPI-ENGINE-v1", "methodology": m["id"],
            "methodology_hash": hashlib.sha256(canonical(m).encode()).hexdigest(), "periods": out}


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    with open(argv[1]) as f:
        inp = json.load(f)
    try:
        print(canonical(run(inp)))
    except EngineError as e:
        print(canonical({"error": e.code}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
