// Run with: node --test test/web/
// Per-environment network settings (#43). web/ is the sepolia build, committed: generating sepolia
// must reproduce it byte for byte, and any other environment may differ from it only in
// assets/network.js and the CSP's connect-src. So the app under test is the app that ships.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const env = require('../../scripts/web-env.cjs');
const { runPage, localScripts } = require('./lib/page.cjs');

const WEB = path.join(__dirname, '../../web');
// mainnet has no registry until #47 deploys one, so no site is built for it yet.
const ENVS = ['sepolia', 'local'];

function files(dir, base = dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((d) => {
    const p = path.join(dir, d.name);
    return d.isDirectory() ? files(p, base) : [path.relative(base, p)];
  }).sort();
}

const built = {};
let tmp;
test.before(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'copra-web-'));
  for (const e of ENVS) {
    built[e] = path.join(tmp, e);
    env.build(e, built[e]);
  }
});
test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

/** Relative paths whose bytes differ between web/ and `dir` (the file sets must match). */
function differing(dir) {
  assert.deepEqual(files(dir), files(WEB), 'same files as web/');
  return files(WEB).filter((f) => !fs.readFileSync(path.join(dir, f)).equals(fs.readFileSync(path.join(WEB, f))));
}

test('sepolia reproduces web/ byte for byte: web/ is the sepolia build', () => {
  assert.deepEqual(differing(built.sepolia), [], 'regenerate web/assets/network.js from networks/sepolia.json');
});

// Today's production values, pinned so a settings change for another environment cannot move them.
test('sepolia settings and headers are what production has served since before #43', () => {
  assert.deepEqual(env.loadNetwork('sepolia'), {
    name: 'sepolia',
    chainId: 84532,
    chainName: 'Base Sepolia',
    rpcUrl: 'https://base-sepolia-rpc.publicnode.com',
    explorer: 'https://sepolia.basescan.org',
    registry: '0x379cB5FED578D6F485ab1834C81E4F1CF4EABb25',
  });
  const csp = fs.readFileSync(path.join(WEB, '_headers'), 'utf8').split('\n').find((l) => l.includes('Content-Security-Policy:'));
  assert.equal(csp.trim(), "Content-Security-Policy: default-src 'self'; script-src 'self' https://cdn.tailwindcss.com https://cdnjs.cloudflare.com https://static.cloudflareinsights.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' https://base-sepolia-rpc.publicnode.com; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
});

for (const e of ['local']) {
  test(`${e} differs from web/ only in network.js and the CSP's connect-src`, () => {
    assert.deepEqual(differing(built[e]), ['_headers', 'assets/network.js']);
    const lines = (dir) => fs.readFileSync(path.join(dir, '_headers'), 'utf8').split('\n');
    const [mine, shipped] = [lines(built[e]), lines(WEB)];
    assert.equal(mine.length, shipped.length);
    const changed = mine.map((l, i) => [l, shipped[i]]).filter(([a, b]) => a !== b);
    assert.equal(changed.length, 1, 'one header line changes');
    const directives = (l) => l.split(';').map((d) => d.trim());
    const [a, b] = changed[0].map(directives);
    const diff = a.filter((d, i) => d !== b[i]);
    const net = env.loadNetwork(e);
    assert.deepEqual(diff, [`connect-src 'self' ${new URL(net.rpcUrl).origin}`]);
  });
}

test('local: the e2e chain, chain id 84532 like the stack, no explorer; --rpc-url follows the host port', () => {
  const net = env.loadNetwork('local');
  assert.equal(net.chainId, 84532);
  assert.equal(net.rpcUrl, 'http://127.0.0.1:8545');
  assert.equal(net.explorer, null);
  assert.equal(env.loadNetwork('local', { rpcUrl: 'http://127.0.0.1:9545' }).rpcUrl, 'http://127.0.0.1:9545');
  assert.throws(() => env.loadNetwork('sepolia', { rpcUrl: 'http://127.0.0.1:9545' }), /local environment only/);
});

test('mainnet: Base (8453) over https, no registry until #47, so no site is built', () => {
  const net = env.loadNetwork('mainnet');
  assert.equal(net.chainId, 8453);
  assert.match(net.rpcUrl, /^https:\/\//);
  assert.match(net.explorer, /^https:\/\//);
  // The Sepolia registry's address has no code on Base: a mainnet page reading it would only fail.
  assert.equal(net.registry, null);
  assert.throws(() => env.build('mainnet', path.join(os.tmpdir(), 'copra-mainnet')), /no CopraRegistry on mainnet/);
});

test('settings are validated: exact keys, https outside local, never written into web/', () => {
  const ok = env.loadNetwork('mainnet');
  assert.doesNotThrow(() => env.validate({ ...ok }));
  assert.throws(() => env.validate({ ...ok, extra: 1 }), /exactly/);
  const { name, ...rest } = ok;
  assert.throws(() => env.validate(rest), /exactly/);
  assert.doesNotThrow(() => env.validate({ ...rest, name }), 'key order does not matter');
  assert.throws(() => env.validate({ ...ok, rpcUrl: 'http://base-rpc.publicnode.com' }), /https/);
  assert.throws(() => env.validate({ ...ok, explorer: 'http://basescan.org' }), /https or null/);
  assert.throws(() => env.validate({ ...ok, registry: '0x1234' }), /registry/);
  assert.throws(() => env.loadNetwork('nowhere'), /no network settings/);
  assert.throws(() => env.build('sepolia', path.join(WEB, 'nested')), /inside web/);
});

// The generated page runs: the scripts load, and CONTRACTS is that environment's network.
for (const e of ENVS) {
  test(`${e}: the generated page loads and uses its network`, () => {
    const dir = built[e];
    const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
    const urls = [];
    const failing = () => Promise.reject(new Error('offline'));
    const scripts = localScripts(html).map((file) => ({ file, code: fs.readFileSync(path.join(dir, 'assets', file), 'utf8') }));
    const { ctx } = runPage({
      hostname: 'localhost',
      scripts,
      quote: require(path.join(dir, 'assets/quote.js')),
      ethers: {
        JsonRpcProvider: function JsonRpcProvider(url) { urls.push(url); },
        Contract: function Contract() { return new Proxy({}, { get: () => failing }); },
        isAddress: () => false,
        ZeroAddress: '0x0000000000000000000000000000000000000000',
      },
    });
    const net = env.loadNetwork(e);
    const contracts = vm.runInContext('CONTRACTS', ctx);
    assert.equal(contracts.chainId, net.chainId);
    assert.equal(contracts.chainIdHex, '0x' + net.chainId.toString(16));
    assert.equal(contracts.rpcUrl, net.rpcUrl);
    assert.equal(contracts.explorer, net.explorer);
    assert.equal(contracts.registry, net.registry);
    assert.ok(urls.length > 0 && urls.every((u) => u === net.rpcUrl), `reads go to ${net.rpcUrl}: ${urls}`);
    // Only Base Sepolia has a fallback set: elsewhere those addresses are not Copra's.
    assert.equal(Boolean(contracts.vault), e === 'sepolia');
  });
}
