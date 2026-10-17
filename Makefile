.PHONY: all build test test-web test-feeder fmt fmt-check lint clean e2e e2e-up e2e-check e2e-scenarios e2e-down

all: build test test-web test-feeder

build:
	forge build --sizes

test:
	forge test -vvv

test-web:
	node --test test/web/*.test.cjs

test-feeder:
	./test/feeder/oracle-feeder.test.sh

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
	$(E2E_COMPOSE) up -d --wait chain
	$(E2E_COMPOSE) run --rm -T deployer
	@cat e2e/.out/deployment.json

e2e-check:
	$(E2E_COMPOSE) run --rm -T --entrypoint bash -e RPC_URL=http://chain:8545 deployer /repo/e2e/check-deployment.sh /out/deployment.json

# Contract scenarios (#44) against a running stack (make e2e-up first). E2E_SEED replays a random sequence.
e2e-scenarios:
	$(E2E_COMPOSE) run --rm -T --build scenarios

e2e-down:
	$(E2E_COMPOSE) down -v --remove-orphans

# Always tears the stack down, and keeps the first failure's exit code.
e2e:
	@$(MAKE) --no-print-directory e2e-down
	@status=0; $(MAKE) --no-print-directory e2e-up && $(MAKE) --no-print-directory e2e-check \
		&& $(MAKE) --no-print-directory e2e-scenarios || status=$$?; \
		$(MAKE) --no-print-directory e2e-down; exit $$status
