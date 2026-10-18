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

test('the pre-push hook blocks the push before the tests run, and passes a clean one', () => {
  for (const [files, want] of [[{ '.wrangler/state/x.sqlite': binary }, 1], [{ 'src/A.sol': 'contract A {}\n' }, 0]]) {
    const r = repo();
    // A bare "origin" holding main, so --remotes=origin marks what is already pushed.
    const origin = fs.mkdtempSync(path.join(os.tmpdir(), 'committed-files-origin-'));
    execFileSync('git', ['init', '-q', '--bare', origin]);
    r.git('remote', 'add', 'origin', origin);
    r.git('push', '-q', 'origin', 'main');
    r.commit(files);
    fs.mkdirSync(path.join(r.dir, 'scripts'), { recursive: true });
    fs.copyFileSync(SCRIPT, path.join(r.dir, 'scripts/check-committed-files.sh'));
    const head = r.git('rev-parse', 'HEAD').trim();
    // forge off PATH, so only the files check decides.
    const res = spawnSync('bash', [HOOK, 'origin', origin], {
      cwd: r.dir, encoding: 'utf8', input: `refs/heads/work ${head} refs/heads/work ${'0'.repeat(40)}\n`,
      env: { ...process.env, PATH: '/usr/bin:/bin' },
    });
    assert.equal(res.status, want, res.stdout + res.stderr);
    if (want) assert.match(res.stdout, /Push aborted/);
  }
});
