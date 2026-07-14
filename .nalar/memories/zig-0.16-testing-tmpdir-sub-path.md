# Zig 0.16 — `testing.TmpDir.sub_path` is a fixed-size array, NOT a slice

In Zig 0.16, `std.testing.TmpDir.sub_path` is declared as
`[sub_path_len]u8` (a fixed-size byte array holding just the random
base64-encoded basename like `"AbCdEfGh1234"`), NOT `[]u8` (a slice
to the full path). Tests that pass `&tmpdir.sub_path` to a function
expecting `[]const u8` compile fine but at runtime get the bare
basename, not the actual tmpdir path.

## Symptom

A test creates `testing.tmpDir`, writes a file inside it, then calls
some function expecting a path:

```zig
var tmpdir = testing.tmpDir(.{});
defer tmpdir.cleanup();
try tmpdir.dir.writeFile(io, .{
    .sub_path = "marker.txt",
    .data = "...",
});

var result = try search.executeSearch(allocator, io, "/tmp", .{
    .pattern = "--help",
    .path = &tmpdir.sub_path,    // ← BUG: only the basename "AbCdEfGh1234"
});
```

`&tmpdir.sub_path` coerces to `[]const u8` (so it compiles), but at
runtime ripgrep receives `"AbCdEfGh1234"` — a relative basename, NOT
the real path. Combined with the test's hardcoded `"/tmp"` as the
cwd, ripgrep looks in `/tmp/AbCdEfGh1234/` which doesn't exist
(because the actual tmpdir lives at
`<project>/.zig-cache/tmp/AbCdEfGh1234/`). Result: `error.PathError`.

This was the root cause of 4 test failures + 1 memory leak in
`src/modules/agent/tools/search_test.zig` (commit
`fix-zig-build-test-2026-07-11` on `feature/search-edge-cases`).

## Why this bit so hard

The code shape (`&tmpdir.sub_path`) looks correct — it reads like
"a reference to the path of the tmpdir". In older Zig (and many
test guides), `sub_path` WAS the full path slice. In Zig 0.16 it's
just the basename, and the helper moved the dir creation logic
into a separate `parent_dir` field.

The tmpdir is created in `Io.Dir.cwd()` (NOT `/tmp`):

```zig
// /usr/local/lib/zig/std/testing.zig:641-647
const cwd = Io.Dir.cwd();
var cache_dir = cwd.createDirPathOpen(io, ".zig-cache", .{}) catch ...;
defer cache_dir.close(io);
const parent_dir = cache_dir.createDirPathOpen(io, "tmp", .{}) catch ...;
const dir = parent_dir.createDirPathOpen(io, &sub_path, .{...}) catch ...;
```

So the full path is `<test_cwd>/.zig-cache/tmp/<random_sub_path>/`.

## The fix — use `tmpdir.dir.realPath(io, &buf)`

`Io.Dir.realPath` resolves a handle to its absolute canonical path:

```zig
var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
const path_len = try tmpdir.dir.realPath(io, &path_buf);
const tmpdir_path: []const u8 = path_buf[0..path_len];

// Use tmpdir_path either as the cwd (and search ".") or as
// the explicit path arg.
var result = try search.executeSearch(allocator, io, tmpdir_path, .{
    .pattern = "--help",
    .path = ".",     // search the tmpdir itself
});
```

`max_path_bytes` is `4096` (or platform-dependent); `realPath` writes
the resolved path into `path_buf` and returns the byte count. Slice
the buffer to get a `[]const u8`. The buffer lives on the stack for
the duration of the test function, so the slice stays valid.

## Alternative — use parent dir + basename

If you want to keep the `&tmpdir.sub_path` pattern (avoiding
realPath), set the cwd to the parent dir:

```zig
var parent_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
const parent_len = try tmpdir.parent_dir.realPath(io, &parent_buf);
const parent_path: []const u8 = parent_buf[0..parent_len];

var result = try search.executeSearch(allocator, io, parent_path, .{
    .pattern = "--help",
    .path = &tmpdir.sub_path,   // basename, now resolves correctly
});
```

This is uglier than the realPath approach but matches the existing
`tmpdir.sub_path` semantics directly.

## When this bites

- Any new test that does `testing.tmpDir` + passes a path to a
  function.
- Porting tests from older Zig (0.13/0.14/0.15) where `sub_path`
  was the full path slice.
- Behavioral tests that use real executables (rg, sqlite3, etc.) —
  the path resolution failure surfaces as `error.PathError` / `FileNotFound`,
  far from the actual cause (`&tmpdir.sub_path`).

## How to verify

1. Check the failure trace: `error.PathError` at the tool's path
   handling → likely `&tmpdir.sub_path` or similar misuse.
2. Verify by adding a `std.debug.print` of the path arg before the
   call — it should be `/home/<user>/.zig-cache/tmp/<basename>/`,
   not just the basename.
3. Apply the `realPath` fix and re-run.

## Related

- `zig-0.16-stdfs-cwd-removed.md` — another Zig 0.16 stdlib
  API change (`std.fs.cwd()` → `std.Io.Dir.cwd()`).
- `zig-defer-allocator-free-on-string-literal.md` — different test
  memory-leak pattern (literal vs heap ownership in defer free).
