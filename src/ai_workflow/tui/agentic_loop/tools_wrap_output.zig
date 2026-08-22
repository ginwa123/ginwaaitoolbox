const std = @import("std");
const nalarcore = @import("nalarcore");

const helpers = @import("helpers");
const xmlEscape = helpers.xml_escape;
const testing = std.testing;


/// Wrap a tool result in the standardized `<tool>...</tool>` envelope.
///
/// On success: emits `<data>` containing the inner tool-specific XML output.
/// On error: emits `<error>` containing a human-readable message and omits
/// `<data>`. The two are mutually exclusive — when `success=true`, the
/// `error_message` argument is ignored; when `success=false`, the `data`
/// argument is ignored.
///
/// `tool_name` — the registered tool name (e.g. `"read_file"`). XML-escaped.
/// `parameters` — the raw JSON arguments string from the tool call
///   (e.g. `{"path":"/foo"}`). The wrapper parses this JSON and converts it
///   to XML structure inside `<parameters>...</parameters>`. If the JSON is
///   malformed, the raw string is wrapped in `<raw>...</raw>` as a fallback.
///   Always emitted (even on error).
/// `success` — `true` for a successful tool execution, `false` for a failure.
/// `error_message` — required when `success=false`; ignored when `success=true`.
/// `data` — the existing tool-specific XML output. Required when
///   `success=true`; ignored when `success=false`. Pass an empty string if
///   you have no data (the wrapper still emits an empty `<data></data>`).
///
/// The returned string is owned by the caller; free with `allocator.free`.
pub fn wrapToolOutput(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    parameters: []const u8,
    success: bool,
    error_message: ?[]const u8,
    data: []const u8,
) ![]u8 {
    const escaped_name = try xmlEscape(allocator, tool_name);
    defer allocator.free(escaped_name);
    const params_xml = try jsonArgsToXml(allocator, parameters);
    defer allocator.free(params_xml);

    if (success) {
        // Note: `data` is NOT XML-escaped. It is the tool-specific XML
        // output (e.g. read_file's `<path>/foo</path>...`) and escaping
        // it would corrupt the inner tags, making the result unreadable
        // to the LLM and the frontend. The other text fields (name,
        // parameters, error_message) ARE escaped because they are
        // arbitrary user input.
        return try std.fmt.allocPrint(
            allocator,
            "<tool><name>{s}</name><parameters>{s}</parameters><success>true</success><data>{s}</data></tool>",
            .{ escaped_name, params_xml, data },
        );
    } else {
        const msg = error_message orelse "unknown error";
        const escaped_err = try xmlEscape(allocator, msg);
        defer allocator.free(escaped_err);
        return try std.fmt.allocPrint(
            allocator,
            "<tool><name>{s}</name><parameters>{s}</parameters><success>false</success><error>{s}</error></tool>",
            .{ escaped_name, params_xml, escaped_err },
        );
    }
}

// Every `execX` function below MUST end by calling `wrapToolOutput` so the
// LLM sees a single consistent envelope:
//
//   <tool>
//     <name>{name}</name>
//     <parameters>{xml args (converted from JSON)}</parameters>
//     <success>true|false</success>
//     <error>{if failure}</error>
//     <data>{xml-escaped inner tool output, if success}</data>
//   </tool>
//
// The inner `<data>` field holds the existing tool-specific XML unchanged
// (e.g. read_file's `<path>`, text_replace's `<diff_view>`, get_skill's
// `<loaded>`, etc.) so the 12 tool modules' `toXmlSuccess`/`toXmlError`
// functions and the 13 frontend `tool_outputs/*.vue` components keep
// working unchanged.

/// Convert a JSON arguments string to XML structure wrapped in
/// `<parameters>...</parameters>`. The conversion rules:
///
/// - Object → `<parameters><k>v</k>...</parameters>` (one child per key)
/// - Array of primitives → `<parameters><item>...</item>...</parameters>`
/// - String/number/boolean → text content (XML-escaped)
/// - null → self-closing `<k/>`
/// - Nested object → `<parameters><k>...</k></parameters>` (recurses)
///
/// Returns `<parameters></parameters>` for an empty input string.
/// Returns `<parameters><raw>{escaped raw}</raw></parameters>` if the JSON
/// fails to parse (fallback so the LLM can still see what was passed).
/// Convert a JSON arguments string into the XML fragment that goes inside
/// `<parameters>...</parameters>` in the tool output envelope.
///
/// **Returns ONLY the inner content** (e.g. `<path>/foo</path>` for
/// `{"path":"/foo"}`). The outer `<parameters>...</parameters>` wrapper
/// is added by `wrapToolOutput` so that there is exactly one wrapper
/// per envelope. Previously this function added the outer wrapper too,
/// producing a double-wrap like
/// `<parameters><parameters><path>/foo</path></parameters></parameters>`
/// which corrupted every show_preview (and any other tool with rich
/// markdown/code content) — the frontend's `tryUnwrapToolOutput` would
/// read the inner `<parameters>` as the parameters JSON, fail to
/// parse, and render an empty preview.
///
/// Caller contract: `wrapToolOutput` is the only caller; it always
/// embeds the returned string inside its own `<parameters>{s}</parameters>`
/// template, so callers MUST NOT add another `<parameters>` wrapper.
fn jsonArgsToXml(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    if (json_str.len == 0) {
        // Empty inner content — wrapToolOutput's template still emits
        // the surrounding <parameters></parameters>.
        return try allocator.dupe(u8, "");
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        // Malformed JSON fallback: wrap the raw string in <raw>...</raw>.
        // The outer <parameters>...</parameters> wrapper is added by
        // wrapToolOutput — we only build the inner content here.
        const escaped = try xmlEscape(allocator, json_str);
        defer allocator.free(escaped);
        return try std.fmt.allocPrint(allocator, "<raw>{s}</raw>", .{escaped});
    };
    defer parsed.deinit();

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    switch (parsed.value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                try helpers.json_value_to_xml(allocator, &buffer, entry.key_ptr.*, entry.value_ptr.*);
            }
        },
        else => {
            // Top-level is not an object — wrap as <raw> for safety.
            // The outer <parameters>...</parameters> wrapper is added by
            // wrapToolOutput — we only build the inner content here.
            const escaped = try xmlEscape(allocator, json_str);
            defer allocator.free(escaped);
            try buffer.appendSlice(allocator, "<raw>");
            try buffer.appendSlice(allocator, escaped);
            try buffer.appendSlice(allocator, "</raw>");
        },
    }

    return try buffer.toOwnedSlice(allocator);
}



test "wrapToolOutput - success with all fields, JSON params converted to XML" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
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
    const out = try wrapToolOutput(
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
    const out = try wrapToolOutput(
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
    const out = try wrapToolOutput(
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
    const out = try wrapToolOutput(
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
    const out = try wrapToolOutput(
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
    const out = try wrapToolOutput(
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
    const out = try wrapToolOutput(
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
    const out = try wrapToolOutput(
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
    const out = try wrapToolOutput(
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
    const out = try wrapToolOutput(
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

