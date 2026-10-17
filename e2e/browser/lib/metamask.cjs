// Real MetaMask for tier 2 (#50): the pinned extension (e2e/browser/Dockerfile) loaded into Playwright's
// full Chromium in new headless mode, onboarded from anvil's public test mnemonic. Nothing about the
// wallet is mocked: every approval is clicked in MetaMask's own UI.
//
// What the trial found about MetaMask 13.49 under automation, and how this file handles it:
//   - Approvals open in MetaMask's side panel, not a popup window. Playwright does not list the side
//     panel among a context's pages, so the suite also attaches over CDP, where it is an ordinary page.
//   - LavaMoat blocks evaluation in an extension page's main world: only locators are used there.
//   - An extension can open its side panel only on a user gesture, so MetaMask cannot open it for a
//     dApp's request: the request then has nowhere to appear. "Open wallet" at the end of onboarding is
//     that gesture, as for a user, and the panel stays open for every approval after it.
//   - "Basic functionality" (MetaMask's external services: prices, token lists, news) is switched off.
//     With it on, the background is busy with mainnet traffic and calls take up to 30s; off, milliseconds.
//     It cannot be made fully offline: with every external host unresolvable, a connect request is
//     never shown.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require('@playwright/test');

const EXTENSION_DIR = process.env.METAMASK_DIR || '/opt/metamask';
const CDP_PORT = Number(process.env.METAMASK_CDP_PORT || 9333);
// anvil's public test mnemonic: account 0 is 0xf39F…2266. A test wallet, never a real one.
const MNEMONIC = 'test test test test test test test test test test test junk';
const PASSWORD = 'copra-e2e-metamask';

const version = () => JSON.parse(fs.readFileSync(path.join(EXTENSION_DIR, 'manifest.json'), 'utf8')).version;

/** Chromium with MetaMask loaded, in a fresh profile. Returns the context, the extension id and a CDP view. */
async function launch({ videoDir } = {}) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'metamask-profile-'));
  const context = await chromium.launchPersistentContext(profile, {
    channel: 'chromium', // the full browser in new headless mode: extensions load without a display
    headless: true,
    viewport: { width: 1280, height: 900 },
    locale: 'en-US',
    timezoneId: 'UTC',
    recordVideo: videoDir ? { dir: videoDir } : undefined,
    args: [
      `--disable-extensions-except=${EXTENSION_DIR}`,
      `--load-extension=${EXTENSION_DIR}`,
      `--remote-debugging-address=127.0.0.1`,
      `--remote-debugging-port=${CDP_PORT}`,
    ],
  });
  const worker = context.serviceWorkers().find((w) => w.url().startsWith('chrome-extension://'))
    || await context.waitForEvent('serviceworker', { predicate: (w) => w.url().startsWith('chrome-extension://'), timeout: 30_000 });
  const extensionId = new URL(worker.url()).host;
  // A step that cannot happen fails on that step's own locator, not at the end of the test.
  context.setDefaultTimeout(30_000);
  return { context, extensionId, cdp: new CdpView(), profile };
}

/**
 * The browser's pages as CDP sees them, side panel included. A CDP connection does not pick up a side
 * panel the extension opens after it attached, so a lookup that misses reconnects and looks again.
 */
class CdpView {
  async pages({ refresh = false } = {}) {
    if (refresh && this.browser) { await this.browser.close().catch(() => {}); this.browser = null; }
    this.browser ??= await chromium.connectOverCDP(`http://127.0.0.1:${CDP_PORT}`);
    return this.browser.contexts().flatMap((c) => c.pages());
  }
  async find(predicate) {
    return (await this.pages()).find(predicate) ?? (await this.pages({ refresh: true })).find(predicate) ?? null;
  }
  async close() { await this.browser?.close().catch(() => {}); }
}

/**
 * Imports the wallet from the mnemonic, sets a password, declines metrics and external services, and
 * opens the side panel with "Open wallet". Returns the side panel, unlocked on the wallet's home.
 */
async function onboard(context, extensionId, cdp) {
  let page;
  for (let i = 0; i < 120 && !page; i++) {
    page = context.pages().find((p) => p.url().startsWith(`chrome-extension://${extensionId}/`));
    if (!page) await new Promise((r) => setTimeout(r, 250));
  }
  if (!page) {
    page = await context.newPage();
    await page.goto(`chrome-extension://${extensionId}/home.html`);
  }
  const id = (t) => page.getByTestId(t);
  try {
    await importWallet(page, id);
  } catch (e) {
    e.message = `MetaMask onboarding stopped at ${page.url()}: ${e.message}`;
    throw e;
  }
  let panel;
  for (let i = 0; i < 60 && !panel; i++) {
    panel = await sidePanel(cdp);
    if (!panel) await new Promise((r) => setTimeout(r, 500));
  }
  if (!panel) throw new Error('"Open wallet" did not open MetaMask\'s side panel');
  await unlockIfLocked(panel);
  return panel;
}

/**
 * Waits for the wallet's home, typing the password if MetaMask shows its lock screen first: right after
 * onboarding its background can restart and lock the vault, as it does for a user.
 */
async function unlockIfLocked(page) {
  const home = page.getByTestId('account-menu-icon');
  const password = page.getByTestId('unlock-password');
  await home.or(password).first().waitFor();
  if (await password.isVisible()) {
    await password.fill(PASSWORD);
    await page.getByTestId('unlock-submit').click();
  }
  await home.waitFor();
}

async function importWallet(page, id) {
  await id('onboarding-import-wallet').click();
  await id('onboarding-import-with-srp-button').click();
  await id('srp-input-import__srp-note').pressSequentially(MNEMONIC, { delay: 5 });
  await id('import-srp-confirm').click();
  await id('create-password-new-input').fill(PASSWORD);
  await id('create-password-confirm-input').fill(PASSWORD);
  await id('create-password-terms').click();
  await id('create-password-submit').click();
  await id('passkey-maybe-later-button').click();
  // No usage data from test runs.
  const metrics = id('metametrics-checkbox');
  if (await metrics.locator('input[type=checkbox]').isChecked()) await metrics.click();
  await id('metametrics-i-agree').click();
  // Basic functionality off (see the top of this file).
  await id('manage-default-settings').click();
  await id('category-item-General').click();
  await id('basic-functionality-toggle').locator('label, input, .toggle-button').first().click();
  await id('basic-configuration-checkbox').click();
  await id('basic-configuration-modal-toggle-button').click();
  await id('category-back-button').click();
  await id('privacy-settings-back-button').click();
  await id('onboarding-complete-done').click(); // "Open wallet": opens the side panel
}

/** MetaMask's side panel, through CDP: null until the extension opens it. */
const sidePanel = (cdp) => cdp.find((p) => p.url().includes('/sidepanel.html'));
const route = (page) => (page ? new URL(page.url()).hash.replace(/^#/, '') : '');
// Where MetaMask shows an approval: its side panel where the browser has one, else its popup window.
const SURFACES = /\/(sidepanel|notification|popup)\.html/;
const isApproval = (p) => SURFACES.test(p.url()) && /^\/(connect|confirm)/.test(route(p));

/**
 * Waits for the side panel to show an approval (a connect or confirmation route) other than `seen`,
 * and returns it with its route. The panel is one page whose route changes per request.
 */
async function nextApproval(cdp, { seen = [], timeout = 60_000 } = {}) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const panel = await cdp.find((p) => isApproval(p) && !seen.includes(route(p)));
    if (panel) {
      await panel.getByRole('button').last().waitFor();
      return { panel, route: route(panel), surface: panel.url().match(SURFACES)[1] };
    }
    await new Promise((res) => setTimeout(res, 500));
  }
  const open = (await cdp.pages({ refresh: true })).map((p) => p.url()).join(', ');
  throw new Error(`no MetaMask approval within ${timeout}ms; pages open: ${open}`);
}

/** The approval's primary button: Connect on a connect request, Confirm on a confirmation. */
const approveButton = (panel) => panel.getByTestId(/^(confirm-btn|confirm-footer-button)$/);
const rejectButton = (panel) => panel.getByTestId(/^(cancel-btn|confirm-footer-cancel-button)$/);

module.exports = { EXTENSION_DIR, version, launch, onboard, sidePanel, nextApproval, approveButton, rejectButton };
