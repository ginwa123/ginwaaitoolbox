//! Tests for text_replace tool's unified diff functionality.
//! These tests verify that executeTextReplace returns a proper diff_view
//! with unified diff format (git-style) showing +/- lines and context.

const std = @import("std");
const text_replace = @import("text_replace.zig");

fn createTestFile(path: []const u8, content: []const u8) !void {
    // Ensure parent directory exists using createDirPath
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    }
    // Write content to file using same pattern as write_file.zig
    const file = std.Io.Dir.cwd().createFile(std.testing.io, path, .{}) catch |file_err| {
        if (file_err == error.FileNotFound) {
            const dir = std.fs.path.dirname(path) orelse ".";
            try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
            const new_file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
            defer std.Io.File.close(new_file, std.testing.io);
            try std.Io.File.writeStreamingAll(new_file, std.testing.io, content);
            return;
        }
        return file_err;
    };
    defer std.Io.File.close(file, std.testing.io);
    try std.Io.File.writeStreamingAll(file, std.testing.io, content);
}

fn deleteTestFile(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

test "text_replace - unified diff contains diff markers" {
    const test_path = "/tmp/test_diff_view_unified.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Unified should contain header markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "---") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "+++") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "@@") != null);
        // Should have context showing the change (Hello appears, Goodbye added)
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "Hello") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "Goodbye") != null);
        // lines_changed should be set
        try std.testing.expect(dv.lines_changed > 0);
    }

    deleteTestFile(test_path);
}

test "text_replace - split diff_view before contains original content" {
    const test_path = "/tmp/test_diff_view_before.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Before should contain original text
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "Hello") != null);
        // Before should NOT contain replacement
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "Goodbye") == null);
    }

    deleteTestFile(test_path);
}

test "text_replace - split diff_view after contains replacement content" {
    const test_path = "/tmp/test_diff_view_after.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // After should contain replacement
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "Goodbye") != null);
        // After should NOT contain original
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "Hello") == null);
    }

    deleteTestFile(test_path);
}

test "text_replace - split diff_view before and after are distinct" {
    const test_path = "/tmp/test_diff_view_distinct.txt";
    try createTestFile(test_path, "original text\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "original",
        "modified",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Before and after should be different
        try std.testing.expect(!std.mem.eql(u8, dv.before, dv.after));
        // Before contains "original", not "modified"
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "original") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "modified") == null);
        // After contains "modified", not "original"
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "modified") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "original") == null);
    }

    deleteTestFile(test_path);
}

test "text_replace - unified diff shows line removal" {
    const test_path = "/tmp/test_diff_view_removal.txt";
    try createTestFile(test_path, "line1\nline2\nline3\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line2\n",
        "",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have git merge conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
        // before should contain old content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line2") != null);
        // after should be empty
        try std.testing.expect(dv.after.len == 0);
    }

    deleteTestFile(test_path);
}

test "text_replace - unified diff shows line insertion" {
    const test_path = "/tmp/test_diff_view_insert.txt";
    try createTestFile(test_path, "line1\nline3\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line1\n",
        "line1\nline2\n",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have git merge conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
        // before should contain old content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line1") != null);
        // after should contain new content
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "line1") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "line2") != null);
    }

    deleteTestFile(test_path);
}

test "text_replace - unified diff shows multiline replacement" {
    const test_path = "/tmp/test_diff_view_multiline.txt";
    try createTestFile(test_path,
        \\fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    );

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}",
        "fn add(a: i32, b: i32) i32 {\n    return a - b;\n}",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have git merge conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
        // before should contain old content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "return a + b;") != null);
        // after should contain new content
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "return a - b;") != null);
    }

    deleteTestFile(test_path);
}

test "text_replace - unified diff includes hunk header with line numbers" {
    const test_path = "/tmp/test_diff_view_hunk.txt";
    try createTestFile(test_path, "line1\nline2\nline3\nline4\nline5\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line2",
        "modified_line2",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have git merge conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
    }

    deleteTestFile(test_path);
}

test "text_replace - lines_changed reflects actual change count" {
    const test_path = "/tmp/test_diff_view_lines.txt";
    try createTestFile(test_path, "line1\nline2\nline3\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line2\n",
        "new_line2a\nnew_line2b\n",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Verify conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
        // before should contain old content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line2") != null);
    }

    deleteTestFile(test_path);
}

// ============================================================================
// generateUnifiedDiff Tests - git merge conflict style
// ============================================================================

test "generateUnifiedDiff output contains git merge conflict markers" {
    const test_path = "/tmp/test_git_conflict_markers.txt";
    try createTestFile(test_path, "line1\nline2\nline3\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line2",
        "modified_line2",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should contain git merge conflict style markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff split view shows old_str under <<<<<<<" {
    const test_path = "/tmp/test_split_before.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);

        // before should contain old_str
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "Hello") != null);
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff split view shows new_str under =======" {
    const test_path = "/tmp/test_split_after.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Unified output: new_str should appear between ======= and >>>>>>>
        const separator = std.mem.indexOf(u8, dv.unified, "=======");
        const after_marker = std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER");
        try std.testing.expect(separator != null);
        try std.testing.expect(after_marker != null);

        // Extract content between ======= and >>>>>>>
        const after_section = dv.unified[separator.?..after_marker.?];
        try std.testing.expect(std.mem.indexOf(u8, after_section, "Goodbye") != null);
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff before field equals old_str exactly" {
    const test_path = "/tmp/test_before_exact.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // before field should be exactly old_str (not wrapped with file context)
        try std.testing.expect(std.mem.eql(u8, dv.before, "Hello"));
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff after field equals new_str exactly" {
    const test_path = "/tmp/test_after_exact.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // after field should be exactly new_str (not wrapped with file context)
        try std.testing.expect(std.mem.eql(u8, dv.after, "Goodbye"));
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff multiline old_str shows all lines in split view" {
    const test_path = "/tmp/test_multiline_split.txt";
    try createTestFile(test_path,
        \\fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    );

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}",
        "fn add(a: i32, b: i32) i32 {\n    return a - b;\n}",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);

        // before should contain the old multiline content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "return a + b;") != null);

        // after should be different from before
        try std.testing.expect(!std.mem.eql(u8, dv.before, dv.after));
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff unified output has both traditional diff and conflict markers" {
    const test_path = "/tmp/test_unified_and_conflict.txt";
    try createTestFile(test_path, "line1\nline2\nline3\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line2",
        "modified_line2",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have git merge conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);

        // before should contain old content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line2") != null);
        // after should contain new content
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "modified_line2") != null);
    }

    deleteTestFile(test_path);
}

// ─── Chunk 4: XML-escape + unified-diff coverage ───────────────────────────

test "toXmlSuccess XML-escapes path containing & and <" {
    // A file with a `&` or `<` in its path used to break toolOutputParser on
    // the frontend (the <path> tag was misaligned). This test ensures the
    // backend escapes such characters.
    const allocator = std.testing.allocator;
    var result: text_replace.TextReplaceResult = .{ .ok = {} };
    defer result.deinit(allocator);
    // Populate the diff_view with a fixed value so we can assert on the
    // emitted XML.
    const before = allocator.dupe(u8, "x") catch unreachable;
    const after = allocator.dupe(u8, "y") catch unreachable;
    const unified = allocator.dupe(u8, "--- a\n+++ b\n-old\n+new") catch unreachable;
    result.diff_view = .{
        .unified = unified,
        .before = before,
        .after = after,
        .lines_changed = 1,
    };
    const xml = text_replace.toXmlSuccess(allocator, result, "/abs/path with & and < and > and \"");
    defer allocator.free(xml);

    // The escaped path must appear, with & < > " all converted to entities.
    try std.testing.expect(std.mem.indexOf(u8, xml, "/abs/path with &amp; and &lt; and &gt; and &quot;") != null);
    // The raw (un-escaped) path must NOT appear inside the body (only in
    // the escaped form).
    try std.testing.expect(std.mem.indexOf(u8, xml, "/abs/path with & and <") == null);
}

test "toXmlSuccess includes the unified diff field" {
    const allocator = std.testing.allocator;
    var result: text_replace.TextReplaceResult = .{ .ok = {} };
    defer result.deinit(allocator);
    const before = allocator.dupe(u8, "old line") catch unreachable;
    const after = allocator.dupe(u8, "new line") catch unreachable;
    const unified = allocator.dupe(u8, "--- a/x\n+++ b/x\n@@ -1,1 +1,1 @@\n-old line\n+new line") catch unreachable;
    result.diff_view = .{
        .unified = unified,
        .before = before,
        .after = after,
        .lines_changed = 1,
    };
    const xml = text_replace.toXmlSuccess(allocator, result, "/x");
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<unified>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "@@ -1,1 +1,1 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "-old line") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "+new line") != null);
}

test "xmlError XML-escapes path/old_str/new_str containing special chars" {
    const allocator = std.testing.allocator;
    const xml = text_replace.xmlError(
        allocator,
        "make & sure",
        "/path with &",
        "old < thing",
        "new > thing",
    );
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<error>make &amp; sure</error>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<path>/path with &amp;</path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<old_str>old &lt; thing</old_str>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<new_str>new &gt; thing</new_str>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<success>false</success>") != null);
}
