# Zig 0.16 — appending to an existing file requires `writePositionalAll`, not `writeStreamingAll`

Zig 0.16's `std.Io.File` has **no `seekTo` / `seekBy` / `seekFromEnd`
API**. After `std.Io.Dir.createFile(.{ .truncate = false })`, the
kernel's file position is always 0 — even if the file already has
content. Calling `writeStreamingAll` writes at position 0, silently
**overwriting the beginning of the file** instead of appending.

## Symptom

A logger / log-rotator / file-append helper that opens an existing
file with `createFile(.{ .truncate = false })` and then writes with
`writeStreamingAll` produces:

- "After restart, the new file only contains the second batch of
  writes; the first batch is gone."
- "The log file has binary garbage at offsets 0–N."
- "Appending to an existing file doesn't work — the new content
  overwrites the old."

## Why

Verified in `/usr/local/lib/zig/std/Io/File.zig`:

```zig
pub fn writeStreamingAll(file: File, io: Io, bytes: []const u8) Writer.Error!void {
    var index: usize = 0;
    while (index < bytes.len) {
        index += try writeStreaming(file, io, &.{}, &.{bytes[index..]}, 1);
    }
}
```

`writeStreamingAll` is a thin wrapper around `writeStreaming`, which
writes at the kernel's current file position. After `createFile`, that
position is 0.

There is no `seekTo` / `seekBy` / `seekFromEnd` on `std.Io.File` (grep
confirms: only `writeStreaming`, `writePositional`, `writePositionalAll`,
`readStreaming`, `readPositional`, `readPositionalAll`).

## The fix

Use `writePositionalAll(..., offset: u64)` with the absolute end-of-file
offset. This is a `pwrite(2)` syscall — independent of the kernel's
position, so each call is self-contained.

```zig
const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false });
const file_size = try std.Io.File.length(file, self.io);  // = end of file
defer file.close(self.io);

var current_offset: u64 = file_size;
const output: []const u8 = ...;
try std.Io.File.writePositionalAll(file, self.io, output, current_offset);
current_offset += output.len;
// next call: writePositionalAll(..., current_offset)
```

## Tracker pattern

When doing many appends, track the offset yourself (a `current_offset:
u64` field on the struct). After `createFile`, initialize it from
`File.length`. After each `writePositionalAll`, add the number of bytes
written. After a `rotateLogFile` / recreate, reset to 0.

This is strictly safer than `writeStreamingAll` + tracking the kernel's
position: there is no hidden state coupling, and the math is obvious.

## When this bites

- Any "append to log file" code on Zig 0.16.
- Any "open existing file, then add to the end" pattern.
- The bug is **invisible in single-process tests** that only create
  the file fresh — the kernel correctly advances the position from 0
  through the end. The bug appears when (a) the file already exists on
  disk at open time, or (b) the file handle is closed and reopened
  within the same process.
- Existing tests in the nalar codebase passed despite the bug because
  the file-rotation test only checked `openFile + close` (i.e., the
  file exists), not the content.

## How to verify (regression test pattern)

Write a test that:

1. Opens a logger / file-handle, writes `"FIRST"`, deinits.
2. Opens a new logger / file-handle on the same path, writes
   `"SECOND"`, deinits.
3. Reads the file and asserts BOTH strings are present and the file
   size equals `len("FIRST") + len("SECOND")`.

Without the fix: file has only `"SECOND"` (26 bytes, or whatever the
second message's size is) — the first message was overwritten.

With the fix: file has both messages, no overwrites, no binary
garbage.

Red-green verified in the nalar `Logger.zig` fix (commit
`1475bb7`, branch `fix/logger-append-after-rotation`): the
"Logger appends to existing file across process restarts" test in
`src/modules/logger/logger_test.zig` fails on stashed (pre-fix)
code with `error.AppendBug` and passes after the
`writeStreamingAll` → `writePositionalAll` swap.

## Related

- `custom-http-server-per-request-arena.md` — different
  `std.Io.File` gotcha (per-request arena reaps memory; don't
  add manual `defer` cleanup).
- `zig-0.16-spawn-cwd-is-not-nullable.md` — another Zig 0.16
  stdlib gotcha.
