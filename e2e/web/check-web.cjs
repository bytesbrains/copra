// Checks the dApp served by the stack's `web` service (#43), from outside, over HTTP:
//   1. what is served is the shipped app: every file is byte-for-byte web/, except assets/network.js,
//      which is the `local` build's;
//   2. the headers are web/_headers' own, enforced, with only connect-src naming the local RPC;
//   3. the served scripts, run against the e2e chain, show the local registry's deployment and read
//      the oracle, supply and reserves from anvil. A holder mints first (in a snapshot, rolled back),
//      so the figures are not just a fresh deployment's zeros.
// The browser itself (CSP enforcement, wallet) is #46; this runs the same scripts in a fake DOM.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { ethers } = require('ethers');

const REPO = path.join(__dirname, '../..');
const env = require(path.join(REPO, 'scripts/web-env.cjs'));
const { runPage, localScripts } = require(path.join(REPO, 'test/web/lib/page.cjs'));

const WEB_URL = process.env.WEB_URL || 'http://127.0.0.1:8787';
const RPC_URL = process.env.RPC_URL || 'http://127.0.0.1:8545';
const manifest = JSON.parse(fs.readFileSync(path.join(process.env.E2E_OUT_DIR || path.join(REPO, 'e2e/.out'), 'deployment.json'), 'utf8'));

const get = async (p) => {
  const res = await fetch(new URL(p, WEB_URL)).catch((e) => {
    throw new Error(`GET ${p}: ${e.cause?.message || e.message} (is the stack's web service up? make e2e-up)`);
  });
  assert.equal(res.status, 200, `GET ${p}: ${res.status}`);
  return { res, body: Buffer.from(await res.arrayBuffer()) };
};

function files(dir, base = dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((d) => {
    const p = path.join(dir, d.name);
    return d.isDirectory() ? files(p, base) : [path.relative(base, p)];
  });
}

async function main() {
  // The served network settings, read the way the page reads them.
  const served = (await get('/assets/network.js')).body.toString();
  const NETWORK = vm.runInNewContext(`${served}; NETWORK`);
  assert.equal(NETWORK.name, 'local', 'served network is local');

  // 1. Every file is the local build of web/, and that build differs from web/ only in network.js.
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'copra-web-'));
  const built = path.join(tmp, 'web');
  let headers;
  try {
    env.build('local', built, { rpcUrl: NETWORK.rpcUrl });
    for (const f of files(built).filter((f) => f !== '_headers')) {
      const { body } = await get('/' + f.split(path.sep).join('/'));
      assert.ok(body.equals(fs.readFileSync(path.join(built, f))), `${f} is not what web-env.cjs builds`);
    }
    console.log(`PASS: ${files(built).length - 1} served files are web/ built for local (RPC ${NETWORK.rpcUrl})`);
    headers = fs.readFileSync(path.join(built, '_headers'), 'utf8');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }

  // 2. Headers: every rule in the build's _headers for /* is served as written.
  const { res } = await get('/');
  const rules = headers.split(/\n(?=\S)/).find((b) => b.startsWith('/*'));
  const want = rules.split('\n').slice(1).filter((l) => l.trim()).map((l) => l.trim().split(/:\s*(.*)/s).slice(0, 2));
  for (const [name, value] of want) assert.equal(res.headers.get(name), value, `header ${name}`);
  assert.equal(res.headers.get('content-security-policy-report-only'), null, 'the CSP is enforced');
  assert.match(res.headers.get('content-security-policy'), new RegExp(`connect-src 'self' ${new URL(NETWORK.rpcUrl).origin};`));
  console.log(`PASS: ${want.length} headers from web/_headers, CSP enforced, connect-src 'self' ${new URL(NETWORK.rpcUrl).origin}`);

  // 3. The served page against the chain. The page's RPC is the host's view of anvil; from inside the
  //    stack it is the chain service, so map that one URL and require every read to use it.
  const chain = new ethers.JsonRpcProvider(RPC_URL, manifest.chainId, { staticNetwork: true });
  const snap = await chain.send('evm_snapshot', []);
  try {
    const holder = manifest.users[0];
    const signer = await chain.getSigner(holder);
    const usdc = new ethers.Contract(manifest.contracts.usdc, ['function faucet(address,uint256)', 'function approve(address,uint256)'], signer);
    const vault = new ethers.Contract(manifest.contracts.vault, ['function mint(uint256,uint256)', 'function quoteMint(uint256) view returns (uint256,uint256)'], signer);
    const amount = ethers.parseUnits('10', 18);
    const [required] = await vault.quoteMint(amount);
    await (await usdc.faucet(holder, required)).wait();
    await (await usdc.approve(vault.target, required)).wait();
    await (await vault.mint(amount, required)).wait();

    const html = (await get('/')).body.toString();
    const scripts = [];
    for (const file of localScripts(html)) scripts.push({ file, code: (await get(`/assets/${file}`)).body.toString() });
    const quote = vm.runInNewContext(`${scripts.find((s) => s.file === 'quote.js').code}; CopraQuote`, { module: undefined });
    const urls = [];
    const pageEthers = {
      ...ethers,
      JsonRpcProvider: function JsonRpcProvider(url) {
        urls.push(url);
        return new ethers.JsonRpcProvider(url === NETWORK.rpcUrl ? RPC_URL : url, NETWORK.chainId, { staticNetwork: true });
      },
    };
    const warnings = [];
    const { el } = runPage({
      hostname: 'localhost', scripts, ethers: pageEthers, quote,
      console: { log() {}, warn: (...a) => warnings.push(a.join(' ')), error: (...a) => warnings.push(a.join(' ')) },
    });
    const deadline = Date.now() + 15000;
    while (!el('metricVaultReserves').textContent && Date.now() < deadline) await new Promise((r) => setTimeout(r, 100));
    assert.ok(el('metricVaultReserves').textContent, `the page showed no reserves within 15s; warnings: ${warnings.join(' | ') || 'none'}`);

    assert.deepEqual(warnings, [], 'the page logged no warnings');
    assert.ok(urls.length >= 2 && urls.every((u) => u === NETWORK.rpcUrl), `every read uses the page's RPC: ${urls}`);
    assert.equal(el('registryVersion').textContent, `· deployment v${manifest.registryVersion}`);
    assert.equal(el('benchmarkHeader').textContent, '$1.42 USD / kg');
    assert.equal(el('metricTotalSupply').textContent, '10.00 $COPRA');
    const reserves = Number(required) / 1e6;
    assert.equal(el('metricVaultReserves').textContent, `$${reserves.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })} USDC`);
    assert.match(el('metricOracleAge').textContent, /^Updated /);
    console.log(`PASS: the served page shows deployment v${manifest.registryVersion}, $1.42, 10.00 $COPRA and ${el('metricVaultReserves').textContent} from anvil`);
  } finally {
    await chain.send('evm_revert', [snap]);
  }
}

main().catch((e) => {
  console.error('FAIL:', e.message);
  process.exit(1);
});
