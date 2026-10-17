// The dApp's flows (#46), each verified on every layer: UI before → wallet request → chain → UI after.
const { execFile } = require('node:child_process');
const path = require('node:path');
const { promisify } = require('node:util');
const {
  test, expect, h, ethers, WEB_URL, show, open, connect, setAmount, expectPageMatchesChain, expectSent, fixed,
  chainMintQuote, toast,
} = require('../lib/fixtures.cjs');
const { REPO, RPC_URL } = require('../lib/env.cjs');

const quote = require(path.join(REPO, 'web/assets/quote.js'));
const units = (v, d) => ethers.parseUnits(String(v), d);

/** Runs the real feeder, which resolves the oracle through the registry and signs as the impersonated updater. */
async function feed(chain, price) {
  const { stdout } = await promisify(execFile)('bash', [path.join(REPO, 'scripts/oracle-feeder.sh')], {
    // Only what the feeder needs, named: a developer's own ORACLE_FEEDER_KEY or COPRA_ORACLE_ADDRESS must
    // not leak in, and the registry is this stack's, not the script's default that happens to match it.
    env: {
      PATH: process.env.PATH, HOME: process.env.HOME || '/tmp', CI: '1', BASE_SEPOLIA_RPC: RPC_URL,
      COPRA_REGISTRY_ADDRESS: chain.manifest.contracts.registry, ORACLE_FEEDER_FROM: chain.UPDATER, TARGET_PRICE: price,
    },
  });
  return stdout;
}

test('connect → faucet claim → balances update, and the button label is restored', async ({ page, wallet, chain }) => {
  const user = wallet.selected;
  await open(page);
  const label = await page.locator('#faucetBtn').innerText();
  await connect(page, wallet);
  const before = await chain.balances(user);
  await expect(page.locator('#usdcBalance')).toHaveText(show.usdc(before.usdc));

  await page.click('#faucetBtn');
  await expect(page.locator('#faucetBtn')).toBeDisabled();
  // Pending: with 2s blocks the page really waits, and says so.
  await expect(toast(page)).toContainText('Waiting for confirmation');
  const { events } = await expectSent(wallet, { from: user, contract: chain.contracts.usdc, fn: 'faucet', args: [user, units(1000, 6)] });
  const transfers = events.filter((e) => e.name === 'Transfer').map((e) => [e.args.from, e.args.to, e.args.value]);
  expect(transfers).toEqual([[ethers.ZeroAddress, user, units(1000, 6)]]);
  expect((await chain.balances(user)).usdc).toBe(before.usdc + units(1000, 6));

  await expect(toast(page)).toContainText('1,000 Testnet USDC successfully claimed');
  await expect(page.locator('#faucetBtn')).toBeEnabled();
  await expect(page.locator('#faucetBtn')).toHaveText(label);
  await expectPageMatchesChain(page, user);
});

test('approve (first mint) → button becomes "Mint $COPRA" → mint → balances, supply, reserves and fees update', async ({ page, wallet, chain }) => {
  const user = wallet.selected;
  await chain.fundUsdc(user, units(100, 6));
  await open(page);
  await connect(page, wallet);

  // UI before: the quote for 14.20 USDC is the chain's, and the first step is the approval.
  await setAmount(page, '14.20');
  const expected = await chainMintQuote(units('14.20', 6));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(expected.copra, 18, 4));
  await expect(page.locator('#feeDisplay')).toHaveText(`$${fixed(expected.fee, 6, 4)} USDC`);
  await expect(page.locator('#actionBtnText')).toHaveText('Approve USDC');

  await page.click('#actionBtn');
  // The amount entered, never an unlimited allowance (#57).
  await expectSent(wallet, { from: user, contract: chain.contracts.usdc, fn: 'approve', args: [chain.contracts.vault.target, units('14.20', 6)] });
  expect(await chain.contracts.usdc.allowance(user, chain.contracts.vault.target)).toBe(units('14.20', 6));
  await expect(toast(page)).toContainText('USDC approved');
  await expect(page.locator('#actionBtnText')).toHaveText('Mint $COPRA');
  await expect(page.locator('#actionBtn')).toBeEnabled();

  const before = await chain.balances(user);
  await page.click('#actionBtn');
  await expect(toast(page)).toContainText('Waiting for confirmation');
  // Bounded by the quote on screen: the vault may not charge more than the user saw (#57).
  const { events } = await expectSent(wallet, { from: user, contract: chain.contracts.vault, fn: 'mint', args: [expected.copra, expected.required] });
  const minted = events.find((e) => e.name === 'Minted').args;
  expect([minted.user, minted.copraAmount, minted.feePaid]).toEqual([user, expected.copra, expected.fee]);
  expect(minted.collateralPaid).toBe(expected.required); // the vault's own quote, which fits in 14.20
  const after = await chain.balances(user);
  expect(before.usdc - after.usdc).toBe(minted.collateralPaid);
  expect(after.copra - before.copra).toBe(expected.copra);

  await expect(toast(page)).toContainText(`Successfully minted ${fixed(expected.copra, 18, 4)} $COPRA`);
  // The mint spent the approval but its dust, so the next one asks again.
  expect(await chain.contracts.usdc.allowance(user, chain.contracts.vault.target)).toBe(units('14.20', 6) - expected.required);
  await expect(page.locator('#actionBtnText')).toHaveText('Approve USDC');
  await expectPageMatchesChain(page, user);
});

test('redeem → balances update; the telemetry cards match on-chain values', async ({ page, wallet, chain }) => {
  const user = wallet.selected;
  await chain.fundUsdc(user, units(100, 6));
  await chain.mintCopra(user, units(10, 18));
  await open(page);
  await connect(page, wallet);

  await page.click('#tabRedeem');
  await setAmount(page, '4');
  const [toReturn, fee] = await chain.contracts.vault.quoteRedeem(units(4, 18));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(toReturn, 6, 4));
  await expect(page.locator('#feeDisplay')).toHaveText(`$${fixed(fee, 6, 4)} USDC`);
  await expect(page.locator('#actionBtnText')).toHaveText('Redeem USDC');

  const before = await chain.balances(user);
  await page.click('#actionBtn');
  await expect(toast(page)).toContainText('Waiting for confirmation');
  const { events } = await expectSent(wallet, { from: user, contract: chain.contracts.vault, fn: 'redeem', args: [units(4, 18), toReturn] });
  const redeemed = events.find((e) => e.name === 'Redeemed').args;
  expect([redeemed.user, redeemed.copraAmount, redeemed.collateralReturned, redeemed.feePaid]).toEqual([user, units(4, 18), toReturn, fee]);
  const after = await chain.balances(user);
  expect(after.usdc - before.usdc).toBe(toReturn);
  expect(before.copra - after.copra).toBe(units(4, 18));

  await expect(toast(page)).toContainText('Successfully redeemed');
  await expect(page.locator('#actionBtnText')).toHaveText('Redeem USDC');
  await expectPageMatchesChain(page, user);
});

test('MAX fills the exact balance in both tabs, and that amount mints and redeems without reverting', async ({ page, wallet, chain }) => {
  const user = wallet.selected;
  // An awkward balance, so a rounded display would differ from the exact one.
  await chain.fundUsdc(user, 123_456_789n);
  await open(page);
  await connect(page, wallet);

  await page.click('#maxBtn');
  await expect(page.locator('#amountInput')).toHaveValue(quote.formatUnits(123_456_789n, 6)); // 123.456789
  await page.click('#actionBtn'); // approve
  await expectSent(wallet, { from: user, contract: chain.contracts.usdc, fn: 'approve', args: [chain.contracts.vault.target, 123_456_789n] });
  await expect(page.locator('#actionBtnText')).toHaveText('Mint $COPRA');
  const expected = await chainMintQuote(123_456_789n);
  await page.click('#actionBtn');
  await expectSent(wallet, { from: user, contract: chain.contracts.vault, fn: 'mint', args: [expected.copra, expected.required] });
  await expect(toast(page)).toContainText('Successfully minted');
  // Charged exactly the vault's quote for the largest mint that fits: what is left is the change, no more.
  expect((await chain.balances(user)).usdc).toBe(123_456_789n - expected.required);

  await page.click('#tabRedeem');
  const { copra } = await chain.balances(user);
  await expect(page.locator('#copraBalance')).toHaveText(show.copra(copra));
  await page.click('#maxBtn');
  await expect(page.locator('#amountInput')).toHaveValue(quote.formatUnits(copra, 18));
  await page.click('#actionBtn');
  const [toReturn] = await chain.contracts.vault.quoteRedeem(copra);
  await expectSent(wallet, { from: user, contract: chain.contracts.vault, fn: 'redeem', args: [copra, toReturn] });
  await expect(toast(page)).toContainText('Successfully redeemed');
  expect((await chain.balances(user)).copra).toBe(0n);
  await expectPageMatchesChain(page, user);
});

test('Add COPRA / USDC to wallet requests wallet_watchAsset with the right address, decimals and logo', async ({ page, wallet, chain }) => {
  await open(page);
  await connect(page, wallet);

  await page.click('#watchCopraBtn');
  await expect.poll(() => wallet.calls('wallet_watchAsset').length).toBe(1);
  const logo = `${WEB_URL}/assets/copra_logo_128.png`;
  expect(wallet.calls('wallet_watchAsset')[0].params).toEqual({
    type: 'ERC20',
    options: { address: chain.contracts.token.target, symbol: 'COPRA', decimals: 18, image: logo },
  });
  // The logo the wallet will fetch is served, as an image.
  const res = await page.request.get(logo);
  expect(res.status()).toBe(200);
  expect(res.headers()['content-type']).toBe('image/png');

  await page.click('#watchUsdcBtn');
  await expect.poll(() => wallet.calls('wallet_watchAsset').length).toBe(2);
  expect(wallet.calls('wallet_watchAsset')[1].params).toEqual({
    type: 'ERC20',
    options: { address: chain.contracts.usdc.target, symbol: 'USDC', decimals: 6, image: '' },
  });
  // Both are the chain's own: what the registry names, with the decimals the tokens report.
  expect(await chain.contracts.token.decimals()).toBe(18n);
  expect(await chain.contracts.usdc.decimals()).toBe(6n);
});

test('the oracle feeder posts a new price mid-session, and the page\'s quote and benchmark follow', async ({ page, wallet, chain }) => {
  await open(page);
  await connect(page, wallet);
  await expect(page.locator('#benchmarkHeader')).toHaveText('$1.42 USD / kg');

  await chain.warp(Number(await chain.contracts.oracle.MIN_UPDATE_INTERVAL()));
  expect(await feed(chain, '1.50')).toContain('successfully updated');
  const [price] = await chain.contracts.oracle.getCopraPriceUSD();
  expect(price).toBe(150_000_000n);

  // No reload, no click: the page polls, and its benchmark, price and quote move to the chain's.
  await expect(page.locator('#benchmarkHeader')).toHaveText('$1.50 USD / kg', { timeout: 25_000 });
  await expect(page.locator('#oracleDisplay')).toHaveText('$1.50 USD / kg');
  const expected = await chainMintQuote(units('14.20', 6));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(expected.copra, 18, 4));
  await expectPageMatchesChain(page, wallet.selected);
});

test('after a stale spell the feeder recovers the oracle, and the page shows the new price and its age', async ({ page, wallet, chain }) => {
  await chain.warp(Number(await chain.contracts.oracle.HEARTBEAT()) + 1);
  await open(page);
  await connect(page, wallet);
  await expect(page.locator('#benchmarkHeader')).toHaveText('Price stale');

  expect(await feed(chain, '1.45')).toContain('successfully updated');
  await expect(page.locator('#benchmarkHeader')).toHaveText('$1.45 USD / kg', { timeout: 25_000 });
  // The age is the update's, read from the chain: just now, not the stale spell.
  await expect(page.locator('#metricOracleAge')).toHaveText(/^Updated \d+s ago$/);
  const [, updatedAt] = await chain.contracts.oracle.getCopraPriceUSD();
  const shown = new Date(Number(updatedAt) * 1000).toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
  await expect(page.locator('#metricOracleUpdated')).toHaveText(shown);
  const expected = await chainMintQuote(units('14.20', 6));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(expected.copra, 18, 4));
});
