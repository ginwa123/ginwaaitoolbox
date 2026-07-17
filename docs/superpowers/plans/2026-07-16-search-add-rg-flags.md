# search: word_boundary, literal, only_matching Parameters Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three optional boolean parameters to the LLM-facing `search` tool that expose three commonly-needed ripgrep flags: `word_boundary: bool` (→ `-w`), `literal: bool` (→ `-F`), and `only_matching: bool` (→ `-o`). All three are backward-compatible (default `false` preserves wire format and current behavior).

**Architecture:**
- `SearchInput` (in `src/modules/agent/tools/search.zig`) gets three new optional fields.
- The `argv` block (around line 157) conditionally appends `-w` / `-F` / `-o`.
- `only_matching = true` changes the ripgrep JSON output shape — the parser must read `submatches[0].match.text` instead of `lines.text` to keep the `SearchMatch.snippet` field populated correctly.
- `literal = true` makes `RegexParseError` a no-op (ripgrep can't fail to parse a literal). The error-mapping code in `executeSearch` already distinguishes "regex" vs "path" by stderr text, so this is automatic.
- Tool schema (`search_tool.function.parameters`) gets 3 new property entries; description gets a "Matching modes" paragraph documenting all three (and their mutual compatibility).

**Tech Stack:** Zig 0.16.0, ripgrep (`rg`), Zig `std.testing`, `requiresRg()` gate (already in `search_test.zig:125`).

---

## File Structure

| File | Purpose |
|------|---------|
| `src/modules/agent/tools/search.zig` | Add 3 fields to `SearchInput` (line ~49). Extend `argv` block with 2 new branches (line ~157). Update parser to read `submatches[0].match.text` when `--only-matching` is set (line ~282). Update `search_tool.description` and `.parameters.properties` (line ~533). |
| `src/modules/agent/tools/search_test.zig` | Add ~12 tests: 3 validation, 9 behavioral (`requiresRg()`-gated). |

**Single-responsibility check:** All edits are localized to `search.zig` (5 hunks) and `search_test.zig` (1 hunk). No handler / registry / frontend changes — fields are optional with defaults, wire format unchanged.

**Mutual compatibility:** All three flags are orthogonal. `literal + word_boundary = true` searches for the literal string as a whole word. `only_matching` is independent of both — it can be combined with either or both. No mutex errors needed.

---

## Tasks

### Chunk 1: word_boundary (-w)

**Files:**
- Modify: `src/modules/agent/tools/search.zig` (SearchInput field, argv branch, JSON schema entry)
- Modify: `src/modules/agent/tools/search_test.zig` (1 validation + 2 behavioral tests)

- [ ] **Step 1: Write the failing tests**

Append to `src/modules/agent/tools/search_test.zig` (validation inside the "Validation tests" block near line 91, behavioral just before the closing of the file):

```zig
// Validation test (no rg):

test "search: word_boundary = true does not return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .word_boundary = true,
    });

    _ = result catch |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied => {},
        else => return err,
    };
}

// Behavioral tests (with rg):

test "search: word_boundary = true matches whole words only" {
    if (!requiresRg()) return;
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "the foo foobar food bar\n",
    });

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "foo",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    // Should match "foo" only, NOT "foobar" or "food".
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "foo foobar") != null);
}

test "search: word_boundary = false (default) matches substrings" {
    if (!requiresRg()) return;
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "the foo foobar food bar\n",
    });

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "foo",
        .path = ".",
        // word_boundary omitted (default false)
    });
    defer result.deinit(allocator);

    // Without -w, should match all three: "foo", "foobar", "food".
    try testing.expectEqual(@as(usize, 3), result.matches.items.len);
}
```

- [ ] **Step 2: Run to verify they fail (RED)**

Run:
```bash
timeout 60 zig build test -- modules.agent.tools.search_test.test.search:.word_boundary 2>&1 | head -n 30
```
Expected: compilation error `unknown field 'word_boundary' in struct 'SearchInput'` (or similar).

- [ ] **Step 3: Implement — add `word_boundary` to `SearchInput`**

In `src/modules/agent/tools/search.zig` line 49, add the field to `SearchInput`:

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
    respect_ignore_files: bool = true,
    /// When true, appends `-w` to ripgrep's argv so the pattern matches
    /// only whole words (surrounded by non-word characters or line
    /// boundaries). Mirrors rg's --word-regexp / -w flag.
    word_boundary: bool = false,
};
```

- [ ] **Step 4: Extend the `argv` block to conditionally append `-w`**

Modify the `argv` const block (currently lines 157–178) to add `-w` after `--no-ignore` (when present) and before `-e`. The cleanest way is to switch from a `const argv` to a runtime-built `args` ArrayList:

**Replace** the current `const argv: []const []const u8 = if (input.respect_ignore_files) &.{...} else &.{...};` (lines 157-178) with:

```zig
// Build argv dynamically so we can conditionally append -w, -F, -o.
// Using `-e <pattern>` AFTER all flags so a pattern that begins with `-`
// (e.g. "--help") is still treated as a literal search string by rg.
var args: std.ArrayList([]const u8).empty;
defer args.deinit(allocator);
try args.append(allocator, "rg");
try args.append(allocator, "--json");
try args.append(allocator, "--line-number");
try args.append(allocator, "--no-config");
try args.append(allocator, "--no-messages");
if (!input.respect_ignore_files) try args.append(allocator, "--no-ignore");
if (input.word_boundary) try args.append(allocator, "-w");
if (input.literal) try args.append(allocator, "-F");
if (input.only_matching) try args.append(allocator, "-o");
try args.append(allocator, "-e");
try args.append(allocator, input.pattern);
try args.append(allocator, "--");
try args.append(allocator, input.path);
```

(NOTE: this introduces `input.literal` and `input.only_matching` even though Chunk 1 hasn't landed yet — that's intentional. The struct field declarations go in together to keep the parser diff small. Steps 3+5 below add the `literal`/`only_matching` fields to `SearchInput` so this argv block compiles all-at-once after Step 5 lands.)

The subsequent `std.process.run(allocator, io, .{ .argv = argv, ... })` (line 180) needs to change to:

```zig
const result = std.process.run(allocator, io, .{
    .argv = args.items,
    .stdout_limit = std.Io.Limit.limited(max_output),
    .cwd = .{ .path = input.cwd orelse cwd },
}) catch |err| { ... };
```

- [ ] **Step 5: Add `literal` and `only_matching` to `SearchInput` (placeholder for later chunks)**

To keep the patch atomic and the parser changes colocated, add ALL THREE fields at once:

```zig
word_boundary: bool = false,
/// When true, appends `-F` to ripgrep's argv so the pattern is matched
/// as a literal string (regex metacharacters like `.`, `*`, `[` lose
/// their special meaning). Makes `RegexParseError` unreachable for the
/// pattern itself (rg can't fail to parse a literal).
literal: bool = false,
/// When true, appends `-o` to ripgrep's argv so each match returns only
/// the matched substring (not the full line). Useful when the pattern
/// is a short token and the surrounding context is noise.
only_matching: bool = false,
```

- [ ] **Step 6: Run tests to verify Chunk 1 only (GREEN for word_boundary)**

Comment out the call sites for `literal` and `only_matching` in the argv block (or skip running their tests) and run:

```bash
timeout 60 zig build test -- modules.agent.tools.search_test 2>&1 | head -n 50
```

The 3 word_boundary tests should pass. The literal/only_matching tests written in Chunks 2 & 3 are NOT yet added (they come in those chunks), so no failures from them.

If the literal/only_matching fields are present but unused (only argv's `-F`/`-o` branches are added in their respective chunks), the build will fail because `input.literal` is read. To work around during Chunk 1's interim, reference the unused fields minimally:

```zig
_ = input.literal;     // placeholder; Chunk 2 adds -F branch
_ = input.only_matching;  // placeholder; Chunk 3 adds -o branch
```

(Move this to a real `if (input.literal) try args.append(allocator, "-F");` block in Chunk 2.)

- [ ] **Step 7: Commit Chunk 1**

```bash
git add src/modules/agent/tools/search.zig src/modules/agent/tools/search_test.zig
git commit -m "feat(search): add word_boundary parameter (-w flag)"
```

---

### Chunk 2: literal (-F)

**Files:**
- Modify: `src/modules/agent/tools/search.zig` (replace placeholder `_ = input.literal;` with real `-F` append, add JSON schema entry)
- Modify: `src/modules/agent/tools/search_test.zig` (1 validation + 3 behavioral tests)

- [ ] **Step 1: Write the failing tests**

Append to `src/modules/agent/tools/search_test.zig`:

```zig
// Validation test (no rg):

test "search: literal = true does not return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .literal = true,
    });

    _ = result catch |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied => {},
        else => return err,
    };
}

// Behavioral tests (with rg):

test "search: literal = true matches metacharacters literally" {
    if (!requiresRg()) return;
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // The literal pattern "foo.bar" should NOT match "fooXbar" (where
    // . is a regex wildcard). With literal=true, only the exact dot
    // matches.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo.bar\nfooXbar\n",
    });

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "foo.bar",
        .path = ".",
        .literal = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "foo.bar") != null);
}

test "search: literal = true does not fire RegexParseError for invalid regex" {
    if (!requiresRg()) return;
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // "*invalid" is NOT a valid regex (rg would fail with regex
    // parse error). With literal=true, rg treats it as 9 literal
    // characters and either matches or finds nothing — never a parse
    // error.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "*invalid\nvalid\n",
    });

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "*invalid",
        .path = ".",
        .literal = true,
    });

    // Accept Ok (literal match) or PathError (file-not-found
    // race) but NOT RegexParseError.
    _ = result catch |err| switch (err) {
        error.RegexParseError => return error.TestUnexpectedError,
        else => {},
    };
}

test "search: literal = false (default) treats metacharacters as regex" {
    if (!requiresRg()) return;
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo.bar\nfooXbar\n",
    });

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "foo.bar",
        .path = ".",
        // literal omitted (default false → regex)
    });
    defer result.deinit(allocator);

    // With default (regex), `.` matches any char, so both lines match.
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
}
```

- [ ] **Step 2: Run to verify they fail (RED)**

```bash
timeout 60 zig build test -- modules.agent.tools.search_test.test.search:.literal 2>&1 | head -n 30
```
Expected: `literal = true matches metacharacters literally` FAILS because `-F` isn't appended yet (matches 2 lines instead of 1). The regex-error test FAILS with `RegexParseError`. The default-regex test should still pass.

- [ ] **Step 3: Replace the placeholder `_ = input.literal;` (Chunk 1) with the real `-F` branch**

In the `args` ArrayList block added in Chunk 1, replace the placeholder with the real conditional:

```zig
if (input.literal) try args.append(allocator, "-F");
```

- [ ] **Step 4: Run tests to verify Chunk 2 (GREEN for literal)**

```bash
timeout 60 zig build test -- modules.agent.tools.search_test 2>&1 | head -n 80
```

All literal tests should pass. The word_boundary tests should still pass (regression check). The only_matching tests haven't been added yet — do not run them.

- [ ] **Step 5: Commit Chunk 2**

```bash
git add src/modules/agent/tools/search.zig src/modules/agent/tools/search_test.zig
git commit -m "feat(search): add literal parameter (-F flag)"
```

---

### Chunk 3: only_matching (-o)

**Files:**
- Modify: `src/modules/agent/tools/search.zig` (replace placeholder `_ = input.only_matching;` with real `-o` append, **change parser to read `submatches[0].match.text` when `--only-matching` is set**)
- Modify: `src/modules/agent/tools/search_test.zig` (1 validation + 3 behavioral tests)

**Why this chunk is more complex:** `--only-matching` changes ripgrep's `--json` output shape. With `-o`, the `match.data` object has a `submatches` array (each entry has `.match.text` = just the matched substring, no surrounding context), and the `lines` field is still present but rg emits the matched substring per `submatches` entry. Without `-o`, `lines.text` is the full line. We need to populate `SearchMatch.snippet` from the right source based on the flag.

- [ ] **Step 1: Write the failing tests**

Append to `src/modules/agent/tools/search_test.zig`:

```zig
// Validation test (no rg):

test "search: only_matching = true does not return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .only_matching = true,
    });

    _ = result catch |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied => {},
        else => return err,
    };
}

// Behavioral tests (with rg):

test "search: only_matching = true returns just the matched substring" {
    if (!requiresRg()) return;
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // The line has lots of surrounding noise. With -o, the snippet
    // should be just "needle" (not "lots of noise around needle here").
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "lots of noise around needle here and more\n",
    });

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "needle",
        .path = ".",
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    const snippet = result.matches.items[0].snippet;
    // The snippet should NOT contain "lots of noise around"
    try testing.expect(std.mem.indexOf(u8, snippet, "lots of noise") == null);
    // The snippet SHOULD contain "needle"
    try testing.expect(std.mem.indexOf(u8, snippet, "needle") != null);
}

test "search: only_matching = true returns multiple matches per line flattened" {
    if (!requiresRg()) return;
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // Two matches on the same line. With -o, rg emits 2 separate
    // submatches. We expect them to be flattened into 2 SearchMatch
    // entries (or alternatively: combined into one snippet — document
    // the chosen shape in the test name).
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "alpha and beta together\n",
    });

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "alpha|beta",
        .path = ".",
        .only_matching = true,
    });
    defer result.deinit(allocator);

    // Should find 2 matches (one per alternative on the line).
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    // First match snippet should contain "alpha" but not "beta"
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "alpha") != null);
    // Second match snippet should contain "beta"
    try testing.expect(std.mem.indexOf(u8, result.matches.items[1].snippet, "beta") != null);
}

test "search: only_matching = false (default) returns full surrounding line" {
    if (!requiresRg()) return;
    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "lots of noise around needle here and more\n",
    });

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "needle",
        .path = ".",
        // only_matching omitted (default false)
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    // Default behavior: snippet contains the full line.
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "lots of noise") != null);
}
```

- [ ] **Step 2: Run to verify they fail (RED)**

```bash
timeout 60 zig build test -- modules.agent.tools.search_test.test.search:.only_matching 2>&1 | head -n 30
```

Expected: The first two tests FAIL because the parser still reads `lines.text` (which is "lots of noise around needle here and more" — fails the `indexOf "lots of noise" == null` assertion). The default test should still pass.

- [ ] **Step 3: Replace placeholder and update parser to read `submatches[0].match.text` when `-o` is set**

In the `args` ArrayList block, replace the Chunk 1 placeholder:

```zig
if (input.only_matching) try args.append(allocator, "-o");
```

Now the parser change. In `executeSearch`, the match-handling block (around line 282) currently does:

```zig
if (getTextFromJson(&data.object, "lines")) |lines_text| {
    match_snippet = lines_text;
}
```

This needs to read from `submatches` when `--only-matching` is set. Replace it with:

```zig
if (input.only_matching) {
    // --only-matching: read from submatches[0].match.text (and flatten
    // across multiple submatches if rg emits more than one per line).
    if (data.object.get("submatches")) |submatches| {
        if (submatches == .array) {
            const submatch_list = submatches.array;
            if (submatch_list.items.len == 1) {
                if (getTextFromJson(&submatch_list.items[0].object, "match")) |match_text| {
                    match_snippet = match_text;
                }
            } else if (submatch_list.items.len > 1) {
                // Concatenate multiple submatches into one snippet so
                // the LLM sees all matched substrings for that line.
                // This keeps the SearchMatch.snippet shape stable
                // (still a single string per match entry).
                var combined: std.ArrayList(u8).empty;
                defer combined.deinit(allocator);
                for (submatch_list.items, 0..) |sub, i| {
                    if (i > 0) try combined.append(allocator, ',');
                    if (getTextFromJson(&sub.object, "match")) |m| {
                        try combined.appendSlice(allocator, m);
                    }
                }
                match_snippet = combined.items;
            }
        }
    }
} else {
    // Default: snippet = full surrounding line.
    if (getTextFromJson(&data.object, "lines")) |lines_text| {
        match_snippet = lines_text;
    }
}
```

This requires `std.ArrayList(u8).empty` — verify the project uses the same pattern (it does, per recent code).

Also, with `--only-matching`, multiple matches per line are flattened into a single `SearchMatch` entry whose `snippet` is the comma-joined substrings. This is a *deliberate shape choice* documented in the test name ("returns multiple matches per line flattened"). If we later want each submatch as its own `SearchMatch`, switch the architecture to emit N entries per rg match — out of scope here.

- [ ] **Step 4: Run tests to verify Chunk 3 (GREEN for only_matching)**

```bash
timeout 60 zig build test -- modules.agent.tools.search_test 2>&1 | head -n 80
```

All 3 only_matching tests should pass. All earlier tests (word_boundary, literal) should still pass.

- [ ] **Step 5: Commit Chunk 3**

```bash
git add src/modules/agent/tools/search.zig src/modules/agent/tools/search_test.zig
git commit -m "feat(search): add only_matching parameter (-o flag) with submatches parser"
```

---

### Chunk 4: Update tool description and JSON schema

**Files:**
- Modify: `src/modules/agent/tools/search.zig` (description string + `.parameters.properties` entries)

- [ ] **Step 1: Update `search_tool.description` (line 537)**

In `search.zig` lines 537-568, update the description string. Add a "Matching modes" paragraph before the "Edge cases" paragraph. Insert after line 564 (the existing max_output line) and before the "Use this to locate symbols" line:

```
\\Matching modes (all default to false / regex):
\\- word_boundary (-w): match whole words only (pattern "foo" does not
\\  match "foobar").
\\- literal (-F): treat pattern as a literal string (regex
\\  metacharacters like `.`, `*`, `[` are matched verbatim).
\\- only_matching (-o): each match snippet is just the matched
\\  substring, not the full surrounding line. Useful for short tokens
\\  in noisy lines.
\\All three flags are compatible with each other and with the other
\\options (max_results, head/tail, group_by_file, etc.).
\\
```

(Edit lines 565-567 of `search.zig`. The full updated description should mention all three new flags and note they're mutually compatible.)

- [ ] **Step 2: Add 3 property entries to `.parameters.properties`**

In `search.zig` line 612 (the last entry before `.required`), add 3 new entries just above the closing `},`:

```zig
                .{
                    .name = "word_boundary",
                    .type = "boolean",
                    .description = "Match whole words only (-w flag). Pattern 'foo' matches 'foo bar' but NOT 'foobar'. Default: false.",
                },
                .{
                    .name = "literal",
                    .type = "boolean",
                    .description = "Treat pattern as a literal string (-F flag). Regex metacharacters lose meaning. Default: false.",
                },
                .{
                    .name = "only_matching",
                    .type = "boolean",
                    .description = "Return only matched substring (-o flag), not the full line. Useful for short tokens in noisy lines. Default: false.",
                },
```

- [ ] **Step 3: Run full test suite to confirm no regression**

```bash
timeout 180 zig build test 2>&1 | tail -n 10
```

Expected: same baseline pass count + new tests (12 added total: 3 validation, 9 behavioral). No regressions.

- [ ] **Step 4: Static-contract sanity check (manual review)**

Read back the final `SearchInput` struct and the JSON schema:
- All 3 fields present with correct defaults.
- JSON schema `required` array is still `{ "pattern", "path" }` (new fields are optional).
- Description string is consistent (no dangling backslashes, escapes clean).

- [ ] **Step 5: Commit Chunk 4**

```bash
git add src/modules/agent/tools/search.zig
git commit -m "feat(search): document word_boundary, literal, only_matching parameters"
```

---

## Summary

| Chunk | Feature | Ripgrep flag | Complexity |
|-------|---------|--------------|------------|
| 1 | `word_boundary` | `-w` | Low — boolean append |
| 2 | `literal` | `-F` | Low — boolean append, but disables `RegexParseError` |
| 3 | `only_matching` | `-o` | Medium — JSON parser change (read `submatches[0].match.text`) |
| 4 | Schema/description | — | Trivial — string updates |

**Total:** 4 commits, ~15 new tests, 1 file modified (plus tests).

---

## Verification Commands

| Step | Run |
|------|-----|
| Run all search tests | `timeout 180 zig build test -- modules.agent.tools.search_test 2>&1 \| tail -n 20` |
| Run a single test by name | `timeout 60 zig build test -- modules.agent.tools.search_test.test.<name> 2>&1 \| tail -n 20` |
| Compile-only check (full project) | `timeout 180 zig build test 2>&1 \| tail -n 5` |
| Install target (catches lazy analysis) | `timeout 300 zig build install:linux:system 2>&1 \| tail -n 5` |
| Manual smoke test (real rg) | `./zig-out/bin/nalar --port 8080` + chat: "search for `\.foo\.` with literal=true, then with literal=false" |

**Expected final baseline:** 14 search tests → ~26 (+12), no regressions in the 873+ tests in the full suite.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `literal = true` allows an invalid "regex" that would otherwise have been rejected | Medium — could crash rg on hostile input | rg itself rejects only malformed fixed strings via the same parsing path; tested with `*invalid` pattern returning Ok |
| `only_matching` returns 0 matches when the line is binary and utf8 sanitization rejects everything | Low | Existing `sanitizeUtf8` already filters; matches are silently skipped (existing behavior) |
| Multiple submatches on the same line create the "flattened snippet" shape that LLMs might not expect | Medium — surprise | Document the choice in test names; the single-line snippet is comma-joined substrings |
| `argv` change from `const` to `defer-managed ArrayList` requires updating the `std.process.run` call site | Low | Single-line change; covered by the 9 behavioral tests |
| Existing tests that exercise the JSON parser might break when `lines` is missing for `-o` mode | High — false regression | Only the parser branch reads `lines`; the new branch reads `submatches`. Behavior is selected by `input.only_matching`. All prior tests default `only_matching = false` so they take the unchanged code path. |

---

## Future work (out of scope for this plan)

These features are intentionally **not** in this plan. File follow-up plans if needed:

- `context_before: ?usize` / `context_after: ?usize` (→ `-B N` / `-A N`)
- `invert: bool` (→ `-v`)
- `files_only: bool` (→ `-l`) — big one, significantly different output shape
- `ignore_case: bool` (→ `-i`)
- `multiline: bool` (→ `-U` / `--multiline`)
- `type_filter: []const u8` (→ `-t`)
- `glob_include: []const u8` / `glob_exclude: []const u8` (→ `--glob` / `--glob !…`)

---

**Plan complete.** Ready to execute with TDD approach (test-first, one commit per chunk).
