.PHONY: all build test test-web test-feeder fmt fmt-check lint clean

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
