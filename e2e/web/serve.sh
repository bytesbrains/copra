#!/usr/bin/env bash
# Builds web/ for the `local` environment (#43) and serves it with wrangler dev, from the repo's own
# wrangler.jsonc with only the assets directory pointed at the build. Runs in the web container.
set -euo pipefail

SITE=/tmp/copra
# The browser runs on the host, so the page's RPC is anvil's host port, not the compose service name.
node /repo/scripts/web-env.cjs local "${SITE}/web" --rpc-url "http://127.0.0.1:${E2E_RPC_PORT:-8545}"
# The pinned wrangler (kept at least two weeks old) can trail the repo's compatibility_date, which
# production moves forward. An assets-only Worker serves files and _headers the same under either
# date, so cap it at the newest date this runtime supports, and say so, rather than refuse to start.
# shellcheck disable=SC2016 # JavaScript, not shell: the template literal is for node
node -e '
  const fs = require("node:fs");
  const { compatibilityDate } = require("/app/node_modules/workerd");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(compatibilityDate)) throw new Error(`workerd exports no compatibilityDate: ${compatibilityDate}`);
  const config = JSON.parse(fs.readFileSync("/repo/wrangler.jsonc", "utf8"));
  delete config.$schema;
  config.assets.directory = "./web";
  if (config.compatibility_date > compatibilityDate) {
    console.log(`compatibility_date ${config.compatibility_date} capped at ${compatibilityDate}, the newest this workerd supports`);
    config.compatibility_date = compatibilityDate;
  }
  fs.writeFileSync(process.argv[1], JSON.stringify(config, null, 2));
' "${SITE}/wrangler.jsonc"

cd "${SITE}"
exec wrangler dev --config "${SITE}/wrangler.jsonc" --ip 0.0.0.0 --port 8787 --show-interactive-dev-session=false
