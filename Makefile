.PHONY: all build test test-web fmt fmt-check lint clean e2e e2e-up e2e-check e2e-scenarios e2e-web e2e-feeder e2e-browser e2e-down e2e-fork e2e-fork-up e2e-fork-check e2e-fork-scenarios

all: build test test-web

build:
	forge build --sizes

test:
	forge test -vvv

test-web:
	node --test test/web/*.test.cjs

fmt:
	forge fmt

fmt-check:
	forge fmt --check

lint:
	gitleaks detect --config .gitleaks.toml --verbose
	./test/gitleaks/allowlist.test.sh

clean:
	forge clean

# --- e2e: disposable local chain with the protocol deployed as in production (see e2e/) ---
E2E_COMPOSE = E2E_UID=$(shell id -u) E2E_GID=$(shell id -g) docker compose -f e2e/docker-compose.yml

e2e-up:
	mkdir -p e2e/.out
	$(E2E_COMPOSE) up -d --wait --build chain web
	$(E2E_COMPOSE) run --rm -T deployer
	@cat e2e/.out/deployment.json

e2e-check:
	$(E2E_COMPOSE) run --rm -T --entrypoint bash -e RPC_URL=http://chain:8545 deployer /repo/e2e/check-deployment.sh /out/deployment.json

# Contract scenarios (#44) against a running stack (make e2e-up first). E2E_SEED replays a random sequence.
e2e-scenarios:
	$(E2E_COMPOSE) run --rm -T --build scenarios

# The dApp served by the stack (#43): the shipped files and headers, reading the local chain.
e2e-web:
	$(E2E_COMPOSE) run --rm -T --build -e WEB_URL=http://web:8787 scenarios node /repo/e2e/web/check-web.cjs

# Oracle feeder scenarios (#45) against a running stack: the real feeder, resolving the oracle via the registry.
e2e-feeder:
	$(E2E_COMPOSE) run --rm -T --build feeder

# Tier-1 browser suite (#46): real Chrome against the served dApp; failure artifacts in e2e/.out/browser.
e2e-browser:
	mkdir -p e2e/.out/browser
	$(E2E_COMPOSE) run --rm -T --build browser $(BROWSER_ARGS)

e2e-down:
	$(E2E_COMPOSE) down -v --remove-orphans

# Always tears the stack down, and keeps the first failure's exit code. On failure the chain and web
# logs are kept in e2e/.out/stack.log, next to the browser suite's traces (CI uploads both).
e2e:
	@$(MAKE) --no-print-directory e2e-down
	@status=0; $(MAKE) --no-print-directory e2e-up && $(MAKE) --no-print-directory e2e-check && $(MAKE) --no-print-directory e2e-web \
		&& $(MAKE) --no-print-directory e2e-scenarios && $(MAKE) --no-print-directory e2e-feeder && $(MAKE) --no-print-directory e2e-browser || status=$$?; \
		[ $$status -eq 0 ] || $(E2E_COMPOSE) logs --no-color --timestamps chain web > e2e/.out/stack.log 2>&1; \
		$(MAKE) --no-print-directory e2e-down; exit $$status

# --- e2e on a Base-mainnet fork (#48): DeployCopraMainnet against real USDC, four roles, pinned block ---
# Needs BASE_MAINNET_RPC (an archive RPC). Not on every PR: run it by hand, nightly, and before a mainnet release.
E2E_FORK_COMPOSE = $(E2E_COMPOSE) -f e2e/docker-compose.fork.yml

e2e-fork-up:
	mkdir -p e2e/.out
	$(E2E_FORK_COMPOSE) up -d --wait chain
	$(E2E_FORK_COMPOSE) run --rm -T deployer
	@cat e2e/.out/deployment.json

e2e-fork-check:
	$(E2E_FORK_COMPOSE) run --rm -T --entrypoint bash -e RPC_URL=http://chain:8545 deployer /repo/e2e/check-deployment-fork.sh /out/deployment.json

e2e-fork-scenarios:
	$(E2E_FORK_COMPOSE) run --rm -T --build scenarios

e2e-fork:
	@$(MAKE) --no-print-directory e2e-down
	@status=0; $(MAKE) --no-print-directory e2e-fork-up && $(MAKE) --no-print-directory e2e-fork-check \
		&& $(MAKE) --no-print-directory e2e-fork-scenarios || status=$$?; \
		[ $$status -eq 0 ] || $(E2E_FORK_COMPOSE) logs --no-color --timestamps chain > e2e/.out/stack.log 2>&1; \
		$(MAKE) --no-print-directory e2e-down; exit $$status
