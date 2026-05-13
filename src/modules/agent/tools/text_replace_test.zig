//! Tests for text_replace tool's diff_view functionality.
//! These tests verify that executeTextReplace returns a proper diff_view
//! with before/after content when files are modified.

const std = @import("std");
const text_replace = @import("text_replace.zig");

fn createTestFile(path: []const u8, content: []const u8) !void {
    // Ensure parent directory exists
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(std.testing.io, dir) catch {};
    }
    // Write content to file using same pattern as write_file.zig
    const file = std.Io.Dir.cwd().createFile(std.testing.io, path, .{}) catch |file_err| {
        if (file_err == error.FileNotFound) {
            const dir = std.fs.path.dirname(path) orelse ".";
            try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
            var new_file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
            defer new_file.close(std.testing.io);
            try std.Io.File.writeStreamingAll(new_file, std.testing.io, content);
            return;
        }
        return file_err;
    };
    defer file.close(std.testing.io);
    try std.Io.File.writeStreamingAll(file, std.testing.io, content);
}

fn deleteTestFile(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

test "text_replace - diff_view before contains original content" {
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

test "text_replace - diff_view after contains replacement content" {
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

test "text_replace - diff_view before and after are distinct for modifications" {
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

test "text_replace - diff_view before and after are identical when no change" {
    const test_path = "/tmp/test_diff_view_nochange.txt";
    try createTestFile(test_path, "unchanged text\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "unchanged text",
        "unchanged text",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // When nothing changes, before and after should be byte-identical
        try std.testing.expectEqualStrings(dv.before, dv.after);
    }

    deleteTestFile(test_path);
}

test "text_replace - diff_view reflects line deletion" {
    const test_path = "/tmp/test_diff_view_delete.txt";
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
        // Before contains context before old_str + old_str (the deleted text)
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line1") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line2") != null);
        // After contains context before old_str only (old_str was deleted, replaced with empty)
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "line1") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "line2") == null);
        // Neither before nor after contains line3 since it's after the replaced text
    }

    deleteTestFile(test_path);
}

test "text_replace - diff_view reflects line insertion" {
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
        // Before contains old_str (the text being replaced)
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line1") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line2") == null);
        // After contains new_str (the replacement)
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "line1") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "line2") != null);
        // Neither before nor after contains line3 since it's after the replaced text
    }

    deleteTestFile(test_path);
}

test "text_replace - diff_view reflects multiline replacement" {
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
        // Before has "a + b"
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "a + b") != null);
        // After has "a - b"
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "a - b") != null);
        // After does NOT have "a + b"
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "a + b") == null);
    }

    deleteTestFile(test_path);
}

test "text_replace - diff_view preserves surrounding context" {
    const test_path = "/tmp/test_diff_view_context.txt";
    try createTestFile(test_path,
        \\// Header comment
        \\const config = "original";
        \\// Footer comment
    );

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "\"original\"",
        "\"modified\"",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Both before and after should contain header and footer
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "Header comment") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "Footer comment") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "Header comment") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "Footer comment") != null);
    }

    deleteTestFile(test_path);
}

test "text_replace - toXmlSuccess includes diff_view with before/after tags" {
    const test_path = "/tmp/test_diff_view_xml.txt";
    try createTestFile(test_path, "old content\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "old",
        "new",
    );
    defer result.deinit(std.testing.allocator);

    const xml_output = text_replace.toXmlSuccess(
        std.testing.allocator,
        result,
        test_path,
    );
    defer std.testing.allocator.free(xml_output);

    // Verify XML structure
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<before>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "</before>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<after>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "</after>") != null);

    // Verify content appears in correct places
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "old") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "new") != null);

    deleteTestFile(test_path);
}

test "text_replace - file actually modified after replace" {
    const test_path = "/tmp/test_diff_view_actual.txt";
    try createTestFile(test_path, "original\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "original",
        "modified",
    );
    defer result.deinit(std.testing.allocator);

    // Verify file was actually modified
    const file_content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, test_path, std.testing.allocator, std.Io.Limit.limited(std.math.maxInt(usize)));
    defer std.testing.allocator.free(file_content);

    try std.testing.expect(std.mem.indexOf(u8, file_content, "modified") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "original") == null);

    deleteTestFile(test_path);
}

test "text_replace - error case returns no diff_view" {
    const test_path = "/tmp/test_diff_view_error.txt";
    try createTestFile(test_path, "hello world\n");

    const result = text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "nonexistent",
        "replacement",
    );

    try std.testing.expectError(text_replace.TextReplaceError.OldStrNotFound, result);

    deleteTestFile(test_path);
}

test "text_replace - error OldStrNotUnique when text appears twice" {
    const test_path = "/tmp/test_diff_view_ambiguous.txt";
    try createTestFile(test_path, "foo bar foo\n");

    const result = text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "foo",
        "baz",
    );

    try std.testing.expectError(text_replace.TextReplaceError.OldStrNotUnique, result);

    deleteTestFile(test_path);
}

test "text_replace - diff_view memory is properly allocated" {
    const test_path = "/tmp/test_diff_view_memory.txt";
    try createTestFile(test_path, "test content\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "test",
        "replaced",
    );

    // deinit should not crash and should free memory properly
    result.deinit(std.testing.allocator);

    deleteTestFile(test_path);
}

test "text_replace - empty new_str removes content and diff_view shows deletion" {
    const test_path = "/tmp/test_diff_view_empty.txt";
    try createTestFile(test_path, "keep this\nremove this\nkeep this too\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "remove this\n",
        "",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Before contains the deleted line
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "remove this") != null);
        // After does NOT contain the deleted line
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "remove this") == null);
        // Both contain surrounding context
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "keep this") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "keep this") != null);
    }

    deleteTestFile(test_path);
}

test "text_replace - diff_view preserves exact before/after equality for unchanged" {
    const test_path = "/tmp/test_diff_view_unchanged.txt";
    try createTestFile(test_path, "exact same content\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "exact same content",
        "exact same content",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // When nothing changes, before and after should be byte-identical
        try std.testing.expectEqualStrings(dv.before, dv.after);
    }

    deleteTestFile(test_path);
}