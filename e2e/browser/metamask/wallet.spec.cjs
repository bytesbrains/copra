// Tier-2 wallet behaviour (#50): what only a real wallet can show. Rejections clicked in MetaMask's own UI.
const { test, expect, connectFirstTime, confirmInMetaMask, reloadWhenWalletSynced } = require('../lib/metamask-fixtures.cjs');
const mm = require('../lib/metamask.cjs');
const { ethers, open, expectPageMatchesChain, toast } = require('../lib/fixtures.cjs');

const units = (v, d) => ethers.parseUnits(String(v), d);
const rejected = (wallet, method) => wallet.requests.filter((r) => r.method === method && r.error?.code === 4001);

test('rejecting in MetaMask (4001): the connection, an approval and a faucet claim each leave the page usable', async ({ dapp, chain }) => {
  const { page, wallet, metamask } = dapp;
  const user = wallet.selected;
  await open(page);

  // Rejecting the connection itself.
  await page.click('#connectBtn');
  const connect = await mm.nextApproval(metamask.cdp);
  dapp.seen = [connect.route];
  await mm.rejectButton(connect.panel).click();
  await expect(toast(page)).toContainText('Wallet error:');
  await expect(page.locator('#connectText')).toHaveText('Connect Wallet');
  expect(rejected(wallet, 'eth_requestAccounts')).toHaveLength(1);

  // Connecting after all, then rejecting an approval.
  await connectFirstTime(dapp);
  await chain.fundUsdc(user, units(100, 6));
  await reloadWhenWalletSynced(dapp);
  await expect(page.locator('#actionBtnText')).toHaveText('Approve USDC');
  await page.click('#actionBtn');
  await confirmInMetaMask(dapp, { reject: true });
  await expect(toast(page)).toContainText('Transaction error:');
  await expect(page.locator('#actionBtn')).toBeEnabled();
  await expect(page.locator('#actionBtnText')).toHaveText('Approve USDC');

  // And a faucet claim.
  const label = await page.locator('#faucetBtn').innerText();
  await page.click('#faucetBtn');
  await confirmInMetaMask(dapp, { contract: chain.manifest.contracts.usdc, reject: true });
  await expect(toast(page)).toContainText('Faucet error:');
  await expect(page.locator('#faucetBtn')).toBeEnabled();
  await expect(page.locator('#faucetBtn')).toHaveText(label);

  // MetaMask reported each as a user rejection, and nothing reached the chain.
  expect(rejected(wallet, 'eth_sendTransaction')).toHaveLength(2);
  expect(wallet.sent).toEqual([]);
  expect(await chain.contracts.usdc.allowance(user, chain.contracts.vault.target)).toBe(0n);
  await expectPageMatchesChain(page, user);
});
