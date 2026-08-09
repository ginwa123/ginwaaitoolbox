# Plan: Self-contained `databases` Zig package + platform-aware `zig build`

**Task**: `ffix error zig build` + "zig build detect platform current".

**Owner**: TBD.

**Worktree**: `worktree/database-self-contained-package` (created from
`main` @ HEAD).

---

## 1. Context (symptoms + root cause)

The user reports two issues with `zig build`:

1. **Build error** (warning, but noisy): the `linux` branch of
   `linkPlatformDeps` adds a `-L vendor/sqlite3/linux-x86_64` library
   path that does not exist in this checkout. The build still
   succeeds (system `libsqlite3.so` is found via `/usr/lib`), but the
   "warning: unable to open library directory ... FileNotFound"
   message reads as an error to the user.

   Cross-compile to Windows/macOS has the same problem in a stronger
   form: the vendored `vendor/sqlite3/libc-windows-amd64/` and
   `vendor/sqlite3/macos-{arm64,x86_64}/` symlink farms don't exist
   either (they're gitignored; the build expects them to be
   pre-populated by `scripts/fetch-vendor-sqlite3.sh` /
   `scripts/build-vendor-mingw.sh` / etc.). Cross-compile is broken
   on a fresh checkout.

2. **Platform detection**: `zig build` always builds the Linux x86_64
   cross-target (`install:linux` step → `nalarcore-linux-x86_64`),
   regardless of the host OS. On macOS/Windows, the user gets a
   Linux cross-compiled binary instead of a native one by default.
   The user wants `zig build` to be host-aware.

The user has independently created a fresh `zig init`-style package at
`src/modules/databases/` (`build.zig` + `build.zig.zon` + `src/{root,
main}.zig`) with the intent of moving sqlite3 / openssl / libpq link
dependencies OUT of the main `build.zig` and INTO the package's own
`build.zig`. The main `build.zig` should then just `@import("databases")`
as a normal Zig dependency.

This plan completes that refactor and addresses both user-reported
issues.

---

## 2. Target architecture

```
src/
├── modules/
│   └── databases/                          ← self-contained Zig package
│       ├── build.zig                       ← adds sqlite3/openssl/pq deps
│       ├── build.zig.zon                   ← name=databases, fingerprint,
│       │                                     paths=src
│       └── src/
│           ├── root.zig                    ← public API re-exports
│           ├── main.zig                    ← (placeholder CLI from zig init)
│           ├── database.zig                ← moved from src/modules/databases/
│           ├── sqlite/                     ← moved from src/modules/databases/sqlite/
│           │   ├── Sqlite.zig
│           │   ├── sqlite_test.zig
│           │   └── sqlite_test_rows_capture_error.zig
│           ├── postgres/                   ← moved from src/modules/databases/postgres/
│           │   ├── postgres.zig
│           │   ├── postgres_test.zig
│           │   └── test_helpers.zig + test_helpers_test.zig
│           └── test_runner.zig             ← test entry point for the package
└── root.zig                                ← @import("databases") instead of
                                              relative paths
```

**Build flow**:

- `zig build` on Linux host → builds `nalar` (native target),
  `nalar-desktop` (native), `nalarcli` (native), prints summary.
  No cross-compile to Linux x86_64 by default (still available via
  explicit `zig build install:linux`).
- `zig build` on macOS host → builds `nalarcore-macos-aarch64` (or
  `-macos-x86_64` for Intel), `nalar-desktop`, `nalarcli`.
- `zig build` on Windows host → builds `nalarcore-windows-x86_64.exe`,
  `nalar-desktop`, `nalarcli`.
- Cross-compile still works via explicit
  `zig build install:linux` / `install:macos` / `install:windows`.

---

## 3. Step-by-step

### Step 1 — Move existing database code into `src/modules/databases/src/`

The existing files live at the top level of `src/modules/databases/`.
The package convention (driven by `paths = .{..., "src"}` in
`build.zig.zon`) puts source under `src/`. Move:

- `src/modules/databases/database.zig` →
  `src/modules/databases/src/database.zig`
- `src/modules/databases/sqlite/` (3 files) →
  `src/modules/databases/src/sqlite/`
- `src/modules/databases/postgres/` (4 files) →
  `src/modules/databases/src/postgres/`
- `src/modules/databases/test_runner.zig` →
  `src/modules/databases/src/test_runner.zig`

Use `git mv` so git tracks the move. The internal `@import(...)`
paths inside these files are already relative to their own directory
(`sqlite_test.zig` → `@import("Sqlite.zig")` from inside the same
folder), so no internal changes are needed.

### Step 2 — Make `src/modules/databases/src/root.zig` the public API

Replace the placeholder content (`add`, `printAnotherMessage`,
fuzz test) with re-exports of the public APIs:

```zig
//! databases package — public API root.
//!
//! Consumers import as `@import("databases")` (the module name declared
//! in build.zig) and access nested namespaces:
//!
//!   const sqlite = @import("databases").sqlite;
//!   const postgres = @import("databases").postgres;
const std = @import("std");

pub const sqlite = @import("sqlite/Sqlite.zig");
pub const postgres = @import("postgres/postgres.zig");

// Internal helpers — exposed so the package's own test_runner.zig
// can pull them in via the same module.
pub const test_runner = @import("test_runner.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
```

`src/main.zig` stays as the `zig init`-generated CLI placeholder —
harmless because nothing depends on it. (It's invoked only by
`zig build run` inside the package directory.)

### Step 3 — Update `src/modules/databases/build.zig`

Replace the `zig init` boilerplate with a minimal, package-style
`build.zig` that:

1. Declares one module `databases` rooted at `src/root.zig`.
2. Adds sqlite3 / ssl / crypto / pq link deps **based on the
   COMPILE's target** (matches the per-Compile pattern in main
   `build.zig::linkPlatformDeps`).
3. Adds include paths for sqlite3.h on every host (the cimport is
   portable C — see main build.zig comments at line 753-771).
4. Exposes a `test` step that runs `src/test_runner.zig`'s tests.

Pseudo-structure:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("databases", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // SQLite3 + OpenSSL + libpq — matches main build.zig::linkPlatformDeps
    // .linux branch. Cross-target paths come from the main build.zig
    // (this package only adds deps for the current build target;
    // cross-target linkage happens at the consumer).
    mod.linkSystemLibrary("c", .{});
    mod.link_libc = true;

    switch (target.result.os.tag) {
        .linux => {
            mod.linkSystemLibrary("sqlite3", .{});
            mod.linkSystemLibrary("ssl", .{});
            mod.linkSystemLibrary("crypto", .{});
            mod.linkSystemLibrary("pq", .{});
            mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
            mod.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
        },
        .macos => {
            mod.linkSystemLibrary("sqlite3", .{});
            mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite/include" });
            mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite/lib" });
        },
        .windows => {
            mod.addIncludePath(b.path("vendor/sqlite3"));
            mod.addCSourceFile(.{
                .file = b.path("vendor/sqlite3/sqlite3.c"),
                .flags = &.{ "-DSQLITE_THREADSAFE=0",
                             "-DSQLITE_OMIT_LOAD_EXTENSION",
                             "-DSQLITE_ENABLE_FTS5" },
            });
        },
        else => {
            mod.addIncludePath(b.path("vendor/sqlite3"));
            mod.addCSourceFile(.{
                .file = b.path("vendor/sqlite3/sqlite3.c"),
                .flags = &.{ "-DSQLITE_THREADSAFE=0",
                             "-DSQLITE_OMIT_LOAD_EXTENSION",
                             "-DSQLITE_ENABLE_FTS5" },
            });
        },
    }

    // Tests for the package itself.
    const mod_tests = b.addTest(.{ .root_module = mod });
    mod_tests.root_module.linkSystemLibrary("c", .{});
    mod_tests.root_module.link_libc = true;
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run databases package tests");
    test_step.dependOn(&run_mod_tests.step);
}
```

This is intentionally small. The package is meant to be a leaf
dependency, not a runnable application. The `exe`/`run` steps from
`zig init` boilerplate are NOT re-added — they would force a
`main()` function that's not part of the public API.

### Step 4 — Update `src/modules/databases/build.zig.zon` paths

The current `paths` field includes `"src"`, which is correct.
**Leave it alone** — it already covers everything we moved in
Step 1. Update only if the move didn't add new top-level files.

### Step 5 — Update root `build.zig.zon` to add `databases` as a dependency

Add the package to the `dependencies` table:

```zon
.dependencies = .{
    .databases = .{
        .path = "src/modules/databases",
    },
},
```

This is a path-based dependency (no `url`/`hash`) — the package lives
in-tree.

### Step 6 — Update root `build.zig` to consume the package

Add the `databases` package via `b.dependency()`, then add its
module to the imports of:

1. `mod` (the main `nalarcore` module — used by `exe`, `desktop_exe`,
   `cli_exe`, all `install:*` cross-compile artifacts).
2. `mod_tests_module` (used by `mod_tests` for `zig build test`).

Replace the manual `mod.linkSystemLibrary("sqlite3", ...)` /
`mod.addIncludePath(...)` etc. lines (currently at main `build.zig`
lines 767-771) with the dependency-based flow:

```zig
const databases_dep = b.dependency("databases", .{
    .target = target,
    .optimize = optimize,
});
const databases_mod = databases_dep.module("databases");

const mod = b.addModule("nalarcore", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .optimize = optimize,
});
mod.addImport("nalarcore", mod);
mod.addImport("databases", databases_mod);
```

And for the test module:

```zig
const mod_tests_module = b.createModule(.{
    .root_source_file = b.path("src/root.zig"),
    .target = test_target,
    .optimize = optimize,
});
mod_tests_module.addImport("nalarcore", mod_tests_module);
mod_tests_module.addImport("databases", databases_mod);
// REMOVE the previous switch-on-test_target linking block for
// sqlite3/openssl/pq (lines ~790-820 in main build.zig) — the
// databases module now carries those deps.
```

### Step 7 — Strip the now-redundant per-Compile sqlite3 wiring

After Step 6, every Compile that imports `mod` already inherits
sqlite3/openssl/pq via the `databases` module. The per-Compile
`linkPlatformDeps` function in main `build.zig` (lines 42-151) no
longer needs the Linux sqlite3 branch — but it must STILL add:

- `libc` + `link_libc` (every Compile needs libc on every platform).
- `ssl` / `crypto` / `pq` (NOT in the databases module — these are
  only needed by the main app's libpq/openssl use, not by SQLite).
- The macOS / Windows / cross-platform amalgamation blocks
  (still needed for those targets).

The Linux block becomes:

```zig
.linux => {
    exe.root_module.linkSystemLibrary("ssl", .{});
    exe.root_module.linkSystemLibrary("crypto", .{});
    exe.root_module.linkSystemLibrary("pq", .{});
    exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
    // sqlite3 deps come from the `databases` module's build.zig
    // — propagated via mod.addImport("databases", ...).
},
```

This eliminates the `-L vendor/sqlite3/linux-x86_64` warning
because we no longer add that path in main build.zig at all.

The macOS and Windows branches keep their vendored-archive logic
because the `databases` module is compiled once per target — its
build.zig picks up the right deps for that target. Cross-compile
from Linux to Windows still uses `vendor/sqlite3/libc-windows-amd64/`
because that's the `databases` module's Windows branch in its own
build.zig (when compiled with `-target x86_64-windows-gnu`).

### Step 8 — Make `build_all_step` (the default `zig build` step) host-aware

Replace the current unconditional `build_all_step.dependOn(&install_linux.step)`
(line 1093) with a `switch (builtin.host.result.os.tag)`:

```zig
build_all_step.dependOn(switch (builtin.host.result.os.tag) {
    .linux => &install_linux.step,
    .macos => if (builtin.host.result.cpu.arch == .aarch64)
        &install_macos_arm.step
    else
        &install_macos.step,
    .windows => &install_windows.step,
    else => &install_linux.step, // safest default for exotic hosts
});
```

`desktop_install` and `cli_install` already use the native `target`,
so they remain unconditional.

### Step 9 — Update `build_banner` to show the host-specific binary name

The shell banner currently hardcodes "nalarcore-linux-x86_64" /
"nalar-desktop" / "nalarcli". Replace with a computed value:

```zig
const host_binary_name = switch (builtin.host.result.os.tag) {
    .linux => "nalarcore-linux-x86_64",
    .macos => if (builtin.host.result.cpu.arch == .aarch64)
        "nalarcore-macos-aarch64"
    else
        "nalarcore-macos-x86_64",
    .windows => "nalarcore-windows-x86_64.exe",
    else => "nalarcore-unknown",
};
```

…then splice that into the banner shell script.

### Step 10 — Update code that imports the old relative paths

Only 3 files need import-path updates:

| File | Before | After |
|---|---|---|
| `src/root.zig:416` | `pub const sqlite = @import("modules/databases/sqlite/Sqlite.zig");` | `pub const sqlite = @import("databases").sqlite;` |
| `src/root.zig:514` | `_ = @import("modules/databases/test_runner.zig");` | **remove** (test runner now lives in the package; the main test step pulls it via the dependency) |
| `src/modules/cronjob/Cronjob.zig:3` | `const sqlite = @import("../databases/sqlite/Sqlite.zig");` | `const sqlite = @import("databases").sqlite;` |

Cronjob.zig will need `databases` in its module's import list
(propagated automatically from the main module).

### Step 11 — Verify no other references to the old paths remain

`rg "modules/databases" src/` should return only comments and the
3 updated imports above.

---

## 4. Verification

### TDD

The databases package's existing tests (`sqlite_test.zig`,
`sqlite_test_rows_capture_error.zig`, `postgres_test.zig`,
`test_helpers_test.zig`) cover the package's own API. After the
move:

1. `cd src/modules/databases && zig build test --summary all`
   should still pass (tests now run via the package's own
   `b.step("test", ...)`).
2. `zig build test --summary all` (from repo root) should still pass
   the same number of tests (2378 pass, 6 skip, 12 fail, 1 crash
   baseline from PR #181 documented in AGENTS.md).

### Functional checks

```bash
cd /home/ginwa/ginwaaitoolbox

# 1. Clean rebuild — catches stale-cache errors.
rm -rf .zig-cache zig-out
timeout 360 zig build 2>&1 | tee /tmp/zig-build.log

# 2. The error / warning should be gone:
grep -c "warning: unable to open library directory" /tmp/zig-build.log
# Expected: 0

# 3. The host-specific binary should be in zig-out/bin/:
ls -la zig-out/bin/

# 4. The binary should still RUN:
./zig-out/bin/nalarcore-linux-x86_64 --help 2>&1 | head -n 5
# Expected: usage message + warning: scheduler: resetStuckRunning failed: DatabaseNotFound

# 5. Cross-compile smoke (catches compile errors that lazy analysis
#    hides — per AGENTS.md cross-platform section):
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# Expected: clean exit
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# Expected: clean exit

# 6. Platform detection works (the install_linux step should be skipped on macOS):
#    On macOS host, `zig build --list-steps` should show only macos_exe
#    in build_all_step's deps, not install_linux.
```

### Behavioural matrix

| Host OS | `zig build` produces |
|---|---|
| Linux x86_64 | `nalarcore-linux-x86_64`, `nalar-desktop`, `nalarcli` |
| macOS arm64 | `nalarcore-macos-aarch64`, `nalar-desktop`, `nalarcli` |
| macOS x86_64 | `nalarcore-macos-x86_64`, `nalar-desktop`, `nalarcli` |
| Windows x86_64 | `nalarcore-windows-x86_64.exe`, `nalar-desktop.exe`, `nalarcli.exe` |

Cross-compile artifacts (`install:linux` / `install:macos` /
`install:windows` / `install:macos-arm`) still work via explicit
`zig build install:<target>`.

---

## 5. Pitfalls

1. **`b.dependency()` requires `name` + `path` in `build.zig.zon`** —
   omitting `name` (or using the wrong key in `dependencies`) makes
   `b.dependency("databases", ...)` resolve to nothing and the build
   fails with `error: dependency 'databases' not found`.

2. **The package's own `build.zig` must declare `optimize`** — the
   dependency consumer passes `optimize` but the package's module
   needs `.optimize = optimize` in `b.addModule(...)`. Forgetting it
   triggers `error: no optimize mode set`.

3. **`link_libc = true` is per-module, not inherited via imports** —
   the main app's `mod` still needs its own `link_libc = true`
   because the dependency doesn't propagate that flag.

4. **`build.zig.zon::paths` is read by `zig fetch` and `zig build
   --fetch`** — moving files INTO `src/` works with the existing
   `paths = .{..., "src"}`, but adding files OUTSIDE `src/` requires
   editing `paths` (otherwise they're excluded from the package hash).

5. **The amalgamation path mismatch** — main `build.zig` currently
   references `vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400/`
   but the only thing actually present is `vendor/sqlite3/sqlite3.c`.
   The new `databases` package's Windows/else branch uses the
   top-level path. If you see "unable to find sqlite3.h" errors in
   cross-compile, the path is wrong.

6. **`test_runner.zig` was imported by main `src/root.zig` for the
   `zig build test` step to discover package tests** — after the
   move, it lives inside the databases package. The main test step
   no longer needs to import it (it'd be a circular re-export).
   Tests are still discoverable: the main test step runs `mod_tests`
   which transitively imports the `databases` module, whose
   `addTest` step runs `test_runner.zig`.

7. **The `b.installArtifact(exe)` line from `zig init` boilerplate
   would force a useless `zig-out/bin/databases` binary** — DON'T
   re-add it. The package is a library, not an application.

8. **`b.default_step = build_all_step;` in the package's build.zig
   would make `cd src/modules/databases && zig build` build the
   wrong thing** — DON'T set a default step. Let it be empty (just
   `test` + `install` from `b.installArtifact`).

9. **The pre-existing baseline from PR #181** — 12 test failures +
   1 crash + 18 leaks — are documented in AGENTS.md and UNRELATED
   to this refactor. Don't try to fix them as part of this plan.

10. **`builtin.host` (not `builtin.target`)** — the host is what
    `zig build` runs on; `target` is what each Compile targets.
    For platform detection in the default step, we want `host`.

---

## 6. Files affected

**New / moved**:

- `src/modules/databases/build.zig` (rewrite from boilerplate)
- `src/modules/databases/build.zig.zon` (no change unless paths need edit)
- `src/modules/databases/src/root.zig` (rewrite from placeholder)
- `src/modules/databases/src/database.zig` (moved from top level)
- `src/modules/databases/src/sqlite/` (moved — 3 files)
- `src/modules/databases/src/postgres/` (moved — 4 files)
- `src/modules/databases/src/test_runner.zig` (moved)

**Modified**:

- Root `build.zig.zon` — add `databases` to `dependencies`.
- Root `build.zig` — consume dependency, strip manual sqlite3
  linking, add platform detection to `build_all_step`,
  parameterize `build_banner`.
- `src/root.zig` — update 2 imports.
- `src/modules/cronjob/Cronjob.zig` — update 1 import.

**Net deletion**:

- Top-level `src/modules/databases/{database.zig,sqlite/,postgres/,test_runner.zig}`
  (moved into `src/`).

---

## 7. Out of scope

- The 12 pre-existing test failures + 1 crash + 18 leaks documented
  in AGENTS.md (from PR #181 baseline).
- Vendor/ directory management (`scripts/fetch-vendor-sqlite3.sh` /
  `scripts/build-vendor-mingw.sh`) — out of scope; the package's
  build.zig references the top-level `vendor/sqlite3/sqlite3.c`
  which `fetch-vendor-sqlite3.sh` already populates.
- The `nalarcli` binary's reference to the same `databases` deps —
  it's a HTTP-only CLI that doesn't touch sqlite3 directly, so no
  import is needed there.
- Renaming the package directory `databases/` → `database/`
  (the screenshot showed singular; the filesystem is plural; we
  keep plural for back-compat with the existing git history).