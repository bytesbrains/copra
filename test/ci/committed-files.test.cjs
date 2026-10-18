// Run with: node --test test/ci/
// scripts/check-committed-files.sh, the pre-push hook's guard against files that should never reach
// history (#79 committed wrangler dev's .wrangler/state SQLite files). Each case builds a throwaway
// repo, commits on top of a pushed-looking base, and runs the script on base..HEAD.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');

const ROOT = path.join(__dirname, '../..');
const SCRIPT = path.join(ROOT, 'scripts/check-committed-files.sh');
const HOOK = path.join(ROOT, '.githooks/pre-push');

function repo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'committed-files-'));
  const git = (...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', ...args], { cwd: dir, encoding: 'utf8' });
  const write = (p, data) => { fs.mkdirSync(path.dirname(path.join(dir, p)), { recursive: true }); fs.writeFileSync(path.join(dir, p), data); };
  git('init', '-q', '-b', 'main');
  write('.gitignore', 'e2e/.out/\n.env\n');
  write('README.md', 'base\n');
  git('add', '.');
  git('commit', '-q', '-m', 'base');
  const commit = (files, msg = 'change') => {
    for (const [p, data] of Object.entries(files)) data === null ? git('rm', '-q', p) : (write(p, data), git('add', '-f', p));
    git('commit', '-q', '-m', msg);
  };
  const check = (...range) => spawnSync('bash', [SCRIPT, ...(range.length ? range : ['main..HEAD'])], { cwd: dir, encoding: 'utf8' });
  git('checkout', '-q', '-b', 'work');
  return { dir, git, write, commit, check };
}

const binary = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0, 1, 2, 3]);

test('clean source changes and images under web/ and assets/ pass', () => {
  const r = repo();
  r.commit({ 'src/A.sol': 'contract A {}\n', 'web/assets/logo.png': binary, 'assets/icon.ico': binary });
  const res = r.check();
  assert.equal(res.status, 0, res.stdout + res.stderr);
  assert.match(res.stdout, /1 commit\(s\) checked/);
});

test('wrangler dev state is refused: the .wrangler store and SQLite journals (the #79 accident)', () => {
  const r = repo();
  r.commit({
    '.wrangler/state/v3/d1/miniflare-D1DatabaseObject/metadata.sqlite': binary,
    'tmp-cache/data.sqlite-wal': binary,
  });
  const res = r.check();
  assert.equal(res.status, 1);
  assert.match(res.stdout, /\.wrangler\/state\/v3\/d1\/miniflare-D1DatabaseObject\/metadata\.sqlite: local tool state/);
  assert.match(res.stdout, /tmp-cache\/data\.sqlite-wal: local tool state/);
});

test('a force-added file that .gitignore excludes is refused', () => {
  const r = repo();
  r.commit({ 'e2e/.out/deployment.json': '{}\n' });
  const res = r.check();
  assert.equal(res.status, 1);
  assert.match(res.stdout, /e2e\/\.out\/deployment\.json: matches \.gitignore/);
});

test('a binary outside assets/ and web/ images is refused, and so is a non-image binary under web/', () => {
  const r = repo();
  r.commit({ 'scripts/tool.bin': binary, 'web/archive.zip': binary });
  const res = r.check();
  assert.equal(res.status, 1);
  assert.match(res.stdout, /scripts\/tool\.bin: binary file/);
  assert.match(res.stdout, /web\/archive\.zip: binary file/);
});

test('a file over 2 MiB is refused, even an image', () => {
  const r = repo();
  r.commit({ 'web/huge.png': Buffer.concat([binary, Buffer.alloc(2 * 1024 * 1024)]) });
  const res = r.check();
  assert.equal(res.status, 1);
  assert.match(res.stdout, /web\/huge\.png: \d+ bytes, over the 2097152-byte limit/);
});

test('a file added and deleted again within the range is still refused: it stays in history', () => {
  const r = repo();
  r.commit({ '.wrangler/state/x.sqlite': binary }, 'oops');
  r.commit({ '.wrangler/state/x.sqlite': null }, 'remove it');
  const res = r.check();
  assert.equal(res.status, 1);
  assert.match(res.stdout, /\.wrangler\/state\/x\.sqlite: local tool state/);
});

test('paths are read raw: a non-ASCII image passes, and state with non-ASCII or tab names is refused by name', () => {
  const ok = repo();
  ok.commit({ 'web/café.png': binary });
  const res = ok.check();
  assert.equal(res.status, 0, res.stdout + res.stderr);
  const bad = repo();
  bad.commit({ '.wrangler/état.sqlite': binary, '.wrangler/a\tb.sqlite': binary });
  const res2 = bad.check();
  assert.equal(res2.status, 1, res2.stdout + res2.stderr);
  assert.match(res2.stdout, /\.wrangler\/état\.sqlite: local tool state/);
  assert.match(res2.stdout, /\.wrangler\/a\tb\.sqlite: local tool state/);
});

test('changing an already-tracked oversized file is refused too: the new version is a new blob in history', () => {
  const r = repo();
  r.git('checkout', '-q', 'main');
  r.commit({ 'web/huge.png': Buffer.concat([binary, Buffer.alloc(3 * 1024 * 1024)]) }, 'already there');
  r.git('checkout', '-q', '-b', 'touch');
  r.commit({ 'web/huge.png': Buffer.concat([binary, Buffer.alloc(3 * 1024 * 1024, 1)]) });
  const res = r.check();
  assert.equal(res.status, 1);
  assert.match(res.stdout, /add or change files/);
});

// Runs the hook with a bare "origin" holding main (so --remotes=origin marks what is already pushed)
// and a stub forge first on PATH that records whether the test step ran.
function pushThroughHook(branches) {
  const r = repo();
  const origin = fs.mkdtempSync(path.join(os.tmpdir(), 'committed-files-origin-'));
  execFileSync('git', ['init', '-q', '--bare', origin]);
  r.git('remote', 'add', 'origin', origin);
  r.git('push', '-q', 'origin', 'main');
  fs.mkdirSync(path.join(r.dir, 'scripts'), { recursive: true });
  fs.copyFileSync(SCRIPT, path.join(r.dir, 'scripts/check-committed-files.sh'));
  const lines = branches.map(([name, files]) => {
    r.git('checkout', '-q', 'main');
    r.git('checkout', '-q', '-b', name);
    r.commit(files);
    return `refs/heads/${name} ${r.git('rev-parse', 'HEAD').trim()} refs/heads/${name} ${'0'.repeat(40)}`;
  });
  const bin = fs.mkdtempSync(path.join(os.tmpdir(), 'committed-files-bin-'));
  const forgeLog = path.join(bin, 'forge.log');
  fs.writeFileSync(path.join(bin, 'forge'), `#!/usr/bin/env bash\necho "$*" >> "${forgeLog}"\n`, { mode: 0o755 });
  const res = spawnSync('bash', [HOOK, 'origin', origin], {
    cwd: r.dir, encoding: 'utf8', input: lines.join('\n') + '\n', env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
  });
  return { res, forgeRan: fs.existsSync(forgeLog) };
}

test('the pre-push hook blocks a bad push before the tests run, and passes a clean one through to them', () => {
  const bad = pushThroughHook([['topic', { '.wrangler/state/x.sqlite': binary }]]);
  assert.equal(bad.res.status, 1, bad.res.stdout + bad.res.stderr);
  assert.match(bad.res.stdout, /Push aborted/);
  assert.equal(bad.forgeRan, false, 'forge test never ran');
  const clean = pushThroughHook([['topic', { 'src/A.sol': 'contract A {}\n' }]]);
  assert.equal(clean.res.status, 0, clean.res.stdout + clean.res.stderr);
  assert.equal(clean.forgeRan, true, 'forge test ran after the check');
});

test('the hook checks every ref pushed: a bad branch after a clean one is still caught', () => {
  const { res } = pushThroughHook([['good', { 'src/A.sol': 'contract A {}\n' }], ['bad', { '.wrangler/x.sqlite': binary }]]);
  assert.equal(res.status, 1, res.stdout + res.stderr);
  assert.match(res.stdout, /1 commit\(s\) checked/);
  assert.match(res.stdout, /\.wrangler\/x\.sqlite: local tool state/);
});
