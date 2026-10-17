// Tier-2 trial (#50): before any suite is written, prove on a GitHub runner that the pinned MetaMask
// loads, onboards from anvil's mnemonic, adds the local network through the dApp, and confirms one real
// transaction end to end. Every approval is clicked in MetaMask's own side panel; the chain is checked
// with the suite's own RPC client, never through the wallet.
const path = require('node:path');
const { test, expect } = require('@playwright/test');
const { REPO, WEB_URL, PAGE_RPC_URL } = require('../lib/env.cjs');
const mm = require('../lib/metamask.cjs');
const h = require(path.join(REPO, 'e2e/scenarios/lib/harness.cjs'));

const ACCOUNT = h.users[0]; // anvil account 0, what MetaMask derives first from the mnemonic
const CHAIN_HEX = '0x' + h.manifest.chainId.toString(16);
const { chainName: CHAIN_NAME } = require(path.join(REPO, 'networks/local.json'));
const usdcShown = (raw) => (Number(raw) / 1e6).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

test('MetaMask: onboard, connect, add the local network, confirm a faucet claim', async ({}, testInfo) => {
  const timings = {};
  const t0 = Date.now();
  const mark = (name) => { timings[name] = Date.now() - t0; };
  // The chain is rolled back whatever fails, including the browser failing to launch or to close.
  const snap = await h.rpc('evm_snapshot');
  try {
    await trial(testInfo, mark, timings);
  } finally {
    await h.rpc('evm_revert', [snap]);
  }
});

async function trial(testInfo, mark, timings) {
  const { context, extensionId, cdp } = await mm.launch({ videoDir: testInfo.outputPath('video') });
  testInfo.annotations.push({ type: 'metamask', description: mm.version() });
  try {
    mark('launched');
    await mm.onboard(context, extensionId, cdp);
    mark('onboarded');

    const dapp = await context.newPage();
    const errors = [];
    dapp.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
    await dapp.goto(WEB_URL);
    await expect(dapp.locator('#registryVersion')).toHaveText(`· deployment v${h.manifest.registryVersion}`);

    // 1. Connect. MetaMask knows no chain 84532, so the dApp's switch gets 4902 and it asks to add the
    // network, with the local RPC; MetaMask then switches to it and the page reloads on chainChanged.
    await dapp.locator('#connectBtn').click();
    const connect = await mm.nextApproval(cdp);
    expect(connect.route).toMatch(/^\/connect\//);
    testInfo.annotations.push({ type: 'approval surface', description: connect.surface });
    console.log(`MetaMask shows approvals in its ${connect.surface}`);
    await expect(connect.panel.getByText('127.0.0.1', { exact: false }).first()).toBeVisible();
    const reloaded = dapp.waitForEvent('load', { timeout: 90_000 });
    await mm.approveButton(connect.panel).click();
    mark('connect approved');

    const addNetwork = await mm.nextApproval(cdp, { seen: [connect.route] });
    await expect(addNetwork.panel.getByText(`Add ${CHAIN_NAME}`)).toBeVisible();
    await mm.approveButton(addNetwork.panel).click();
    await reloaded;
    mark('network added');
    expect(await dapp.evaluate(() => window.ethereum.request({ method: 'eth_chainId' }))).toBe(CHAIN_HEX);
    // The wallet reads the local chain, not a public one: its block number is anvil's.
    const walletBlock = Number(await dapp.evaluate(() => window.ethereum.request({ method: 'eth_blockNumber' })));
    expect(Math.abs(walletBlock - (await h.provider.getBlockNumber()))).toBeLessThanOrEqual(2);

    // 2. Connect again after the reload: already permitted and on the right chain, so no approval.
    await dapp.locator('#connectBtn').click();
    await expect(dapp.locator('#connectText')).toHaveText(`${ACCOUNT.slice(0, 6)}...${ACCOUNT.slice(-4)}`, { ignoreCase: true });
    mark('connected');

    // 3. One real transaction: claim from the TestnetUSDC faucet, confirmed in MetaMask.
    const before = await h.contracts.usdc.balanceOf(ACCOUNT);
    const fromBlock = await h.provider.getBlockNumber();
    await dapp.locator('#faucetBtn').click();
    const confirm = await mm.nextApproval(cdp, { seen: [connect.route, addNetwork.route] });
    expect(confirm.route).toMatch(/^\/confirm-transaction\//);
    // What MetaMask shows before the user confirms: this network, this site, the TestnetUSDC contract.
    await expect(confirm.panel.getByTestId('confirmation__details-network-name')).toContainText(CHAIN_NAME);
    await expect(confirm.panel.getByTestId('confirmation__details-origin')).toHaveText(new URL(WEB_URL).host);
    const shown = (await confirm.panel.getByTestId('transaction-details-recipient-row').innerText()).replace(/\s+/g, ' ');
    expect(shown).toContain(h.manifest.contracts.usdc.slice(0, 7));
    expect(shown).toContain(h.manifest.contracts.usdc.slice(-5));
    await mm.approveButton(confirm.panel).click();
    mark('transaction confirmed');

    // On chain, read by the suite: one successful faucet call from the account, for 1,000 USDC.
    await expect.poll(() => h.contracts.usdc.balanceOf(ACCOUNT), { timeout: 30_000 }).toBe(before + 1_000_000_000n);
    const logs = await h.contracts.usdc.queryFilter(h.contracts.usdc.filters.Transfer(h.ethers.ZeroAddress, ACCOUNT), fromBlock + 1);
    expect(logs).toHaveLength(1);
    const receipt = await h.provider.getTransactionReceipt(logs[0].transactionHash);
    expect(receipt.status).toBe(1);
    expect(receipt.from.toLowerCase()).toBe(ACCOUNT.toLowerCase());
    expect(receipt.to.toLowerCase()).toBe(h.manifest.contracts.usdc.toLowerCase());
    // And the page shows it.
    await expect(dapp.locator('#usdcBalance')).toHaveText(usdcShown(before + 1_000_000_000n));
    mark('mined and shown');
    expect(errors).toEqual([]);
  } catch (e) {
    for (const [i, p] of context.pages().entries()) {
      await testInfo.attach(`page-${i}.png`, { body: await p.screenshot().catch(() => Buffer.alloc(0)), contentType: 'image/png' });
    }
    const panel = await mm.sidePanel(cdp);
    if (panel) await testInfo.attach('side-panel.png', { body: await panel.screenshot().catch(() => Buffer.alloc(0)), contentType: 'image/png' });
    throw e;
  } finally {
    await testInfo.attach('trial.json', {
      body: JSON.stringify({ metamask: mm.version(), rpc: PAGE_RPC_URL, timingsMs: timings }, null, 2),
      contentType: 'application/json',
    });
    console.log(`MetaMask ${mm.version()} trial timings (ms):`, JSON.stringify(timings));
    await cdp.close();
    await context.close();
  }
}
