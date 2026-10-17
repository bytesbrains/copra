// Run with: node --test test/web/
// Keeps web/.well-known/security.txt (RFC 9116) valid. An expired file tells researchers the contact is
// dead, so this fails 30 days before Expires: bump it (to at most a year ahead) when it does.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '../..');
const txt = fs.readFileSync(path.join(ROOT, 'web/.well-known/security.txt'), 'utf8');
const securityMd = fs.readFileSync(path.join(ROOT, 'SECURITY.md'), 'utf8');

const fields = (name) =>
  txt.split('\n').filter((l) => l.startsWith(`${name}:`)).map((l) => l.slice(name.length + 1).trim());

test('security.txt has the required Contact and Expires fields', () => {
  assert.ok(fields('Contact').length > 0, 'no Contact');
  assert.equal(fields('Expires').length, 1, 'exactly one Expires');
});

test('security.txt Expires is at least 30 days and at most a year ahead', () => {
  const expires = Date.parse(fields('Expires')[0]);
  assert.ok(!Number.isNaN(expires), 'Expires is not an RFC 3339 date');
  const day = 24 * 60 * 60 * 1000;
  assert.ok(expires - Date.now() > 30 * day, `security.txt expires ${fields('Expires')[0]}: renew it`);
  assert.ok(expires - Date.now() <= 366 * day, 'RFC 9116: Expires should be less than a year ahead');
});

test('security.txt and SECURITY.md name the same contacts', () => {
  for (const contact of fields('Contact')) {
    const target = contact.replace(/^mailto:/, '');
    assert.ok(securityMd.includes(target), `SECURITY.md does not mention ${target}`);
  }
});

test('every security.txt URL is https', () => {
  for (const name of ['Contact', 'Policy', 'Canonical']) {
    for (const v of fields(name).filter((f) => !f.startsWith('mailto:'))) {
      assert.match(v, /^https:\/\//, `${name}: ${v}`);
    }
  }
});
