// Protocol corner cases in the browser (#46): a stale oracle, a vault short of collateral, the price
// moving between quote and signature, and an unreachable registry.
const {
  test, expect, h, ethers, open, connect, setAmount, expectPageMatchesChain, expectSent, fixed, chainMintQuote, toast,
  afterTelemetryPoll,
} = require('../lib/fixtures.cjs');
const { PAGE_RPC_URL } = require('../lib/env.cjs');

const units = (v, d) => ethers.parseUnits(String(v), d);
const STALE = 'The oracle price is stale, so minting and redeeming are paused until it is updated.';

/** The custom error a call reverts with, read by the suite itself. */
async function revertOf(promise) {
  try {
    await promise;
  } catch (e) {
    return h.decodeRevert(e.data ?? e.info?.error?.data).name;
  }
  return null;
}

test('stale oracle → a clear degraded UI, and mint and redeem show a readable error, not a raw revert', async ({ page, wallet, chain }) => {
  const user = wallet.selected;
  await chain.fundUsdc(user, units(100, 6));
  await chain.mintCopra(user, units(5, 18));
  await chain.warp(Number(await chain.contracts.oracle.HEARTBEAT()) + 1);
  expect(await revertOf(chain.contracts.oracle.getCopraPriceUSD())).toBe('StalePrice');

  await open(page);
  // No price is invented: the page used to show its built-in $1.42 and quote against it.
  await expect(page.locator('#benchmarkHeader')).toHaveText('Price stale');
  await expect(page.locator('#oracleDisplay')).toHaveText('Price stale');
  await expect(page.locator('#metricOracleAge')).toHaveText('Stale: no update within the 7-day heartbeat');
  await expect(page.locator('#metricOracleUpdated')).toHaveText('Minting and redeeming are paused');
  await expect(page.locator('#outputAmount')).toHaveValue('');
  await expect(page.locator('#feeDisplay')).toHaveText('—');

  await connect(page, wallet);
  await page.click('#actionBtn');
  await expect(toast(page)).toHaveText(STALE);
  await expect(page.locator('#actionBtn')).toBeEnabled();
  await page.click('#tabRedeem');
  await expect(page.locator('#outputAmount')).toHaveValue('');
  await page.click('#actionBtn');
  await expect(toast(page)).toHaveText(STALE);
  await expect(page.locator('#actionBtn')).toBeEnabled();
  expect(wallet.calls('eth_sendTransaction')).toEqual([]);
});

test('the oracle goes stale with the page open → the vault\'s StalePrice revert is shown readably', async ({ page, wallet, chain, guard }) => {
  guard.allow(/^Transaction error:/);
  const user = wallet.selected;
  await chain.fundUsdc(user, units(100, 6));
  await chain.send(chain.contracts.usdc, 'approve', [chain.contracts.vault.target, ethers.MaxUint256], user);
  await open(page);
  await connect(page, wallet);
  await expect(page.locator('#actionBtnText')).toHaveText('Mint $COPRA');

  await afterTelemetryPoll(page);
  await chain.warp(Number(await chain.contracts.oracle.HEARTBEAT()) + 1);
  await page.click('#actionBtn');
  // The page still has the old price, so this is the vault's quote reverting, decoded.
  await expect(toast(page)).toHaveText(`Transaction error: ${STALE}`);
  await expect(page.locator('#actionBtn')).toBeEnabled();
  expect(wallet.calls('eth_sendTransaction')).toEqual([]);
  // And the next poll catches up with the chain.
  await expect(page.locator('#benchmarkHeader')).toHaveText('Price stale', { timeout: 20_000 });
});

test('vault short of collateral → readable InsufficientVaultCollateral message', async ({ page, wallet, chain, guard }) => {
  guard.allow(/^Transaction error:/);
  const user = wallet.selected;
  await chain.fundUsdc(user, units(100, 6));
  await chain.mintCopra(user, units(10, 18));
  // +19.5%, the feeder's clamp: 10 $COPRA are now worth more than the vault holds for them.
  await chain.postPrice(169_690_000n);
  expect(await revertOf(chain.contracts.vault.connect(await chain.signer(user)).redeem.staticCall(units(10, 18), 0n))).toBe('InsufficientVaultCollateral');

  await open(page);
  await connect(page, wallet);
  await page.click('#tabRedeem');
  await setAmount(page, '10');
  await page.click('#actionBtn');
  await expect(toast(page)).toHaveText('Transaction error: The vault does not hold enough USDC to pay this redemption right now. Try a smaller amount.');
  await expect(page.locator('#actionBtn')).toBeEnabled();
  await expect(page.locator('#actionBtnText')).toHaveText('Redeem USDC');
  expect(wallet.calls('eth_sendTransaction')).toEqual([]); // refused at the gas estimate: nothing signed
  expect((await chain.balances(user)).copra).toBe(units(10, 18));
  await expectPageMatchesChain(page, user);
});

test('the oracle moves between page load and submit → the user sees the new price before signing', async ({ page, wallet, chain }) => {
  const user = wallet.selected;
  await chain.fundUsdc(user, units(100, 6));
  await chain.send(chain.contracts.usdc, 'approve', [chain.contracts.vault.target, ethers.MaxUint256], user);
  await open(page);
  await connect(page, wallet);
  await expect(page.locator('#actionBtnText')).toHaveText('Mint $COPRA');
  const before = await chainMintQuote(units('14.20', 6));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(before.copra, 18, 4));

  await afterTelemetryPoll(page);
  await chain.postPrice(155_000_000n); // $1.42 → $1.55
  await page.click('#actionBtn');
  // Nothing is signed at the old quote: the page shows the new one and asks again.
  await expect(toast(page)).toHaveText('The price or fee changed since your quote. The new quote is shown: check it and submit again.');
  expect(wallet.calls('eth_sendTransaction')).toEqual([]);
  const after = await chainMintQuote(units('14.20', 6));
  await expect(page.locator('#benchmarkHeader')).toHaveText('$1.55 USD / kg');
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(after.copra, 18, 4));
  await expect(page.locator('#actionBtn')).toBeEnabled();

  // Submitting again signs exactly what is now shown.
  await page.click('#actionBtn');
  const { events } = await expectSent(wallet, { from: user, contract: chain.contracts.vault, fn: 'mint', args: [after.copra, after.required] });
  expect(events.find((e) => e.name === 'Minted').args.feePaid).toBe(after.fee);
  await expect(toast(page)).toContainText(`Successfully minted ${fixed(after.copra, 18, 4)} $COPRA`);
  await expectPageMatchesChain(page, user);
});

const SLIPPAGE = 'The price or fee moved past your quote before the transaction ran, so the vault refused it and no USDC or $COPRA moved. The new quote is shown: check it and submit again.';

/** The one transaction the page had signed: mined, reverted on chain with SlippageExceeded(actual, limit). */
async function expectRefusedOnChain(wallet, chain, { fn, args, limit }) {
  await expect.poll(() => wallet.sent.length, { message: `the page sends ${fn}` }).toBe(1);
  const [tx] = wallet.sent;
  const call = chain.contracts.vault.interface.parseTransaction({ data: tx.data });
  expect([call.name, ...call.args.toArray()]).toEqual([fn, ...args]);
  const receipt = await chain.provider.waitForTransaction(tx.hash);
  expect(receipt.status, `${fn} reverted on chain`).toBe(0);
  const trace = await chain.rpc('debug_traceTransaction', [tx.hash, { tracer: 'callTracer' }]);
  const err = chain.decodeRevert(trace.output);
  expect(err.name).toBe('SlippageExceeded');
  expect(err.args[1]).toBe(limit);
  await chain.checkInvariants();
}

// #57: the guard above catches a move before signing; this is the window it cannot see. The wallet
// lets the oracle move after the user signs and before it broadcasts, so the vault itself must refuse.
test('the oracle moves after the user signs a mint → the vault refuses it on chain, nothing moves, the page says why', async ({ page, wallet, chain, guard }) => {
  guard.allow(/^Transaction error:/);
  const user = wallet.selected;
  await chain.fundUsdc(user, units(100, 6));
  // An unlimited approval from elsewhere: only the bound stands between the user and the new price.
  await chain.send(chain.contracts.usdc, 'approve', [chain.contracts.vault.target, ethers.MaxUint256], user);
  await open(page);
  await connect(page, wallet);
  await expect(page.locator('#actionBtnText')).toHaveText('Mint $COPRA');
  const quoted = await chainMintQuote(units('14.20', 6));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(quoted.copra, 18, 4));

  await afterTelemetryPoll(page);
  wallet.beforeSend = async () => { wallet.beforeSend = null; await chain.postPrice(155_000_000n); }; // $1.42 → $1.55
  const before = await chain.balances(user);
  await page.click('#actionBtn');
  await expectRefusedOnChain(wallet, chain, { fn: 'mint', args: [quoted.copra, quoted.required], limit: quoted.required });
  expect(await chain.balances(user)).toEqual(before);

  await expect(toast(page)).toHaveText(SLIPPAGE);
  await expect(page.locator('#benchmarkHeader')).toHaveText('$1.55 USD / kg');
  const fresh = await chainMintQuote(units('14.20', 6));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(fresh.copra, 18, 4));
  await expect(page.locator('#actionBtn')).toBeEnabled();
  await expectPageMatchesChain(page, user);
});

test('the oracle drops after the user signs a redeem → the vault refuses it on chain, nothing moves, the page says why', async ({ page, wallet, chain, guard }) => {
  guard.allow(/^Transaction error:/);
  const user = wallet.selected;
  await chain.fundUsdc(user, units(100, 6));
  await chain.mintCopra(user, units(10, 18));
  await open(page);
  await connect(page, wallet);
  await page.click('#tabRedeem');
  await setAmount(page, '4');
  const [quoted] = await chain.contracts.vault.quoteRedeem(units(4, 18));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(quoted, 6, 4));

  await afterTelemetryPoll(page);
  wallet.beforeSend = async () => { wallet.beforeSend = null; await chain.postPrice(130_000_000n); }; // $1.42 → $1.30
  const before = await chain.balances(user);
  await page.click('#actionBtn');
  await expectRefusedOnChain(wallet, chain, { fn: 'redeem', args: [units(4, 18), quoted], limit: quoted });
  expect(await chain.balances(user)).toEqual(before);

  await expect(toast(page)).toHaveText(SLIPPAGE);
  await expect(page.locator('#benchmarkHeader')).toHaveText('$1.30 USD / kg');
  const [fresh] = await chain.contracts.vault.quoteRedeem(units(4, 18));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(fresh, 6, 4));
  await expect(page.locator('#actionBtnText')).toHaveText('Redeem USDC');
  await expectPageMatchesChain(page, user);
});

test('registry unreachable → the page uses no address it was not given, warns, and says it is unavailable', async ({ page, wallet, chain, guard }) => {
  guard.allow(/Failed to load resource/); // the aborted registry read, as the browser reports it
  const registryCall = chain.contracts.registry.interface.getFunction('getDeployment').selector.slice(2);
  const calledAddresses = new Set();
  await page.route((url) => url.origin === PAGE_RPC_URL, async (route) => {
    const body = route.request().postData() || '';
    if (body.includes(registryCall)) return route.abort('connectionrefused');
    for (const m of body.matchAll(/"to":"(0x[0-9a-fA-F]{40})"/g)) calledAddresses.add(ethers.getAddress(m[1]));
    return route.continue();
  });
  const warnings = [];
  page.on('console', (m) => { if (m.type() === 'warning') warnings.push(m.text()); });

  await page.goto('/');
  await expect.poll(() => warnings.some((w) => w.startsWith('CopraRegistry unavailable'))).toBe(true);
  await expect(page.locator('#registryVersion')).toHaveText('');
  // The local network, like every network but Base Sepolia, has no fallback set (test/web/network.test.cjs).
  await expect(page.locator('#metricVaultReserves')).toHaveText('Unavailable');
  await expect(page.locator('#metricTotalSupply')).toHaveText('Unavailable');
  await expect(page.locator('#benchmarkHeader')).toHaveText('Price unavailable');

  await connect(page, wallet);
  await page.click('#actionBtn');
  await expect(toast(page)).toHaveText('The protocol cannot be read right now, so minting and redeeming are paused.');
  expect(wallet.calls('eth_sendTransaction')).toEqual([]);
  expect([...calledAddresses]).toEqual([]);
});
