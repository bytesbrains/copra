# e2e stack

A disposable local chain with Copra deployed exactly as on Base Sepolia. It is the base for the end-to-end suites tracked in #41. Docker is the only requirement; Foundry runs inside the containers.

```bash
make e2e            # up → deploy → verify → dApp check → contract scenarios → down (what CI runs)
make e2e-up         # bring the chain and the dApp up, deploy, print the manifest; leaves it running
make e2e-check      # verify a running stack
make e2e-web        # check the dApp the stack serves: shipped files and headers, reading the local chain
make e2e-scenarios  # run the contract scenario suite against a running stack
make e2e-down       # stop and delete everything
```

## What you get
- **`chain`**: anvil `v1.7.1` (pinned by digest) on `127.0.0.1:8545` (`E2E_RPC_PORT` to change). It uses **chain id 84532** (Base Sepolia), so the dApp and wallets treat it as that network, and **2-second blocks** like Base, so pending states are real.
- **`deployer`**: runs `DeployCopra` through `forge script` **as the production registry owner** `0x91d3…eB8E`, impersonated on anvil (`runUnlocked()`). `CopraRegistry` therefore lands at its canonical address `0x379c…Bb25`, the one the dApp and oracle feeder already hardcode. As in production, that one account is the vault owner, fee recipient and oracle updater. Impersonation is switched off again after the deploy, so a test that acts as the owner must impersonate it explicitly.
- **`web`**: the dApp on `http://127.0.0.1:8787` (`E2E_WEB_PORT` to change), served by **`wrangler dev`** from the repo's own `wrangler.jsonc`, so assets and `_headers` (the enforced CSP included) are handled as Cloudflare handles them. The site is `web/` built for the **`local`** environment (#43) by `scripts/web-env.cjs`. It differs from what ships only in `assets/network.js` (anvil's RPC on the host port, no explorer) and the RPC in `connect-src`. Open it in a browser with a wallet on `http://127.0.0.1:8545`, chain id 84532. wrangler is pinned at least two weeks old, so its runtime can trail the repo's `compatibility_date`. The stack then caps the date at the newest the runtime supports (it logs this), which changes nothing for an assets-only Worker.
- **`e2e/.out/deployment.json`**: chain id, RPC, contract addresses, roles and the 10 funded anvil accounts (unlocked, so `eth_sendTransaction` from them just works). Addresses are deterministic: the same on every fresh run.

## Contract scenarios (`e2e/scenarios/`, #44)
`node --test` with ethers 6.13.4, the version the dApp loads, in a pinned `node:24-slim` container.
- **Real transactions only.** Every state change is a signed transaction from an anvil account through `eth_sendTransaction`, as a wallet sends it.
- **Expected failures are mined.** `expectRevert` sends with a fixed gas limit, so the transaction is mined and fails on chain. It then reads the revert data back with `debug_traceTransaction` and requires the exact custom error. A failed gas estimate can never pass for a revert.
- **Invariants after every transaction:**
  - the vault holds at least `accumulatedFees`;
  - `accumulatedFees` equals the fees taken minus the fees claimed (summed from events);
  - `totalSupply` equals the COPRA minted minus the COPRA burned, and only the vault mints;
  - the registry still points where the test expects.
- **Isolation.** Each test runs in an `evm_snapshot`, which also rolls back time travel. Boundaries are hit exactly with `evm_setNextBlockTimestamp`.
- **Model-based run.** `lifecycle` drives a seeded random sequence of mints, redeems, transfers, burns, claims and price moves, ending in a bank run. Before every redeem it predicts from chain state whether the vault can pay, and requires the chain to agree. `E2E_SEED=<n> make e2e-scenarios` replays a sequence.
- **Mining.** The suite switches the chain to mine per transaction while it runs, for speed, and restores 2s blocks afterwards.

To iterate from the host: `make e2e-up`, then `cd e2e/scenarios && npm ci && node --test --test-concurrency=1 'tests/*.test.cjs'`.

## dApp check (`e2e/web/check-web.cjs`, #43)
Checks the served site from outside: every file is byte-for-byte `web/` built for `local`, every `_headers` rule is served as written with the CSP enforced, and the served scripts run against the chain. A holder mints first, inside a snapshot that is rolled back, and the page must show the registry's `deployment v1`, the oracle price, the supply and the reserves read from anvil. It runs the scripts in a fake DOM; the real browser, the CSP in action and the wallet are #46.

## Notes
- The repo is mounted **read-only**. Build output, cache and broadcast logs stay inside the container, and only the manifest is written back (as your uid).
- Block timestamps follow the wall clock, not a fixed genesis time. The dApp shows the oracle's age against your clock, and a fixed past genesis would make every price look stale. Tests that need time move it with `evm_increaseTime`.
- `check-deployment.sh` reads the chain only through the canonical registry and fails on the first mismatch with the manifest.
