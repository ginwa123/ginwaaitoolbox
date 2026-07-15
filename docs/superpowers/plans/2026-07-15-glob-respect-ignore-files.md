# glob: respect_ignore_files parameter Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `respect_ignore_files: bool = true` parameter to `GlobInput` that, when `false`, disables glob's custom `.gitignore` parser so the directory walk lists everything (including `node_modules/`, `build/`, `.git/`).

**Architecture:** Single-field addition to `GlobInput` + conditional `GitignoreContext` init + pass `null` to `walkDir`'s already-nullable `gitignore_ctx` slot. All changes inside `src/modules/agent/tools/glob.zig` and `src/modules/agent/tools/glob_test.zig`. No handler / registry / frontend changes (default-true preserves wire format).

**Tech Stack:** Zig 0.16.0, glob's custom `.gitignore` parser (pure Zig), Zig `std.testing`. Tests use `testing.tmpDir(.{})` with the same `realPath` + `Dir.createDirPath` patterns as PR #96's tests.

**Parallel feature:** This PR mirrors [search's `respect_ignore_files` (#96)](https://github.com/ginwa123/ginwaaitoolbox/pull/96) — same parameter name, same semantics, same default. The tool family now has consistent ignore-file handling.

---

## File Structure

| File | Purpose |
|------|---------|
| `src/modules/agent/tools/glob.zig` | Add `respect_ignore_files: bool = true` to `GlobInput` (line ~318). Conditionally init `GitignoreContext` (line ~982). Pass `gitignore_ctx = null` when false. Update `glob_tool.description` (line ~1163). Add JSON schema entry (line ~1183). |
| `src/modules/agent/tools/glob_test.zig` | Add 4 tests: 1 validation + 3 behavioral. Append to the file's appropriate section. |
| `src/ai_workflow/tui/tool_registry.zig` | NO CHANGE (`GlobInput` parsed automatically; no new error variants). |
| Frontend / wire format | NO CHANGE (default-true preserves wire format). |

**Pre-existing fortune:** `walkDir`'s `gitignore_ctx: ?*GitignoreContext` parameter is ALREADY nullable. The walker has guards like `if (gitignore_ctx) |ctx| { ctx.loadGitignoreForDir(...) }` (lines 677-678) and `if (gitignore_ctx) |ctx| { if (ctx.isIgnored(full_path)) ... }` (lines 712-715). The only call site (executor at line ~982) currently passes non-null. This means the change is purely about toggling the existing nullable — no `walkDir` signature change needed.

---

## Tasks

### Task 1: RED — Add 4 failing tests for `respect_ignore_files`

**Files:**
- Modify: `src/modules/agent/tools/glob_test.zig` (append at end of file)

- [ ] **Step 1: Write the failing tests**

Append 4 tests to `glob_test.zig`. Since the test file already has its own structure (read the file first to find existing patterns), place the 4 tests at the end of the file.

```zig
// Validation test (no dir walk needed beyond the up-front validation):

test "glob: respect_ignore_files = false does NOT return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    // The boolean should flow through executeGlob without triggering
    // any of the up-front validators (EmptyPattern, etc). Pass a
    // benign input that walks a real tmpdir — if the field is wired
    // right, this returns Ok (possibly with 0 matches if the dir is
    // empty); if the field trips a validation error, it returns a
    // domain error and the test fails.
    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    var result = search.executeGlob(allocator, io, .{
        .pattern = "*.txt",
        .path = ".",
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);
    // The test passes as long as we get back a result (no error).
}

// Behavioral tests (with real dir walk + ignore parsing):

test "glob: respect_ignore_files = true (default) skips .gitignored paths" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{
        .sub_path = ".gitignore",
        .data = "node_modules/\n",
    });
    try tmpdir.dir.createDirPath(io, "node_modules");
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "node_modules/secret.js",
        .data = "// MARKER_TOKEN_GITIGNORE_GLOB\n",
    });
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "app.js",
        .data = "// MARKER_TOKEN_GITIGNORE_GLOB\n",
    });

    // Zig 0.16: testing.TmpDir.sub_path is the basename; resolve full path.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeGlob(allocator, io, .{
        .pattern = "**/*.js",
        .path = tmpdir_path,
    });
    defer result.deinit(allocator);

    // Default = true respects .gitignore, so only app.js matches.
    // node_modules/secret.js is skipped because of the .gitignore rule.
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    const path0 = std.mem.trim(u8, result.matches.items[0].path, &std.ascii.whitespace);
    try testing.expect(std.mem.endsWith(u8, path0, "/app.js"));
}

test "glob: respect_ignore_files = false includes .gitignored paths" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{
        .sub_path = ".gitignore",
        .data = "node_modules/\n",
    });
    try tmpdir.dir.createDirPath(io, "node_modules");
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "node_modules/secret.js",
        .data = "// MARKER_TOKEN_NOIGNORE_GLOB\n",
    });
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "app.js",
        .data = "// MARKER_TOKEN_NOIGNORE_GLOB\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeGlob(allocator, io, .{
        .pattern = "**/*.js",
        .path = tmpdir_path,
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // Both files matched — .gitignore was un-respected via the null
    // gitignore_ctx. Order not guaranteed; check presence of each.
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);

    var saw_app = false;
    var saw_secret = false;
    for (result.matches.items) |m| {
        if (std.mem.endsWith(u8, m.path, "/app.js")) saw_app = true;
        if (std.mem.endsWith(u8, m.path, "/node_modules/secret.js")) saw_secret = true;
    }
    try testing.expect(saw_app);
    try testing.expect(saw_secret);
}

test "glob: respect_ignore_files = false also un-respects .ignore / .rgignore" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // .ignore (not .gitignore) skips build_artifacts/
    try tmpdir.dir.writeFile(io, .{
        .sub_path = ".ignore",
        .data = "build_artifacts/\n",
    });
    try tmpdir.dir.createDirPath(io, "build_artifacts");
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "build_artifacts/cached.dat",
        .data = "MARKER_TOKEN_IGNORE_GLOB\n",
    });
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "main.txt",
        .data = "MARKER_TOKEN_IGNORE_GLOB\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeGlob(allocator, io, .{
        .pattern = "**/*",
        .path = tmpdir_path,
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // Both files matched — .ignore was un-respected via null gitignore_ctx
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);

    var saw_main = false;
    var saw_cached = false;
    for (result.matches.items) |m| {
        if (std.mem.endsWith(u8, m.path, "/main.txt")) saw_main = true;
        if (std.mem.endsWith(u8, m.path, "/build_artifacts/cached.dat")) saw_cached = true;
    }
    try testing.expect(saw_main);
    try testing.expect(saw_cached);
}
```

- [ ] **Step 2: Run the new tests to confirm they FAIL (compile error expected)**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/glob-respect-ignore
timeout 180 zig build test --summary all 2>&1 | rg -A 2 "respect_ignore_files"
```

Expected: errors like `error: no field named 'respect_ignore_files' in struct 'glob.GlobInput'` at each of the 4 new tests. Build fails.

This is the "red" state. We cannot proceed until Task 2 adds the field.

---

### Task 2: GREEN — Implement the feature in `glob.zig`

**Files:**
- Modify: `src/modules/agent/tools/glob.zig:309-318` (GlobInput struct)
- Modify: `src/modules/agent/tools/glob.zig:982` (executor GitignoreContext init — make conditional)
- Modify: `src/modules/agent/tools/glob.zig:826,833,842,872` (walkDir calls — pass null when false)
- Modify: `src/modules/agent/tools/glob.zig:1159-1228` (glob_tool.description and JSON schema)

- [ ] **Step 3: Add `respect_ignore_files` field to `GlobInput`**

In `src/modules/agent/tools/glob.zig`, add the new field at the end of the struct (line ~318). Read the exact lines first to confirm the field placement:

```zig
pub const GlobInput = struct {
    pattern: []const u8 = "*",
    path: []const u8 = ".",
    max_results: ?usize = null,
    offset: ?usize = null,
    hidden: bool = false,
    ignore_case: bool = false,
    file_type: ?[]const u8 = null,
    follow: bool = false,
    /// When true (default), the tool respects .gitignore / .ignore / .rgignore
    /// (using glob's own custom parser — supports `!` negation, `/` anchors).
    /// When false, no ignore-file filtering is applied, so the tool will
    /// list files in `node_modules/`, `build/`, `.git/`, etc. Mirrors the
    /// search tool's `respect_ignore_files` parameter (#96).
    respect_ignore_files: bool = true,
};
```

- [ ] **Step 4: Make GitignoreContext init conditional + pass null to walkDir**

Find the executor block in `executeGlob` around line 982:

```zig
var gitignore_ctx = GitignoreContext.init(input.path);
defer gitignore_ctx.deinit(allocator);
```

Replace with:

```zig
// Only build a GitignoreContext when respect_ignore_files is true. The
// existing walkDir plumbing already accepts a nullable context, so we
// just toggle the existing nullable — no walkDir signature change
// needed.
var gitignore_ctx_storage: ?GitignoreContext = if (input.respect_ignore_files)
    GitignoreContext.init(input.path)
else
    null;
defer if (gitignore_ctx_storage) |*ctx| ctx.deinit(allocator);
const gitignore_ctx: ?*GitignoreContext = if (gitignore_ctx_storage) |*ctx| ctx else null;
```

Then find the 4 `walkDir(...)` calls in the executor (around lines 826, 833, 842, 872) and update each one to use `gitignore_ctx` instead of `&gitignore_ctx_storage.?`. Read the file first to confirm the exact form.

The current pattern likely is:
```zig
walkDir(allocator, io, dir_path, patterns, opts, results, depth + 1, &gitignore_ctx_storage.?);
```

It should become:
```zig
walkDir(allocator, io, dir_path, patterns, opts, results, depth + 1, gitignore_ctx);
```

(Read the file to confirm the exact existing form before editing.)

- [ ] **Step 5: Update `glob_tool.description`**

Find the `glob_tool.description` block (around line 1163-1180). Add a new bullet to the existing "Gitignore behavior" section (after the line ending `.gitignore if file is not gitignored)`):

```zig
        \\  - Use hidden=true to include hidden files (still respects gitignore if file is not gitignored)
        \\  - respect_ignore_files: default true. Set false to list gitignored paths
        \\    (node_modules/, build/, .git/, etc.).
        \\
```

Read the description's `\\` continuation pattern and follow it exactly.

- [ ] **Step 6: Add `respect_ignore_files` to the JSON schema**

Find the `.properties = &.{...}` block (around line 1183). Add a new entry AFTER `follow`:

```zig
.{
    .name = "respect_ignore_files",
    .type = "boolean",
    .description = "Respect .gitignore/.ignore/.rgignore (glob's custom parser). Default: true. Set false to list gitignored paths (node_modules/, build/, .git/, etc.).",
},
```

**Note:** `ToolProperty` (schemas.zig) has only `{ name, type, description }` — no `default` field. OMIT any `.default = true` line.

- [ ] **Step 7: Run the new tests to confirm they PASS**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/glob-respect-ignore
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expected: test count up by +4 from baseline. NO new failures vs the baseline.

- [ ] **Step 8: Run the full build (catch lazy-analysis errors)**

Per project memory `zig-build-catches-lazy-analysis-errors-test-misses`:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/glob-respect-ignore
rm -rf zig-out/bin
timeout 360 zig build 2>&1 | tail -n 10
```

Expected: `[zig build success]`. No compile errors.

- [ ] **Step 9: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/glob-respect-ignore
git add src/modules/agent/tools/glob.zig src/modules/agent/tools/glob_test.zig
git commit -m "feat(glob): add respect_ignore_files param (default true)

The glob tool always respected .gitignore / .ignore / .rgignore via
its custom parser (glob.zig:22-188), with no opt-out. PR #96 added
respect_ignore_files to the search tool; this PR mirrors that for
glob so the two tools have consistent ignore-file handling.

Add respect_ignore_files: bool = true to GlobInput. When false,
skip GitignoreContext.init and pass null to walkDir's existing
nullable gitignore_ctx slot. The walker's if (gitignore_ctx) |ctx|
guards (lines 677-678, 712-715) light up automatically — no
walkDir signature change needed.

Default true preserves current behavior; no breaking change for
existing callers or tests.

Adds 4 tests (1 validation + 3 behavioral) in glob_test.zig
covering: no validation error on the new field, default-respects-
.gitignore behavior, --no-ignore-style behavior, and .ignore /
.rgignore un-respecting.

Wire format unchanged (default-true on the struct field; no handler/
registry/frontend changes needed).

Design: docs/plans/2026-07-15-glob-respect-ignore-files-design.md"
```

---

## Verification

After all tasks, run the project memory `verification-before-completion` ritual:

1. `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — test count = baseline + 4, no new failures.
2. `rm -rf zig-out/bin && timeout 360 zig build 2>&1 | tail -n 10` — full build green.

If both pass, the implementation is complete and can be reviewed + PR'd.

## Memory Notes

This task exercises the "add parameter to a Zig tool" pattern for the second time. Lessons carried over from PR #96:
- New optional field with sensible default = backwards compatible.
- Use `tmpdir.dir.createDirPath(io, "parent")` BEFORE writing files with sub-paths like `"parent/file"` — Zig 0.16's `Dir.writeFile` doesn't auto-create parent dirs.
- `std.mem.endsWith(u8, m.path, "/<basename>")` is more robust than `expectEqualStrings` because glob returns absolute paths starting from the user's input `path` arg.
- ToolProperty has no `default` field — convey defaults via struct-level `= true` + description prose.
- No handler / registry / frontend changes needed (default-true = wire-format-neutral).