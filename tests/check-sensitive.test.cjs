'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const checker = path.resolve(__dirname, '../scripts/check-sensitive.cjs');
const hooks = path.resolve(__dirname, '../.githooks');

function run(cwd, command, args) {
  return spawnSync(command, args, { cwd, encoding: 'utf8' });
}

function withRepo(callback) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tab-out-privacy-'));
  try {
    assert.equal(run(dir, 'git', ['init', '-q']).status, 0);
    assert.equal(run(dir, 'git', ['config', 'user.name', 'Public Developer']).status, 0);
    assert.equal(run(dir, 'git', ['config', 'user.email', 'dev@users.noreply.github.com']).status, 0);
    const patternFile = path.join(dir, '.git', 'tab-out-sensitive-patterns');
    fs.writeFileSync(patternFile, 'privatecorp\\.example\n');
    callback(dir, patternFile);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('blocks staged company data, not just working-tree edits', () => withRepo((dir) => {
  fs.writeFileSync(path.join(dir, 'data.txt'), 'safe text\n');
  assert.equal(run(dir, 'git', ['add', 'data.txt']).status, 0);
  fs.writeFileSync(path.join(dir, 'data.txt'), 'privatecorp.example\n');
  assert.equal(run(dir, 'node', [checker]).status, 0);
  assert.equal(run(dir, 'git', ['add', 'data.txt']).status, 0);
  const result = run(dir, 'node', [checker]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /data\.txt:1/);
  assert.doesNotMatch(result.stderr, /privatecorp\.example/);
}));

test('fails closed without private patterns or with private Git identity', () => withRepo((dir, patternFile) => {
  fs.rmSync(patternFile);
  assert.match(run(dir, 'node', [checker]).stderr, /Missing private company patterns/);
  fs.writeFileSync(patternFile, 'privatecorp\\.example\n');
  run(dir, 'git', ['config', 'user.email', 'employee@privatecorp.example']);
  const result = run(dir, 'node', [checker]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /identity/);
}));

test('blocks staged binary files requiring manual privacy review', () => withRepo((dir) => {
  fs.writeFileSync(path.join(dir, 'photo.png'), Buffer.from([0, 1, 2]));
  assert.equal(run(dir, 'git', ['add', 'photo.png']).status, 0);
  const result = run(dir, 'node', [checker]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /manual privacy review/);
}));

test('blocks a clean change when existing tracked text is sensitive', () => withRepo((dir) => {
  fs.writeFileSync(path.join(dir, 'legacy.txt'), 'privatecorp.example\n');
  assert.equal(run(dir, 'git', ['add', 'legacy.txt']).status, 0);
  assert.equal(run(dir, 'git', ['commit', '-qm', 'legacy fixture']).status, 0);
  fs.writeFileSync(path.join(dir, 'clean.txt'), 'safe text\n');
  assert.equal(run(dir, 'git', ['add', 'clean.txt']).status, 0);
  const result = run(dir, 'node', [checker]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /legacy\.txt:1/);
}));

test('installed hook rejects a real commit', () => withRepo((dir) => {
  fs.mkdirSync(path.join(dir, 'scripts'));
  fs.copyFileSync(checker, path.join(dir, 'scripts', 'check-sensitive.cjs'));
  fs.mkdirSync(path.join(dir, '.githooks'));
  fs.copyFileSync(path.join(hooks, 'pre-commit'), path.join(dir, '.githooks', 'pre-commit'));
  fs.chmodSync(path.join(dir, '.githooks', 'pre-commit'), 0o755);
  assert.equal(run(dir, 'git', ['config', 'core.hooksPath', '.githooks']).status, 0);
  fs.writeFileSync(path.join(dir, 'data.txt'), 'privatecorp.example\n');
  assert.equal(run(dir, 'git', ['add', 'data.txt']).status, 0);
  const result = run(dir, 'git', ['commit', '-m', 'check hook']);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Commit blocked/);
  assert.equal(run(dir, 'git', ['rev-list', '--all', '--count']).stdout.trim(), '0');
}));
