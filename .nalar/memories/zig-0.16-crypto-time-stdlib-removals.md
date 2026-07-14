# Zig 0.16 — `std.crypto.random.bytes` and `std.time.timestamp` don't exist (use libc)

Zig 0.16's stdlib removed the module-level `std.crypto.random.bytes(...)`
helper and the `std.time.timestamp()` function. Code that worked under
0.13/0.14/0.15 (and that you might find in older projects, tutorials, or
LLM training data) fails to compile against 0.16's stdlib with errors
like `error: no member named 'random' in struct 'crypto'` or
`error: no member named 'timestamp' in struct 'time'`.

## Symptom

```zig
std.crypto.random.bytes(&buf);   // ❌ 'crypto.random' doesn't exist
const ts = std.time.timestamp(); // ❌ 'time.timestamp' doesn't exist
```

The compile errors reference the missing module namespace or member.

## Root cause

In Zig 0.16:

- `std.crypto.random` is **not** a module. The file is `std/Random.zig`
  and `Random` is a **struct**. `bytes()` is an instance method on
  `Random`, not a free function:
  ```zig
  pub const Random = struct {
      pub fn bytes(r: Random, buf: []u8) void { ... }
      // ...
  };
  ```
  So `std.crypto.random.bytes(&buf)` is wrong on two counts: wrong
  namespace (`std.crypto.random` doesn't exist) and wrong calling
  convention (it's an instance method).

- `std/time.zig` is now mostly constants (`ns_per_s`, `ns_per_ms`, ...).
  The legacy `timestamp()` function that returned `i64` seconds is gone.
  The file `/usr/local/lib/zig/std/time.zig` has no `pub fn timestamp`
  (verified via `rg "pub fn timestamp\b" /usr/local/lib/zig/std/` → 0 hits
  across the entire stdlib).

## The fix

Use libc syscalls via `std.c.*` (the project already links `c`):

```zig
const std = @import("std");
const c = std.c;

/// Fill `buf` with random bytes from the kernel CSPRNG.
/// Loops on EINTR, returns `error.EntropyUnavailable` on other failures.
fn fillRandom(buf: []u8) !void {
    while (true) {
        const rc = c.getrandom(buf.ptr, buf.len, 0);
        if (rc >= 0) {
            if (@as(usize, @intCast(rc)) == buf.len) return;
            // Partial read — not expected from getrandom with flags=0
            // (it either fills the buffer or errors), but be defensive.
            continue;
        }
        const err = c.errno(rc);
        if (err == .INTR) continue;
        return error.EntropyUnavailable;
    }
}

/// Unix timestamp in seconds (i64).
fn unixTimestampSeconds() i64 {
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @intCast(tv.sec);
}
```

Signatures (from `/usr/local/lib/zig/std/c.zig`):
- `pub extern "c" fn getrandom(buf: [*]u8, buflen: usize, flags: u32) isize;`
- `pub extern "c" fn gettimeofday(tv: ?*timeval, tz: ?*timezone) c_int;`
- `pub extern "c" fn errno(rc: anytype) E;`

## Hex encoding helpers DO exist

For the related "I need to hex-encode/decode bytes" problem, these
stdlib helpers work fine in Zig 0.16 (no libc fallback needed):

```zig
// Encode: returns a fixed-size array of length 2 * input.len.
const arr = std.fmt.bytesToHex(&bytes, .lower);   // []const u8 of hex chars
const hex_str = try allocator.dupe(u8, &arr);

// Decode: writes into out, returns the slice of out that was written.
const decoded = try std.fmt.hexToBytes(&out_buf, input_str);
```

Verified at `/usr/local/lib/zig/std/fmt.zig:1156` (`bytesToHex`) and
`std/fmt.zig:1172` (`hexToBytes`).

## How to verify

1. `rg "pub fn timestamp\b" /usr/local/lib/zig/std/` → expect 0 hits.
2. `rg "pub fn bytes\b" /usr/local/lib/zig/std/Random.zig` → expect 1 hit
   (the instance method).
3. `rg "bytesToHex|hexToBytes" /usr/local/lib/zig/std/fmt.zig` → expect
   2 hits (the two helpers above).

## When this bites

- Any auth/security code that needs random bytes (password salts,
  session tokens, CSPRNG seeds, API keys).
- Any code that wants unix timestamps for IDs or log timestamps.
- Porting code from older Zig (0.10–0.15) that used the module-level
  helpers — the project root orginally had 4 places using
  `std.time.timestamp()` that all need to be ported (see global memory
  `nalar-build-cross-compile-blocked.md` for the ginwaaitoolbox
  pre-existing occurrences).
- Any code that tried to use `std.fmt.allocPrint(..., "{x}", .{&bytes})`
  to hex-encode a byte slice — this either prints a pointer address
  (wrong) or formats byte-by-byte correctly depending on the stdlib
  version. Use `std.fmt.bytesToHex` directly to be unambiguous.

## Concrete example (this project, commit `5f3b9e4` of `feature/sign-in-sign-up-api`)

`src/auth.zig` lines 144–164 use `std.c.getrandom` wrapped in
`fillRandom()`, and lines 152–157 use `std.c.gettimeofday` wrapped in
`unixTimestampSeconds()`. The fix replaced the plan's sketched
`std.crypto.random.bytes` and `std.time.timestamp` calls with these
libc-backed helpers.
