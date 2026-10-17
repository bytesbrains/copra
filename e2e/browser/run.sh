#!/usr/bin/env bash
# Runs the browser suite in its container. The suite is copied out of the read-only repo mount, so
# @playwright/test resolves to the image's one copy (NODE_PATH) even when the host has its own
# e2e/browser/node_modules: Playwright refuses to load two.
set -euo pipefail

SUITE=/tmp/suite
mkdir -p "${SUITE}"
cp -r /repo/e2e/browser/playwright.config.cjs /repo/e2e/browser/lib /repo/e2e/browser/tests "${SUITE}/"
cd "${SUITE}"
exec playwright test "$@"
