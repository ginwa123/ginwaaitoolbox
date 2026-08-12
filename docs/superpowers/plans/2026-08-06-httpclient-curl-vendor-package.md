# Plan: Self-contained `custom_http_client` Zig package + vendored curl

**Task**: "make curl as vendor, and move deps to modules httpclient, mirror like database".

**Owner**: TBD.

**Worktree**: `worktree/httpclient-curl-vendor` (created from `main` @ HEAD).

**Mirrors**: `docs/superpowers/plans/2026-08-06-database-self-contained-package.md` (PR #211).

---

## 1. Context (symptoms + root cause)

The current `custom_http_client` setup has three problems that the
`databases` package refactor (PR #211) already solved for SQLite:

1. **System libcurl required.** `build.zig` calls
   `linkSystemLibrary("curl", .{})` everywhere — every developer
   machine and every CI host must have a matching `libcurl` installed
   at a predictable path (`/usr/include` on Linux,
   `/opt/homebrew/opt/curl` on macOS, `C:/vcpkg/...` on Windows). The
   `-Dcurl-prefix` and `-Dcurl-vcpkg-root` build options are
   stand-ins for missing hermetic builds.

2. **Curl include path plumbing lives in 9 call sites.** The
   `linkCurlIncludePath` helper is called from `exe`, `cli_exe`,
   `cli_tests`, `mod_tests_module`, `linux_exe`, `windows_exe`,
   `macos_exe`, `macos_arm_exe`, `linux_system_exe`, and `dev_exe` —
   each with its own switch on `target.result.os.tag`. Adding a new
   cross-target requires touching all 9 sites. Bumping the Homebrew
   prefix or vcpkg root requires updating all 9.

3. **No mirror of the `databases` package pattern.** The
   `databases` package (PR #211) is a self-contained Zig package
   consumed via `b.dependency("databases", .{...})` with one
   target-aware switch inside its OWN `build.zig`. Curl should be the
   same — one place, hermetic, no system libcurl required.

The vendor infra already exists from PR #210:
- `scripts/build-vendor-curl.sh` (cross-compiles curl 8.10.1 from
  source for Linux x86_64, macOS arm64, macOS x86_64 → writes
  prebuilt `libcurl.a` + headers to `vendor/curl/<target>/`).
- `scripts/bootstrap-vendor.sh` already runs it (Step 4/4).
- `vendor/` is gitignored — `.gitignore` documents the bootstrap.

This plan completes the refactor by:

- **Populating `vendor/curl/`** so the hermetic build works.
- **Rewriting `src/modules/custom_http_client/build.zig`** to use the
  vendored prebuilt archive via `addObjectFile` + `addIncludePath`,
  with target-aware resolution mirroring the `databases` package's
  approach.
- **Removing curl wiring from parent `build.zig`** — the
  `linkCurlIncludePath` helper, the `linkSystemLibrary("curl", ...)`
  calls, and the `-Dcurl-prefix` / `-Dcurl-vcpkg-root` options all
  disappear.
- **Adding `custom_http_client` as a path dependency** in parent
  `build.zig.zon`, mirroring the `.databases = .{ .path = ... }` entry.

---

## 2. Target architecture

```
vendor/curl/                                    ← vendored prebuilt
├── linux-x86_64/lib/libcurl.a                  ← built by scripts/build-vendor-curl.sh
├── linux-x86_64/include/curl/curl.h
├── macos-arm64/lib/libcurl.a
├── macos-arm64/include/curl/curl.h
├── macos-x86_64/lib/libcurl.a
├── macos-x86_64/include/curl/curl.h
└── windows-amd64/lib/libcurl.a                 ← out of scope (script doesn't build yet;
                                                  needs MinGW; documented below)
└── windows-amd64/include/curl/curl.h

src/modules/custom_http_client/                 ← self-contained Zig package
├── build.zig                                   ← links vendored libcurl.a per target
├── build.zig.zon                               ← name=custom_http_client, paths=src
└── src/
    ├── root.zig                                ← public API re-exports (already exists)
    ├── main.zig                                ← (zig init placeholder CLI)
    ├── client.zig                              ← (unchanged)
    ├── request.zig                             ← (unchanged)
    ├── response.zig                            ← (unchanged)
    ├── options.zig                             ← (unchanged)
    ├── methods.zig                             ← (unchanged)
    ├── stream.zig                              ← (unchanged)
    ├── curl.zig                                ← @cImport("curl/curl.h") — needs vendored
    │                                              include path on every host
    └── *_test.zig                              ← (unchanged)

build.zig:                                      ← parent build (simplified)
  const custom_http_client_dep = b.dependency("custom_http_client", .{
      .target = target,
      .optimize = optimize,
      .vendor_dir = ...,
  });
  const custom_http_client_mod = custom_http_client_dep.module("custom_http_client");
  mod.addImport("custom_http_client", custom_http_client_mod);
  // REMOVE: -Dcurl-prefix / -Dcurl-vcpkg-root options
  // REMOVE: linkCurlIncludePath() helper function (lines 64-85)
  // REMOVE: linkSystemLibrary("curl", ...) calls (9 sites)
  // REMOVE: addIncludePath(b.fmt("{s}/opt/curl/include", ...)) (3 sites)
```

**Build flow** (after refactor):

- `zig build` on a Linux host with `vendor/curl/linux-x86_64/` populated
  → builds all binaries using the vendored `libcurl.a` statically
  linked. No system libcurl needed.
- `zig build install:linux:system` → same as today.
- `zig build install:macos` → needs `vendor/curl/macos-x86_64/` built
  (run `bash scripts/build-vendor-curl.sh` once).
- `zig build install:windows` → needs `vendor/curl/windows-amd64/`
  built (out of scope for this PR — documented in §5).

---

## 3. Step-by-step

### Step 1 — Populate `vendor/curl/` with prebuilt archives

Run the existing bootstrap script to cross-compile curl 8.10.1 for
Linux native + macOS arm64 + macOS x86_64:

```bash
bash scripts/build-vendor-curl.sh
```

**Expected output**:
- `vendor/curl/linux-x86_64/lib/libcurl.a` + `include/curl/*.h`
- `vendor/curl/macos-arm64/lib/libcurl.a` + `include/curl/*.h`
- `vendor/curl/macos-x86_64/lib/libcurl.a` + `include/curl/*.h`

**Verification**:
```bash
ls -la vendor/curl/
ls -la vendor/curl/linux-x86_64/lib/
ls -la vendor/curl/linux-x86_64/include/curl/ | head -n 20
file vendor/curl/linux-x86_64/lib/libcurl.a
nm vendor/curl/linux-x86_64/lib/libcurl.a 2>&1 | grep -c 'T curl_easy_init'
```

The `nm` count > 0 confirms the archive exports the symbols
`src/modules/custom_http_client/src/curl.zig` references.

**Failure recovery**:
- If `scripts/build-vendor-curl.sh` fails on a single .c file (the
  script already handles per-file failures with a `WARN:` log), the
  archive is still built — verify `curl_easy_init` is exported; if not,
  the affected platform's archive is incomplete and `install:<plat>`
  for that platform will fail at link time.
- If `zig cc` is missing for the macOS cross-compile branch, install
  zig 0.16+ — already required by AGENTS.md.

**Out of scope**: Windows `vendor/curl/windows-amd64/` is not built
by the script today (would need MinGW setup). Documented in §5.

### Step 2 — Verify the current build still passes (baseline lock)

Before touching any `build.zig`, run the baseline tests to lock in the
expected pass/fail counts. The numbers below are the documented
pre-existing baseline (PR #181 + others; AGENTS.md changelog baseline):

```bash
zig build test --summary all 2>&1 | tail -n 5
```

**Expected baseline**: 2189 pass, 6 skip, 12 fail, 1 crash, 18 leaks.
The 12 fail + 1 crash + 18 leaks are PRE-EXISTING (PR #181 baseline
documented in AGENTS.md) and MUST NOT change from this PR. Run from
the worktree to capture the local baseline before changes:

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/httpclient-curl-vendor
zig build test --summary all 2>&1 | tail -n 5
```

Record the exact numbers. Any deviation after this PR lands = a
regression that must be investigated before merge.

### Step 3 — Restructure `custom_http_client/` to match `databases/` convention

The existing layout (`src/modules/custom_http_client/`) already
matches the `databases/` package layout — `src/` subdir holds all the
Zig code, `build.zig` is at the package root, `build.zig.zon` declares
`paths = .{ ..., "src" }`. **No file moves needed.** Skip this step.

(Mentioned for completeness — the corresponding Step 1 in the
databases plan moved files from `src/modules/databases/{sqlite,postgres}/`
to `src/modules/databases/src/{sqlite,postgres}/`. The curl side was
already organized correctly.)

### Step 4 — Rewrite `src/modules/custom_http_client/build.zig`

Replace the entire file with a self-contained package `build.zig` that
mirrors `src/modules/databases/build.zig`. Key differences from
databases:

- `databases` uses `addCSourceFile(vendor/sqlite3/sqlite3.c)` (compile
  the amalgamation per consumer). Curl uses `addObjectFile(...)` with
  a prebuilt `.a` archive because curl's source has ~80 .c files with
  per-platform compile flags — building the amalgamation per
  consumer would be slow and re-introduce the cross-compile breakage
  the vendor script solved.
- `databases` has a flat `vendor/sqlite3/` for sqlite3.c. Curl has
  per-target subdirs (`vendor/curl/<target>/lib/libcurl.a`).

Sketch (full impl in the commit):

```zig
//! custom_http_client package — self-contained Zig package that
//! exposes the libcurl-backed HTTP client used by nalarcore.
//!
//! Mirrors `src/modules/databases/build.zig`'s pattern: vendored curl
//! is a per-target prebuilt archive under vendor/curl/<target>/lib/
//! libcurl.a + a portable C header under vendor/curl/<target>/include/.
//! Consumers (`b.dependency("custom_http_client", .{...})`) get the
//! right include path + library path + libc linkage based on the
//! TARGET they pass in — without the consumer needing to wire
//! per-platform paths itself.
//!
//! Why per-TARGET (not per-Compile from the consumer): the consumer
//! build.zig's curl include-path plumbing no longer needs to know
//! about Homebrew keg-only paths or vcpkg sysroots. The
//! custom_http_client module carries those for its own target, and
//! Zig's module-graph dep propagation handles the rest.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Path to the vendored curl directory, relative to this
    // package's build.zig. Default assumes the package lives at
    // `<project>/src/modules/custom_http_client/` and the vendor
    // dir is at `<project>/vendor/curl/`. Override with
    // `-Dvendor-dir=...` if you move either side.
    //
    // `b.path()` resolves relative to the package's build.zig
    // directory, so `../../../vendor/curl` walks up 3 levels to
    // reach the project root (matching the databases package's
    // `-Dvendor-dir` convention).
    const vendor_dir = b.option(
        []const u8,
        "vendor-dir",
        "Path to vendor/curl/ (relative to this package, default '../../../vendor/curl')",
    ) orelse "../../../vendor/curl";

    const mod = b.addModule("custom_http_client", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Universal: libc is required by every libcurl binding + cimport.
    mod.linkSystemLibrary("c", .{});
    mod.link_libc = true;

    // Resolve the per-target subdirectory name. The bootstrap script
    // (scripts/build-vendor-curl.sh) writes:
    //   vendor/curl/linux-x86_64/{lib,include}/
    //   vendor/curl/macos-arm64/{lib,include}/
    //   vendor/curl/macos-x86_64/{lib,include}/
    //   vendor/curl/windows-amd64/{lib,include}/  ← not built yet
    //
    // The Zig target triple (arch-os-abi) doesn't directly match these
    // directory names (e.g. aarch64-macos-none != macos-arm64), so we
    // map explicitly. Unsupported targets panic at config time with a
    // clear message — better than a cryptic link error.
    const target_subdir = switch (target.result.os.tag) {
        .linux => b.fmt("linux-{s}", .{switch (target.result.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            else => @panic("vendored curl: unsupported Linux arch"),
        }}),
        .macos => switch (target.result.cpu.arch) {
            .aarch64 => "macos-arm64",
            .x86_64 => "macos-x86_64",
            else => @panic("vendored curl: unsupported macOS arch"),
        },
        .windows => "windows-amd64",  // script doesn't build yet — see §5
        else => @panic("vendored curl: unsupported OS"),
    };
    const target_dir = b.fmt("{s}/{s}", .{ vendor_dir, target_subdir });

    // Header path — needed by `@cImport(@cInclude("curl/curl.h"))`
    // inside src/curl.zig. The header is portable C, so the same
    // vendored copy works for every host (Zig's cimport uses the
    // HOST C compiler, not the cross-target compiler).
    mod.addIncludePath(b.path(b.fmt("{s}/include", .{target_dir})));

    // Link the prebuilt vendored archive directly into every consumer.
    // addObjectFile embeds the .a symbols in the consumer's link line
    // (no separate -L/-l needed — Zig's linker resolves the archive's
    // undefined symbols at consumer link time).
    //
    // For Linux native builds, this REPLACES the system libcurl.so —
    // the vendored archive is statically linked. For cross-targets
    // (Linux→macOS, Linux→Windows), the target-appropriate archive
    // is used. No more `linkSystemLibrary("curl", ...)` leak.
    const libcurl_a = b.path(b.fmt("{s}/lib/libcurl.a", .{target_dir}));
    mod.addObjectFile(libcurl_a);

    // === Tests for the package itself ===
    // `b.addTest({ .root_module = mod })` walks every `_test.zig`
    // reachable from src/root.zig via the `test { _ = @import(...) }`
    // block. The mod already carries link_libc + vendored libcurl,
    // so test executables inherit those deps automatically.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run custom_http_client package tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(b.getInstallStep());
}
```

**Key design points**:
- No more `-Dcurl-prefix` / `-Dcurl-vcpkg-root` options — the
  vendored `vendor/curl/<target>/` layout is self-describing.
- The `addObjectFile()` call REPLACES the previous
  `linkSystemLibrary("curl", .{})` calls in the parent `build.zig`.
  The vendored archive's symbols are linked into every consumer that
  imports this module.
- The `addIncludePath()` call REPLACES the previous platform-specific
  include path plumbing in the parent (`/usr/include` on Linux,
  `$(brew --prefix curl)/opt/curl/include` on macOS, etc.) — the
  vendored headers are portable C, so they work on every host.
- The `target_subdir` mapper handles the directory name vs. Zig
  triple mismatch. Add new platforms here as the bootstrap script
  supports them.

### Step 5 — Update `src/modules/custom_http_client/build.zig.zon`

The current `build.zig.zon` declares `.name = .custom_http_client`
and `.paths = .{ ..., "src", "README.md", "NALAR.md", "CLAUDE.md" }`.
No changes needed — the `paths` already cover what the package needs.
Skip this step.

### Step 6 — Add `custom_http_client` to parent `build.zig.zon`

In the root `build.zig.zon`, add a new entry to `.dependencies`:

```zon
.dependencies = .{
    .databases = .{
        .path = "src/modules/databases",
    },
    // Self-contained libcurl-backed HTTP client package. The package
    // lives in-tree at src/modules/custom_http_client/ and exposes a
    // single `custom_http_client` module; consumers
    // `@import("custom_http_client")` to use it.
    .custom_http_client = .{
        .path = "src/modules/custom_http_client",
    },
},
```

Mirrors the `.databases = .{ .path = ... }` entry exactly. Path-based
dependency (no `url`/`hash`) — the package lives in-tree.

### Step 7 — Update parent `build.zig` to consume the package

Replace the inline `custom_http_client_mod` + `-Dcurl-prefix` +
`-Dcurl-vcpkg-root` + `linkCurlIncludePath` blocks with the
dependency-based flow. Concretely:

1. **Remove the curl option declarations** at lines 120-129 of the
   current `build.zig`:

   ```zig
   // DELETE:
   const curl_prefix = b.option(...);
   const curl_vcpkg_root = b.option(...);
   ```

2. **Remove the `linkCurlIncludePath` helper function** at lines
   64-85.

3. **Replace the inline `custom_http_client_mod`** (lines 181-203) with:

   ```zig
   const custom_http_client_dep = b.dependency("custom_http_client", .{
       .target = target,
       .optimize = optimize,
   });
   const custom_http_client_mod = custom_http_client_dep.module("custom_http_client");
   mod.addImport("custom_http_client", custom_http_client_mod);
   ```

4. **Strip `linkSystemLibrary("curl", .{})` and
   `linkCurlIncludePath(...)` calls** from:
   - `exe` (line 260 + line 268)
   - `dev_exe` (line 858 + line 861)
   - `linux_exe` (line 776 + line 778)
   - `windows_exe` (line 793 + line 795)
   - `macos_exe` (line 807 + line 809)
   - `macos_arm_exe` (line 819 + line 821)
   - `linux_system_exe` (line 829 + line 831)
   - `cli_exe` (line 623) — replaced by `custom_http_client_mod`
     carrying the include path; the inline
     `cli_exe.root_module.linkSystemLibrary("c", .{});
     cli_exe.root_module.link_libc = true;` can stay (libc is
     universal).
   - `cli_tests` (line 645)
   - `mod_tests_module` (lines 727-741) — the curl include path block
     goes away; the `linkSystemLibrary("c", .{})` + `link_libc = true`
     stay.

5. **Verify** that every Compile step that imported
   `custom_http_client` now gets `libcurl` from the module's transitive
   deps (via the `addObjectFile` inside the package's `build.zig`).
   Zig's module graph propagates the `.a` archive to every consumer.

### Step 8 — Add `fetch-vendor-curl` build step

The current `scripts/build-vendor-curl.sh` must be run before
`install:macos` or `install:windows` will succeed (cross-target
vendored curl). Add a `zig build fetch-vendor-curl` step that runs
the script, mirroring the now-deprecated `fetch-vendor-sqlite3` step
in pattern:

```zig
const fetch_vendor_curl_step = b.step(
    "fetch-vendor-curl",
    "Build vendor/curl/<target>/ from source (cross-compiles libcurl for Linux + macOS; idempotent)",
);
const fetch_vendor_curl_cmd = b.addSystemCommand(&.{
    "bash", "scripts/build-vendor-curl.sh",
});
fetch_vendor_curl_cmd.setCwd(b.path(""));
fetch_vendor_curl_step.dependOn(&fetch_vendor_curl_cmd.step);

// Make install:macos / install:macos-arm / install:windows depend on
// the fetch step so a fresh checkout Just Works.
install_macos_step.dependOn(&fetch_vendor_curl_step.step);
install_macos_arm_step.dependOn(&fetch_vendor_curl_step.step);
install_windows_step.dependOn(&fetch_vendor_curl_step.step);
```

(Windows will still fail because the bootstrap script doesn't yet
build `vendor/curl/windows-amd64/`. Documented in §5. The step
dependency makes the failure mode obvious — the user sees the
"fetch-vendor-curl: Windows archive not built" error at the fetch
step, not at link time.)

### Step 9 — Update `AGENTS.md` changelog

Append a section to `AGENTS.md`'s "Recent changes" section documenting
the refactor. Pattern follows the 2026-08-06 database package
changelog entry — title, symptom (none — proactive refactor),
root cause (none — mirror of an established pattern), what landed
(files + lines), verification matrix.

Key items to document:
- `scripts/build-vendor-curl.sh` already existed (PR #210). The
  refactor just makes the project depend on its output.
- 9 call sites in `build.zig` simplified to 1.
- `-Dcurl-prefix` / `-Dcurl-vcpkg-root` options removed.
- The `addObjectFile` pattern for prebuilt archives differs from
  the `addCSourceFile` pattern for amalgamation source — both are
  valid "vendored library" approaches; the choice depends on the
  source layout.

### Step 10 — Verify

Run the full pre-commit checklist from AGENTS.md (the project's
mandatory verification workflow):

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/httpclient-curl-vendor

# 1. Static unit tests (Linux)
timeout 180 zig build test --summary all
# Expected: 2189 pass, 6 skip, 12 fail, 1 crash, 18 leaks (same as
# baseline from Step 2; the 12 fail + 1 crash + 18 leaks are PRE-EXISTING).

# 2. Build the Linux binary
timeout 180 zig build install:linux:system
# Expected: zig-out/bin/nalar produced (cp to /usr/local/bin/nalar
# fails on perms — pre-existing).

# 3. Fresh rebuild
rm -rf zig-out/bin
timeout 360 zig build
# Expected: zig-out/bin/nalar + nalar-desktop + nalarcli produced.

# 4. Cross-compile smoke (catches lazy semantic analysis bugs)
timeout 60 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
timeout 60 zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# Expected: clean (no errors). Windows will fail at the link step if
# vendored curl archive is missing — but the COMPILE step (which is
# what -fno-emit-bin tests) should succeed.

# 5. CLI smoke
./zig-out/bin/nalarcli --help
# Expected: prints usage.

# 6. Vendor bootstrap (idempotent re-run)
bash scripts/bootstrap-vendor.sh
# Expected: prints "vendor/<X> already populated" for every cached
# artifact.
```

**Wire check** (the critical sanity check that the vendored libcurl
actually linked correctly):

```bash
ldd ./zig-out/bin/nalar 2>&1 | grep -i curl
# Expected: NOTHING (libcurl is statically linked via vendored archive)
# Pre-fix would show: libcurl.so.4 => /usr/lib/x86_64-linux-gnu/libcurl.so.4
```

If `ldd` shows the system libcurl, the `addObjectFile` call inside
`src/modules/custom_http_client/build.zig` didn't replace the
`linkSystemLibrary("curl", .{})` properly — recheck Step 7.

### Step 11 — Smoke test with `nalar` running

Spin up the binary and verify it actually makes an HTTP request
through the vendored libcurl:

```bash
# Use port 8080 (NOT 8081 — that's the user's always-running dev server)
./zig-out/bin/nalar --port 8080 --static-dir /tmp 2>&1 &
PID=$!
sleep 2
curl -s http://127.0.0.1:8080/api/health 2>&1
# Expected: {"status":"ok"} (or whatever the health endpoint returns)
kill $PID
```

If the health endpoint returns 200, the vendored libcurl + the agent's
HTTP path are working end-to-end.

---

## 4. Verification summary

| Check | Expected | Failure mode |
|---|---|---|
| `vendor/curl/linux-x86_64/lib/libcurl.a` exists after Step 1 | yes | Script failed silently; re-run with `set -x` |
| `nm libcurl.a \| grep -c 'T curl_easy_init'` | > 0 | Archive is incomplete |
| `zig build test --summary all` after refactor | 2189 pass / 6 skip / 12 fail / 1 crash (baseline) | `addObjectFile` broke link — check Step 7 |
| `zig build` produces all 3 binaries | `nalar` + `nalar-desktop` + `nalarcli` | Static-contract test issue — check `addIncludePath` propagation |
| `ldd zig-out/bin/nalar \| grep curl` | (empty) | System libcurl still linked — `linkSystemLibrary("curl", ...)` not removed |
| `zig build-obj -target x86_64-windows-gnu` | clean (no errors) | Lazy semantic analysis bug — check `addObjectFile` path resolution |
| `zig build-obj -target aarch64-macos` | clean (no errors) | Same |
| `bash scripts/build-vendor-curl.sh` (re-run) | "Done. Run 'zig build' to verify" | Idempotency broken — script touched vendored files |
| `./zig-out/bin/nalar --port 8080` + `curl /api/health` | `{"status":"ok"}` | Vendored curl can't resolve DNS / make sockets — check OS-level includes in the vendored archive |

---

## 5. Out of scope (deferred)

These items are explicitly NOT part of this PR. Surface them as
follow-up kanban tasks if the user wants them addressed.

1. **`vendor/curl/windows-amd64/` build** — `scripts/build-vendor-curl.sh`
   currently builds only Linux + macOS arm64 + macOS x86_64. Windows
   needs MinGW setup (analogous to `scripts/build-vendor-sqlite3-windows.sh`).
   Add `build_target_windows()` to the script using
   `x86_64-w64-mingw32-gcc` + the curl sources. Until then,
   `install:windows` will fail with "libcurl.a not found" — same
   pre-existing failure mode as today (currently vcpkg is required).

2. **HTTPS support** — vendored curl is HTTP-only (no TLS backend;
   see lines 93-110 of `scripts/build-vendor-curl.sh` setting all
   `CURL_USE_*` macros to 0). The agent's LLM API calls will fall
   back to `http://` URLs for v1. To support HTTPS, also vendor
   OpenSSL or BearSSL — significant additional build complexity.

3. **Dynamic linking decision** — this PR statically links the
   vendored libcurl. If a future requirement needs dynamic linking
   (smaller binary, libcurl updates from OS package manager), the
   `addObjectFile` becomes `linkSystemLibrary("curl", .{})` with an
   `addLibraryPath(target_dir + "/lib")` — but then we need to deal
   with the runtime `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` /
   `PATH` story on each platform.

4. **Curl WebSocket support** — `ENABLE_WEBSOCKETS=0` in the bootstrap
   script. The `custom-http-websocket` worktree branch (already in
   the .worktrees list) re-enables websockets at the cimport level.
   That worktree's `build.zig` changes will need to be re-merged
   onto this PR's refactored `build.zig` separately.

5. **Auto-fetching in CI** — the `fetch-vendor-curl` step runs the
   build script on demand, but doesn't cache the artifacts in CI. For
   GitHub Actions, add a CI step that runs
   `bash scripts/build-vendor-curl.sh` and caches `vendor/curl/`
   between jobs (similar to how `vendor/sqlite3/` is currently
   handled, but that pattern was gitignored).

---

## 6. Pitfalls (record for future agents)

1. **`addObjectFile` vs `linkSystemLibrary`** — these are NOT
   equivalent. `linkSystemLibrary("curl", ...)` adds `-lcurl` to the
   link line, which the linker resolves via `-L<dir>` paths. With
   the vendored `libcurl.a` at a non-standard path, the linker
   CANNOT find it via `-lcurl` (no `-L` flag pointing at our
   vendor dir). `addObjectFile` embeds the archive directly,
   bypassing the search-path resolution. **Use `addObjectFile` for
   vendored prebuilt archives.**

2. **`addObjectFile` archives are statically linked.** The resulting
   binary has no `libcurl.so` dependency (good for hermetic builds;
   bad if you want libcurl updates). `ldd` will show no `libcurl.so.4`
   line — that's the success indicator.

3. **The vendored libcurl archive is per-target.** Cross-compile from
   Linux to Windows needs `vendor/curl/windows-amd64/lib/libcurl.a`,
   which the bootstrap script doesn't yet build. Cross-compile from
   Linux to macOS works (zig cc builds it). Linux native builds use
   the `linux-x86_64` archive (matches host).

4. **`@cImport("curl/curl.h")` uses the HOST C compiler.** The
   include path inside `src/modules/custom_http_client/build.zig` is
   added on the module — Zig's cimport machinery picks the include
   path that's valid on the HOST, not the cross-target. For Linux
   host cross-compiling to macOS, the cimport resolves
   `vendor/curl/macos-arm64/include/curl/curl.h` (because that's the
   include path the module declares). The headers are portable C,
   so this works regardless of the host.

5. **`-Dvendor-dir` default walks `../../../`.** The package lives at
   `src/modules/custom_http_client/`. `b.path()` resolves relative to
   the package's own `build.zig`. So `../../../vendor/curl` walks:
   `src/modules/custom_http_client/` → `src/modules/` → `src/` →
   `<project_root>`. Matches the `databases` package's
   `../../../vendor/sqlite3` default.

6. **`linkCurlIncludePath` removal is critical.** Leaving the helper
   in `build.zig` (even if unused) doesn't hurt the build, but it's
   dead code that future maintainers will be tempted to call. Delete
   the function entirely.

7. **`-Dcurl-prefix` / `-Dcurl-vcpkg-root` options are gone.** Any
   external CI / scripts that pass these flags will silently be
   ignored (Zig's `b.option()` with `orelse` defaults). No error.
   If CI is set up to pass these, update it to pass `-Dvendor-dir=...`
   instead (or nothing — the default works for the standard layout).

8. **The bootstrap script needs to be re-runnable.** `scripts/build-vendor-curl.sh`
   already has an idempotency check (`if [[ ! -d "${SRC_DIR}" ]]`)
   for the source download, but the actual build step writes
   unconditionally. If a developer re-runs it, the archives are
   rebuilt from scratch (no incremental compile). For this PR, that's
   acceptable — the script takes ~30-60s. Future enhancement: add a
   skip-if-archive-exists guard around `build_target()`.

9. **`vendor/curl/` is gitignored.** A fresh checkout will NOT have
   the vendored archives. Either run `bash scripts/bootstrap-vendor.sh`
   (which calls `build-vendor-curl.sh`) or `bash scripts/build-vendor-curl.sh`
   before the first `zig build`. AGENTS.md and `.gitignore` already
   document this.

10. **`scripts/build-vendor-curl.sh` cross-compiles macOS archives
    from Linux.** It uses `zig cc -target aarch64-macos` /
    `x86_64-macos`. If zig is not on PATH, the macOS branches fail
    (Linux native build succeeds because it uses `gcc`). Same as
    before — this PR doesn't change the script.

---

## 7. Migration checklist

For the agent executing this plan:

- [ ] Step 1: `bash scripts/build-vendor-curl.sh` — vendor/curl/
      populated, archives contain `curl_easy_init` symbols.
- [ ] Step 2: capture baseline `zig build test --summary all`
      numbers from the worktree.
- [ ] Step 3: SKIP — file layout already matches databases/ pattern.
- [ ] Step 4: rewrite `src/modules/custom_http_client/build.zig`
      per the sketch in §3.
- [ ] Step 5: SKIP — `build.zig.zon` already correct.
- [ ] Step 6: add `.custom_http_client = .{ .path = ... }` to root
      `build.zig.zon` dependencies.
- [ ] Step 7: edit root `build.zig`:
      - Remove `-Dcurl-prefix` + `-Dcurl-vcpkg-root` options
      - Remove `linkCurlIncludePath()` helper
      - Replace inline `custom_http_client_mod` with `b.dependency()`
      - Strip `linkSystemLibrary("curl", ...)` and
        `linkCurlIncludePath(...)` calls at all 9 call sites
- [ ] Step 8: add `fetch-vendor-curl` build step + make
      `install:macos*` and `install:windows` depend on it.
- [ ] Step 9: update AGENTS.md changelog.
- [ ] Step 10: run full verification matrix from §3 Step 10.
- [ ] Step 11: smoke test with `nalar` running on port 8080.
- [ ] Commit with message following the project's
      `feat(build): ...` convention (PR #210 used
      `feat(build): vendor sqlite3 + curl for hermetic cross-platform
      builds`; this PR uses something like
      `refactor(build): self-contained custom_http_client Zig package
      + vendored libcurl (#212)`).
- [ ] Open a PR against `main` referencing this plan.