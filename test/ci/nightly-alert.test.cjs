// Run with: node --test test/ci/
// The nightly-failure alert (.github/workflows/e2e-nightly-alert.yml, #49) can only fire for real when a
// nightly run fails, so its script is run here against a stub `gh` that records every call and answers
// `issue list` from a fixture, applying the workflow's own --jq filter with jq.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const WORKFLOW = path.join(__dirname, '../../.github/workflows/e2e-nightly-alert.yml');

// The `run: |` block of the only step, dedented.
function script() {
  const lines = fs.readFileSync(WORKFLOW, 'utf8').split('\n');
  const start = lines.findIndex((l) => /^\s+run: \|\s*$/.test(l));
  assert.ok(start > 0, 'the workflow has a run: | block');
  const body = [];
  for (const l of lines.slice(start + 1)) {
    if (l.trim() && !l.startsWith('          ')) break;
    body.push(l.slice(10));
  }
  return body.join('\n');
}

const STUB = `#!/usr/bin/env bash
printf '%s\\0' "$*" >> "$GH_CALLS"
if [[ "$1 $2" == "issue list" ]]; then
  while [[ $# -gt 0 ]]; do [[ "$1" == --jq ]] && { jq -r "$2" <<< "$OPEN_ISSUES"; exit; }; shift; done
fi
`;

function run({ conclusion, open = [], workflow = 'E2E with real MetaMask' }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nightly-alert-'));
  fs.writeFileSync(path.join(dir, 'gh'), STUB, { mode: 0o755 });
  const calls = path.join(dir, 'calls');
  fs.writeFileSync(calls, '');
  execFileSync('bash', ['-c', script()], {
    env: {
      PATH: `${dir}:${process.env.PATH}`, GH_CALLS: calls, OPEN_ISSUES: JSON.stringify(open),
      WORKFLOW: workflow, CONCLUSION: conclusion, RUN_URL: 'https://example.test/run/1', SHA: 'abc123',
    },
  });
  return fs.readFileSync(calls, 'utf8').split('\0').slice(1, -1); // NUL-separated; after the issue list
}

const mine = { number: 7, title: 'Nightly failing: E2E with real MetaMask' };
const other = { number: 8, title: 'Nightly failing: E2E on a Base-mainnet fork' };

test('a failure with no open issue opens one, titled after the workflow, with the run link', () => {
  const calls = run({ conclusion: 'failure', open: [other] });
  assert.match(calls.at(-1), /^issue create --label e2e-nightly --title Nightly failing: E2E with real MetaMask --body .*ended \*\*failure\*\*: https:\/\/example\.test\/run\/1/s);
  assert.equal(calls.filter((c) => c.startsWith('issue create')).length, 1);
});

test('a failure while its issue is open comments on that issue instead of opening another', () => {
  assert.deepEqual(run({ conclusion: 'timed_out', open: [other, mine] }),
    ['issue comment 7 --body Still timed_out: https://example.test/run/1 (`abc123`).']);
});

test('a green run closes its open issue, and only its own', () => {
  assert.deepEqual(run({ conclusion: 'success', open: [mine, other] }),
    ['issue close 7 --comment Green again: https://example.test/run/1 (`abc123`).']);
});

test('a green run with no open issue does nothing', () => {
  assert.deepEqual(run({ conclusion: 'success', open: [other] }), []);
});
