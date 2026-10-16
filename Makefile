.PHONY: all build test test-web fmt fmt-check lint clean

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

clean:
	forge clean
