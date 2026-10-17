// Wallet corner cases (#46): no wallet, wrong or unknown chain, rejections, account and chain changes.
const path = require('node:path');
const { test, expect, ethers, short, show, open, connect, expectPageMatchesChain, expectSent, toast } = require('../lib/fixtures.cjs');
const { REPO, PAGE_RPC_URL } = require('../lib/env.cjs');

const LOCAL = require(path.join(REPO, 'networks/local.json'));
const CHAIN_HEX = '0x' + LOCAL.chainId.toString(16);
const units = (v, d) => ethers.parseUnits(String(v), d);
const REJECTED = 'You rejected the request in your wallet.';

test('no window.ethereum → install-a-wallet toast, and the page still renders read-only', async ({ page }) => {
  await open(page);
  expect(await page.evaluate(() => typeof window.ethereum)).toBe('undefined');
  await expectPageMatchesChain(page);

  for (const button of ['#connectBtn', '#actionBtn']) {
    await page.click(button);
    await expect(toast(page)).toContainText('Please install MetaMask, Coinbase Wallet, or Rabby');
  }
  await expect(page.locator('#connectText')).toHaveText('Connect Wallet');
  await expect(page.locator('#balanceBar')).toBeHidden();
});

test('wrong chain → wallet_switchEthereumChain; the page reloads on chainChanged and then connects', async ({ page, installWallet }) => {
  const wallet = await installWallet({ chainId: 1, knownChains: [1, LOCAL.chainId] });
  await open(page);
  const reloaded = page.waitForEvent('load');
  await page.click('#connectBtn');
  await reloaded;
  expect(wallet.calls('wallet_switchEthereumChain').map((c) => c.params)).toEqual([[{ chainId: CHAIN_HEX }]]);
  expect(wallet.calls('wallet_addEthereumChain')).toEqual([]);
  expect(wallet.chainId).toBe(LOCAL.chainId);

  await open(page);
  await connect(page, wallet);
  expect(wallet.calls('wallet_switchEthereumChain')).toHaveLength(1); // on the right chain, no second switch
});

test('unknown chain (4902) → wallet_addEthereumChain with the right params', async ({ page, installWallet }) => {
  const wallet = await installWallet({ chainId: 1, knownChains: [1] });
  await open(page);
  const reloaded = page.waitForEvent('load');
  await page.click('#connectBtn');
  await reloaded;
  expect(wallet.calls('wallet_switchEthereumChain').map((c) => c.params)).toEqual([[{ chainId: CHAIN_HEX }]]);
  expect(wallet.calls('wallet_addEthereumChain').map((c) => c.params)).toEqual([[{
    chainId: CHAIN_HEX,
    chainName: LOCAL.chainName,
    nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    rpcUrls: [PAGE_RPC_URL],
    blockExplorerUrls: null, // the local chain has no explorer: never another network's
  }]]);
  expect(wallet.chainId).toBe(LOCAL.chainId);

  await open(page);
  await connect(page, wallet);
});

test('user rejects (4001) → error toast, button re-enabled, no stuck "Confirming…"', async ({ page, wallet, chain, guard }) => {
  guard.allow(/^(Wallet|Transaction|Faucet) error:/);
  const user = wallet.selected;
  await chain.fundUsdc(user, units(100, 6));
  await open(page);

  // Rejecting the connection itself.
  wallet.reject.add('eth_requestAccounts');
  await page.click('#connectBtn');
  await expect(toast(page)).toContainText(`Wallet error: ${REJECTED}`);
  await expect(page.locator('#connectText')).toHaveText('Connect Wallet');
  wallet.reject.delete('eth_requestAccounts');
  await connect(page, wallet);

  wallet.reject.add('eth_sendTransaction');
  await expect(page.locator('#actionBtnText')).toHaveText('Approve USDC');
  await page.click('#actionBtn');
  await expect(toast(page)).toContainText(`Transaction error: ${REJECTED}`);
  await expect(page.locator('#actionBtn')).toBeEnabled();
  await expect(page.locator('#actionBtnText')).toHaveText('Approve USDC');

  const label = await page.locator('#faucetBtn').innerText();
  await page.click('#faucetBtn');
  await expect(toast(page)).toContainText(`Faucet error: ${REJECTED}`);
  await expect(page.locator('#faucetBtn')).toBeEnabled();
  await expect(page.locator('#faucetBtn')).toHaveText(label);

  // Nothing reached the chain.
  expect(wallet.sent).toEqual([]);
  expect(await chain.contracts.usdc.allowance(user, chain.contracts.vault.target)).toBe(0n);
  await expectPageMatchesChain(page, user);
});

test('accountsChanged to another account and to none', async ({ page, wallet, chain }) => {
  const [alice, bob] = chain.users;
  await chain.fundUsdc(bob, units(5, 6));
  await open(page);
  await connect(page, wallet);

  await wallet.selectAccount(bob);
  await expect(page.locator('#connectText')).toHaveText(short(bob));
  await expect(page.locator('#usdcBalance')).toHaveText(show.usdc(units(5, 6)));
  // The page signs as the account now selected. It used to keep the first account's signer, which
  // a real wallet refuses (4100), so every transaction after a switch failed.
  await page.click('#faucetBtn');
  await expectSent(wallet, { from: bob, contract: chain.contracts.usdc, fn: 'faucet', args: [bob, units(1000, 6)] });
  await expect(toast(page)).toContainText('successfully claimed');
  await expectPageMatchesChain(page, bob);

  await wallet.selectAccount(null);
  await expect(page.locator('#connectText')).toHaveText('Connect Wallet');
  await expect(page.locator('#balanceBar')).toBeHidden();
  await expect(page.locator('#maxBtn')).toBeHidden();

  // With no account, a click asks the wallet to connect instead of signing for nobody.
  wallet.selected = alice; // what the user picks in the wallet's connect prompt
  const sends = wallet.calls('eth_sendTransaction').length;
  await page.click('#actionBtn');
  await expect(page.locator('#connectText')).toHaveText(short(alice));
  expect(wallet.calls('eth_sendTransaction')).toHaveLength(sends);
});

test('chainChanged reloads the page', async ({ page, wallet }) => {
  await open(page);
  await connect(page, wallet);
  await page.evaluate(() => { window.__beforeReload = true; });
  const reloaded = page.waitForEvent('load');
  await wallet.setChain(LOCAL.chainId);
  await reloaded;
  expect(await page.evaluate(() => window.__beforeReload)).toBeUndefined();
  await open(page);
});
