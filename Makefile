.PHONY: all build test fmt fmt-check lint clean

all: build test

build:
	forge build --sizes

test:
	forge test -vvv

fmt:
	forge fmt

fmt-check:
	forge fmt --check

lint:
	gitleaks detect --config .gitleaks.toml --verbose

clean:
	forge clean
