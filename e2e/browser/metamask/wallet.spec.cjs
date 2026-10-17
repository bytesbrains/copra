// Tier-2 wallet behaviour (#50): what only a real wallet can show. Rejections clicked in MetaMask's own UI.
const { test, expect, connectFirstTime, confirmInMetaMask, reloadWhenWalletSynced } = require('../lib/metamask-fixtures.cjs');
const mm = require('../lib/metamask.cjs');
const { ethers, short, show, open, expectPageMatchesChain, expectSent, toast } = require('../lib/fixtures.cjs');

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

test('Add COPRA to wallet: MetaMask shows the token, its logo and the balance at the right decimals, and accepts it', async ({ connected, chain }) => {
  const { page, wallet, metamask } = connected;
  const user = wallet.selected;
  // A fractional balance, so MetaMask showing it right means it took the decimals the page gave it.
  await chain.fundUsdc(user, units(10, 6));
  await chain.mintCopra(user, units('2.5', 18));
  await reloadWhenWalletSynced(connected);

  await page.click('#watchCopraBtn');
  const { panel, route } = await mm.nextApproval(metamask.cdp, { seen: connected.seen });
  connected.seen.push(route);
  expect(route).toBe('/confirm-add-suggested-token');
  await expect(panel.getByTestId('confirm-add-suggested-token-balance')).toHaveAttribute('title', '2.5 COPRA');
  // The page's own logo, which tier 1 checks is served as image/png.
  await expect(panel.getByRole('img', { name: 'COPRA' })).toHaveAttribute('src', `${new URL(page.url()).origin}/assets/copra_logo_128.png`);
  await panel.getByTestId('page-container-footer-next').click(); // "Add token"

  const watched = () => wallet.requests.filter((r) => r.method === 'wallet_watchAsset');
  await expect.poll(() => watched().length).toBe(1);
  const [added] = watched();
  expect(added.result).toBe(true);
  expect(added.params.options).toEqual({ address: chain.contracts.token.target, symbol: 'COPRA', decimals: 18, image: expect.stringContaining('copra_logo_128.png') });
  // Not asserted: that MetaMask then lists COPRA among its tokens. With Basic functionality off (see
  // lib/metamask.cjs) it did not, even after a reload, though it accepted the token; what a user sees
  // before accepting is what the dApp controls, and is checked above.
});

test('switching account in MetaMask and connecting it drives accountsChanged; the page signs as that account; disconnecting empties it', async ({ connected, chain }) => {
  const { page, wallet, metamask } = connected;
  const [, bob] = chain.users; // MetaMask's Account 2: the mnemonic's second address
  await chain.fundUsdc(bob, units(5, 6));

  // In MetaMask: pick Account 2, which this site has no permission for yet, then connect it from the bar.
  let panel = await metamask.panel();
  await panel.getByTestId('account-menu-icon').click();
  await panel.getByTestId('multichain-account-cell-name-Account 2').click();
  const bar = panel.getByTestId('dapp-connection-control-bar');
  await expect(bar).toContainText('Not connected');
  await bar.getByRole('button', { name: 'Connect' }).click();

  await expect(page.locator('#connectText')).toHaveText(short(bob), { ignoreCase: true });
  wallet.selected = bob;
  await reloadWhenWalletSynced(connected); // the page reads bob's balance through the wallet
  await expect(page.locator('#usdcBalance')).toHaveText(show.usdc(units(5, 6)));

  // The page signs as the account now selected: MetaMask's confirmation, the request and the chain agree.
  await page.click('#faucetBtn');
  panel = await confirmInMetaMask(connected, { contract: chain.manifest.contracts.usdc });
  await expectSent(wallet, { from: bob, contract: chain.contracts.usdc, fn: 'faucet', args: [bob, units(1000, 6)] });
  await expect(toast(page)).toContainText('successfully claimed');
  await expectPageMatchesChain(page, bob);

  // Disconnecting the site in MetaMask: accountsChanged to none.
  panel = await metamask.panel();
  await panel.getByTestId('dapp-connection-control-bar__disconnect-button').click();
  const confirmDisconnect = panel.getByRole('button', { name: /^Disconnect/ }).last();
  if (await confirmDisconnect.isVisible().catch(() => false)) await confirmDisconnect.click();
  await expect(page.locator('#connectText')).toHaveText('Connect Wallet');
  await expect(page.locator('#balanceBar')).toBeHidden();
  await expect(page.locator('#maxBtn')).toBeHidden();
});

test('switching the site to another network in MetaMask reloads the page (chainChanged); connecting brings it back to the local chain', async ({ connected, chain }) => {
  const { page, wallet, metamask } = connected;
  const chainHex = '0x' + chain.manifest.chainId.toString(16);

  // In MetaMask: move this site to Ethereum mainnet from the connection bar.
  const panel = await metamask.panel();
  const reloaded = page.waitForEvent('load');
  await panel.getByTestId('dapp-connection-control-bar__network-button').click();
  await panel.getByTestId('dapp-bar-network-selector-popover').getByText('Ethereum', { exact: true }).click();
  await reloaded;
  expect(await page.evaluate(() => window.ethereum.request({ method: 'eth_chainId' }))).toBe('0x1');

  // Connecting asks the wallet to switch back. The network is known and the site permitted, so MetaMask
  // switches without a prompt (13.49): a version that starts asking fails here, not silently approved.
  await open(page);
  const back = page.waitForEvent('load');
  await page.click('#connectBtn');
  await back;
  expect(await page.evaluate(() => window.ethereum.request({ method: 'eth_chainId' }))).toBe(chainHex);
  const switches = wallet.requests.filter((r) => r.method === 'wallet_switchEthereumChain');
  expect(switches.at(-1)?.params).toEqual([{ chainId: chainHex }]);
  expect(wallet.requests.filter((r) => r.method === 'wallet_addEthereumChain')).toHaveLength(1); // only the first connection's

  await open(page);
  await page.click('#connectBtn');
  await expect(page.locator('#connectText')).toHaveText(short(wallet.selected), { ignoreCase: true });
  await expectPageMatchesChain(page, wallet.selected);
});

test('closing MetaMask mid-confirmation does not reject: the page waits, and rejecting when MetaMask is reopened restores it', async ({ connected, chain }) => {
  const { page, wallet, metamask } = connected;
  const label = await page.locator('#faucetBtn').innerText();
  await page.click('#faucetBtn');
  const { panel, route } = await mm.nextApproval(metamask.cdp, { seen: connected.seen });
  connected.seen.push(route);

  // The user closes the side panel instead of answering. MetaMask 13.49 keeps the request pending
  // (closing is not a rejection), so the page still waits on the wallet, and says what it is waiting for.
  await panel.close();
  await page.waitForTimeout(3000);
  await expect(page.locator('#faucetBtn')).toBeDisabled();
  await expect(toast(page)).toContainText('Claiming');
  expect(wallet.requests.filter((r) => r.method === 'eth_sendTransaction')).toEqual([]);

  // Reopening MetaMask shows the same request; rejecting it there gives the page its 4001.
  const reopened = await metamask.context.newPage();
  await reopened.goto(`chrome-extension://${metamask.extensionId}/home.html#${route}`);
  await mm.rejectButton(reopened).click();
  await expect(toast(page)).toContainText('Faucet error:');
  await expect(page.locator('#faucetBtn')).toBeEnabled();
  await expect(page.locator('#faucetBtn')).toHaveText(label);
  expect(wallet.requests.filter((r) => r.method === 'eth_sendTransaction').map((r) => r.error?.code)).toEqual([4001]);
  expect(wallet.sent).toEqual([]);
  await expectPageMatchesChain(page, wallet.selected);
});
