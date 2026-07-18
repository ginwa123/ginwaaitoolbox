# Zig 0.16 — cross-platform patterns and 9 blocker classes

This file consolidates the 9 distinct Zig 0.16 cross-platform blocker classes from `zig-cross-platform-blockers-and-fixes.md`. For nalar-specific cross-platform work (CI smoke test, Mac CI quirks, setsockopt), see `nalar-backend-architecture.md`. For Zig 0.16 stdlib changes, see `zig-0.16-stdlib-changes.md`.

## The `std.c.*` pattern (fix for all blockages)

In Zig 0.16, `std.os.linux.*` functions are **Linux-only** — they call Linux kernel syscall numbers directly. On macOS the syscall numbers differ, so a `std.os.linux.mkdirat` call on macOS invokes the wrong slot and fails.

**The rule:** replace every `std.os.linux.X` call with its `std.c.X` libc wrapper. The libc layer compiles the right platform-specific code per target.

### Specific syscall patterns (Linux + macOS + BSD)

```zig
// mkdirat — was std.os.linux.mkdirat(linux.AT.FDCWD, &path, mode)
const rc = std.c.mkdirat(std.c.AT.FDCWD, &path, 0o755);
if (rc != 0) {
    const err = std.c.errno(rc);   // checks rc == -1, returns E enum
    if (err != .EXIST) return error.MkdirFailed;
}

// fork — was std.os.linux.fork() returning usize
const pid = std.c.fork();           // returns c_int (pid_t)
if (pid < 0) return error.ForkFailed;
if (pid > 0) std.process.exit(0);
if (std.c.setsid() < 0) return error.SessionFailed;

// open — was std.os.linux.open(path, flags, mode)
const fd: std.c.fd_t = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
if (fd < 0) return error.OpenFailed;
_ = std.c.dup2(fd, 1);
_ = std.c.close(fd);

// waitpid — was std.os.linux.waitpid(pid, &u32, flags)
_ = std.c.waitpid(pid, null, 0);

// kill — was std.posix.kill (Windows pid_t issue)
std.c.kill(pid, std.c.SIG.TERM);
```

**Why Linux tests still pass after the fix:** `std.c.fork` and `std.os.linux.fork` both work on Linux because libc on Linux calls the same `clone` syscall.

**Where this pattern is already in use:** `src/helpers/process_status.zig`, `src/helpers/process.zig`, etc. Default to `std.c.*` — never `std.os.linux.*`.

## The 9 blocker classes

### 1. `std.posix.kill(pid, 0)` — `@compileError` on Windows

`std.posix.kill` exists in 0.16, but on Windows `std.c.pid_t` is `*anyopaque`. `@intCast(i32 → *anyopaque)` fails at compile time.

**Fix:** comptime switch on `builtin.os.tag` between POSIX `std.c.kill` and Win32 `OpenProcess` / `TerminateProcess`.

### 2. `std.posix.getcwd(&buf)` — REMOVED in 0.16

**Fix:** Use libc `std.c.getcwd(buf.ptr, buf.len)` (cross-platform via UCRT on Windows).

```zig
fn getcwd(buf: []u8) ?[]u8 {
    const rc = std.c.getcwd(buf.ptr, buf.len);
    if (rc == null) return null;
    return std.mem.sliceTo(rc.?, 0);
}
```

### 3. `std.posix.getenv(name)` — REMOVED in 0.16

**Fix:** `std.c.getenv(name: [*:0]const u8) ?[*:0]u8` — wrap with `std.mem.sliceTo(ptr, 0)`.

### 4. `std.c.pid_t` is `*anyopaque` on Windows → `i32` comparison fails

**Fix:** Change `helpers.process.getCurrentProcessId()` to return `i32` with a comptime switch:

```zig
pub fn getCurrentProcessId() i32 {
    return switch (builtin.os.tag) {
        .linux, .macos => @intCast(std.c.getpid()),
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        else => @compileError(...),
    };
}
```

`@hasDecl(std.c, "getpid")` returns true on Windows but the return type is `*anyopaque` — switch on `builtin.os.tag` instead.

### 5. (covered by #4) `@hasDecl` is misleading on Windows

### 6. `std.posix.setsockopt` — `@compileError("use std.Io instead")` on Windows

**Status: OUT OF SCOPE** in nalar — requires `std.Io.Net` migration of `Agent.zig apply_tcp_keepalive`.

### 7. `std.fs.accessAbsolute(path, .{})` — REMOVED in 0.16

**Fix:** Use libc `access(path, F_OK)` (cross-platform via UCRT). `std.c.F_OK` is only defined for Linux/emscripten — on Windows + macOS the literal `0` works.

### 8. `std.fs.cwd().openFile(path, .{})` — REMOVED in 0.16

**Fix:** Use libc `fopen`/`fread`/`fclose`. `fseek`/`ftell` are NOT in Zig 0.16's `std.c` — declare them as `extern "c" fn` (see `zig-language-quirks.md` for the rules).

### 9. `std.time.timestamp()` — REMOVED in 0.16

**Fix:**
- If the function has `io: std.Io`: `std.Io.Clock.now(.real, io).toSeconds()`
- If no `io` parameter: use libc-based helper (POSIX `gettimeofday`, Win32 `GetSystemTimeAsFileTime`)

## The `extern "c" fn` declaration rules (for cross-platform libc wrapping)

See `zig-language-quirks.md` for the full rules. Quick reference:

1. **MUST be at module scope** (not inside function bodies in Zig 0.16).
2. **Use the REAL libc name** — if you write `extern "c" fn c_fseek(...)`, the linker looks for `c_fseek`, NOT `fseek`. Use `extern "c" fn fseek(...)`.
3. **`std.c.FILE` vs your own `FILE` opaque** — `std.c.fopen` returns `?*std.c.FILE`, so declarations must use `*std.c.FILE`.
4. **`std.c.c_long` and `std.c.c_void` don't exist** in this Zig 0.16 stdlib version. Use `i64`/`i32` directly, or `*anyopaque` for void pointers.
5. **`extern "c" fn` bodies are not type-checked** at the call site.

## The Clong alias pattern

C `long` is platform-sized: 64-bit on Linux/macOS 64-bit, 32-bit on Windows 64-bit (LP64 vs LLP64):

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

## FILETIME → Unix timestamp conversion (Windows)

Win32 `GetSystemTimeAsFileTime` returns a `FILETIME` (100-ns ticks since 1601-01-01 UTC):

```zig
const ticks: u64 = (@as(u64, ft.dw_high_date_time) << 32) |
    @as(u64, ft.dw_low_date_time);
const seconds_since_1601: u64 = ticks / 10_000_000;
const unix_offset: u64 = 11_644_473_600;   // seconds from 1601 to 1970
return @intCast(seconds_since_1601 - unix_offset);
```

## Cross-compile verification technique

When the `zig build install:windows` / `install:macos` steps are blocked by missing system libraries (sqlite3.h, libssl, etc.) at link time, detect compile errors via **standalone `zig build-obj`**:

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

`-fno-emit-bin` skips the link step, so missing Windows SDK libraries don't matter — only the Zig type checker runs. Catches all `@compileError`, type mismatch, and missing-symbol errors. Fast (< 5s per file).

**Three CLI quirks for `zig build-obj`:**
- `-target x86_64-windows-gnu` (use SPACE, not `=`)
- `-Mname=path` declares a module — must be referenced via `@import("name")` from the root
- `-lc` is required when the module uses libc APIs

## Related / cross-references

- `zig-0.16-stdlib-changes.md` — Zig 0.16 stdlib API changes
- `zig-language-quirks.md` — `extern "c"` declaration rules, language gotchas
- `nalar-backend-architecture.md` — nalar-specific cross-platform work (CI smoke test, Mac CI quirks)