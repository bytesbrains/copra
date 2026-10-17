// Run with: node --test test/web/
// Loads web/assets/*.js the way the browser does: classic scripts, in index.html's order, in one
// shared global scope, against a minimal fake DOM. Catches what a split of the dApp script can
// break without any single file failing `node --check`: a name declared twice across files (a
// SyntaxError that kills the whole page), a name used at load time before the file declaring it
// has run, a module with load-time side effects, and an event that is no longer wired.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { runPage, localScripts: scriptsIn } = require('./lib/page.cjs');

const WEB = path.join(__dirname, '../../web');
const html = fs.readFileSync(path.join(WEB, 'index.html'), 'utf8');
const localScripts = scriptsIn(html);

function loadPage({ hostname = 'copra.dev', upTo = localScripts.length } = {}) {
  const network = [];
  const failing = () => Promise.reject(new Error('offline'));
  // Every chain call fails, as if the RPC were unreachable: the page must still load.
  const ethers = {
    JsonRpcProvider: function JsonRpcProvider(url) { network.push(url); },
    Contract: function Contract() { return new Proxy({}, { get: () => failing }); },
    isAddress: () => false,
    ZeroAddress: '0x0000000000000000000000000000000000000000',
  };
  const scripts = localScripts.slice(0, upTo)
    .map((file) => ({ file, code: fs.readFileSync(path.join(WEB, 'assets', file), 'utf8') }));
  const page = runPage({ hostname, scripts, ethers, quote: require(path.join(WEB, 'assets/quote.js')) });
  return { ...page, network };
}

test('index.html loads the dApp scripts in dependency order, entry point last', () => {
  const app = ['network.js', 'config.js', 'ui.js', 'chain.js', 'wallet.js', 'app.js'];
  assert.deepEqual(localScripts.filter((f) => app.includes(f)), app);
  assert.equal(localScripts.at(-1), 'app.js');
  assert.ok(localScripts.indexOf('quote.js') < localScripts.indexOf('config.js'));
});

test('every script in web/assets is loaded by index.html, and nothing missing is referenced', () => {
  const onDisk = fs.readdirSync(path.join(WEB, 'assets')).filter((f) => f.endsWith('.js')).sort();
  assert.deepEqual([...localScripts].sort(), onDisk);
});

test('the scripts load together without redeclaration or load-order errors', () => {
  for (const hostname of ['copra.dev', 'testnet.copra.dev']) {
    assert.doesNotThrow(() => loadPage({ hostname }), hostname);
  }
});

test('only app.js has load-time side effects', () => {
  const { network, elements } = loadPage({ hostname: 'testnet.copra.dev', upTo: localScripts.indexOf('app.js') });
  assert.deepEqual(network, [], 'a module started a network read at load');
  for (const [id, el] of elements) {
    assert.deepEqual(el.listeners, {}, `${id} was wired outside app.js`);
    assert.equal(el.classList.set.size, 0, `${id} was themed outside app.js`);
  }
});

test('app.js wires every control and starts the registry and telemetry reads', async () => {
  const { el, network } = loadPage();
  await new Promise((r) => setImmediate(r)); // telemetry waits for the registry read to settle
  const wired = (id, type = 'click') => (el(id).listeners[type] || []).length;
  assert.equal(wired('amountInput', 'input'), 2, 'quote preview + allowance check');
  for (const id of ['tabMint', 'tabRedeem', 'maxBtn', 'watchCopraBtn', 'watchUsdcBtn', 'actionBtn', 'faucetBtn', 'connectBtn']) {
    assert.equal(wired(id), 1, id);
  }
  assert.ok(network.length >= 2, 'registry + telemetry reads');
});

test('the testnet theme follows the hostname', () => {
  assert.ok(loadPage({ hostname: 'testnet.copra.dev' }).el('bodyEl').classList.set.has('testnet-theme'));
  assert.ok(!loadPage({ hostname: 'copra.dev' }).el('bodyEl').classList.set.has('testnet-theme'));
});

test('switching tabs across files updates the shared state and the form', () => {
  const { el, ctx } = loadPage();
  el('tabRedeem').listeners.click[0]();
  assert.equal(vm.runInContext('mode', ctx), 'redeem');
  assert.equal(el('inputLabel').textContent, 'You Burn ($COPRA)');
  assert.equal(el('outputTicker').children[0].textContent, 'USDC');
  el('tabMint').listeners.click[0]();
  assert.equal(el('inputLabel').textContent, 'You Pay (USDC)');
  assert.deepEqual(el('outputTicker').children.map((n) => n.tagName), ['IMG', 'SPAN']);
  assert.notEqual(el('outputAmount').value, '', 'quote preview ran');
});
