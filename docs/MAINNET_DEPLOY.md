# Mainnet Deploy (Base, chain id 8453)

**Copra Protocol** ([copra.dev](https://copra.dev))

`script/DeployCopraMainnet.s.sol` deploys Copra against Circle's USDC with four separate roles (#47). `script/DeployCopra.s.sol` is testnet only. It deploys `TestnetUSDC`, which has a public faucet, and gives one key every role, so it refuses chain id 8453.

---

## 1. Roles

| Input | Role | Notes |
| :--- | :--- | :--- |
| `PRIVATE_KEY` | **Deployer** | A throwaway key that only pays gas. Once the multisig accepts the vault, it holds no role. |
| `COPRA_OWNER` | **Multisig**: registry owner and vault owner | Must be a contract. It owns `CopraRegistry` **from birth**: the owner is part of the registry's CREATE2 init code, so the multisig fixes the registry's permanent address, and no other key ever owns it. |
| `COPRA_ORACLE_UPDATER` | **Oracle updater** (immutable) | The feeder's key. It may not be the deployer unless `COPRA_ALLOW_DEPLOYER_UPDATER=true`. |
| `COPRA_FEE_RECIPIENT` | **Fee recipient** | Receives `claimFees()`. It may not be the deployer. The multisig is a sensible choice. |

`COPRA_COLLATERAL` and `COPRA_COLLATERAL_DECIMALS` are `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` and `6`. On chain 8453 the script accepts no other token. `COPRA_INITIAL_PRICE` is the day's copra benchmark in USD with 8 decimals (`142000000` = $1.42). There is no default.

## 2. Pre-flight

1. **The multisig exists on Base**, and its signers and threshold are final. The registry's address depends on it, and changing owners later does not move the address.
2. **The registry's address**, computed offline. Put it in `networks/mainnet.json` (`registry`) only after step 4 of the deploy:
   ```bash
   forge script script/DeployCopraMainnet.s.sol:DeployCopraMainnet --sig 'registryAddress(address)' $COPRA_OWNER
   ```
3. **The feeder's key** is the updater, and it is funded. It is immutable: a wrong updater means redeploying the oracle and the vault.
4. **The deployer** has enough ETH on Base for four contract creations and two calls. Use a fresh key.
5. **Dry run** against Base, with the same environment and no `--broadcast`. The script runs every refusal in `check()` before it broadcasts anything:
   ```bash
   forge script script/DeployCopraMainnet.s.sol:DeployCopraMainnet --rpc-url $BASE_RPC
   ```
6. **Fork run** (#48). Start `anvil --fork-url $BASE_RPC`, give a test address code to stand in for the multisig (`cast rpc anvil_setCode <addr> 0x00`), then broadcast to the fork and execute the batch below as that address (`anvil_impersonateAccount`).

## 3. Deploy

```bash
PRIVATE_KEY=... COPRA_OWNER=0x... COPRA_ORACLE_UPDATER=0x... COPRA_FEE_RECIPIENT=0x... \
COPRA_COLLATERAL=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 COPRA_COLLATERAL_DECIMALS=6 COPRA_INITIAL_PRICE=... \
forge script script/DeployCopraMainnet.s.sol:DeployCopraMainnet --rpc-url $BASE_RPC --broadcast
```

The script:
1. Deploys the multisig's registry, or reuses it if it already exists.
2. Deploys the oracle, the vault and the token.
3. Binds the token to the vault.
4. Offers the vault to the multisig (`Ownable2Step`).

**Nothing is live yet.** The registry still points at nothing (version 0), so copra.dev and the feeder ignore the new set. Before the multisig acts, the deployer still owns the vault. The token is already bound, so all it can do is set the fee (capped at 1%) or the fee recipient, or offer the vault to someone else. Execute the batch promptly, and check `pendingOwner()` before signing.

The script prints the multisig's batch. Execute it as **one** transaction:

| # | To | Call |
| :--- | :--- | :--- |
| 1 | `CopraVault` | `acceptOwnership()` |
| 2 | `CopraRegistry` | `setDeployment(collateral, oracle, vault, token)` |

**If the broadcast stops part-way** (a dropped transaction, gas, a nonce clash), whatever was already sent stays on chain. Nothing goes live: the registry still points at the old set, and `setDeployment` refuses a vault with no token bound (`InconsistentDeployment`). Run the script again. It reuses the registry and deploys a fresh oracle, vault and token, and the half-finished contracts are simply abandoned. Don't try to finish them by hand.

## 4. Post-deploy verification

Read everything back through the registry, from an RPC that is not the one you deployed with:

```bash
cast call $REGISTRY 'getDeployment()(address,address,address,address,uint256,uint256)' --rpc-url $BASE_RPC
cast call $REGISTRY 'owner()(address)'                  # the multisig
cast call $VAULT    'owner()(address)'                  # the multisig
cast call $VAULT    'pendingOwner()(address)'           # 0x0
cast call $VAULT    'feeRecipient()(address)'           # COPRA_FEE_RECIPIENT
cast call $VAULT    'collateralToken()(address)'        # USDC
cast call $VAULT    'copraToken()(address)'             # the token
cast call $TOKEN    'vault()(address)'                  # the vault
cast call $ORACLE   'feedUpdater()(address)'            # COPRA_ORACLE_UPDATER
cast call $ORACLE   'getCopraPriceUSD()(uint256,uint256)'
```

- [ ] `getDeployment()` returns version 1 (or one more than before) and the four addresses the script printed.
- [ ] The multisig owns the registry and the vault, and no ownership is pending.
- [ ] The four roles are four different addresses. The deployer is none of them.
- [ ] Set `registry` in `networks/mainnet.json`. Then `node scripts/web-env.cjs mainnet <dir>` builds the mainnet site.
- [ ] Point the feeder at the registry with the updater's key, and watch its first update land a day later (`MIN_UPDATE_INTERVAL`).

### The mainnet site's Worker

A mainnet dApp must exist at exactly one address: its own domain. The testnet Worker also answers at `copra.<subdomain>.workers.dev` and at a public preview for every branch (#78). For mainnet, that would mean live copies of the site on addresses that aren't copra.dev, some running unreviewed code against real USDC. The mainnet Worker's wrangler config therefore sets:

```jsonc
"workers_dev": false,   // no <name>.<subdomain>.workers.dev copy
"preview_urls": false,  // no per-branch or per-version previews
"routes": [{ "pattern": "<mainnet domain>", "custom_domain": true }]
```

- [ ] The mainnet Worker's config has `workers_dev: false`, `preview_urls: false` and only its custom domain as a route.
- [ ] `https://<worker>.<subdomain>.workers.dev/` doesn't serve the site (no 200 with the dApp).
- [ ] Workers Builds for that Worker has non-production branch builds turned off. Check that pull requests from forks are never built for any Worker.

## 5. Later redeploys

Run the same script with the same `COPRA_OWNER`. It reuses the registry and prints a new batch. The old set stays live until the multisig executes `setDeployment` for the new one.
