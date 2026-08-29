#!/usr/bin/env node
// scripts/patch-arm64-bindings.mjs
//
// Workaround for the Windows-ARM64 + pnpm bug that breaks `pnpm run dev` on
// this repo's webapp. Background:
//
// pnpm installs optional native bindings based on host OS+arch. On a
// Windows-ARM64 host (process.platform === 'win32', process.arch ===
// 'arm64'), pnpm currently picks the *x64* binding packages instead of the
// arm64 ones. As a result, vite (which uses rolldown internally) and
// tailwindcss (which uses lightningcss + @tailwindcss/oxide) fail at
// runtime with `Cannot find module '@rolldown/binding-win32-arm64-msvc'`
// / `lightningcss.win32-arm64-msvc.node` /
// `tailwindcss-oxide.win32-arm64-msvc.node` — every native load tries the
// arm64 paths first because the parent package's binding-loader knows
// we're on arm64 (via `process.arch`).
//
// Fix: after every `pnpm install`, run this script. It:
//
//   1. Skips entirely (exit 0, no-op) on non-Windows-ARM64 hosts
//      (macOS, Linux, Windows-x64). The `postinstall` hook fires for
//      every dev box + every CI run, so the no-op keeps the cross-
//      platform build chain cheap.
//   2. For each missing arm64 binding, downloads the tarball via
//      `npm pack <pkg>@<ver>`, extracts via the system `tar` (Windows
//      ships bsdtar in C:\Windows\System32; macOS/Linux have GNU tar by
//      default), and drops the `.node` file(s) at the locations the
//      parent packages' binding-loaders look for.
//   3. Skips work that's already done — if the destination file exists
//      with the expected size, no re-extraction runs.
//
// This is intentionally idempotent and side-effect-free on success:
// re-running it on an already-patched tree is a no-op (the existence
// check at the top short-circuits each binding).
//
// Maintainer note: when bumping vite / tailwindcss / lightningcss, the
// binding package versions below must be bumped in lockstep. Look up
// the new arm64 binding version in the parent package's
// package.json#optionalDependencies. The script takes the binding
// version as a literal in `BINDINGS` below; there's no auto-detection
// because pnpm's lockfile doesn't currently encode "which arm64 binding
// did the parent want?".

import { execFileSync } from 'node:child_process';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const IS_WINDOWS_ARM64 =
  process.platform === 'win32' && process.arch === 'arm64';

if (!IS_WINDOWS_ARM64) {
  // No-op on every other host (macOS, Linux, Windows-x64). The dev
  // server + CI runners on those hosts don't need the arm64 binding
  // because pnpm's platform-detection picks the right one at install
  // time.
  process.exit(0);
}

// ---- binding map ------------------------------------------------------
//
// Each entry describes:
//   pkg              — `<name>@<version>` string to `npm pack`
//   mode             — `dir-as-package` (drop the whole extracted dir
//                     at a top-level node_modules location, like
//                     @rolldown/binding-…) or
//                     `nodefile-into-pkg` (extract a single .node file
//                     and drop it next to the parent package's `node/`
//                     subdir or inside its package dir, like
//                     lightningcss / @tailwindcss/oxide)
//   nodeFile         — (mode `nodefile-into-pkg` only) the name of the
//                     `.node` file inside the tarball AND the name to
//                     use at the destination
//   destination      — (mode `dir-as-package` only) the destination
//                     directory under the project root (relative to
//                     cwd, written as POSIX for cross-platform)
//   pnpmGlob         — (mode `nodefile-into-pkg` only) glob (POSIX path
//                     under cwd) of the parent package directories to
//                     drop the .node file into. The `.pnpm/` store
//                     names the parent with a hash suffix, e.g.
//                     `lightningcss@1.32.0`, so we glob to find the
//                     resolved directory at run time.
//
// The current versions match pnpm-lock.yaml for the repo as of 2026-08-28.
// See the maintainer note at the top of this file for how to bump them.
const BINDINGS = [
  {
    pkg: '@rolldown/binding-win32-arm64-msvc@1.0.0-rc.15',
    mode: 'dir-as-package',
    destination: 'node_modules/@rolldown/binding-win32-arm64-msvc',
  },
  {
    pkg: 'lightningcss-win32-arm64-msvc@1.32.0',
    mode: 'nodefile-into-pkg',
    nodeFile: 'lightningcss.win32-arm64-msvc.node',
    pnpmGlob: 'node_modules/.pnpm/lightningcss@*/node_modules/lightningcss',
  },
  {
    pkg: '@tailwindcss/oxide-win32-arm64-msvc@4.2.2',
    mode: 'nodefile-into-pkg',
    nodeFile: 'tailwindcss-oxide.win32-arm64-msvc.node',
    pnpmGlob: 'node_modules/.pnpm/@tailwindcss+oxide@*/node_modules/@tailwindcss/oxide',
  },
];

const projectRoot = process.cwd();
const cacheRoot = join(tmpdir(), 'arm64-bindings-patch');

// ---- helpers ----------------------------------------------------------

function npmCmd() {
  // npm on Windows is `npm.cmd` (a batch file) which cmd.exe must
  // invoke — Node's child_process can't directly spawn `.cmd` files
  // (returns EINVAL on Win32 CreateProcess). On macOS/Linux it's just
  // `npm` on PATH.
  return process.platform === 'win32' ? 'npm' : 'npm';
}

function tarCmd() {
  // macOS / Linux: GNU tar. Windows: bsdtar in C:\Windows\System32.
  // Both accept the same `-xzf <tarball> -C <dest>` invocation for
  // gzip-compressed tarballs.
  return process.platform === 'win32' ? 'tar.exe' : 'tar';
}

/**
 * Spawn `npm pack` cross-platform. On Windows, Node's execFile can't
 * directly run `.cmd` batch files (Win32 CreateProcess returns
 * EINVAL), so we wrap in `cmd.exe /c npm.cmd …`. On macOS/Linux we
 * just exec `npm` directly.
 */
function npmPack(pkg, cacheDir) {
  if (process.platform === 'win32') {
    execFileSync(
      'cmd.exe',
      ['/c', 'npm.cmd', 'pack', pkg, '--pack-destination', cacheDir],
      { stdio: 'inherit' },
    );
  } else {
    execFileSync('npm', ['pack', pkg, '--pack-destination', cacheDir], {
      stdio: 'inherit',
    });
  }
}

/** Glob a POSIX path with `*` wildcards under a root dir. */
function expandGlob(p) {
  // Convert POSIX `*` wildcards to a regex, then walk the tree.
  const root = projectRoot;
  const parts = p.split('/');
  // Find the first segment containing `*` — that's where we start
  // walking vs. descending.
  let i = 0;
  while (i < parts.length && !parts[i].includes('*')) i++;
  const fixed = parts.slice(0, i);
  const wild = parts.slice(i);
  let dirs = [join(root, ...fixed)];
  for (const seg of wild) {
    const next = [];
    for (const d of dirs) {
      let entries;
      try {
        entries = readdirSync(d, { withFileTypes: true });
      } catch {
        continue;
      }
      if (seg === '*') {
        for (const e of entries) {
          if (e.isDirectory()) next.push(join(d, e.name));
        }
      } else if (seg.includes('*')) {
        const re = new RegExp(
          '^' + seg.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$',
        );
        for (const e of entries) {
          if (e.isDirectory() && re.test(e.name)) next.push(join(d, e.name));
        }
      } else {
        // No wildcard in this segment (shouldn't happen after the first
        // match), but handle for completeness.
        const p2 = join(d, seg);
        if (existsSync(p2)) next.push(p2);
      }
    }
    dirs = next;
  }
  return dirs;
}

/** Returns the local tarball path, downloading via `npm pack` if needed. */
function ensureTarball(pkg) {
  // `npm pack @rolldown/binding-x@1.0.0-rc.15` produces
  // `rolldown-binding-x-1.0.0-rc.15.tgz` (full unscoped name +
  // version, with leading `@` and slashes replaced by `-`).
  const unscoped = pkg.replace(/^@/, '').split('@')[0];
  const version = pkg.split('@').pop();
  const tarballName = unscoped.replace(/\//g, '-') + '-' + version + '.tgz';
  const tarball = join(cacheRoot, tarballName);
  if (!existsSync(tarball)) {
    mkdirSync(cacheRoot, { recursive: true });
    npmPack(pkg, cacheRoot);
  }
  return tarball;
}

/** Recursively delete a directory, retrying with cmd.exe rmdir on EPERM. */
function rmRecursive(p) {
  if (!existsSync(p)) return;
  try {
    rmSync(p, { recursive: true, force: true });
  } catch (e) {
    if (process.platform === 'win32' && /EPERM|EACCES/.test(e.code || '')) {
      // Windows file locks (e.g., open file handles) can cause rmSync
      // to fail with EPERM. Fall back to cmd.exe's rmdir which handles
      // those cases better than Node's recursive rm.
      try {
        execFileSync('cmd.exe', ['/c', 'rmdir', '/s', '/q', p], {
          stdio: 'ignore',
        });
      } catch {
        throw e; // re-throw the original Node error if cmd.exe also fails
      }
    } else {
      throw e;
    }
  }
}

/** Extract a tarball into a fresh directory. Returns the directory. */
function extractTo(tarball, subdir) {
  const dest = join(cacheRoot, subdir);
  rmRecursive(dest);
  mkdirSync(dest, { recursive: true });
  execFileSync(tarCmd(), ['-xzf', tarball, '-C', dest], { stdio: 'inherit' });
  return dest;
}

// ---- per-binding logic ------------------------------------------------

function patchDirAsPackage(b) {
  const dest = join(projectRoot, b.destination);
  // Idempotency: if the dir already has a `package.json` AND the
  // expected `.node` file, assume the patch is already applied.
  if (existsSync(dest)) {
    const pkgJson = join(dest, 'package.json');
    if (existsSync(pkgJson)) {
      // Quick check: the rolldown binding package's `main` field
      // points at the .node file; see if that file is present.
      const main = JSON.parse(readFileSync(pkgJson, 'utf8')).main;
      if (main && existsSync(join(dest, main))) {
        console.log(`[arm64-patch] ${b.pkg}: already patched, skipping`);
        return;
      }
    }
  }
  const tarball = ensureTarball(b.pkg);
  const extracted = extractTo(
    tarball,
    'extract-' + b.pkg.replace(/[^a-z0-9-]/gi, '_'),
  );
  const pkgDir = join(extracted, 'package');
  rmRecursive(dest);
  mkdirSync(dest, { recursive: true });
  // Copy the extracted `package/` contents (the binding's package.json
  // + its .node + README + LICENSE) into the destination directory.
  for (const entry of readdirSync(pkgDir, { withFileTypes: true })) {
    const src = join(pkgDir, entry.name);
    const dst = join(dest, entry.name);
    if (entry.isDirectory()) {
      mkdirSync(dst, { recursive: true });
      for (const inner of readdirSync(src)) {
        copyFileSync(join(src, inner), join(dst, inner));
      }
    } else {
      copyFileSync(src, dst);
    }
  }
  console.log(`[arm64-patch] ${b.pkg}: installed → ${b.destination}`);
}

function patchNodefileIntoPkg(b) {
  // Resolve the parent package dirs from the glob. For each one, drop
  // the .node file into the directory (lightningcss wants a sibling of
  // its `node/` subdir; tailwindcss/oxide wants the file inside its
  // own package dir — both layouts end up "in the same directory as
  // the index.js that does `require('./foo.node')`", so a single
  // destination works for both).
  const parentDirs = expandGlob(b.pnpmGlob);
  if (parentDirs.length === 0) {
    console.warn(
      `[arm64-patch] ${b.pkg}: no parent dirs matched glob ${b.pnpmGlob} — ` +
        `was pnpm install run? (Skipping; re-run after pnpm install.)`,
    );
    return;
  }

  const tarball = ensureTarball(b.pkg);
  const extracted = extractTo(
    tarball,
    'extract-' + b.pkg.replace(/[^a-z0-9-]/gi, '_'),
  );
  const src = join(extracted, 'package', b.nodeFile);
  if (!existsSync(src)) {
    console.warn(
      `[arm64-patch] ${b.pkg}: tarball did not contain ${b.nodeFile} — ` +
        `version drift? Bump the pkg= field in scripts/patch-arm64-bindings.mjs.`,
    );
    return;
  }
  for (const parentDir of parentDirs) {
    const dest = join(parentDir, b.nodeFile);
    // Idempotency: if the .node file is already at this exact size,
    // skip the copy. (Same size = same content for these tarballs.)
    if (existsSync(dest)) {
      try {
        if (statSync(dest).size === statSync(src).size) {
          console.log(
            `[arm64-patch] ${b.pkg}: already in place at ${dest}, skipping`,
          );
          continue;
        }
      } catch {
        // fall through and overwrite
      }
    }
    copyFileSync(src, dest);
    console.log(`[arm64-patch] ${b.pkg}: installed → ${dest}`);
  }
}

// ---- main -------------------------------------------------------------

console.log(
  `[arm64-patch] Windows-ARM64 host detected; patching pnpm's missing native bindings...`,
);
for (const b of BINDINGS) {
  try {
    if (b.mode === 'dir-as-package') patchDirAsPackage(b);
    else if (b.mode === 'nodefile-into-pkg') patchNodefileIntoPkg(b);
    else {
      console.warn(`[arm64-patch] ${b.pkg}: unknown mode ${b.mode}`);
    }
  } catch (e) {
    console.error(`[arm64-patch] ${b.pkg}: failed — ${e.message}`);
    // Don't re-throw: a single missing binding shouldn't fail the
    // whole `pnpm install`. The dev server will surface the missing
    // binding as a clear error message when it's actually loaded.
  }
}
console.log('[arm64-patch] done.');
