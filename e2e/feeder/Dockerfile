# Runs scripts/oracle-feeder.sh as production does: bash, cast and python3 (the benchmark path).
# The same Foundry pin as the chain and deployer; the feeder and its test are mounted at run time.
FROM ghcr.io/foundry-rs/foundry:v1.7.1@sha256:8347b728d5d393dac1c018691b36f506d23b9dcd78341d40ea0fcb11c3a19cdd
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
USER foundry
