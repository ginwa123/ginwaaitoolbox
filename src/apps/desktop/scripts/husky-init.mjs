#!/usr/bin/env node
// Husky 9.x requires `.git` to exist at CWD when its prepare/install
// script runs. Our package.json lives at src/apps/desktop/ — a level
// below the git worktree root — so `npm install` (which CWDs into
// src/apps/desktop/ before running prepare) trips
// `husky: .git can't be found`.
//
// This wrapper:
//   1. Resolves the git worktree root via `git rev-parse --show-toplevel`
//      (cross-platform; works for both regular repos and worktrees).
//   2. chdir()s there so husky's `f.existsSync('.git')` check passes.
//   3. Invokes husky's bin.js which sets `core.hooksPath .husky/_` and
//      writes the internal `_/h` bootstrap + stub hook files.
//
// Once this runs, husky looks for the user's hook at `.husky/pre-commit`
// (one level up from the internal `_/pre-commit` stub). The hook itself
// is checked into git, so it's there from clone time — only the git
// `core.hooksPath` config (local, per-clone) needs this init step.
//
// Idempotent: re-running `npm install` re-sets core.hooksPath and
// re-creates the internal files, both of which are safe to repeat.

import { execFileSync, execSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(here, '..'); // src/apps/desktop/

// `git rev-parse --show-toplevel` resolves to the worktree root even when
// the caller is inside a linked worktree, and to the bare repo root from
// any subdirectory. Both cases are correct for husky's purposes.
const gitRoot = execSync('git rev-parse --show-toplevel', {
  cwd: projectRoot,
  encoding: 'utf-8',
}).trim();

process.chdir(gitRoot);

// Resolve husky's bin.js. husky's package.json declares
// `"bin": { "husky": "bin.js" }` but does NOT expose `bin.js` through
// the `exports` field — `import('husky/bin.js')` and
// `require.resolve('husky/bin.js')` both fail with
// ERR_PACKAGE_PATH_NOT_EXPORTED. Read the bin path from
// node_modules/husky/package.json directly, then exec the file with the
// current node binary so it runs in-process with our chdir.
const huskyPkgPath = resolve(projectRoot, 'node_modules/husky/package.json');
const huskyPkg = JSON.parse(readFileSync(huskyPkgPath, 'utf-8'));
const huskyBinRel = huskyPkg.bin?.husky ?? 'bin.js';
const huskyBinAbs = resolve(projectRoot, 'node_modules/husky', huskyBinRel);

if (!existsSync(huskyBinAbs)) {
  console.error(`husky-init: expected bin at ${huskyBinAbs} — is husky installed?`);
  process.exit(1);
}

execFileSync(process.execPath, [huskyBinAbs], { stdio: 'inherit' });
