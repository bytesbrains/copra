// Tier-2 flows (#50): tier 1's flows (#46) with the real MetaMask extension. Every transaction is
// confirmed in MetaMask's own UI after checking what it shows; the page's request to the wallet, the
// receipt, the events and the invariants are checked exactly as tier 1 does (expectSent).
const { test, expect, confirmInMetaMask, reloadWhenWalletSynced } = require('../lib/metamask-fixtures.cjs');
const { ethers, show, setAmount, expectPageMatchesChain, expectSent, fixed, chainMintQuote, toast } = require('../lib/fixtures.cjs');

const path = require('node:path');
const { REPO } = require('../lib/env.cjs');

const quote = require(path.join(REPO, 'web/assets/quote.js'));
const units = (v, d) => ethers.parseUnits(String(v), d);

test('faucet claim confirmed in MetaMask → balances update, and the button label is restored', async ({ connected, chain }) => {
  const { page, wallet } = connected;
  const user = wallet.selected;
  const label = await page.locator('#faucetBtn').innerText();
  const before = await chain.balances(user);
  await expect(page.locator('#usdcBalance')).toHaveText(show.usdc(before.usdc));

  await page.click('#faucetBtn');
  await expect(page.locator('#faucetBtn')).toBeDisabled();
  await confirmInMetaMask(connected, { contract: chain.manifest.contracts.usdc });
  const { events } = await expectSent(wallet, { from: user, contract: chain.contracts.usdc, fn: 'faucet', args: [user, units(1000, 6)] });
  expect(events.filter((e) => e.name === 'Transfer').map((e) => [e.args.from, e.args.to, e.args.value]))
    .toEqual([[ethers.ZeroAddress, user, units(1000, 6)]]);

  await expect(toast(page)).toContainText('1,000 Testnet USDC successfully claimed');
  await expect(page.locator('#faucetBtn')).toBeEnabled();
  await expect(page.locator('#faucetBtn')).toHaveText(label);
  await expectPageMatchesChain(page, user);
});

test('approve the amount entered, then mint, both confirmed in MetaMask → balances, supply, reserves and fees update', async ({ connected, chain }) => {
  const { page, wallet } = connected;
  const user = wallet.selected;
  await chain.fundUsdc(user, units(100, 6));
  await reloadWhenWalletSynced(connected);
  await expect(page.locator('#usdcBalance')).toHaveText(show.usdc(units(100, 6)));

  await setAmount(page, '14.20');
  const expected = await chainMintQuote(units('14.20', 6));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(expected.copra, 18, 4));
  await expect(page.locator('#actionBtnText')).toHaveText('Approve USDC');

  await page.click('#actionBtn');
  // The amount entered, never an unlimited allowance (#57): the user sees exactly that in MetaMask.
  await confirmInMetaMask(connected, { spendingCap: { amount: '14.2', spender: chain.manifest.contracts.vault } });
  await expectSent(wallet, { from: user, contract: chain.contracts.usdc, fn: 'approve', args: [chain.contracts.vault.target, units('14.20', 6)] });
  await expect(toast(page)).toContainText('USDC approved');
  await expect(page.locator('#actionBtnText')).toHaveText('Mint $COPRA');

  const before = await chain.balances(user);
  await page.click('#actionBtn');
  await confirmInMetaMask(connected, { contract: chain.manifest.contracts.vault });
  const { events } = await expectSent(wallet, { from: user, contract: chain.contracts.vault, fn: 'mint', args: [expected.copra, expected.required] });
  const minted = events.find((e) => e.name === 'Minted').args;
  expect([minted.user, minted.copraAmount, minted.feePaid, minted.collateralPaid]).toEqual([user, expected.copra, expected.fee, expected.required]);
  const after = await chain.balances(user);
  expect(before.usdc - after.usdc).toBe(expected.required);
  expect(after.copra - before.copra).toBe(expected.copra);

  await expect(toast(page)).toContainText(`Successfully minted ${fixed(expected.copra, 18, 4)} $COPRA`);
  await expectPageMatchesChain(page, user);
});

test('redeem confirmed in MetaMask → balances update; the telemetry cards match on-chain values', async ({ connected, chain }) => {
  const { page, wallet } = connected;
  const user = wallet.selected;
  await chain.fundUsdc(user, units(100, 6));
  await chain.mintCopra(user, units(10, 18));
  await reloadWhenWalletSynced(connected);

  await page.click('#tabRedeem');
  await setAmount(page, '4');
  const [toReturn, fee] = await chain.contracts.vault.quoteRedeem(units(4, 18));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(toReturn, 6, 4));
  await expect(page.locator('#actionBtnText')).toHaveText('Redeem USDC');

  const before = await chain.balances(user);
  await page.click('#actionBtn');
  await confirmInMetaMask(connected, { contract: chain.manifest.contracts.vault });
  const { events } = await expectSent(wallet, { from: user, contract: chain.contracts.vault, fn: 'redeem', args: [units(4, 18), toReturn] });
  const redeemed = events.find((e) => e.name === 'Redeemed').args;
  expect([redeemed.user, redeemed.copraAmount, redeemed.collateralReturned, redeemed.feePaid]).toEqual([user, units(4, 18), toReturn, fee]);
  const after = await chain.balances(user);
  expect(after.usdc - before.usdc).toBe(toReturn);
  expect(before.copra - after.copra).toBe(units(4, 18));

  await expect(toast(page)).toContainText('Successfully redeemed');
  await expectPageMatchesChain(page, user);
});

test('MAX in both tabs: the exact balance is approved, minted and redeemed through MetaMask without reverting', async ({ connected, chain }) => {
  const { page, wallet } = connected;
  const user = wallet.selected;
  await chain.fundUsdc(user, 123_456_789n); // awkward, so a rounded display would differ from the exact one
  await reloadWhenWalletSynced(connected);

  await page.click('#maxBtn');
  await expect(page.locator('#amountInput')).toHaveValue(quote.formatUnits(123_456_789n, 6));
  await page.click('#actionBtn');
  await confirmInMetaMask(connected, { spendingCap: { amount: '123.456789', spender: chain.manifest.contracts.vault } });
  await expectSent(wallet, { from: user, contract: chain.contracts.usdc, fn: 'approve', args: [chain.contracts.vault.target, 123_456_789n] });
  await expect(page.locator('#actionBtnText')).toHaveText('Mint $COPRA');
  const expected = await chainMintQuote(123_456_789n);
  await page.click('#actionBtn');
  await confirmInMetaMask(connected, { contract: chain.manifest.contracts.vault });
  await expectSent(wallet, { from: user, contract: chain.contracts.vault, fn: 'mint', args: [expected.copra, expected.required] });
  await expect(toast(page)).toContainText('Successfully minted');
  expect((await chain.balances(user)).usdc).toBe(123_456_789n - expected.required);

  await page.click('#tabRedeem');
  const { copra } = await chain.balances(user);
  await expect(page.locator('#copraBalance')).toHaveText(show.copra(copra));
  await page.click('#maxBtn');
  await expect(page.locator('#amountInput')).toHaveValue(quote.formatUnits(copra, 18));
  await page.click('#actionBtn');
  const [toReturn] = await chain.contracts.vault.quoteRedeem(copra);
  await confirmInMetaMask(connected, { contract: chain.manifest.contracts.vault });
  await expectSent(wallet, { from: user, contract: chain.contracts.vault, fn: 'redeem', args: [copra, toReturn] });
  await expect(toast(page)).toContainText('Successfully redeemed');
  expect((await chain.balances(user)).copra).toBe(0n);
  await expectPageMatchesChain(page, user);
});
