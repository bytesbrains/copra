# Tier-1 browser suite (#46). Playwright's own image, pinned like everything else in the stack: its
# full Chromium build (Chrome for Testing where one exists) runs in new headless mode, the real browser
# rather than the headless shell. cast comes from the stack's Foundry pin, for the real oracle feeder.
# Dependencies are baked in; the suite, the manifest and the feeder are mounted at run time.
FROM ghcr.io/foundry-rs/foundry:v1.7.1@sha256:8347b728d5d393dac1c018691b36f506d23b9dcd78341d40ea0fcb11c3a19cdd AS foundry

FROM mcr.microsoft.com/playwright:v1.63.0-noble@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27 AS tier1
COPY --from=foundry /usr/local/bin/cast /usr/local/bin/cast
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
ENV NODE_PATH=/app/node_modules PATH=/app/node_modules/.bin:$PATH

# Tier 2 (#50): the same image plus the MetaMask extension, pinned to one release by URL and checksum.
# Upgrades go in their own PR: change the version and the checksum together, and run the tier-2 trial.
FROM tier1 AS metamask
ADD --checksum=sha256:7ba00bfe4fe8b0ffb27be1e8fc06506248f1b888cb4f2e5e5e8b1c37f461f262 \
    https://github.com/MetaMask/metamask-extension/releases/download/v13.49.0/metamask-chrome-13.49.0.zip /tmp/metamask.zip
RUN python3 -m zipfile -e /tmp/metamask.zip /opt/metamask && rm /tmp/metamask.zip && chmod -R a+rX /opt/metamask
ENV METAMASK_DIR=/opt/metamask
