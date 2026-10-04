# Plan: Probe system deps before using vendor scripts

**Task**: `zig build custom http server, custom client, database` — user
says: "before use vendor script to build, check the current system deps first,
if system have the lib no need use vendor".

**Owner**: TBD.

**Worktree**: `worktree/system-deps-first` (created from `main` @ `1977bb28`).

---

## 1. Context (symptoms + root cause)

`zig build` on the developer's host (Arch Linux x86_64) currently runs two
pre-build vendor scripts unconditionally:

1. `src/modules/custom_http_client/scripts/build-vendor-curl.sh` — cross-
   compiles libcurl 8.10.1 + OpenSSL 3.4.0 from source for
   `linux-x86_64`, `macos-arm64`, `macos-x86_64`. On a Linux host this
   takes ~30 min (curl/openssl build + config) the first time it runs.
2. `src/modules/databases/scripts/fetch-vendor-sqlite3.sh` — downloads
   the ~10 MB SQLite 3.53.3 amalgamation from `sqlite.org` and
   verifies its SHA3-256.

The host has all the required system libraries installed:

```
$ pkg-config --modversion libcurl libssl libcrypto libpq sqlite3
8.21.0
3.6.3
3.6.3
18.4
3.53.4
```

with headers at `/usr/include/curl/curl.h`, `/usr/include/openssl/ssl.h`,
`/usr/include/libpq-fe.h`, `/usr/include/sqlite3.h` — and SO files at
`/usr/lib/libcurl.so.4`, `/usr/lib/libssl.so.3`, `/usr/lib/libcrypto.so.3`,
`/usr/lib/libpq.so.5`, `/usr/lib/libsqlite3.so.0`.

The current build ALWAYS uses the vendored stack regardless of whether the
system already has the libs. The user wants the build to detect the system
libs first and skip the vendor scripts when they already satisfy the dep.

After this change:
- On a Linux host with `libcurl-dev` + `openssl-dev` + `libpq-dev` +
  `sqlite3` installed (the normal case), `zig build` skips the vendor
  cross-compile entirely (~30 min faster cold build).
- On hosts without the system libs (Windows MinGW, exotic Linux), the
  build falls back to the existing vendored path unchanged.
- Cross-compile (`install:linux`, `install:macos`, `install:windows`)
  still uses the vendored path because the system libs match the HOST
  not the TARGET — the cross-linker needs the target's libs.

---

## 2. Target architecture

```
src/modules/custom_http_client/build.zig
├── probe(host) → { use_system: bool, libcurl_path, ssl_path, crypto_path }
├── if use_system:
│     mod.linkSystemLibrary("curl", .{})  + addIncludePath(system)
│     mod.linkSystemLibrary("ssl", .{})   + addIncludePath(system)
│     mod.linkSystemLibrary("crypto", .{}) + addIncludePath(system)
└── else: existing vendored path (addObjectFile libcurl.a)
```

```
src/modules/databases/build.zig
├── probe(host) → { use_system_sqlite3: bool, use_system_pq: bool, ... }
├── Linux + system sqlite3 present  → linkSystemLibrary("sqlite3") + addIncludePath
├── Linux + system libpq            → linkSystemLibrary("pq") + addIncludePath
├── else (Windows target or system missing) → vendored sqlite3 amalgamation
└── (Windows still links bcrypt)
```

```
build.zig (root)
├── vendor_curl_step is gated on a new "would_use_vendor" probe at build
│   config time. If custom_http_client/build.zig detected system libs, the
│   step is a no-op (still present in --list-steps so existing scripts
│   don't break, but does nothing).
└── vendor_sqlite3_step is gated on the same probe for databases.
```

### 2.1 What "probe" means

A small helper that runs at build config time (NOT at compile time). It
checks host paths NOT target paths — the build runs on the host, so the
host's `/usr/include` is what the cimport phase can see (cimport uses the
HOST C compiler per the existing comments in `build.zig`).

For each lib, the probe checks:

1. The header file exists at a system location (`/usr/include/...` on
   Linux, `/opt/homebrew/include/...` on macOS, system path on Windows).
2. The `.so` (or `.dylib` / `.dll`) is reachable via the system's
   dynamic linker (`ldconfig -p` on Linux, `otool -L` on macOS, etc.).

Either check passing is enough — the linker will say so if both are
present but they disagree. We pick "system" when the header is present
AND the library is on the ldconfig path, otherwise "vendor".

For Linux specifically, the probe is:

```bash
test -f /usr/include/curl/curl.h  && ldconfig -p | grep -q libcurl.so
```

(equivalents for ssl/crypto/pq/sqlite3). The build.zig runs this via
`b.addSystemCommand` and uses the exit code to decide. To avoid the
probe running on every build (slow), we cache the result in a sentinel
file at `.zig-cache/system-deps-probe.ok` and only re-probe when the
sentinel is missing.

### 2.2 Why probe at build config time (not compile time)

The probe needs to RUN something (shell, ldconfig, etc.). `build.zig` runs
at config time — that's where shell commands exist. The PROBE'S result
flows into the `mod` setup, which then affects every consumer's link
line. Doing the probe at compile time would require `mod` to be mutable
per-consumer, which it isn't.

### 2.3 Why a sentinel + re-probe only when missing

`ldconfig -p` on Linux is fast (~5 ms). We don't need to cache. Re-probing
every build is fine. The sentinel is just a way to skip the probe when we
already know the result. If the user uninstalls a lib and re-runs `zig
build`, the probe re-runs and detects the missing lib.

Simpler: just re-probe every build. Cost: ~5 ms × 5 libs = 25 ms per
build. Negligible.

---

## 3. Step-by-step

### Task 1 — Add a probe helper to `src/modules/custom_http_client/build.zig`

**File**: `src/modules/custom_http_client/build.zig`

**What**: Add a private `probeSystemLibs(b: *std.Build) SystemLibs` fn
that returns a struct with `{ use_system: bool, found_curl, found_ssl,
found_crypto }`. The probe runs `sh -c` with a `command -v` + `test -f`
+ `ldconfig -p` chain.

**Acceptance**:
- `zig build` on a Linux host with `libcurl-dev` + `openssl` prints
  `[custom_http_client] using system libcurl + ssl + crypto` to stderr.
- `zig build` on a host missing `libcurl-dev` (e.g. Arch with no
  `curl` package) prints an info message but proceeds to use the
  vendored archive.

**Test**: `zig build --list-steps` (smoke), then `zig build test`
(package's own tests, no network).

**Commit**: `feat(custom_http_client): probe system libs before vendoring`.

---

### Task 2 — Wire the probe into `custom_http_client/build.zig` link line

**File**: `src/modules/custom_http_client/build.zig`

**What**: Replace the unconditional `addObjectFile(libcurl.a)` block with
a `if (probe.use_system) { linkSystemLibrary paths } else { addObjectFile }`
choice. The vendored path remains UNTOUCHED in the `else` branch.

The current code (lines 88-98 of `build.zig`):

```zig
mod.addIncludePath(b.path(b.fmt("{s}/include", .{target_dir})));
const libcurl_a = b.path(b.fmt("{s}/lib/libcurl.a", .{target_dir}));
mod.addObjectFile(libcurl_a);
```

becomes:

```zig
if (probe.use_system) {
    mod.linkSystemLibrary("curl", .{});
    mod.linkSystemLibrary("ssl", .{});
    mod.linkSystemLibrary("crypto", .{});
    // Headers come from the system include path — no addIncludePath
    // needed because Zig's cimport already searches /usr/include.
} else {
    mod.addIncludePath(b.path(b.fmt("{s}/include", .{target_dir})));
    const libcurl_a = b.path(b.fmt("{s}/lib/libcurl.a", .{target_dir}));
    mod.addObjectFile(libcurl_a);
}
```

**Acceptance**: `zig build test` passes; `zig build` produces a working
`zig-out/bin/pabrikcore-linux-x86_64`.

**Test**: `zig build test --summary all` — 2198 pass, 6 skip (existing
baseline).

**Commit**: `feat(custom_http_client): link system libs when available,
fall back to vendored`.

---

### Task 3 — Add a probe helper to `src/modules/databases/build.zig`

**File**: `src/modules/databases/build.zig`

**What**: Same pattern as Task 1, but for `sqlite3` + `ssl` + `crypto`
+ `libpq`. The Linux branch already uses `linkSystemLibrary` for all
four, so the change is simpler: probe just controls whether we ALSO
need the vendored amalgamation (NO — only when system is missing).

**Acceptance**: `zig build` on this Arch host prints `[databases] using
system sqlite3 + libpq` to stderr and does NOT trigger the
`fetch-vendor-sqlite3` step.

**Test**: `zig build test --summary all` — same baseline.

**Commit**: `feat(databases): probe system sqlite3 + libpq before
vendoring amalgamation`.

---

### Task 4 — Wire the probe into `databases/build.zig` Linux branch

**File**: `src/modules/databases/build.zig`

**What**: Current Linux branch (lines 74-89):

```zig
.linux => {
    mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
    mod.linkSystemLibrary("ssl", .{});
    mod.linkSystemLibrary("crypto", .{});
    mod.linkSystemLibrary("pq", .{});
    mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    mod.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
},
```

The issue: `addCSourceFile(sqlite_c, ...)` ALWAYS compiles the
vendored amalgamation, even when `linkSystemLibrary("sqlite3")` is
available. The amalgamation is 9.5 MB C — compilation takes ~3 min on
first build.

Change to:

```zig
.linux => {
    if (probe.use_system_sqlite3) {
        mod.linkSystemLibrary("sqlite3", .{});
    } else {
        mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
    }
    if (probe.use_system_pq) {
        mod.linkSystemLibrary("pq", .{});
        mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    } else {
        // pq missing — let the existing addIncludePath for /usr/include
        // try anyway; if libpq-fe.h isn't there either, the cimport
        // will fail at compile time (which is the correct outcome).
    }
    mod.addIncludePath(.{ .cwd_relative = "/usr/include" }); // for openssl/, libpq-fe.h
    mod.linkSystemLibrary("ssl", .{});
    mod.linkSystemLibrary("crypto", .{});
},
```

**Acceptance**: `zig build test` passes with the same baseline.

**Test**: `zig build test --summary all`.

**Commit**: `feat(databases): link system sqlite3 when available, fall
back to vendored amalgamation`.

---

### Task 5 — Skip the vendor fetch scripts when system libs are present

**File**: `build.zig` (root)

**What**: The two `addSystemCommand` steps
(`fetch-vendor-sqlite3`, `fetch-vendor-curl`) currently run unconditionally
when depended on. Add a guard: if the corresponding probe detects system
libs, the step is a no-op (empty body). The two helpers that need to be
called from the root build.zig are added to the package's `build.zig` as
public APIs.

Each probe becomes a `pub fn` on the package's `build.zig` so the root
build.zig can call `b.dependency("custom_http_client").builder.path("...")`
or — simpler — export the result via a file the root build.zig reads.

**Simpler approach**: Add a `pub fn systemLibsPresent(b: *std.Build) bool`
to each package's `build.zig`. The root build.zig calls it, and only
attaches the fetch step if the function returns false.

**Acceptance**: `zig build` on a Linux host with system libs does NOT
run `build-vendor-curl.sh` or `fetch-vendor-sqlite3.sh`. The vendor
directories stay empty.

**Test**: `rm -rf src/modules/custom_http_client/vendor/curl/linux-x86_64
src/modules/databases/vendor/sqlite3/sqlite3.c && zig build` should
succeed with the vendor dirs still empty afterward.

**Commit**: `feat(build): skip vendor fetch scripts when system libs
satisfy the dep`.

---

### Task 6 — Update plan + agent docs

**Files**:
- `docs/superpowers/plans/2026-08-14-system-deps-first.md` — already
  this file (final touches).
- `AGENTS.md` — add a "Recent changes" entry summarizing the probe +
  skip behavior, so the next agent knows `zig build` is fast on bare
  Arch hosts.

**Commit**: `docs: AGENTS.md breadcrumb for system-deps-first`.

---

## 4. Verification

### Functional checks

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/system-deps-first

# 1. Clean vendor dirs — system libs should still let the build succeed.
rm -rf src/modules/custom_http_client/vendor/curl src/modules/databases/vendor/sqlite3
rm -rf .zig-cache zig-out
timeout 180 zig build 2>&1 | tee /tmp/zig-build-system.log
# Expected: NO "Building OpenSSL" / "Building curl" / "Fetching SQLite" lines.
# Expected: "[custom_http_client] using system ..." + "[databases] using system ..." lines
# Expected: "zig build success" banner at the end.

# 2. The vendor dirs should still be empty afterward (proves we didn't fetch).
ls -la src/modules/custom_http_client/vendor/curl/ 2>&1
ls -la src/modules/databases/vendor/sqlite3/ 2>&1
# Expected: directories empty or missing.

# 3. The binary should still RUN.
./zig-out/bin/pabrikcore-linux-x86_64 --help 2>&1 | head -n 5
# Expected: usage message.

# 4. ldd should show system libcurl, not vendored.
ldd zig-out/bin/pabrikcore-linux-x86_64 | grep -i curl
# Expected: "libcurl.so.4 => /usr/lib/libcurl.so.4" (NOT the vendored one).

# 5. Tests still pass.
timeout 360 zig build test --summary all 2>&1 | tail -n 10
# Expected: 2198 pass, 6 skip, 0 fail (matches existing baseline).

# 6. Fallback path: simulate "no system libs" by temporarily breaking the
#    probe. Simplest: override the probe return via a const in the build.zig.
#    Then verify the vendor paths are used.
```

### Cross-platform checks (smoke)

```bash
# The probe should ALWAYS say "use vendor" for cross-compile targets
# because the target's libs aren't on the host's /usr/lib.
timeout 60 zig build install:linux --summary all 2>&1 | tail -n 10
# Expected: builds but uses vendored amalgamation (THIN archive in
# databases, not libcurl fat archive — install:linux doesn't use the
# custom_http_client).
```

### Regression check

The vendored amalgamation fetch is gated on the same probe — empty vendor
dir + system libs = no fetch. But the build.zig currently has a hardcoded
`addCSourceFile` for the amalgamation on Linux. After this change, the
amalgamation is only compiled when the system libs are missing. The
on-disk amalgamation file can be deleted without breaking the build.

---

## 5. Pitfalls

1. **Libpq header is at `/usr/include/libpq-fe.h` on Arch, not
   `/usr/include/postgresql/libpq-fe.h`** — the existing addIncludePath
   already lists both, and libpq-fe.h being at `/usr/include/` is
   covered by the new `addIncludePath(.{ .cwd_relative = "/usr/include" })`.
   But the existing line `addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" })`
   is still safe to keep (it's a no-op on Arch).

2. **Probe runs at build config time, not compile time** — Zig's `build.zig`
   runs once per `zig build` invocation. A `pub fn` exported from a
   package's build.zig is callable from the root build.zig via
   `b.dependency(...).builder.path(...)` for file paths, but to read a
   computed value, the package must write to a file the root reads (or
   use `std.Build.Step.Run` ordering). Easiest: have the probe return
   a result via a shared sentinel file at `.zig-cache/deps-probe-{name}.ok`.

3. **`linkSystemLibrary("curl", ...)` doesn't pull in libssl/libcrypto
   on Linux** — libcurl's pkg-config declares `Requires: libssl,
   libcrypto`. `linkSystemLibrary` does NOT honour pkg-config Requires.
   So we must explicitly add `linkSystemLibrary("ssl", .{})` and
   `linkSystemLibrary("crypto", .{})` when going system-only.

4. **Cross-compile (Linux→macOS, Linux→Windows) must still use vendor**
   — the probe checks the HOST's system libs, not the TARGET's. Cross-
   compile paths always need the vendored archive because the host
   doesn't have the target's dynamic libs. The `install:linux` /
   `install:macos` / `install:windows` build targets run with the
   native host target's `system_libs_present` probe returning FALSE
   only when the TARGET is different from the host. This is the
   existing behavior we want to preserve.

5. **glibc version mismatch on Linux** — system libcurl is built against
   the host's glibc. The project default target is glibc 2.38 (set in
   the root build.zig). On a host with OLDER glibc, linking against
   system libcurl may fail with "version `GLIBC_2.38' not found". This
   is a pre-existing risk that the vendored archive sidesteps by
   linking against the same glibc the binary compiles for. Document
   this in AGENTS.md so users on older distros know to use `-Dtarget=...`
   to match their host.

6. **The probe must be a `pub fn` exported from the package's build.zig**
   so the root build.zig can call it. Zig's `b.dependency()` returns a
   `*Dependency` whose `.builder` field is the package's `*Build`. We
   can call helper functions on it via:
   ```zig
   const custom_http_client_pkg = b.dependency("custom_http_client", ...);
   if (!custom_http_client_pkg.builder.systemLibsPresent()) {
       // attach the fetch step
   }
   ```
   Wait — `builder` is private (`*std.Build` is opaque). The cleanest
   pattern is to make the probe write a sentinel file at a known path
   and the root build.zig reads it. Or: pass an option `-Duse-system-libs=true`
   to the package and let the user toggle. Or: just probe in the root
   build.zig too (using `b.findProgram` + `b.addSystemCommand`).

   The simplest reliable approach: probe in the root build.zig using the
   same helpers, and read the result via a small `pub fn` exported from
   each package. The cleaner separation: each package EXPORTS a
   `pub fn probeSystemLibs(b: *std.Build) SystemLibs` that the root
   build.zig calls. The package's build.zig also RUNS the probe to
   decide its own link line. The probe runs TWICE at config time
   (~10 ms × 5 libs × 2 = 100 ms — fine).

   Actually, the cleanest: each package's build.zig exposes a public
   fn that returns the probe result by writing to a builder cache file
   and the root reads it. Too much complexity for a config-time probe.

   The simplest: probe in the root build.zig directly, BEFORE creating
   the dependent Compiles. The package's build.zig gets a
   `use_system_libs: bool` option that's set by the root based on the
   probe.

7. **The build.zig's `mod_tests_module` uses the same probe** — the
   test module also imports `databases` and `custom_http_client`. If
   the probe says "use system", the test module inherits the system
   link line. Tests should pass either way (same libcurl.so + sqlite3.so
   symbols).

---

## 6. Files affected

**Modified**:
- `src/modules/custom_http_client/build.zig` — add probe, gate link line
- `src/modules/databases/build.zig` — add probe, gate amalgamation
- `build.zig` (root) — gate fetch-vendor-curl / fetch-vendor-sqlite3 steps
- `AGENTS.md` — add breadcrumb

**New**:
- `docs/superpowers/plans/2026-08-14-system-deps-first.md` — this file

**Net deletion** (optional follow-up):
- `src/modules/custom_http_client/vendor/curl/<target>/` and
  `src/modules/databases/vendor/sqlite3/` — no longer needed on hosts
  with system libs. Keep gitignored; don't touch in this plan.

---

## 7. Out of scope

- macOS Homebrew keg-only libcurl at `/opt/homebrew/opt/curl/` — the
  probe doesn't handle this case. Fall back to vendor. Document as a
  follow-up.
- Windows MSVC `libcurl.lib` — the probe doesn't handle this. Fall back
  to vendor. The package's build.zig Windows branch keeps the existing
  vendored path.
- Cross-compile (`install:linux`, `install:macos`, `install:windows`) —
  always uses vendor. The probe only optimises the native-host build.
- Removing the vendored directories from the repo entirely — keep
  gitignored for the case where a developer is on a minimal host.
- Updating the build.zig.zon — no path changes needed; the package
  layout is unchanged.
- Adding tests to verify the probe behaviour — the existing
  `zig build test` suite covers all consumers (Agent, EventBus, etc.)
  and will fail if the probe wrongly decides "use system" on a host
  that lacks the libs (link errors at compile time).
