const std = @import("std");
const testing = std.testing;
const tool_registry = @import("tool_registry.zig");

test "wrapToolOutput - success with all fields, JSON params converted to XML" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "read_file",
        "{\"path\":\"/foo/bar.txt\"}",
        true,
        null,
        "<path>/foo/bar.txt</path><content>hello</content>",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<tool>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<name>read_file</name>") != null);
    // JSON {"path":"/foo/bar.txt"} → <parameters><path>/foo/bar.txt</path></parameters>
    try testing.expect(std.mem.indexOf(u8, out, "<parameters><path>/foo/bar.txt</path></parameters>") != null);
    // Regression: ensure no double-wrapped <parameters><parameters>...</parameters></parameters>
    // (jsonArgsToXml previously added its own <parameters> wrapper, which
    // wrapToolOutput then wrapped again — see show_preview PR #55 bug fix.)
    try testing.expect(std.mem.indexOf(u8, out, "<parameters><parameters>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<success>true</success>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<data>") != null);
    // Data is NOT escaped — it's preserved as-is so the LLM and
    // frontend can read the inner tool-specific tags.
    try testing.expect(std.mem.indexOf(u8, out, "<path>/foo/bar.txt</path>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "</tool>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
}

test "wrapToolOutput - error case omits data and emits error" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "read_file",
        "{\"path\":\"/missing\"}",
        false,
        "File not found",
        "",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<success>false</success>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<error>File not found</error>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<data>") == null);
}

test "wrapToolOutput - empty parameters string emits empty <parameters>" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "list_skills",
        "",
        true,
        null,
        "<skills></skills>",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<parameters></parameters>") != null);
}

test "wrapToolOutput - JSON with array converts to <item> children" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "some_tool",
        "{\"tags\":[\"a\",\"b\",\"c\"]}",
        true,
        null,
        "ok",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<tags><item>a</item><item>b</item><item>c</item></tags>") != null);
}

test "wrapToolOutput - JSON with nested object converts to nested elements" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "bash",
        "{\"options\":{\"verbose\":true,\"count\":3}}",
        true,
        null,
        "ok",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<options><verbose>true</verbose><count>3</count></options>") != null);
}

test "wrapToolOutput - JSON with boolean and null values" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "tool",
        "{\"enabled\":true,\"flag\":null}",
        true,
        null,
        "ok",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<enabled>true</enabled>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<flag/>") != null);
}

test "wrapToolOutput - malformed JSON falls back to <raw> wrapper" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "bash",
        "{not valid json",
        true,
        null,
        "ok",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<parameters><raw>{not valid json</raw></parameters>") != null);
}

test "wrapToolOutput - data is preserved as-is (not escaped)" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "bash",
        "{}",
        true,
        null,
        "<stdout><hi> & \"world\"</stdout>",
    );
    defer allocator.free(out);

    // Data is NOT XML-escaped — inner tags stay as-is.
    try testing.expect(std.mem.indexOf(u8, out, "<stdout><hi> & \"world\"</stdout>") != null);
}

test "wrapToolOutput - error message is escaped" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "bash",
        "{}",
        false,
        "bad <tag> & \"quote\"",
        "",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>bad &lt;tag&gt; &amp; &quot;quote&quot;</error>") != null);
}

test "wrapToolOutput - success and error are mutually exclusive" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "bash",
        "{}",
        true,
        "ignored error msg",
        "<stdout>ok</stdout>",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<data><stdout>ok</stdout></data>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
}

test "wrapToolOutput - allocates and caller owns" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "bash",
        "{}",
        true,
        null,
        "ok",
    );
    defer allocator.free(out);
    try testing.expect(out.len > 0);
}
