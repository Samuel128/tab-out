#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const { execFileSync } = require('node:child_process');

function git(...args) {
  return execFileSync('git', args, { maxBuffer: 64 * 1024 * 1024 });
}

function check() {
  const patternPath = git('rev-parse', '--git-path', 'tab-out-sensitive-patterns').toString().trim();
  if (!fs.existsSync(patternPath)) {
    throw new Error('Missing private company patterns. Create .git/tab-out-sensitive-patterns (one regex per line) before committing.');
  }

  const entries = fs.readFileSync(patternPath, 'utf8').split(/\r?\n/)
    .map(line => line.trim()).filter(line => line && !line.startsWith('#'));
  if (!entries.length) throw new Error('Private company patterns must not be empty.');
  const patterns = entries.map(entry => new RegExp(entry, 'i'));
  patterns.push(/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/i);

  const violations = [];
  for (const role of ['AUTHOR', 'COMMITTER']) {
    const identity = git('var', `GIT_${role}_IDENT`).toString();
    if (patterns.some(pattern => pattern.test(identity))) violations.push(`${role.toLowerCase()} identity`);
  }

  const changedPaths = new Set(git('diff', '--cached', '--name-only', '--diff-filter=ACMRT', '-z')
    .toString().split('\0').filter(Boolean));
  const paths = git('ls-files', '--cached', '-z')
    .toString().split('\0').filter(Boolean);
  for (const path of paths) {
    const content = git('show', `:${path}`);
    let lines;
    try {
      if (content.includes(0)) throw new Error('binary');
      lines = new TextDecoder('utf-8', { fatal: true }).decode(content).split(/\r?\n/);
    } catch {
      if (changedPaths.has(path)) violations.push(`${path} (binary file; manual privacy review required)`);
      continue;
    }
    lines.forEach((line, index) => {
      if (patterns.some(pattern => pattern.test(line))) violations.push(`${path}:${index + 1}`);
    });
  }

  if (violations.length) {
    process.stderr.write(`Commit blocked: possible company or private information in:\n${violations.join('\n')}\n`);
    process.stderr.write('Review the staged content and Git identity. Do not bypass this check to publish sensitive data.\n');
    return false;
  }
  process.stdout.write('Privacy check passed for the staged snapshot and Git identity.\n');
  return true;
}

try {
  if (!check()) process.exitCode = 1;
} catch (error) {
  process.stderr.write(`Privacy check could not run: ${error.message}\n`);
  process.exitCode = 1;
}
