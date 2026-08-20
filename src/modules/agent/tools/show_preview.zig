//! `show_preview` — an agent tool that pushes visual content
//! (markdown, text, code, images) to the frontend side panel.
//!
//! The LLM calls this tool to render rich content alongside the chat
//! transcript (e.g. when summarizing a file, presenting a code diff,
//! or showing a generated diagram). The content is NOT written to
//! the chat history — it lives only in the side panel — so the tool
//! is distinct from any "save to chat" / "save to memory" tool.
//!
//! Response shape: an XML envelope (per project convention, like
//! `kanban_list.zig`):
//!   <show_preview>
//!     <status>shown</status>
//!     <preview_id>pv_1782850123456_a8b3c2</preview_id>
//!     <content_type>markdown</content_type>
//!     <content_length>NN</content_length>
//!   </show_preview>
//!
//! On error:
//!   <show_preview><error>...</error></show_preview>
//!
//! Plan: docs/superpowers/plans/2026-06-30-feat-show-preview.md
//! Design: docs/plans/2026-06-29-show-preview-design.md

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const helpers = @import("helpers");

/// Hard cap on the size of a single preview's `content` payload.
/// Set to 1 MiB so even a large markdown rendering or a base64 image
/// stays well under the SSE payload limits (see
/// `custom_http_server/sse_manager.zig` for the max-chunk-size
/// constant). If the LLM sends more, validation rejects it with a
/// clear error so the LLM can split the content.
pub const MAX_CONTENT_BYTES: usize = 1 * 1024 * 1024;

/// Hex alphabet used for the random suffix of the preview id.
/// Mirrors `helpers/random.zig:hex_digits` (kept local for the same
/// reason `xmlEscape` is duplicated — tool files are self-contained).
const HEX_DIGITS = "0123456789abcdef";

/// Input structure for the `show_preview` tool.
///
/// Fields mirror the OpenAI-style tool schema (see
/// `show_preview_tool` below). The LLM provides:
///   - `content_type` — one of "markdown", "text", "code", "image",
///                      "html"
///   - `content`      — the raw payload (markdown source, plain text,
///                      code source, or for "image" a data URI / URL).
///                      **For "image", either `content` OR `path` must
///                      be provided — not both.** When `path` is given,
///                      the server reads the file, MIME-sniffs via
///                      magic bytes, base64-encodes the bytes, and emits
///                      a `data:` URL the same as a hand-written
///                      `content` would.
///   - `path`         — ABSOLUTE path to a local image file. Only valid
///                      when `content_type == "image"`. The server reads
///                      + MIME-sniffs + base64-encodes the file and
///                      returns the same shape as a `content` data URL.
///                      Cap is the same 1 MiB (so local files must be
///                      ≤ ~750 KB raw to fit after base64 expansion).
///                      Security: same threat model as `read_file` —
///                      the LLM can read anything the `nalar` process
///                      can read. No sandboxing.
///   - `title`        — optional caption shown above the content
///   - `language`     — required when content_type == "code"
///                      (e.g. "zig", "python"); ignored otherwise
///   - `caption`      — optional caption shown BELOW the content
pub const ShowPreviewInput = struct {
    content_type: []const u8,
    content: []const u8,
    path: ?[]const u8 = null,
    title: ?[]const u8 = null,
    language: ?[]const u8 = null,
    caption: ?[]const u8 = null,
};

/// Top-level tool definition exposed to the LLM.
///
/// Description MUST mention "side panel" so the LLM picks this tool
/// (not e.g. `add_memory` or `write_file`) when the user asks to
/// "show", "display", "preview", or "render" something — without
/// that hint the LLM would write to the chat transcript and miss
/// the rich-rendering side panel entirely.
pub const show_preview_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "show_preview",
        .description =
            \\Render rich content (markdown, plain text, source code, or an image) in the chat's side panel. Use this tool when the user asks to "show", "display", "preview", "render", or "visualize" something — markdown summaries, formatted code blocks, generated diagrams, images, etc. The content is rendered ONLY in the side panel (NOT appended to the chat transcript), so the tool is best for ephemeral / visualization purposes.
            \\
            \\The content_type must be one of "markdown", "text", "code", "image", or "html". For "code", you MUST also pass the language field (e.g. "zig", "python", "javascript") so the side panel can apply syntax highlighting. For "html", the content is rendered inside a sandboxed iframe with allow-scripts enabled (no allow-forms, no allow-same-origin) — so it can run JS but cannot read the app's cookies, submit forms, or navigate the parent window. Optional `title` renders above the content (a short heading), and optional `caption` renders below (a longer description). The content payload is capped at 1 MiB; for larger content, split across multiple calls.
            \\
            \\For content_type="image", you may pass EITHER `content` (a data: URI like `data:image/png;base64,...` or an http(s) URL) OR `path` (an ABSOLUTE path to a local image file). When `path` is given, the server reads the file, MIME-sniffs via magic bytes (PNG/JPEG/GIF/WebP only), base64-encodes the bytes, and emits a data: URL. Use `path` when the image already exists on disk (a screenshot the agent just wrote, a generated PNG, etc.) to avoid base64 round-trips through the LLM context. The 1 MiB cap still applies, so local files must be ≤ ~750 KB raw.
            \\
            \\This tool does NOT save anything to the chat history, to a memory file, or to the workspace. It only renders in the side panel. If the user wants the content to persist (e.g. as a saved note, a saved file, or a chat-attached message), use a different tool such as `add_memory` or `write_file` instead.
            ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "content_type",
                    .type = "string",
                    .description = "One of: \"markdown\", \"text\", \"code\", \"image\", \"html\". Determines how the side panel renders the content.",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "The raw content to render. For markdown: the markdown source. For text: plain text. For code: the source code. For image: a data URI (data:image/...;base64,...) or an http(s) URL. Capped at 1 MiB. Mutually exclusive with `path` for image previews.",
                },
                .{
                    .name = "path",
                    .type = "string",
                    .description = "ABSOLUTE path to a local image file (only valid when content_type=\"image\"). The server reads + MIME-sniffs + base64-encodes the file and renders it. PNG, JPEG, GIF, and WebP are detected via magic bytes; other formats are rejected. Files >~750 KB raw (so the resulting data URL exceeds the 1 MiB cap) are rejected. Mutually exclusive with `content`.",
                },
                .{
                    .name = "title",
                    .type = "string",
                    .description = "Optional short heading rendered above the content.",
                },
                .{
                    .name = "language",
                    .type = "string",
                    .description = "Required when content_type == \"code\" — the programming language for syntax highlighting (e.g. \"zig\", \"python\", \"typescript\"). Ignored for other content_types.",
                },
                .{
                    .name = "caption",
                    .type = "string",
                    .description = "Optional caption rendered below the content (a longer description or note).",
                },
            },
            .required = &.{ "content_type", "content" },
        },
    },
};

// ─── XML helpers ─────────────────────────────────────────────────────────
//
// Local helpers — kept private to this file (the project convention
// is to duplicate `xmlEscape` in every tool file rather than share
// via a public module — see `kanban_list.zig:115`, `list_memory.zig`,
// `list_skills.zig`). The body is byte-for-byte the same as those
// (escape `< > & " '` to their XML entities).

/// Escape XML special characters. Mirrors the helper in
/// `kanban_list.zig` / `list_memory.zig` / `list_skills.zig`.
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

/// Build the success envelope: `<show_preview>...fields...</show_preview>`.
/// All string fields are XML-escaped. Numeric fields (`content_length`)
/// are formatted via `bufPrint` and inserted raw (no escaping needed).
pub fn successEnvelope(
    allocator: std.mem.Allocator,
    preview_id: []const u8,
    content_type: []const u8,
    content_length: usize,
) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<show_preview>");

    try xml.appendSlice(allocator, "<status>shown</status>");

    const eid = try xmlEscape(allocator, preview_id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, "<preview_id>");
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "</preview_id>");

    const ect = try xmlEscape(allocator, content_type);
    defer allocator.free(ect);
    try xml.appendSlice(allocator, "<content_type>");
    try xml.appendSlice(allocator, ect);
    try xml.appendSlice(allocator, "</content_type>");

    var len_buf: [32]u8 = undefined;
    // 32 bytes is provably enough for a usize (max 20 decimal digits).
    // Treat NoSpaceLeft as unreachable rather than falling back to "0"
    // (which would silently lie about the rendered size to the LLM).
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{content_length}) catch unreachable;
    try xml.appendSlice(allocator, "<content_length>");
    try xml.appendSlice(allocator, len_str);
    try xml.appendSlice(allocator, "</content_length>");

    try xml.appendSlice(allocator, "</show_preview>");
    return try xml.toOwnedSlice(allocator);
}

/// Build the error envelope: `<show_preview><error>...</error></show_preview>`.
/// `error_msg` is XML-escaped before insertion.
fn errorEnvelope(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<show_preview><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></show_preview>");
    return try xml.toOwnedSlice(allocator);
}

// ─── Validation helpers ──────────────────────────────────────────────────

/// Check that `content_type` is one of the four supported values.
/// Returns `null` on success, or an owned error message string on
/// failure (the caller wraps it in the XML error envelope via
/// `errorEnvelope`).
///
/// Kept as a separate function (not inlined into `execute*`) so the
/// tests can exercise it in isolation and so the validator is
/// reusable if a future HTTP handler mirrors this tool.
pub fn validateContentType(
    allocator: std.mem.Allocator,
    content_type: []const u8,
) !?[]u8 {
    if (std.mem.eql(u8, content_type, "markdown")) return null;
    if (std.mem.eql(u8, content_type, "text")) return null;
    if (std.mem.eql(u8, content_type, "code")) return null;
    if (std.mem.eql(u8, content_type, "image")) return null;
    if (std.mem.eql(u8, content_type, "html")) return null;
    return try std.fmt.allocPrint(
        allocator,
        \\invalid content_type '{s}'. Must be one of: "markdown", "text", "code", "image", "html".
    , .{content_type});
}

/// Check that `content.len` does not exceed `MAX_CONTENT_BYTES`.
/// Returns `null` on success, or an owned error message string on
/// failure with the actual size + limit so the LLM can decide
/// whether to split or trim.
pub fn validateContentSize(
    allocator: std.mem.Allocator,
    content: []const u8,
) !?[]u8 {
    if (content.len <= MAX_CONTENT_BYTES) return null;
    return try std.fmt.allocPrint(
        allocator,
        "content size {d} bytes exceeds MAX_CONTENT_BYTES ({d}). Split the content across multiple show_preview calls.",
        .{ content.len, MAX_CONTENT_BYTES },
    );
}

// ─── Preview id generation ───────────────────────────────────────────────

/// Generate a unique preview id of the form
/// `pv_<unix_milliseconds>_<6 hex chars>`.
///
/// The timestamp prefix (unix_ms) gives a natural sort order in the
/// side panel (later previews render lower / newer) and lets the
/// frontend detect id collisions during rapid sequential fires.
/// The 3-byte (6 hex) suffix is filled from the kernel CSPRNG via
/// `std.c.getrandom` — same approach as the auth helpers
/// (`src/helpers/auth.zig:fillRandom`, etc.) — so two previews
/// fired in the same millisecond get distinct ids with negligible
/// collision probability.
///
/// Caller owns the returned slice.
pub fn generatePreviewId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const unix_ms = ts.toMilliseconds();

    // Fill 3 random bytes via the kernel CSPRNG. Use the Io runtime's
    // random which is cross-platform (works on Windows, Linux, macOS).
    var random_bytes: [3]u8 = undefined;
    io.random(&random_bytes);

    var hex: [6]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex[i * 2] = HEX_DIGITS[b >> 4];
        hex[i * 2 + 1] = HEX_DIGITS[b & 0xF];
    }

    return std.fmt.allocPrint(allocator, "pv_{d}_{s}", .{ unix_ms, &hex });
}

// ─── Main execution function ──────────────────────────────────────────────

/// Execute the `show_preview` tool. Returns the XML response string
/// the LLM will see inside `<tool>...<data>...</data></tool>`.
///
/// Parameters:
///   - `allocator`      — for all owned strings
///   - `io`             — for the `Clock.now` timestamp
///   - `input`          — the LLM-supplied input struct
///   - `out_preview_id` — output; the function writes the generated
///                        preview id (e.g. `pv_1782850123456_a8b3c2`)
///                        into `out_preview_id.*`. Caller owns the
///                        slice and must `allocator.free` it after
///                        using it. On error, this is still written
///                        so the caller can log the failed id.
///
/// On success the returned XML is `<show_preview>...</show_preview>`
/// with `<status>shown</status>`, `<preview_id>`, `<content_type>`,
/// and `<content_length>` (the BYTE length of the sanitized content
/// — the same length the frontend will see after sanitization).
///
/// On any validation failure the returned XML is
/// `<show_preview><error>...</error></show_preview>` with a
/// self-correcting hint.
///
/// Content validation:
///   1. `content_type` must be one of the four supported values.
///   2. `content.len` must not exceed `MAX_CONTENT_BYTES`.
///   3. `content_type == "code"` requires `language` to be non-null
///      and non-empty (the frontend needs it for syntax highlighting).
///   4. The content is sanitized via
///      `helpers.sanitize.sanitizeUtf8` to replace invalid UTF-8
///      byte sequences with U+FFFD before the side panel renders
///      it (same defensive pattern as
///      `on_event_sent.zig:254-258` and `session_messages_get.zig`).
///
/// `title` and `caption` are accepted but not echoed in the
/// envelope — they're metadata for the side panel's rendering, not
/// for the LLM to see. The tool's contract with the LLM is
/// "your content was rendered", not "here's the rendered title".
pub fn executeShowPreviewToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: ShowPreviewInput,
    out_preview_id: *[]u8,
) ![]u8 {
    // 1. Always generate the preview id FIRST — even on validation
    //    failure — so the caller can log/track which attempted fire
    //    produced the error. This matches the auth helpers' pattern
    //    of allocating the id before validation so log lines always
    //    have a correlation id.
    const preview_id = try generatePreviewId(allocator, io);
    out_preview_id.* = preview_id;

    // 2. Validate content_type.
    if (try validateContentType(allocator, input.content_type)) |err_msg_owned| {
        defer allocator.free(err_msg_owned);
        return errorEnvelope(allocator, err_msg_owned);
    }

    // 2.5 (show-preview-local-file): cross-validate `path` against
    // `content_type` and `content`, then resolve the local file into a
    // `data:` URL that the existing content-size validator and sanitizer
    // can process uniformly. `resolved_content` is the post-resolution
    // value the rest of the function uses (== input.content when path
    // is null, == resolved data URL when path is given).
    const has_content = input.content.len > 0;
    const has_path = input.path != null;

    if (has_path and !std.mem.eql(u8, input.content_type, "image")) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "`path` is only valid when content_type=\"image\"; got content_type=\"{s}\". For non-image previews, use `content`.",
            .{input.content_type},
        );
        defer allocator.free(msg);
        return errorEnvelope(allocator, msg);
    }

    if (has_path and has_content) {
        const msg = "provide EITHER `content` OR `path` for an image preview, not both. `content` is a hand-written data: URI or http(s) URL; `path` is a local image file the server reads.";
        return errorEnvelope(allocator, msg);
    }

    var resolved_content: []u8 = undefined;
    var resolved_content_owned: bool = false;
    defer if (resolved_content_owned) allocator.free(resolved_content);

    if (has_path) {
        const p = input.path.?;
        resolved_content = resolveImageContentFromPath(allocator, io, p) catch |err| {
            const msg = switch (err) {
                error.FileNotFound => try std.fmt.allocPrint(
                    allocator,
                    "could not read image file at path \"{s}\": file not found (or is a directory). Verify the path is correct and the file exists.",
                    .{p},
                ),
                error.UnsupportedImageFormat => try std.fmt.allocPrint(
                    allocator,
                    "image at path \"{s}\" has an unsupported format. Only PNG, JPEG, GIF, and WebP are detected (via magic bytes); other formats are rejected. Convert the file or use `content` with a hand-written data: URL.",
                    .{p},
                ),
                error.ImageTooLarge => try std.fmt.allocPrint(
                    allocator,
                    "image at path \"{s}\" is too large after base64 encoding (exceeds {d} bytes). Resize or compress the image, or split into multiple smaller previews.",
                    .{ p, MAX_CONTENT_BYTES },
                ),
                else => try std.fmt.allocPrint(
                    allocator,
                    "could not read image file at path \"{s}\": {s}",
                    .{ p, @errorName(err) },
                ),
            };
            defer allocator.free(msg);
            return errorEnvelope(allocator, msg);
        };
        resolved_content_owned = true;
    } else {
        resolved_content = @constCast(input.content);
        resolved_content_owned = false;
    }

    // 3. Validate content size (on the resolved content, not the raw
    //    `input.content` — the data URL produced from `path` may have
    //    grown past the cap and must be checked too).
    if (try validateContentSize(allocator, resolved_content)) |err_msg_owned| {
        defer allocator.free(err_msg_owned);
        return errorEnvelope(allocator, err_msg_owned);
    }

    // 4. For code previews, the language field is required so the
    //    side panel can apply the right syntax highlighter. Both null
    //    and empty-string are rejected (the latter is what an LLM that
    //    emits `"language": ""` would produce).
    if (std.mem.eql(u8, input.content_type, "code")) {
        const lang = input.language orelse "";
        if (lang.len == 0) {
            return errorEnvelope(
                allocator,
                \\content_type "code" requires a non-empty `language` field (e.g. "zig", "python", "typescript"). The side panel needs it for syntax highlighting.
            ,
            );
        }
    }

    // 5. Sanitize the content. Invalid UTF-8 would either break the
    //    side panel renderer or be silently dropped by JSON
    //    serialization (the content is delivered to the frontend
    //    via an SSE event, and Zig 0.16's std.json.fmt emits
    //    invalid-UTF-8 strings as ARRAYS of bytes — see project
    //    memory `zig-0.16-std-json-fmt-emits-invalid-utf8-as-array`).
    //    The replacement character (U+FFFD) is always valid UTF-8,
    //    so the sanitized output can be safely emitted.
    //
    // NOTE (show-preview-local-file): we sanitize the RESOLVED content
    // (which may be a `data:image/...;base64,...` URL produced from the
    // `path` parameter). Base64 payload bytes are always ASCII so
    // sanitization is a no-op for them — but it does no harm and keeps
    // the code path uniform for content-vs-path branches.
    const sanitized_content = helpers.sanitize.sanitizeUtf8(allocator, resolved_content) catch |err| {
        // If sanitization itself fails (OOM), surface as a tool
        // error rather than a panic — the LLM can retry with a
        // smaller content payload.
        const msg = try std.fmt.allocPrint(
            allocator,
            "internal: UTF-8 sanitization failed: {s}",
            .{@errorName(err)},
        );
        defer allocator.free(msg);
        return errorEnvelope(allocator, msg);
    };
    defer allocator.free(sanitized_content);

    return try successEnvelope(
        allocator,
        preview_id,
        input.content_type,
        sanitized_content.len,
    );
}

// ─── Local image file resolution ─────────────────────────────────────────
//
// When the LLM passes `path` instead of `content` for an image preview,
// the server reads the file, MIME-sniffs via magic bytes, base64-encodes
// the bytes, and returns a `data:<mime>;base64,<payload>` URL — the same
// shape a hand-written `content` would produce. The frontend's existing
// `imageSrc` computed in `PreviewContentRenderer.vue` already renders
// `data:` URLs, so no frontend changes are needed for this feature.
//
// Security: this is the SAME threat model as `read_file` — the LLM can
// pass any path the `nalar` process can read. No sandboxing is added
// (out of scope per the plan; would require a separate allow-list work).

/// Detect an image's MIME type from its first 12 bytes (magic bytes).
/// Returns null if no supported format is detected. Only the 4
/// browser-native formats are supported: PNG, JPEG, GIF, WebP.
///
/// Detection table (RFC-style):
///
/// | Bytes (hex)                       | MIME                  |
/// |-----------------------------------|----------------------|
/// | 89 50 4E 47 0D 0A 1A 0A           | image/png             |
/// | FF D8 FF                          | image/jpeg            |
/// | 47 49 46 38 37 61 / 47 49 46 38 39 61 | image/gif (87a/89a) |
/// | 52 49 46 46 ?? ?? ?? ?? 57 45 42 50 | image/webp (RIFF/WEBP) |
fn detectImageMime(bytes: []const u8) ?[]const u8 {
    // PNG: 89 50 4E 47 0D 0A 1A 0A (8 bytes)
    if (bytes.len >= 8 and
        bytes[0] == 0x89 and bytes[1] == 0x50 and
        bytes[2] == 0x4E and bytes[3] == 0x47 and
        bytes[4] == 0x0D and bytes[5] == 0x0A and
        bytes[6] == 0x1A and bytes[7] == 0x0A)
    {
        return "image/png";
    }

    // JPEG: FF D8 FF (3 bytes)
    if (bytes.len >= 3 and
        bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF)
    {
        return "image/jpeg";
    }

    // GIF: GIF87a or GIF89a (6 bytes)
    if (bytes.len >= 6 and
        bytes[0] == 0x47 and bytes[1] == 0x49 and bytes[2] == 0x46 and
        bytes[3] == 0x38 and
        (bytes[4] == 0x37 or bytes[4] == 0x39) and
        bytes[5] == 0x61)
    {
        return "image/gif";
    }

    // WebP: RIFF....WEBP (12 bytes)
    if (bytes.len >= 12 and
        bytes[0] == 0x52 and bytes[1] == 0x49 and
        bytes[2] == 0x46 and bytes[3] == 0x46 and
        bytes[8] == 0x57 and bytes[9] == 0x45 and
        bytes[10] == 0x42 and bytes[11] == 0x50)
    {
        return "image/webp";
    }

    return null;
}

/// Read a local image file and return a `data:<mime>;base64,<payload>`
/// URL string the frontend can render directly.
///
/// Errors:
///   - `error.FileNotFound` — path does not exist (covers FileSystem + IsDir)
///   - `error.UnsupportedImageFormat` — magic bytes don't match a supported
///     format (no extension trust; we sniff the actual bytes)
///   - `error.ImageTooLarge` — resulting data URL exceeds `MAX_CONTENT_BYTES`
///   - `error.OutOfMemory` — alloc failure (propagated)
///
/// Caller owns the returned slice (must free with `allocator.free`).
pub fn resolveImageContentFromPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    // Read the file. Same pattern as `read_file.zig::readFile`:
    // std.Io.Dir.cwd().readFileAlloc returns the raw bytes (any size).
    // If the file doesn't exist or is a directory, returns
    // `error.FileNotFound` (we surface this verbatim to the LLM).
    const raw = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        std.Io.Limit.limited(std.math.maxInt(usize)),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.IsDir => return error.FileNotFound,
        error.AccessDenied => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(raw);

    // Detect MIME via magic bytes BEFORE allocating any output buffers.
    // If we can't sniff the format, fail fast — we'd rather reject a
    // wrong file than render garbage in the side panel.
    const mime = detectImageMime(raw) orelse return error.UnsupportedImageFormat;

    // Base64-encode the raw bytes. Zig 0.16 API:
    //   std.base64.standard.Encoder.calcSize(len) → encoded byte count
    //   std.base64.standard.Encoder.encode(dest, source) → fills dest
    const encoder = &std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(raw.len);
    const total_len = "data:".len + mime.len + ";base64,".len + b64_len;

    // Enforce the SAME size cap as `content` previews: the resulting data
    // URL must fit in MAX_CONTENT_BYTES. Raw files >~750 KB are rejected
    // so the SSE payload stays under the 1 MiB limit. We check the
    // computed length (not the post-build string) to avoid building a
    // buffer we then throw away.
    if (total_len > MAX_CONTENT_BYTES) return error.ImageTooLarge;

    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);

    var pos: usize = 0;
    @memcpy(out[pos..][0.."data:".len], "data:");
    pos += "data:".len;
    @memcpy(out[pos..][0..mime.len], mime);
    pos += mime.len;
    @memcpy(out[pos..][0..";base64,".len], ";base64,");
    pos += ";base64,".len;
    _ = encoder.encode(out[pos..][0..b64_len], raw);

    return out;
}