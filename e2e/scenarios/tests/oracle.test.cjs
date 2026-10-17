// Oracle corner cases (#44): interval, collar, heartbeat and access, each at its exact boundary,
// with block timestamps set precisely and every rejection a mined transaction.
const { describe, it, before, after, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('../lib/harness.cjs');

const { contracts: { oracle, vault, usdc }, users, UPDATER, send, expectRevert, units, NO_MAX, NO_MIN } = h;
const [alice] = users;

const price = async () => (await oracle.getCopraPriceUSD())[0];

describe('oracle', () => {
  h.isolate({ before, after, beforeEach, afterEach });

  it('rejects an update 1s before MIN_UPDATE_INTERVAL and accepts one exactly at it', async () => {
    const due = (await h.lastUpdatedAt()) + (await oracle.MIN_UPDATE_INTERVAL());
    await h.setNextTimestamp(due - 1n);
    await expectRevert(oracle, 'updatePrice', [143000000n], UPDATER, 'UpdateTooSoon');
    await h.setNextTimestamp(due);
    await send(oracle, 'updatePrice', [143000000n], UPDATER);
    assert.equal(await price(), 143000000n);
  });

  it('accepts shifts up to the exact collar threshold and rejects the first unit past it, both ways', async () => {
    const p = await price();
    const firstRejected = (p * ((await oracle.MAX_PRICE_CHANGE_BPS()) + 1n) + 9999n) / 10000n; // 2000.99 bps accepted
    const due = (await h.lastUpdatedAt()) + (await oracle.MIN_UPDATE_INTERVAL());
    await h.warpTo(due);

    await expectRevert(oracle, 'updatePrice', [p + firstRejected], UPDATER, 'PriceChangeExceeded');
    await expectRevert(oracle, 'updatePrice', [p - firstRejected], UPDATER, 'PriceChangeExceeded');
    // A rejected update does not restart the interval: a valid one lands in the same window.
    await send(oracle, 'updatePrice', [p + firstRejected - 1n], UPDATER);
    assert.equal(await price(), p + firstRejected - 1n);
  });

  it('accepts exactly -20%', async () => {
    const p = await price();
    await h.postPrice((p * 8000n) / 10000n);
    assert.equal(await price(), (p * 8000n) / 10000n);
  });

  it('is fresh at exactly HEARTBEAT and stale 1s later: mint and redeem revert, one update recovers', async () => {
    await h.fundUsdc(alice, units(1000, 6));
    await send(usdc, 'approve', [vault.target, h.ethers.MaxUint256], alice);
    await send(vault, 'mint', [units(10, 18), NO_MAX], alice);
    const stale = (await h.lastUpdatedAt()) + (await oracle.HEARTBEAT());

    await h.setNextTimestamp(stale);
    await send(vault, 'mint', [units(1, 18), NO_MAX], alice); // age == HEARTBEAT: still fresh

    await h.setNextTimestamp(stale + 1n);
    await expectRevert(vault, 'mint', [units(1, 18), NO_MAX], alice, 'StalePrice');
    await expectRevert(vault, 'redeem', [units(1, 18), NO_MIN], alice, 'StalePrice');
    await assert.rejects(oracle.getCopraPriceUSD(), /StalePrice|execution reverted/);

    await send(oracle, 'updatePrice', [await h.lastPrice()], UPDATER); // stale is long past the interval
    await send(vault, 'redeem', [units(1, 18), NO_MIN], alice);
  });

  it('accepts updates only from the updater, and never 0', async () => {
    await h.warp(Number(await oracle.MIN_UPDATE_INTERVAL()));
    await expectRevert(oracle, 'updatePrice', [143000000n], alice, 'OnlyUpdater');
    await expectRevert(oracle, 'updatePrice', [0n], UPDATER, 'PriceTooLow');
  });

  it('trust assumption: 13 daily +20% updates let the updater drain the vault through redeem', async () => {
    // Pins README "Trust Assumptions" on a real chain: the interval slows the updater, it does not stop it.
    await h.fundUsdc(alice, units(1500, 6));
    await h.mintCopra(alice, units(1000, 18));
    await h.fundUsdc(UPDATER, units(200, 6));
    await h.mintCopra(UPDATER, units(100, 18));
    const updaterPaid = units(200, 6) - (await usdc.balanceOf(UPDATER));

    const start = await h.latestTimestamp();
    let p = await price();
    for (let i = 0; i < 13; i++) {
      p = (p * 12n) / 10n;
      await h.postPrice(p);
    }
    assert.ok(p > 142000000n * 10n, 'price x10 after 13 updates');
    assert.ok((await h.latestTimestamp()) - start <= 13 * 86400 + 13, 'within 13 days');

    const before = await usdc.balanceOf(UPDATER);
    await send(vault, 'redeem', [units(100, 18), NO_MIN], UPDATER);
    const out = (await usdc.balanceOf(UPDATER)) - before;
    assert.ok(out > updaterPaid * 10n, `updater got ${out} back for ${updaterPaid} in`);
    await expectRevert(vault, 'redeem', [units(1000, 18), NO_MIN], alice, 'InsufficientVaultCollateral');
  });
});
