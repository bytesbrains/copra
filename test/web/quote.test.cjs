// Run with: node --test test/web/
const test = require('node:test');
const assert = require('node:assert/strict');
const Q = require('../../web/assets/quote.js');

const PRICE = 142000000n; // $1.42, 8 decimals
const BPS = 25n;

test('parseUnits accepts plain decimals and truncates excess precision', () => {
  assert.equal(Q.parseUnits('11', 6), 11000000n);
  assert.equal(Q.parseUnits('10.999999', 6), 10999999n);
  assert.equal(Q.parseUnits('.5', 6), 500000n);
  assert.equal(Q.parseUnits('1.2345678', 6), 1234567n);
  assert.equal(Q.parseUnits('0.1', 18), 100000000000000000n); // no float garbage
  for (const bad of ['', '.', '-1', '1e-7', 'abc', null, undefined]) {
    assert.equal(Q.parseUnits(bad, 6), null, `rejects ${bad}`);
  }
});

test('formatUnits never rounds up', () => {
  assert.equal(Q.formatUnits(10999999n, 6, 2), '10.99');
  assert.equal(Q.formatUnits(1234560000000000000n, 18, 4), '1.2345');
  assert.equal(Q.formatUnits(5n, 6, 4), '0.0000');
  assert.equal(Q.formatUnits(10999999n, 6), '10.999999');
  assert.equal(Q.formatUnits(1234560000000000000n, 18), '1.23456');
  assert.equal(Q.formatUnits(0n, 18), '0');
});

test('quote mirrors match CopraVault for the documented example', () => {
  const tenCopra = 10n * 10n ** 18n;
  assert.deepEqual(Q.quoteMint(tenCopra, PRICE, BPS), { collateralRequired: 14235500n, fee: 35500n });
  assert.deepEqual(Q.quoteRedeem(tenCopra, PRICE, BPS), { collateralToReturn: 14164500n, fee: 35500n });
});

test('quoteMint rounds up like CopraVault, quoteRedeem rounds down', () => {
  const dust = 714285714285n; // just under 1 micro-USDC at $1.40
  assert.equal(Q.quoteMint(dust, 140000000n, BPS).collateralRequired, 1n);
  assert.equal(Q.quoteRedeem(dust, 140000000n, BPS).collateralToReturn, 0n);
  assert.equal(Q.quoteMint(10n ** 18n, 140000000n, BPS).collateralRequired, 1403500n); // matches test_Vault_DustMintIsNotFree
});

// Regression for the MAX button: spending the full balance must never require more than the balance.
test('copraForCollateral never exceeds the USDC budget', () => {
  const budgets = [1n, 999n, 10999999n, 11000000n, 14235500n, 1000000000n, 123456789012n];
  const prices = [1n, 99999999n, PRICE, 314159265n, 10000000000n];
  for (const usdc of budgets) {
    for (const price of prices) {
      for (const bps of [0n, 1n, BPS, 30n, 1000n]) {
        const copra = Q.copraForCollateral(usdc, price, bps);
        const { collateralRequired } = Q.quoteMint(copra, price, bps);
        assert.ok(collateralRequired <= usdc, `usdc=${usdc} price=${price} bps=${bps}`);
      }
    }
  }
  assert.equal(Q.copraForCollateral(0n, PRICE, BPS), 0n);
  assert.equal(Q.copraForCollateral(1000n, 0n, BPS), 0n);
});

test('copraForCollateral spends the budget to within one cent of a unit', () => {
  const usdc = 10999999n;
  const { collateralRequired } = Q.quoteMint(Q.copraForCollateral(usdc, PRICE, BPS), PRICE, BPS);
  assert.ok(usdc - collateralRequired <= 1n, `left ${usdc - collateralRequired} unspent`);
});
