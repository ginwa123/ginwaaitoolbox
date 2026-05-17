const std = @import("std");
const handle_tool = @import("handle_tool.zig");
const parseDiffViewFromResult = handle_tool.parseDiffViewFromResult;
const DiffViewParseResult = handle_tool.DiffViewParseResult;

test "parseDiffViewFromResult - no diff_view returns allocated copy" {
    const content = "File modified successfully";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(!result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, content));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    // ALWAYS free the allocated content
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - empty diff_view at end returns content before diff_view" {
    const content = "Success<diff_view></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Success"));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - extracts before and after content" {
    const content = "Success<diff_view><before>old content</before><after>new content</after></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Success!"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "old content"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "new content"));

    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - extracts multiline before and after" {
    const content = "Result:<diff_view><before>line1\nline2\nline3</before><after>line1\nmodified\nline3</after></diff_view>:end";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Result::end"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "line1\nline2\nline3"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "line1\nmodified\nline3"));

    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - only before tag extracts correctly" {
    const content = "Done<diff_view><before>original</before></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Done!"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "original"));
    try std.testing.expect(result.after == null);

    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - only after tag extracts correctly" {
    const content = "Done<diff_view><after>replacement</after></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Done!"));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "replacement"));

    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - missing closing tag returns allocated copy" {
    const content = "Result<diff_view><before>old</before><after>new</after>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(!result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, content));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    // ALWAYS free the allocated content
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - missing opening tag returns allocated copy" {
    const content = "Result<before>old</before><after>new</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(!result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, content));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    // ALWAYS free the allocated content
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - empty before and after tags" {
    const content = "Empty<diff_view><before></before><after></after></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Empty!"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, ""));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, ""));

    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - before/after at boundaries" {
    const content = "<diff_view><before>start</before><after>end</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, ""));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "start"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "end"));

    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - diff_view in middle of content" {
    const content = "prefix <diff_view><before>a</before><after>b</after></diff_view> suffix";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "prefix  suffix"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "a"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "b"));

    std.testing.allocator.free(result.content_without_diffview);
}