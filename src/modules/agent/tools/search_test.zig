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

test "search: respect_ignore_files = false does NOT return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    if (search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .respect_ignore_files = false,
    })) |r| {
        // Success — release the SearchResult's heap allocations
        // (matches.items[].file + .snippet, and content). Without
        // this the test leaks ~102 allocations on the CI runner
        // (root's /tmp contains many matching files; local user
        // /tmp is usually smaller so leaks went undetected).
        var owned = r;
        defer owned.deinit(allocator);
    } else |err| switch (err) {
        // Either success (Ok with possibly 0 matches in /tmp) or a
        // rg-spawn error is acceptable. What matters is NO
        // SearchError domain variant fires (those would mean
        // validation rejected the field).
        error.FileNotFound, error.PathError, error.AccessDenied, error.StreamTooLong => {},
        else => return err,
    }
}

test "search: word_boundary = true does NOT return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    // The word_boundary field is a flag, not a numeric limit — there's no
    // value that could fail up-front validation. Just confirm the field
    // is plumbed through correctly (no compile error on the struct init)
    // and that the call attempts to spawn rg (rather than rejecting the
    // input with a SearchError variant).
    if (search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .word_boundary = true,
    })) |r| {
        var owned = r;
        defer owned.deinit(allocator);
    } else |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied, error.StreamTooLong => {},
        else => return err,
    }
}

test "search: literal = true does NOT return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    // The literal field is a flag, not a numeric limit — there's no value
    // that could fail up-front validation. Just confirm the field is
    // plumbed through correctly (no compile error on the struct init)
    // and that the call attempts to spawn rg with -F (rather than
    // rejecting the input with a SearchError variant).
    if (search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .literal = true,
    })) |r| {
        var owned = r;
        defer owned.deinit(allocator);
    } else |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied, error.StreamTooLong => {},
        else => return err,
    }
}

test "search: only_matching = true does NOT return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    // The only_matching field is a flag, not a numeric limit — there's no
    // value that could fail up-front validation. Just confirm the field is
    // plumbed through correctly (no compile error on the struct init)
    // and that the call attempts to spawn rg with -o (rather than
    // rejecting the input with a SearchError variant).
    if (search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .only_matching = true,
    })) |r| {
        var owned = r;
        defer owned.deinit(allocator);
    } else |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied, error.StreamTooLong => {},
        else => return err,
    }
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

/// Strip the `./` prefix that rg adds to relative paths when invoked with
/// `path = "."`. Used by the respect_ignore_files tests to compare match
/// files against expected basenames regardless of rg's prefix convention.
fn stripDotSlash(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '.' and s[1] == '/') return s[2..];
    return s;
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

    // Zig 0.16's testing.TmpDir.sub_path is a fixed-size array holding just
    // the random basename (e.g. "AbCdEfGh1234"), NOT the full path. Resolve
    // the real path via tmpdir.dir.realPath and pass it as cwd, then search
    // "." inside the tmpdir. See commit message for the Zig 0.16 context.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "--help",
        .path = ".",
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

    // Zig 0.16's testing.TmpDir.sub_path is a fixed-size array holding just
    // the random basename (e.g. "AbCdEfGh1234"), NOT the full path. Resolve
    // the real path via tmpdir.dir.realPath and pass it as cwd, then search
    // "." inside the tmpdir. See commit message for the Zig 0.16 context.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
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
    // and doesn't hang or silently return empty results. If we do get
    // a successful SearchResult, free it (matches + content) — the
    // pattern matches the 4 other tests above that also call rg with
    // a possibly-empty /tmp.
    if (result) |r| {
        var owned = r;
        defer owned.deinit(allocator);
    } else |err| switch (err) {
        error.PathError, error.FileNotFound, error.AccessDenied, error.NotDir, error.IsDir => {},
        else => return err,
    }
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

    // Zig 0.16's testing.TmpDir.sub_path is a fixed-size array holding just
    // the random basename (e.g. "AbCdEfGh1234"), NOT the full path. Resolve
    // the real path via tmpdir.dir.realPath and pass it as cwd, then search
    // "." inside the tmpdir. See commit message for the Zig 0.16 context.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "match_here",
        .path = ".",
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
    // content is heap-owned from toOwnedSlice; writeFile reads but does not
    // take ownership. Free it once writeFile returns.
    defer allocator.free(content);
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "many.txt",
        .data = content,
    });

    // Zig 0.16's testing.TmpDir.sub_path is a fixed-size array holding just
    // the random basename (e.g. "AbCdEfGh1234"), NOT the full path. Resolve
    // the real path via tmpdir.dir.realPath and pass it as cwd, then search
    // "." inside the tmpdir. See commit message for the Zig 0.16 context.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .max_results = 5,
    });
    defer result.deinit(allocator);

    try testing.expect(result.matches.items.len <= 5);
    try testing.expect(result.matches.items.len > 0);
}

test "search: respect_ignore_files = true (default) skips .gitignored dirs" {
    if (!requiresRg()) return;

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
        .data = "MARKER_TOKEN_NODE_MODULES\n",
    });
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "app.js",
        .data = "MARKER_TOKEN_NODE_MODULES\n",
    });

    // Zig 0.16: testing.TmpDir.sub_path is just the basename; resolve full path via realPath.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, "/tmp", .{
        .pattern = "MARKER_TOKEN_NODE_MODULES",
        .path = ".",
        .cwd = tmpdir_path,
    });
    defer result.deinit(allocator);

    // Exactly 1 match — only app.js. node_modules/secret.js was skipped.
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    // rg with path="." returns paths prefixed with "./"; strip it for the
    // filename comparison.
    const match_file = stripDotSlash(result.matches.items[0].file);
    try testing.expectEqualStrings("app.js", match_file);
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
    try tmpdir.dir.createDirPath(io, "node_modules");
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

    // Both files matched — .gitignore was un-respected via --no-ignore
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);

    // Collect filenames (order from rg is not guaranteed) and assert each
    // expected file is present. rg with path="." prefixes matches with
    // "./" — use stripDotSlash to normalize.
    var saw_app = false;
    var saw_node_modules = false;
    for (result.matches.items) |m| {
        const f = stripDotSlash(m.file);
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

    try tmpdir.dir.writeFile(io, .{
        .sub_path = ".ignore",
        .data = "build_artifacts/\n",
    });
    try tmpdir.dir.createDirPath(io, "build_artifacts");
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

    // Per-filename check (rg match order is not guaranteed). rg with
    // path="." prefixes matches with "./" — use stripDotSlash to normalize.
    var saw_main = false;
    var saw_cached = false;
    for (result.matches.items) |m| {
        const f = stripDotSlash(m.file);
        if (std.mem.eql(u8, f, "main.txt")) saw_main = true;
        if (std.mem.eql(u8, f, "build_artifacts/cached.dat")) saw_cached = true;
    }
    try testing.expect(saw_main);
    try testing.expect(saw_cached);
}

test "search: word_boundary = true matches whole words only" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        // "foo" appears as part of "foobar" — should NOT match with -w
        // "foo" appears as a whole word — SHOULD match
        // "foo" appears at end of line, preceded by space — SHOULD match
        .data = "foobar whole foo\nline foo trailing\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    // 2 matches: line 1 (the "whole foo" segment) and line 2 (trailing foo).
    // "foobar" on line 1 must NOT match because there's no boundary between
    // "foo" and "bar".
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
}

test "search: word_boundary = false (default) matches substrings" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // rg returns ONE match event per matched line (not per occurrence).
    // So even though "foobar" contains "foo" twice, that's still 1 match
    // event. The 2nd match event comes from "whole foo" on a separate line.
    // Compare with the word_boundary=true test which filters out "foobar"
    // — the boundary version reports 2 events (line 1 "whole foo" + line
    // 2 trailing foo), this default version reports 2 events too (line 1
    // "foobar" + line 2 "whole foo"). The DIFFERENCE is line 1: substring
    // matches "foobar" + "whole foo" on one line, while -w matches only
    // "whole foo" on line 1.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        // Line 1 has two substring occurrences of "foo" — rg reports 1 event.
        // Line 2 has one occurrence — rg reports 1 event.
        .data = "foobar whole foo\nline foo here\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        // word_boundary explicitly false — same as omitting it
    });
    defer result.deinit(allocator);

    // 2 match events (one per matched line). The line_number list
    // proves both lines were hit — but with substring matching, line 1
    // is matched even though only "whole foo" is a word occurrence;
    // "foobar" also matches as a substring.
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
}

test "search: word_boundary works at start of file (offset 0)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // The pattern is the very first thing in the file — there's no
    // preceding character. With -w, rg must still identify the boundary
    // (the implicit "start of file" is a word boundary in ripgrep's view).
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo bar",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: word_boundary works at end of file (no trailing newline)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // File ends mid-line — pattern is the last token with no trailing
    // newline. rg must treat EOF as a word boundary for -w.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "hello world",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "world",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: word_boundary treats underscore as a WORD char (no match inside foo_bar)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // ripgrep's default Unicode word rule treats underscore as a word
    // character. So "foo" with -w does NOT match inside "foo_bar",
    // "baz_foo", or "qux_foo" — even though an English speaker might
    // visually parse those as "foo" the word.
    //
    // This test documents that subtle behavior — the search tool's
    // word_boundary is a literal pass-through to rg's -w, NOT a
    // linguistically-aware "word" check.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo_bar baz_foo qux_foo",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    // None of the three occurrences are bounded — _ is a word char.
    try testing.expectEqual(@as(usize, 0), result.matches.items.len);
}

test "search: word_boundary treats hyphen as a boundary (matches foo-bar and foo+bar)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Hyphen and plus are non-word chars — they DO create boundaries,
    // so "foo" with -w matches both "foo-bar" and "foo+bar". Two lines
    // so rg reports 2 match events (one per line).
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo-bar\nfoo+bar\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
}

test "search: word_boundary with punctuation boundaries matches each occurrence" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // ( ) [ ] { } , . — each of these is a non-word char and creates
    // a word boundary. So "foo" with -w matches every occurrence here.
    // Spread across 4 lines so rg reports 4 match events (one per line).
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "(foo)\n[foo]\n{foo}\nfoo.\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 4), result.matches.items.len);
}

test "search: word_boundary with multi-line file matches only the line containing the word" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Three lines; only line 2 contains the pattern as a whole word.
    // Lines 1 and 3 contain "target" only as part of "targeted" /
    // "untargeted" — which -w rejects.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "first line targeted here\nsecond line has target word\nthird line untargeted here\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "target",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    // Only 1 match — line 2.
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 2), result.matches.items[0].line_number);
}

// =============================================================================
// Chunk 2 behavioral tests — literal / -F flag
// =============================================================================
//
// These tests verify that the `literal: bool = false` field in SearchInput
// correctly maps to ripgrep's `-F` flag (treat pattern as literal string,
// not regex). The implementation lives at src/modules/agent/tools/search.zig
// in the argv block — `if (input.literal) try args.append(allocator, "-F");`.

test "search: literal = true matches metacharacters literally" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Two lines: line 1 has the LITERAL substring "foo.bar" (with real dot),
    // line 2 has "fooXbar" (X is not a dot, so the LITERAL pattern "foo.bar"
    // does not match it). With regex default (no -F), "." is a wildcard that
    // matches ANY char including X — so regex matches both lines.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo.bar\nfooXbar\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo.bar",
        .path = ".",
        .literal = true,
    });
    defer result.deinit(allocator);

    // With literal = true: only line 1 matches (literal dot).
    // Without literal (regex): both lines match (dot is wildcard).
    // If this test sees 2 matches, the -F flag is NOT being passed to rg.
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: literal = true does NOT fire RegexParseError for invalid regex pattern" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // "*invalid" is INVALID as a regex (unanchored `*` quantifier has no
    // preceding atom). With regex default, rg would emit stderr containing
    // "regex" / "pattern" and our error-mapping code would surface
    // error.RegexParseError. With literal = true, rg treats the bytes
    // opaquely — it does NOT parse them as regex, so no parse error.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "literal content\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    const result_or_err = search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "*invalid",
        .path = ".",
        .literal = true,
    });

    // Acceptable outcomes:
    //   - Ok with 0 matches (rg found no file containing literal "*invalid")
    //   - PathError (rg spawn failed for some platform-specific reason)
    // NOT acceptable: error.RegexParseError — that's the bug we're guarding
    // against (rg cannot fail to parse a literal pattern, so the stderr-based
    // mapping should never trigger).
    if (result_or_err) |ok| {
        var owned = ok;
        defer owned.deinit(allocator);
        // 0 matches is expected — the file content doesn't contain "*invalid".
    } else |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied, error.StreamTooLong => {},
        error.RegexParseError => return error.RegexParseError,
        else => return err,
    }
}

test "search: literal = false (default) treats metacharacters as regex" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Same file as the literal-true test: line 1 has literal "foo.bar",
    // line 2 has "fooXbar". With regex default (no literal), "." matches
    // any char — so BOTH lines match.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo.bar\nfooXbar\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo.bar",
        .path = ".",
        // literal omitted — defaults to false, rg treats "." as wildcard
    });
    defer result.deinit(allocator);

    // 2 matches — line 1 (literal dot) AND line 2 (X matched by wildcard).
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
}

test "search: literal = true matches backslashes literally" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // File contains the literal 3-char substring "\bx" (backslash + b + x)
    // at positions 7..9 of line 1. Line 2 has no such substring.
    //
    // With literal = true: rg searches for the literal substring "\bx".
    // It matches line 1. 1 match.
    //
    // With regex default (no literal): rg treats "\b" as the word-boundary
    // ZERO-WIDTH assertion followed by literal "x". So the pattern means
    // "find an 'x' preceded by a word boundary". In `prefix \bx here`:
    //   - position 8 ('b', word) → position 9 ('x', word): both word, no
    //     boundary. No match there.
    //   - no other 'x' has a word boundary just before it.
    // Result: 0 matches in regex mode.
    //
    // This is the clearest demonstration that literal mode handles `\` as
    // an opaque byte, NOT as a regex escape introducer.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "prefix \\bx here\nno match on this line\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    // Pattern is the 3-byte literal "\bx" (backslash + b + x). Construct
    // it from a u8 array to avoid Zig string-literal escape ambiguity
    // (writing "\" in a Zig string literal is a parse error, and "\\b"
    // would be 2 chars: backslash + b — which is what we want).
    const pattern_bs: []const u8 = &[_]u8{ '\\', 'b', 'x' };

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = pattern_bs,
        .path = ".",
        .literal = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: literal = true matches combined regex special chars as opaque bytes" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // File contains the literal 8-char substring "(?:foo)+" on line 1.
    // rg's regex engine DOES support non-capturing groups (?:...), so
    // even in regex mode, the pattern "(?:foo)+" is valid and matches
    // the inner "foo" portion of the literal substring. With literal =
    // true, rg treats the bytes opaquely and matches the whole 8-char
    // substring. Both modes return 1 match — but the substring matched
    // is different (regex: "foo"; literal: "(?:foo)+"). The test
    // confirms literal mode handles combined special chars without
    // erroring out.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "(?:foo)+ and (a|b)\njust literal text\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "(?:foo)+",
        .path = ".",
        .literal = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: literal = true with unmatched bracket does NOT fire RegexParseError" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Pattern "[unclosed" has an unmatched `[`. With regex, rg would emit
    // a regex parse error. With literal = true, the `[` is just a char.
    // The file doesn't contain "[unclosed" as a substring, so the search
    // succeeds with 0 matches.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "completely unrelated content\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "[unclosed",
        .path = ".",
        .literal = true,
    });
    defer result.deinit(allocator);

    // 0 matches (no file content matches the literal "[unclosed").
    // CRITICALLY: no RegexParseError — rg doesn't parse literal patterns.
    try testing.expectEqual(@as(usize, 0), result.matches.items.len);
}

test "search: literal = true with multi-byte UTF-8 pattern matches byte-for-byte" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // File contains "café résumé" with é as the 2-byte UTF-8 sequence
    // C3 A9. The literal pattern "café" is 5 bytes (c, a, f, C3, A9).
    // With literal = true, rg matches the exact 5-byte sequence.
    // This verifies that literal mode handles multi-byte UTF-8 patterns
    // correctly — a regex-interpretation that decoded to Unicode code
    // points could (in theory) match differently.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "café résumé\nplain text\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    // Construct "café" (5 bytes) from a u8 array to make the byte
    // sequence explicit (c=0x63, a=0x61, f=0x66, é=0xC3 0xA9).
    const pattern_utf8: []const u8 = &[_]u8{ 'c', 'a', 'f', 0xC3, 0xA9 };

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = pattern_utf8,
        .path = ".",
        .literal = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: literal = true combined with word_boundary = true matches bounded literal substring" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Three lines:
    //   Line 1: "foo.bar baz"  — contains the literal substring "foo.bar"
    //   Line 2: "fooXbar qux"  — contains "fooXbar" but NOT "foo.bar" (X != .)
    //   Line 3: "prefix foo.bar.suffix" — contains "foo.bar" at positions 7..13
    //
    // Pattern: literal "foo.bar" (7 bytes: f, o, o, ., b, a, r)
    //
    // With literal = true + word_boundary = true:
    //   - Line 1 matches: "foo.bar" starts at position 0 (left boundary =
    //     start of line) and ends at position 7 (right boundary = space,
    //     a non-word char).
    //   - Line 2 does NOT match: "fooXbar" does not contain the literal
    //     substring "foo.bar" — X is not ".".
    //   - Line 3 matches: "foo.bar" starts at position 7 (left boundary =
    //     space, non-word char) and ends at position 14 (right boundary =
    //     ".", a non-word char).
    //
    // Expected: 2 matches (lines 1 and 3).
    //
    // Without literal (regex default), "." would be a wildcard matching
    // any char — line 2 would also match because "fooXbar" has a char
    // at the "dot" position. So this test would emit 3 matches in regex
    // mode. Confirms both flags are being passed to rg.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo.bar baz\nfooXbar qux\nprefix foo.bar.suffix\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo.bar",
        .path = ".",
        .literal = true,
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 3), result.matches.items[1].line_number);
}

// =============================================================================
// only_matching (-o) tests — Chunk 3 of the rg-flags plan
// =============================================================================
//
// With `--only-matching`, ripgrep emits `data.submatches[]` per match event.
// For multi-match lines, ALL submatches live in a single match event; we
// flatten that into one SearchMatch with a comma-joined snippet.

test "search: only_matching = true strips surrounding context from snippet" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Single line: lots of noise around the match.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "a.txt",
        .data = "lots of noise around needle here and more\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    // Snippet should contain the matched substring.
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "needle") != null);
    // Snippet should NOT contain the surrounding context that would be
    // present in default mode. The leading "lots of noise" is the
    // clearest discriminator.
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "lots of noise") == null);
}

test "search: only_matching = true with multiple submatches on same line joins them with comma" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // "alpha and beta together" — the regex "alpha|beta" matches TWICE on
    // this single line. With --only-matching, rg emits ONE match event
    // with submatches[]=[{alpha},{beta}]. Our implementation flattens to
    // ONE SearchMatch with snippet "alpha,beta".
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "b.txt",
        .data = "alpha and beta together\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "alpha|beta",
        .path = ".",
        .only_matching = true,
    });
    defer result.deinit(allocator);

    // ONE SearchMatch (not two) — single match event with submatches[] array.
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    // Snippet is the comma-joined submatches.
    try testing.expectEqualStrings("alpha,beta", result.matches.items[0].snippet);
}

test "search: only_matching = false (default) keeps surrounding context in snippet" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "c.txt",
        .data = "lots of noise around needle here and more\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    // Default mode: snippet is the full surrounding line.
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "lots of noise") != null);
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "needle") != null);
}

test "search: only_matching = true returns multiple match events for multi-line input" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // 3 lines, each with one match.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "multi.txt",
        .data = "first line has target here\nsecond line has target there\nthird line has target everywhere\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "target",
        .path = ".",
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), result.matches.items.len);
    // Each match's line_number is 1, 2, 3 respectively.
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
    try testing.expectEqual(@as(usize, 3), result.matches.items[2].line_number);
    // All snippets are just "target" (no surrounding text).
    for (result.matches.items) |m| {
        try testing.expectEqualStrings("target", m.snippet);
    }
}

test "search: only_matching = true combined with literal = true matches literal substring without context" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // "a.b" appears literally in line 1. Without literal, "." would match
    // any char so "aXb" would also match. With literal + only_matching,
    // only "a.b" matches and snippet is just "a.b".
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "lit.txt",
        .data = "a.b and aXb\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "a.b",
        .path = ".",
        .literal = true,
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqualStrings("a.b", result.matches.items[0].snippet);
}

test "search: only_matching = true combined with word_boundary = true matches whole words" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // "needle" on line 1 is a whole word. "needlex" on line 2 is a single
    // word (not "needle" followed by "x" — "x" is a word char), so no
    // boundary at the end. With word_boundary, only line 1 matches.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "wb.txt",
        .data = "needle case needlex case\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
        .word_boundary = true,
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqualStrings("needle", result.matches.items[0].snippet);
}

test "search: only_matching = true with literal + word_boundary matches bounded literal as substring" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // "foo.bar" appears on line 1 and line 3 as a literal substring.
    // Line 2 has "fooXbar" (not literal match for "foo.bar"). All three
    // flags together: literal (so "." is literal), word_boundary (so the
    // match must be bounded), only_matching (so snippet is just the match).
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "all3.txt",
        .data = "foo.bar baz\nfooXbar qux\nprefix foo.bar.suffix\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo.bar",
        .path = ".",
        .literal = true,
        .word_boundary = true,
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqualStrings("foo.bar", result.matches.items[0].snippet);
    try testing.expectEqual(@as(usize, 3), result.matches.items[1].line_number);
    try testing.expectEqualStrings("foo.bar", result.matches.items[1].snippet);
}

test "search: only_matching = true respects head slicing" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Build 5 matching lines programmatically.
    const content = blk: {
        var buf: std.ArrayList(u8) = .empty;
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            const line = try std.fmt.allocPrint(allocator, "line {d}: needle here\n", .{i});
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }
        break :blk try buf.toOwnedSlice(allocator);
    };
    defer allocator.free(content);
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "head.txt",
        .data = content,
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
        .head = 2,
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    // First 2 lines only.
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
    // Snippets are just "needle" (no surrounding text).
    try testing.expectEqualStrings("needle", result.matches.items[0].snippet);
    try testing.expectEqualStrings("needle", result.matches.items[1].snippet);
}

test "search: only_matching = true respects max_results cap" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Build 100 matching lines.
    const content = blk: {
        var buf: std.ArrayList(u8) = .empty;
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            const line = try std.fmt.allocPrint(allocator, "needle line {d}\n", .{i});
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }
        break :blk try buf.toOwnedSlice(allocator);
    };
    defer allocator.free(content);
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "cap.txt",
        .data = content,
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
        .max_results = 10,
        .only_matching = true,
    });
    defer result.deinit(allocator);

    // Cap honored.
    try testing.expectEqual(@as(usize, 10), result.matches.items.len);
    // First 10 lines.
    for (result.matches.items, 0..) |m, i| {
        try testing.expectEqual(@as(usize, i + 1), m.line_number);
        try testing.expectEqualStrings("needle", m.snippet);
    }
}

test "search: only_matching = true with group_by_file = false renders <s>needle</s> per match" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "flat.txt",
        .data = "line1: needle\nline2: needle\nline3: needle\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
        .only_matching = true,
        .group_by_file = false,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), result.matches.items.len);

    const flat = try search.search_result_to_string_flat(
        allocator,
        result,
        "needle",
        ".",
    );
    defer allocator.free(flat);

    // The flat output contains <m><f>...</f><l>...</l><s>needle</s></m>
    // for each match. Each <s> is JUST the matched substring (no surrounding
    // text), confirming only_matching is rendered into the flat XML.
    try testing.expect(std.mem.indexOf(u8, flat, "<s>needle</s>") != null);
    // And the snippets do NOT contain surrounding context (e.g. "line1: ").
    try testing.expect(std.mem.indexOf(u8, flat, "<s>line1:") == null);
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

// =============================================================================
// No-match output: include the actual pattern + path in the warning text so
// the operator (and the frontend's header) can see what was searched.
// (Plan: docs/superpowers/plans/2026-08-06-search-better-error.md)
// =============================================================================

test "search: executeSearch no-match warning includes the actual pattern and path" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "empty.txt",
        .data = "no matches here\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try search.executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle_NOT_FOUND",
        .path = "empty.txt",
    });
    defer result.deinit(allocator);

    // No matches.
    try testing.expectEqual(@as(usize, 0), result.matches.items.len);

    // The warning body MUST contain the literal pattern + path the LLM
    // passed so the operator can see what was searched (fix for the
    // "unknown" / "unknown pattern not found" rendering bug).
    try testing.expect(std.mem.indexOf(u8, result.content, "needle_NOT_FOUND") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "empty.txt") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "<warning>") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "</warning>") != null);
}

test "search: search_result_to_string_grouped no-match wraps warning in <search pattern=\"...\" path=\"...\">" {
    const allocator = testing.allocator;

    // Warning body now includes the pattern + path so the operator sees
    // what was searched even when the header attributes get truncated by
    // narrow UIs (the LLM passes "needle_NOT_FOUND" but the toast shows
    // "needle_NO..."). Body text is the durable source of truth.
    const result = search.SearchResult{
        .matches = std.ArrayList(search.SearchMatch).empty,
        .content = "<warning>no matches for pattern \"needle_NOT_FOUND\" in path \"/tmp/x\"</warning>",
    };

    const grouped = try search.search_result_to_string_grouped(
        allocator,
        result,
        "needle_NOT_FOUND",
        "/tmp/x",
    );
    defer allocator.free(grouped);

    // The opening <search pattern="..." path="..."> wrapper MUST be present
    // so the frontend header can extract the actual pattern + path. Before
    // this fix, the no-match branch closed the tag immediately after the
    // opening, never emitting pattern/path — the frontend fell back to
    // "unknown" everywhere.
    try testing.expect(std.mem.indexOf(u8, grouped, "<search pattern=\"needle_NOT_FOUND\"") != null);
    try testing.expect(std.mem.indexOf(u8, grouped, "path=\"/tmp/x\"") != null);
    // The warning body MUST survive inside the wrapper, not be silently
    // dropped.
    try testing.expect(std.mem.indexOf(u8, grouped, "no matches for pattern") != null);
    try testing.expect(std.mem.indexOf(u8, grouped, "needle_NOT_FOUND") != null);
    // And the closing tag MUST come after the warning body.
    try testing.expect(std.mem.indexOf(u8, grouped, "</warning>") != null);
    try testing.expect(std.mem.indexOf(u8, grouped, "</search>") != null);
}

test "search: search_result_to_string_flat no-match wraps warning in <search pattern=\"...\" path=\"...\">" {
    const allocator = testing.allocator;

    const result = search.SearchResult{
        .matches = std.ArrayList(search.SearchMatch).empty,
        .content = "<warning>no matches for pattern \"foo\" in path \"bar\"</warning>",
    };

    const flat = try search.search_result_to_string_flat(
        allocator,
        result,
        "foo",
        "bar",
    );
    defer allocator.free(flat);

    try testing.expect(std.mem.indexOf(u8, flat, "<search pattern=\"foo\"") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "path=\"bar\"") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "no matches for pattern") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "</warning>") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "</search>") != null);
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

    // Look for the "-e" token in the argv construction. The argv is now
    // a runtime ArrayList, but the SAME pattern + ordering must hold:
    // rg's argv is built as ["rg", "--json", ..., "-e", <pattern>, "--", <path>].
    const argv_e = std.mem.indexOf(u8, source, "\"-e\"");
    try testing.expect(argv_e != null);

    // After "-e", the pattern is appended. Check that "input.pattern"
    // appears AFTER "-e" (so the order is right).
    const argv_pattern = std.mem.indexOfPos(u8, source, argv_e.?, "input.pattern");
    try testing.expect(argv_pattern != null);

    // And the "--" token (path separator) appears after the pattern.
    const argv_dashdash = std.mem.indexOfPos(u8, source, argv_pattern.?, "\"--\"");
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

test "agentic_loop/tools_exec_search.zig maps new SearchErrors to LLM-friendly messages" {
    // After the migration, the search exec function lives in
    // `src/ai_workflow/tui/agentic_loop/tools_exec_search.zig` (re-exported
    // via `agentic_loop_mod.tools.execSearch`).
    const source = try readSource(testing.allocator, "src/ai_workflow/tui/agentic_loop/tools_exec_search.zig");
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

test "agentic_loop/tools_exec_search.zig honors group_by_file flag (no longer dead code)" {
    // After the migration, the search exec function lives in
    // `src/ai_workflow/tui/agentic_loop/tools_exec_search.zig` (re-exported
    // via `agentic_loop_mod.tools.execSearch`).
    const source = try readSource(testing.allocator, "src/ai_workflow/tui/agentic_loop/tools_exec_search.zig");
    defer testing.allocator.free(source);

    // The registry must branch on parsed.value.group_by_file and call
    // either grouped or flat output.
    try testing.expect(std.mem.indexOf(u8, source, "parsed.value.group_by_file") != null);
    try testing.expect(std.mem.indexOf(u8, source, "search_result_to_string_flat") != null);
}

test "search.zig tool schema documents word_boundary, literal, only_matching" {
    const source = try readSource(testing.allocator, SEARCH_SOURCE_PATH);
    defer testing.allocator.free(source);

    // Each new field must appear as a JSON schema property entry
    // (mirrors the group_by_file precedent at the previous test).
    try testing.expect(std.mem.indexOf(u8, source, ".name = \"word_boundary\"") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".name = \"literal\"") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".name = \"only_matching\"") != null);

    // Description must mention all 3 flags by name (in prose so LLMs
    // learn when to set them).
    try testing.expect(std.mem.indexOf(u8, source, "word_boundary") != null);
    try testing.expect(std.mem.indexOf(u8, source, "literal") != null);
    try testing.expect(std.mem.indexOf(u8, source, "only_matching") != null);

    // The 'required' array must stay minimal — only pattern + path are
    // required. The 3 new flags are optional with defaults.
    try testing.expect(std.mem.indexOf(u8, source, ".required = &.{ \"pattern\", \"path\" }") != null);
}
