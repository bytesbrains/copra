// Run with: node --test test/web/
// Only the site's own domains are indexed (#78): branch previews and the Worker's workers.dev address
// are copies of the site, and web/_headers marks them noindex by host. This pins the file's rules; that
// the server applies them by Host is checked against wrangler dev by e2e/web/check-web.cjs.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const headers = fs.readFileSync(path.join(__dirname, '../../web/_headers'), 'utf8');
// Rule blocks: a URL pattern line followed by indented header lines (comments dropped).
const blocks = headers.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n').split(/\n(?=\S)/)
  .map((b) => b.trim().split('\n')).filter((b) => b[0]).map(([url, ...lines]) => ({ url, lines: lines.map((l) => l.trim()) }));

test('every workers.dev host, previews and the Worker\'s own address, is served noindex', () => {
  // Cloudflare's documented pattern: placeholders match one host label each, so this covers
  // <branch>-copra.<subdomain>.workers.dev, <version>-copra.<subdomain>.workers.dev and copra.<subdomain>.workers.dev.
  const rule = blocks.find((b) => b.url === 'https://:version.:subdomain.workers.dev/*');
  assert.ok(rule, 'web/_headers has a rule for https://:version.:subdomain.workers.dev/*');
  assert.deepEqual(rule.lines, ['X-Robots-Tag: noindex']);
});

test('the site itself stays indexable: no noindex for every host, and robots.txt allows crawling', () => {
  for (const b of blocks.filter((b) => b.url.startsWith('/'))) {
    assert.ok(!b.lines.some((l) => /^X-Robots-Tag:/i.test(l)), `${b.url} sets no X-Robots-Tag on copra.dev`);
  }
  assert.match(fs.readFileSync(path.join(__dirname, '../../web/robots.txt'), 'utf8'), /^Allow: \/$/m);
});
