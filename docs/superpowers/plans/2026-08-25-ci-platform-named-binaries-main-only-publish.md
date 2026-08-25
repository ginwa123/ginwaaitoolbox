# Plan: adjust ci.yml — platform-named binaries + main-only publish

**Task:** task_1787577212777_8 ("adjust ci.yml")
**Date:** 2026-08-24
**File touched:** `.github/workflows/ci.yml` (backend job only)

## User requirements (verbatim intent)

1. Binary name must also carry the **platform name**
   (e.g. `nalar-x86_64-linux-gnu`, `nalar-desktop-aarch64-macos`,
   `nalar-x86_64-windows-gnu.exe`).
2. Only pipelines that land on **main** build+publish binaries
   (push to main, or manual `workflow_dispatch`).
3. A **pull request from another branch → main** runs the pipeline
   (tests/build) but must **NOT upload/publish any binary**.

## Current state (verified on main @ 7111e730)

The workflow already has the right *shape* — PR #303 moved binary delivery
from quota-metered Actions artifacts to a rolling `ci-latest` GitHub Release:

| Requirement | Status | Where |
|---|---|---|
| Platform in asset name | ❌ **BROKEN** | "Stage binaries with target-triple names" steps copy files but keep plain names (`nalar`, `nalar-desktop`) |
| Publish only on main | ✅ already correct | `if: github.event_name == 'push' \|\| github.event_name == 'workflow_dispatch'` on the publish step |
| PRs never publish | ✅ already correct | same gate — `pull_request` events skip publish; they only stage into a local dir |

### The actual bug

Both staging steps do:

```bash
cp "zig-out/bin/$candidate" "$stage/$candidate"     # bash twin (Linux/macOS)
Copy-Item "zig-out/bin/$candidate" "$stage/$candidate"  # pwsh twin (Windows)
```

…so every cell stages `bin-stage-<triple>/nalar` and
`bin-stage-<triple>/nalar-desktop`. When all 3 matrix cells upload to the
SHARED `ci-latest` release, softprops derives asset names from filenames:

- Linux uploads `nalar`, macOS uploads `nalar` → **collision / overwrite**.
  Last writer wins; users can't tell which platform a file is for, and one
  platform's binary silently disappears from the release.
- The release body text *claims* assets are named
  `nalar[-desktop]-<target>[.exe]` — documentation lies about reality.

## Fix design

### Change 1 — staging steps rename with the triple suffix

Single source of truth: `matrix.target.zig` (already in the matrix:
`x86_64-linux-gnu`, `aarch64-macos`, `x86_64-windows-gnu`).

bash twin (Linux/macOS):

```bash
stage="bin-stage-${{ matrix.target.zig }}"
for bin in nalar nalar-desktop; do
  src="zig-out/bin/$bin"
  [ -f "$src.exe" ] && src="$src.exe"
  dst="$stage/${bin}-${{ matrix.target.zig }}${src##*zig-out/bin/$bin}"
  cp "$src" "$dst"
done
```

Concretely produces:

| Cell | staged files |
|---|---|
| Linux X64 | `nalar-x86_64-linux-gnu`, `nalar-desktop-x86_64-linux-gnu` |
| macOS ARM64 | `nalar-aarch64-macos`, `nalar-desktop-aarch64-macos` |
| Windows X64 | `nalar-x86_64-windows-gnu.exe`, `nalar-desktop-x86_64-windows-gnu.exe` |

pwsh twin (Windows): same logic, `Copy-Item` + explicit `.exe` suffix.

### Change 2 — publish step (no gate change needed)

Gate stays exactly as-is (`push || workflow_dispatch`) — that already
satisfies requirements 2 & 3. Only edits:

- Update the release `body:` text so it matches the real asset naming.
- Keep `files: bin-stage-${{ matrix.target.zig }}/*`.

### Why not other approaches

- **Rename inside zig-out/bin**: mutates build outputs consumed by later
  verify/smoke steps (`Verify desktop + service binaries`,
  `Smoke test: criteria pass` probe `zig-out/bin/nalar`). Staging-dir-only
  rename keeps those untouched.
- **Per-cell distinct release tags**: fragments downloads across 3 URLs;
  shared rolling tag + unique filenames is simpler for consumers.

## Steps

1. [x] Write this plan doc.
2. [ ] Edit bash staging step: append `-${{ matrix.target.zig }}` (+ `.exe`
       if source had it) to staged filename.
3. [ ] Edit pwsh staging step: same suffix logic.
4. [ ] Update publish step body text to describe real asset names; confirm
       gate unchanged.
5. [ ] Validate with actionlint (local download per skill
       `actionlint-before-pushing-workflows`; asset
       `actionlint_<ver>_linux_amd64.tar.gz`), commit on worktree branch,
       push, open PR.

## Verification

- actionlint exit 0 on `.github/workflows/ci.yml`.
- Static grep: staged filename template contains `${{ matrix.target.zig }}`.
- On next green run: `gh release view ci-latest --json assets` shows 6
  assets, each carrying its triple (3 cells × 2 binaries), no collisions.
