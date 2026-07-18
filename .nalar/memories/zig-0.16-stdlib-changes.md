# Zig 0.16 — stdlib API removals and changes

This file consolidates all Zig 0.16 stdlib API changes from the nalar codebase. Each section below documents ONE removal/change with: the old API, why it was removed, the fix, and when it bites.

For Zig 0.16 language-level quirks (not stdlib API), see `zig-language-quirks.md`. For Zig build/test patterns and lazy analysis, see `zig-build-and-test.md`. For cross-platform porting, see `zig-cross-platform.md`.

---

## `std.crypto.random.bytes` and `std.time.timestamp` removed — use libc

**Removed:**
- `std.crypto.random.bytes(&buf)` — namespace is gone; `bytes()` is now an instance method on `std.Random`.
- `std.time.timestamp()` — entire function removed; `std/time.zig` now only has constants like `ns_per_s`.

**Fix:** Use libc syscalls via `std.c.*`:

```zig
const c = std.c;
fn fillRandom(buf: []u8) !void {
    while (true) {
        const rc = c.getrandom(buf.ptr, buf.len, 0);
        if (rc >= 0 and @as(usize, @intCast(rc)) == buf.len) return;
        if (c.errno(rc) == .INTR) continue;
        return error.EntropyUnavailable;
    }
}
fn unixTimestampSeconds() i64 {
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @intCast(tv.sec);
}
```

**Hex encode/decode still works:** `std.fmt.bytesToHex` and `std.fmt.hexToBytes` are unchanged.

**When this bites:** any auth/security code, any code needing Unix timestamps for IDs, any port from older Zig that used module-level helpers.

---

## `std.fs.cwd()` removed — use `std.Io.Dir.cwd()`

**Removed:** `std.fs.cwd()` (entire `std.fs` namespace reorganized).

**Fix:**

```zig
const data = try std.Io.Dir.cwd().readFileAlloc(
    std.testing.io,        // or ctx.io from a handler
    path,                  // []const u8 path
    allocator,
    .limited(1 << 20),     // Io.Limit (enum), not raw usize
);
```

All of `std.fs.File.*` moved to `std.Io.File.*` and take `io: std.Io`. `readFileAlloc` signature is now `(io, path, allocator, limit: Io.Limit)`.

**When this bites:** any test that reads source files, any startup code reading config/prompt/memory files from cwd, any port from older Zig.

---

## `std.posix` no longer exposes common syscall wrappers

`std.posix.socket/bind/listen/accept/connect/recv/send/close` are NOT public. They live in `std.os.linux.*` (or `.darwin.*`, `.windows.*`) and return raw `usize`:
- Success: non-negative value (fd or byte count or 0)
- Failure: value > `std.math.maxInt(i32)` (negation of errno, encoded as `usize`)

**Pattern:**

```zig
const fd_rc = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
if (fd_rc > std.math.maxInt(i32)) return error.SocketFailed;
const fd: i32 = @intCast(fd_rc);
defer _ = std.os.linux.close(fd);
```

**Other removals in this category:**
- `std.Thread.sleep(ns)` → use `std.c.nanosleep(&std.posix.timespec{...}, null)`
- `std.fs.accessAbsolute(path, .{})` → use `std.c.faccessat(AT_FDCWD, path, mode, 0)`
- `std.fs.File.createFileAbsolute` / `writeFileAbsolute` — signature changed

**`Io.Threaded` opens sockets non-blocking internally** — breaks one-shot TCP probes (health checks). The probe gets `EAGAIN` before any data arrives because `connect()` returns after SYN/ACK but before `accept()`. For one-shot probes use raw blocking syscalls with `SO_RCVTIMEO` set via `setsockopt`.

**Multi-threaded `Io.Threaded` does NOT support multiple threads awaiting on the same Io runtime.** If you need a mock server in a test, use raw syscalls in the test thread (`std.os.linux.*`) and `Io.Threaded` in the main thread.

**When this bites:** any new code spawning subprocesses that need TCP/HTTP interaction, one-shot probes, test mock servers, path resolution needing `access(2)`.

---

## `std.process.spawn` `.cwd` field is `process.Child.Cwd` union, NOT nullable

The `.cwd` field requires a `process.Child.Cwd` tagged-union value, NOT a `?[]const u8`:

```zig
pub const Cwd = union(enum) {
    inherit,                    // ← default; same as parent's cwd
    dir: Io.Dir,                // ← fchdir to this Dir handle
    path: []const u8,           // ← chdir to this absolute path
};
```

**Common cases:**

| Intent | Correct `.cwd = ` |
|---|---|
| Use parent's cwd | `.inherit` (or OMIT the line entirely) |
| Chdir to absolute path | `.{ .path = "/abs/path" }` |
| Fchdir to a Dir handle | `.{ .dir = someIoDir }` |
| "I don't know" | OMIT the line — defaults to `.inherit` |

**`null` is never correct.** It produces `error: expected type 'process.Child.Cwd', found '@TypeOf(null)'`.

**Why `zig build test` doesn't catch this:** lazy analysis — private spawn call sites may not be reached by the test target's module graph. Always run `zig build install:linux:system` or `zig build` (with `rm -rf zig-out/bin`) to verify.

**When this bites:** porting from older Zig (≤ 0.15) where `.cwd` was `?[]const u8`.

---

## `child.kill(io)` returns `void`, asserts `child.id == null` after

Zig 0.16: `child.kill(child: *Child, io: Io) void` blocks until child dies, reaps via `childCleanupPosix`, closes pipe FDs, sets `child.id = null`.

**You MUST NOT call `child.wait(io)` after `kill(io)`** — `wait` asserts `child.id != null` and panics.

**Pattern:**

```zig
if (elapsed > timeout_ns) {
    timeout_hit = true;
    child.kill(io);                          // void, blocks until reaped
    child_term = .{ .signal = .KILL };        // record what happened
    break;
    // NO child.wait(io) here — would assert-fail
}
```

**When this bites:** porting code from 0.15 (where `kill` returned `Term`) or adding `wait` after a `kill` call.

---

## Fire-and-forget spawn needs per-child reaper thread (NOT `signal(SIGCHLD, SIG_IGN)`)

`std.process.spawn` without `wait()` leaves the child as a zombie forever UNLESS SIGCHLD is SIG_IGN (process-global). Glibc ≥ 2.34 does NOT default to SIG_IGN, so fire-and-forget accumulates zombies.

**Fix:** per-child detached reaper thread:

```zig
const ReaperArgs = struct { io: std.Io, child: std.process.Child };
fn reapChild(args: ReaperArgs) void {
    var local = args;
    _ = local.child.wait(local.io) catch {};
}

const child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
if (std.Thread.spawn(.{}, reapChild, .{ReaperArgs{ .io = io, .child = child } })) |t| {
    t.detach();
} else |_| {
    child.kill(io);  // fallback: kill+reap+close pipes
}
```

**Why not `signal(SIGCHLD, SIG_IGN)`:** it's process-global; would break every other `child.wait(io)` site (bash, HttpClient, lsp tools) by making them return ECHILD.

**When this bites:** any spawn whose result is deliberately not waited on (notification daemons, cleanup tasks). Tested at ~9 zombies/hour without fix; 0 after fix.

---

## `std.time.sleep` removed — use `std.Io.sleep`

```zig
try std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .real);
```

The `try` is required because `sleep` is `Cancelable!void` — the Io runtime can cancel it.

**When this bites:** any polling loop using `std.time.sleep`. Replace with `std.Io.sleep`.

---

## `std.Thread.Mutex` does NOT exist in 0.16

`std.Thread` exposes only thread spawn/name/handle APIs, no synchronization. Available options:

| Mutex type | Io required? | Blocking? | Use when |
|---|---|---|---|
| `std.Io.Mutex` | yes | yes (futex) | Io-runtime code, long critical sections |
| `std.atomic.Mutex` | no | no (spinlock) | `std.Thread.spawn`'d workers, module-level globals, critical sections < 1µs |

**Spinlock pattern:**

```zig
var mutex: std.atomic.Mutex = .unlocked;
while (!mutex.tryLock()) std.atomic.spinLoopHint();
defer mutex.unlock();
```

**A noopIo shim with `mutexLock`/`mutexUnlock` vtable fields does NOT compile** — those fields don't exist on `std.Io.VTable` in 0.16. Use `std.atomic.Mutex` instead.

**When this bites:** writing module-level globals that need a mutex but have no Io in scope; porting 0.15 code that used `std.Thread.Mutex`.

---

## `std.Io.Threaded` env cache blocks runtime env propagation

`std.Io.Threaded` memoizes the process env at `init()` time. Once cached, it's permanent for the Io's lifetime — no public API to re-scan.

**Symptom:** `setenv(...)` (via libc) at runtime + `std.process.spawn(io, ...)` gives the child the STALE env, not the libc env.

**Fix:** Set env BEFORE the Io is constructed, or pass `environ_map` to spawn. For tests: invoke with the env set at the shell level (`env FOO=bar zig build test`).

**When this bites:** any test that spawns a subprocess and needs the subprocess to see specific env; any production code that wants per-request env.

---

## Appending to existing file requires `writePositionalAll`, not `writeStreamingAll`

`std.Io.File` has NO `seekTo`/`seekBy`/`seekFromEnd`. After `createFile(.{ .truncate = false })`, the kernel's position is 0 even if the file already has content. `writeStreamingAll` writes at position 0, overwriting the beginning.

**Fix:** Use `writePositionalAll(file, io, bytes, offset: u64)` with the absolute end-of-file offset:

```zig
const file_size = try std.Io.File.length(file, io);
var current_offset: u64 = file_size;
// next append: writePositionalAll(file, io, output, current_offset); current_offset += output.len;
```

**Tracker pattern:** maintain `current_offset` on the struct; after `createFile`, init from `File.length`; after each write, add bytes written. Reset to 0 after rotation.

**When this bites:** any "append to log file" code on Zig 0.16. The bug is invisible in single-process tests that only create fresh files.

---

## `std.json.fmt` emits invalid-UTF-8 strings as byte ARRAYS (not strings)

```zig
// /usr/local/lib/zig/std/json/Stringify.zig:506
if (!self.options.emit_strings_as_arrays and std.unicode.utf8ValidateSlice(slice)) {
    return self.stringValue(slice);
}
// else: emit as array of byte values
```

If a `[]const u8` contains invalid UTF-8, the JSON output is `"content": [60, 116, 111, ...]` (an array), not `"content": "..."` (a string). The frontend then fails to render the array as text.

**Fix:** Sanitize before serializing:

```zig
const sanitized: ?[]u8 = blk: {
    const c = input.content orelse break :blk null;
    break :blk try helpers.sanitize.sanitizeUtf8(allocator, c);
};
defer if (sanitized) |s| allocator.free(s);
// Use `sanitized orelse input.content orelse ""` in the payload struct.
```

`sanitizeUtf8` replaces invalid bytes with U+FFFD, so the output is always valid UTF-8.

**When this bites:** any tool that returns binary output (test binaries printing control chars, `cat`-ing binary files), any SSE event that pipes tool output.

---

## Function parameter with matching return type is implicitly `const`

A function with signature `fn(messages: std.ArrayList(T)) !std.ArrayList(T)` treats `messages` as `const` inside the body. Calling `messages.deinit(allocator)` (which takes `*Self`) fails with `expected type '*T', found '*const T'`.

**Fix:** Copy to a mutable local:

```zig
pub fn compactNew(messages: std.ArrayList(T)) !std.ArrayList(T) {
    var messages_owned = messages;     // local is mutable
    for (messages_owned.items) |*msg| msg.deinit(allocator);
    messages_owned.deinit(allocator);
    return new_messages;
}
```

**Why `zig build test` may miss this:** lazy analysis — the function may not be reached by the test target's graph. Always run `zig build` (with `rm -rf zig-out/bin`) to verify.

**When this bites:** any function refactored from `T → *T` (in-place mutation) to `T → !T` (by-value, return new).

---

## `std.Io.Select` for race-based process timeouts (not busy-poll)

`std.Io.Select` is the proper primitive for racing two async tasks (deadline-sleep vs child-completion). Replaces `while-true { check; sleep(10ms); }` busy-poll with a futex-parked deadline task.

**Pattern:**

```zig
const Result = union(enum) { timeout: void, child_done: void };
var buf: [1]Result = .{undefined};
var select = std.Io.Select(Result).init(io, &buf);
defer select.cancelDiscard();

select.async(.timeout, timeoutFn, .{ io, timeout_ns });
select.async(.child_done, waitChildFn, .{ io, &stdout_eof, &stderr_eof });

const result = try select.await();   // NO io argument
switch (result) {
    .timeout => kill_and_reap(),
    .child_done => call_wait(),
}
```

**Pitfalls (all hit during the bash-mandatory-timeout work):**
1. `select.await()` does NOT take `io` (Io is stored in the struct by `init`).
2. Zig 0.16 has no `goto` — use labeled blocks for cross-branch fall-through.
3. `testing.expectError` takes a value (`error.X`), NOT a type.
4. Union field type must match the async fn's return type.

**Background spawn path:** should EXEMPT from mandatory-timeout validation (background processes detach and have no tool-enforced deadline).

**When this bites:** any tool that runs a subprocess with a deadline and currently polls via `std.Io.sleep` loops.

---

## `for (info.fields)` on `@typeInfo(T).@"struct"` requires `inline for`

A normal `for` over `info.fields` is a compile error: `values of type 'builtin.Type.StructField' must be comptime-known`.

**Why:** `StructField.default_value: ?anyopt` has comptime-only metadata; runtime `for` can't read it.

**Fix:** Use `inline for`:

```zig
inline for (@typeInfo(T).@"struct".fields) |f| {
    if (std.mem.eql(u8, f.name, "foo")) ...
}
```

Alternative for tests: direct indexing `info.fields[i].name` reads only the runtime-readable `name` field.

**When this bites:** tests that scan struct fields by name with a loop; enum variant discovery.

---

## Module-level globals need `StringHashMapUnmanaged`, not `StringHashMap`

`var map: std.StringHashMap(V) = .empty;` is a compile error — `.empty` is only on the `Unmanaged` variant.

**Fix:**

```zig
var map: std.StringHashMapUnmanaged(V) = .empty;
pub fn insert(allocator: Allocator, key: []const u8, value: V) !void {
    try map.put(allocator, key, value);
}
```

**When this bites:** module-level global state backed by a string-keyed map.

---

## User-space deadlines cannot interrupt blocking socket reads

`std.Io.Threaded` parks worker threads in kernel `recv()`. A deadline check on the main thread is dead code for that path — the worker only unblocks on RST/FIN/error/timeout.

**Old advice** (set `SO_RCVTIMEO` and catch `EAGAIN`) is **WRONG** in current `std.Io.Threaded`. It treats `EAGAIN` as a programmer bug and panics in debug (`errnoBug`). The only safe recv-early errors are: `ECONNRESET` (via TCP keepalive), `ETIMEDOUT` (via connect-timeout), `ENOTCONN`/`EPIPE`.

**Actual fix:** aggressive TCP keepalive:

```zig
const keepidle: c_int = 2;
std.posix.setsockopt(sock, std.posix.SOL.IPPROTO.TCP, std.posix.TCP.KEEPIDLE,
    std.mem.asBytes(&keepidle)) catch {};
const keepintvl: c_int = 2;
std.posix.setsockopt(sock, std.posix.SOL.IPPROTO.TCP, std.posix.TCP.KEEPINTVL,
    std.mem.asBytes(&keepintvl)) catch {};
const keepcnt: c_int = 2;
std.posix.setsockopt(sock, std.posix.SOL.IPPROTO.TCP, std.posix.TCP.KEEPCNT,
    std.mem.asBytes(&keepcnt)) catch {};
```

Total detection: `keepidle + keepintvl * keepcnt` = 6s. On loopback, keepalive never fires (peer kernel ACKs probes) — use a server that `close()`s the socket to exercise the path.

**When this bites:** LLM streaming where upstream can stall; long-polling with deadline guarantee.

---

## `expectError` tests that exercise production `std.log.err` exit 1

When a test exercises a production error path that calls `std.log.err(...)`, the test framework reports `log_err_count > 0` to the build runner, which exits 1 even though assertions passed. The test binary itself returns non-zero (`X passed; 0 failed. N errors were logged.`).

**Why:** `std.options.logFn` is `pub const` — can't reassign per-test. The default test log_level is `.warn` (inclusive-low), so `.err` always gets through.

**Pragmatic fix:** verify test correctness by running the binary directly (exit 1 is cosmetic noise). Long-term: demote `std.log.err` → `std.log.warn` for user-input errors (not programmer errors).

**When this bites:** any test that exercises a production error path with `std.log.err` (e.g., Config parsing, MCP config, sqlite error paths).

---

## Borrowed SSE/event-bus slices need explicit ownership tracking

When a function builds a `[]const u8` slice for an event-bus payload, the slice is borrowed by the receiver. The caller MUST free after the function returns. The naive pattern with `try X catch "literal"` fails because `"literal"` is `*const [N:0]u8`, not `[]u8`.

**Fix — split owned + fallback:**

```zig
const created_at_owned: ?[]u8 = blk: {
    var q = db.query(...) catch break :blk null;
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        break :blk allocator.dupe(u8, row.values[0]) catch null;
    }
    break :blk null;
};
defer if (created_at_owned) |c| allocator.free(c);

const created_at: []const u8 = created_at_owned orelse
    std.fmt.allocPrint(allocator, "{d}", .{now_ms}) catch return;
defer if (created_at_owned == null) allocator.free(created_at);
```

The two `defer if (...)` blocks are mutually exclusive.

**When this bites:** any function building strings for SSE/log payloads with a primary DB-read path AND a fallback compute path.

---

## `@import("../foo.zig")` is rejected from root_source_file targets

When a file is the `root_source_file` of an `addExecutable()`, `@import("..")` that escapes the file's dir is a hard error: `import of file outside module path`.

**Fix:** Don't reach up. Re-export the symbol through a public module surface (e.g., `nalarcore.ai_mod.routines.fire`), then import the module. The nalar pattern: `const nalarcore = @import("nalarcore"); const fire = nalarcore.ai_mod.routines.fire;`.

**Invisible to `zig build test` and `zig ast-check`** — they don't compile the file as a root. Only fails when wired as a build target.

**When this bites:** any new sub-process binary in a sibling dir of the code it wants to call.

---

## Related / cross-references

- `zig-language-quirks.md` — non-stdlib language gotchas (anonymous structs, error sets, etc.)
- `zig-build-and-test.md` — build/test/lazy analysis patterns
- `zig-cross-platform.md` — cross-platform porting patterns
- `zig-sqlite-patterns.md` — SQLite-specific Zig patterns