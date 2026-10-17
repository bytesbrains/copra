// Mint corner cases (#44), each a real transaction on the e2e chain.
const { describe, it, before, after, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('../lib/harness.cjs');

const { contracts: { usdc, vault, token }, users, OWNER, send, expectRevert, units } = h;
const [alice, bob] = users;

describe('mint', () => {
  h.isolate({ before, after, beforeEach, afterEach });

  it('rejects 0 with ZeroAmount', async () => {
    await expectRevert(vault, 'mint', [0n], alice, 'ZeroAmount');
  });

  it('charges at least 1 micro-USDC for 1 wei of COPRA (rounds up)', async () => {
    await h.fundUsdc(alice, units(1, 6));
    const [required, fee] = await vault.quoteMint(1n);
    assert.equal(required, 1n, 'quote for 1 wei');
    assert.equal(fee, 0n);
    const before = await h.balances(alice);
    await h.mintCopra(alice, 1n);
    const after = await h.balances(alice);
    assert.equal(before.usdc - after.usdc, 1n);
    assert.equal(after.copra - before.copra, 1n);
  });

  it('rounds up at the micro-USDC boundary too, where the USD value is a whole USDC plus a fraction', async () => {
    // 704225352113 wei x $1.42 = 1.00000000000046e12 USD-wei: floor would make it exactly 1 micro-USDC
    // and charge 1; the true value is a fraction above, so the vault must charge 2.
    const copra = 704225352113n;
    const [required] = await vault.quoteMint(copra);
    assert.equal(required, 2n);
    await h.fundUsdc(alice, units(1, 6));
    const before = await usdc.balanceOf(alice);
    await h.mintCopra(alice, copra);
    assert.equal(before - (await usdc.balanceOf(alice)), 2n);
  });

  it('reverts with ERC20InsufficientAllowance without an approval', async () => {
    await h.fundUsdc(alice, units(100, 6));
    const [, , needed] = await expectRevert(vault, 'mint', [units(10, 18)], alice, 'ERC20InsufficientAllowance');
    const [required] = await vault.quoteMint(units(10, 18));
    assert.equal(needed, required);
  });

  it('mints with an exact-allowance approval and leaves the allowance at 0', async () => {
    await h.fundUsdc(alice, units(100, 6));
    const amount = units(10, 18);
    const [required, fee] = await vault.quoteMint(amount);
    await send(usdc, 'approve', [vault.target, required], alice);
    const before = await h.balances(alice);
    await send(vault, 'mint', [amount], alice);
    const after = await h.balances(alice);
    assert.equal(before.usdc - after.usdc, required);
    assert.equal(after.copra - before.copra, amount);
    assert.equal(await usdc.allowance(alice, vault.target), 0n);
    assert.equal(await vault.accumulatedFees(), fee);
  });

  it('reverts with ERC20InsufficientBalance when the balance is below the quote', async () => {
    await h.fundUsdc(alice, units(1, 6));
    await send(usdc, 'approve', [vault.target, h.ethers.MaxUint256], alice);
    await expectRevert(vault, 'mint', [units(10, 18)], alice, 'ERC20InsufficientBalance');
  });

  it('charges no fee at 0 bps and exactly 1% at MAX_FEE_BPS', async () => {
    await h.fundUsdc(alice, units(1000, 6));
    const amount = units(100, 18);

    await send(vault, 'setProtocolFee', [0n], OWNER);
    const [base, zeroFee] = await vault.quoteMint(amount);
    assert.equal(zeroFee, 0n);
    await h.mintCopra(alice, amount);

    await send(vault, 'setProtocolFee', [await vault.MAX_FEE_BPS()], OWNER);
    const [required, fee] = await vault.quoteMint(amount);
    assert.equal(fee, (base * 100n) / 10000n);
    assert.equal(required, base + fee);
    await h.mintCopra(alice, amount);
    assert.equal(await vault.accumulatedFees(), fee);
  });

  it('refuses a fee above MAX_FEE_BPS, and fee changes from anyone but the owner', async () => {
    await expectRevert(vault, 'setProtocolFee', [101n], OWNER, 'FeeExceedsMax');
    await expectRevert(vault, 'setProtocolFee', [50n], alice, 'OwnableUnauthorizedAccount');
    assert.equal(await vault.protocolFeeBps(), 25n);
  });

  it('mints to the sender only, whatever they approved for', async () => {
    await h.fundUsdc(alice, units(100, 6));
    await h.mintCopra(alice, units(5, 18));
    assert.equal(await token.balanceOf(bob), 0n);
    assert.equal(await token.balanceOf(alice), units(5, 18));
  });
});
