// Slippage (#44 ⚠️, fixed in #57): mint takes maxCollateralIn and redeem minCollateralOut. These tests
// move the price or fee between the quote the user saw and the transaction landing, as the feeder or the
// owner can, and assert the bound refuses it with nothing moved. Before #57 the same moves charged up to
// +20.9% over the quote and paid −20.0% under it; the last test pins that this is now the caller's choice.
const { describe, it, before, after, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('../lib/harness.cjs');

const { contracts: { usdc, oracle, vault, token }, users, VAULT_OWNER, send, expectRevert, units, ethers, NO_MAX } = h;
const [alice] = users;
const AMOUNT = units(1000, 18);

/** The largest price the collar accepts from the current one (2000.99 bps, see oracle.test.cjs). */
async function maxCollarPrice(up = true) {
  const p = (await oracle.getCopraPriceUSD())[0];
  const firstRejected = (p * 2001n + 9999n) / 10000n;
  return up ? p + firstRejected - 1n : p - firstRejected + 1n;
}

/** Alice, funded and with an unlimited approval: only the bound stands between her and the new price. */
async function unlimitedAlice() {
  await h.fundUsdc(alice, units(5000, 6));
  await send(usdc, 'approve', [vault.target, ethers.MaxUint256], alice);
}

async function expectRefusedMint(quoted) {
  const before = await h.balances(alice);
  const [now] = await vault.quoteMint(AMOUNT);
  const [actual, limit] = await expectRevert(vault, 'mint', [AMOUNT, quoted], alice, 'SlippageExceeded');
  assert.deepEqual([actual, limit], [now, quoted]);
  assert.deepEqual(await h.balances(alice), before, 'a refused mint moves nothing');
}

describe('slippage between quote and transaction', () => {
  h.isolate({ before, after, beforeEach, afterEach });

  it('a price update at the collar landing first: the mint reverts instead of costing ~20% more', async () => {
    await unlimitedAlice();
    const [quoted] = await vault.quoteMint(AMOUNT);
    await h.postPrice(await maxCollarPrice(true)); // lands between the quote and the user's tx
    await expectRefusedMint(quoted);
  });

  it('a fee raise to MAX_FEE_BPS landing first: the mint reverts instead of costing 0.75% more', async () => {
    await unlimitedAlice();
    const [quoted] = await vault.quoteMint(AMOUNT);
    await send(vault, 'setProtocolFee', [100n], VAULT_OWNER);
    await expectRefusedMint(quoted);
  });

  it('price and fee both moved: the mint reverts instead of costing ~20.9% more', async () => {
    await unlimitedAlice();
    const [quoted] = await vault.quoteMint(AMOUNT);
    await send(vault, 'setProtocolFee', [100n], VAULT_OWNER);
    await h.postPrice(await maxCollarPrice(true));
    await expectRefusedMint(quoted);
  });

  it('a price drop landing first: the redeem reverts instead of paying ~20% less', async () => {
    await h.fundUsdc(alice, units(5000, 6));
    await h.mintCopra(alice, AMOUNT);
    const [quoted] = await vault.quoteRedeem(AMOUNT);
    await h.postPrice(await maxCollarPrice(false));
    const [now] = await vault.quoteRedeem(AMOUNT);
    const before = await h.balances(alice);
    const [actual, limit] = await expectRevert(vault, 'redeem', [AMOUNT, quoted], alice, 'SlippageExceeded');
    assert.deepEqual([actual, limit], [now, quoted]);
    assert.deepEqual(await h.balances(alice), before, 'a refused redeem moves nothing');
  });

  it('a move in the user\'s favour still executes, at the new price', async () => {
    await unlimitedAlice();
    const [quotedIn] = await vault.quoteMint(AMOUNT);
    await h.postPrice(await maxCollarPrice(false));
    const [cheaper] = await vault.quoteMint(AMOUNT);
    const before = await usdc.balanceOf(alice);
    await send(vault, 'mint', [AMOUNT, quotedIn], alice);
    assert.equal(before - (await usdc.balanceOf(alice)), cheaper);
    assert.ok(cheaper < quotedIn);

    const [quotedOut] = await vault.quoteRedeem(units(10, 18));
    const [price] = await oracle.getCopraPriceUSD();
    await h.postPrice(price + price / 100n); // +1%: 10 of 1000 $COPRA, well inside the backing
    const [better] = await vault.quoteRedeem(units(10, 18));
    const got = await usdc.balanceOf(alice);
    await send(vault, 'redeem', [units(10, 18), quotedOut], alice);
    assert.equal((await usdc.balanceOf(alice)) - got, better);
    assert.ok(better >= quotedOut);
  });

  it('the bound is the caller\'s: one who passes none still takes whatever the price is when it lands', async () => {
    await unlimitedAlice();
    const [quoted] = await vault.quoteMint(AMOUNT);
    await h.postPrice(await maxCollarPrice(true));
    const before = await usdc.balanceOf(alice);
    await send(vault, 'mint', [AMOUNT, NO_MAX], alice);
    assert.ok(before - (await usdc.balanceOf(alice)) > (quoted * 12n) / 10n, 'unbounded: over 20% above the quote');
    assert.equal(await token.balanceOf(alice), AMOUNT);
  });
});
