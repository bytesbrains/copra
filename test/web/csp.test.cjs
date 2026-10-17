// Run with: node --test test/web/
// Keeps web/_headers' CSP and web/index.html in step: a new inline script, inline handler or
// third-party host must be a deliberate policy change, not a silent violation found in production.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const WEB = path.join(__dirname, '../../web');
const html = fs.readFileSync(path.join(WEB, 'index.html'), 'utf8');
const headers = fs.readFileSync(path.join(WEB, '_headers'), 'utf8');

function cspDirectives() {
  const line = headers.split('\n').find((l) => /^\s*Content-Security-Policy:/.test(l));
  assert.ok(line, 'web/_headers sets an enforced Content-Security-Policy');
  const policy = line.slice(line.indexOf(':') + 1);
  const map = {};
  for (const d of policy.split(';').map((s) => s.trim()).filter(Boolean)) {
    const [name, ...sources] = d.split(/\s+/);
    map[name] = sources;
  }
  return map;
}

const csp = cspDirectives();

// Enforced since #32. Going back to report-only would silently drop the protection: a violation
// would only log, and only in the console of whoever happened to be looking.
test('the CSP is enforced, not report-only', () => {
  assert.doesNotMatch(headers, /Content-Security-Policy-Report-Only/);
});

const allows = (directive, url) => {
  const sources = csp[directive] || csp['default-src'];
  if (!/^https?:/.test(url)) return sources.includes("'self'");
  return sources.includes(new URL(url).origin);
};

test('index.html has no inline <script> blocks, so script-src needs no unsafe-inline', () => {
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
  assert.ok(scripts.length > 0);
  for (const [tag, attrs, body] of scripts) {
    assert.match(attrs, /\bsrc=/, `inline script: ${tag.slice(0, 80)}`);
    assert.equal(body.trim(), '', `script with src also has a body: ${tag.slice(0, 80)}`);
  }
  assert.ok(!csp['script-src'].includes("'unsafe-inline'"));
});

test('index.html has no inline event handlers or javascript: URLs', () => {
  assert.doesNotMatch(html, /<[^>]+\son[a-z]+\s*=/i);
  assert.doesNotMatch(html, /javascript:/i);
});

test('every script and stylesheet index.html loads is allowed by the CSP', () => {
  for (const [, src] of html.matchAll(/<script\b[^>]*\bsrc="([^"]+)"/gi)) {
    assert.ok(allows('script-src', src), `script-src blocks ${src}`);
  }
  for (const [tag] of html.matchAll(/<link\b[^>]*>/gi)) {
    if (!/rel="stylesheet"/.test(tag)) continue;
    const href = tag.match(/href="([^"]+)"/)[1];
    assert.ok(allows('style-src', href), `style-src blocks ${href}`);
  }
});

test('the app scripts write no HTML strings into the DOM', () => {
  for (const f of fs.readdirSync(path.join(WEB, 'assets')).filter((n) => n.endsWith('.js'))) {
    const src = fs.readFileSync(path.join(WEB, 'assets', f), 'utf8');
    assert.doesNotMatch(src, /\.(innerHTML|outerHTML)\s*=|insertAdjacentHTML|document\.write/, f);
  }
});

test('connect-src covers the RPC endpoint network.js sets', () => {
  const network = fs.readFileSync(path.join(WEB, 'assets/network.js'), 'utf8');
  const rpc = network.match(/"rpcUrl":\s*"([^"]+)"/)[1];
  assert.ok(allows('connect-src', rpc), `connect-src blocks ${rpc}`);
});

// Cloudflare Web Analytics is switched on in the dashboard, not in this repo: the edge injects the
// beacon into every page, so index.html never shows it. Found by the #32 browser check.
test('the CSP allows the Cloudflare Web Analytics beacon the edge injects', () => {
  assert.ok(allows('script-src', 'https://static.cloudflareinsights.com/beacon.min.js'), 'script-src blocks the beacon');
  assert.ok(allows('connect-src', '/cdn-cgi/rum'), 'connect-src blocks the beacon\'s same-origin report');
});
