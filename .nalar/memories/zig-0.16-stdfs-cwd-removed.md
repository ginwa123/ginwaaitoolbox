# Zig 0.16 — `std.fs.cwd()` removed; use `std.Io.Dir.cwd()` with new `readFileAlloc` signature

In Zig 0.16, `std.fs.cwd()` is gone. The replacement is `std.Io.Dir.cwd()`
(matching the broader `std.Io`-aware API in 0.16) and the `readFileAlloc`
signature changed to require an `Io` parameter and an `Io.Limit` value
(rather than a raw byte count).

## Symptom

```zig
const data = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
// ❌ 'std.fs' has no member 'cwd' (or 'cwd' is gone from std.fs)
```

The compile error references the missing `cwd()` function or the changed
`readFileAlloc` signature.

## Root cause

The `std.fs` namespace was reorganized in Zig 0.16 to align with the
`std.Io` thread/group model. Directory operations moved to
`std.Io.Dir` (which is a *runtime* directory handle, not a module-level
helper). `readFileAlloc` now takes an `Io` instance as a parameter
because all I/O goes through the Io vtable.

## The fix

```zig
const data = try std.Io.Dir.cwd().readFileAlloc(
    std.testing.io,        // or any std.Io instance
    path,                  // []const u8 path
    allocator,             // std.mem.Allocator
    .limited(1 << 20),     // Io.Limit (enum, not raw usize)
);
```

Key changes:
- `std.fs.cwd()` → `std.Io.Dir.cwd()`
- New first parameter: `io: std.Io` (pass `std.testing.io` from tests, or
  the request's `ctx.io` from handlers)
- Old: `readFileAlloc(allocator, path, max_size: usize)`
- New: `readFileAlloc(io, path, allocator, limit: Io.Limit)` where
  `Io.Limit.unlimited` and `Io.Limit.limited(n)` are the two main variants

## How to verify

```bash
rg "pub fn readFileAlloc\b" /usr/local/lib/zig/std/Io/Dir.zig
# expect 1 hit confirming the (io, path, allocator, limit) signature

rg "pub fn cwd\b" /usr/local/lib/zig/std/fs.zig
# expect 0 hits — cwd is gone
```

## Concrete precedent in this project

`src/modules/custom_http_server/src/sse_chunked_test.zig:202` uses the
new API and was the reference for adapting
`src/tests/auth_signup_handler_test.zig` and
`src/tests/auth_signin_handler_test.zig`.

```zig
// From sse_chunked_test.zig (working Zig 0.16 idiom):
const data = try std.Io.Dir.cwd().readFileAlloc(
    std.testing.io, path, allocator, .limited(1 << 20),
);
```

## When this bites

- Any test that reads a source file (e.g. static-contract tests that
  grep a handler for substrings).
- Any startup code that reads a config file, prompt file, or memory
  file from the working directory.
- Any port from older Zig (0.10–0.15) that used `std.fs.cwd()` directly.
- The std.Io model affects **all** I/O APIs, not just cwd:
  - `std.fs.File.openFile` → `std.Io.Dir.openFile(io, ...)`
  - `std.fs.File.readToEndAlloc` → `std.Io.File.readToEndAlloc(io, ...)`
  - etc.

## Related memories

- `zig-0.16-syscall-helpers.md` — `std.posix` removals (parallel class of changes)
- `zig-0.16-file-append-must-use-writePositionalAll.md` — `std.Io.File.writeStreamingAll` doesn't seek; use `writePositionalAll` for append
- `zig-0.16-crypto-time-stdlib-removals.md` — `std.crypto.random.bytes` and `std.time.timestamp` removals (parallel class of changes)
