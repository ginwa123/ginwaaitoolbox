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

    // before / after are always allocated when diff_view_found=true
    // (so xmlUnescape can transform entities).
    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
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

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
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

    std.testing.allocator.free(result.before.?);
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

    std.testing.allocator.free(result.after.?);
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

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
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

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
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

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

// ============================================================================
// XML unescape regression tests (bug: "diff view shows &quot; instead of \"")
// ============================================================================

test "parseDiffViewFromResult - unescapes &quot; in before/after (regression)" {
    // XML-escaped content (as produced by xmlEscape) must be un-escaped before
    // being stored, so the diff view renders the original characters.
    const content =
        "<diff_view><before>const a = &quot;hello&quot;;</before>" ++
        "<after>const a = &quot;world&quot;;</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "const a = \"hello\";"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "const a = \"world\";"));

    // Caller MUST free before/after when diff_view_found is true.
    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - unescapes all 5 XML entities" {
    const content =
        "<diff_view><before>" ++
        "&lt;a&gt; &amp; &quot;b&quot; &apos;c&apos;" ++
        "</before><after>" ++
        "&lt;x&gt; &amp; &quot;y&quot; &apos;z&apos;" ++
        "</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "<a> & \"b\" 'c'"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "<x> & \"y\" 'z'"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - no entities, content unchanged (fast path)" {
    // When there's no `&` at all, before/after should be allocated copies
    // with the original content unchanged (fast path in xmlUnescape).
    const content =
        "<diff_view><before>plain text content</before>" ++
        "<after>more plain text</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "plain text content"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "more plain text"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - decodes &amp; LAST (no double-decoding)" {
    // `&amp;quot;` is the literal 6-byte sequence representing the entity
    // `&quot;` — NOT a double-encoded `"`. The &amp; replacement must come
    // last, otherwise the prior passes would convert `&amp;quot;` → `"`.
    // Correct: `&amp;quot;` → `&quot;` (literal 6 chars).
    const content =
        "<diff_view><before>encoded &amp;quot;quote&amp;quot;</before></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "encoded &quot;quote&quot;"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - unescapes multiline content with entities" {
    const content =
        "<diff_view><before>const fn = &lt;T&gt;(a: &amp;T) {\n" ++
        "  return a.toString();\n}</before>" ++
        "<after>const fn = &lt;T&gt;(a: &amp;T) {\n" ++
        "  return a.serialize();\n}</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(
        u8,
        result.before.?,
        "const fn = <T>(a: &T) {\n  return a.toString();\n}",
    ));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(
        u8,
        result.after.?,
        "const fn = <T>(a: &T) {\n  return a.serialize();\n}",
    ));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}