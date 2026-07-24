# `std.fs.path.join` returns non-null-terminated slice, breaks {s} and C APIs

## Symptom
Garbage characters appear after format-substituted paths in XML output. `{s}` prints a path string followed by random bytes (the bytes after the slice's logical end, until the next NUL). C APIs expecting `[*:0]u8` may read past the intended end.

## Root cause
`std.fs.path.join(allocator, &.{ a, b, c })` returns `[]u8` (pointer + length) — NOT a NUL-terminated string. The `{s}` format specifier expects a `[:0]u8` (or `*[:0]u8`) sentinel-terminated slice. Mismatch → `std.fmt` reads past `len` looking for the sentinel.

## Fix
For XML/JSON/string output, build the value via `ArrayList.appendSlice` directly (no `{s}`). For C APIs, write a NUL byte manually:

```zig
// For ArrayList-based output (preferred):
var buf: std.ArrayList(u8) = .empty;
defer buf.deinit(allocator);
try buf.appendSlice(allocator, path);   // respects len, no sentinel scan

// For C APIs requiring null-terminated:
const path_z = try allocator.allocSentinel(u8, path.len, 0);
defer allocator.free(path_z);
@memcpy(path_z[0..path.len], path);
```

## Pitfalls
- **Avoid `std.fmt.allocPrint(..., "{s}\n", .{path})` for path-containing strings** — use `std.fmt.allocPrint` with `{}` only for primitives, then write the path bytes via `ArrayList.appendSlice` separately.
- **Adjacent bug — `@memcpy arguments alias`**: when user input strings (skill_name, agent name) alias the destination buffer passed to `path.join`, Zig's safety check panics. Fix: `const name_owned = try allocator.dupe(u8, input.name); defer allocator.free(name_owned);` before `path.join`.
- **Don't `path.join` + then write to a NUL-buffer via `std.fmt.bufPrint` with `{s}`** — the format spec still scans for `\0`.

## Verification
Build an XML string containing a path, then `std.mem.indexOfScalar(u8, xml, 0)` — must return `null` (no NUL bytes leaked into output). Or print the result byte-by-byte and confirm length matches `path.join` output length.

## Related
- `zig-slice-headers-across-defer-lifetimes` — same family of slice ownership bugs
- source: `src/ai_workflow/tui/tools/{add_skill,edit_skill,add_agent,remove_agent,remove_skill}.zig`
