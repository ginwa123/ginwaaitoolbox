# Fix `glob` Tool Duplicate Results (Exponential Duplication from Dual-Recursion in `walkDir`)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the `glob` tool so that patterns with leading directory components (e.g. `src/apps/desktop/src/**/Sidebar*.vue`) return each matching file **exactly once** instead of `2^N` times (where N = number of leading directory components).

**Architecture:** Surgical fix to the `walkDir` recursion in `src/modules/agent/tools/glob.zig:660-722`. The function currently recurses into every subdirectory TWICE — once via the prefix-aware logic (lines 663-718, which strips the matched leading directory from the pattern) and once via the unconditional "normal recursive descent" call (line 721, which recurses with the full pattern). The fix tracks per-pattern consumption and only passes *unconsumed* patterns down via the fallback recursion. Plus a guard that skips the prefix-aware logic entirely for patterns whose first segment is a wildcard (the prefix-aware logic produces wrong inner patterns for wildcard prefixes — e.g. `**/foo` would be turned into `foo` which only matches the literal filename).

**Tech Stack:** Zig 0.16 + `std.Io.Threaded` + `std.Io.Dir` + the existing `std.testing.allocator` / `std.testing.io` test harness. No new dependencies.

---

## Background — the bug, with evidence

The `glob` tool is reachable from two surfaces that produce identical XML output (`<glob_summary>` + `<f>path</f>`):

1. **The AI agent's `glob` tool** — defined in `src/modules/agent/tools/glob.zig` as `pub const glob_tool = AgentTool{...}`, registered in `src/ai_workflow/tui/tool_registry.zig:1520` as `{ .name = "glob", .exec = execGlob, .tool_def = glob_tool_mod.glob_tool }`. The LLM (and sub-agents) call it via the `executeGlob` → `toXmlSuccess` pipeline.
2. **The agent harness's `glob` tool** — what this session used when I tested it. The output format `<glob_summary pattern="..." total="..." returned="...">` is produced by `toXmlSuccess` (line 809). It is calling the Zig tool.

**Symptom (duplication count = `2^N` for N leading directory components):**

| Pattern | Leading prefix length | Files matched | Observed `total=` | Duplicates per file |
|---|---|---|---|---|
| `src/apps/desktop/src/**/Sidebar*.vue` | 4 | 1 (`Sidebar.vue`) | 16 | 16 (= 2^4) |
| `src/modules/agent/tools/**/*Sidebar*` | 4 | 2 (`Sidebar.vue`, `RightSidebar.vue`) | 16 | 8 (= 2^3 each) |
| `glob_dup_test/a/b/c/d/e/match.txt` | 5 | 1 (`match.txt`) | 32 | 32 (= 2^5) |

The "1 file → 16 entries" and "1 file → 32 entries" cases prove the duplication factor is `2^N` exactly, not a coincidence. The "2 files → 16 entries" case confirms the factor is the same regardless of how many files match the suffix.

**Why this matters in practice:**

- A user asks the LLM "show me all Sidebar files" → it calls `glob` with `**/Sidebar*.vue` → gets 2 results. Then the LLM tries `src/apps/desktop/src/**/Sidebar*.vue` to be more specific → gets 16 results, dedupes them, and confuses the model.
- The `<glob_summary total="16" returned="16">` line tells the LLM (and the user) that 16 files match. The LLM may then try to `read_file` all 16 paths, most of which are duplicates of the same file.
- The LLM's mental model of "what files exist" is polluted by the noise.
- A user looking at the glob output in the chat UI sees 16 identical lines, thinks it's broken, and reports a bug (as just happened).

---

## Root cause

`src/modules/agent/tools/glob.zig:569-726` — the `walkDir` function recurses into subdirectories via **two** paths simultaneously:

```zig
if (is_dir) {
    // PATH A: prefix-aware recursion (lines 663-718)
    for (regular_patterns.items) |pat| {
        // ... matches the first segment of `pat` against the directory name ...
        if (globMatch(dir_part, name, opts.nocase)) {
            // Recurse into `full_path` with the prefix-stripped pattern
            walkDir(allocator, io, full_path, new_patterns.items, ...);
            break;
        }
    }

    // PATH B: "normal recursive descent" (line 721) — ALWAYS recurses
    walkDir(allocator, io, full_path, patterns, ...);
}
```

**The bug:** When PATH A matches a child directory, it correctly strips the leading directory from the pattern and recurses with the inner pattern. **But PATH B then ALSO recurses into the same child with the FULL original pattern** (including the leading prefix that's already been consumed). The child walkDir call sees the full pattern again, matches the same files, and adds them to results.

The recursion forks at every level of the prefix. With 4 leading directory components, we get 2^4 = 16 paths through the tree, each independently reaching and re-emitting the same file. With 5 components, 2^5 = 32.

A secondary issue: the prefix-aware logic (PATH A) also mis-fires for **wildcard** patterns whose first segment is `*`, `?`, `[`, or `**`. For pattern `*.vue`:
- `dir_part = "*"`. `globMatch("*", "anydir", false)` returns `true` for any directory name.
- The code recurses with the inner pattern `.vue` (literal), which only matches the literal filename `.vue`.
- The intended semantics — "find all `.vue` files at any depth" — are broken.

The fix needs to address both: skip PATH A for wildcard prefixes, and stop PATH B from re-applying consumed patterns.

---

## Design decisions

1. **Per-pattern consumption tracking** — Each pattern in `regular_patterns.items` is either "consumed" (the prefix-aware logic successfully stripped its leading directory for this child) or "unconsumed" (it didn't match and needs to be re-applied at deeper levels). PATH B then recurses with **only the unconsumed regular patterns + all negation patterns**.

2. **Skip PATH A for wildcard prefixes** — If the first segment of a pattern contains a wildcard character (`*`, `?`, `[`), mark it unconsumed immediately and skip the prefix-aware logic. The pattern will be re-applied at deeper levels via PATH B (with the unconsumed list), which correctly handles `**`, `*`, `?`, and `[...]` prefixes.

3. **`**/foo` semantics preserved** — A pattern starting with `**` is now handled by PATH B (not PATH A). PATH B re-applies the full pattern at every subdirectory, which is exactly what `**/foo` should do.

4. **Negation patterns always pass through** — The existing `negation_patterns` separation is preserved. Negation patterns are never consumed (they have no leading directory prefix) and are always included in PATH B's recursion.

5. **No change to public API** — The `GlobInput`, `GlobResult`, `glob_tool`, `executeGlob`, and `toXmlSuccess` signatures and behavior are unchanged. Only the internal `walkDir` is fixed. The platform harness's `glob` tool (which calls the Zig tool) benefits automatically.

6. **No change to gitignore handling** — The `GitignoreContext` plumbing is correct. The bug is purely in the recursion structure.

---

## File structure

### Modified files

```
src/modules/agent/tools/
├── glob.zig                          (fix walkDir; add isWildcardPattern helper)
└── glob_test.zig                     (add regression tests for walkDir)

src/modules/agent/
└── test_runner.zig                   (verify glob_test.zig is registered; add if missing)
```

No new files. No DB migrations. No frontend changes. No HTTP handler changes. The fix is internal to one function.

---

## Chunk 1: Failing regression test (red-green TDD)

Add a regression test that captures the bug **before** the fix. The test MUST fail on the current code (16 entries for a 4-component prefix) and PASS after the fix (1 entry).

- [ ] **Step 1.1: Verify `glob_test.zig` is registered in `src/modules/agent/test_runner.zig`**

Run: `rg "glob_test" src/modules/agent/test_runner.zig`
Expected: `_ = @import("glob_test.zig");` already present. If missing, add it (per the project's "Always register new tests in test_runner.zig" memory).

- [ ] **Step 1.2: Add a helper `setupTempTree` to `src/modules/agent/tools/glob_test.zig`**

Mirrors the pattern from the existing `loadGitignoreForDir` tests (lines 75-100) — uses `std.testing.allocator` + `std.testing.io` + `std.Io.Dir.cwd().createDirPath` / `deleteTree`. The helper creates a deterministic tree under `/tmp/glob_walkdir_test_<unique>/` with the structure:

```
<tmp>/
├── a/
│   └── b/
│       └── c/
│           └── d/
│               └── match.txt
```

The helper takes an allocator and a unique suffix (for parallel-test safety), creates the tree, returns the root path. The test does `defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};` for cleanup.

Full helper code:

```zig
const TmpTree = struct {
    root: []const u8,

    fn deinit(self: *TmpTree, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.root) catch {};
    }
};

fn setupTempTree(allocator: std.mem.Allocator, suffix: []const u8) !TmpTree {
    const root = try std.fmt.allocPrint(allocator, "/tmp/glob_walkdir_test_{s}", .{suffix});
    errdefer allocator.free(root);

    // Idempotent: clean any prior state, then create
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/a/b/c/d");

    // Create the matching file
    const match_path = try std.fmt.allocPrint(allocator, "{s}/a/b/c/d/match.txt", .{root});
    defer allocator.free(match_path);
    {
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, match_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreaming(std.testing.io, &[_]u8{'m', 'a', 't', 'c', 'h'});
    }

    return TmpTree{ .root = root };
}
```

- [ ] **Step 1.3: Add the failing regression test `walkDir returns each file once for literal-prefix pattern`**

```zig
test "walkDir returns each file once for literal-prefix pattern" {
    // Regression test for the duplicate-results bug:
    // Pattern with 5 leading directory components (a/b/c/d/) used to
    // return the file 32 times (= 2^5) due to the dual-recursion bug
    // in walkDir. After the fix, it must return exactly 1 time.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "literal_prefix");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "a/b/c/d/match.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(allocator, "{s}/a/b/c/d/match.txt", .{tree.root}),
        result.matches.items[0].path,
    );
}
```

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: **FAIL** with `expected 1, found 32` (or similar). This is the red state we need before the fix.

- [ ] **Step 1.4: Add a second failing test for wildcard-prefix pattern (also broken by the current code)**

```zig
test "walkDir returns each file once for wildcard-prefix pattern" {
    // Pattern with a leading **/ must also produce a single result per file.
    // The current code mis-handles wildcard prefixes in the prefix-aware
    // logic (it strips ** and recurses with the wrong inner pattern).
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "wildcard_prefix");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/match.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}
```

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: **FAIL** with `expected 1, found N` where N is the bug's count. (The exact count depends on the recursion; the test just asserts = 1.)

- [ ] **Step 1.5: Add a third test for mixed patterns (literal + wildcard)**

```zig
test "walkDir with mixed literal and wildcard patterns returns each file once" {
    // Both patterns should match match.txt exactly once, total 2 entries.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "mixed");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "{a/b/c/d/match.txt,**/match.txt}",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.matches.items.len);
}
```

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: **FAIL** with the current code (the literal-prefix path will duplicate, the wildcard path may also duplicate). The exact count is implementation-defined; what matters is the post-fix assertion `== 2`.

- [ ] **Step 1.6: Commit the failing tests (red)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/glob_test.zig
git commit -m "test(glob): add failing regression tests for walkDir duplicate-results bug"
```

The commit is the red baseline. Do NOT proceed to Chunk 2 without this commit on the branch.

---

## Chunk 2: Apply the fix

Surgically rewrite the `is_dir` branch in `walkDir` (lines 660-722) to use the per-pattern consumption tracking design.

- [ ] **Step 2.1: Add the `isWildcardPattern` helper to `src/modules/agent/tools/glob.zig`**

Insert after the `globMatch` function (around line 393, after the closing brace). A "wildcard pattern" contains any of `*`, `?`, `[`. Brace expansion is done upstream in `expandBraces`, so `{` never appears in patterns reaching `walkDir`.

```zig
/// Check if a glob pattern segment contains wildcard metacharacters.
/// Used to decide whether the prefix-aware logic in walkDir applies:
/// literal segments can be safely stripped as directory prefixes;
/// wildcard segments (`*`, `?`, `[`, `**`) must be re-applied at every
/// recursion level.
fn isWildcardPattern(pat: []const u8) bool {
    for (pat) |c| {
        switch (c) {
            '*', '?', '[' => return true,
            else => {},
        }
    }
    return false;
}
```

- [ ] **Step 2.2: Replace the `is_dir` branch in `walkDir` (lines 660-722)**

Surgical edit — replace ONLY the block between `if (is_dir) {` and the closing `}` of that `if`. The rest of `walkDir` (file matching, negation logic, `full_path` cleanup) is unchanged.

Old (lines 660-722):
```zig
        if (is_dir) {
            // Handle patterns with leading directory paths like "src/**" or "src/**/*.zig"
            // We need to recurse into directories that could match the pattern prefix
            for (regular_patterns.items) |pat| {
                // ... [~55 lines of prefix-aware logic] ...
            }

            // Also do normal recursive descent
            walkDir(allocator, io, full_path, patterns, opts, results, depth + 1, gitignore_ctx);
        }
```

New:
```zig
        if (is_dir) {
            // Build the list of patterns that the "normal recursive descent"
            // will pass down. A pattern is "consumed" when the prefix-aware
            // logic below successfully strips its leading directory segment
            // (e.g. "src/**" → "**" for the "src" child) — re-applying the
            // consumed pattern at the next level would re-match the same
            // files, producing 2^N duplicate results. Unconsumed patterns
            // (those whose first segment is a wildcard, or those that did
            // not match this child's name) are passed down unchanged.
            var unconsumed: std.ArrayListUnmanaged([]const u8) = .empty;
            defer unconsumed.deinit(allocator);

            for (regular_patterns.items) |pat| {
                var consumed = false;
                var pat_idx: usize = 0;

                // Skip the prefix-aware logic entirely for wildcard first
                // segments. The prefix-aware logic recurses with a
                // prefix-stripped pattern; for `**`, `*`, `?`, or `[...]`
                // first segments, the stripped pattern has the wrong
                // semantics (it stops being recursive). Mark the pattern
                // unconsumed and let the fallback recursion handle it.
                {
                    const first_slash = std.mem.indexOfScalar(u8, pat, '/') orelse pat.len;
                    const first_seg = pat[0..first_slash];
                    if (isWildcardPattern(first_seg)) continue;
                }

                while (pat_idx < pat.len) {
                    const remaining_pat = pat[pat_idx..];
                    const slash_idx = std.mem.indexOfScalar(u8, remaining_pat, '/') orelse remaining_pat.len;
                    const dir_part = remaining_pat[0..slash_idx];

                    if (globMatch(dir_part, name, opts.nocase)) {
                        // Matched a literal prefix segment — recurse with the
                        // prefix-stripped pattern and mark this pattern as
                        // consumed (do NOT also re-apply the full pattern
                        // via the fallback recursion below).
                        const next_idx = pat_idx + slash_idx + 1;
                        if (next_idx < pat.len) {
                            const remaining_pattern = pat[next_idx..];

                            if (remaining_pattern.len >= 2 and
                                remaining_pattern[0] == '*' and
                                remaining_pattern[1] == '*')
                            {
                                // Recursive "**" suffix — recurse with the
                                // inner pattern.
                                var inner_start: usize = 2;
                                if (inner_start < remaining_pattern.len and
                                    remaining_pattern[inner_start] == '/')
                                {
                                    inner_start += 1;
                                }
                                const inner_pattern =
                                    if (inner_start < remaining_pattern.len)
                                        remaining_pattern[inner_start..]
                                    else
                                        "*";

                                var new_patterns: std.ArrayListUnmanaged([]const u8) = .empty;
                                new_patterns.append(allocator, inner_pattern) catch break;
                                walkDir(allocator, io, full_path, new_patterns.items,
                                    opts, results, depth + 1, gitignore_ctx);
                                new_patterns.deinit(allocator);
                            } else {
                                // Non-recursive suffix — recurse with it.
                                var new_patterns: std.ArrayListUnmanaged([]const u8) = .empty;
                                new_patterns.append(allocator, remaining_pattern) catch break;
                                walkDir(allocator, io, full_path, new_patterns.items,
                                    opts, results, depth + 1, gitignore_ctx);
                                new_patterns.deinit(allocator);
                            }
                        } else {
                            // Pattern ends with the matched directory name —
                            // this directory itself matches; recurse to
                            // check children.
                            if (pat[pat_idx + slash_idx - 1] != '*') {
                                walkDir(allocator, io, full_path, patterns,
                                    opts, results, depth + 1, gitignore_ctx);
                            }
                        }
                        consumed = true;
                        break;
                    } else {
                        pat_idx += slash_idx + 1;
                        if (pat_idx > pat.len) break;
                    }
                }

                if (!consumed) {
                    unconsumed.append(allocator, pat) catch continue;
                }
            }

            // Always include negation patterns in the fallback recursion —
            // they have no leading directory prefix and must be re-applied
            // at every level.
            for (negation_patterns.items) |pat| {
                unconsumed.append(allocator, pat) catch continue;
            }

            // Fallback recursion with the unconsumed patterns only.
            // This is the single recursion path that PASSES PATTERNS DOWN.
            // The prefix-aware recursions above recurse with the
            // prefix-stripped pattern; the fallback recurses with the
            // patterns that the prefix-aware did NOT consume.
            if (unconsumed.items.len > 0) {
                walkDir(allocator, io, full_path, unconsumed.items,
                    opts, results, depth + 1, gitignore_ctx);
            }
        }
```

The key behavioral change: the fallback recursion (formerly line 721) now passes `unconsumed.items` (a filtered list) instead of the full `patterns`. Negation patterns are preserved.

- [ ] **Step 2.3: Run the regression tests (green)**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: **PASS** — all 3 new tests in Chunk 1 now show 1 (or 2) entries as expected. The full test count increases by 3 from the previous baseline.

- [ ] **Step 2.4: Run the full test suite to confirm no regressions**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: All previously-passing tests still pass. The new total should be (old total + 3) with the same `failed: 0` count.

If any existing test fails, the fix has broken an edge case. Read the failure, identify the pattern, and adjust the fix (most likely cause: a pattern that was relying on the unconditional fallback recursion to be passed down past a level — which is exactly what we want to prevent, but the test may be testing a legitimate case the fix needs to handle).

- [ ] **Step 2.5: Manual smoke test on the actual `Sidebar` case**

Start the nalar server on port 8080 (per the project MANDATORY rule: never use 8081):
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build install:linux:system 2>&1 | tail -n 5
./zig-out/bin/nalar --port 8080 &
NALAR_PID=$!
sleep 2
```

Then use the agent harness's `glob` tool (or call the Zig tool directly via the LLM API) with the bug-triggering pattern:
- Pattern: `src/apps/desktop/src/**/Sidebar*.vue`
- Expected: `<glob_summary total="1" returned="1">` and one `<f>` line for `Sidebar.vue`.

Verify the previous `total="16" returned="16"` is gone.

Cleanup: `kill $NALAR_PID` (NEVER `pkill -f "zig build run"` — that would also catch the nalar on 8081).

- [ ] **Step 2.6: Commit the fix (green)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/glob.zig
git commit -m "fix(glob): stop walkDir dual-recursion from producing 2^N duplicate results"
```

---

## Chunk 3: Comprehensive test coverage

Add tests for edge cases the fix could regress. These are the "stay-green" tests that lock in the new correct behavior.

- [ ] **Step 3.1: Test pattern without any leading directory prefix (regression check for `*.vue` style)**

```zig
test "walkDir with simple wildcard pattern finds files at any depth exactly once" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "simple_wildcard");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}
```

- [ ] **Step 3.2: Test pattern with `*` first segment (NOT `**`)**

```zig
test "walkDir with * prefix pattern finds files at top level only exactly once" {
    // The setup tree has a/match.txt at the top level. Pattern "*.txt"
    // should match ONLY that one file (a/*/... are subdirectories).
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "star_prefix");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.matches.items.len);
    // (No .txt file at the root; the only .txt is at a/b/c/d/match.txt
    // which is 4 levels deep and won't match a top-level "*.txt".)
}
```

- [ ] **Step 3.3: Test negation patterns (verify the separation is preserved)**

```zig
test "walkDir with negation pattern excludes correctly" {
    // Tree has a/b/c/d/match.txt. Pattern "**/*.txt" matches it.
    // Adding "!**/match.txt" (after brace expansion) should exclude it.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "negation");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "{**/*.txt,!**/match.txt}",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.matches.items.len);
}
```

Note: confirm the brace-expansion + negation handling works as expected. If the negation pattern isn't reaching the file, debug the test setup, not the fix.

- [ ] **Step 3.4: Test the Sidebar case from the original bug report**

```zig
test "walkDir with 4-component literal prefix returns each file once (regression)" {
    // The exact pattern from the original bug report:
    // "src/apps/desktop/src/**/Sidebar*.vue" returned 16 entries.
    // After the fix, the project's actual Sidebar.vue must appear
    // exactly once.
    const allocator = std.testing.allocator;

    // Use the project root as the search path. The test asserts only on
    // the count for Sidebar.vue (project invariant: 1 file, 1 result).
    const project_root = "/home/ginwa/agentic_coding_zig/ginwaaitoolbox";

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "src/apps/desktop/src/**/Sidebar*.vue",
        .path = project_root,
    });
    defer result.deinit(allocator);

    // Count how many entries point to Sidebar.vue specifically.
    var sidebar_count: usize = 0;
    for (result.matches.items) |m| {
        if (std.mem.endsWith(u8, m.path, "/Sidebar.vue")) {
            sidebar_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), sidebar_count);
}
```

This test will fail on a sandbox/CI environment that doesn't have the project at that path. Mark it as a "local only" test if so (e.g. skip when `std.fs.cwd().access` of the path fails).

- [ ] **Step 3.5: Run the full test suite**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: All tests pass. New total = (old total + 3 from Chunk 1 + 4 from Chunk 3) = +7 tests.

- [ ] **Step 3.6: Commit the new tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/glob_test.zig
git commit -m "test(glob): add stay-green coverage for walkDir edge cases after duplicate-results fix"
```

---

## Verification (run at the end of every chunk)

```bash
# Backend (Zig) — full test suite
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 20

# Manual smoke test on port 8080 (NEVER 8081)
zig build install:linux:system 2>&1 | tail -n 5
./zig-out/bin/nalar --port 8080 &
NALAR_PID=$!
sleep 2

# Use the agent harness's glob tool (or call the Zig tool directly):
#   Pattern: src/apps/desktop/src/**/Sidebar*.vue
#   Expected: total="1" returned="1", one <f>Sidebar.vue</f> line
#   Previous (buggy): total="16" returned="16", 16 identical <f> lines

kill $NALAR_PID
```

Per the project's NALAR.md memory: `zig build test --summary all` is the authoritative check for backend code. No frontend changes are needed (this is backend-only), so `bun run build` is not required for this task.

---

## Pitfalls to watch for during execution

1. **Forgetting to free the `unconsumed` ArrayList** — the `defer unconsumed.deinit(allocator)` at the top of the `is_dir` block is essential. The `ArrayListUnmanaged` itself is stack-allocated; only the backing slice is heap. Zig's debug allocator will catch the leak, but it's a code-review red flag.

2. **Using `continue` inside the `for (regular_patterns.items)` loop** — Zig's `continue` in a `for` loop skips to the next iteration of the SAME for loop (not the outer if). I use it to mean "skip the prefix-aware logic for this pattern and add it to unconsumed" (via the early `if (isWildcardPattern) continue` block). The flow is: `continue` → fall through to `if (!consumed) unconsumed.append(...)` → loop again. This is intentional but non-obvious. Add a comment to make it clear.

3. **The `pat_idx > pat.len` boundary check** — line 715 in the original. The condition is `>`, not `>=`, because we incremented `pat_idx` by `slash_idx + 1` and want to allow exactly `pat.len` (one past the end, which is a valid "done" state). Get this wrong and the loop may iterate past the end or stop one segment early.

4. **The `pat[pat_idx + slash_idx - 1] != '*'` check** — line 707 in the original. The `-1` is correct (the last char of the matched segment). If the segment is `*` itself, the directory "matches" trivially and we don't need to recurse to find children (there's nothing to match). Get this wrong and we recurse into the directory looking for matches inside a pattern that's already been satisfied by the directory name itself.

5. **The `next_idx` calculation** — line 678. `pat_idx + slash_idx + 1` correctly points to the char AFTER the slash. If the slash is the last char of `pat` (e.g. trailing slash), then `next_idx == pat.len` and the `next_idx < pat.len` check fails, falling through to the "Pattern ends with the matched directory name" branch. This is the correct handling of trailing slashes.

6. **`readFileAlloc` is gone in Zig 0.16** — the `loadGitignoreForDir` function uses `std.Io.Dir.cwd().readFileAlloc(...)` (line 523) which is the new 0.16 API. If the project is using the older API, this will fail to compile. Verify by running the tests.

7. **Don't refactor the gitignore handling** — the gitignore code is correct (it loads `.gitignore` files at every directory and accumulates entries). The bug is purely in the recursion. Touching gitignore code "while you're in there" is a scope-creep risk. Per the project rule: surgical patches only.

8. **Test directory collisions in parallel runs** — `zig build test` runs tests in parallel. The `setupTempTree` helper uses a unique suffix to avoid `/tmp/glob_walkdir_test_X` collisions. Don't use a fixed path like `/tmp/glob_walkdir_test`.

9. **The `<f>path</f>` output ordering** — `toXmlSuccess` iterates `result.matches.items` in order. The fix preserves insertion order (we just don't insert duplicates), so the output order is stable. Don't add a "sort the results" step "for determinism" — it's a behavior change.

---

## Out of scope (deliberately)

- The `**/foo` semantics (the prefix-aware logic's broken handling of wildcard-first patterns) is fixed as a side effect of the wildcard check in Step 2.2. The behavior of `**/foo` is unchanged from the original intent (recursive); the fix just makes it actually work.
- The absolute-path-in-pattern case (`/tmp/...` patterns) appears to have a separate bug (returns 0 results instead of expected 1). That's a different issue and is NOT addressed by this plan.
- The gitignore `readFileAlloc` line uses `cwd()` regardless of whether the path is absolute — there may be a subtle bug there, but it's a separate issue and is NOT in scope.
- `walkDir`'s `path` parameter handling: `path = "/abs/path"` and `path = "rel/path"` may behave differently. Also out of scope.

These are tracked as future-work memories; if any of them affect the fix, the executor should surface them to the user rather than silently expanding scope.
