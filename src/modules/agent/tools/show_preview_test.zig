//! Tests for `show_preview.zig` (Task 1.1 of the
//! show-preview feature).
//!
//! Test strategy mirrors the project's tool-test convention:
//!   1. Static source-check tests that grep the implementation file
//!      for required substrings (tool name, schema fields, constant
//!      declarations, function signatures). These catch "I forgot to
//!      add the field" / "I renamed the function" regressions
//!      without needing to drive the runtime.
//!   2. Behavioral tests that drive `executeShowPreviewToString`
//!      directly. The Io runtime is provided by
//!      `std.Io.Threaded.init(testing.allocator, .{})` + `.io()`
//!      — same pattern as `fire_test.zig` and `read_compacted_messages_test.zig`.
//!
//! The behavioral tests do NOT use an in-memory SQLite — the
//! show_preview tool is purely a string-manipulation tool (no DB
//! read/write), so the only Io-touching operations are the
//! `Clock.now` timestamp inside `generatePreviewId` and the
//! `std.c.getrandom` syscall (which doesn't need Io).
//!
//! Plan: docs/superpowers/plans/2026-06-30-feat-show-preview.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;
const show_preview = @import("show_preview.zig");

const TOOL_PATH = "src/modules/agent/tools/show_preview.zig";

// ─── Helpers ─────────────────────────────────────────────────────────────

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
/// The returned buffer is owned by the caller (freed with `allocator.free`).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Open a fresh `std.Io.Threaded` runtime. Mirrors the setup helper
/// in `routines/fire_test.zig:52-91` and
/// `tools/read_compacted_messages_test.zig:6-33`. Returns the
/// runtime so the caller can `defer threaded.deinit()` and pass
/// `threaded.io()` to `executeShowPreviewToString`.
fn setupIo() std.Io.Threaded {
    const threaded = std.Io.Threaded.init(testing.allocator, .{});
    return threaded;
}

// ─── Static source-check tests (6) ───────────────────────────────────────

test "show_preview tool definition has name \"show_preview\"" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The `.name = "show_preview"` assignment lives inside the
    // `show_preview_tool` constant. If it's missing the LLM will
    // never be able to call the tool.
    if (!contains(source, ".name = \"show_preview\"")) {
        std.debug.print("!! show_preview.zig does not define the tool with .name = \"show_preview\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "show_preview description mentions \"side panel\"" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The phrase "side panel" is the LLM's signal that this tool
    // renders to a special UI area — without it the LLM will fall
    // back to `add_memory` or `write_file` and miss the side panel
    // entirely.
    if (!contains(source, "side panel")) {
        std.debug.print("!! show_preview.zig description does not mention \"side panel\" (LLM won't know this is a UI-rendering tool) !!\n", .{});
        return error.SidePanelHintMissing;
    }
}

test "show_preview schema has all 5 properties (content_type, content, title, language, caption)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Each property name must appear in a `.name = "<prop>"` line.
    const required_props = [_][]const u8{
        "content_type",
        "content",
        "title",
        "language",
        "caption",
    };
    for (required_props) |prop| {
        const needle = try std.fmt.allocPrint(allocator, ".name = \"{s}\"", .{prop});
        defer allocator.free(needle);
        if (!contains(source, needle)) {
            std.debug.print("!! show_preview.zig schema is missing property: {s} !!\n", .{prop});
            return error.SchemaPropertyMissing;
        }
    }
}

test "show_preview schema required array contains content_type and content" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The `required` array literal MUST include the two fields the
    // LLM must always provide. If "content" is missing, the LLM
    // could call with no payload; if "content_type" is missing, the
    // LLM could call without specifying how to render.
    if (!contains(source, "required = &.{ \"content_type\", \"content\" }")) {
        std.debug.print("!! show_preview.zig schema `required` is not &.{{ \"content_type\", \"content\" }} (or is in a different order) !!\n", .{});
        return error.RequiredArrayWrong;
    }
}

test "show_preview defines pub fn executeShowPreviewToString" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The function is the public entry point used by `tool_registry.zig`.
    // Without this signature the tool can't be wired into the agent loop.
    if (!contains(source, "pub fn executeShowPreviewToString(")) {
        std.debug.print("!! show_preview.zig does not define pub fn executeShowPreviewToString !!\n", .{});
        return error.ExecuteFnMissing;
    }
}

test "show_preview defines 1024 * 1024 byte cap constant (MAX_CONTENT_BYTES)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The 1 MiB cap is required so we don't OOM the SSE pipeline on
    // a misbehaving LLM. The literal "1024 * 1024" must appear in a
    // `pub const MAX_CONTENT_BYTES` declaration (or similar) — if
    // someone replaces it with a different formula, the test fails.
    if (!contains(source, "MAX_CONTENT_BYTES")) {
        std.debug.print("!! show_preview.zig does not define MAX_CONTENT_BYTES constant !!\n", .{});
        return error.MaxContentBytesConstMissing;
    }
    if (!contains(source, "1024 * 1024")) {
        std.debug.print("!! show_preview.zig does not include the 1024 * 1024 byte cap (1 MiB) !!\n", .{});
        return error.OneMiBCapMissing;
    }
}

// ─── Behavioral tests (6) ────────────────────────────────────────────────

test "executeShowPreviewToString returns success envelope for markdown input" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const input = show_preview.ShowPreviewInput{
        .content_type = "markdown",
        .content = "# Hello\n\nThis is a **preview**.",
        .title = "Greeting",
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<show_preview>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</show_preview>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content_type>markdown</content_type>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content_length>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);

    // Preview id is well-formed: pv_<digits>_<6 hex chars>
    try testing.expect(std.mem.startsWith(u8, preview_id, "pv_"));
    try testing.expect(std.mem.indexOf(u8, preview_id, "_") != null);
    // The preview_id should appear in the envelope
    try testing.expect(std.mem.indexOf(u8, xml, preview_id) != null);
}

test "executeShowPreviewToString returns error envelope for invalid content_type" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const input = show_preview.ShowPreviewInput{
        .content_type = "video",
        .content = "anything",
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<show_preview>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "invalid content_type") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "video") != null);
    // Should list the allowed values so the LLM self-corrects
    try testing.expect(std.mem.indexOf(u8, xml, "markdown") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "image") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") == null);
}

test "executeShowPreviewToString returns error envelope when content exceeds MAX_CONTENT_BYTES" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Build a content payload one byte over the cap. Using a small
    // ArrayList so we don't allocate 1 MiB just for a test (the
    // validator runs the size check BEFORE any expensive work).
    var oversized = try std.ArrayList(u8).initCapacity(alloc, show_preview.MAX_CONTENT_BYTES + 1);
    defer oversized.deinit(alloc);
    try oversized.resize(alloc, show_preview.MAX_CONTENT_BYTES + 1);
    for (oversized.items) |*b| b.* = 'x';

    const input = show_preview.ShowPreviewInput{
        .content_type = "text",
        .content = oversized.items,
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "exceeds MAX_CONTENT_BYTES") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") == null);
}

test "executeShowPreviewToString returns error envelope when content_type is \"code\" with no language" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Missing language field entirely (null).
    {
        const input = show_preview.ShowPreviewInput{
            .content_type = "code",
            .content = "fn main() {}",
            // .language left null
        };
        var preview_id: []u8 = undefined;
        const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
        defer alloc.free(xml);
        defer alloc.free(preview_id);
        try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
        try testing.expect(std.mem.indexOf(u8, xml, "language") != null);
    }

    // Empty language field.
    {
        const input = show_preview.ShowPreviewInput{
            .content_type = "code",
            .content = "fn main() {}",
            .language = "",
        };
        var preview_id: []u8 = undefined;
        const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
        defer alloc.free(xml);
        defer alloc.free(preview_id);
        try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
        try testing.expect(std.mem.indexOf(u8, xml, "language") != null);
    }
}

test "executeShowPreviewToString accepts code type with language" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const input = show_preview.ShowPreviewInput{
        .content_type = "code",
        .content = "const std = @import(\"std\");\n\npub fn main() void {}",
        .language = "zig",
        .title = "hello.zig",
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content_type>code</content_type>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);
}

test "executeShowPreviewToString sanitizes invalid UTF-8 in content (no error, content_length reflects sanitized size)" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    // 0xFF is an invalid UTF-8 start byte; the sanitizer replaces
    // it with U+FFFD (EF BF BD = 3 bytes). So the input "a\xFFb"
    // (3 bytes) becomes "a\xEF\xBF\xBDb" (5 bytes) after sanitization.
    // The envelope's content_length should be 5, not 3.
    const input = show_preview.ShowPreviewInput{
        .content_type = "text",
        .content = "a\xFFb",
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);
    // content_length is the post-sanitization byte count
    try testing.expect(std.mem.indexOf(u8, xml, "<content_length>5</content_length>") != null);
}

test "validateContentType accepts 'html' alongside the existing 4 types" {
    const alloc = testing.allocator;

    // All 4 pre-existing types must continue to pass (regression check).
    try testing.expect(try show_preview.validateContentType(alloc, "markdown") == null);
    try testing.expect(try show_preview.validateContentType(alloc, "text") == null);
    try testing.expect(try show_preview.validateContentType(alloc, "code") == null);
    try testing.expect(try show_preview.validateContentType(alloc, "image") == null);

    // The new "html" type must also pass — this is the fix.
    try testing.expect(try show_preview.validateContentType(alloc, "html") == null);

    // Make sure the new "html" doesn't accidentally accept "htmlx" or similar.
    {
        const err = try show_preview.validateContentType(alloc, "htmlx");
        defer if (err) |e| alloc.free(e);
        try testing.expect(err != null);
    }
}

test "executeShowPreviewToString returns success envelope for html input" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const input = show_preview.ShowPreviewInput{
        .content_type = "html",
        .content = "<!DOCTYPE html><html><body><h1>Hello</h1></body></html>",
        .title = "Landing page",
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content_type>html</content_type>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);
}

test "executeShowPreviewToString accepts html content with embedded script and closing slashes" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Real-world landing pages have <script> blocks (GA, animations).
    // The tool must accept them and put the content_length in the envelope
    // without the "</script>" sequence corrupting the response shape.
    const input = show_preview.ShowPreviewInput{
        .content_type = "html",
        .content = "<html><body><script>console.log('hi');</script></body></html>",
        .title = "with script",
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content_type>html</content_type>") != null);
}