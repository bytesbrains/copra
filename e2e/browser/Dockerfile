# Tier-1 browser suite (#46). Playwright's own image, pinned like everything else in the stack: its
# full Chromium build (Chrome for Testing where one exists) runs in new headless mode, the real browser
# rather than the headless shell. cast comes from the stack's Foundry pin, for the real oracle feeder.
# Dependencies are baked in; the suite, the manifest and the feeder are mounted at run time.
FROM ghcr.io/foundry-rs/foundry:v1.7.1@sha256:8347b728d5d393dac1c018691b36f506d23b9dcd78341d40ea0fcb11c3a19cdd AS foundry

FROM mcr.microsoft.com/playwright:v1.63.0-noble@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27
COPY --from=foundry /usr/local/bin/cast /usr/local/bin/cast
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
ENV NODE_PATH=/app/node_modules PATH=/app/node_modules/.bin:$PATH
