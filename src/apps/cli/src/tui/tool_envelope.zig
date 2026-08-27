//! Parse the `<tool>...</tool>` envelope produced by
//! `src/ai_workflow/tui/agentic_loop/tools_wrap_output.zig`.
//!
//! Mirrors the Vue frontend's `tryUnwrapToolOutput` helper (used by
//! the desktop chatview) — extracts the fields the TUI needs to
//! render a compact card. Pure functions, no allocations on the
//! parsed-struct path; the slices inside `ToolEnvelope` alias into
//! `content`.

const std = @import("std");
const testing = std.testing;

/// Parsed shape of `<tool>...</tool>`. All string slices alias into
/// the input `content` — they are NOT independently allocated. The
/// caller must keep `content` alive for the lifetime of the
/// `ToolEnvelope`.
pub const ToolEnvelope = struct {
    name: []const u8,
    parameters: []const u8,
    data: []const u8,
    success: bool,
    err_msg: []const u8,
};

/// Return the inner substring of a top-level tag, found at or after
/// `start`. Returns `null` when the open tag is not found.
/// Allocation-free aside from the tiny scratch closures for the
/// `<tag>` and `</tag>` strings, which use `page_allocator` (one-shot,
/// no leaks in this short-lived helper).
fn sliceBetween(content: []const u8, tag: []const u8, start: usize) []const u8 {
    var buf: [64]u8 = undefined;
    var open_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return &[_]u8{};
    const close = std.fmt.bufPrint(&buf, "</{s}>", .{tag}) catch return &[_]u8{};
    const open_at = std.mem.indexOfPos(u8, content, start, open) orelse return &[_]u8{};
    const body_start = open_at + open.len;
    const close_at = std.mem.indexOfPos(u8, content, body_start, close) orelse content.len;
    return content[body_start..close_at];
}

/// Walk the wire envelope and return a parsed struct, or `null` when
/// the input is missing any of `<name>` or `<success>` (the minimum
/// required shape).
pub fn tryParseToolEnvelope(content: []const u8) ?ToolEnvelope {
    // <name>...</name> — required
    const name_open_at = std.mem.indexOf(u8, content, "<name>") orelse return null;
    const name = sliceBetween(content, "name", name_open_at);

    // <parameters>...</parameters> is optional in v1 (legacy tools
    // sometimes emit empty). We default to "" when absent.
    const parameters: []const u8 = if (std.mem.indexOf(u8, content, "<parameters>")) |p|
        sliceBetween(content, "parameters", p)
    else
        "";

    // <success>...</success> — required (single tag, no nesting)
    const success_open_at = std.mem.indexOf(u8, content, "<success>") orelse return null;
    const success_body = sliceBetween(content, "success", success_open_at);
    const success = std.mem.eql(u8, std.mem.trim(u8, success_body, &std.ascii.whitespace), "true");

    // <data> and <error> are mutually exclusive. When success=true the
    // wire always emits <data>; when success=false always <error>.
    const data: []const u8 = if (std.mem.indexOf(u8, content, "<data>")) |p|
        sliceBetween(content, "data", p)
    else
        "";

    const err_body: []const u8 = if (std.mem.indexOf(u8, content, "<error>")) |p|
        sliceBetween(content, "error", p)
    else
        "";

    return .{
        .name = name,
        .parameters = parameters,
        .data = data,
        .success = success,
        .err_msg = err_body,
    };
}

/// Pick the most informative primary field for the header line.
/// Whitelist mirrors the desktop's ToolCardHeader logic. Unknown
/// tools fall back to the tool name itself so the header is always
/// non-empty.
pub fn toolEnvelopePrimary(env: ToolEnvelope) []const u8 {
    if (env.name.len == 0) return "unknown";

    // Helper: return the trimmed inner of `<tag>...</tag>` inside
    // env.data, or "" when missing. Two separate buffers so the
    // second bufPrint doesn't overwrite the first before we use it.
    const dataInner = struct {
        fn call(haystack: []const u8, tag: []const u8) []const u8 {
            var open_buf: [64]u8 = undefined;
            var close_buf: [64]u8 = undefined;
            const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return &[_]u8{};
            const close_tag = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return &[_]u8{};
            const open_at = std.mem.indexOf(u8, haystack, open) orelse return &[_]u8{};
            const body_start = open_at + open.len;
            const close_at = std.mem.indexOfPos(u8, haystack, body_start, close_tag) orelse return &[_]u8{};
            return std.mem.trim(u8, haystack[body_start..close_at], &std.ascii.whitespace);
        }
    }.call;

    if (std.mem.eql(u8, env.name, "read_file") or
        std.mem.eql(u8, env.name, "write_file") or
        std.mem.eql(u8, env.name, "text_replace"))
    {
        const path = dataInner(env.data, "path");
        if (path.len > 0) return path;
    }

    if (std.mem.eql(u8, env.name, "search")) {
        const q = dataInner(env.data, "query");
        if (q.len > 0) return q;
    }

    if (std.mem.eql(u8, env.name, "glob")) {
        const p = dataInner(env.data, "pattern");
        if (p.len > 0) return p;
    }

    if (std.mem.eql(u8, env.name, "bash") or std.mem.eql(u8, env.name, "pwsh")) {
        const limit: usize = 64;
        if (env.data.len == 0) {
            // On error path there's no <data>; fall through to tool name.
        } else if (env.data.len <= limit) {
            return env.data;
        } else {
            return env.data[0..limit];
        }
    }

    return env.name;
}

// ----------------------------------------------------------------------------
// Tests (RED — impl added below after tests fail)
// ----------------------------------------------------------------------------

test "tryParseToolEnvelope: valid envelope returns parsed struct" {
    const content =
        \\<tool><name>read_file</name><parameters><path>/foo.txt</path></parameters><success>true</success><data><content>hi</content></data></tool>
    ;
    const env = tryParseToolEnvelope(content) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("read_file", env.name);
    try testing.expect(env.success);
    try testing.expectEqualStrings("<content>hi</content>", env.data);
    try testing.expectEqualStrings("", env.err_msg);
}

test "tryParseToolEnvelope: success=false with <error>" {
    const content =
        \\<tool><name>bash</name><parameters><command>bad</command></parameters><success>false</success><error>boom</error></tool>
    ;
    const env = tryParseToolEnvelope(content) orelse return error.UnexpectedNull;
    try testing.expect(!env.success);
    try testing.expectEqualStrings("boom", env.err_msg);
}

test "tryParseToolEnvelope: missing <name> returns null" {
    try testing.expect(tryParseToolEnvelope("<tool><parameters></parameters><success>true</success><data></data></tool>") == null);
}

test "tryParseToolEnvelope: missing <success> returns null" {
    try testing.expect(tryParseToolEnvelope("<tool><name>x</name><data></data></tool>") == null);
}

test "tryParseToolEnvelope: plain text returns null" {
    try testing.expect(tryParseToolEnvelope("some plain legacy output") == null);
}

test "toolEnvelopePrimary: read_file uses <path> from data" {
    const env = tryParseToolEnvelope(
        "<tool><name>read_file</name><parameters></parameters><success>true</success><data><path>/foo.txt</path><content>hi</content></data></tool>"
    ) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/foo.txt", toolEnvelopePrimary(env));
}

test "toolEnvelopePrimary: write_file uses <path> from data" {
    const env = tryParseToolEnvelope(
        "<tool><name>write_file</name><parameters></parameters><success>true</success><data><path>/a/b/c.txt</path><diff>x</diff></data></tool>"
    ) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/a/b/c.txt", toolEnvelopePrimary(env));
}

test "toolEnvelopePrimary: text_replace uses <path> from data" {
    const env = tryParseToolEnvelope(
        "<tool><name>text_replace</name><parameters></parameters><success>true</success><data><path>/foo.txt</path><replaced>3</replaced></data></tool>"
    ) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/foo.txt", toolEnvelopePrimary(env));
}

test "toolEnvelopePrimary: search uses <query> from data" {
    const env = tryParseToolEnvelope(
        "<tool><name>search</name><parameters></parameters><success>true</success><data><query>foo bar</query><matches>3</matches></data></tool>"
    ) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("foo bar", toolEnvelopePrimary(env));
}

test "toolEnvelopePrimary: glob uses <pattern> from data" {
    const env = tryParseToolEnvelope(
        "<tool><name>glob</name><parameters></parameters><success>true</success><data><pattern>**/*.zig</pattern></data></tool>"
    ) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("**/*.zig", toolEnvelopePrimary(env));
}

test "toolEnvelopePrimary: bash truncates to 64 chars" {
    var buf: [512]u8 = undefined;
    const long_output = "a" ** 200;
    const content = std.fmt.bufPrint(&buf, "<tool><name>bash</name><parameters></parameters><success>true</success><data><output>{s}</output></data></tool>", .{long_output}) catch unreachable;
    const env = tryParseToolEnvelope(content) orelse return error.UnexpectedNull;
    const primary = toolEnvelopePrimary(env);
    try testing.expect(primary.len <= 64);
    try testing.expect(primary.len > 0);
}

test "toolEnvelopePrimary: unknown tool falls back to its name" {
    const env = tryParseToolEnvelope(
        "<tool><name>weird_thing</name><parameters></parameters><success>true</success><data>x</data></tool>"
    ) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("weird_thing", toolEnvelopePrimary(env));
}

test "toolEnvelopePrimary: empty data falls back to tool name" {
    const env = tryParseToolEnvelope(
        "<tool><name>read_file</name><parameters></parameters><success>false</success><error>not found</error></tool>"
    ) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("read_file", toolEnvelopePrimary(env));
}