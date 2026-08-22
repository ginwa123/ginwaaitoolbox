//! Tests for `generate_image.zig` — the OpenAI Images API agent tool.
//!
//! Test strategy mirrors the existing `show_preview_test.zig` convention:
//!   1. Static source-check tests that grep the implementation file
//!      for required substrings (tool name, schema fields, constant
//!      declarations, function signatures). These catch "I forgot to
//!      add the field" / "I renamed the function" regressions
//!      without needing to drive the runtime.
//!   2. Behavioural tests that drive the public helpers
//!      (`validateModelSize`, `buildJsonRequestBody`,
//!      `parseImageResponse`, `saveImageToDisk`, `toXMLSuccess`,
//!      `toXMLError`) directly. The Io runtime is provided by
//!      `std.Io.Threaded.init(testing.allocator, .{})` + `.io()` —
//!      same pattern as `show_preview_test.zig` and
//!      `fire_test.zig`.
//!
//! Plan: docs/superpowers/plans/2026-08-14-generate-image-tool.md

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;
const generate_image = @import("generate_image.zig");

const TOOL_PATH = "src/modules/agent/tools/generate_image.zig";

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

/// Open a fresh `std.Io.Threaded` runtime for tests that need an Io
/// (the save-to-disk helper needs it for `std.Io.Clock.now` and
/// `std.Io.Dir.createFile`). Mirrors the helper in
/// `show_preview_test.zig:59-62` and `fire_test.zig:52-91`.
fn setupIo() std.Io.Threaded {
    const threaded = std.Io.Threaded.init(testing.allocator, .{});
    return threaded;
}

// ─── Static source-check tests (6) ────────────────────────────────────────

test "generate_image tool definition has name \"generate_image\"" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"generate_image\"")) {
        std.debug.print("!! generate_image.zig does not define the tool with .name = \"generate_image\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "generate_image schema has all 8 properties (prompt, model, n, size, quality, style, response_format, user)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    const required_props = [_][]const u8{
        "prompt",
        "model",
        "n",
        "size",
        "quality",
        "style",
        "response_format",
        "user",
    };
    for (required_props) |prop| {
        const needle = try std.fmt.allocPrint(allocator, ".name = \"{s}\"", .{prop});
        defer allocator.free(needle);
        if (!contains(source, needle)) {
            std.debug.print("!! generate_image.zig schema is missing property: {s} !!\n", .{prop});
            return error.SchemaPropertyMissing;
        }
    }
}

test "generate_image schema required array contains prompt" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The `required` array MUST include prompt (the only mandatory field).
    // Accept any case where prompt is one of the entries — exact form is
    // "&.{\"prompt\"}" alone or "&.{\"prompt\", ...}".
    const required_lines = [_][]const u8{
        "required = &.{ \"prompt\" }",
        "required = &.{ \"prompt\",",
    };
    var found = false;
    for (required_lines) |line| {
        if (contains(source, line)) {
            found = true;
            break;
        }
    }
    if (!found) {
        std.debug.print("!! generate_image.zig schema `required` does not include \"prompt\" !!\n", .{});
        return error.RequiredArrayMissingPrompt;
    }
}

test "generate_image defines pub fn execute_generate_image" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execute_generate_image(")) {
        std.debug.print("!! generate_image.zig does not define pub fn execute_generate_image !!\n", .{});
        return error.ExecuteFnMissing;
    }
}

test "generate_image defines MAX_RESPONSE_BYTES cap" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "MAX_RESPONSE_BYTES")) {
        std.debug.print("!! generate_image.zig does not define MAX_RESPONSE_BYTES constant !!\n", .{});
        return error.MaxResponseBytesConstMissing;
    }
}

test "generate_image references custom_http_client (libcurl-backed HTTP)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The implementation MUST use the custom_http_client module
    // (libcurl-backed, cross-platform) — not std.http.Client (which the
    // nalar_browser tool uses for its localhost server, but is not
    // appropriate for HTTPS to api.openai.com). Guards against an
    // accidental std-lib-only stub.
    if (!contains(source, "custom_http_client")) {
        std.debug.print("!! generate_image.zig does not @import(\"custom_http_client\") — must use the libcurl-backed client for api.openai.com !!\n", .{});
        return error.CustomHttpClientMissing;
    }
}

// ─── validateModelSize behavioural tests (8) ─────────────────────────────

test "validateModelSize accepts dall-e-2 with 256x256" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-2", "256x256");
    try testing.expect(err == null);
}

test "validateModelSize accepts dall-e-2 with 512x512" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-2", "512x512");
    try testing.expect(err == null);
}

test "validateModelSize accepts dall-e-2 with 1024x1024" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-2", "1024x1024");
    try testing.expect(err == null);
}

test "validateModelSize accepts dall-e-3 with 1024x1024" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-3", "1024x1024");
    try testing.expect(err == null);
}

test "validateModelSize accepts dall-e-3 with 1792x1024" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-3", "1792x1024");
    try testing.expect(err == null);
}

test "validateModelSize accepts dall-e-3 with 1024x1792" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-3", "1024x1792");
    try testing.expect(err == null);
}

test "validateModelSize rejects dall-e-3 with 512x512" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-3", "512x512");
    try testing.expect(err != null);
    if (err) |msg| {
        defer alloc.free(msg);
        try testing.expect(std.mem.indexOf(u8, msg, "dall-e-3") != null);
        try testing.expect(std.mem.indexOf(u8, msg, "512x512") != null);
    }
}

test "validateModelSize rejects dall-e-2 with 1792x1024" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-2", "1792x1024");
    try testing.expect(err != null);
    if (err) |msg| {
        defer alloc.free(msg);
    }
}

test "validateModelSize rejects unknown model" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dalle-4", "1024x1024");
    try testing.expect(err != null);
    if (err) |msg| {
        defer alloc.free(msg);
        try testing.expect(std.mem.indexOf(u8, msg, "dalle-4") != null);
    }
}

test "validateModelSize rejects unknown size" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-3", "4096x4096");
    try testing.expect(err != null);
    if (err) |msg| {
        defer alloc.free(msg);
    }
}

// ─── buildJsonRequestBody behavioural tests (5) ──────────────────────────

test "buildJsonRequestBody produces correct shape for minimal input (prompt only)" {
    const alloc = testing.allocator;
    const input = generate_image.GenerateImageInput{ .prompt = "a cat" };
    const body = try generate_image.buildJsonRequestBody(alloc, input);
    defer alloc.free(body);

    // Must contain the prompt and the default model + n + response_format
    try testing.expect(std.mem.indexOf(u8, body, "\"prompt\":\"a cat\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"dall-e-3\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"n\":1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"response_format\":\"b64_json\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"size\":\"1024x1024\"") != null);
}

test "buildJsonRequestBody omits optional fields when null (no nulls in JSON)" {
    const alloc = testing.allocator;
    const input = generate_image.GenerateImageInput{ .prompt = "a cat" };
    const body = try generate_image.buildJsonRequestBody(alloc, input);
    defer alloc.free(body);

    // quality, style, user should NOT appear (they're null)
    try testing.expect(std.mem.indexOf(u8, body, "quality") == null);
    try testing.expect(std.mem.indexOf(u8, body, "style") == null);
    try testing.expect(std.mem.indexOf(u8, body, "user") == null);
    try testing.expect(std.mem.indexOf(u8, body, "null") == null);
}

test "buildJsonRequestBody includes all fields when provided" {
    const alloc = testing.allocator;
    const input = generate_image.GenerateImageInput{
        .prompt = "a hat-wearing cat",
        .model = "dall-e-2",
        .n = 3,
        .size = "512x512",
        .quality = "hd",
        .style = "vivid",
        .response_format = "url",
        .user = "user-42",
    };
    const body = try generate_image.buildJsonRequestBody(alloc, input);
    defer alloc.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"prompt\":\"a hat-wearing cat\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"dall-e-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"n\":3") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"size\":\"512x512\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"quality\":\"hd\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"style\":\"vivid\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"response_format\":\"url\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"user\":\"user-42\"") != null);
}

test "buildJsonRequestBody defaults model to dall-e-3 and n to 1" {
    const alloc = testing.allocator;
    const input = generate_image.GenerateImageInput{ .prompt = "x" };
    const body = try generate_image.buildJsonRequestBody(alloc, input);
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"dall-e-3\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"n\":1") != null);
}

test "buildJsonRequestBody defaults response_format to b64_json" {
    const alloc = testing.allocator;
    const input = generate_image.GenerateImageInput{ .prompt = "x" };
    const body = try generate_image.buildJsonRequestBody(alloc, input);
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"response_format\":\"b64_json\"") != null);
}

// ─── parseImageResponse behavioural tests (5) ────────────────────────────

test "parseImageResponse accepts a single-image response with b64_json" {
    const alloc = testing.allocator;
    const body =
        \\{"created":1700000000,"data":[{"b64_json":"iVBORw0KGgo=","revised_prompt":"a happy cat"}]}
    ;
    const images = try generate_image.parseImageResponse(alloc, body);
    defer {
        for (images) |img| {
            if (img.b64_json) |b| alloc.free(b);
            if (img.url) |u| alloc.free(u);
            if (img.revised_prompt) |r| alloc.free(r);
        }
        alloc.free(images);
    }

    try testing.expect(images.len == 1);
    try testing.expect(std.mem.eql(u8, images[0].b64_json.?, "iVBORw0KGgo="));
    try testing.expect(std.mem.eql(u8, images[0].revised_prompt.?, "a happy cat"));
}

test "parseImageResponse accepts a multi-image response with n=2 (DALL-E 2)" {
    const alloc = testing.allocator;
    const body =
        \\{"created":1700000000,"data":[
        \\  {"b64_json":"AAAA"},
        \\  {"b64_json":"BBBB"}
        \\]}
    ;
    const images = try generate_image.parseImageResponse(alloc, body);
    defer {
        for (images) |img| {
            if (img.b64_json) |b| alloc.free(b);
            if (img.url) |u| alloc.free(u);
            if (img.revised_prompt) |r| alloc.free(r);
        }
        alloc.free(images);
    }
    try testing.expect(images.len == 2);
    try testing.expect(std.mem.eql(u8, images[0].b64_json.?, "AAAA"));
    try testing.expect(std.mem.eql(u8, images[1].b64_json.?, "BBBB"));
}

test "parseImageResponse extracts revised_prompt when present" {
    const alloc = testing.allocator;
    const body =
        \\{"created":1,"data":[{"b64_json":"x","revised_prompt":"A vibrant watercolor painting of a cat"}]}
    ;
    const images = try generate_image.parseImageResponse(alloc, body);
    defer {
        for (images) |img| {
            if (img.b64_json) |b| alloc.free(b);
            if (img.url) |u| alloc.free(u);
            if (img.revised_prompt) |r| alloc.free(r);
        }
        alloc.free(images);
    }
    try testing.expect(images[0].revised_prompt != null);
    try testing.expect(std.mem.eql(u8, images[0].revised_prompt.?, "A vibrant watercolor painting of a cat"));
}

test "parseImageResponse handles URL response_format (URL only, no b64_json)" {
    const alloc = testing.allocator;
    const body =
        \\{"created":1,"data":[{"url":"https://example.com/img.png"}]}
    ;
    const images = try generate_image.parseImageResponse(alloc, body);
    defer {
        for (images) |img| {
            if (img.b64_json) |b| alloc.free(b);
            if (img.url) |u| alloc.free(u);
            if (img.revised_prompt) |r| alloc.free(r);
        }
        alloc.free(images);
    }
    try testing.expect(images.len == 1);
    try testing.expect(images[0].b64_json == null);
    try testing.expect(images[0].url != null);
    try testing.expect(std.mem.eql(u8, images[0].url.?, "https://example.com/img.png"));
}

test "parseImageResponse surfaces OpenAI error envelope (HTTP 400-style body)" {
    const alloc = testing.allocator;
    const body =
        \\{"error":{"message":"Invalid model","type":"invalid_request_error","code":"model_not_found"}}
    ;
    const result = generate_image.parseImageResponse(alloc, body);
    try testing.expectError(error.OpenAiError, result);
}

test "parseImageResponse rejects empty data array" {
    const alloc = testing.allocator;
    const body =
        \\{"created":1,"data":[]}
    ;
    const result = generate_image.parseImageResponse(alloc, body);
    try testing.expectError(error.NoImagesReturned, result);
}

// ─── saveImageToDisk behavioural tests (3) ───────────────────────────────

test "saveImageToDisk writes base64 bytes to <cwd>/generated_images/img_<ts>_<idx>.png" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const tmp_cwd = "/tmp/nalar-generate-image-save";
    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_cwd);

    // "iVBORw0KGgo=" decodes to 8 bytes (PNG signature prefix + IHDR start).
    // We don't need a valid PNG for the save test — we just verify the
    // bytes round-trip through disk.
    const path = try generate_image.saveImageToDisk(alloc, io, tmp_cwd, "iVBORw0KGgo=", 0, "image/png");
    defer alloc.free(path);

    try testing.expect(std.mem.endsWith(u8, path, ".png"));
    // Path separator: `/` on POSIX, `\` on Windows. `std.fs.path.join`
    // uses the host's separator, so accept either when checking the
    // subdirectory in the returned path.
    const sep_str: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
    try testing.expect(std.mem.indexOf(u8, path, sep_str ++ "generated_images" ++ sep_str) != null);
    try testing.expect(std.mem.indexOf(u8, path, "img_") != null);

    // Verify the file exists and has the expected content
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer std.Io.File.close(file, io);
    const stat = try std.Io.File.stat(file, io);
    try testing.expect(stat.size == 8);
}

test "saveImageToDisk creates the generated_images subdirectory if missing" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const tmp_cwd = "/tmp/nalar-generate-image-mkdir";
    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_cwd);

    // generated_images/ does NOT exist yet — saveImageToDisk must create it.
    const path = try generate_image.saveImageToDisk(alloc, io, tmp_cwd, "AAAA", 0, "image/png");
    defer alloc.free(path);

    // Verify the dir now exists by writing a sentinel file inside it
    try std.Io.Dir.cwd().createDirPath(io, "/tmp/nalar-generate-image-mkdir/generated_images");
    const f = try std.Io.Dir.cwd().createFile(io, "/tmp/nalar-generate-image-mkdir/generated_images/.sentinel", .{});
    std.Io.File.close(f, io);
}

test "saveImageToDisk rejects when the base64 payload is not valid base64" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    // "not_valid_base64!!!" contains '!' and ' ' which are not in the
    // base64 alphabet. std.base64.standard.Decoder rejects them.
    const result = generate_image.saveImageToDisk(alloc, io, "/tmp/nalar-generate-image-bad-b64", "not_valid_base64!!!", 0, "image/png");
    try testing.expectError(error.InvalidBase64, result);
}

// ─── toXMLSuccess / toXMLError behavioural tests (4) ─────────────────────

test "toXMLSuccess produces the expected envelope shape" {
    const alloc = testing.allocator;
    const images = [_]generate_image.SavedImage{
        .{ .path = "/cwd/generated_images/img_1_0.png", .bytes = 12345, .mime = "image/png" },
    };
    const xml = try generate_image.toXMLSuccess(alloc, "dall-e-3", "1024x1024", &images, "A cat");
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<generate_image>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<status>generated</status>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<model>dall-e-3</model>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<size>1024x1024</size>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<images>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<image ") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "path=\"/cwd/generated_images/img_1_0.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "bytes=\"12345\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "mime=\"image/png\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<revised_prompt>A cat</revised_prompt>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</generate_image>") != null);
}

test "toXMLSuccess omits revised_prompt when null (DALL-E 2)" {
    const alloc = testing.allocator;
    const images = [_]generate_image.SavedImage{
        .{ .path = "/x.png", .bytes = 100, .mime = "image/png" },
    };
    const xml = try generate_image.toXMLSuccess(alloc, "dall-e-2", "512x512", &images, null);
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "revised_prompt") == null);
}

test "toXMLSuccess escapes XML special chars in revised_prompt" {
    const alloc = testing.allocator;
    const images = [_]generate_image.SavedImage{
        .{ .path = "/x.png", .bytes = 100, .mime = "image/png" },
    };
    // The prompt contains '<' and '&' which MUST be escaped, else the
    // envelope is invalid XML.
    const xml = try generate_image.toXMLSuccess(alloc, "dall-e-3", "1024x1024", &images, "A <cat> & a <dog>");
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "&lt;cat&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "&amp;") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<cat>") == null);
}

test "toXMLError produces <generate_image><error>...</error></generate_image>" {
    const alloc = testing.allocator;
    const xml = try generate_image.toXMLError(alloc, "HTTP 401: Invalid API key");
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<generate_image>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>HTTP 401: Invalid API key</error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</generate_image>") != null);
}