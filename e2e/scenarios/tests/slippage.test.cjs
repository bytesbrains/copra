// Slippage (#44 ⚠️): mint and redeem take no bound on what the user pays or receives, and the dApp
// approves MaxUint256. These tests MEASURE what happens when the price or fee moves between the quote
// the user saw and the transaction landing, and pin today's behaviour, so a fix shows up as a diff.
const { describe, it, before, after, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('../lib/harness.cjs');

const { contracts: { usdc, oracle, vault }, users, OWNER, send, expectRevert, units, ethers } = h;
const [alice] = users;
const AMOUNT = units(1000, 18);
const pct = (a, b) => `${((Number(a - b) * 100) / Number(b)).toFixed(4)}%`;

async function paidForMint(user, copra) {
  const before = await usdc.balanceOf(user);
  await send(vault, 'mint', [copra], user);
  return before - (await usdc.balanceOf(user));
}

/** The largest price the collar accepts from the current one (2000.99 bps, see oracle.test.cjs). */
async function maxCollarPrice(up = true) {
  const p = (await oracle.getCopraPriceUSD())[0];
  const firstRejected = (p * 2001n + 9999n) / 10000n;
  return up ? p + firstRejected - 1n : p - firstRejected + 1n;
}

describe('slippage between quote and transaction', () => {
  h.isolate({ before, after, beforeEach, afterEach });

  it('MaxUint256 approval: a price update landing first makes the mint cost up to ~20% more than quoted', async (t) => {
    await h.fundUsdc(alice, units(5000, 6));
    await send(usdc, 'approve', [vault.target, ethers.MaxUint256], alice); // what the dApp does
    const [quoted] = await vault.quoteMint(AMOUNT);

    await h.postPrice(await maxCollarPrice(true)); // lands between the quote and the user's tx
    const paid = await paidForMint(alice, AMOUNT);
    t.diagnostic(`quoted ${ethers.formatUnits(quoted, 6)} USDC, paid ${ethers.formatUnits(paid, 6)} USDC (+${pct(paid, quoted)})`);
    assert.ok(paid > (quoted * 12n) / 10n, 'paid over 20% more than the quote, with no way to refuse');
  });

  it('MaxUint256 approval: a fee raise to MAX_FEE_BPS landing first adds 0.75%', async (t) => {
    await h.fundUsdc(alice, units(5000, 6));
    await send(usdc, 'approve', [vault.target, ethers.MaxUint256], alice);
    const [quoted] = await vault.quoteMint(AMOUNT);
    await send(vault, 'setProtocolFee', [100n], OWNER);
    const paid = await paidForMint(alice, AMOUNT);
    t.diagnostic(`quoted ${ethers.formatUnits(quoted, 6)} USDC, paid ${ethers.formatUnits(paid, 6)} USDC (+${pct(paid, quoted)})`);
    assert.ok(paid > quoted);
  });

  it('worst case, price and fee both moved: the user pays ~20.9% over the quote', async (t) => {
    await h.fundUsdc(alice, units(5000, 6));
    await send(usdc, 'approve', [vault.target, ethers.MaxUint256], alice);
    const [quoted] = await vault.quoteMint(AMOUNT);
    await send(vault, 'setProtocolFee', [100n], OWNER);
    await h.postPrice(await maxCollarPrice(true));
    const paid = await paidForMint(alice, AMOUNT);
    t.diagnostic(`quoted ${ethers.formatUnits(quoted, 6)} USDC, paid ${ethers.formatUnits(paid, 6)} USDC (+${pct(paid, quoted)})`);
    assert.ok(paid > (quoted * 1209n) / 1000n);
  });

  it('exact approval of the quote already protects the user: the same mint reverts instead', async () => {
    await h.fundUsdc(alice, units(5000, 6));
    const [quoted] = await vault.quoteMint(AMOUNT);
    await send(usdc, 'approve', [vault.target, quoted], alice);
    await h.postPrice(await maxCollarPrice(true));
    await expectRevert(vault, 'mint', [AMOUNT], alice, 'ERC20InsufficientAllowance');
  });

  it('redeem has no minimum out: a price drop landing first pays ~20% less, and approvals cannot help', async (t) => {
    await h.fundUsdc(alice, units(5000, 6));
    await h.mintCopra(alice, AMOUNT);
    const [quoted] = await vault.quoteRedeem(AMOUNT);
    await h.postPrice(await maxCollarPrice(false));
    const before = await usdc.balanceOf(alice);
    await send(vault, 'redeem', [AMOUNT], alice);
    const got = (await usdc.balanceOf(alice)) - before;
    t.diagnostic(`quoted ${ethers.formatUnits(quoted, 6)} USDC, received ${ethers.formatUnits(got, 6)} USDC (${pct(got, quoted)})`);
    assert.ok(got < (quoted * 8n) / 10n + units(1, 6));
  });
});
