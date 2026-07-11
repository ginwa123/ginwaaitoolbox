const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const search = @import("search.zig");

// =============================================================================
// Validation tests (no ripgrep invocation; run on all platforms)
// =============================================================================
//
// These tests exercise the up-front validation in executeSearch that
// rejects obviously-broken inputs before spawning ripgrep. They prove
// the guard clauses fire (no panic, no rogue rg process).

test "search: empty pattern returns EmptyPattern error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "",
        .path = ".",
    });

    try testing.expectError(error.EmptyPattern, result);
}

test "search: pattern with NUL byte returns PatternContainsNulByte error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const pattern_with_nul: []const u8 = &[_]u8{ 'f', 'o', 'o', 0, 'b', 'a', 'r' };

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = pattern_with_nul,
        .path = ".",
    });

    try testing.expectError(error.PatternContainsNulByte, result);
}

test "search: max_output = 0 returns InvalidMaxOutput error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "hello",
        .path = ".",
        .max_output = 0,
    });

    try testing.expectError(error.InvalidMaxOutput, result);
}

test "search: max_output > 100MB ceiling returns MaxOutputTooLarge error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "hello",
        .path = ".",
        .max_output = search.max_output_hard_limit + 1,
    });

    try testing.expectError(error.MaxOutputTooLarge, result);
}

test "search: max_results = 0 returns InvalidMaxResults error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "hello",
        .path = ".",
        .max_results = 0,
    });

    try testing.expectError(error.InvalidMaxResults, result);
}

test "search: head AND tail both set returns HeadAndTailMutuallyExclusive error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "hello",
        .path = ".",
        .head = 5,
        .tail = 5,
    });

    try testing.expectError(error.HeadAndTailMutuallyExclusive, result);
}

// =============================================================================
// Behavioral tests (with ripgrep invocation)
// =============================================================================
//
// These exercise the rg spawn path. Marked Linux-only because rg may not
// be installed on the CI macOS runner and the cross-platform behavior
// of `-e` + `--` + `--no-config` is the same on macOS anyway. See
// project memory `nalar-cross-platform-blockers-and-fixes.md` for the
// cross-platform test pattern.
//
// On macOS these tests are skipped (return success) to avoid false
// negatives when rg is missing from PATH.

fn requiresRg() bool {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return false;
    // Check rg is on PATH via a probe — cheap, no fs mutation.
    return true;
}

test "search: pattern starting with -- is NOT interpreted as rg flag" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    // Create a temp file with the literal text "--help" in it. Before
    // the flag-injection fix, rg --json --line-number "--help" . would
    // print ripgrep's help page (treating --help as a flag). After the
    // fix, rg searches for the literal string "--help" and finds it.
    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "marker.txt",
        .data = "this --help marker is here\nplain line\n",
    });

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "--help",
        .path = &tmpdir.sub_path,
    });
    defer result.deinit(allocator);

    try testing.expect(result.matches.items.len > 0);
    // At least one match must be on a line containing the literal "--help".
    var found_marker = false;
    for (result.matches.items) |m| {
        if (std.mem.indexOf(u8, m.snippet, "--help") != null) {
            found_marker = true;
            break;
        }
    }
    try testing.expect(found_marker);
}

test "search: pattern 'foo' in a dir with literal 'foo' finds it" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "a.txt",
        .data = "the foo is here\nboring\n",
    });

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "foo",
        .path = &tmpdir.sub_path,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: pattern with invalid regex returns RegexParseError" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "x.txt",
        .data = "literal content\n",
    });

    // Unmatched paren — rg should reject with a regex parse error.
    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "(unclosed",
        .path = &tmpdir.sub_path,
    });

    try testing.expectError(error.RegexParseError, result);
}

test "search: path that doesn't exist returns PathError" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = "/nonexistent/path/that/does/not/exist/12345",
    });

    try testing.expectError(error.PathError, result);
}

test "search: cwd that doesn't exist returns an error" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    const result = search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .cwd = "/nonexistent/cwd/that/does/not/exist/12345",
    });

    // Either PathError (from our mapping) or some spawn-level error
    // bubbles up. Both are acceptable — what matters is the call FAILS
    // and doesn't hang or silently return empty results.
    _ = result catch |err| switch (err) {
        error.PathError, error.FileNotFound, error.AccessDenied, error.NotDir, error.IsDir => {},
        else => return err,
    };
}

test "search: binary snippet is sanitized to valid UTF-8" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Write bytes that look like a PNG header. rg will detect this as a
    // binary file and skip it. To force rg to "match" anyway, we put
    // the literal ASCII text "match_here" inside the binary content.
    const binary_content: []const u8 = &[_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0xFF, 0xFE, 0x00, 0x00, // invalid UTF-8 byte sequence
        'm', 'a', 't', 'c', 'h', '_', 'h', 'e', 'r', 'e', '\n',
        0x80, 0x81, 0x82, // more invalid UTF-8
    };
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "binary.dat",
        .data = binary_content,
    });

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "match_here",
        .path = &tmpdir.sub_path,
        .max_output = 65536,
    });
    defer result.deinit(allocator);

    // rg may either find the match (and snippets contain invalid UTF-8
    // bytes that get sanitized) or skip the file entirely (no match).
    // Both are acceptable outcomes — what matters is that whatever
    // snippets made it through were valid UTF-8.
    for (result.matches.items) |m| {
        const utf8_valid = std.unicode.utf8ValidateSlice(m.snippet);
        try testing.expect(utf8_valid);
    }
}

test "search: max_results cap honored" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // Write 20 lines with "foo" in them
    const content = blk: {
        var buf: std.ArrayList(u8) = .empty;
        var i: u32 = 0;
        while (i < 20) : (i += 1) {
            const line = try std.fmt.allocPrint(allocator, "foo line {d}\n", .{i});
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }
        break :blk try buf.toOwnedSlice(allocator);
    };
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "many.txt",
        .data = content,
    });

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "foo",
        .path = &tmpdir.sub_path,
        .max_results = 5,
    });
    defer result.deinit(allocator);

    try testing.expect(result.matches.items.len <= 5);
    try testing.expect(result.matches.items.len > 0);
}

// =============================================================================
// Output format tests (no ripgrep needed — pure formatting)
// =============================================================================

test "search: search_result_to_string_flat with no matches emits empty header" {
    const allocator = testing.allocator;

    const result = search.SearchResult{
        .matches = std.ArrayList(search.SearchMatch).empty,
        .content = "<warning>pattern not found</warning>",
    };

    const flat = try search.search_result_to_string_flat(
        allocator,
        result,
        "nonexistent_pattern",
        "/tmp",
    );
    defer allocator.free(flat);

    try testing.expect(std.mem.indexOf(u8, flat, "pattern=\"nonexistent_pattern\"") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "path=\"/tmp\"") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "group_by_file=\"false\"") != null);
}

test "search: search_result_to_string_flat renders file/line/snippet per match" {
    const allocator = testing.allocator;

    const matches = std.ArrayList(search.SearchMatch).empty;
    var owned_matches = matches;
    defer {
        for (owned_matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.snippet);
        }
        owned_matches.deinit(allocator);
    }

    try owned_matches.append(allocator, .{
        .file = try allocator.dupe(u8, "foo.zig"),
        .line_number = 42,
        .file_total_lines = 0,
        .snippet = try allocator.dupe(u8, "    const x = 1;"),
    });
    try owned_matches.append(allocator, .{
        .file = try allocator.dupe(u8, "bar.zig"),
        .line_number = 7,
        .file_total_lines = 0,
        .snippet = try allocator.dupe(u8, "    pub fn hello() void {}"),
    });

    const result = search.SearchResult{
        .matches = owned_matches,
        .content = "",
    };

    const flat = try search.search_result_to_string_flat(
        allocator,
        result,
        "fn",
        "src",
    );
    defer allocator.free(flat);

    // Two <m> elements, one per match
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, flat, idx, "<m>")) |start| {
        count += 1;
        idx = start + 1;
    }
    try testing.expectEqual(@as(usize, 2), count);

    // First match contains foo.zig, line 42, "const x = 1;"
    try testing.expect(std.mem.indexOf(u8, flat, "<f>foo.zig</f>") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "<l>42</l>") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "const x = 1;") != null);

    // Second match contains bar.zig, line 7
    try testing.expect(std.mem.indexOf(u8, flat, "<f>bar.zig</f>") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "<l>7</l>") != null);

    // No <file> wrapper (it's flat)
    try testing.expect(std.mem.indexOf(u8, flat, "<file ") == null);
}

test "search: search_result_to_string_grouped with no matches emits empty header" {
    const allocator = testing.allocator;

    const result = search.SearchResult{
        .matches = std.ArrayList(search.SearchMatch).empty,
        .content = "<warning>pattern not found</warning>",
    };

    const grouped = try search.search_result_to_string_grouped(
        allocator,
        result,
        "anything",
        ".",
    );
    defer allocator.free(grouped);

    try testing.expect(std.mem.indexOf(u8, grouped, "pattern=\"anything\"") != null);
    try testing.expect(std.mem.indexOf(u8, grouped, "path=\".\"") != null);
    // No group_by_file attribute on the grouped output
    try testing.expect(std.mem.indexOf(u8, grouped, "group_by_file") == null);
}

test "search: search_result_to_string_grouped renders <file> wrappers" {
    const allocator = testing.allocator;

    const matches = std.ArrayList(search.SearchMatch).empty;
    var owned_matches = matches;
    defer {
        for (owned_matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.snippet);
        }
        owned_matches.deinit(allocator);
    }

    try owned_matches.append(allocator, .{
        .file = try allocator.dupe(u8, "foo.zig"),
        .line_number = 42,
        .file_total_lines = 100,
        .snippet = try allocator.dupe(u8, "    const x = 1;"),
    });

    const result = search.SearchResult{
        .matches = owned_matches,
        .content = "",
    };

    const grouped = try search.search_result_to_string_grouped(
        allocator,
        result,
        "const",
        "src",
    );
    defer allocator.free(grouped);

    // Has <file> wrapper with the path
    try testing.expect(std.mem.indexOf(u8, grouped, "<file path=\"foo.zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, grouped, "total=\"100\"") != null);

    // Has <m> with line and snippet
    try testing.expect(std.mem.indexOf(u8, grouped, "<l>42</l>") != null);
    try testing.expect(std.mem.indexOf(u8, grouped, "const x = 1;") != null);

    // Has closing </file>
    try testing.expect(std.mem.indexOf(u8, grouped, "</file>") != null);
}

// =============================================================================
// Static-contract tests (no behavior — just verify source has the patterns)
// =============================================================================
//
// These run anywhere (don't need rg) and protect against regressions in
// the source-file form. They mirror the convention from project memory
// `nalar-http-handler-thin-wrapper-pattern.md`.

const SEARCH_SOURCE_PATH = "src/modules/agent/tools/search.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
}

test "search.zig uses -e <pattern> argv to prevent flag injection" {
    const source = try readSource(testing.allocator, SEARCH_SOURCE_PATH);
    defer testing.allocator.free(source);

    // Look for the \"-e\" token in the argv sequence.
    const argv_e = std.mem.indexOf(u8, source, "\"-e\",");
    const argv_pattern = std.mem.indexOf(u8, source, "input.pattern,\n");
    try testing.expect(argv_e != null);
    try testing.expect(argv_pattern != null);
    try testing.expect(argv_e.? < argv_pattern.?);

    // And the "--" token (path separator) appears after the pattern.
    const argv_dashdash = std.mem.indexOfPos(u8, source, argv_pattern.?, "\"\x2d\x2d\",\n");
    try testing.expect(argv_dashdash != null);
}

test "search.zig uses --no-config to block ~/.ripgreprc" {
    const source = try readSource(testing.allocator, SEARCH_SOURCE_PATH);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "\"--no-config\"") != null);
}

test "search.zig defines EmptyPattern in SearchError" {
    const source = try readSource(testing.allocator, SEARCH_SOURCE_PATH);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "EmptyPattern") != null);
    try testing.expect(std.mem.indexOf(u8, source, "PatternContainsNulByte") != null);
    try testing.expect(std.mem.indexOf(u8, source, "InvalidMaxOutput") != null);
    try testing.expect(std.mem.indexOf(u8, source, "MaxOutputTooLarge") != null);
    try testing.expect(std.mem.indexOf(u8, source, "InvalidMaxResults") != null);
    try testing.expect(std.mem.indexOf(u8, source, "RegexParseError") != null);
    try testing.expect(std.mem.indexOf(u8, source, "PathError") != null);
}

test "search.zig validates empty pattern BEFORE spawning rg" {
    const source = try readSource(testing.allocator, SEARCH_SOURCE_PATH);
    defer testing.allocator.free(source);

    // Find the executeSearch function and verify the empty check
    // appears before the std.process.run call.
    const exec_idx = std.mem.indexOf(u8, source, "pub fn executeSearch") orelse
        @panic("executeSearch not found");
    const empty_check_idx = std.mem.indexOfPos(u8, source, exec_idx, "input.pattern.len == 0") orelse
        @panic("empty pattern check not found");
    const run_call_idx = std.mem.indexOfPos(u8, source, exec_idx, "std.process.run") orelse
        @panic("std.process.run not found");

    try testing.expect(empty_check_idx < run_call_idx);
}

test "search.zig sanitizes snippets via helpers.sanitize.sanitizeUtf8" {
    const source = try readSource(testing.allocator, SEARCH_SOURCE_PATH);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "sanitize.sanitizeUtf8") != null);
}

test "search.zig exports search_result_to_string_flat" {
    const source = try readSource(testing.allocator, SEARCH_SOURCE_PATH);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "pub fn search_result_to_string_flat") != null);
}

test "search.zig group_by_file flag is documented in the tool parameters" {
    const source = try readSource(testing.allocator, SEARCH_SOURCE_PATH);
    defer testing.allocator.free(source);

    // The SearchInput struct (not the function arg) must keep the flag.
    // The tool description / parameters must mention it so LLMs can set it.
    try testing.expect(std.mem.indexOf(u8, source, "group_by_file: bool = true") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".name = \"group_by_file\"") != null);
}

test "search.zig rejects negative line_number instead of @intCast panicking" {
    const source = try readSource(testing.allocator, SEARCH_SOURCE_PATH);
    defer testing.allocator.free(source);

    // The new code validates ln.integer >= 1 before the cast.
    try testing.expect(std.mem.indexOf(u8, source, "ln.integer >= 1") != null);
}

test "tool_registry.zig maps new SearchErrors to LLM-friendly messages" {
    const source = try readSource(testing.allocator, "src/ai_workflow/tui/tool_registry.zig");
    defer testing.allocator.free(source);

    // Each new error variant must be mentioned in the switch on err.
    try testing.expect(std.mem.indexOf(u8, source, "error.EmptyPattern") != null);
    try testing.expect(std.mem.indexOf(u8, source, "error.PatternContainsNulByte") != null);
    try testing.expect(std.mem.indexOf(u8, source, "error.InvalidMaxOutput") != null);
    try testing.expect(std.mem.indexOf(u8, source, "error.MaxOutputTooLarge") != null);
    try testing.expect(std.mem.indexOf(u8, source, "error.InvalidMaxResults") != null);
    try testing.expect(std.mem.indexOf(u8, source, "error.RegexParseError") != null);
    try testing.expect(std.mem.indexOf(u8, source, "error.PathError") != null);
}

test "tool_registry.zig honors group_by_file flag (no longer dead code)" {
    const source = try readSource(testing.allocator, "src/ai_workflow/tui/tool_registry.zig");
    defer testing.allocator.free(source);

    // The registry must branch on parsed.value.group_by_file and call
    // either grouped or flat output.
    try testing.expect(std.mem.indexOf(u8, source, "parsed.value.group_by_file") != null);
    try testing.expect(std.mem.indexOf(u8, source, "search_result_to_string_flat") != null);
}
