// Real USDC (#48): Circle's FiatToken is pausable and has a blacklist, and the vault holds it. Each
// scenario acts as USDC's own pauser or blacklister, impersonated on the Base-mainnet fork, and checks
// which paths revert, what stays recorded, and that the vault is consistent once the action is undone.
// Only on the fork: TestnetUSDC has neither.
const { describe, it, before, after, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('../lib/harness.cjs');

const { contracts: { usdc, vault, token }, users, VAULT_OWNER, FEE_RECIPIENT, send, expectRevert, units, ethers, rpc, NO_MAX, NO_MIN } = h;
const [alice, bob, carol] = users;

const BLACKLISTED = 'Blacklistable: account is blacklisted';
const PAUSED = 'Pausable: paused';

const fiatToken = new ethers.Contract(usdc.target, [
  'function blacklister() view returns (address)',
  'function pauser() view returns (address)',
  'function isBlacklisted(address) view returns (bool)',
  'function paused() view returns (bool)',
  'function blacklist(address)',
  'function unBlacklist(address)',
  'function pause()',
  'function unpause()',
], h.provider);

describe('real USDC: pause and blacklist', { skip: !h.REAL_USDC && 'TestnetUSDC has no pause or blacklist' }, () => {
  h.isolate({ before, after, beforeEach, afterEach });
  let blacklister, pauser;

  before(async () => {
    [blacklister, pauser] = [await fiatToken.blacklister(), await fiatToken.pauser()];
    for (const a of [blacklister, pauser]) {
      await rpc('anvil_impersonateAccount', [a]);
      await rpc('anvil_setBalance', [a, '0xDE0B6B3A7640000']); // 1 ETH for gas
    }
  });
  after(async () => {
    for (const a of [blacklister, pauser]) await rpc('anvil_stopImpersonatingAccount', [a]);
  });

  /** Alice and bob hold COPRA and the vault has fees: the state every scenario starts from. */
  async function holders() {
    for (const u of [alice, bob]) {
      await h.fundUsdc(u, units(1000, 6));
      await h.mintCopra(u, units(100, 18));
    }
    assert.ok((await vault.accumulatedFees()) > 0n);
  }

  it('funds users from a real holder: transfer, not mint, so totalSupply does not move', async () => {
    const supply = await usdc.totalSupply();
    await h.fundUsdc(alice, units(1000, 6));
    assert.equal(await usdc.balanceOf(alice), units(1000, 6));
    assert.equal(await usdc.totalSupply(), supply);
  });

  it('vault blacklisted: mint, redeem and claimFees revert, so every holder is stuck until it is lifted', async () => {
    await holders();
    await send(fiatToken, 'blacklist', [vault.target], blacklister);
    const reserves = await usdc.balanceOf(vault.target);
    const fees = await vault.accumulatedFees();

    await send(usdc, 'approve', [vault.target, ethers.MaxUint256], carol);
    await h.fundUsdc(carol, units(100, 6));
    await expectRevert(vault, 'mint', [units(10, 18), NO_MAX], carol, BLACKLISTED);
    await expectRevert(vault, 'redeem', [units(100, 18), NO_MIN], alice, BLACKLISTED);
    await expectRevert(vault, 'claimFees', [], FEE_RECIPIENT, BLACKLISTED);
    // Nothing moved: the reserves and fees are frozen in place, not lost, and COPRA still transfers.
    assert.equal(await usdc.balanceOf(vault.target), reserves);
    assert.equal(await vault.accumulatedFees(), fees);
    await send(token, 'transfer', [carol, units(50, 18)], alice);

    await send(fiatToken, 'unBlacklist', [vault.target], blacklister);
    for (const [u, amount] of [[alice, units(50, 18)], [bob, units(100, 18)], [carol, units(50, 18)]]) {
      await send(vault, 'redeem', [amount, NO_MIN], u);
    }
    await send(vault, 'claimFees', [], FEE_RECIPIENT);
    assert.equal(await token.totalSupply(), 0n);
  });

  it('holder blacklisted: their own mint and redeem revert, but their COPRA is not frozen', async () => {
    await holders();
    await send(fiatToken, 'blacklist', [alice], blacklister);

    await expectRevert(vault, 'redeem', [units(100, 18), NO_MIN], alice, BLACKLISTED);
    await expectRevert(vault, 'mint', [units(1, 18), NO_MAX], alice, BLACKLISTED);
    // Others are unaffected.
    await send(vault, 'redeem', [units(100, 18), NO_MIN], bob);
    // COPRA is not USDC: the blacklist does not reach it, so it moves to an address that can redeem.
    await send(token, 'transfer', [carol, units(100, 18)], alice);
    const [out] = await vault.quoteRedeem(units(100, 18));
    await send(vault, 'redeem', [units(100, 18), out], carol);
    assert.equal(await usdc.balanceOf(carol), out);
  });

  it('paused: every path that moves USDC reverts; COPRA still transfers; all of it works after unpause', async () => {
    await holders();
    await send(fiatToken, 'pause', [], pauser);
    const reserves = await usdc.balanceOf(vault.target);

    await expectRevert(vault, 'mint', [units(1, 18), NO_MAX], alice, PAUSED);
    await expectRevert(vault, 'redeem', [units(1, 18), NO_MIN], alice, PAUSED);
    await expectRevert(vault, 'claimFees', [], FEE_RECIPIENT, PAUSED);
    await send(token, 'transfer', [bob, units(10, 18)], alice);
    assert.equal(await usdc.balanceOf(vault.target), reserves);

    await send(fiatToken, 'unpause', [], pauser);
    await h.mintCopra(alice, units(1, 18));
    await send(vault, 'redeem', [units(110, 18), NO_MIN], bob);
    await send(vault, 'claimFees', [], FEE_RECIPIENT);
  });

  it('fee recipient blacklisted: claimFees reverts and the fees stay recorded until the owner moves the recipient', async () => {
    await holders();
    await send(fiatToken, 'blacklist', [FEE_RECIPIENT], blacklister);
    const fees = await vault.accumulatedFees();

    await expectRevert(vault, 'claimFees', [], FEE_RECIPIENT, BLACKLISTED);
    assert.equal(await vault.accumulatedFees(), fees);
    // Holders are not affected by the recipient's blacklisting.
    await send(vault, 'redeem', [units(100, 18), NO_MIN], alice);
    assert.equal(await vault.accumulatedFees() > fees, true, 'the redeem fee accrued on top');

    const accrued = await vault.accumulatedFees();
    await send(vault, 'setFeeRecipient', [carol], VAULT_OWNER);
    await send(vault, 'claimFees', [], bob);
    assert.equal(await usdc.balanceOf(carol), accrued);
    assert.equal(await vault.accumulatedFees(), 0n);
  });
});
