// CopraVault's collateral-decimal branches (#44): < 18 (USDC), == 18 (DAI-like) and > 18. Each runs a
// full mint/redeem round trip with real transactions, and the amounts are checked against an
// independent model of the quote formula, not against the vault's own quote functions.
const { describe, it, before, after, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('../lib/harness.cjs');

const { users, OWNER, send, expectRevert, units, ethers, NO_MAX, NO_MIN } = h;
const [alice, bob] = users;
const PRICE = 142000000n; // $1.42, 8 decimals
const FEE_BPS = 25n;

const ceilDiv = (a, b) => (a + b - 1n) / b;
function model(copra, decimals) {
  const d = BigInt(decimals);
  const scale = (v18, up) => (d < 18n ? (up ? ceilDiv(v18, 10n ** (18n - d)) : v18 / 10n ** (18n - d)) : v18 * 10n ** (d - 18n));
  const mintBase = scale(ceilDiv(copra * PRICE, 10n ** 8n), true);
  const redeemBase = scale((copra * PRICE) / 10n ** 8n, false);
  const mintFee = (mintBase * FEE_BPS) / 10000n;
  const redeemFee = (redeemBase * FEE_BPS) / 10000n;
  return { mintPaid: mintBase + mintFee, mintFee, redeemOut: redeemBase - redeemFee, redeemFee };
}

async function deploySet(decimals) {
  const collateral = await h.deploy('MockCollateral', [decimals]);
  const oracle = await h.deploy('CopraOracle', [OWNER, PRICE]);
  const vault = await h.deploy('CopraVault', [collateral.target, decimals, oracle.target, OWNER, OWNER]);
  const token = await h.deploy('CopraToken', [vault.target]);
  await send(vault, 'setCopraToken', [token.target], OWNER);
  h.invariants.extraVaults.push({ vault, token, collateral });
  return { collateral, vault, token };
}

describe('collateral decimals', () => {
  h.isolate({ before, after, beforeEach, afterEach });

  for (const decimals of [6, 18, 24]) {
    it(`${decimals}-decimal collateral: mint and redeem match the model exactly`, async () => {
      const { collateral, vault, token } = await deploySet(decimals);
      await send(collateral, 'mint', [alice, units(10_000, decimals)], alice);
      await send(collateral, 'approve', [vault.target, ethers.MaxUint256], alice);

      for (const copra of [1n, units(1, 18), units(123.456789, 18), units(5000, 18)]) {
        const m = model(copra, decimals);
        const before = await collateral.balanceOf(alice);
        await send(vault, 'mint', [copra, NO_MAX], alice);
        assert.equal(before - (await collateral.balanceOf(alice)), m.mintPaid, `mint ${copra}`);

        const mid = await collateral.balanceOf(alice);
        await send(vault, 'redeem', [copra, NO_MIN], alice);
        assert.equal((await collateral.balanceOf(alice)) - mid, m.redeemOut, `redeem ${copra}`);
      }
      assert.equal(await token.totalSupply(), 0n);
      // A round trip never pays out more than it took in.
      assert.ok((await collateral.balanceOf(vault.target)) >= (await vault.accumulatedFees()));
    });
  }

  it('the 6-decimal mock quotes exactly like the deployed USDC vault', async () => {
    const { vault } = await deploySet(6);
    for (const copra of [1n, units(0.000001, 18), units(1, 18), units(999999.999999, 18)]) {
      assert.deepEqual([...(await vault.quoteMint(copra))], [...(await h.contracts.vault.quoteMint(copra))]);
      assert.deepEqual([...(await vault.quoteRedeem(copra))], [...(await h.contracts.vault.quoteRedeem(copra))]);
    }
  });

  it('a redeem on an 18-decimal vault cannot touch another vault\'s collateral', async () => {
    const a = await deploySet(18);
    const b = await deploySet(18);
    for (const s of [a, b]) {
      await send(s.collateral, 'mint', [alice, units(1000, 18)], alice);
      await send(s.collateral, 'approve', [s.vault.target, ethers.MaxUint256], alice);
    }
    await send(a.vault, 'mint', [units(100, 18), NO_MAX], alice);
    await send(b.collateral, 'mint', [bob, units(1000, 18)], bob);
    await expectRevert(b.vault, 'redeem', [units(100, 18), NO_MIN], alice, 'InsufficientVaultCollateral');
  });
});
