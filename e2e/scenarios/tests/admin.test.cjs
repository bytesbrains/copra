// Ownership, fee recipient and registry (#44).
const { describe, it, before, after, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('../lib/harness.cjs');

const { contracts: { usdc, oracle, vault, token, registry }, users, OWNER, send, expectRevert, units, ethers, NO_MAX, NO_MIN } = h;
const [alice, bob, carol] = users;

describe('admin and registry', () => {
  h.isolate({ before, after, beforeEach, afterEach });

  // An action only the current owner may take, per contract.
  const ownerOnly = {
    vault: { contract: vault, method: 'setProtocolFee', args: [30n] },
    registry: { contract: registry, method: 'setDeployment', args: [usdc.target, oracle.target, vault.target, token.target] },
  };

  for (const [name, { contract, method, args }] of Object.entries(ownerOnly)) {
    it(`${name}: Ownable2Step keeps the old owner in control until the new one accepts`, async () => {
      await send(contract, 'transferOwnership', [bob], OWNER);
      assert.equal(await contract.pendingOwner(), bob);
      await expectRevert(contract, method, args, bob, 'OwnableUnauthorizedAccount'); // pending is not owner
      await send(contract, method, args, OWNER); // old owner still in control

      await expectRevert(contract, 'acceptOwnership', [], carol, 'OwnableUnauthorizedAccount');
      await send(contract, 'acceptOwnership', [], bob);
      assert.equal(await contract.owner(), bob);
      await expectRevert(contract, method, args, OWNER, 'OwnableUnauthorizedAccount');
      await send(contract, method, args, bob);
    });
  }

  it('binds the token once: a second setCopraToken reverts', async () => {
    await expectRevert(vault, 'setCopraToken', [alice], OWNER, 'VaultAlreadyInitialized');
    assert.equal(await vault.copraToken(), token.target);
  });

  it('sends claimed fees to the current recipient only, whoever triggers the claim', async () => {
    await expectRevert(vault, 'setFeeRecipient', [ethers.ZeroAddress], OWNER, 'ZeroAddress');
    await expectRevert(vault, 'setFeeRecipient', [alice], alice, 'OwnableUnauthorizedAccount');
    await h.fundUsdc(alice, units(1000, 6));
    await h.mintCopra(alice, units(500, 18));
    await send(vault, 'setFeeRecipient', [carol], OWNER);

    const fees = await vault.accumulatedFees();
    const before = { carol: await usdc.balanceOf(carol), owner: await usdc.balanceOf(OWNER), bob: await usdc.balanceOf(bob) };
    await send(vault, 'claimFees', [], bob);
    assert.equal((await usdc.balanceOf(carol)) - before.carol, fees);
    assert.equal(await usdc.balanceOf(OWNER), before.owner);
    assert.equal(await usdc.balanceOf(bob), before.bob);
    await expectRevert(vault, 'claimFees', [], bob, 'ZeroAmount');
  });

  it('refuses an inconsistent or incomplete deployment set', async () => {
    const strayOracle = await h.deploy('CopraOracle', [OWNER, 142000000n]);
    await expectRevert(registry, 'setDeployment', [usdc.target, strayOracle.target, vault.target, token.target], OWNER, 'InconsistentDeployment');
    await expectRevert(registry, 'setDeployment', [usdc.target, oracle.target, vault.target, ethers.ZeroAddress], OWNER, 'ZeroAddress');
    await expectRevert(registry, 'setDeployment', [usdc.target, oracle.target, vault.target, token.target], alice, 'OwnableUnauthorizedAccount');
  });

  it('repoints to a redeployed set (version 2) without stranding holders of the old one', async () => {
    await h.fundUsdc(alice, units(1000, 6));
    await h.mintCopra(alice, units(100, 18));

    const newOracle = await h.deploy('CopraOracle', [OWNER, 142000000n]);
    const newVault = await h.deploy('CopraVault', [usdc.target, 6, newOracle.target, OWNER, OWNER]);
    const newToken = await h.deploy('CopraToken', [newVault.target]);
    await send(newVault, 'setCopraToken', [newToken.target], OWNER);
    h.invariants.expected.registry = { ...h.manifest.contracts, oracle: newOracle.target, vault: newVault.target, token: newToken.target };
    h.invariants.extraVaults.push({ vault: newVault, token: newToken, collateral: usdc });
    await send(registry, 'setDeployment', [usdc.target, newOracle.target, newVault.target, newToken.target], OWNER);
    assert.equal(await registry.version(), 2n);

    // Old holders redeem from the vault they minted in; the new set works independently.
    await send(vault, 'redeem', [units(100, 18), NO_MIN], alice);
    await send(usdc, 'approve', [newVault.target, ethers.MaxUint256], alice);
    await send(newVault, 'mint', [units(10, 18), NO_MAX], alice);
    assert.equal(await newToken.balanceOf(alice), units(10, 18));
  });
});
