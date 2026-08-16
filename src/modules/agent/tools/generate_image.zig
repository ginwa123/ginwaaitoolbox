//! `generate_image` — an agent tool that calls the OpenAI Images API
//! (`POST /v1/images/generations`) to generate images from a text prompt
//! using DALL-E 2 / DALL-E 3 / gpt-image-1.
//!
//! The generated image is saved to `<cwd>/generated_images/img_<ts>_<idx>.png`
//! and the absolute path is returned in an XML envelope. The agent then
//! calls `show_preview` with `content_type="image"` + `path=<path>` to
//! display the image in the chat's side panel.
//!
//! Plan: docs/superpowers/plans/2026-08-14-generate-image-tool.md
//! API:  https://developers.openai.com/api/reference/resources/images/methods/generate

const std = @import("std");
const custom_http_client = @import("custom_http_client");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const ToolProperty = schemas.ToolProperty;

/// Maximum response body size — 4 MiB covers a single DALL-E 3 b64_json
/// payload (1-3 MiB PNG → 1.3-4 MiB base64). 4 MiB also covers a 10-image
/// DALL-E 2 multi-image response comfortably. Exceeding this cap surfaces
/// `error.ResponseTooLarge` to the LLM so it can retry with a smaller
/// `n` or `size` (the LLM knows what it asked for).
pub const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

/// Input structure for the `generate_image` tool. Mirrors the OpenAI
/// Images API request body (POST /v1/images/generations) — every field
/// here corresponds 1:1 to a JSON field the API accepts, with `null`
/// meaning "use OpenAI's default for this parameter".
///
/// Defaults applied at the `buildJsonRequestBody` step (NOT in the
/// struct, so the wire shape stays an accurate mirror of what the LLM
/// sent):
///   - `model`           → "dall-e-3"
///   - `n`               → 1
///   - `size`            → "1024x1024"
///   - `response_format` → "b64_json"
///
/// Fields the LLM can pass (all optional except `prompt`):
///   - `model`           — "dall-e-2" | "dall-e-3" | "gpt-image-1"
///   - `n`               — 1..10 (DALL-E 3 / gpt-image-1 only accept n=1)
///   - `size`            — model-dependent (see `validateModelSize`)
///   - `quality`         — "standard" | "hd" (DALL-E 3 only)
///   - `style`           — "vivid" | "natural" (DALL-E 3 only)
///   - `response_format` — "url" | "b64_json" (we always save to disk
///                         regardless of format; "url" is only useful if
///                         the caller wants the URL too, which we don't
///                         currently expose)
///   - `user`            — end-user identifier forwarded to OpenAI for
///                         abuse detection
pub const GenerateImageInput = struct {
    /// REQUIRED. Description of the image to generate.
    prompt: []const u8,
    /// Model name. `null` → "dall-e-3".
    model: ?[]const u8 = null,
    /// Number of images. `null` → 1. Range 1-10; DALL-E 3 and gpt-image-1
    /// only accept n=1 (OpenAI returns 400 if violated).
    n: ?u8 = null,
    /// Output size. `null` → "1024x1024". Allowed values depend on model
    /// (enforced by `validateModelSize`).
    size: ?[]const u8 = null,
    /// Quality (DALL-E 3 only). Ignored for other models.
    quality: ?[]const u8 = null,
    /// Style (DALL-E 3 only). Ignored for other models.
    style: ?[]const u8 = null,
    /// Response format. `null` → "b64_json". OpenAI's defaults apply if
    /// we don't pass it explicitly — we always pass it for predictability.
    response_format: ?[]const u8 = null,
    /// End-user identifier forwarded to OpenAI for abuse detection.
    user: ?[]const u8 = null,
};

/// One decoded image record from OpenAI's response. Exactly one of
/// `b64_json` / `url` is non-null (depends on `response_format`); the
/// other is null. `revised_prompt` is non-null for DALL-E 3 / gpt-image-1
/// (OpenAI silently rewrites the prompt for safety + clarity) and null
/// for DALL-E 2 (which doesn't rewrite).
pub const ImageRecord = struct {
    b64_json: ?[]const u8 = null,
    url: ?[]const u8 = null,
    revised_prompt: ?[]const u8 = null,
};

/// One saved image ready to be referenced by `<image>` element in the
/// envelope. Path is absolute; `bytes` is the on-disk file size; `mime`
/// is the image MIME type (always `image/png` for now since OpenAI
/// returns PNG, but the field is here for future flexibility).
pub const SavedImage = struct {
    path: []const u8,
    bytes: u64,
    mime: []const u8,
};

// ─── Tool definition ──────────────────────────────────────────────────────

/// Top-level tool definition exposed to the LLM.
///
/// Description is intentionally verbose — it must explain (1) that the
/// tool saves the image to disk and returns a path, (2) that the LLM
/// should call `show_preview` next, and (3) that the active profile's
/// API key is used (no separate key needed).
pub const generate_image_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "generate_image",
        .description =
            \\Generate an image from a text prompt using the OpenAI Images API (POST /v1/images/generations). Supports DALL-E 2, DALL-E 3, and gpt-image-1.
            \\
            \\INPUT: prompt (required, string), model (optional, default "dall-e-3"), n (optional, default 1, max 10), size (optional, default "1024x1024"), quality (optional, dall-e-3 only — "standard"|"hd"), style (optional, dall-e-3 only — "vivid"|"natural"), response_format (optional, default "b64_json" — "url"|"b64_json"), user (optional, end-user id).
            \\
            \\BEHAVIOUR: Calls the OpenAI Images API using the active profile's api_key and base_url (same auth as chat completion — NO separate key needed). Saves the returned image to <cwd>/generated_images/img_<timestamp>_<index>.png. Creates the directory if missing.
            \\
            \\OUTPUT (XML success envelope): <generate_image><status>generated</status><count>N</count><model>...</model><size>...</size><images><image index="0" path="/abs/path/img_xxx.png" bytes="12345" mime="image/png"/></images><revised_prompt>...</revised_prompt></generate_image>. On error: <generate_image><error>HTTP 400: ...OpenAI message...</error></generate_image>.
            \\
            \\NEXT STEP: Call `show_preview` with content_type="image", path=<path from the envelope>, and title=<prompt> (or a truncated version) to display the image in the chat's side panel. The image is durable on disk, so the user can re-view it later.
            \\
            \\IMAGE SIZE NOTE: DALL-E 3 images are 1-5 MB and exceed show_preview's 1 MiB inline content cap — always use `path`, not `content`. DALL-E 2 at 256x256 / 512x512 is small enough to inline if the caller insists.
            \\
            \\AUTH: Active profile's api_key + base_url. Self-hosted DALL-E-compatible endpoints work the same way (just set base_url to the proxy).
        ,
        .parameters = .{
            .type = "object",
            .properties = &[_]ToolProperty{
                .{ .name = "prompt", .type = "string", .description = "A text description of the desired image. Max 1000 characters for dall-e-2, 4000 for dall-e-3 / gpt-image-1. Be specific — subject, style, lighting, composition." },
                .{ .name = "model", .type = "string", .description = "The model to use. One of \"dall-e-2\" (cheaper, allows n>1), \"dall-e-3\" (best quality, default), \"gpt-image-1\" (newest, multimodal)." },
                .{ .name = "n", .type = "string", .description = "Number of images to generate (1-10). DALL-E 3 and gpt-image-1 only accept n=1." },
                .{ .name = "size", .type = "string", .description = "Output size. dall-e-2: \"256x256\", \"512x512\", \"1024x1024\". dall-e-3: \"1024x1024\", \"1792x1024\", \"1024x1792\". gpt-image-1: \"1024x1024\", \"1536x1024\", \"1024x1536\". Default \"1024x1024\"." },
                .{ .name = "quality", .type = "string", .description = "DALL-E 3 only. \"standard\" (default) or \"hd\" (more detail, ~2× cost). Ignored for dall-e-2 / gpt-image-1." },
                .{ .name = "style", .type = "string", .description = "DALL-E 3 only. \"vivid\" (default, hyper-real / dramatic) or \"natural\" (more subdued). Ignored for dall-e-2 / gpt-image-1." },
                .{ .name = "response_format", .type = "string", .description = "\"url\" or \"b64_json\" (default). We always save to disk regardless of format. \"b64_json\" is the standard; \"url\" is only useful if you also want the OpenAI URL (which expires after ~60 min)." },
                .{ .name = "user", .type = "string", .description = "A unique identifier for the end-user. Helps OpenAI detect abuse. Optional." },
            },
            .required = &.{ "prompt" },
        },
    },
};

// ─── Model + size validation ─────────────────────────────────────────────

/// Allowed (model, size) combinations per OpenAI's API docs as of
/// 2026-08-14. The set is small and stable; if OpenAI adds new models
/// or sizes, add them here.
const ModelSizes = struct {
    model: []const u8,
    sizes: []const []const u8,
};

const MODEL_SIZE_TABLE = [_]ModelSizes{
    .{ .model = "dall-e-2", .sizes = &.{ "256x256", "512x512", "1024x1024" } },
    .{ .model = "dall-e-3", .sizes = &.{ "1024x1024", "1792x1024", "1024x1792" } },
    .{ .model = "gpt-image-1", .sizes = &.{ "1024x1024", "1536x1026", "1024x1536" } },
};

/// Validate that `size` is one of the sizes allowed for `model`.
/// Returns `null` on success, or an owned error message string on
/// failure (caller wraps it in the XML error envelope via `toXMLError`).
///
/// Errors are intentionally verbose — they tell the LLM (a) what the
/// offending input was and (b) what the allowed set is, so it can
/// self-correct without trial-and-error round trips.
pub fn validateModelSize(allocator: std.mem.Allocator, model: []const u8, size: []const u8) !?[]u8 {
    for (MODEL_SIZE_TABLE) |entry| {
        if (std.mem.eql(u8, model, entry.model)) {
            for (entry.sizes) |allowed| {
                if (std.mem.eql(u8, size, allowed)) return null;
            }
            // Size not in the allowed list — build an error message
            // listing the allowed sizes for this model.
            var allowed_buf = std.ArrayList(u8).empty;
            defer allowed_buf.deinit(allocator);
            for (entry.sizes, 0..) |s, i| {
                if (i > 0) try allowed_buf.appendSlice(allocator, ", ");
                try allowed_buf.appendSlice(allocator, s);
            }
            const allowed_str = try allowed_buf.toOwnedSlice(allocator);
            defer allocator.free(allowed_str);
            return try std.fmt.allocPrint(
                allocator,
                "size '{s}' is not valid for model '{s}'. Allowed sizes: {s}.",
                .{ size, model, allowed_str },
            );
        }
    }
    // Model not in the table — unknown model
    return try std.fmt.allocPrint(
        allocator,
        "unknown model '{s}'. Allowed models: dall-e-2, dall-e-3, gpt-image-1.",
        .{model},
    );
}

// ─── JSON request body builder ───────────────────────────────────────────

/// Build the JSON request body for `POST /v1/images/generations`. Uses
/// `null`-skipping so we never emit `"field":null` in the JSON — OpenAI
/// returns 400 on some null fields (notably `n` when omitted-then-null
/// in some SDKs). Pure-data — no I/O, no HTTP, easy to test.
pub fn buildJsonRequestBody(allocator: std.mem.Allocator, input: GenerateImageInput) ![]u8 {
    var json: std.ArrayList(u8) = .empty;
    errdefer json.deinit(allocator);

    // Apply defaults
    const model = input.model orelse "dall-e-3";
    const n: u8 = input.n orelse 1;
    const size = input.size orelse "1024x1024";
    const response_format = input.response_format orelse "b64_json";

    try json.append(allocator, '{');

    // prompt (required)
    try json.appendSlice(allocator, "\"prompt\":\"");
    const ep = try xmlEscape(allocator, input.prompt);
    defer allocator.free(ep);
    try json.appendSlice(allocator, ep);
    try json.append(allocator, '"');

    // model
    try json.appendSlice(allocator, ",\"model\":\"");
    try json.appendSlice(allocator, model);
    try json.append(allocator, '"');

    // n (number, no quotes)
    try json.appendSlice(allocator, ",\"n\":");
    var n_buf: [16]u8 = undefined;
    const n_str = std.fmt.bufPrint(&n_buf, "{d}", .{n}) catch unreachable;
    try json.appendSlice(allocator, n_str);

    // size
    try json.appendSlice(allocator, ",\"size\":\"");
    try json.appendSlice(allocator, size);
    try json.append(allocator, '"');

    // quality (optional)
    if (input.quality) |q| {
        try json.appendSlice(allocator, ",\"quality\":\"");
        try json.appendSlice(allocator, q);
        try json.append(allocator, '"');
    }

    // style (optional)
    if (input.style) |s| {
        try json.appendSlice(allocator, ",\"style\":\"");
        try json.appendSlice(allocator, s);
        try json.append(allocator, '"');
    }

    // response_format
    try json.appendSlice(allocator, ",\"response_format\":\"");
    try json.appendSlice(allocator, response_format);
    try json.append(allocator, '"');

    // user (optional)
    if (input.user) |u| {
        try json.appendSlice(allocator, ",\"user\":\"");
        try json.appendSlice(allocator, u);
        try json.append(allocator, '"');
    }

    try json.append(allocator, '}');
    return try json.toOwnedSlice(allocator);
}

// ─── JSON response parser ────────────────────────────────────────────────

/// Parse an OpenAI Images API response body. Returns one `ImageRecord`
/// per image in the `data` array. Caller owns the returned slice AND
/// every non-null `b64_json` / `url` / `revised_prompt` slice inside.
///
/// Errors:
///   - `error.InvalidJson` — body is not valid JSON or has the wrong shape
///   - `error.OpenAiError` — body is the OpenAI error envelope
///                            (`{"error":{"message":"..."}}`)
///   - `error.NoImagesReturned` — `data` array is missing or empty
pub fn parseImageResponse(allocator: std.mem.Allocator, body: []const u8) ![]ImageRecord {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    // OpenAI error envelope: {"error": {"message": "...", ...}}
    if (root.object.get("error")) |_| {
        return error.OpenAiError;
    }

    // Walk the data array
    const data_val = root.object.get("data") orelse return error.NoImagesReturned;
    if (data_val != .array) return error.NoImagesReturned;
    if (data_val.array.items.len == 0) return error.NoImagesReturned;

    const images = try allocator.alloc(ImageRecord, data_val.array.items.len);
    errdefer {
        for (images[0..data_val.array.items.len]) |img| {
            if (img.b64_json) |v| allocator.free(@constCast(v));
            if (img.url) |v| allocator.free(@constCast(v));
            if (img.revised_prompt) |v| allocator.free(@constCast(v));
        }
        allocator.free(images);
    }

    for (data_val.array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidJson;

        var b64: ?[]const u8 = null;
        var url: ?[]const u8 = null;
        var rp: ?[]const u8 = null;

        if (item.object.get("b64_json")) |v| {
            if (v == .string) b64 = try allocator.dupe(u8, v.string);
        }
        if (item.object.get("url")) |v| {
            if (v == .string) url = try allocator.dupe(u8, v.string);
        }
        if (item.object.get("revised_prompt")) |v| {
            if (v == .string) rp = try allocator.dupe(u8, v.string);
        }

        images[i] = .{ .b64_json = b64, .url = url, .revised_prompt = rp };
    }

    return images;
}

// ─── Save image to disk ──────────────────────────────────────────────────

/// Decode `b64_payload` (base64) and write the raw bytes to
/// `<cwd>/generated_images/img_<unix_ms>_<index>.<ext>`. Returns the
/// absolute path. Creates the `generated_images/` subdirectory if missing.
///
/// `mime` drives the file extension (always `image/png` from OpenAI,
/// but the parameter exists for future flexibility).
pub fn saveImageToDisk(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    b64_payload: []const u8,
    index: usize,
    mime: []const u8,
) ![]u8 {
    const decoder = &std.base64.standard.Decoder;

    // 1. Decode base64 → raw bytes
    const decoded_len = decoder.calcSizeForSlice(b64_payload) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    decoder.decode(decoded, b64_payload) catch return error.InvalidBase64;

    // 2. Resolve filename + compose the absolute path up front so the
    //    I/O calls below write to the right place (the cwd passed by
    //    the caller is the canonical absolute path; we don't chdir).
    const ts = std.Io.Clock.now(.real, io).toMilliseconds();
    const ext = extForMime(mime);
    const filename = try std.fmt.allocPrint(allocator, "img_{d}_{d}.{s}", .{ ts, index, ext });
    defer allocator.free(filename);

    const abs_path = try std.fs.path.join(allocator, &.{ cwd, "generated_images", filename });
    errdefer allocator.free(abs_path);

    // 3. Create the parent directory (mkdir -p). Idempotent — no
    //    error if the dir already exists. Extract the parent dir from
    //    the absolute path so we don't depend on process cwd.
    const parent_dir = std.fs.path.dirname(abs_path) orelse abs_path;
    try std.Io.Dir.cwd().createDirPath(io, parent_dir);

    // 4. Write the file at the absolute path.
    const file = try std.Io.Dir.cwd().createFile(io, abs_path, .{});
    defer std.Io.File.close(file, io);
    try std.Io.File.writeStreamingAll(file, io, decoded);

    return abs_path;
}

/// Map an image MIME type to its conventional file extension.
/// OpenAI always returns PNG today; the function is here for forward
/// compatibility (gpt-image-1 may return other formats in the future).
fn extForMime(mime: []const u8) []const u8 {
    if (std.mem.eql(u8, mime, "image/png")) return "png";
    if (std.mem.eql(u8, mime, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, mime, "image/webp")) return "webp";
    if (std.mem.eql(u8, mime, "image/gif")) return "gif";
    return "png"; // safe default — PNG decoders exist everywhere
}

/// Read the file size of a just-written image. Returns 0 on any error
/// (open failure, stat failure) — the LLM still gets a valid path; the
/// size is metadata, not part of the tool's correctness contract.
fn statFileSize(io: std.Io, path: []const u8) u64 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer std.Io.File.close(file, io);
    const stat = std.Io.File.stat(file, io) catch return 0;
    return stat.size;
}

// ─── XML helpers ─────────────────────────────────────────────────────────

/// Escape XML special characters. Mirrors the helper in
/// `show_preview.zig:149-165` (duplicated per project convention —
/// every tool file has its own copy).
fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Build the success envelope:
/// `<generate_image><status>generated</status><count>N</count><model>...</model><size>...</size><images>...</images><revised_prompt>...</revised_prompt></generate_image>`
pub fn toXMLSuccess(
    allocator: std.mem.Allocator,
    model: []const u8,
    size: []const u8,
    images: []const SavedImage,
    revised_prompt: ?[]const u8,
) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<generate_image>");
    try xml.appendSlice(allocator, "<status>generated</status>");

    // <count>
    var count_buf: [16]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{images.len}) catch unreachable;
    try xml.appendSlice(allocator, "<count>");
    try xml.appendSlice(allocator, count_str);
    try xml.appendSlice(allocator, "</count>");

    // <model>
    try xml.appendSlice(allocator, "<model>");
    const em = try xmlEscape(allocator, model);
    defer allocator.free(em);
    try xml.appendSlice(allocator, em);
    try xml.appendSlice(allocator, "</model>");

    // <size>
    try xml.appendSlice(allocator, "<size>");
    const es = try xmlEscape(allocator, size);
    defer allocator.free(es);
    try xml.appendSlice(allocator, es);
    try xml.appendSlice(allocator, "</size>");

    // <images>
    try xml.appendSlice(allocator, "<images>");
    for (images, 0..) |img, i| {
        try xml.appendSlice(allocator, "<image index=\"");
        var idx_buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
        try xml.appendSlice(allocator, idx_str);
        try xml.appendSlice(allocator, "\" path=\"");
        const ep = try xmlEscape(allocator, img.path);
        defer allocator.free(ep);
        try xml.appendSlice(allocator, ep);
        try xml.appendSlice(allocator, "\" bytes=\"");
        var bytes_buf: [32]u8 = undefined;
        const bytes_str = std.fmt.bufPrint(&bytes_buf, "{d}", .{img.bytes}) catch unreachable;
        try xml.appendSlice(allocator, bytes_str);
        try xml.appendSlice(allocator, "\" mime=\"");
        const emime = try xmlEscape(allocator, img.mime);
        defer allocator.free(emime);
        try xml.appendSlice(allocator, emime);
        try xml.appendSlice(allocator, "\" />");
    }
    try xml.appendSlice(allocator, "</images>");

    // <revised_prompt> (omitted when null — DALL-E 2 doesn't rewrite)
    if (revised_prompt) |rp| {
        try xml.appendSlice(allocator, "<revised_prompt>");
        const erp = try xmlEscape(allocator, rp);
        defer allocator.free(erp);
        try xml.appendSlice(allocator, erp);
        try xml.appendSlice(allocator, "</revised_prompt>");
    }

    try xml.appendSlice(allocator, "</generate_image>");
    return try xml.toOwnedSlice(allocator);
}

/// Build the error envelope: `<generate_image><error>...</error></generate_image>`.
/// `error_msg` is XML-escaped before insertion.
pub fn toXMLError(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<generate_image><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></generate_image>");
    return try xml.toOwnedSlice(allocator);
}

// ─── HTTP execution ──────────────────────────────────────────────────────

/// Execute the `generate_image` tool end-to-end:
///   1. Validate `prompt` (non-empty)
///   2. Apply defaults for `model`, `n`, `size`, `response_format`
///   3. Validate `model` + `size` compatibility
///   4. Build the JSON request body
///   5. POST `<base_url>/images/generations` with `Authorization: Bearer <api_key>`
///   6. Parse the JSON response
///   7. Save each image to `<cwd>/generated_images/img_<ts>_<idx>.png`
///   8. Build and return the XML success envelope
///
/// On any error (validation, HTTP, parse, save-to-disk), returns an
/// XML error envelope via `toXMLError`. The LLM sees the failure as
/// `<generate_image><error>...</error></generate_image>` — same wire
/// shape as a success result, just with `<error>` instead of `<status>`.
///
/// Caller owns the returned slice (freed via `allocator.free`).
pub fn execute_generate_image(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: GenerateImageInput,
    base_url: []const u8,
    api_key: []const u8,
    cwd: []const u8,
) ![]u8 {
    // 1. Validate prompt (non-empty)
    if (input.prompt.len == 0) {
        return toXMLError(allocator, "prompt is required and must be non-empty");
    }

    // 2. Apply defaults
    const model = input.model orelse "dall-e-3";
    const size = input.size orelse "1024x1024";
    const response_format = input.response_format orelse "b64_json";

    // 3. Validate model + size
    if (try validateModelSize(allocator, model, size)) |err_msg| {
        defer allocator.free(err_msg);
        return toXMLError(allocator, err_msg);
    }

    // If the user asked for "url" response_format, surface a clear
    // warning — we don't currently return the URL in the envelope, so
    // the user would be confused why their url param had no effect.
    if (!std.mem.eql(u8, response_format, "b64_json")) {
        std.log.warn("generate_image: response_format={s} requested — image is still saved to disk; URL is not returned in the envelope", .{response_format});
    }

    // 4. Build the JSON request body
    const json_body = buildJsonRequestBody(allocator, input) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "buildJsonRequestBody failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return toXMLError(allocator, msg);
    };
    defer allocator.free(json_body);

    // 5. Compose URL: <base_url> + "/images/generations"
    const endpoint = "/images/generations";
    const uri_str = std.mem.concat(allocator, u8, &.{ base_url, endpoint }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "concat URI failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return toXMLError(allocator, msg);
    };
    defer allocator.free(uri_str);

    // Validate the URL scheme BEFORE handing to libcurl (same pattern
    // as Agent.zig:1799-1821 — a missing scheme surfaces as
    // CURLE_UNSUPPORTED_PROTOCOL with no hint about WHY).
    if (!std.mem.startsWith(u8, uri_str, "http://") and
        !std.mem.startsWith(u8, uri_str, "https://"))
    {
        const msg = try std.fmt.allocPrint(
            allocator,
            "baseUrl+endpoint={s} has no http:// or https:// scheme — check api_key/base_url in config",
            .{uri_str},
        );
        defer allocator.free(msg);
        return toXMLError(allocator, msg);
    }

    // 6. Build auth header + request
    const auth_value = try std.mem.concat(allocator, u8, &.{ "Bearer ", api_key });
    defer allocator.free(auth_value);

    const headers = [_]custom_http_client.Header{
        .{ .name = "authorization", .value = auth_value },
        .{ .name = "content-type", .value = "application/json" },
    };

    const req = custom_http_client.Request{
        .method = .POST,
        .url = uri_str,
        .headers = &headers,
        .body = json_body,
    };

    // Timeouts: 60 s connect + 120 s total. DALL-E 3 generation takes
    // 5-30 s typically, gpt-image-1 can be slower for large sizes.
    const options = custom_http_client.Options{
        .timeout_ms = 120_000,
        .connect_timeout_ms = 30_000,
        .follow_redirects = false,
        .verify_ssl = true,
    };

    // 7. Perform the request
    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    var response = client.perform(req, options) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "HTTP request failed: {s}",
            .{@errorName(err)},
        );
        defer allocator.free(msg);
        return toXMLError(allocator, msg);
    };
    defer response.deinit(allocator);

    // 8. Check the status code
    if (response.status_code >= 400) {
        // Try to surface OpenAI's actual error message. Their error
        // envelope is `{"error":{"message":"...", ...}}`. parseImageResponse
        // returns `error.OpenAiError` for that shape — we use it as a
        // uniform "extract the message" path, then read the raw body for
        // the `message` string.
        var msg_buf: std.ArrayList(u8) = .empty;
        defer msg_buf.deinit(allocator);
        try msg_buf.print(allocator, "HTTP {d}", .{response.status_code});
        if (extractOpenAiErrorMessage(allocator, response.body)) |extracted| {
            defer allocator.free(extracted);
            try msg_buf.print(allocator, ": {s}", .{extracted});
        }
        return toXMLError(allocator, msg_buf.items);
    }

    // Enforce the response-size cap BEFORE parsing (a runaway server
    // response shouldn't OOM the LLM context).
    if (response.body.len > MAX_RESPONSE_BYTES) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "response body size {d} exceeds MAX_RESPONSE_BYTES ({d}) — retry with smaller `n` or `size`",
            .{ response.body.len, MAX_RESPONSE_BYTES },
        );
        defer allocator.free(msg);
        return toXMLError(allocator, msg);
    }

    // 9. Parse the response
    const images = parseImageResponse(allocator, response.body) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "parseImageResponse failed: {s}",
            .{@errorName(err)},
        );
        defer allocator.free(msg);
        return toXMLError(allocator, msg);
    };
    defer {
        for (images) |img| {
            if (img.b64_json) |v| allocator.free(@constCast(v));
            if (img.url) |v| allocator.free(@constCast(v));
            if (img.revised_prompt) |v| allocator.free(@constCast(v));
        }
        allocator.free(images);
    }

    // 10. Save each image to disk and collect SavedImage records.
    //     If a save fails, abort and return the error envelope (the
    //     user explicitly asked for the image; partial results are
    //     worse than a clean failure).
    var saved = try allocator.alloc(SavedImage, images.len);
    errdefer {
        for (saved[0..images.len]) |s| allocator.free(@constCast(s.path));
        allocator.free(saved);
    }

    var last_revised: ?[]const u8 = null;

    for (images, 0..) |img, i| {
        // Only b64_json is supported for saving (we don't follow
        // external URLs — the OpenAI URL expires in 60 min anyway).
        const b64 = img.b64_json orelse {
            const msg = try std.fmt.allocPrint(
                allocator,
                "image {d} has no b64_json field — response_format must be \"b64_json\" (URL format is not saved to disk; OpenAI URLs expire after ~60 min)",
                .{i},
            );
            defer allocator.free(msg);
            return toXMLError(allocator, msg);
        };

        const path = saveImageToDisk(allocator, io, cwd, b64, i, "image/png") catch |err| {
            const msg = try std.fmt.allocPrint(
                allocator,
                "saveImageToDisk failed for image {d}: {s}",
                .{ i, @errorName(err) },
            );
            defer allocator.free(msg);
            return toXMLError(allocator, msg);
        };

        // Read back the file size so the LLM sees an honest number
        // (instead of "0" or the b64 length which differs). On stat
        // failure, fall back to 0 — the LLM still gets a valid path.
        const stat_size: u64 = statFileSize(io, path);
        saved[i] = .{ .path = path, .bytes = stat_size, .mime = "image/png" };

        // Capture the last revised_prompt (DALL-E 3 / gpt-image-1 return
        // one for every image; for n>1 we use the last one in the
        // envelope since they're all the same model + same prompt).
        if (img.revised_prompt) |rp| {
            last_revised = rp;
        }
    }

    // 11. Build the success envelope.
    //     Note: `last_revised` is borrowed from `images[i].revised_prompt`
    //     — we MUST not free it. The `defer` above handles the cleanup.
    const envelope = toXMLSuccess(allocator, model, size, saved, last_revised) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "toXMLSuccess failed: {s}",
            .{@errorName(err)},
        );
        defer allocator.free(msg);
        return toXMLError(allocator, msg);
    };

    // saved[].path was allocated by std.fs.path.join in saveImageToDisk —
    // ownership transfers to the envelope? No, the envelope only
    // references the path strings as slices. We have to free them now
    // that we're done.
    for (saved) |s| allocator.free(@constCast(s.path));
    allocator.free(saved);

    return envelope;
}

/// Extract OpenAI's `error.message` field from an error response body.
/// Returns null if the body is not the error envelope or doesn't have
/// the expected shape — caller falls back to a generic message.
fn extractOpenAiErrorMessage(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const err_val = root.object.get("error") orelse return null;
    if (err_val != .object) return null;

    const msg_val = err_val.object.get("message") orelse return null;
    if (msg_val != .string) return null;

    return allocator.dupe(u8, msg_val.string) catch null;
}