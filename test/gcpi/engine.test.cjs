// Run with: node --test test/gcpi/*.test.cjs
// gcpi/engine (#91): the JavaScript engine against every published vector. The vectors' expected bytes
// come from the Python engine, so passing here is the "two independent implementations produce
// byte-identical results" criterion. test_engine.py checks what each vector is meant to show.
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const ENGINE = path.join(__dirname, '../../gcpi/engine');
const engine = require(path.join(ENGINE, 'engine.cjs'));

const VECTORS = path.join(ENGINE, 'vectors');
const load = (name) => JSON.parse(fs.readFileSync(path.join(VECTORS, `${name}.json`), 'utf8'));
const names = fs.readdirSync(VECTORS).filter((f) => f.endsWith('.json') && f !== 'arithmetic.json').map((f) => f.slice(0, -5)).sort();

test('there are vectors to check', () => {
  assert.ok(names.length >= 20, `${names.length} vectors`);
});

for (const name of names) {
  test(`vector ${name}: byte-identical to the Python engine`, () => {
    const v = load(name);
    const out = engine.runSafe(structuredClone(v.input));
    assert.equal(out, engine.canonical(v.expected));
    assert.equal(crypto.createHash('sha256').update(out).digest('hex'), v.expected_sha256);
  });
}

test('ln and exp match the published arithmetic vector', () => {
  const v = load('arithmetic');
  for (const [x, y] of v.ln) assert.equal(String(engine.ln(BigInt(x))), y, `ln(${x})`);
  for (const [m, y] of v.exp) assert.equal(String(engine.exp(BigInt(m))), y, `exp(${m})`);
});

test('the output does not depend on observation order', () => {
  for (const name of ['genuine_shock', 'circuit_breaker', 'disputed_and_duplicate']) {
    const v = load(name);
    const want = engine.runSafe(structuredClone(v.input));
    const reversed = structuredClone(v.input);
    reversed.observations.reverse();
    assert.equal(engine.runSafe(reversed), want, name);
  }
});

test('a trailing newline is not canonical, with the same codes as the Python engine', () => {
  const cases = [
    ['observation_id', (i) => { i.observations[0].market = 'PH\n'; }],
    ['observation_period', (i) => { i.observations[0].period = '2020-01\n'; }],
    ['observation_integer', (i) => { i.observations[0].price = '100\n'; }],
    ['methodology_id', (i) => { i.methodology.id = 'GCPI-test\n'; }],
  ];
  for (const [code, mutate] of cases) {
    const inp = structuredClone(load('normal').input);
    mutate(inp);
    assert.equal(engine.runSafe(inp), engine.canonical({ error: code }), code);
  }
});

test('canonical encoding refuses numbers and non-printable text', () => {
  for (const bad of [1.5, 3, 'café', 'tab\there']) {
    assert.throws(() => engine.canonical({ x: bad }), engine.EngineError);
  }
});

test('the command line prints the canonical output', () => {
  const { execFileSync } = require('node:child_process');
  const file = path.join(VECTORS, 'normal.json');
  const tmp = path.join(require('node:os').tmpdir(), `gcpi-engine-${process.pid}.json`);
  fs.writeFileSync(tmp, JSON.stringify(load('normal').input));
  try {
    const out = execFileSync('node', [path.join(ENGINE, 'engine.cjs'), tmp], { encoding: 'utf8' }).trim();
    assert.equal(out, engine.canonical(JSON.parse(fs.readFileSync(file, 'utf8')).expected));
  } finally {
    fs.rmSync(tmp, { force: true });
  }
});
