// Tier-1 browser suite (#46): real Chrome against the dApp served by the stack, every transaction real.
// One worker, in order: every test runs in its own evm_snapshot on the one shared chain.
const path = require('node:path');
const { defineConfig, devices } = require('@playwright/test');
const { WEB_URL } = require('./lib/env.cjs');

const OUT = process.env.BROWSER_OUT_DIR || path.join(__dirname, '../.out/browser');

module.exports = defineConfig({
  testDir: './tests',
  testMatch: '*.spec.cjs',
  globalSetup: './lib/global-setup.cjs',
  workers: 1,
  fullyParallel: false,
  retries: 0, // a flaky step is a finding, not something to retry away
  timeout: 90_000,
  expect: { timeout: 20_000 },
  outputDir: path.join(OUT, 'test-results'),
  reporter: [['list'], ['html', { outputFolder: path.join(OUT, 'report'), open: 'never' }]],
  use: {
    ...devices['Desktop Chrome'],
    channel: 'chromium', // the full browser in new headless mode, not the headless shell
    baseURL: WEB_URL,
    locale: 'en-US',
    timezoneId: 'UTC',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
});
