# Contributing to Copra Protocol

Thank you for your interest in contributing to Copra Protocol ([copra.dev](https://copra.dev)).

## Development Setup

Copra Protocol is built using [Foundry](https://getfoundry.sh/).

1. **Clone the repository**:
   ```bash
   git clone https://github.com/bytesbrains/copra.git
   cd copra
   ```

2. **Install dependencies**:
   ```bash
   forge install
   ```

3. **Run the test suite**:
   ```bash
   forge test -v
   ```

4. **Verify formatting**:
   ```bash
   forge fmt --check
   ```

## Running the E2E suite

The end-to-end suite runs the whole protocol on a disposable local chain: the real contracts deployed by the real script, the dApp served as Cloudflare serves it, real Chrome, and the real oracle feeder. [e2e/README.md](e2e/README.md) describes each part.

**Prerequisites:** Docker with Compose v2, and `make`. Foundry, Node and the browsers run inside the containers. Clone with `--recurse-submodules` (or run `git submodule update --init --recursive`).

**One command:**
```bash
make e2e
```
It brings the stack up, deploys, verifies the deployment and the served dApp, runs the contract scenarios, the feeder scenarios and the tier-1 browser suite, and always tears the stack down. It exits non-zero on the first failure. This is exactly what CI runs on every push and PR.

The other tiers, against a running stack (`make e2e-up`, then `make e2e-down` when done):
```bash
make e2e-metamask                                # tier 2: the real MetaMask extension
make e2e-browser BROWSER_ARGS="-g mint"          # one tier-1 test by name
BASE_MAINNET_RPC=<archive RPC> make e2e-fork     # the scenario suite on a Base-mainnet fork (its own stack)
```

**Where each tier runs in CI**

| | Workflow | When |
| :--- | :--- | :--- |
| Contract scenarios, feeder, tier-1 browser | `CI` (`test.yml`), job "E2E stack" | every push and PR, forks included; no secrets |
| Tier 2, real MetaMask | `e2e-metamask.yml` | nightly 04:00 UTC, by hand, PRs touching `web/` or `e2e/browser/` |
| Base-mainnet fork, real USDC | `e2e-fork.yml` | nightly 03:30 UTC, by hand; needs the `BASE_MAINNET_RPC` secret, so never from forks |
| Release gate | `release.yml` | on a `v*` tag, runs tier 2 and the fork on the tagged commit; nothing is deployed or published unless both are green |

**Debugging a failure from CI.** Every e2e job uploads `e2e/.out/` as an artifact (`e2e-output`, `e2e-metamask` or `e2e-fork-output`):
```bash
gh run download <run-id> -D /tmp/e2e     # or download it from the run's Summary page
```
- `browser/report/` (tier 1) or `browser/metamask-report/` (tier 2): the Playwright HTML report. Open `index.html`. A failing test's screenshots are attached there; in tier 2 they include MetaMask's side panel as it was when the test failed.
- `browser/test-results/<test>/` (tier 1) or `browser/metamask-results/<test>/` (tier 2): for each failing test, `trace.zip` and its video. Open a trace with `npx playwright show-trace trace.zip`, or at [trace.playwright.dev](https://trace.playwright.dev). It holds every action, network request and DOM snapshot.
- `stack.log`: the chain's and the web server's logs, kept when a run fails.
- `deployment.json`: the addresses and roles of the deployment the run used.

To reproduce locally, run the same `make` target. Fresh runs deploy to the same addresses, so the addresses in a CI log are valid locally. For random scenario sequences, `E2E_SEED=<seed> make e2e-scenarios` replays the seed the failure printed.

**When a nightly run fails**, `e2e-nightly-alert.yml` opens an issue labelled `e2e-nightly` and closes it once the next nightly run is green. GitHub disables scheduled workflows on a public repo after **60 days without repository activity**. A disabled nightly simply stops, so no alert can come from it. GitHub emails the repository admins first, and `gh workflow enable e2e-metamask.yml` (or `e2e-fork.yml`) restores it. The release gate runs both suites itself, so a stopped nightly cannot let an untested release through.

## Pull Request Guidelines

1. **Branching**: Create feature branches off `main` (e.g. `feat/oracle-heartbeat-check` or `fix/vault-rounding`).
2. **Testing**: Every change to smart contracts must include corresponding unit and integration tests in `test/`.
3. **Formatting**: Ensure your code passes `forge fmt --check` before opening a pull request.
4. **Clean Commits**: Write clear, descriptive commit messages following the Conventional Commits specification.
