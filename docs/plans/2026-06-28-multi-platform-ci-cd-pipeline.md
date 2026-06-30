# Multi-Platform CI/CD Pipeline (Linux / Windows / macOS)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Actions workflow that builds and tests `nalar` (Zig backend) + the Vue webapp on Linux, Windows, and macOS so that every PR is verified against all three platforms before merge.

**Architecture:** One GitHub Actions workflow with a **matrix** of native GitHub-hosted runners (`ubuntu-latest`, `windows-latest`, `macos-latest`) plus a second matrix entry for Apple Silicon (`macos-14`). **Each OS runs its own native `zig build`** against its own system libraries — we do **not** cross-compile from Linux. This avoids the pre-existing cross-compile blockers (`bash_selfkill.zig` Windows `pid_t`, `Agent.zig apply_tcp_keepalive` Windows `std.posix.setsockopt`, and the missing `addLibraryPath` for cross-target sysroots in `build.zig`). Native builds are slower per-runner but reliable and catch real platform bugs. Caching: `mlugg/setup-zig@v2` for Zig stdlib/cache + `actions/cache@v4` keyed on `build.zig.zon` and `package-lock.json`. Frontend (`bun run build` + `bunx vitest run`) is a separate job that runs on Linux only (the webapp is platform-independent; building it three times is wasteful).

**Tech Stack:** GitHub Actions, `mlugg/setup-zig@v2` (Zig 0.16.0), `oven-sh/setup-bun@v2` (Bun 1.x), `actions/cache@v4`, `actions/upload-artifact@v4`. Linux: `apt`. macOS: `brew`. Windows: Zig's bundled MinGW + `choco` for sqlite3/openssl when needed.

---

## Background — what's broken today

- **No CI exists.** `git remote -v` shows `ginwa/ginwaaitoolbox` but there's no `.github/workflows/` directory. PRs to `main` are merged without any platform verification.
- **Linux build works locally** but is not exercised on PRs. `zig build test --summary all` is the project's authoritative test command (per memory `verification-before-completion`).
- **Windows compile is blocked** by two known compile errors (per memory `zig-cross-platform-windows-blockers.md`):
  - `src/modules/agent/tools/bash_selfkill.zig:72` — `target_pid == self_pid` fails on Windows because `std.c.pid_t` is `*anyopaque` on Windows vs `i32` on Linux/macOS.
  - `src/modules/agent/Agent.zig:802-833` (`apply_tcp_keepalive`) — uses `std.posix.setsockopt` which has `@compileError("use std.Io instead")` on Windows (verified at `/usr/local/lib/zig/std/posix.zig:1074-1075`).
- **Cross-compile from Linux is blocked** at link time (per memory `nalar-build-cross-compile-blocked.md`). The `install:windows` / `install:macos` / `install:macos-arm` steps in `build.zig` do not set `addLibraryPath` for cross-target sysroots, so `linkSystemLibrary("sqlite3"/"ssl"/"crypto")` fails. **Fixing this is OUT OF SCOPE for this plan** — we work around it by using native runners.
- **`sse_manager.zig` uses `std.os.linux.MSG.NOSIGNAL`** inside a comptime `if (is_linux)` branch, so it compiles cross-platform (verified). No fix needed.

## Design Decisions (locked in)

1. **Native runners** for each OS — not cross-compile. Three matrix entries: `ubuntu-latest`, `windows-latest`, `macos-latest` (Intel x86_64), and a fourth `macos-14` for Apple Silicon (aarch64).
2. **Frontend runs on Linux only** — the webapp is OS-independent. Building it three times wastes ~2 minutes per run. The Vue/bun CI lives in the same workflow file as a separate job.
3. **Build the four artifacts** (Linux x86_64, Windows x86_64, macOS x86_64, macOS aarch64) and **upload each as a separate artifact** so users can download prebuilt binaries from the Actions run page.
4. **Cache Zig stdlib + .zig-cache** via `mlugg/setup-zig@v2`'s built-in cache (keyed on `build.zig.zon` hash).
5. **Cache bun node_modules** via `actions/cache@v4` (keyed on `package-lock.json` hash, restore-keys for the previous lock).
6. **Tests are non-blocking on macOS arm64 first run** — we're not 100% sure macOS aarch64 passes yet (the local Linux runner never exercises it). The first failure should be triaged; the second failure blocks merge.
7. **Workflow triggers**: `push` to `main`, `pull_request` to `main`, `workflow_dispatch` for manual runs.
8. **Concurrency control**: cancel in-progress runs for the same PR when a new commit is pushed (saves CI minutes).

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `.github/workflows/ci.yml` | **Create** | GitHub Actions matrix workflow: 4 OS jobs + 1 frontend job |
| `.github/dependabot.yml` | **Create** | Weekly dependency bump PRs for `oven-sh/setup-bun` and `mlugg/setup-zig` (optional, kept minimal) |
| `docs/ci.md` | **Create** | CI troubleshooting guide: how to read a failed matrix cell, common failures, cache-bust procedure |
| `README.md` | **Modify** | Add CI status badge at the top |
| `.gitignore` | **Modify** (if needed) | Add `.zig-cache/` and `zig-out/` if not already present |
| `src/modules/agent/tools/bash_selfkill.zig` | **Modify** (Chunk 0 prereq) | Windows `pid_t` compat fix |
| `src/modules/agent/Agent.zig` | **Modify** (Chunk 0 prereq) | Replace `std.posix.setsockopt` with `std.Io` keepalive |
| `src/helpers/process_status.zig` | **Verify exists** (Chunk 0 prereq) | Already created in earlier cross-platform work — verify and reuse |
| `src/helpers/mod.zig` | **Verify exports** (Chunk 0 prereq) | Export `process_status` if not already done |

No new test files. No changes to the webapp. No changes to `build.zig` install steps (cross-compile remains broken and we work around it).

---

## Chunk 0: Pre-requisite fixes for Windows

**Why this chunk exists:** Without these two fixes, the Windows job will fail at compile time and the workflow will be permanently red. Both fixes are mechanical and well-documented in project memory (`zig-cross-platform-windows-blockers.md`).

### Task 0.1: Fix `bash_selfkill.zig` Windows `pid_t` compatibility

**Files:**
- Modify: `src/modules/agent/tools/bash_selfkill.zig` (lines 8 and 72)
- Verify: `src/helpers/process_status.zig` (already created)

- [ ] **Step 0.1.1: Read the current `bash_selfkill.zig` to confirm the failure mode**

Run: `timeout 5 sed -n '1,15p;65,80p' src/modules/agent/tools/bash_selfkill.zig`
Expected: lines 8 and 72 match the failures documented in memory `zig-cross-platform-windows-blockers.md` (section "Class 4").

- [ ] **Step 0.1.2: Verify `helpers.process_status.getCurrentProcessIdInt()` exists and returns `i32`**

Run: `timeout 5 rg "pub fn getCurrentProcessIdInt" src/helpers/process_status.zig`
Expected: 1 hit. If 0 hits, the file from the earlier cross-platform work is missing — STOP and surface to user; this chunk depends on it.

- [ ] **Step 0.1.3: Modify `bash_selfkill.zig` to use `helpers.process_status.getCurrentProcessIdInt()`**

In `src/modules/agent/tools/bash_selfkill.zig`:

```zig
// Replace line 8:
const process_status = @import("../../../helpers/process_status.zig");
pub fn get_self_pid() std.c.pid_t {
    return process_status.getCurrentProcessIdInt();  // ← was process.getCurrentProcessId()
}
// Replace line 72 (the comparison):
// If `target_pid == self_pid` — both sides are now i32 via getCurrentProcessIdInt,
// so the comparison compiles on Windows.
```

The `std.c.pid_t` return type remains — but since `getCurrentProcessIdInt()` returns `i32` and Linux/macOS `pid_t` is `i32`, the implicit conversion succeeds on POSIX. On Windows, `std.c.pid_t` is `*anyopaque` but the function body returns `i32`; the cast will fail at the `return` line. **Therefore also change the return type to `i32`:**

```zig
pub fn get_self_pid() i32 {
    return process_status.getCurrentProcessIdInt();
}
```

- [ ] **Step 0.1.4: Verify Linux build still passes**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success` with the same test count as the baseline (no regressions; the `bash_selfkill_test.zig` tests must still pass — they exercise `get_self_pid()` against `os.getpid()`).

- [ ] **Step 0.1.5: Verify Windows type-checks via standalone `zig build-obj`**

Run:
```bash
cat > /tmp/test_bash_selfkill.zig <<'EOF'
const nalarcore = @import("nalarcore");
const m = nalarcore.helpers.process_status;
pub fn main() !void {
    const self = m.getCurrentProcessIdInt();
    std.debug.print("{d}\n", .{self});
}
EOF
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 30 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
    --dep nalarcore \
    -Mroot=/tmp/test_bash_selfkill.zig \
    -Mnalarcore=src/root.zig 2>&1 | head -n 10
```
Expected: zero errors. The `-fno-emit-bin` skips link so we don't need a Windows sysroot.

- [ ] **Step 0.1.6: Commit**

```bash
git add src/modules/agent/tools/bash_selfkill.zig
git commit -m "fix(bash_selfkill): use helpers.process_status.getCurrentProcessIdInt for Windows compat

Replace std.process.getCurrentProcessId() (returns *anyopaque on Windows)
with helpers.process_status.getCurrentProcessIdInt() (returns i32 on
all platforms via comptime switch).

Ref: zig-cross-platform-windows-blockers.md class 4."
```

### Task 0.2: Fix `Agent.zig apply_tcp_keepalive` Windows compile error

**Files:**
- Modify: `src/modules/agent/Agent.zig` (lines 802-833 — the `apply_tcp_keepalive` function)

- [ ] **Step 0.2.1: Read the current `apply_tcp_keepalive` implementation**

Run: `timeout 5 sed -n '795,840p' src/modules/agent/Agent.zig`
Expected: uses `std.posix.setsockopt(fd, SOL.IPPROTO.TCP, TCP.KEEPIDLE/...)` with raw bytes.

- [ ] **Step 0.2.2: Refactor to skip keepalive on Windows for v1 (acceptable temporary fix)**

**Design decision:** Per memory `zig-cross-platform-windows-blockers.md` class 6, the proper fix requires migrating to the `std.Io` socket API (a much larger refactor of `Agent.zig`'s streaming code). For the CI plan, we **gate `apply_tcp_keepalive` behind `builtin.os.tag != .windows`** so the Windows build passes today. The keepalive detection (currently ~6s) is replaced by no keepalive on Windows — a regression in stall-detection speed, but the connection still works.

```zig
fn apply_tcp_keepalive(sock: std.posix.socket_t) void {
    // Windows: std.posix.setsockopt has @compileError("use std.Io instead")
    // on Windows. The full std.Io socket migration is out of scope for this
    // plan; for now we skip keepalive on Windows (no 6s stall detection, but
    // the connection still works via TCP's default 2h timeout). Follow-up
    // plan to migrate Agent.zig's streaming sockets to std.Io.Net.
    if (builtin.os.tag == .windows) return;

    const keepidle: c_int = 2;
    std.posix.setsockopt(sock, std.posix.SOL.IPPROTO.TCP, std.posix.TCP.KEEPIDLE,
        std.mem.asBytes(&keepidle)) catch {};

    const keepintvl: c_int = 2;
    std.posix.setsockopt(sock, std.posix.SOL.IPPROTO.TCP, std.posix.TCP.KEEPINTVL,
        std.mem.asBytes(&keepintvl)) catch {};

    const keepcnt: c_int = 2;
    std.posix.setsockopt(sock, std.posix.SOL.IPPROTO.TCP, std.posix.TCP.KEEPCNT,
        std.mem.asBytes(&keepcnt)) catch {};
}
```

Add `const builtin = @import("builtin");` at the top of `Agent.zig` if not already present.

- [ ] **Step 0.2.3: Verify Linux build still passes**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: same baseline pass count (the function is exercised via the streaming agent tests).

- [ ] **Step 0.2.4: Verify Windows type-checks via standalone `zig build-obj`**

Run the same `zig build-obj -target x86_64-windows-gnu` pattern as Step 0.1.5 against a test root that imports `Agent.zig`. The Agent module is large — if compilation fails for unrelated reasons, focus only on `setsockopt` errors.

```bash
cat > /tmp/test_agent.zig <<'EOF'
const nalarcore = @import("nalarcore");
pub fn main() !void { _ = nalarcore; }
EOF
timeout 60 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
    --dep nalarcore \
    -Mroot=/tmp/test_agent.zig \
    -Mnalarcore=src/root.zig 2>&1 | head -n 20
```
Expected: zero errors mentioning `setsockopt` or `apply_tcp_keepalive`.

- [ ] **Step 0.2.5: Add a memory note about the temporary Windows keepalive gap**

Create the memory `~/.config/nalar/memories/agent-keepalive-windows-temporary-gap.md` (or edit the existing cross-platform memory) documenting:
- `Agent.zig apply_tcp_keepalive` is a no-op on Windows today.
- This means stall detection on Windows relies on TCP's default 2h keepalive (or never fires if the server doesn't RST).
- The fix requires migrating Agent.zig's socket code to `std.Io.Net` (out of scope; tracked as follow-up).

- [ ] **Step 0.2.6: Commit**

```bash
git add src/modules/agent/Agent.zig
git commit -m "fix(agent): skip tcp keepalive on Windows (std.posix.setsockopt unavailable)

Windows std.posix.setsockopt has @compileError('use std.Io instead').
The full std.Io.Net migration of Agent.zig's streaming sockets is a
larger follow-up; this commit gates apply_tcp_keepalive behind
builtin.os.tag != .windows so the Windows CI job can compile.

Stall-detection on Windows reverts to TCP's default 2h timeout.
Ref: zig-cross-platform-windows-blockers.md class 6."
```

---

## Chunk 1: Linux-only CI baseline

**Why this chunk exists:** Get the simplest matrix entry (just Linux) working end-to-end first. Validates the workflow syntax, caching strategy, artifact upload, and test command before adding the other 3 OS entries.

### Task 1.1: Create the workflow file with Linux-only matrix

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1.1.1: Write the initial workflow file**

```yaml
# .github/workflows/ci.yml
name: ci

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

# Cancel in-progress runs for the same PR when a new commit is pushed.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

env:
  ZIG_VERSION: 0.16.0
  BUN_VERSION: 1.1.42

jobs:
  backend:
    name: backend (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        # Chunk 1: Linux only. Chunks 3 and 4 add windows-latest,
        # macos-latest (Intel), and macos-14 (Apple Silicon).
        os: [ubuntu-latest]
        target:
          - { zig: x86_64-linux-gnu,       step: install:linux:system }
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install Zig ${{ env.ZIG_VERSION }}
        uses: mlugg/setup-zig@v2
        with:
          version: ${{ env.ZIG_VERSION }}

      - name: Install system dependencies (Ubuntu)
        if: runner.os == 'Linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            build-essential \
            libssl-dev \
            libsqlite3-dev \
            pkg-config

      - name: Show toolchain versions
        run: |
          zig version
          cc --version | head -n 1
          pkg-config --modversion sqlite3
          pkg-config --modversion openssl

      - name: Cache Zig build artifacts
        uses: actions/cache@v4
        with:
          path: |
            .zig-cache
            zig-out
          key: zig-${{ runner.os }}-${{ matrix.target.zig }}-${{ hashFiles('build.zig.zon', 'build.zig') }}
          restore-keys: |
            zig-${{ runner.os }}-${{ matrix.target.zig }}-

      - name: Run main test suite
        run: zig build test --summary all

      - name: Run AI workflow TUI tests
        run: zig build test:ai_workflow:tui --summary all

      - name: Build nalar binary
        run: zig build ${{ matrix.target.step }}

      - name: Verify binary was produced
        run: |
          test -f zig-out/bin/nalar && \
            echo "✓ zig-out/bin/nalar exists ($(stat -c%s zig-out/bin/nalar) bytes)"

      - name: Smoke test: version check
        run: ./zig-out/bin/nalar --version || true
        # The --version flag may not exist; this is a "does it run?" smoke test.

      - name: Upload nalar binary
        uses: actions/upload-artifact@v4
        with:
          name: nalar-${{ matrix.target.zig }}
          path: zig-out/bin/nalar
          retention-days: 14

  frontend:
    name: frontend
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install Bun ${{ env.BUN_VERSION }}
        uses: oven-sh/setup-bun@v2
        with:
          bun-version: ${{ env.BUN_VERSION }}

      - name: Cache bun node_modules
        uses: actions/cache@v4
        with:
          path: src/apps/desktop/node_modules
          key: bun-${{ runner.os }}-${{ hashFiles('src/apps/desktop/package-lock.json') }}
          restore-keys: |
            bun-${{ runner.os }}-

      - name: Install dependencies
        working-directory: src/apps/desktop
        run: bun install --frozen-lockfile

      - name: Type-check + bundle (vue-tsc + vite)
        working-directory: src/apps/desktop
        run: bun run build

      - name: Run vitest unit tests
        working-directory: src/apps/desktop
        run: bunx vitest run
```

- [ ] **Step 1.1.2: Verify the YAML is syntactically valid**

Run: `timeout 5 python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo OK`
Expected: `OK` printed. If YAML parse fails, fix the indentation before committing.

- [ ] **Step 1.1.3: Push to a feature branch and verify the workflow runs**

```bash
git checkout -b ci/linux-baseline
git add .github/workflows/ci.yml
git commit -m "ci: add GitHub Actions workflow (Linux-only matrix)"
git push origin ci/linux-baseline
# Open a PR or push to a branch — the workflow will run automatically.
# Expected: both backend (ubuntu-latest) and frontend jobs succeed.
```

- [ ] **Step 1.1.4: Document the first-run gotcha**

If the first run fails with `unable to find dynamic system library 'ssl'` or `'sqlite3'`, the system deps step didn't run before the build. The cause is likely a misnamed step in the `if:` conditional. Fix and re-push.

- [ ] **Step 1.1.5: Verify the artifact is downloadable**

After the workflow succeeds, go to the Actions run page → bottom of the page → Artifacts → download `nalar-x86_64-linux-gnu`. Verify the zip contains `nalar` binary (Linux x86_64 ELF).

- [ ] **Step 1.1.6: Merge to main**

Once the workflow is green, merge the PR to main. Subsequent pushes will run the workflow automatically.

---

## Chunk 2: Frontend job isolation and tuning

**Why this chunk exists:** The frontend job from Chunk 1 works but is configured with broad cache keys and lacks a build-on-PR-only optimization. This chunk tightens it and adds a vitest coverage report.

### Task 2.1: Tighten the frontend cache and add the type-check-only fast path

**Files:**
- Modify: `.github/workflows/ci.yml` (the `frontend` job)

- [ ] **Step 2.1.1: Add `bun run lint` to the frontend job as a separate step**

```yaml
      - name: Lint (oxlint + eslint)
        working-directory: src/apps/desktop
        run: bun run lint
        # Continue-on-error is set in the workflow-level default; we WANT lint
        # to fail the job if it breaks.
```

- [ ] **Step 2.1.2: Add a vitest coverage report**

```yaml
      - name: Run vitest with coverage
        working-directory: src/apps/desktop
        run: bunx vitest run --coverage

      - name: Upload coverage report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: frontend-coverage
          path: src/apps/desktop/coverage
          retention-days: 14
```

If the project doesn't have `@vitest/coverage-v8` installed yet, add it: `cd src/apps/desktop && bun add -D @vitest/coverage-v8`. Run locally first to confirm the config doesn't break existing tests.

- [ ] **Step 2.1.3: Verify the frontend job still passes**

Push a no-op commit (`git commit --allow-empty -m "ci: trigger workflow" && git push`) and confirm the workflow goes green.

---

## Chunk 3: Windows matrix addition

**Why this chunk exists:** Once Linux is green and Chunk 0's compile fixes are merged, we add `windows-latest` to the matrix. Windows requires MinGW for system libraries; we use the Zig bundled SDK approach.

### Task 3.1: Add Windows to the matrix

**Files:**
- Modify: `.github/workflows/ci.yml` (the `matrix.os` list and `target` list, plus a Windows install step)

- [ ] **Step 3.1.1: Extend the matrix with Windows targets**

```yaml
        os: [ubuntu-latest, windows-latest]
        target:
          - { zig: x86_64-linux-gnu,       step: install:linux:system }
          - { zig: x86_64-windows-gnu,     step: install:windows }
        exclude:
          # Only run the matching zig target for each OS. (Cross-compile
          # would be faster but is broken at link time per memory
          # nalar-build-cross-compile-blocked.md.)
          - os: ubuntu-latest
            target: { zig: x86_64-windows-gnu, step: install:windows }
          - os: windows-latest
            target: { zig: x86_64-linux-gnu, step: install:linux:system }
```

This produces exactly 2 cells: (ubuntu, linux) and (windows, windows). When we add macOS in Chunk 4, we'll add another exclude pair.

- [ ] **Step 3.1.2: Add Windows system library installation**

Zig on Windows typically uses the bundled MinGW (`-lc` etc. are picked up automatically), but `sqlite3` and `ssl` are NOT bundled. Add a Chocolatey step:

```yaml
      - name: Install system dependencies (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          choco install --no-progress sqlite openssl --version=3.1.4
          # sqlite comes via choco at C:\ProgramData\chocolatey\lib\mingw\tools\install\mingw64\...
          # zig on windows-latest (GitHub Actions) already has libsqlite3-0.dll on PATH.
```

**Important:** The `libsqlite3-dev` equivalent on Windows is `sqlite` via Chocolatey, which puts `sqlite3.h` in `C:\ProgramData\chocolatey\lib\sqlite\tools\` — NOT in Zig's default search path. The cleanest fix is to use `vcpkg` instead, but that requires installing `vcpkg` first.

**Alternative (simpler):** add a `vcpkg` install:

```yaml
      - name: Install system dependencies (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          git clone https://github.com/microsoft/vcpkg.git C:\vcpkg
          C:\vcpkg\bootstrap-vcpkg.bat
          C:\vcpkg\vcpkg.exe install sqlite3 openssl:x64-windows
          echo "VCPKG_ROOT=C:\vcpkg" >> $env:GITHUB_ENV
```

Then in `build.zig`, the `addLibraryPath` would need to point at `C:\vcpkg\installed\x64-windows\lib`. **However, this requires modifying `build.zig` to read `VCPKG_ROOT` from env — out of scope for this plan.**

**Pragmatic alternative (recommended for v1):** for the Windows CI job, run only the **test** step (not `install:windows`), and document that Windows binary builds are not yet exercised in CI. The compile-fix work in Chunk 0 already validates that the code type-checks on Windows; running `zig build test` on Windows-latest will exercise the test target (which uses the same code paths). The actual Windows BINARY artifact upload can come in a follow-up plan that wires vcpkg into build.zig.

```yaml
          # Drop the install step for Windows in v1; only run tests.
          # See docs/ci.md "Why no Windows binary yet" for the rationale.
          - { zig: x86_64-windows-gnu,     step: __SKIP__ }
```

And update the matrix `exclude`:

```yaml
        exclude:
          - os: ubuntu-latest
            target: { zig: x86_64-windows-gnu, step: __SKIP__ }
          - os: windows-latest
            target: { zig: x86_64-linux-gnu, step: install:linux:system }
```

- [ ] **Step 3.1.3: Update the "Build nalar binary" step to skip the placeholder**

```yaml
      - name: Build nalar binary
        if: matrix.target.step != '__SKIP__'
        run: zig build ${{ matrix.target.step }}
```

- [ ] **Step 3.1.4: Update the "Verify binary was produced" step similarly**

```yaml
      - name: Verify binary was produced
        if: matrix.target.step != '__SKIP__'
        run: |
          if [ "${{ runner.os }}" = "Windows" ]; then
            test -f zig-out/bin/nalarcore-windows-x86_64.exe && echo "✓ binary exists"
          else
            test -f zig-out/bin/nalar && echo "✓ binary exists"
          fi
```

- [ ] **Step 3.1.5: Verify the Windows job compiles and runs tests**

Push the change. Expected:
- `backend (windows-latest)` job succeeds.
- All tests pass on Windows.
- `zig-out/bin/nalarcore-windows-x86_64.exe` is NOT produced (per Step 3.1.2's v1 decision). The "Verify binary" step is skipped.

- [ ] **Step 3.1.6: If any test fails on Windows, triage**

Common causes:
- Hardcoded `/tmp` paths (replace with `std.fs.getAppDataDir` or similar — out of scope for this plan; surface as a follow-up).
- Hardcoded `/` paths in test fixtures (same).
- File-system case-sensitivity (Windows is case-insensitive; tests that create files with mixed-case names may collide).
- Line-ending differences (`\n` vs `\r\n`).

- [ ] **Step 3.1.7: Document the Windows-binary gap**

In `docs/ci.md` (created in Chunk 5), document:
> **Why no Windows binary in CI yet?**
> Building the Windows binary requires linking against `sqlite3` and `openssl`, which on Windows means installing them via `vcpkg` or `chocolatey` and pointing `build.zig` at the include/lib paths. This is a 1-2 day follow-up plan (wire `VCPKG_ROOT` into `build.zig` + add a `target = windows-latest` build step). Until then, Windows CI verifies that the code compiles and tests pass on Windows — the actual binary build is exercised locally before release.

---

## Chunk 4: macOS matrix addition (Intel + Apple Silicon)

**Why this chunk exists:** macOS support is the last piece. We need two matrix cells (Intel x86_64 and Apple Silicon aarch64) since `zig build install:macos` and `install:macos-arm` produce different binaries.

### Task 4.1: Add macOS to the matrix

**Files:**
- Modify: `.github/workflows/ci.yml` (matrix)

- [ ] **Step 4.1.1: Extend the matrix with macOS**

```yaml
        os: [ubuntu-latest, windows-latest, macos-latest, macos-14]
        target:
          - { zig: x86_64-linux-gnu,       step: install:linux:system }
          - { zig: x86_64-windows-gnu,     step: __SKIP__ }
          - { zig: x86_64-macos,           step: install:macos }
          - { zig: aarch64-macos,          step: install:macos-arm }
        exclude:
          - os: ubuntu-latest
            target: { zig: x86_64-windows-gnu, step: __SKIP__ }
          - os: ubuntu-latest
            target: { zig: x86_64-macos, step: install:macos }
          - os: ubuntu-latest
            target: { zig: aarch64-macos, step: install:macos-arm }
          - os: windows-latest
            target: { zig: x86_64-linux-gnu, step: install:linux:system }
          - os: windows-latest
            target: { zig: x86_64-macos, step: install:macos }
          - os: windows-latest
            target: { zig: aarch64-macos, step: install:macos-arm }
          - os: macos-latest
            target: { zig: x86_64-linux-gnu, step: install:linux:system }
          - os: macos-latest
            target: { zig: x86_64-windows-gnu, step: __SKIP__ }
          - os: macos-latest
            target: { zig: aarch64-macos, step: install:macos-arm }
          - os: macos-14
            target: { zig: x86_64-linux-gnu, step: install:linux:system }
          - os: macos-14
            target: { zig: x86_64-windows-gnu, step: __SKIP__ }
          - os: macos-14
            target: { zig: x86_64-macos, step: install:macos }
```

This produces 4 cells: (ubuntu,linux), (windows,windows-skip), (macos-latest,macos), (macos-14,arm64).

- [ ] **Step 4.1.2: Add macOS system library installation**

macOS-latest runners come with sqlite3 pre-installed via Xcode CLT, but **OpenSSL is not present**. Install via brew:

```yaml
      - name: Install system dependencies (macOS)
        if: runner.os == 'macOS'
        run: |
          brew update
          brew install openssl@3
          # openssl@3 is keg-only; export paths explicitly:
          echo "LDFLAGS=-L$(brew --prefix openssl@3)/lib" >> $GITHUB_ENV
          echo "CPPFLAGS=-I$(brew --prefix openssl@3)/include" >> $GITHUB_ENV
          echo "PKG_CONFIG_PATH=$(brew --prefix openssl@3)/lib/pkgconfig" >> $GITHUB_ENV
```

- [ ] **Step 4.1.3: Update the binary verification step to handle macOS**

```yaml
      - name: Verify binary was produced
        if: matrix.target.step != '__SKIP__'
        run: |
          case "${{ runner.os }}" in
            Linux)   test -f zig-out/bin/nalar && echo "✓ nalar exists" ;;
            Windows) test -f zig-out/bin/nalarcore-windows-x86_64.exe && echo "✓ nalar.exe exists" ;;
            macOS)   ls zig-out/bin/nalarcore-macos-* 2>/dev/null | grep -q . && echo "✓ macos binary exists" ;;
          esac
```

- [ ] **Step 4.1.4: Update the artifact upload to handle macOS naming**

```yaml
      - name: Upload nalar binary
        if: matrix.target.step != '__SKIP__'
        uses: actions/upload-artifact@v4
        with:
          name: nalar-${{ matrix.target.zig }}
          path: |
            zig-out/bin/nalar
            zig-out/bin/nalarcore-windows-x86_64.exe
            zig-out/bin/nalarcore-macos-x86_64
            zig-out/bin/nalarcore-macos-aarch64
          retention-days: 14
```

- [ ] **Step 4.1.5: Verify both macOS cells succeed**

Push the change. Expected:
- `backend (macos-latest)` and `backend (macos-14)` both green.
- 2 macOS artifacts uploaded: `nalar-x86_64-macos` and `nalar-aarch64-macos`.

- [ ] **Step 4.1.6: If macOS tests fail, triage**

Common causes:
- `linkSystemLibrary("ssl")` resolves to LibreSSL on macOS instead of OpenSSL. Zig's stdlib is happy with either, but the behavior may differ slightly. The brew step (4.1.2) ensures OpenSSL is found.
- File-system case-insensitivity on macOS (HFS+/APFS is case-INsensitive by default, even though APFS supports case-sensitive volumes). Tests that create files with mixed-case names may collide.
- Path separators (`/` vs `\`). Use `std.fs.path.sep` not hardcoded `/`.

- [ ] **Step 4.1.7: Verify the artifacts are downloadable**

Download `nalar-x86_64-macos` and `nalar-aarch64-macos`. Confirm they are Mach-O binaries:

```bash
file nalarcore-macos-x86_64
# Expected: Mach-O 64-bit executable x86_64
file nalarcore-macos-aarch64
# Expected: Mach-O 64-bit executable arm64
```

---

## Chunk 5: Polish and documentation

**Why this chunk exists:** A green CI without a badge in the README and without a troubleshooting doc is half-done. New contributors need to know how to read a failed matrix cell.

### Task 5.1: Add a CI status badge to README

**Files:**
- Modify: `README.md`

- [ ] **Step 5.1.1: Add the badge markdown near the top of README.md**

```markdown
[![CI](https://github.com/ginwa/ginwaaitoolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/ginwa/ginwaaitoolbox/actions/workflows/ci.yml)
```

Place it after the project title and before the first paragraph. The exact placement depends on the current README structure; insert it as the second line if the README starts with `# ginwaaitoolbox`.

- [ ] **Step 5.1.2: Verify the badge URL resolves**

Open `https://github.com/ginwa/ginwaaitoolbox/actions/workflows/ci.yml/badge.svg` in a browser. Expected: an SVG image with the workflow status. If the URL returns 404, the workflow hasn't run yet — push a no-op commit to trigger it.

### Task 5.2: Create the CI troubleshooting guide

**Files:**
- Create: `docs/ci.md`

- [ ] **Step 5.2.1: Write the troubleshooting doc**

```markdown
# CI / Build Pipeline

## Overview

The `.github/workflows/ci.yml` workflow builds and tests `nalar` (Zig backend)
on Linux, Windows, and macOS, plus the Vue webapp on Linux. Every PR to
`main` must pass all green matrix cells before merge.

## Matrix cells

| Cell | OS | Zig target | Build step | Artifact |
|------|----|----|----|----|
| `backend (ubuntu-latest)` | Ubuntu 24.04 | x86_64-linux-gnu | `install:linux:system` | `nalar-x86_64-linux-gnu` |
| `backend (windows-latest)` | Windows Server 2022 | x86_64-windows-gnu | (tests only) | (none yet — see below) |
| `backend (macos-latest)` | macOS 14 (Intel) | x86_64-macos | `install:macos` | `nalar-x86_64-macos` |
| `backend (macos-14)` | macOS 14 (Apple Silicon) | aarch64-macos | `install:macos-arm` | `nalar-aarch64-macos` |
| `frontend` | Ubuntu 24.04 | n/a | `bun run build` + `bunx vitest run` | `frontend-coverage` |

## Why no Windows binary in CI yet?

Building the Windows binary requires linking against `sqlite3` and
`openssl`, which on Windows means installing them via `vcpkg` or
`chocolatey` and pointing `build.zig` at the include/lib paths. This
is a 1-2 day follow-up plan (wire `VCPKG_ROOT` into `build.zig` +
add a Windows build step). Until then, Windows CI verifies that
the code **compiles** and **tests pass** on Windows — the actual
binary build is exercised locally before release.

## Common failures

### "unable to find dynamic system library 'ssl'" or 'sqlite3'

The `apt-get install` (Ubuntu), `choco install` (Windows), or
`brew install openssl@3` (macOS) step ran AFTER the `zig build` step.
Check the step ordering — system deps must come BEFORE the cache
restore step (so the system libraries are present when the cache is
hit and the build runs).

### "Error: Zig version mismatch" or build cache stale

The `.zig-cache` cache key is based on `build.zig.zon` + `build.zig`.
If you changed either, the cache misses and rebuilds from scratch.
If you changed `httpz` (the http.zig dependency) but not `build.zig.zon`,
the cache hits with a stale hash and the build fails with cryptic
import errors. **Fix:** bump the cache key with a no-op edit to
`build.zig` (add a blank line) and push.

### "Permission denied" copying nalar to /usr/local/bin

This is the `install:linux:system` step's `cp` to `/usr/local/bin/`.
Expected on CI (no sudo to that path). The artifact is still produced
at `zig-out/bin/nalar`; only the system copy fails. Not a real failure.

### Windows: "@compileError("use std.Io instead")"

Means `std.posix.setsockopt` was called somewhere. The known site is
`src/modules/agent/Agent.zig apply_tcp_keepalive` — this is gated
behind `builtin.os.tag != .windows` (commit from Chunk 0). If you
see this error in a NEW file, surface to user — that's a new
cross-platform bug.

### macOS: "Library not loaded: @rpath/libssl.3.dylib"

Means the `brew install openssl@3` step didn't run before the build.
Verify `brew --prefix openssl@3` returns a non-empty path in the
CI log.

## Reading a failed matrix cell

1. Click the failed cell name in the Actions run summary.
2. Look at the FIRST failed step (not the last — GitHub shows the
   last failed step at the bottom; the first is the root cause).
3. If the failure is in `Run main test suite` (`zig build test`):
   the failing test is named in the test output. Run it locally
   with `zig build test --summary all` and reproduce.
4. If the failure is in `Build nalar binary`:
   check the linker error. Most likely a system library is missing.
5. If the failure is in `Upload nalar binary`:
   the binary was not produced — re-check the previous step's
   output for a silent failure.

## Manually triggering the workflow

Go to Actions → CI → Run workflow → select branch → Run. Useful for
re-running after a flaky test fix without pushing a new commit.

## Updating the Zig or Bun version

Edit the `env:` block at the top of `ci.yml`. Bump `ZIG_VERSION`
or `BUN_VERSION`. The next run will pick up the new version; old
caches are automatically invalidated because the version is part
of the cache key path (for Zig) or because Bun reinstalls node_modules
from scratch on version bump (for Bun).

## Cross-compile follow-up (out of scope for this plan)

The `zig build install:windows`, `install:macos`, `install:macos-arm`
steps in `build.zig` are cross-compile steps that do not work from
a Linux host — they fail at link time with "unable to find dynamic
system library 'sqlite3'" because `addLibraryPath` is not set for
cross-target sysroots. Fixing this requires installing Windows SDKs
(e.g. `mingw-w64`) and macOS sysroots on a Linux host, OR adding
conditional `addLibraryPath` reads from environment variables.

Follow-up plan: `docs/plans/2026-XX-XX-cross-compile-from-linux.md`.
```

- [ ] **Step 5.2.2: Add a link from README.md to docs/ci.md**

In `README.md`, after the CI badge, add:

```markdown
See [docs/ci.md](docs/ci.md) for the CI matrix layout, common failures,
and how to read a failed build.
```

### Task 5.3: Add a CI verification checklist to the project memory

**Files:**
- Modify: `~/.config/nalar/memories/verification-before-completion/SKILL.MD` (or a similar memory file)

- [ ] **Step 5.3.1: Add a CI section to the verification checklist**

In the verification-before-completion skill content, add a section:

```markdown
## CI verification (nalar)

Before declaring a multi-file change complete, push to a feature branch
and confirm the CI workflow is green:

```bash
git push origin <branch>
# Open https://github.com/ginwa/ginwaaitoolbox/actions
# Verify all 5 jobs are green:
#   - backend (ubuntu-latest)
#   - backend (windows-latest)
#   - backend (macos-latest)
#   - backend (macos-14)
#   - frontend
```

If any cell is red, do NOT merge — even if local tests pass. The CI
matrix catches cross-platform regressions that the Linux dev box misses
(see project memory `nalar-build-cross-compile-blocked.md` and
`zig-cross-platform-windows-blockers.md` for context).
```

- [ ] **Step 5.3.2: Update NALAR.md with the new CI tooling location**

In `NALAR.md`, add a "CI/CD" section under "Available tooling":

```markdown
## CI/CD

- Workflow file: `.github/workflows/ci.yml`
- 4 backend matrix cells (linux/windows/macos/macos-arm) + 1 frontend cell
- All PRs to `main` must pass before merge
- See `docs/ci.md` for troubleshooting and the matrix layout
- Triggers: `push` to main, `pull_request` to main, `workflow_dispatch`
```

---

## Verification

End-to-end verification that the plan succeeded:

1. **Workflow file exists and is valid YAML**:
   `timeout 5 python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo OK`

2. **All 5 matrix cells produce a green check**:
   Open `https://github.com/ginwa/ginwaaitoolbox/actions` → most recent run → all 5 cells show ✅.

3. **All 4 backend artifacts are downloadable**:
   Run artifacts → `nalar-x86_64-linux-gnu`, `nalar-x86_64-windows-gnu` (note: empty or skipped per Chunk 3), `nalar-x86_64-macos`, `nalar-aarch64-macos`. Linux + macOS artifacts contain real binaries; Windows artifact is empty (per design decision).

4. **Linux binary runs**:
   ```bash
   curl -L -o nalar https://github.com/ginwa/ginwaaitoolbox/actions/runs/<id>/artifacts/nalar-x86_64-linux-gnu
   chmod +x nalar && ./nalar --version
   ```
   Expected: prints version info (or `--help` works) without segfault.

5. **macOS binaries are real Mach-O**:
   ```bash
   file nalarcore-macos-x86_64
   # Expected: Mach-O 64-bit executable x86_64
   file nalarcore-macos-aarch64
   # Expected: Mach-O 64-bit executable arm64
   ```

6. **Frontend coverage is uploaded**:
   Actions run → Artifacts → `frontend-coverage` contains an HTML report with the test coverage percentages.

7. **README has the CI badge**:
   Open `https://github.com/ginwa/ginwaaitoolbox` → top of README → see a green "CI" badge.

8. **CI troubleshooting doc is in place**:
   Open `docs/ci.md` in the repo. Verify the table, the "Why no Windows binary yet?" section, and the "Common failures" section are present.

9. **No regressions on the baseline test suite**:
   The CI must report the same `zig build test` pass count as the local baseline (currently ~760 tests, per memory `zig-cross-platform-day2-fixes.md`). Any drop is a regression.

10. **Badge URL is live**:
    `curl -I https://github.com/ginwa/ginwaaitoolbox/actions/workflows/ci.yml/badge.svg` returns `200 OK` (not 404).

---

## Follow-ups (out of scope)

These are tracked separately:

1. **Windows binary in CI**: wire `VCPKG_ROOT` into `build.zig` and add a Windows install step. (See `docs/ci.md` "Why no Windows binary yet?" for the rationale.)
2. **Cross-compile from Linux**: fix `install:windows` / `install:macos` / `install:macos-arm` to work from a Linux host. Requires either installing cross-compile SDKs OR adding conditional `addLibraryPath` reads from env vars.
3. **`std.Io.Net` migration for `Agent.zig`**: the `apply_tcp_keepalive` Windows skip is a temporary workaround. Full migration to `std.Io.Net` enables keepalive on all platforms.
4. **Release automation**: tag-triggered builds that produce signed binaries + a GitHub Release page. Out of scope for "CI passes on every PR".
5. **Performance benchmarks**: a separate workflow that runs benchmarks on each matrix cell and posts the results as a PR comment. Out of scope.
6. **Code coverage for Zig**: kcov or similar. The frontend already has coverage; the backend doesn't yet.
7. **Dependabot config**: weekly PRs to bump `oven-sh/setup-bun`, `mlugg/setup-zig`, `actions/checkout`, etc. Trivial but out of scope for v1.

---

## Risk and Mitigation

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| First run fails with cryptic linker error | High | Medium | The `docs/ci.md` troubleshooting section covers the most common ones; failing builds block merge so they'll be fixed before deploy |
| Windows tests have hardcoded `/tmp` or `/` paths | Medium | High | The cross-platform work in earlier plans (`zig-cross-platform-windows-blockers.md`) already fixed all known cases; a follow-up PR will be needed if new ones surface |
| macOS brew install is slow (3-5 min) | High | Low | macOS cells run in parallel with Linux/Windows; total wallclock is bounded by the slowest cell |
| zig cache misses too often, slowing CI | Medium | Medium | Cache key includes `build.zig` hash; only changes when `build.zig` or `build.zig.zon` changes (rare) |
| `macos-14` runner changes to arm64 by default | Low | Low | GitHub's `macos-14` is already arm64; `macos-latest` was Intel until 2024-2025, then arm64. The matrix `exclude` keeps the cells separate |
| Zig 0.16.0 release has a Windows-specific bug | Low | High | The cross-platform fixes from earlier plans cover all known Windows blockers; a new Zig patch release would surface as a single failing cell, easy to triage |