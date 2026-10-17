// Amount input edge cases, and the displayed quote against the vault's own (#46).
const path = require('node:path');
const { test, expect, ethers, open, connect, setAmount, fixed, chainMintQuote, toast } = require('../lib/fixtures.cjs');
const { REPO } = require('../lib/env.cjs');

const quote = require(path.join(REPO, 'web/assets/quote.js'));

const units = (v, d) => ethers.parseUnits(String(v), d);

test('input edge cases: empty, 0, negative, 1e-7 and exponents quote nothing and sign nothing', async ({ page, wallet, chain }) => {
  await chain.fundUsdc(wallet.selected, units(100, 6));
  await chain.mintCopra(wallet.selected, units(5, 18));
  await open(page);
  await connect(page, wallet);

  for (const [tab, message] of [['#tabMint', 'Enter a valid USDC amount to mint.'], ['#tabRedeem', 'Enter a valid $COPRA amount to redeem.']]) {
    await page.click(tab);
    for (const value of ['', '0', '-5', '1e-7', '1e30']) {
      await setAmount(page, value);
      await expect(page.locator('#outputAmount'), `quote for "${value}"`).toHaveValue('0.0000');
      await expect(page.locator('#feeDisplay')).toHaveText('$0.0000 USDC');
      await page.click('#actionBtn');
      await expect(toast(page), `submit "${value}"`).toHaveText(message);
      await expect(page.locator('#actionBtn')).toBeEnabled();
      await expect(page.locator('#actionBtnText')).not.toHaveText('Confirming in wallet...');
    }
  }
  expect(wallet.calls('eth_sendTransaction')).toEqual([]);
});

// Chrome's number input (en-US) drops a typed comma, so "1,5" becomes a visible 15, not a hidden 1.5 or
// 15,000: the box shows exactly the amount quoted and signed.
test('a locale comma is dropped as typed: the box shows what is quoted', async ({ page, wallet }) => {
  await open(page);
  await connect(page, wallet);
  await setAmount(page, '1,5');
  await expect(page.locator('#amountInput')).toHaveValue('15');
  const q = await chainMintQuote(units(15, 6));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(q.copra, 18, 4));
});

test('more than 6 USDC decimals is truncated, never rounded up; a huge amount is refused before signing', async ({ page, wallet, chain }) => {
  await chain.fundUsdc(wallet.selected, units(100, 6));
  await chain.send(chain.contracts.usdc, 'approve', [chain.contracts.vault.target, ethers.MaxUint256], wallet.selected);
  await open(page);
  await connect(page, wallet);

  await setAmount(page, '1.1234569');
  const truncated = await chainMintQuote(1_123_456n); // 1.123456 USDC, the 7th decimal dropped
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(truncated.copra, 18, 4));
  await expect(page.locator('#feeDisplay')).toHaveText(`$${fixed(truncated.fee, 6, 4)} USDC`);

  const huge = '99999999999999999999';
  await setAmount(page, huge);
  const big = await chainMintQuote(units(huge, 6));
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(big.copra, 18, 4));
  await page.click('#actionBtn');
  const [required] = await chain.contracts.vault.quoteMint(big.copra);
  await expect(toast(page)).toHaveText(`Insufficient USDC: this mint needs ${quote.formatUnits(required, 6)} USDC at the current oracle price.`);
  await expect(page.locator('#actionBtn')).toBeEnabled();
  expect(wallet.calls('eth_sendTransaction')).toEqual([]);

  await page.click('#tabRedeem');
  await setAmount(page, '1.1234567890123456789'); // 19 decimals: the 19th is dropped
  const [toReturn, fee] = await chain.contracts.vault.quoteRedeem(1_123_456_789_012_345_678n);
  await expect(page.locator('#outputAmount')).toHaveValue(fixed(toReturn, 6, 4));
  await expect(page.locator('#feeDisplay')).toHaveText(`$${fixed(fee, 6, 4)} USDC`);
});

test('the displayed quote equals quoteMint / quoteRedeem on chain for the same input', async ({ page, wallet, chain }) => {
  await open(page);
  await connect(page, wallet);

  for (const usdc of ['14.20', '0.000001', '0.01', '1.123456', '5000', '123456.789']) {
    await setAmount(page, usdc);
    const q = await chainMintQuote(units(usdc, 6));
    await expect(page.locator('#outputAmount'), `mint ${usdc} USDC`).toHaveValue(fixed(q.copra, 18, 4));
    await expect(page.locator('#feeDisplay'), `mint fee for ${usdc} USDC`).toHaveText(`$${fixed(q.fee, 6, 4)} USDC`);
  }

  await page.click('#tabRedeem');
  for (const copra of ['10', '0.000000000000000001', '0.7', '3.333333333333333333', '1000000']) {
    await setAmount(page, copra);
    const [toReturn, fee] = await chain.contracts.vault.quoteRedeem(units(copra, 18));
    await expect(page.locator('#outputAmount'), `redeem ${copra} COPRA`).toHaveValue(fixed(toReturn, 6, 4));
    await expect(page.locator('#feeDisplay'), `redeem fee for ${copra} COPRA`).toHaveText(`$${fixed(fee, 6, 4)} USDC`);
  }
});
