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
// ─── Behavioral tests for the `path` parameter (show-preview-local-file) ─
//
// Plan: docs/superpowers/plans/2026-08-06-show-preview-local-file.md
// The `path` parameter lets the agent hand the server an absolute path to
// a local image file; the server reads + MIME-sniffs + base64-encodes the
// bytes and emits the same `<show_preview>` envelope a hand-written data
// URL would produce. Frontend unchanged — the existing `imageSrc` computed
// in PreviewContentRenderer.vue already renders `data:` URLs.
//
// These tests are RED before the implementation lands in show_preview.zig
// (the helper and the schema field don't exist yet). All tests use a
// per-test temp dir that is cleaned up by `defer deleteTree`.

// Smallest valid PNG (1x1 transparent). 67 bytes pre-baked so the test
// does not need anything beyond std.io + the magic bytes. The PNG
// signature is 89 50 4E 47 0D 0A 1A 0A; the rest is minimal IHDR + IDAT
// + IEND.
const TEST_PNG_BYTES: [67]u8 = .{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk header
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // width=1, height=1
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, // 8-bit RGBA + CRC
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, // IDAT chunk header
    0x54, 0x08, 0x99, 0x63, 0x00, 0x01, 0x00, 0x00, // zlib-deflated 0,0,0,0
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, // CRC
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, // IEND chunk header
    0x42, 0x60, 0x82, // CRC
};

// Smallest valid JPEG (1x1 white, JFIF). 254 bytes.
const TEST_JPEG_BYTES: [254]u8 = .{
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
    0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08,
    0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
    0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20, 0x24, 0x2E, 0x27, 0x20,
    0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29, 0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27,
    0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
    0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04,
    0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
    0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D, 0x01, 0x02, 0x03, 0x00,
    0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32,
    0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
    0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x34, 0x35,
    0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55,
    0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
    0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD0, 0xFF, 0xD9,
};

// Smallest valid GIF87a (1x1 transparent). 42 bytes.
const TEST_GIF_BYTES: [42]u8 = .{
    0x47, 0x49, 0x46, 0x38, 0x37, 0x61, // "GIF87a"
    0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, // width=1, height=1, GCT flag
    0x00, 0x00, 0xFF, 0xFF, 0xFF, // 2-color palette: black + white
    0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, // GCE
    0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, // image descriptor
    0x00, 0x02, 0x02, 0x44, 0x01, 0x00, // LZW min code size + 0-length block
    0x3B, // trailer
};

// Smallest valid WebP (1x1 VP8L lossless). 32 bytes — RIFF header + WEBP
// + VP8L chunk + 1-byte payload.
const TEST_WEBP_BYTES: [32]u8 = .{
    0x52, 0x49, 0x46, 0x46, // "RIFF"
    0x1A, 0x00, 0x00, 0x00, // file size - 8 (little-endian: 26)
    0x57, 0x45, 0x42, 0x50, // "WEBP"
    0x56, 0x50, 0x38, 0x4C, // "VP8L"
    0x0D, 0x00, 0x00, 0x00, // chunk size - 8 (little-endian: 13)
    0x2F, 0x00, 0x00, 0x00, 0x00, // signature byte 0x2F + width=1
    0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0x08, // packed
};

/// Write `bytes` to `<tmp_dir>/<name>` and return the absolute path.
/// Caller owns the returned path (must free with `allocator.free`).
fn writeTestFile(allocator: std.mem.Allocator, io: std.Io, tmp_dir: []const u8, name: []const u8, bytes: []const u8) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    const path = try std.fs.path.join(allocator, &.{ tmp_dir, name });
    errdefer allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer std.Io.File.close(file, io);
    try std.Io.File.writeStreamingAll(file, io, bytes);
    return path;
}

test "resolveImageContentFromPath returns data:image/png;base64,... for a valid PNG" {
    const alloc = testing.allocator;
    const io = testing.io;

    const tmp_dir = "/tmp/nalar-show-preview-path-png";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const path = try writeTestFile(alloc, io, tmp_dir, "tiny.png", &TEST_PNG_BYTES);
    defer alloc.free(path);

    const data_url = try show_preview.resolveImageContentFromPath(alloc, io, path);
    defer alloc.free(data_url);

    // Must start with the PNG data URL prefix
    try testing.expect(std.mem.startsWith(u8, data_url, "data:image/png;base64,"));
    // The base64-encoded payload follows. Sanity: a 67-byte PNG encodes
    // to ceil(67/3)*4 = 92 base64 chars (with padding).
    const prefix_len = "data:image/png;base64,".len;
    try testing.expect(data_url.len > prefix_len);
}

test "resolveImageContentFromPath detects JPEG via FF D8 FF magic bytes" {
    const alloc = testing.allocator;
    const io = testing.io;

    const tmp_dir = "/tmp/nalar-show-preview-path-jpeg";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const path = try writeTestFile(alloc, io, tmp_dir, "tiny.jpg", &TEST_JPEG_BYTES);
    defer alloc.free(path);

    const data_url = try show_preview.resolveImageContentFromPath(alloc, io, path);
    defer alloc.free(data_url);

    try testing.expect(std.mem.startsWith(u8, data_url, "data:image/jpeg;base64,"));
}

test "resolveImageContentFromPath detects GIF via GIF87a/GIF89a magic bytes" {
    const alloc = testing.allocator;
    const io = testing.io;

    const tmp_dir = "/tmp/nalar-show-preview-path-gif";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const path = try writeTestFile(alloc, io, tmp_dir, "tiny.gif", &TEST_GIF_BYTES);
    defer alloc.free(path);

    const data_url = try show_preview.resolveImageContentFromPath(alloc, io, path);
    defer alloc.free(data_url);

    try testing.expect(std.mem.startsWith(u8, data_url, "data:image/gif;base64,"));
}

test "resolveImageContentFromPath detects WebP via RIFF....WEBP magic bytes" {
    const alloc = testing.allocator;
    const io = testing.io;

    const tmp_dir = "/tmp/nalar-show-preview-path-webp";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const path = try writeTestFile(alloc, io, tmp_dir, "tiny.webp", &TEST_WEBP_BYTES);
    defer alloc.free(path);

    const data_url = try show_preview.resolveImageContentFromPath(alloc, io, path);
    defer alloc.free(data_url);

    try testing.expect(std.mem.startsWith(u8, data_url, "data:image/webp;base64,"));
}

test "resolveImageContentFromPath rejects file with unknown magic bytes" {
    const alloc = testing.allocator;
    const io = testing.io;

    const tmp_dir = "/tmp/nalar-show-preview-path-bad";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    // Plain text file with no image magic bytes
    const garbage = "this is not an image at all, just plain text\n";
    const path = try writeTestFile(alloc, io, tmp_dir, "garbage.bin", garbage);
    defer alloc.free(path);

    const result = show_preview.resolveImageContentFromPath(alloc, io, path);
    try testing.expectError(error.UnsupportedImageFormat, result);
}

test "resolveImageContentFromPath rejects missing file with FileNotFound" {
    const alloc = testing.allocator;
    const io = testing.io;

    const result = show_preview.resolveImageContentFromPath(
        alloc,
        io,
        "/tmp/nalar-show-preview-does-not-exist/nope.png",
    );
    try testing.expectError(error.FileNotFound, result);
}

test "resolveImageContentFromPath rejects file exceeding MAX_CONTENT_BYTES" {
    const alloc = testing.allocator;
    const io = testing.io;

    const tmp_dir = "/tmp/nalar-show-preview-path-huge";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    // Build a PNG-tagged file larger than MAX_CONTENT_BYTES. The file
    // STARTS with valid PNG magic bytes so MIME sniff succeeds; the
    // rest is zero-padding. After base64 encoding, the resulting data
    // URL will exceed the 1 MiB cap.
    const oversize = show_preview.MAX_CONTENT_BYTES + 1;
    var buf = try alloc.alloc(u8, oversize);
    defer alloc.free(buf);
    @memcpy(buf[0..8], TEST_PNG_BYTES[0..8]);
    @memset(buf[8..], 0);

    const path = try writeTestFile(alloc, io, tmp_dir, "huge.png", buf);
    defer alloc.free(path);

    const result = show_preview.resolveImageContentFromPath(alloc, io, path);
    try testing.expectError(error.ImageTooLarge, result);
}

test "executeShowPreviewToString with path-only image returns success envelope" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const tmp_dir = "/tmp/nalar-show-preview-exec-png";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const path = try writeTestFile(alloc, io, tmp_dir, "specimen.png", &TEST_PNG_BYTES);
    defer alloc.free(path);

    // The new `path` field is non-null; `content` is the empty string
    // (mutual exclusivity — content carries the rendered payload AFTER
    // resolution, but the LLM only supplies one of the two).
    const input = show_preview.ShowPreviewInput{
        .content_type = "image",
        .content = "",
        .path = path,
        .title = "Specimen",
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content_type>image</content_type>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);
    // content_length reflects the base64-encoded data URL, not the raw PNG
    const prefix_len: usize = "data:image/png;base64,".len;
    const expected_b64_len = ((TEST_PNG_BYTES.len + 2) / 3) * 4;
    const expected_total = prefix_len + expected_b64_len;
    // 64 bytes covers "<content_length>N</content_length>" (31 fixed chars)
    // with up to 33 digits of headroom for the content_length value.
    var len_buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&len_buf, "<content_length>{d}</content_length>", .{expected_total});
    try testing.expect(std.mem.indexOf(u8, xml, needle) != null);
}

test "executeShowPreviewToString rejects when both content AND path are provided" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const tmp_dir = "/tmp/nalar-show-preview-exec-both";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const path = try writeTestFile(alloc, io, tmp_dir, "specimen.png", &TEST_PNG_BYTES);
    defer alloc.free(path);

    const input = show_preview.ShowPreviewInput{
        .content_type = "image",
        .content = "data:image/png;base64,AAAA",
        .path = path,
        .title = "Specimen",
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "content") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "path") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") == null);
}

test "executeShowPreviewToString rejects path when content_type is not \"image\"" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const tmp_dir = "/tmp/nalar-show-preview-exec-wrong-ct";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const path = try writeTestFile(alloc, io, tmp_dir, "specimen.png", &TEST_PNG_BYTES);
    defer alloc.free(path);

    // markdown + path is nonsensical — the LLM should use `content` for
    // non-image types. The error message guides the LLM to call again
    // with `content_type: "image"` or drop the `path`.
    const input = show_preview.ShowPreviewInput{
        .content_type = "markdown",
        .content = "# hello",
        .path = path,
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "image") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "path") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") == null);
}

test "executeShowPreviewToString with content-only image still works (back-compat regression)" {
    // The existing 4-type behaviour for `content`-only images must not
    // regress when `path` is added to the schema. The LLM should still
    // be able to send a hand-written data URL or http(s) URL via
    // `content` without ever touching `path`.
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const input = show_preview.ShowPreviewInput{
        .content_type = "image",
        .content = "data:image/png;base64,iVBORw0KGgoAAAA==",
        // .path left null (default)
    };
    var preview_id: []u8 = undefined;
    const xml = try show_preview.executeShowPreviewToString(alloc, io, input, &preview_id);
    defer alloc.free(xml);
    defer alloc.free(preview_id);

    try testing.expect(std.mem.indexOf(u8, xml, "<status>shown</status>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content_type>image</content_type>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);
}

test "ShowPreviewInput schema has the new path property" {
    // Static source check: the schema MUST include the new `path` field
    // so the LLM can call it. If a future refactor drops the field, the
    // LLM would silently fall back to data-URL-only behaviour and the
    // feature would break in production.
    const alloc = testing.allocator;
    const source = try readSource(alloc, TOOL_PATH);
    defer alloc.free(source);
    if (!contains(source, ".name = \"path\"")) {
        std.debug.print("!! show_preview.zig schema is missing property: path !!\n", .{});
        return error.SchemaPropertyMissing;
    }
}
