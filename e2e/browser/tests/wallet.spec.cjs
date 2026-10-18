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
    await expect(toast(page)).toHaveText(`Please install MetaMask, Coinbase Wallet, or Rabby to interact with Copra Protocol on ${LOCAL.chainName}.`);
  }
  await expect(page.locator('#connectText')).toHaveText('Connect Wallet');
  await expect(page.locator('#balanceBar')).toBeHidden();
});

// #63: index.html ships with Base Sepolia's copy and addresses on every network; the page must render
// this build's own. The local build names its own chain and has no explorer, so it links nowhere.
test('the page names its own network: chain name and id, its own contract addresses, no explorer links, never Base Sepolia', async ({ page, wallet, chain }) => {
  await open(page);
  await expect(page.locator('#networkBadge')).toHaveText(LOCAL.chainName);
  await expect(page.locator('#testnetBar')).toContainText(`${LOCAL.chainName} Testnet Live (Chain ID: ${LOCAL.chainId})`);
  await expect(page.locator('#testnetBar a[data-needs-explorer]')).toBeHidden(); // "View Contracts on …": no explorer here
  await expect(page.locator('main')).toContainText(`${LOCAL.chainName} Contract Registry`);
  for (const [name, address] of Object.entries(chain.manifest.contracts)) {
    const link = page.locator(`a[data-contract="${name}"][data-short]`);
    await expect(link).toHaveText(short(address));
    await expect(link).not.toHaveAttribute('href', /.*/);
  }
  await expect(page.locator('body')).not.toContainText('Sepolia');
  await expect(page.locator('a[href*="basescan"]')).toHaveCount(0);

  // A confirmed transaction's toast offers no explorer link either.
  await connect(page, wallet);
  await page.click('#faucetBtn');
  await expect(toast(page)).toContainText('successfully claimed');
  await expect(toast(page).locator('a')).toHaveCount(0);
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

// #76: closing the wallet's window does not reject a request, so the page can only wait. After 5s it says
// where the answer is expected, and withdraws the hint the moment the request settles.
const WALLET_HINT = 'Waiting for your answer: open your wallet to confirm or reject this request.';

test('a request left unanswered in the wallet → after 5s the page says to open your wallet; the hint goes when it is answered', async ({ page, wallet, chain, guard }) => {
  guard.allow(/^(Wallet|Faucet) error:/);
  const user = wallet.selected;
  await open(page);

  // Connecting, answered after the hint: the hint is withdrawn and the page connects.
  let release = wallet.hold('eth_requestAccounts');
  const clicked = Date.now();
  await page.click('#connectBtn');
  await expect(toast(page)).toHaveText(WALLET_HINT, { timeout: 10_000 });
  expect(Date.now() - clicked, 'not before 5s').toBeGreaterThanOrEqual(5_000);
  release();
  await expect(page.locator('#connectText')).toHaveText(short(user), { ignoreCase: true });
  await expect(toast(page)).not.toContainText(WALLET_HINT);

  // A faucet claim: "Claiming…" first, the hint once it is still unanswered, then the claim goes through.
  release = wallet.hold('eth_sendTransaction');
  await page.click('#faucetBtn');
  await expect(toast(page)).toContainText('Claiming 1,000 Testnet USDC');
  await expect(toast(page)).toHaveText(WALLET_HINT, { timeout: 10_000 });
  await expect(page.locator('#faucetBtn')).toBeDisabled();
  release();
  await expect(toast(page)).toContainText('1,000 Testnet USDC successfully claimed');
  await expect(page.locator('#faucetBtn')).toBeEnabled();

  // Rejected after the hint: the error replaces it.
  release = wallet.hold('eth_sendTransaction');
  await page.click('#faucetBtn');
  await expect(toast(page)).toHaveText(WALLET_HINT, { timeout: 10_000 });
  release({ reject: true });
  await expect(toast(page)).toContainText(`Faucet error: ${REJECTED}`);
  await expect(page.locator('#faucetBtn')).toBeEnabled();
  await expectPageMatchesChain(page, user);
});

test('two requests left unanswered at once: the hint stays while either is pending, and goes when both are answered', async ({ page, wallet }) => {
  await open(page);
  await connect(page, wallet);
  // Add COPRA, then Add USDC, neither answered: neither is followed by a toast of its own when answered,
  // so the page alone must take the hint down.
  const first = wallet.hold('wallet_watchAsset');
  const second = wallet.hold('wallet_watchAsset');
  await page.click('#watchCopraBtn');
  await page.waitForTimeout(1_000);
  await page.click('#watchUsdcBtn');
  await expect(toast(page)).toHaveText(WALLET_HINT, { timeout: 10_000 });
  await page.waitForTimeout(1_500); // past the second request's 5s too
  first();
  await page.waitForTimeout(500);
  await expect(toast(page), 'the second request is still waiting').toHaveText(WALLET_HINT);
  second();
  await expect(toast(page)).not.toContainText(WALLET_HINT);
  expect(wallet.calls('wallet_watchAsset')).toHaveLength(2);
});

test('a request answered within 5s never shows the hint', async ({ page, wallet }) => {
  await open(page);
  const release = wallet.hold('eth_requestAccounts');
  await page.click('#connectBtn');
  await page.waitForTimeout(3_000);
  release();
  await expect(page.locator('#connectText')).toHaveText(short(wallet.selected), { ignoreCase: true });
  await page.waitForTimeout(3_000); // past the 5s mark: a timer left running would show it now
  await expect(toast(page)).not.toContainText(WALLET_HINT);
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
