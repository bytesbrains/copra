# e2e stack

A disposable local chain with Copra deployed exactly as on Base Sepolia. It is the base for the end-to-end suites tracked in #41. Docker is the only requirement; Foundry runs inside the containers.

```bash
make e2e            # up → deploy → verify → dApp check → contract, feeder and browser suites → down (what CI runs)
make e2e-up         # bring the chain and the dApp up, deploy, print the manifest; leaves it running
make e2e-check      # verify a running stack
make e2e-web        # check the dApp the stack serves: shipped files and headers, reading the local chain
make e2e-scenarios  # run the contract scenario suite against a running stack
make e2e-feeder     # run the oracle feeder scenarios against a running stack
make e2e-browser    # run the tier-1 browser suite against a running stack (BROWSER_ARGS="-g mint" to filter)
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
Checks the served site from outside: every file is byte-for-byte `web/` built for `local`, every `_headers` rule is served as written with the CSP enforced, and the served scripts run against the chain. A holder mints first, inside a snapshot that is rolled back, and the page must show the registry's `deployment v1`, the oracle price, the supply and the reserves read from anvil. It runs the scripts in a fake DOM; the real browser, the CSP in action and the wallet are the browser suite below.

## Oracle feeder scenarios (`e2e/feeder/`, #45)
`scripts/oracle-feeder.sh`, unchanged, in its own container (the pinned Foundry image plus `python3`, for the benchmark path).
- **Through the registry.** No oracle address is passed in: the feeder resolves it from the canonical registry as in production, and one scenario repoints the registry at a new oracle and checks the next run follows it.
- **No key.** On testnet the updater is the registry owner, whose key never leaves the `oracle-feeder` environment. The suite impersonates it on anvil and runs the feeder with `ORACLE_FEEDER_FROM`, which signs through the node's unlocked account (local chains only, like `DeployCopra.runUnlocked()`). The registry-repoint scenario signs with a key instead, as production does: its new oracle's updater is anvil account 9, whose key is derived at runtime from anvil's public test mnemonic.
- **Checked on chain.** After each run the oracle's price and age, and the last `PriceUpdated` event, must match exactly; a run that should not broadcast must leave the event count unchanged, and a failing run must not reach the broadcast.
- **Scenarios:** skip inside `MIN_UPDATE_INTERVAL`; update after a day; clamp to 19.5% both ways; skip an unchanged price within 5 days, `FORCE=true`, refresh after 5 days; stale recovery, clamped too; RPC down, oracle or interval read failing, interval getter reverting; stale storage unreadable or implausible (a moved layout fails closed); both signers set; registry repointed; a non-allowlisted feed host falling back to the benchmark.
- Each scenario runs in an `evm_snapshot`. It replaces `test/feeder/oracle-feeder.test.sh`, which ran the same checks against a bare oracle.
- The dApp showing the oracle's new age after a recovery is covered by the browser suite (#46).

## Browser suite, tier 1 (`e2e/browser/`, #46)
Playwright `1.63.0` drives **Chrome** (Playwright's full Chromium build in new headless mode, not the headless shell) in its pinned image, against the `web` service with its CSP enforced. The page runs at `http://127.0.0.1:8787` and reads anvil on `127.0.0.1:8545`, as in a browser on the host: inside the container those two ports are plain TCP forwards to `web` and `chain`, so every byte and header is wrangler's.
- **The wallet** is a thin EIP-1193 provider injected as `window.ethereum`, whose logic runs in the test process (`lib/wallet.cjs`). It sends transactions to anvil from its unlocked dev accounts, so each one really executes. It signs only for the account it has selected (4100 otherwise), and a test can make it reject (4001), switch account or chain, or not know the chain (4902). Only the wallet's own UI is skipped; tier 2 (#50) is real MetaMask.
- **Four layers per action.** UI before (quote, fee, button) → the wallet request (contract, function and exact arguments) → the chain (receipt, events, balances read by the suite's own RPC client, and the contract scenarios' invariants) → UI after (balances and every telemetry card against the chain).
- **No noise passes.** Every test fails on a `pageerror`, a `securitypolicyviolation`, or a `console.error` it did not declare.
- **Isolation.** Each test runs in an `evm_snapshot`; pending transactions are dropped before the revert, so one failure cannot stall the next test. Blocks stay at 2s, so pending states are real.
- **Flows:** connect and faucet; approve then mint; redeem; MAX in both tabs, minting and redeeming the exact balance; `wallet_watchAsset` for both tokens; the real oracle feeder moving the price mid-session, and recovering it after a stale spell.
- **Corner cases:** no wallet; wrong and unknown chain; rejections; account changes; `chainChanged`; a stale oracle, before load and mid-session; a vault short of collateral; the price moving between quote and signature, and between signature and mining (the vault's bound, #57); the registry unreachable; the vault's fee unreadable; input edge cases; the displayed quote against the vault's own.
- **On failure** the trace, screenshot and video of each failing test, and the HTML report, are in `e2e/.out/browser/`. `make e2e` also keeps the chain and web logs in `e2e/.out/stack.log`, and CI uploads both.

Found by the suite and fixed in the dApp:
- the page showed its built-in $1.42 when the oracle was stale or unreachable, and quoted against it;
- the same for the fee: an unreadable `protocolFeeBps()` left quotes on the built-in 25 bps (#64);
- every build named Base Sepolia and Basescan, and with the registry unreachable a non-Sepolia build showed Sepolia's contract addresses (#63);
- reverts showed as "unknown custom error";
- the price never refreshed mid-session;
- an account switch kept the old account's signer;
- a quote that had moved was signed without the user seeing it. Since #57 the vault refuses one that moves after signing too, and the page approves the amount entered instead of `MaxUint256`;
- a mint could buy one micro-USDC less than the amount entered, so MAX left dust (`copraForCollateral` was not the largest amount, as it claimed).

## Notes
- The repo is mounted **read-only**. Build output, cache and broadcast logs stay inside the container, and only the manifest is written back (as your uid).
- Block timestamps follow the wall clock, not a fixed genesis time. The dApp shows the oracle's age against your clock, and a fixed past genesis would make every price look stale. Tests that need time move it with `evm_increaseTime`.
- `check-deployment.sh` reads the chain only through the canonical registry and fails on the first mismatch with the manifest.
