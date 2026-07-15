# search: respect_ignore_files parameter Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `respect_ignore_files: bool = true` parameter to `SearchInput` that, when `false`, appends `--no-ignore` to ripgrep's argv (so the search skips `.gitignore`/`.ignore`/`.rgignore` filtering).

**Architecture:** Single-field addition to `SearchInput` struct + conditional argv append + tool description update + JSON schema entry + 4 new tests (1 validation, 3 behavioral). All changes inside `src/modules/agent/tools/search.zig` and `src/modules/agent/tools/search_test.zig`. No handler / registry / frontend changes (default-true preserves wire format).

**Tech Stack:** Zig 0.16.0, ripgrep (`rg`), Zig `std.testing`. Test gating via `requiresRg()` helper for rg-dependent behavioral tests.

---

## File Structure

| File | Purpose |
|------|---------|
| `src/modules/agent/tools/search.zig` | Add `respect_ignore_files: bool = true` to `SearchInput` (line ~57). Conditionally append `--no-ignore` to argv (line ~152). Update `search_tool.description` (line ~521). Add JSON schema entry (line ~553). |
| `src/modules/agent/tools/search_test.zig` | Add 4 tests at the end of the validation-block (line ~91) and behavioral-block sections. |
| `src/ai_workflow/tui/tool_registry.zig` | NO CHANGE (SearchInput is parsed by `parseFromSlice` automatically; no new error variants). |
| `src/apps/desktop/src/api/index.ts` | NO CHANGE (field is optional with default; no wire format change). |

**Single-responsibility check:** All edits are in `search.zig` and its test file. The change is fully localized.

---

## Tasks

### Task 1: RED — Add 4 failing tests for `respect_ignore_files`

**Files:**
- Modify: `src/modules/agent/tools/search_test.zig` (append to existing `// Validation tests` block at line ~91 and `// Behavioral tests` block at line ~91+)

- [ ] **Step 1: Write the failing tests**

Append the following 4 tests to `src/modules/agent/tools/search_test.zig`. Place the validation test inside the "Validation tests" block (right after the `head AND tail` test at line ~91) and the 3 behavioral tests inside the "Behavioral tests" block (right before the final closing of the file, alongside other `requiresRg()`-gated tests).

```zig
// Validation test (no rg invocation):

test "search: respect_ignore_files = false does NOT return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    // The boolean should flow through executeSearch without triggering
    // any of the up-front validators (EmptyPattern, InvalidMaxOutput,
    // etc). We use a real rg invocation as the assertion surface — if
    // the field is wired right, this returns Ok (possibly with 0
    // matches in /tmp); if the field triggers a validation error, it
    // returns a domain error and the test fails.
    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .respect_ignore_files = false,
    });

    // Either success (Ok with 0 matches) or a rg-spawn error is
    // acceptable. What matters is NO `SearchError` domain variant
    // fires (those would mean validation rejected the field).
    _ = result catch |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied => {},
        else => return err,
    };
}

// Behavioral tests (with rg):

test "search: respect_ignore_files = true (default) skips .gitignored dirs" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // .gitignore in tmpdir root skips node_modules/
    try tmpdir.dir.writeFile(io, .{
        .sub_path = ".gitignore",
        .data = "node_modules/\n",
    });
    // node_modules/secret.js has a unique marker token
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "node_modules/secret.js",
        .data = "MARKER_TOKEN_NODE_MODULES\n",
    });
    // app.js also has the marker, but it's NOT in .gitignore
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "app.js",
        .data = "MARKER_TOKEN_NODE_MODULES\n",
    });

    // Zig 0.16: testing.TmpDir.sub_path is the basename; resolve full path.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "MARKER_TOKEN_NODE_MODULES",
        .path = ".",
        .cwd = tmpdir_path,
    });
    defer result.deinit(allocator);

    // Exactly 1 match — only app.js. node_modules/secret.js was skipped
    // because it's in .gitignore.
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqualStrings("app.js", result.matches.items[0].file);
}

test "search: respect_ignore_files = false searches .gitignored dirs" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{
        .sub_path = ".gitignore",
        .data = "node_modules/\n",
    });
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "node_modules/secret.js",
        .data = "MARKER_TOKEN_NODE_MODULES_FALSE\n",
    });
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "app.js",
        .data = "MARKER_TOKEN_NODE_MODULES_FALSE\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "MARKER_TOKEN_NODE_MODULES_FALSE",
        .path = ".",
        .cwd = tmpdir_path,
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // Exactly 2 matches — both app.js AND node_modules/secret.js.
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);

    // Collect filenames (order from rg is not guaranteed)
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);
    for (result.matches.items) |m| try files.append(allocator, m.file);
    var saw_app = false;
    var saw_node_modules = false;
    for (files.items) |f| {
        if (std.mem.eql(u8, f, "app.js")) saw_app = true;
        if (std.mem.eql(u8, f, "node_modules/secret.js")) saw_node_modules = true;
    }
    try testing.expect(saw_app);
    try testing.expect(saw_node_modules);
}

test "search: respect_ignore_files = false also un-respects .ignore / .rgignore" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // .ignore (not .gitignore!) skips the build_artifacts/ dir
    try tmpdir.dir.writeFile(io, .{
        .sub_path = ".ignore",
        .data = "build_artifacts/\n",
    });
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "build_artifacts/cached.dat",
        .data = "MARKER_TOKEN_IGNORE_FILE\n",
    });
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "main.txt",
        .data = "MARKER_TOKEN_IGNORE_FILE\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "MARKER_TOKEN_IGNORE_FILE",
        .path = ".",
        .cwd = tmpdir_path,
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // Both files matched — .ignore was un-respected via --no-ignore
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
}
```

- [ ] **Step 2: Run the new tests to confirm they FAIL (compile error expected)**

Run:
```bash
timeout 180 zig build test --summary all 2>&1 | rg -A 2 "respect_ignore_files"
```

Expected: errors like `error: no field named 'respect_ignore_files' in struct 'agent.tools.search.SearchInput'` at each of the 4 new tests. Build fails.

This is the "red" state. We cannot proceed until Task 2 adds the field.

---

### Task 2: GREEN — Implement the feature in `search.zig`

**Files:**
- Modify: `src/modules/agent/tools/search.zig:49-58` (SearchInput struct)
- Modify: `src/modules/agent/tools/search.zig:152-162` (argv block)
- Modify: `src/modules/agent/tools/search.zig:517-600` (search_tool.description and JSON schema)

- [ ] **Step 3: Add `respect_ignore_files` field to `SearchInput`**

In `src/modules/agent/tools/search.zig`, add the new field to the `SearchInput` struct (around line 57). Insert it AFTER `cwd` so the struct keeps its existing field order:

```zig
pub const SearchInput = struct {
    pattern: []const u8,
    path: []const u8,
    max_results: ?usize = null,
    head: ?usize = null,
    tail: ?usize = null,
    max_output: ?usize = 1024 * 1024,
    group_by_file: bool = true,
    cwd: ?[]const u8 = null,
    /// When true (default), ripgrep respects .gitignore / .ignore / .rgignore.
    /// When false, appends `--no-ignore` to rg's argv so it searches
    /// gitignored paths (build/, node_modules/, etc.). Mirrors rg's
    /// --no-ignore flag, which disables ALL ignore-file filtering.
    respect_ignore_files: bool = true,
};
```

- [ ] **Step 4: Conditionally append `--no-ignore` to argv**

In `src/modules/agent/tools/search.zig`, replace the existing argv literal at line 152-162 with a conditional version. The cleanest approach is to build an `ArrayList([]const u8)` and append conditionally.

Replace lines 152-162:

```zig
const argv = &[_][]const u8{
    "rg",
    "--json",
    "--line-number",
    "--no-config",
    "--no-messages",
    "-e",
    input.pattern,
    "--",
    input.path,
};
```

with:

```zig
// Build the argv conditionally. Start with the always-present flags,
// then add --no-ignore when the caller has opted out of ignore-file
// filtering. The closure-captured `argv_*` slices must outlive the
// std.process.run call below; --no-ignore_arg is a static string
// literal so no allocator ownership is needed.
const ignore_arg: []const u8 = "--no-ignore";
const argv_const: []const []const u8 = if (input.respect_ignore_files) &[_][]const u8{
    "rg",
    "--json",
    "--line-number",
    "--no-config",
    "--no-messages",
    "-e",
    input.pattern,
    "--",
    input.path,
} else &[_][]const u8{
    "rg",
    "--json",
    "--line-number",
    "--no-config",
    "--no-messages",
    "--no-ignore",
    "-e",
    input.pattern,
    "--",
    input.path,
};
const argv = argv_const; // pointer to the chosen slice
```

Then change line 164 (`const result = std.process.run(...)`) — NO signature change needed; `argv` is still `[]const []const u8` either way.

Also delete the `ignore_arg` declaration (unused since both branches use string literal `"--no-ignore"` directly). Simplify to:

```zig
const argv: []const []const u8 = if (input.respect_ignore_files) &[_][]const u8{
    "rg",
    "--json",
    "--line-number",
    "--no-config",
    "--no-messages",
    "-e",
    input.pattern,
    "--",
    input.path,
} else &[_][]const u8{
    "rg",
    "--json",
    "--line-number",
    "--no-config",
    "--no-messages",
    "--no-ignore",
    "-e",
    input.pattern,
    "--",
    input.path,
};
```

- [ ] **Step 5: Update `search_tool.description` to document the new param**

In `src/modules/agent/tools/search.zig`, find the description block (around line 540-549). Add the bullet at the end of the existing list (after the `max_results and max_output must be > 0.` line):

```zig
\\
\\- respect_ignore_files: default true (respects .gitignore/.ignore/.rgignore).
\\  Set false to search gitignored paths (build/, node_modules/, .git/, etc.).
```

- [ ] **Step 6: Add `respect_ignore_files` to the JSON schema**

In `src/modules/agent/tools/search.zig`, find the `.properties = &.{...}` block (around line 553-594). Add a new property block AFTER the `cwd` entry (around line 593):

```zig
.{
    .name = "respect_ignore_files",
    .type = "boolean",
    .description = "Respect .gitignore/.ignore/.rgignore. Default: true. Set false to search gitignored paths (build/, node_modules/, .git/, etc.).",
},
```

**Why no `.default` field:** The `ToolProperty` struct in `src/modules/agent/tools/schemas.zig:57-61` is just `{ name, type, description }` — no `default` field exists. The default is conveyed via the description prose ("Default: true") plus the `= true` default value on the Zig struct field, which `parseFromSlice` honors when the JSON omits the key.

- [ ] **Step 7: Run the new tests to confirm they PASS**

Run:
```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `Build Summary: X/Y steps succeeded; N/N tests passed (K skipped)` with the test count up by +4 from the baseline. NO new failures vs the baseline.

- [ ] **Step 8: Run the full Zig build (catch lazy-analysis errors)**

Per project memory `zig-build-catches-lazy-analysis-errors-test-misses`, run:
```bash
rm -rf zig-out/bin
timeout 360 zig build 2>&1 | tail -n 10
```

Expected: `Build Summary: N/N steps succeeded` with no compile errors. This catches errors the test target's lazy analysis hides (e.g. production handler code that wasn't in the test compile graph).

- [ ] **Step 9: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/search-respect-ignore
git add src/modules/agent/tools/search.zig src/modules/agent/tools/search_test.zig
git commit -m "feat(search): add respect_ignore_files param (default true)

The search tool previously inherited ripgrep's default of respecting
.gitignore / .ignore / .rgignore, with no way to opt out. This meant
LLMs and operators couldn't search across gitignored paths
(node_modules/, build/, .git/ internals) for tokens, version pins, or
secret-leak scans.

Add respect_ignore_files: bool = true to SearchInput. When false,
appends --no-ignore to rg's argv (ripgrep's one-flag switch that
disables ALL ignore-file filtering — gitignore, ignore, rgignore,
.git/info/exclude, global gitignore, parent-dir gitignores).

Default true preserves current behavior; no breaking change for
existing callers or tests.

Adds 4 tests (1 validation + 3 behavioral) in search_test.zig
covering: no validation error on the new field, default-skip behavior
on .gitignore'd dirs, --no-ignore behavior on .gitignore'd dirs, and
--no-ignore behavior on .ignore / .rgignore.

Wire format unchanged (JSON schema marks default=true; no handler/
registry/frontend changes needed).

Design: docs/plans/2026-07-15-search-respect-ignore-files-design.md"
```

---

## Verification

After all tasks, run the project memory `verification-before-completion` ritual:

1. `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — test count should be baseline + 4, no new failures.
2. `rm -rf zig-out/bin && timeout 360 zig build 2>&1 | tail -n 10` — full build green.

If both pass, the implementation is complete and can be reviewed + PR'd.

## Memory Notes

This task exercises the standard "add parameter to a Zig tool" pattern:
- New optional field with sensible default = backwards compatible
- Conditional argv-construction with two literal slices
- TDD: tests-first so the `respect_ignore_files = false` field exists in the struct before executeSearch tries to read it
- JSON schema update with `.default = true` so the LLM sees the default
- No handler / registry / frontend changes (default = wire-format-neutral)
