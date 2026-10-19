#!/usr/bin/env node
// GCPI Phase 3 (#91): the reference engine, JavaScript implementation.
//
// The second, independent implementation of gcpi/ENGINE.md (engine.py is the first). BigInt only: no
// Number takes part in any value the output depends on. Both must produce byte-identical canonical output
// on every vector in vectors/.
//
// Usage: node engine.cjs <input.json>   prints the canonical output
// Node built-ins only.
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');

const WAD = 10n ** 18n;
const S = 10n ** 36n;
const LN2 = 693147180559945309417232121458176568n;
const P_MIN = 10n ** 12n;
const P_MAX = 10n ** 24n;
const MAX_MANTISSA = 10n ** 30n;
const MAX_EXP = 18n;
const UNIT_KG = { kg: 1n, quintal: 100n, t: 1000n };
const BANDS = ['normal', 'corroborate', 'confirm', 'quarantine'];
const SECONDS_PER_DAY = 86400n;

const PERIOD = /^[0-9]{4}-(0[1-9]|1[0-2])$/;
const UINT = /^(0|[1-9][0-9]*)$/;
const HEX32 = /^[0-9a-f]{64}$/;
const ID = /^[A-Za-z0-9_.-]{1,64}$/;
const CODE = /^[A-Z]{3}$/;

class EngineError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function need(cond, code) {
  if (!cond) throw new EngineError(code);
}

// ---------------------------------------------------------------------------------------------------
// Integer helpers. BigInt `/` already rounds toward zero.

const abs = (x) => (x < 0n ? -x : x);
const sign = (x) => (x > 0n ? 1n : x < 0n ? -1n : 0n);
const hdiv = (a, b) => (2n * a + b) / (2n * b);

function ln(x) {
  let k = 0n;
  while (x >= 2n * S) {
    x /= 2n;
    k += 1n;
  }
  while (x < S) {
    x *= 2n;
    k -= 1n;
  }
  const z = ((x - S) * S) / (x + S);
  const z2 = (z * z) / S;
  let total = z;
  let power = z;
  for (let n = 3n; ; n += 2n) {
    power = (power * z2) / S;
    const term = power / n;
    if (term === 0n) break;
    total += term;
  }
  return 2n * total + k * LN2;
}

function exp(m) {
  const k = m / LN2;
  const r = m - k * LN2;
  let total = S;
  let term = S;
  for (let n = 1n; ; n += 1n) {
    term = (term * r) / (n * S);
    if (term === 0n) break;
    total += term;
  }
  return k >= 0n ? total << k : total >> -k;
}

const ymIndex = (ym) => Number(ym.slice(0, 4)) * 12 + Number(ym.slice(5)) - 1;
const ymName = (i) => `${String(Math.floor(i / 12)).padStart(4, '0')}-${String((i % 12) + 1).padStart(2, '0')}`;

// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
function daysFromCivil(y, m, d) {
  y -= m <= 2 ? 1 : 0;
  const era = Math.floor(y / 400);
  const yoe = y - era * 400;
  const doy = Math.floor((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return BigInt(era * 146097 + doe - 719468);
}

const periodStart = (i) => daysFromCivil(Math.floor(i / 12), (i % 12) + 1, 1) * SECONDS_PER_DAY;

// ---------------------------------------------------------------------------------------------------
// Canonical encoding.

function canonical(v) {
  if (v === null || v === true || v === false) return JSON.stringify(v);
  if (typeof v === 'string') {
    // Printable ASCII only, so that the only escapes are \" and \\, which every JSON encoder agrees on.
    need(/^[\x20-\x7e]*$/.test(v), 'non_ascii');
    return JSON.stringify(v);
  }
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (typeof v === 'object') {
    const keys = Object.keys(v).sort(); // ASCII keys: UTF-16 order equals code point order
    return `{${keys.map((k) => `${canonical(k)}:${canonical(v[k])}`).join(',')}}`;
  }
  throw new EngineError('non_canonical_value');
}

const OBS_FIELDS = ['market', 'period', 'source', 'price', 'price_exp', 'currency', 'unit', 'fx', 'fx_exp',
  'fx_source', 'published', 'record', 'basis'];
const INT_FIELDS = new Set(['price', 'price_exp', 'fx', 'fx_exp', 'published']);

function str(s) {
  const b = Buffer.from(s, 'ascii');
  const len = Buffer.alloc(4);
  len.writeUInt32BE(b.length);
  return Buffer.concat([len, b]);
}

function uint(n) {
  return Buffer.from(n.toString(16).padStart(64, '0'), 'hex');
}

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

function commitment(o) {
  const parts = [str('GCPI-OBS-v1')];
  for (const f of OBS_FIELDS) {
    parts.push(INT_FIELDS.has(f) && o[f] !== '' ? uint(BigInt(o[f])) : str(o[f]));
  }
  return sha256(Buffer.concat(parts));
}

function inputCommitment(commitments) {
  const parts = [str('GCPI-INPUT-v1'), uint(BigInt(commitments.length))];
  for (const c of [...commitments].sort()) parts.push(Buffer.from(c, 'hex'));
  return sha256(Buffer.concat(parts));
}

// ---------------------------------------------------------------------------------------------------
// Input checking.

const isUint = (v) => typeof v === 'string' && UINT.test(v);
const sameKeys = (o, keys) => {
  const a = Object.keys(o).sort();
  const b = [...keys].sort();
  return a.length === b.length && a.every((k, i) => k === b[i]);
};
const isObject = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);

function checkMethodology(m) {
  need(isObject(m), 'methodology');
  need(typeof m.id === 'string' && ID.test(m.id), 'methodology_id');
  const markets = m.markets;
  need(isObject(markets) && Object.keys(markets).length > 0, 'markets');
  for (const [k, w] of Object.entries(markets)) need(ID.test(k) && isUint(w) && BigInt(w) > 0n, 'market_weight');
  const signals = m.signals;
  need(Array.isArray(signals) && signals.every((s) => typeof s === 'string' && ID.test(s)), 'signals');
  need(new Set(signals).size === signals.length && !signals.some((s) => s in markets), 'signals');
  const corr = m.corroborators;
  need(isObject(corr) && Object.keys(corr).every((k) => k in markets), 'corroborators');
  for (const [k, cs] of Object.entries(corr)) {
    need(Array.isArray(cs) && cs.every((c) => c in markets || signals.includes(c)) && !cs.includes(k)
      && new Set(cs).size === cs.length, 'corroborators');
  }
  for (const f of ['min_coverage_bp', 'max_publication_lag_days']) need(isUint(m[f]), f);
  need(BigInt(m.min_coverage_bp) <= 10000n, 'min_coverage_bp');
  const bands = m.bands_bp;
  need(bands === null || (Array.isArray(bands) && bands.length === 3 && bands.every(isUint)
    && 0n < BigInt(bands[0]) && BigInt(bands[0]) < BigInt(bands[1]) && BigInt(bands[1]) < BigInt(bands[2])), 'bands_bp');
  const cb = m.circuit_breaker_bp;
  need(cb === null || (isUint(cb) && BigInt(cb) > 0n && bands !== null), 'circuit_breaker_bp');
  need(typeof m.base_period === 'string' && PERIOD.test(m.base_period), 'base_period');
  need(sameKeys(m, ['id', 'markets', 'signals', 'corroborators', 'min_coverage_bp', 'max_publication_lag_days',
    'bands_bp', 'circuit_breaker_bp', 'base_period']), 'methodology_fields');
}

function checkObservation(o) {
  need(isObject(o) && sameKeys(o, OBS_FIELDS), 'observation_fields');
  need(OBS_FIELDS.every((f) => typeof o[f] === 'string'), 'observation_types');
  for (const f of ['market', 'source', 'fx_source', 'basis']) need(o[f] === '' || ID.test(o[f]), 'observation_id');
  need(ID.test(o.market), 'observation_id');
  need(PERIOD.test(o.period), 'observation_period');
  for (const f of INT_FIELDS) need(UINT.test(o[f]) || ((f === 'fx' || f === 'fx_exp') && o[f] === ''), 'observation_integer');
  need((o.fx === '') === (o.fx_exp === ''), 'observation_fx');
  need(HEX32.test(o.record), 'observation_record');
  need(CODE.test(o.currency), 'observation_currency');
}

// [price at WAD or null, reason or null]
function normalize(o, lagDays) {
  const price = BigInt(o.price);
  const pexp = BigInt(o.price_exp);
  if (!Object.prototype.hasOwnProperty.call(UNIT_KG, o.unit)) return [null, 'unit'];
  if (price === 0n || price >= MAX_MANTISSA || pexp > MAX_EXP) return [null, 'price_range'];
  let fx = 1n;
  let fexp = 0n;
  if (o.currency === 'USD') {
    if (o.fx !== '') return [null, 'fx_unexpected'];
  } else {
    if (o.fx === '') return [null, 'fx_missing'];
    fx = BigInt(o.fx);
    fexp = BigInt(o.fx_exp);
    if (fx === 0n || fx >= MAX_MANTISSA || fexp > MAX_EXP) return [null, 'fx_range'];
  }
  const p = hdiv(price * WAD * 10n ** fexp, 10n ** pexp * UNIT_KG[o.unit] * fx);
  if (p < P_MIN || p > P_MAX) return [null, 'price_range'];
  const t = ymIndex(o.period);
  const published = BigInt(o.published);
  if (published < periodStart(t)) return [null, 'published_early'];
  if (published > periodStart(t + 1) + BigInt(lagDays) * SECONDS_PER_DAY) return [p, 'stale'];
  return [p, null];
}

// ---------------------------------------------------------------------------------------------------
// Bands. thr in basis points; thresholds scale by the square root of the periods elapsed, k.

function within(pRef, pNew, thr, k) {
  const d = abs(pNew - pRef) * 10000n;
  return d * d <= thr * thr * BigInt(k) * pRef * pRef;
}

// |v - a| / a < |v - b| / b, exactly. A tie is false.
const closer = (v, a, b) => abs(v - a) * b < abs(v - b) * a;

function band(pRef, pNew, bands, k) {
  for (let i = 0; i < 3; i++) if (within(pRef, pNew, bands[i], k)) return BANDS[i];
  return BANDS[3];
}

// ---------------------------------------------------------------------------------------------------
// Pass 1.

function collect(m, observations) {
  const lag = m.max_publication_lag_days;
  const series = new Set([...Object.keys(m.markets), ...m.signals]);
  const raw = new Map();
  for (const o of observations) {
    if (!series.has(o.market)) continue;
    if (!raw.has(o.market)) raw.set(o.market, new Map());
    const byPeriod = raw.get(o.market);
    const t = ymIndex(o.period);
    if (!byPeriod.has(t)) byPeriod.set(t, new Map());
    byPeriod.get(t).set(commitment(o), o);
  }
  const out = {};
  for (const [s, periods] of raw) {
    out[s] = new Map();
    for (const [t, obs] of periods) {
      const results = [...obs].map(([c, o]) => [c, ...normalize(o, lag), o.basis]);
      const usable = results.filter((r) => r[2] === null);
      const stale = results.filter((r) => r[2] === 'stale');
      const entry = { commitments: [...obs.keys()].sort() };
      if (usable.length) {
        const values = new Set(usable.map((r) => `${r[1]}|${r[3]}`));
        if (values.size > 1) Object.assign(entry, { state: 'DISPUTED', price: null, basis: null });
        else Object.assign(entry, { state: 'OK', price: usable[0][1], basis: usable[0][3] });
      } else if (stale.length) {
        Object.assign(entry, { state: 'STALE', price: null, basis: null });
      } else {
        Object.assign(entry, { state: 'INVALID', price: null, basis: null });
      }
      out[s].set(t, entry);
    }
  }
  return out;
}

function corroborated(m, data, market, a, t, direction, strong) {
  for (const c of m.corroborators[market] || []) {
    const ea = data[c] && data[c].get(a);
    const et = data[c] && data[c].get(t);
    if (!ea || !et || ea.state !== 'OK' || et.state !== 'OK' || ea.basis !== et.basis) continue;
    if (direction === 0n || sign(et.price - ea.price) !== direction) continue;
    if (strong && within(ea.price, et.price, BigInt(m.bands_bp[0]), t - a)) continue;
    return true;
  }
  return false;
}

function passes(m, data, market, refT, refP, t, p) {
  if (m.bands_bp === null) return [true, null];
  const b = band(refP, p, m.bands_bp.map(BigInt), t - refT);
  if (b === 'normal') return [true, b];
  if (b === 'quarantine') return [false, b];
  return [corroborated(m, data, market, refT, t, sign(p - refP), b === 'confirm'), b];
}

function decideMarket(m, data, market, periods) {
  const obs = data[market] || new Map();
  const out = new Map();
  let ref = null;
  let pending = [];
  for (const t of periods) {
    const e = obs.get(t);
    if (!e) {
      out.set(t, { decision: 'ABSENT', band: null, decidedAt: t, price: null });
      continue;
    }
    if (e.state !== 'OK') {
      out.set(t, { decision: e.state, band: null, decidedAt: t, price: null });
      continue;
    }
    const p = e.price;
    if (ref === null) {
      ref = [t, p];
      out.set(t, { decision: 'ACCEPTED', band: 'first', decidedAt: t, price: p });
      continue;
    }
    const [okRef, bRef] = passes(m, data, market, ref[0], ref[1], t, p);
    const last = pending.length ? pending[pending.length - 1] : null;
    const [okPend, bPend] = last ? passes(m, data, market, last[0], last[1], t, p) : [false, null];
    if (okPend && (!okRef || closer(p, last[1], ref[1]))) {
      // The newest pending observation is confirmed; the older ones were not.
      for (const [q] of pending.slice(0, -1)) Object.assign(out.get(q), { decision: 'REJECTED_ANOMALY', decidedAt: t });
      Object.assign(out.get(last[0]), { decision: 'ACCEPTED', decidedAt: t });
      pending = [];
      ref = [t, p];
      out.set(t, { decision: 'ACCEPTED', band: bPend, decidedAt: t, price: p });
    } else if (okRef) {
      // Back in line with the last accepted price: anything pending was not confirmed.
      for (const [q] of pending) Object.assign(out.get(q), { decision: 'REJECTED_ANOMALY', decidedAt: t });
      pending = [];
      ref = [t, p];
      out.set(t, { decision: 'ACCEPTED', band: bRef, decidedAt: t, price: p });
    } else {
      pending.push([t, p]);
      out.set(t, { decision: 'PENDING', band: bRef, decidedAt: null, price: p });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------
// Pass 2.

const MARKET_REASON = [['PENDING', 'PENDING_CONFIRMATION', 'market_pending'],
  ['INVALID', 'INVALID_INPUT', 'market_invalid'],
  ['DISPUTED', 'INVALID_INPUT', 'market_disputed'],
  ['REJECTED_ANOMALY', 'INVALID_INPUT', 'market_rejected'],
  ['STALE', 'STALE', 'market_stale']];

function link(weights, levelS, pricesS, pricesT) {
  const matched = Object.keys(pricesS).filter((k) => k in pricesT).sort();
  if (!matched.length) return [null, matched];
  let num = 0n;
  let den = 0n;
  for (const k of matched) {
    num += weights[k] * ln((pricesT[k] * S) / pricesS[k]);
    den += weights[k];
  }
  return [hdiv(levelS * exp(num / den), S), matched];
}

function run(inp) {
  need(isObject(inp) && sameKeys(inp, ['methodology', 'first', 'last', 'observations']), 'input_fields');
  const m = inp.methodology;
  checkMethodology(m);
  for (const f of ['first', 'last']) need(typeof inp[f] === 'string' && PERIOD.test(inp[f]), f);
  const first = ymIndex(inp.first);
  const last = ymIndex(inp.last);
  const base = ymIndex(m.base_period);
  need(first <= base && base <= last, 'period_range');
  need(Array.isArray(inp.observations), 'observations');
  for (const o of inp.observations) {
    checkObservation(o);
    const t = ymIndex(o.period);
    need(first <= t && t <= last, 'observation_out_of_range');
  }

  const data = collect(m, inp.observations);
  const periods = [];
  for (let t = first; t <= last; t++) periods.push(t);
  const markets = Object.keys(m.markets).sort();
  const decisions = {};
  for (const k of markets) decisions[k] = decideMarket(m, data, k, periods);
  const weights = {};
  for (const k of markets) weights[k] = BigInt(m.markets[k]);
  const totalW = markets.reduce((a, k) => a + weights[k], 0n);
  const cb = m.circuit_breaker_bp === null ? null : BigInt(m.circuit_breaker_bp);
  const normal = m.bands_bp === null ? null : BigInt(m.bands_bp[0]);

  const acceptedAt = (t) => markets.filter((k) => decisions[k].get(t).decision === 'ACCEPTED');
  const pricesAt = (t) => Object.fromEntries(acceptedAt(t).map((k) => [k, decisions[k].get(t).price]));
  const nonvalid = (t) => {
    const ds = markets.map((k) => decisions[k].get(t).decision);
    for (const [d, status, reason] of MARKET_REASON) if (ds.includes(d)) return [status, reason];
    if (ds.every((d) => d === 'ABSENT')) return ['UNAVAILABLE', 'no_observations'];
    return ['INSUFFICIENT_COVERAGE', 'coverage'];
  };
  const record = (status, reason, at, level = null, linkedFrom = null, matched = [], candidate = null) =>
    ({ status, reason, level, candidate, linkedFrom, matched: [...matched], decidedAt: at });

  const rec = new Map();
  const valid = [];
  let pend = [];
  let at = first;
  for (let t = base; t <= last; t++) {
    const ds = markets.map((k) => decisions[k].get(t).decidedAt);
    if (at === null || ds.includes(null)) {
      at = null;
      rec.set(t, record('PENDING_CONFIRMATION', ds.includes(null) ? 'market_pending' : 'earlier_period_pending', null));
      continue;
    }
    at = Math.max(at, t, ...ds);
    const acc = acceptedAt(t);
    if (t === base) {
      if (acc.length === markets.length) {
        const level = hdiv(markets.reduce((a, k) => a + weights[k] * decisions[k].get(t).price, 0n), totalW);
        rec.set(t, record('VALID', 'base', at, level));
        valid.push(t);
      } else {
        const [status, reason] = nonvalid(t);
        rec.set(t, record(status, status === 'INSUFFICIENT_COVERAGE' ? 'base_coverage' : reason, at));
      }
      continue;
    }
    if (!valid.length) {
      rec.set(t, record('UNAVAILABLE', 'no_base', at));
      continue;
    }
    const covered = acc.reduce((a, k) => a + weights[k], 0n);
    if (!acc.length || covered * 10000n < BigInt(m.min_coverage_bp) * totalW) {
      const [status, reason] = nonvalid(t);
      rec.set(t, record(status, reason, at));
      continue;
    }
    const s = valid[valid.length - 1];
    const levelS = rec.get(s).level;
    const [level, matched] = link(weights, levelS, pricesAt(s), pricesAt(t));
    if (level === null) {
      rec.set(t, record('INSUFFICIENT_COVERAGE', 'no_matched_market', at));
      continue;
    }
    const okRef = cb === null || within(levelS, level, cb, t - s);
    const lastPend = pend.length ? pend[pend.length - 1] : null;
    let okPend = false;
    let levelP = null;
    let matchedP = [];
    if (lastPend) {
      [levelP, matchedP] = link(weights, lastPend[1], pricesAt(lastPend[0]), pricesAt(t));
      okPend = levelP !== null && within(lastPend[1], levelP, normal, t - lastPend[0]);
    }
    if (okPend && (!okRef || closer(levelP, lastPend[1], levelS))) {
      // The newest pending candidate is confirmed; the older ones were not.
      const [p, lvlP] = lastPend;
      for (const [q] of pend.slice(0, -1)) {
        Object.assign(rec.get(q), { status: 'INVALID_INPUT', reason: 'circuit_breaker_rejected', candidate: null, decidedAt: at });
      }
      Object.assign(rec.get(p), { status: 'VALID', reason: 'confirmed', level: lvlP, candidate: null, decidedAt: at });
      valid.push(p);
      pend = [];
      rec.set(t, record('VALID', 'linked', at, levelP, p, matchedP));
      valid.push(t);
    } else if (okRef) {
      for (const [q] of pend) {
        Object.assign(rec.get(q), { status: 'INVALID_INPUT', reason: 'circuit_breaker_rejected', candidate: null, decidedAt: at });
      }
      pend = [];
      rec.set(t, record('VALID', 'linked', at, level, s, matched));
      valid.push(t);
    } else {
      pend.push([t, level]);
      rec.set(t, record('PENDING_CONFIRMATION', 'circuit_breaker', null, null, s, matched, level));
    }
  }

  const sameList = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
  const opt = (v) => (v === null ? null : String(v));
  const optYm = (v) => (v === null ? null : ymName(v));
  const series = Object.keys(data).sort();
  const out = [];
  for (let t = base; t <= last; t++) {
    const r = rec.get(t);
    const acc = acceptedAt(t);
    const prev = r.linkedFrom;
    const comparable = r.status === 'VALID' && prev === t - 1 && sameList(r.matched, acc) && sameList(acc, acceptedAt(prev));
    const commits = series.flatMap((s) => (data[s].has(t) ? data[s].get(t).commitments : []));
    const mk = {};
    for (const k of markets) {
      const d = decisions[k].get(t);
      mk[k] = {
        decision: d.decision,
        band: d.band,
        price: opt(d.price),
        decided_at: optYm(d.decidedAt),
        observations: data[k] && data[k].has(t) ? data[k].get(t).commitments : [],
      };
    }
    out.push({
      period: ymName(t),
      status: r.status,
      reason: r.reason,
      level: opt(r.level),
      candidate: opt(r.candidate),
      coverage_bp: String((acc.reduce((a, k) => a + weights[k], 0n) * 10000n) / totalW),
      accepted: acc,
      linked_from: optYm(prev),
      matched: r.matched,
      comparable,
      decided_at: optYm(r.decidedAt),
      input_commitment: inputCommitment(commits),
      markets: mk,
    });
  }
  return { engine: 'GCPI-ENGINE-v1', methodology: m.id, methodology_hash: sha256(canonical(m)), periods: out };
}

function runSafe(inp) {
  try {
    return canonical(run(inp));
  } catch (e) {
    if (e instanceof EngineError) return canonical({ error: e.code });
    throw e;
  }
}

module.exports = { run, runSafe, canonical, commitment, ln, exp, S, LN2, WAD, EngineError };

if (require.main === module) {
  if (process.argv.length !== 3) {
    process.stderr.write('Usage: node engine.cjs <input.json>\n');
    process.exit(2);
  }
  process.stdout.write(`${runSafe(JSON.parse(fs.readFileSync(process.argv[2], 'utf8')))}\n`);
}
