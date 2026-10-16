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

## Pull Request Guidelines

1. **Branching**: Create feature branches off `main` (e.g. `feat/oracle-heartbeat-check` or `fix/vault-rounding`).
2. **Testing**: Every change to smart contracts must include corresponding unit and integration tests in `test/`.
3. **Formatting**: Ensure your code passes `forge fmt --check` before opening a pull request.
4. **Clean Commits**: Write clear, descriptive commit messages following the Conventional Commits specification.
