# Zig — `std.fs.path.join` treats every argument as a path component, not a suffix

`std.fs.path.join(allocator, &.{ a, b })` does NOT concatenate `a ++ b`. It treats
both `a` and `b` as separate path components, joining them with `/` and
**inserting a slash between them** (or collapsing redundant ones). So if you want
"`<dir>/<name>.md.tmp`" (a `.tmp` suffix on the filename), you cannot do
`path.join(dir, name, ".tmp")` — that produces `<dir>/<name>.md/.tmp` (a file
named `.tmp` inside the `.md` file, which the kernel then rejects with
`error.FileNotFound` from `createFile`).

## Symptom

You write what looks like a "temp file" helper:

```zig
const tmp_path = std.fs.path.join(allocator, &.{ full_path, ".tmp" }) catch return false;
// full_path = "/tmp/.../memories/new.md"
// tmp_path = "/tmp/.../memories/new.md/.tmp"  ← wrong! "new.md" is treated as a dir
```

Then `createFile(io, tmp_path, .{})` returns `error.FileNotFound` because
`/tmp/.../memories/new.md/` doesn't exist (and the kernel can't `openat` a
"`.tmp`" entry inside what is actually a regular file).

The error surfaces as "createFile failed: FileNotFound" in debug logs, and the
test that just calls `writeMemoryFile(...)` fails on its first call to it.

## The fix

For a "suffix on the final filename" pattern, allocate a buffer of
`full_path.len + suffix.len` and concatenate with `@memcpy`. Do not use
`path.join` — every element of the join is a path component.

```zig
const tmp_path = allocator.alloc(u8, full_path.len + 4) catch return false;
defer allocator.free(tmp_path);
@memcpy(tmp_path[0..full_path.len], full_path);
@memcpy(tmp_path[full_path.len..][0..4], ".tmp");
// tmp_path = "/tmp/.../memories/new.md.tmp"  ← correct
```

For multi-component paths where you genuinely DO want components (e.g.
`"a" ++ "/" ++ "b" ++ "/" ++ "c"`), `path.join` is the right tool. Just never
mix a "full path" and a "suffix" in the same `join` call.

## Why this bites

The mental model "join = string concat with `/`" is wrong — `join` does
path-aware joining (it normalizes `//` and `/.` etc.), but the key
counter-intuitive property is that EVERY argument is a component. The single
trailing component can never be "no separator" — there is always a `/` between
components unless the first is empty or `.`.

The plan in `docs/plans/2026-06-17-add-memories-settings-menu.md` Chunk 1 had
this exact pattern (`path.join(allocator, &.{ full_path, ".tmp" })`) and would
have failed the same way in tests. The bug was caught by the integration test
when 3 `writeMemoryFile` tests all failed with `createFile: FileNotFound`.

## When this bites

- Atomic-write helpers: `<final_path>.tmp`, `*.lock`, `*.swp` — all suffix
  patterns, all wrong with `path.join`.
- Anything where you have a "full path" and want to add a short marker
  extension to the filename.
- Test debug logs that print `tmp_path` — the slash-in-middle is a dead
  giveaway: `<dir>/<name>.<ext>/<marker>` instead of `<dir>/<name>.<ext>.<marker>`.

## How to verify

If `createFile(io, <path>, .{})` returns `error.FileNotFound` and the path
string contains a `/` that wasn't in the original dir or filename, you have
this bug. Print the constructed path and look for an extra `/` before the
suffix. Switch to `@memcpy`-based concatenation.
</content>
</invoke>