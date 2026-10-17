# e2e stack

A disposable local chain with Copra deployed exactly as on Base Sepolia. It is the base for the end-to-end suites tracked in #41. Docker is the only requirement; Foundry runs inside the containers.

```bash
make e2e        # up → deploy → verify → down (what CI runs)
make e2e-up     # bring the chain up, deploy, print the manifest; leaves it running
make e2e-check  # verify a running stack
make e2e-down   # stop and delete everything
```

## What you get
- **`chain`**: anvil `v1.7.1` (pinned by digest) on `127.0.0.1:8545` (`E2E_RPC_PORT` to change). It uses **chain id 84532** (Base Sepolia), so the dApp and wallets treat it as that network, and **2-second blocks** like Base, so pending states are real.
- **`deployer`**: runs `DeployCopra` through `forge script` **as the production registry owner** `0x91d3…eB8E`, impersonated on anvil (`runUnlocked()`). `CopraRegistry` therefore lands at its canonical address `0x379c…Bb25`, the one the dApp and oracle feeder already hardcode. As in production, that one account is the vault owner, fee recipient and oracle updater. Impersonation is switched off again after the deploy, so a test that acts as the owner must impersonate it explicitly.
- **`e2e/.out/deployment.json`**: chain id, RPC, contract addresses, roles and the 10 funded anvil accounts (unlocked, so `eth_sendTransaction` from them just works). Addresses are deterministic: the same on every fresh run.

## Notes
- The repo is mounted **read-only**. Build output, cache and broadcast logs stay inside the container, and only the manifest is written back (as your uid).
- Block timestamps follow the wall clock, not a fixed genesis time. The dApp shows the oracle's age against your clock, and a fixed past genesis would make every price look stale. Tests that need time move it with `evm_increaseTime`.
- `check-deployment.sh` reads the chain only through the canonical registry and fails on the first mismatch with the manifest.
