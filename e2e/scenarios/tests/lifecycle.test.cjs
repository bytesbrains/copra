// End-to-end use cases (#44): the flows real users and operators go through, with real transactions.
const { describe, it, before, after, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('../lib/harness.cjs');

const { contracts: { usdc, oracle, vault, token }, users, OWNER, send, expectRevert, units, ethers } = h;
const [alice, bob, carol] = users;

// Deterministic PRNG (mulberry32), so a failing sequence replays exactly. Override with E2E_SEED.
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Predicts from chain state whether the vault can pay, then requires the redeem to do exactly that. */
async function redeemAsPredicted(who, copra) {
  const [out, fee] = await vault.quoteRedeem(copra);
  const available = (await usdc.balanceOf(vault.target)) - (await vault.accumulatedFees());
  if (out + fee > available) {
    await expectRevert(vault, 'redeem', [copra], who, 'InsufficientVaultCollateral');
    return false;
  }
  const before = await usdc.balanceOf(who);
  await send(vault, 'redeem', [copra], who);
  assert.equal((await usdc.balanceOf(who)) - before, out);
  return true;
}

describe('lifecycle', () => {
  h.isolate({ before, after, beforeEach, afterEach });

  it('faucet → approve → mint → transfer → the receiver redeems', async () => {
    await send(usdc, 'faucet', [alice, units(1000, 6)], alice);
    const amount = units(250, 18);
    const [required] = await vault.quoteMint(amount);
    await send(usdc, 'approve', [vault.target, required], alice);
    await send(vault, 'mint', [amount], alice);
    await send(token, 'transfer', [bob, units(100, 18)], alice);

    const [out] = await vault.quoteRedeem(units(100, 18));
    const before = await usdc.balanceOf(bob);
    await send(vault, 'redeem', [units(100, 18)], bob); // no approval needed to redeem
    assert.equal((await usdc.balanceOf(bob)) - before, out);
    assert.equal(await token.balanceOf(alice), units(150, 18));
  });

  it('the owner changes the fee and the recipient; quotes, mints and claims follow', async () => {
    await h.fundUsdc(alice, units(5000, 6));
    await send(usdc, 'approve', [vault.target, ethers.MaxUint256], alice);
    await send(vault, 'mint', [units(1000, 18)], alice);
    const feeAt25 = await vault.accumulatedFees();

    await send(vault, 'setProtocolFee', [80n], OWNER);
    const [, fee80] = await vault.quoteMint(units(1000, 18));
    await send(vault, 'mint', [units(1000, 18)], alice);
    assert.equal((await vault.accumulatedFees()) - feeAt25, fee80);
    assert.ok(fee80 > feeAt25 * 3n, 'fee quote follows the new rate');

    await send(vault, 'setFeeRecipient', [carol], OWNER);
    const fees = await vault.accumulatedFees();
    await send(vault, 'claimFees', [], alice);
    assert.equal(await usdc.balanceOf(carol), fees);
  });

  it('many users over many days: every redeem succeeds or fails exactly as predicted', async (t) => {
    const seed = Number(process.env.E2E_SEED || 20261017);
    const rand = rng(seed);
    t.diagnostic(`seed ${seed} (set E2E_SEED to replay)`);
    const actors = users.slice(0, 6);
    for (const a of actors) {
      await h.fundUsdc(a, units(20_000, 6));
      await send(usdc, 'approve', [vault.target, ethers.MaxUint256], a);
    }
    const pick = (xs) => xs[Math.floor(rand() * xs.length)];
    const amountUpTo = (max) => (max * BigInt(Math.floor(rand() * 1_000_000) + 1)) / 1_000_000n;
    const counts = { mint: 0, redeem: 0, refused: 0, transfer: 0, burn: 0, claim: 0, price: 0 };

    for (let step = 0; step < 80; step++) {
      const who = pick(actors);
      const r = rand();
      if (r < 0.32) {
        const copra = amountUpTo(units(2000, 18));
        const [required] = await vault.quoteMint(copra);
        if (required > (await usdc.balanceOf(who))) continue;
        await send(vault, 'mint', [copra], who);
        counts.mint++;
      } else if (r < 0.62) {
        const held = await token.balanceOf(who);
        if (held === 0n) continue;
        if (await redeemAsPredicted(who, rand() < 0.3 ? held : amountUpTo(held))) counts.redeem++;
        else counts.refused++;
      } else if (r < 0.72) {
        const held = await token.balanceOf(who);
        if (held === 0n) continue;
        await send(token, 'transfer', [pick(actors), amountUpTo(held)], who);
        counts.transfer++;
      } else if (r < 0.76) {
        const held = await token.balanceOf(who);
        if (held === 0n) continue;
        await send(token, 'burn', [amountUpTo(held / 10n || held)], who);
        counts.burn++;
      } else if (r < 0.82) {
        if ((await vault.accumulatedFees()) === 0n) continue;
        await send(vault, 'claimFees', [], who);
        counts.claim++;
      } else {
        // The feeder's daily update: -4% to +12%, biased upward so the vault runs short of backing.
        const p = (await oracle.getCopraPriceUSD())[0];
        const bps = BigInt(Math.floor(rand() * 1600) - 400);
        await h.postPrice((p * (10000n + bps)) / 10000n);
        counts.price++;
      }
    }

    // Bank run after a final rise: everyone tries to leave in full, in random order. Early redeemers are
    // paid at the new price; once the vault runs short, the rest are refused, each exactly as predicted.
    const p = (await oracle.getCopraPriceUSD())[0];
    await h.postPrice((p * 12n) / 10n);
    counts.price++;
    for (const who of [...actors].sort(() => rand() - 0.5)) {
      const held = await token.balanceOf(who);
      if (held === 0n) continue;
      if (await redeemAsPredicted(who, held)) counts.redeem++;
      else counts.refused++;
    }
    await send(vault, 'claimFees', [], alice); // fees stay claimable after the run

    t.diagnostic(`steps: ${JSON.stringify(counts)}`);
    assert.ok(counts.mint > 5 && counts.redeem > 5 && counts.price > 3, 'the sequence exercised every path');
    assert.ok(counts.refused > 0, 'the bank run reached InsufficientVaultCollateral');
  });
});
