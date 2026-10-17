// Fixtures for tier 2 (#50): every test gets its own MetaMask, onboarded from anvil's mnemonic, and its
// own evm_snapshot. A fresh wallet per test is deliberate: MetaMask keeps nonces and history of its own,
// and a chain rolled back under a long-lived wallet leaves it signing with nonces the chain never saw.
//
// Each action is verified on the same layers as tier 1 (#46), plus the one tier 1 cannot see:
//   UI before → what the page asked the wallet (recorded, not mocked) → what MetaMask showed before the
//   user confirmed → the chain (receipt, events, invariants, via tier 1's expectSent) → UI after.
const base = require('@playwright/test');
const path = require('node:path');
const { REPO, WEB_URL } = require('./env.cjs');
const mm = require('./metamask.cjs');
const { h, short, show, open } = require('./fixtures.cjs');

const { expect } = base;

const test = base.test.extend({
  // The chain, rolled back after the test whatever happens in it.
  chain: [async ({}, use) => {
    const snap = await h.rpc('evm_snapshot');
    h.invariants.expected.registry = { ...h.manifest.contracts };
    for (const a of h.IMPERSONATED) await h.rpc('anvil_impersonateAccount', [a]);
    try {
      await use(h);
    } finally {
      for (const a of h.IMPERSONATED) await h.rpc('anvil_stopImpersonatingAccount', [a]);
      await h.rpc('anvil_dropAllTransactions');
      await h.rpc('evm_revert', [snap]);
    }
  }, { auto: true }],

  // A fresh MetaMask, onboarded, with its side panel open. On failure: the trace, a video, and
  // screenshots of every page and of MetaMask's side panel; the MetaMask version is on every result.
  metamask: async ({}, use, testInfo) => {
    const session = await mm.launch({ videoDir: testInfo.outputPath('video'), baseURL: WEB_URL });
    testInfo.annotations.push({ type: 'metamask', description: mm.version() });
    await session.context.tracing.start({ screenshots: true, snapshots: true });
    try {
      await mm.onboard(session.context, session.extensionId, session.cdp);
      // A function, not the page: a CDP reconnect closes the page objects of the connection before it.
      await use({ ...session, panel: () => mm.sidePanel(session.cdp) });
    } finally {
      const failed = testInfo.status !== testInfo.expectedStatus;
      await session.context.tracing.stop(failed ? { path: testInfo.outputPath('trace.zip') } : undefined);
      if (failed) {
        for (const [i, p] of session.context.pages().entries()) {
          await testInfo.attach(`page-${i}.png`, { body: await p.screenshot().catch(() => Buffer.alloc(0)), contentType: 'image/png' });
        }
        const panel = await mm.sidePanel(session.cdp).catch(() => null);
        if (panel) await testInfo.attach('side-panel.png', { body: await panel.screenshot().catch(() => Buffer.alloc(0)), contentType: 'image/png' });
      }
      await session.cdp.close();
      await session.context.close();
    }
  },

  // The dApp in the MetaMask browser. `wallet.sent` records each eth_sendTransaction the page made and the
  // hash MetaMask returned, in the shape tier 1's expectSent reads. The page fails on any pageerror.
  dapp: async ({ metamask }, use) => {
    const page = await metamask.context.newPage();
    const wallet = { sent: [], requests: [], selected: h.users[0] };
    await page.exposeBinding('__copraWalletRequest', (_src, entry) => {
      wallet.requests.push(entry);
      if (entry.method === 'eth_sendTransaction' && entry.result) wallet.sent.push({ ...entry.params[0], hash: entry.result });
    });
    await page.addInitScript(() => {
      // Observes the page's requests to the wallet; changes nothing about them.
      const wrap = () => {
        const eth = window.ethereum;
        if (!eth || eth.__copraObserved) return;
        const request = eth.request.bind(eth);
        eth.request = async (args) => {
          const t = { start: Date.now() };
          try {
            const result = await request(args);
            window.__copraWalletRequest({ method: args.method, params: args.params, result, ms: Date.now() - t.start, at: t.start });
            return result;
          } catch (e) {
            window.__copraWalletRequest({ method: args.method, params: args.params, error: { code: e.code, message: e.message }, ms: Date.now() - t.start, at: t.start });
            throw e;
          }
        };
        eth.__copraObserved = true;
      };
      // MetaMask's content script may inject the provider after this runs: keep trying until it is there.
      wrap();
      window.addEventListener('ethereum#initialized', wrap, { once: true });
      const timer = setInterval(() => { wrap(); if (window.ethereum?.__copraObserved) clearInterval(timer); }, 20);
    });
    const errors = [];
    page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
    await use({ page, wallet, metamask });
    expect(errors, 'no pageerror').toEqual([]);
  },

  // The dApp connected to MetaMask on the local chain: Connect, approve, let the dApp add the network
  // (MetaMask answers 4902 for it), and connect again after the chainChanged reload.
  connected: async ({ dapp }, use) => {
    await open(dapp.page);
    await connectFirstTime(dapp);
    await use(dapp);
  },
});

/**
 * A first connection, as a new user makes it: Connect, approve in MetaMask, approve adding the network
 * the dApp asks for (MetaMask answers 4902 for it), then connect again after the chainChanged reload.
 */
async function connectFirstTime(dapp) {
  const { page, metamask } = dapp;
  dapp.seen ??= [];
  await page.click('#connectBtn');
  const connect = await mm.nextApproval(metamask.cdp, { seen: dapp.seen });
  dapp.seen.push(connect.route);
  const reloaded = page.waitForEvent('load', { timeout: 90_000 });
  await mm.approveButton(connect.panel).click();
  const addNetwork = await mm.nextApproval(metamask.cdp, { seen: dapp.seen });
  dapp.seen.push(addNetwork.route);
  await mm.approveButton(addNetwork.panel).click();
  await reloaded;
  await open(page);
  await page.click('#connectBtn');
  await expect(page.locator('#connectText')).toHaveText(short(dapp.wallet.selected), { ignoreCase: true });
  await expect(page.locator('#balanceBar')).toBeVisible();
}

/**
 * Waits for MetaMask's next confirmation, checks what it shows (this network, this site and, when given,
 * the contract the transaction goes to, or for an approval the amount and the spender), then confirms or
 * rejects it in MetaMask's own UI.
 */
async function confirmInMetaMask(dapp, { contract, spendingCap, reject = false } = {}) {
  const { panel, route } = await mm.nextApproval(dapp.metamask.cdp, { seen: dapp.seen });
  dapp.seen.push(route);
  if (process.env.METAMASK_DUMP) await dump(panel, route);
  const network = require(path.join(REPO, 'networks/local.json')).chainName;
  await expect(panel.getByTestId('confirmation__details-network-name')).toContainText(network);
  await expect(panel.getByTestId('confirmation__details-origin')).toHaveText(new URL(WEB_URL).host);
  if (contract) {
    const shown = (await panel.getByTestId('transaction-details-recipient-row').innerText()).replace(/\s+/g, ' ');
    expect(shown, 'MetaMask shows the contract the transaction goes to').toContain(contract.slice(0, 7));
    expect(shown).toContain(contract.slice(-5));
  }
  if (spendingCap) {
    // An ERC-20 approval: MetaMask names it, and shows the amount and who may spend it.
    await expect(panel.getByTestId('confirm-title-text')).toHaveText('Spending cap request');
    // MetaMask rounds the amount it shows (123.456789 reads 123.5); its edit dialog holds the exact one.
    await panel.getByTestId('edit-spending-cap-icon').click();
    const input = panel.getByTestId('custom-spending-cap-input');
    await expect(input).toHaveValue(spendingCap.amount);
    // Closed without saving: the approval stays exactly what the page asked for.
    await panel.getByRole('dialog').getByRole('button', { name: 'Cancel' }).click();
    await expect(input).toBeHidden();
    const spender = (await panel.getByTestId('confirmation__approve-spender').innerText()).replace(/\s+/g, ' ');
    expect(spender, 'MetaMask shows the vault as the spender').toContain(spendingCap.spender.slice(0, 7));
    expect(spender).toContain(spendingCap.spender.slice(-5));
  }
  await (reject ? mm.rejectButton(panel) : mm.approveButton(panel)).click();
  return panel;
}

/**
 * After the suite changed the chain behind the wallet's back (funding an account, minting for it): waits
 * until MetaMask returns the chain's balances for the account, then reloads and reconnects. The page reads
 * balances through the wallet, and MetaMask can answer `latest` from before the change for a while, even
 * after it reports a newer block number, so the wait is on the balances themselves.
 */
async function reloadWhenWalletSynced(dapp) {
  const { page, wallet } = dapp;
  const { usdc, copra } = await h.balances(wallet.selected);
  const viaWallet = (token) => page.evaluate(([to, data]) => window.ethereum.request({ method: 'eth_call', params: [{ to, data }, 'latest'] }),
    [token.target, token.interface.encodeFunctionData('balanceOf', [wallet.selected])]).then(BigInt);
  await expect.poll(async () => [await viaWallet(h.contracts.usdc), await viaWallet(h.contracts.token)],
    { message: 'MetaMask returns the chain\'s balances', timeout: 60_000, intervals: [500] }).toEqual([usdc, copra]);
  await open(page);
  await page.click('#connectBtn');
  await expect(page.locator('#connectText')).toHaveText(short(wallet.selected), { ignoreCase: true });
  await expect(page.locator('#usdcBalance')).toHaveText(show.usdc(usdc));
  await expect(page.locator('#copraBalance')).toHaveText(show.copra(copra));
}

/** Debugging aid (METAMASK_DUMP=1): the visible test ids and text of a MetaMask screen. */
async function dump(panel, label) {
  const lines = [`--- ${label}`];
  for (const l of await panel.locator('[data-testid]').all()) {
    if (await l.isVisible().catch(() => false)) {
      lines.push(`  ${await l.getAttribute('data-testid')} :: ${((await l.innerText().catch(() => '')) || '').slice(0, 90).replace(/\s+/g, ' ')}`);
    }
  }
  console.log(lines.join('\n'));
}

module.exports = { test, expect, connectFirstTime, confirmInMetaMask, reloadWhenWalletSynced, dump };
