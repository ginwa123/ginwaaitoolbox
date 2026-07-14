# Zig 0.16 — Cross-platform compile blockers and fixes in nalar (Windows + macOS)

Consolidated reference for cross-platform Zig 0.16 work in nalar. Covers
**9 distinct blocker classes** discovered across 3 days of work (2026-06-25,
2026-07-02, 2026-07-05), the **`std.c.*` libc pattern** that fixes them, the
**`extern "c" fn` declaration rules**, and the **cross-compile verification
technique**. Replaces the previous three day-separated memories
(`zig-cross-platform-windows-blockers.md`,
`zig-cross-platform-day2-fixes.md`,
`zig-cross-platform-stdc-syscalls.md`).

## The 9 blocker classes

Each class lists the Zig error, the root cause, the fix, and the files
affected.

### 1. `std.posix.kill(pid, 0)` — `@compileError` on Windows

```
src/modules/cronjob/ProcessChecker.zig:24:35: error: expected integer
                                          or vector, found '*anyopaque'
const result = std.posix.kill(@intCast(pid), @enumFromInt(0));
```

`std.posix.kill` exists in Zig 0.16
(`/usr/local/lib/zig/std/posix.zig:378`, signature
`pub fn kill(pid: pid_t, sig: SIG) KillError!void`), but on Windows
`std.c.pid_t` is `*anyopaque` (no real pid concept). `@intCast(i32 → *anyopaque)` fails at compile time.

**Fix:** Use a comptime switch on `builtin.os.tag` to dispatch between
`std.c.kill` (POSIX, returns `c_int`) and Win32
`OpenProcess` / `TerminateProcess` (declared as `extern "c"`).
See `src/helpers/process_status.zig` for the working implementation.

**Files affected:**
- `src/modules/cronjob/ProcessChecker.zig:24`
- `src/ai_workflow/tui/background_process.zig:130, 138, 140`

### 2. `std.posix.getcwd(&buf)` — REMOVED in Zig 0.16

```
src/modules/agent/tools/skills.zig:191:26: error: root source file
                                          struct 'posix' has no member named 'getcwd'
const cwd = std.posix.getcwd(&cwd_buf) catch {
```

Zig 0.16 deleted `std.posix.getcwd` entirely. The Io replacement
(`std.Io.Dir.cwd().realPath(io, &buf)`) requires `io: std.Io`, but many
tool/handler call sites only have `allocator` in scope.

**Fix:** Use libc `std.c.getcwd(buf.ptr, buf.len)` which exists on
Linux, macOS, AND Windows (via MinGW/UCRT) without requiring Io.
Wrap as `helpers.getcwd(buf)` (a new helper in `src/helpers/mod.zig`).

**Files affected:**
- `src/modules/agent/tools/skills.zig:191`
- `src/modules/agent/tools/add_agent.zig:62`
- `src/modules/agent/tools/remove_agent.zig:55`

### 3. `std.posix.getenv(name)` — REMOVED in Zig 0.16

```
error: root source file struct 'posix' has no member named 'getenv'
```

Same removal as `getcwd`. `std.c.getenv(name: [*:0]const u8) ?[*:0]u8`
exists in libc and is cross-platform.

**Fix:** Switch to `std.c.getenv`. Return is `?[*:0]u8` — wrap with
`std.mem.sliceTo(ptr, 0)` to get `[]const u8`.

**Files affected:**
- `src/ai_workflow/tui/http_handlers/session_create_test.zig:9, 55, 77` (3 sites)

### 4. `std.c.pid_t` is `*anyopaque` on Windows → `i32` comparison fails

```
src/modules/agent/tools/bash_selfkill.zig:72:32: error: incompatible types:
                                        'i32' and '*anyopaque'
if (target_pid == self_pid) {
                    ~~~~~~~~~~~^~~~~~~~~~~
```

`parsePid(s)` returns `?i32` but `get_self_pid()` returns `std.c.pid_t` which
is `*anyopaque` on Windows.

**Fix:** Change `helpers.process.getCurrentProcessId()` (and the callers
that wrap it) to return `i32` directly with a comptime switch:

```zig
pub fn getCurrentProcessId() i32 {
    return switch (builtin.os.tag) {
        .linux, .macos => @intCast(std.c.getpid()),
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        else => @compileError(...),
    };
}
```

**Files affected:**
- `src/helpers/process.zig` (signature change)
- `src/helpers/random.zig` (signature change)
- `src/modules/agent/tools/bash_selfkill.zig` (`get_self_pid`, `detect_self_kill`)

### 5. `@hasDecl(std.c, "getpid")` returns true on Windows — but `std.c.getpid` returns `*anyopaque`

The existing `helpers/process.zig` had a check
`if (@hasDecl(std.c, "getpid")) return std.c.getpid()` which **fails**
on Windows because the check passes but the return type mismatch triggers
the same `@intCast(i32 → *anyopaque)` error. **Fix: switch on
`builtin.os.tag` (NOT `@hasDecl`)** — see #4.

### 6. `std.posix.setsockopt` — `@compileError("use std.Io instead")` on Windows

```
src/modules/agent/Agent.zig:810:29: error: use std.Io instead
@compileError("use std.Io instead");
```

From `/usr/local/lib/zig/std/posix.zig:1074-1075`:

```zig
pub fn setsockopt(fd: socket_t, level: i32, optname: u32, opt: []const u8) SetSockOptError!void {
    if (native_os == .windows) {
        @compileError("use std.Io instead");
    } ...
```

**Status: OUT OF SCOPE.** Requires refactoring `Agent.zig apply_tcp_keepalive`
to use `std.Io.Net`. Tracked as follow-up.

**Files affected (NOT FIXED):**
- `src/modules/agent/Agent.zig:802-833` (`apply_tcp_keepalive`)

### 7. `std.fs.accessAbsolute(path, .{})` — REMOVED in Zig 0.16

```
src/modules/agent/tools/lsp.zig:42:32: error: root source file
                                     struct 'fs' has no member named 'accessAbsolute'
    std.fs.accessAbsolute(lsp_name, .{}) catch return LspError.BinaryNotFound;
```

Zig 0.16 removed `std.fs.accessAbsolute`. The Io replacement
(`std.Io.Dir.accessAbsolute(io, path, .{})`) requires `Io`, which many
tool call sites don't have (the agent dispatch path doesn't thread
`io: std.Io` through).

**Fix:** Use libc `access(path, F_OK)` (cross-platform). Note:
`std.c.F_OK` is only defined for Linux/emscripten — on Windows + macOS
the literal `0` works (test for existence).

**Files affected:**
- `src/modules/agent/tools/lsp.zig:42, 165`
- `src/modules/agent/tools/lsp_hover.zig:204`
- `src/modules/agent/tools/lsp_document_symbol.zig:303`

### 8. `std.fs.cwd().openFile(path, .{})` — REMOVED in Zig 0.16

```
src/modules/agent/tools/lsp_hover.zig:207:31: error: root source file
                                              struct 'fs' has no member named 'cwd'
    const file = try std.fs.cwd().openFile(input.file_path, .{});
```

Zig 0.16 removed the `std.fs.cwd()` shortcut entirely. Replacement is
`std.Io.Dir.cwd().openFile(io, path, .{})` which requires `io: std.Io`.

**Fix:** Use libc `fopen`/`fread`/`fclose` (cross-platform). `fseek`/
`ftell` are NOT in Zig 0.16's `std.c` — declare them as `extern "c" fn`.
See the `extern "c" fn` rules and the `readFile` helper below.

**Files affected:**
- `src/modules/agent/tools/lsp.zig:168`
- `src/modules/agent/tools/lsp_hover.zig:207`
- `src/modules/agent/tools/lsp_document_symbol.zig:306`
- `src/modules/agent/tools/lsp_references.zig:173`

### 9. `std.time.timestamp()` — REMOVED in Zig 0.16

```
src/modules/cronjob/Cronjob.zig:237:38: error: use of undeclared identifier 'timestamp'
    const cutoff_time = std.time.timestamp() - older_than_seconds;
```

Zig 0.16 removed `std.time.timestamp()`. Replacement is
`std.Io.Clock.now(.real, io).toSeconds()` which requires `io: std.Io`.

**Fix:**
- If the function has `io: std.Io`: use `std.Io.Clock.now(.real, io).toSeconds()`
- If no `io` parameter: use a libc-based helper (POSIX `gettimeofday`,
  Win32 `GetSystemTimeAsFileTime`) — see `unixTimestamp` helper below.

**Files affected:**
- `src/modules/cronjob/Cronjob.zig:237` (had `io`, used Io runtime)
- `src/ai_workflow/tui/llm_history.zig:918` (no `io`, used helper)

## The `std.c.*` pattern (fix for all blockages above)

In Zig 0.16, `std.os.linux.*` functions are **Linux-only** — they call
Linux kernel syscall numbers directly. On macOS the syscall numbers
differ (`mkdirat` is 264 on Linux, 242 on macOS), so a
`std.os.linux.mkdirat` call on macOS invokes the wrong slot and fails
(ENOENT / EBADF / "terminated with signal SYS" depending on which
syscall).

**The rule: replace every `std.os.linux.X` call with its `std.c.X`
libc wrapper.** The libc layer compiles the right platform-specific
code per target (`std.c.AT = switch (native_os) { .linux => linux.AT,
.macos => struct { pub const FDCWD = -2; ... }, ... }` — verified at
`/usr/local/lib/zig/std/c.zig:8264`).

### Specific syscall patterns (Linux + macOS + BSD)

```zig
// mkdirat — was std.os.linux.mkdirat(linux.AT.FDCWD, &path, mode)
const rc = std.c.mkdirat(std.c.AT.FDCWD, &path, 0o755);
if (rc != 0) {
    const err = std.c.errno(rc);   // checks `rc == -1`, returns E enum
    if (err != .EXIST) return error.MkdirFailed;
}

// fork — was std.os.linux.fork() returning usize
const pid = std.c.fork();           // returns c_int (pid_t)
if (pid < 0) return error.ForkFailed;
if (pid > 0) std.process.exit(0);
if (std.c.setsid() < 0) return error.SessionFailed;

// open — was std.os.linux.open(path, .{.ACCMODE=..., .CREAT=...}, mode)
const fd: std.c.fd_t = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
if (fd < 0) return error.OpenFailed;
_ = std.c.dup2(fd, 1);
_ = std.c.close(fd);

// waitpid — was std.os.linux.waitpid(pid, &u32, flags)
_ = std.c.waitpid(pid, null, 0);   // status pointer is optional

// kill — was std.posix.kill (Windows pid_t issue)
std.c.kill(pid, std.c.SIG.TERM);   // returns c_int
const kill_err = std.c.errno(...);
```

**Why Linux tests still pass after the fix:** `std.c.fork` and
`std.os.linux.fork` both work on Linux because libc on Linux calls the
same `clone` syscall. So switching to `std.c.*` preserves Linux
behaviour (953/956 tests pass, same baseline as before the fix).
Verified at `/usr/local/lib/zig/std/c.zig` — `pub extern "c" fn fork(...)
pid_t` is a libc import that delegates to the kernel.

**Where this pattern was already in use in nalar:**
`src/helpers/process_status.zig` (commit `1475bb7` and earlier) uses the
same `std.c.kill` + `std.c.errno` pattern for cross-platform process
probing. The new daemon.zig + state_file.zig code follows the same
convention. **Whenever a new file needs a POSIX syscall, default to
`std.c.*` — never `std.os.linux.*`.**

### 4 specific Mac CI failures from PR #78 (daemon.zig fixes)

`src/daemon.zig` and `src/state_file.zig` called these unconditionally
before the fix:

| Failure | Test | Cause |
|---------|------|-------|
| 1 | `state_file_test.test.writeStateFile does mkdir-p into a fresh nested dir` | `ENOENT` at `dirCreateFilePosix` |
| 2 | `state_file_test.test.freeState is a no-op on slices` | Same ENOENT from the same `mkdirat` |
| 3 | `daemon_test.test.mkdirP creates all parent dirs of a fresh nested path` | `std.c.access(&post_z, 0) != 0` after `mkdirP` |
| 4 | `daemon_test.test.POSIX daemonize detaches the grandchild from the original` | Terminated with signal SYS (fork syscall slot was wrong) |

The PR that fixed these is `dfde8d4e` on branch `worktree/fix-ci-mac-daemon`.

## The `extern "c" fn` declaration rules

These were the trickiest part of the day-2 fixes. Verified during
`readFile`/`unixTimestamp` helper implementation.

1. **`extern "c" fn` MUST be at module scope.** Cannot be declared
   inside function bodies in Zig 0.16. The `const c_fseek = ...` style
   inside a function fails with "expected a struct, enum or union,
   found 'a string literal'".

2. **Use the REAL libc name.** If you write
   `extern "c" fn c_fseek(...)` and call it, the linker looks for a
   symbol named `c_fseek`, NOT `fseek`. The test binary fails to link
   with "undefined symbol: c_fseek" even though libc IS linked. Fix:
   name the extern the same as the libc symbol: `extern "c" fn fseek(...)`.

3. **`std.c.FILE` vs your own `FILE` opaque** — these are distinct
   types in Zig 0.16. The `std.c.fopen` returns `?*std.c.FILE`, so your
   `extern "c" fn` declarations must use `*std.c.FILE` (not a local
   `const FILE = opaque {}`).

4. **`std.c.c_long` and `std.c.c_void` don't exist** in this Zig 0.16
   stdlib version. Use `i64`/`i32` directly based on platform, or
   `*anyopaque` for void pointers.

5. **`extern "c" fn` bodies are not type-checked** at the call site
   (only the signature). So you can declare `gettimeofday` and it
   will resolve at link time without you implementing anything.

## The Clong alias pattern

C `long` is platform-sized: 64-bit on Linux/macOS 64-bit, 32-bit on
Windows 64-bit (LP64 vs LLP64). Need a comptime alias:

```zig
const Clong = if (@bitSizeOf(usize) == 64 and builtin.os.tag != .windows)
    i64
else
    i32;
```

Then declare libc functions using `Clong`:

```zig
extern "c" fn fseek(stream: *std.c.FILE, offset: Clong, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) Clong;
extern "c" fn gettimeofday(tv: ?*PosixTimeval, tz: ?*anyopaque) c_int;
```

## The FILETIME → Unix timestamp conversion

Win32 `GetSystemTimeAsFileTime` returns a `FILETIME` (100-ns ticks
since 1601-01-01 UTC). To convert to Unix epoch seconds:

```zig
const ticks: u64 = (@as(u64, ft.dw_high_date_time) << 32) |
    @as(u64, ft.dw_low_date_time);
const seconds_since_1601: u64 = ticks / 10_000_000;
const unix_offset: u64 = 11_644_473_600;
return @intCast(seconds_since_1601 - unix_offset);
```

## Helpers added to `src/helpers/mod.zig`

### `getcwd(buf: []u8) ?[]u8`
Uses libc `std.c.getcwd(buf.ptr, buf.len)`. Strips the NUL terminator.
Cross-platform (Linux, macOS, Windows-via-UCRT).

### `fileExists(path: []const u8) bool`
Uses libc `access(path, 0)` where 0 = F_OK.

### `readFile(allocator: Allocator, path: []const u8) ![]u8`
Uses libc `fopen` + manually-declared `fseek`/`ftell` + `fread` +
`fclose`. Reads entire file into a heap buffer.

### `unixTimestamp() i64`
Comptime-switches between POSIX `gettimeofday` and Win32
`GetSystemTimeAsFileTime`. No `io: std.Io` required.

## Cross-compile verification technique

When the `zig build install:windows` / `install:macos` steps are
blocked by missing system libraries (sqlite3.h, libssl, etc.) at link
time, you can still detect compile errors via **standalone
`zig build-obj`**:

```bash
# Minimal test root that imports the module under test
cat > /tmp/test_mod.zig <<EOF
const nalarcore = @import("nalarcore");
const mod = nalarcore.helpers.process_status;
pub fn main() !void {
    const self = mod.getCurrentProcessIdInt();
    std.debug.print("{d}\n", .{self});
}
EOF

# Type-check only (no link, no system libs)
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
    --dep nalarcore \
    -Mroot=/tmp/test_mod.zig \
    -Mnalarcore=src/root.zig
```

`-fno-emit-bin` skips the link step entirely, so missing Windows SDK
libraries don't matter — only the Zig type checker runs. This catches
all `@compileError`, type mismatch, and missing-symbol errors. The
check is fast (< 5s per file) and runs without needing the macOS
self-hosted runner (which is useful when that runner is offline).

**Three command-line quirks for `zig build-obj`:**
- `-target x86_64-windows-gnu` (use SPACE, not `=`): `zig build-obj -target x86_64-windows-gnu`
- The `-Mname=path` declares a module — must be referenced via
  `@import("name")` from the root, or you get `module 'name' declared but not used`
- `-lc` is required when the module uses libc APIs (otherwise
  `dependency on libc must be explicitly specified in the build command`)

### How to verify a "fixed" cross-platform file

For each previously-failing file, build-obj it against three targets
and confirm zero errors on all three:

```bash
for target in "" "-target x86_64-windows-gnu" "-target aarch64-macos"; do
    echo "=== TARGET=$target ==="
    timeout 30 zig build-obj -fno-emit-bin $target -lc \
        --dep nalarcore \
        -Mroot=/tmp/test_root.zig \
        -M<module>=<path>.zig \
        -Mnalarcore=src/root.zig 2>&1 | head -n 5
done
```

This catches all `std.os.linux.*` references at compile time — the
namespace `linux` doesn't exist when targeting macOS, so a leftover
`std.os.linux.X` produces `error: root source file struct 'os' has no
member named 'linux'`.

## Verification results

**Linux x86_64 — IMPROVED across the work:**

| | Pass | Fail | Total |
|--|------|------|-------|
| Before day 2 (after day 1) | 755 | 5 | 760 |
| After day 2 | **760** | **5** | **765** |
| After day 3 (Mac fixes) | 953 | 3 | 956 |

5 new tests picked up on day 2, ~190 on day 3. No regressions.

**macOS cross-compile** (via `zig build-obj -fno-emit-bin -target aarch64-macos`):
All modified files type-check cleanly after the fixes.

## What's still NOT fixed

- `Agent.zig apply_tcp_keepalive` (uses `std.posix.setsockopt`) —
  `@compileError("use std.Io instead")` on Windows. Requires `std.Io.Net`
  migration (out of scope; tracked as follow-up).
- `zig build install:windows` / `install:macos` / `install:macos-arm`
  blocked at link time by missing `addLibraryPath` / `addIncludePath`
  for cross-target sysroots in `build.zig` (pre-existing, see memory
  `nalar-build-cross-compile-blocked.md`).
- `sse_manager.zig` uses `std.os.linux.MSG.NOSIGNAL` / `std.os.linux.sendto`
  inside `if (is_linux)` block — this compiles cross-platform (the
  comptime branch excludes the Linux-only references on Windows/macOS),
  so no fix is needed.
- `lsp.zig` has dangling `_ = @import("lsp_*_test.zig")` for test files
  that don't exist (intentionally removed in commit `4c77a494`).
  Pre-existing bug.

## When this bites

- Any new file in `src/` that needs `mkdirat`, `open`, `dup2`, `close`,
  `fork`, `setsid`, `waitpid`, `pipe`, `kill`, `getpid`, `getppid`,
  `access`, `unlink`, `rename`, `linkat`, `getcwd`, `readFile`, or
  `timestamp`.
- Porting any Linux-specific Zig code to nalar's Mac CI cell.
- Reviewing a PR that touches daemon/state_file/lifecycle code — the
  reviewer should grep for `std.os.linux.` and require every match to
  be replaced with `std.c.`.
- Any new tool/handler that needs `Io` but doesn't have it in scope —
  use the helpers added to `src/helpers/mod.zig` instead.

## Related memories

- `nalar-build-cross-compile-blocked.md` — `zig build install:macos`
  fails at link time because of missing macOS sysroot lib paths in
  build.zig. The `build-obj -fno-emit-bin` workaround in this memory
  bypasses that link step.
- `zig-0.16-syscall-helpers.md` — older memory about the Io.Threaded
  non-blocking socket problem (related to class #6).
- `zig-0.16-spawn-cwd-is-not-nullable.md` — different spawn API gotcha.
- `zig-0.16-crypto-time-stdlib-removals.md` — confirms std.time.timestamp
  removal with the gettimeofday/GetSystemTimeAsFileTime fix (matches
  class #9).
- `zig-0.16-file-append-must-use-writePositionalAll.md` — different
  Zig 0.16 file IO gotcha (writeStreamingAll doesn't seek).
- `nalar-macos-setsockopt-reuseaddr-bug.md` — pre-existing
  cross-platform bug found by the CI smoke test (different topic).
