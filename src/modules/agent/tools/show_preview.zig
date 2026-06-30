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
const helpers = nalarcore.helpers;

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
///   - `content_type` — one of "markdown", "text", "code", "image"
///   - `content`      — the raw payload (markdown source, plain text,
///                      code source, or for "image" a data URI / URL)
///   - `title`        — optional caption shown above the content
///   - `language`     — required when content_type == "code"
///                      (e.g. "zig", "python"); ignored otherwise
///   - `caption`      — optional caption shown BELOW the content
pub const ShowPreviewInput = struct {
    content_type: []const u8,
    content: []const u8,
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
            \\The content_type must be one of "markdown", "text", "code", or "image". For "code", you MUST also pass the language field (e.g. "zig", "python", "javascript") so the side panel can apply syntax highlighting. Optional `title` renders above the content (a short heading), and optional `caption` renders below (a longer description). The content payload is capped at 1 MiB; for larger content, split across multiple calls.
            \\
            \\This tool does NOT save anything to the chat history, to a memory file, or to the workspace. It only renders in the side panel. If the user wants the content to persist (e.g. as a saved note, a saved file, or a chat-attached message), use a different tool such as `add_memory` or `write_file` instead.
            ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "content_type",
                    .type = "string",
                    .description = "One of: \"markdown\", \"text\", \"code\", \"image\". Determines how the side panel renders the content.",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "The raw content to render. For markdown: the markdown source. For text: plain text. For code: the source code. For image: a data URI (data:image/...;base64,...) or an http(s) URL. Capped at 1 MiB.",
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
fn successEnvelope(
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
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{content_length}) catch "0";
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
    return try std.fmt.allocPrint(
        allocator,
        \\invalid content_type '{s}'. Must be one of: "markdown", "text", "code", "image".
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

    // Fill 3 random bytes via the kernel CSPRNG. Loop on EINTR to
    // match the project's libc-getrandom pattern (see
    // project memory `zig-0.16-crypto-time-stdlib-removals.md`).
    var random_bytes: [3]u8 = .{ 0, 0, 0 };
    while (true) {
        const rc = std.c.getrandom(&random_bytes, random_bytes.len, 0);
        if (rc >= 0) break;
        const errno_val = std.c.errno(rc);
        if (errno_val == .INTR) continue;
        return error.RandomSourceFailed;
    }

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

    // 3. Validate content size.
    if (try validateContentSize(allocator, input.content)) |err_msg_owned| {
        defer allocator.free(err_msg_owned);
        return errorEnvelope(allocator, err_msg_owned);
    }

    // 4. For code previews, the language field is required so the
    //    side panel can apply the right syntax highlighter.
    if (std.mem.eql(u8, input.content_type, "code")) {
        const lang = input.language orelse {
            return errorEnvelope(
                allocator,
                \\content_type "code" requires a non-empty `language` field (e.g. "zig", "python", "typescript"). The side panel needs it for syntax highlighting.
            ,
            );
        };
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
    const sanitized_content = helpers.sanitize.sanitizeUtf8(allocator, input.content) catch |err| {
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