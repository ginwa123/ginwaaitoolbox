# nalar — gitignore large vendored binaries + fetch on demand pattern

When a project vendors large C/C++ binaries (SQLite amalgamation, libxml2,
zlib, etc.) into a `vendor/` directory for cross-platform builds, the
~10 MB of binary-like content bloats every git clone with no diffable
substance. The proper fix is to gitignore the vendor dir and fetch it
on demand.

## The pattern (5 files, +534/-284702 on the nalar SQLite case)

1. **`.gitignore`** — anchor to repo root:
   ```
   /vendor/
   ```
   The leading slash ensures it ONLY matches the repo-root `vendor/`
   dir, not nested `src/.../vendor/` directories of third-party code.

2. **`scripts/fetch-vendor-X.sh`** — idempotent downloader:
   - Skip if all files exist (idempotent)
   - `curl --retry 3 --connect-timeout 30` (network resilience)
   - Verify SHA3-256 (or SHA-256 if sha3sum isn't available) against
     the upstream download page
   - Extract via `python3 - zipfile` (primary, cross-platform) or
     `unzip` (fallback for minimal CI images)
   - Make it executable: `chmod +x scripts/fetch-vendor-X.sh`

3. **`.github/workflows/ci.yml`** — invoke on non-native runners:
   ```yaml
   - name: Fetch vendored X amalgamation (Windows / macOS)
     if: runner.os != 'Linux'
     shell: bash
     run: |
       chmod +x scripts/fetch-vendor-X.sh
       ./scripts/fetch-vendor-X.sh
   ```
   And add the vendor dir to the cache path + include the script in
   the cache key so version bumps invalidate the cache.

4. **`README.md`** + **`docs/ci.md`** — document the Linux (system
   library) vs Windows/macOS (fetch) flow, with a troubleshooting
   section for "unable to find file 'vendor/X/X.c'".

5. **Static-contract regression tests** — verify the contracts:
   - `.gitignore` contains the anchored rule (line-level, not substring
     — comment lines shouldn't count)
   - The script exists with shebang
   - The script pins specific version + URL + SHA
   - The script is idempotent ("skipping fetch" marker)
   - The script has python3 AND unzip extraction paths
   - CI workflow invokes the script on non-Linux runners
   - CI cache key includes the script

## Why this pattern

- **Removes ~285K lines of binary content from every clone** without
  breaking the build for fresh checkouts.
- **Linux users don't notice anything** — they continue using
  `linkSystemLibrary("X")` against the system library. Only Windows/
  macOS targets (or cross-compile from Linux) need the amalgamation.
- **CI cells stay green** — the fetch step runs before any `zig build`
  call on Windows/macOS, with the result cached across runs.
- **Red-green testable** — the static-contract tests catch every
  regression: rule removed, script deleted, SHA mismatch, cache key
  drift, etc.

## Anti-patterns to avoid

- ❌ **Don't commit the amalgamation and rely on `git lfs`** — LFS
  pollutes the clone workflow with extra setup steps and is a pain
  for tools that don't support LFS (notably some static analyzers).
- ❌ **Don't use `git submodule` for the amalgamation** — submodules
  add cloning complexity (init + update) that confuses fresh contributors.
- ❌ **Don't just delete the vendor dir without a fetch step** —
  breaks the build for Windows/macOS users with no clear recovery path.
- ❌ **Don't add the rule as `vendor/` (no leading slash)** — matches
  nested `src/.../vendor/` directories of third-party code and hides
  real source files from `git status`.

## Version-bump workflow

To bump the vendored library version:

1. Update the version constants + URL + SHA3-256 in the fetch script.
2. Update the regression tests to match the new constants (or the
   tests will fail).
3. Delete the local `vendor/` dir and re-run the fetch script to
   verify the new SHA matches.
4. CI will detect the cache-key change and re-fetch on the next push.

## Reference implementation

The full working example is in this repo at commit `eeb15157`
(PR #66 squash-merge): `.gitignore:23`, `scripts/fetch-vendor-sqlite3.sh`,
`.github/workflows/ci.yml` ("Fetch vendored SQLite amalgamation" step),
`src/ai_workflow/tui/gitignore_vendor_sqlite3_test.zig`. Eight static
tests cover the contracts. Net diff: +534 / -284,702 lines (~285K
lines of binary content removed).