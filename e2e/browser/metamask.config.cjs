// Tier 2 (#50): real MetaMask in real Chrome. One worker, in order: each test launches its own browser
// with the extension, so the Desktop Chrome defaults of the tier-1 config do not apply here.
const path = require('node:path');
const { defineConfig } = require('@playwright/test');

const OUT = process.env.BROWSER_OUT_DIR || path.join(__dirname, '../.out/browser');

module.exports = defineConfig({
  testDir: './metamask',
  testMatch: '*.spec.cjs',
  globalSetup: './lib/global-setup.cjs',
  workers: 1,
  fullyParallel: false,
  retries: 0, // the trial measures flakiness: a retry would hide it
  timeout: 240_000,
  expect: { timeout: 30_000 },
  outputDir: path.join(OUT, 'metamask-results'),
  preserveOutput: 'failures-only', // the video of a failing run; nothing for a green one
  reporter: [['list'], ['html', { outputFolder: path.join(OUT, 'metamask-report'), open: 'never' }]],
});
