# Zig 0.16 test cleanup for deeply nested directory trees

## Symptom

After `zig build test` runs, the project root is littered with empty
`test_wf_*/`, `test_diff_view_*/`, etc. directories left behind by tests
that exercise `createDir` / `createDirPath` with deeply nested paths.
Files are cleaned up but parent directories persist. Pattern repeats on
every run.

## Root cause

The standard pattern `defer deleteFile(path)` only removes the leaf
file — parent dirs remain. For tests that use deeply nested paths
(`test_wf_deeply_nested/a/b/c/deep.txt`), this leaves 4 empty parent
dirs behind every run.

Developers sometimes add a comment like "parent dir cleanup skipped:
Io runtime iterate() is flaky in tests" — but the real fix is to
delete the KNOWN parent paths in deepest-first order (no iteration
needed because the test is the sole creator of the tree).

## Fix — `deleteTestTree` helper

```zig
fn deleteDir(path: []const u8) void {
    std.Io.Dir.cwd().deleteDir(testing.io, path) catch {};
}

// Best-effort cleanup for a test's full directory tree. Deletes the
// leaf file, then each parent directory in DEEPEST-FIRST order so each
// rmdir sees an empty directory.
//
// Why no `openDir().iterate()` walk: the Zig 0.16 Io runtime is flaky
// when iterating from the cwd Dir handle after a createDir/createDirPath
// syscall (it can return BADF). Since the test is the SOLE creator of
// the tree, we can hardcode the parent list at comptime and avoid the
// iteration. All errors are swallowed — the goal is "leave no residue",
// not "assert cleanup succeeded".
fn deleteTestTree(comptime parents_deep_first: []const []const u8, leaf_file: []const u8) void {
    deleteFile(leaf_file);
    inline for (parents_deep_first) |dir| {
        deleteDir(dir);
    }
}
```

Usage at call sites:

```zig
test "writes deeply nested file" {
    const path = "test_wf_deeply_nested/a/b/c/deep.txt";
    defer deleteTestTree(&.{
        "test_wf_deeply_nested/a/b/c",
        "test_wf_deeply_nested/a/b",
        "test_wf_deeply_nested/a",
        "test_wf_deeply_nested",
    }, path);
    // ... test body ...
}
```

## Pitfalls

- **Order matters**: must be DEEPEST FIRST. `deleteDir` requires an
  empty directory; if `c/` isn't empty when you try to rmdir it, the
  call fails (silently here because we `catch {}`, but the parent
  `b/`/`a`/`test_wf_deeply_nested` will still be left behind).
- **Don't try to walk with `openDir().iterate()`** in Zig 0.16 test
  contexts — the Io runtime can return `BADF` on the cwd Dir handle
  after `createDir`/`createDirPath`. Use the hardcoded parent list.
- **For tests that DON'T create nested dirs** (just leaf files), keep
  using `defer deleteFile(path)` — don't over-engineer.
- **Don't `path.join` the parents** — hardcode them as string literals
  in the comptime slice. `path.join` returns a `[]u8` runtime slice
  with no NUL terminator (see `zig-path-join-non-null-terminated-slice.md`),
  which would break the comptime list.
- **For tests that create a single non-nested dir** (like
  `test_wf_create_dir_parent/`), inline `defer { deleteFile(path); deleteDir("test_wf_create_dir_parent"); }`
  rather than calling `deleteTestTree` — keeps the simple cases simple.

## Verification

```bash
# Pre-clean any existing residue
rm -rf test_wf_*/ "test_wf dir with spaces"

# Run the test
zig build test --summary all

# Verify zero new residue
ls -la test_wf_*.* test_wf_*/ "test_wf dir with spaces"
# expect: all "No such file or directory"
```

Same pass rate before and after the fix (verified on 2026-07-25:
1837/1847 both pre- and post-fix on macOS, the 4 failures are pre-existing
in `workflow_retry_delay_test.zig`).

## Related

- `zig-path-join-non-null-terminated-slice.md` — why hardcoded strings
  beat `path.join` for the parent list
- `src/ai_workflow/tui/design_io.zig::deleteDirectoryRecursively` —
  the production recursive-delete helper (DO NOT use in tests for the
  reasons above)
