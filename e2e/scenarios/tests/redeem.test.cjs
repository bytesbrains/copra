// Redeem corner cases (#44), each a real transaction on the e2e chain.
const { describe, it, before, after, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('../lib/harness.cjs');

const { contracts: { usdc, vault, token }, users, VAULT_OWNER, send, expectRevert, units, rpc, NO_MAX, NO_MIN } = h;
const [alice, bob, carol] = users;

describe('redeem', () => {
  h.isolate({ before, after, beforeEach, afterEach });

  it('rejects 0 with ZeroAmount', async () => {
    await expectRevert(vault, 'redeem', [0n, NO_MIN], alice, 'ZeroAmount');
  });

  it('rejects more than the balance with ERC20InsufficientBalance, even when the vault could pay', async () => {
    await h.fundUsdc(alice, units(100, 6));
    await h.fundUsdc(bob, units(1000, 6));
    await h.mintCopra(alice, units(10, 18));
    await h.mintCopra(bob, units(100, 18));
    await expectRevert(vault, 'redeem', [units(11, 18), NO_MIN], alice, 'ERC20InsufficientBalance');
  });

  it('pays the quote exactly and keeps the redeem fee in the vault', async () => {
    await h.fundUsdc(alice, units(100, 6));
    await h.mintCopra(alice, units(50, 18));
    const feesBefore = await vault.accumulatedFees();
    const [out, fee] = await vault.quoteRedeem(units(20, 18));
    const before = await h.balances(alice);
    await send(vault, 'redeem', [units(20, 18), NO_MIN], alice);
    const after = await h.balances(alice);
    assert.equal(after.usdc - before.usdc, out);
    assert.equal(before.copra - after.copra, units(20, 18));
    assert.equal((await vault.accumulatedFees()) - feesBefore, fee);
  });

  it('lets the last holder exit in full: the vault keeps the fees plus rounding dust only', async (t) => {
    await h.fundUsdc(alice, units(2000, 6));
    await h.mintCopra(alice, units(777.123456789, 18));
    await send(vault, 'redeem', [await token.balanceOf(alice), NO_MIN], alice);
    assert.equal(await token.totalSupply(), 0n);

    const dust = (await usdc.balanceOf(vault.target)) - (await vault.accumulatedFees());
    t.diagnostic(`vault dust after full exit: ${dust} micro-USDC`);
    assert.ok(dust >= 0n && dust <= 2n, `dust ${dust}: mint rounds up and redeem rounds down by at most 1 unit each`);

    await send(vault, 'claimFees', [], carol); // anyone can trigger; funds go to feeRecipient
    assert.equal(await usdc.balanceOf(vault.target), dust);
  });

  it('after a price rise, pays first come first served, then InsufficientVaultCollateral; fees stay claimable', async () => {
    await h.fundUsdc(alice, units(1500, 6));
    await h.fundUsdc(bob, units(1500, 6));
    await h.mintCopra(alice, units(1000, 18));
    await h.mintCopra(bob, units(1000, 18));
    const p = (await h.contracts.oracle.getCopraPriceUSD())[0];
    await h.postPrice((p * 12n) / 10n);

    await send(vault, 'redeem', [units(1000, 18), NO_MIN], alice); // first: paid in full at the new price
    await expectRevert(vault, 'redeem', [units(1000, 18), NO_MIN], bob, 'InsufficientVaultCollateral');

    // Bob can still take what is left, minus the fees the vault must keep.
    const available = (await usdc.balanceOf(vault.target)) - (await vault.accumulatedFees());
    const [perCopra, perFee] = await vault.quoteRedeem(units(1, 18));
    const partial = (available * units(1, 18)) / (perCopra + perFee) - units(1, 18);
    await send(vault, 'redeem', [partial, NO_MIN], bob);
    await send(vault, 'claimFees', [], bob);
    assert.ok((await token.balanceOf(bob)) > 0n, 'bob is left holding COPRA the vault cannot pay for');
  });

  it('refuses a redeem that would only fit by spending the fee reserve', async () => {
    // The vault must keep accumulatedFees: a redeem whose payout fits in the free collateral but whose
    // payout + fee does not must revert, or claimFees would later find the vault short.
    await h.fundUsdc(alice, units(1500, 6));
    await h.fundUsdc(bob, units(1500, 6));
    await h.mintCopra(alice, units(1000, 18));
    await h.mintCopra(bob, units(1000, 18));
    const p = (await h.contracts.oracle.getCopraPriceUSD())[0];
    await h.postPrice((p * 12n) / 10n);
    await send(vault, 'redeem', [units(1000, 18), NO_MIN], alice);

    // Smallest amount whose payout + fee exceeds the free collateral (binary search over view quotes).
    const available = (await usdc.balanceOf(vault.target)) - (await vault.accumulatedFees());
    let lo = 0n, hi = units(1000, 18);
    while (hi - lo > 1n) {
      const mid = (lo + hi) / 2n;
      const [out, fee] = await vault.quoteRedeem(mid);
      if (out + fee > available) hi = mid; else lo = mid;
    }
    const [out, fee] = await vault.quoteRedeem(hi);
    assert.ok(out <= available && out + fee > available, 'found an amount inside the fee-reserve window');
    await expectRevert(vault, 'redeem', [hi, NO_MIN], bob, 'InsufficientVaultCollateral');
    await send(vault, 'redeem', [lo, NO_MIN], bob); // one wei less fits, fee included
    await send(vault, 'claimFees', [], bob);
  });

  it('reserves every redeem fee: claimFees succeeds after each redeem in a mixed sequence', async () => {
    const actors = [alice, bob, carol];
    for (const a of actors) {
      await h.fundUsdc(a, units(500, 6));
      await send(usdc, 'approve', [vault.target, h.ethers.MaxUint256], a);
    }
    const steps = [
      [alice, 'mint', 300], [bob, 'mint', 120.5], [alice, 'redeem', 99.99], [carol, 'mint', 333.333333],
      [bob, 'redeem', 120.5], [carol, 'redeem', 0.000001], [alice, 'redeem', 200.01], [carol, 'redeem', 333.333332],
    ];
    for (const [who, method, amount] of steps) {
      await send(vault, method, [units(amount, 18), method === 'mint' ? NO_MAX : NO_MIN], who);
      if (method === 'redeem' && (await vault.accumulatedFees()) > 0n) {
        const snap = await rpc('evm_snapshot');
        await send(vault, 'claimFees', [], who);
        await rpc('evm_revert', [snap]);
      }
    }
  });

  it('stays solvent when a holder burns their own COPRA (ERC20Burnable)', async () => {
    await h.fundUsdc(alice, units(100, 6));
    await h.mintCopra(alice, units(10, 18));
    await send(token, 'burn', [units(4, 18)], alice);
    assert.equal(await token.totalSupply(), units(6, 18));
    await send(vault, 'redeem', [units(6, 18), NO_MIN], alice);
    assert.ok((await usdc.balanceOf(vault.target)) > (await vault.accumulatedFees()), 'burned COPRA leaves its USDC behind');
  });

  it('lets only the vault mint or burn COPRA', async () => {
    await h.fundUsdc(alice, units(100, 6));
    await h.mintCopra(alice, units(10, 18));
    await expectRevert(token, 'mint', [alice, units(1, 18)], alice, 'OnlyVault');
    await expectRevert(token, 'burnFromVault', [alice, units(1, 18)], VAULT_OWNER, 'OnlyVault');
  });
});
