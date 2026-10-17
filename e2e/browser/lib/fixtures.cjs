// Fixtures for the browser suite (#46). Every test:
//   - runs in its own evm_snapshot, with the production oracle updater impersonated for price moves;
//   - fails on any pageerror, securitypolicyviolation or console.error it did not declare (guard.allow);
//   - verifies each action on four layers: UI before, the wallet request, the chain (receipt, events,
//     balances read by the suite's own RPC client, the protocol invariants), UI after.
const path = require('node:path');
const base = require('@playwright/test');
const { REPO, RPC_URL, WEB_URL, PAGE_RPC_URL } = require('./env.cjs');
const { Wallet } = require('./wallet.cjs');

const { expect } = base;
// The contract scenario suite's harness: its contracts, invariants and chain controls, unchanged.
const h = require(path.join(REPO, 'e2e/scenarios/lib/harness.cjs'));
const { ethers } = h;

const test = base.test.extend({
  chain: [async ({}, use) => {
    const snap = await h.rpc('evm_snapshot');
    await h.rpc('anvil_impersonateAccount', [h.OWNER]);
    h.invariants.expected.registry = { ...h.manifest.contracts };
    try {
      await use(h);
    } finally {
      await h.rpc('anvil_stopImpersonatingAccount', [h.OWNER]);
      // A test that fails mid-flow can leave the page's transaction pending. Reverting keeps it in the
      // pool with a nonce from the future, and every later transaction from that account queues behind it.
      await h.rpc('anvil_dropAllTransactions');
      await h.rpc('evm_revert', [snap]);
    }
  }, { auto: true }],

  guard: [async ({ page }, use) => {
    const problems = [];
    const allowed = [];
    page.on('pageerror', (e) => problems.push(`pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !allowed.some((re) => re.test(m.text()))) problems.push(`console.error: ${m.text()}`);
    });
    await page.exposeBinding('__copraCsp', (_source, v) => problems.push(`securitypolicyviolation: ${v}`));
    await page.addInitScript(() => {
      document.addEventListener('securitypolicyviolation', (e) => window.__copraCsp(`${e.violatedDirective} blocked ${e.blockedURI}`));
    });
    await use({ allow: (re) => allowed.push(re), problems });
    expect(problems, 'pageerror, CSP violation or unexpected console.error').toEqual([]);
  }, { auto: true }],

  // A wallet with the stack's dev accounts, on the stack's chain. Tests that need another start
  // (no wallet, another chain) install their own with installWallet instead.
  wallet: async ({ installWallet }, use) => {
    await use(await installWallet());
  },

  installWallet: async ({ page }, use, testInfo) => {
    let wallet;
    await use(async (opts = {}) => {
      wallet = await Wallet.install(page, { rpcUrl: RPC_URL, accounts: h.users, chainId: h.manifest.chainId, ...opts });
      return wallet;
    });
    if (wallet && testInfo.status !== testInfo.expectedStatus) {
      await testInfo.attach('wallet-requests.json', { body: JSON.stringify(wallet.requests, null, 2), contentType: 'application/json' });
    }
  },
});

// --- the page, as a user sees it ---
const short = (a) => `${a.slice(0, 6)}...${a.slice(-4)}`;
const fmt = (raw, decimals, min, max) => (Number(raw) / 10 ** decimals).toLocaleString('en-US', { minimumFractionDigits: min, maximumFractionDigits: max });
const show = {
  usdc: (raw) => fmt(raw, 6, 2, 2), // balance bar
  copra: (raw) => fmt(raw, 18, 4, 4), // balance bar
  supply: (raw) => `${fmt(raw, 18, 2, 4)} $COPRA`,
  reserves: (raw) => `$${fmt(raw, 6, 2, 2)} USDC`,
  fees: (raw) => `$${fmt(raw, 6, 4, 4)} USDC`,
  price: (raw8) => `$${(Number(raw8) / 1e8).toFixed(2)} USD / kg`,
};

async function open(page) {
  await page.goto('/');
  await expect(page.locator('#registryVersion')).toHaveText(`· deployment v${h.manifest.registryVersion}`);
  await expect(page.locator('#metricVaultReserves')).not.toHaveText('Loading...');
}

async function connect(page, wallet) {
  await page.click('#connectBtn');
  await expect(page.locator('#connectText')).toHaveText(short(wallet.selected));
  await expect(page.locator('#balanceBar')).toBeVisible();
}

async function setAmount(page, value) {
  const input = page.locator('#amountInput');
  await input.fill('');
  await input.pressSequentially(String(value));
}

/** UI after: every telemetry card, and the user's balances if connected, match the suite's own chain reads. */
async function expectPageMatchesChain(page, user = null) {
  const { contracts: c } = h;
  const [usdc, copra, supply, reserves, fees, [price]] = await Promise.all([
    user ? c.usdc.balanceOf(user) : 0n, user ? c.token.balanceOf(user) : 0n, c.token.totalSupply(),
    c.usdc.balanceOf(c.vault.target), c.vault.accumulatedFees(), c.oracle.getCopraPriceUSD(),
  ]);
  if (user) {
    await expect(page.locator('#usdcBalance')).toHaveText(show.usdc(usdc));
    await expect(page.locator('#copraBalance')).toHaveText(show.copra(copra));
  }
  await expect(page.locator('#metricTotalSupply')).toHaveText(show.supply(supply));
  await expect(page.locator('#metricVaultReserves')).toHaveText(show.reserves(reserves));
  await expect(page.locator('#metricAccumulatedFees')).toHaveText(show.fees(fees));
  await expect(page.locator('#benchmarkHeader')).toHaveText(show.price(price));
}

/**
 * Layers 2 and 3 for the transaction the page just had signed: the wallet was asked to send exactly
 * `fn(args)` to `contract` from `from`, and it was mined, succeeded and left every invariant holding.
 * `args` may be omitted when the test reads them back. Returns the call's args and the receipt's events.
 */
async function expectSent(wallet, { from, contract, fn, args }) {
  const i = wallet.verified ?? 0; // transactions before this one were verified by earlier calls
  await expect.poll(() => wallet.sent.length, { message: `the page sends ${fn}` }).toBeGreaterThan(i);
  const tx = wallet.sent[i];
  wallet.verified = i + 1;
  expect(ethers.getAddress(tx.from)).toBe(ethers.getAddress(from));
  expect(ethers.getAddress(tx.to)).toBe(ethers.getAddress(contract.target));
  const call = contract.interface.parseTransaction({ data: tx.data });
  expect(call.name).toBe(fn);
  if (args) expect(call.args.toArray()).toEqual(args);
  const receipt = await h.provider.waitForTransaction(tx.hash);
  expect(receipt.status, `${fn} succeeded on chain`).toBe(1);
  await h.checkInvariants();
  const events = receipt.logs.filter((l) => ethers.getAddress(l.address) === ethers.getAddress(contract.target))
    .map((l) => contract.interface.parseLog(l));
  return { args: call.args.toArray(), events };
}

/** A base-unit amount as the page shows it: truncated (never rounded up) to `digits` decimals. */
function fixed(raw, decimals, digits) {
  const [whole, frac = ''] = ethers.formatUnits(raw, decimals).split('.');
  return `${whole}.${frac.padEnd(digits, '0').slice(0, digits)}`;
}

/**
 * The mint quote for a USDC budget, from the chain alone: the largest $COPRA amount whose
 * vault.quoteMint fits in it (binary search over eth_call), with that quote's fee.
 */
async function chainMintQuote(usdcRaw) {
  const [price] = await h.contracts.oracle.getCopraPriceUSD();
  let lo = 0n;
  let hi = (usdcRaw * 10n ** 20n) / price + 1n;
  while (lo < hi) {
    const mid = (lo + hi + 1n) / 2n;
    const [required] = await h.contracts.vault.quoteMint(mid);
    if (required <= usdcRaw) lo = mid;
    else hi = mid - 1n;
  }
  const [, fee] = await h.contracts.vault.quoteMint(lo);
  return { copra: lo, fee };
}

const toast = (page) => page.locator('#txStatus');

/**
 * Resolves once the page has finished one of its periodic oracle reads (every 15s), so a test that moves
 * the chain right after has most of an interval before the page could notice on its own.
 */
async function afterTelemetryPoll(page) {
  const selector = h.contracts.oracle.interface.getFunction('getCopraPriceUSD').selector.slice(2);
  const req = await page.waitForRequest((r) => r.url().startsWith(PAGE_RPC_URL) && (r.postData() || '').includes(selector), { timeout: 20_000 });
  await req.response();
}

module.exports = { test, expect, h, ethers, WEB_URL, short, show, open, connect, setAmount, expectPageMatchesChain, expectSent, fixed, chainMintQuote, toast, afterTelemetryPoll };
