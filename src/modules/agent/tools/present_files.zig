//! `present_files` — an agent tool that presents workspace files of ANY
//! type (text, jpg/png, pdf, zip, code, html, etc.) as rich inline-preview
//! cards in the chat transcript.
//!
//! The LLM calls this tool with a list of ABSOLUTE file paths. The
//! server stats each file (existence, size, mime) and returns a JSON
//! object listing them. The frontend's `<PresentFiles>` card renders
//! one section per file with an inline preview plus a download action:
//! images (`image/*`) render full-width, html renders in a sandboxed
//! iframe, text/markdown/code render fetched source inline, pdf renders
//! in an embedded frame, video/audio render native players, and anything
//! else falls back to a generic row. Every row links to
//! `GET /api/files/download?disposition=attachment` so clicking
//! downloads the bytes with the original filename (cookie-based auth,
//! so plain `<a href>` + `<img src>` carry credentials). Inline bytes
//! come from `GET /api/files/download?disposition=inline`.
//!
//! Response shape (per project convention, like `generate_image.zig`):
//!   {"status":"presented","count":2,"files":[
//!     {"path":"/abs/a.txt","bytes":12,"mime":"text/plain; charset=utf-8","label":"notes"},
//!     {"path":"/abs/b.jpg","bytes":48211,"mime":"image/jpeg","label":"b.jpg"}
//!   ],"error":null}
//!
//! On error (any file fails validation):
//!   {"status":null,"count":0,"files":[],"error":"..."}
//!
//! Design: docs/plans/2026-09-14-agent-tool-present-files.md
//! This tool never reads file bytes — only `stat` — so the SSE payload
//! stays tiny and previews render via URL instead of data URI. To show
//! LLM-generated content inline, first persist it with `write_file`,
//! then present the saved file.

const std = @import("std");
const schemas = @import("schemas.zig");
const path_validate = @import("helpers").path_validate;
const invalidPathReason = path_validate.invalidPathReason;
const AgentTool = schemas.AgentTool;

/// Maximum number of files per call. Keeps the card scannable and the
/// envelope small; the LLM can split larger sets across calls.
pub const MAX_FILES: usize = 10;

/// Maximum per-file size (50 MiB). Matches the download handler's cap
/// (`files_download.zig`) so a presented file is always downloadable.
/// Larger files are rejected with a clear error so the LLM can explain
/// instead of emitting a dead link.
pub const MAX_FILE_BYTES: usize = 50 * 1024 * 1024;

/// One file reference from the LLM.
pub const PresentFileRef = struct {
    /// ABSOLUTE path to a workspace file.
    path: []const u8,
    /// Optional short display name shown in the card. Falls back to the
    /// basename when absent or empty.
    label: ?[]const u8 = null,
    /// Optional longer note shown below the row.
    caption: ?[]const u8 = null,
};

/// Input structure for the `present_files` tool.
pub const PresentFilesInput = struct {
    files: []PresentFileRef,
};

/// Top-level tool definition exposed to the LLM.
pub const present_files_tool_system_prompt =
    \\## Present Files Tool — Behavior
    \\Use `present_files` to present workspace files (any type: text, images, pdf, zip, code, html, video, audio) as inline-preview cards in the chat.
    \\- Provide `files` with ABSOLUTE `path` entries (1-10). Each file must exist and be ≤ 50 MiB.
    \\- The card renders each file inline: images full-width, html in a sandboxed iframe, text/markdown/code as fetched source, pdf embedded, video/audio with native players; anything else shows a file row with a download button.
    \\- To show generated content inline, first save it with `write_file`, then present the saved file.
    \\- Optional `label` overrides the displayed name; optional `caption` adds a note below the row.
    \\
;

pub const present_files_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "present_files",
        .description =
        \\Present one or more workspace files as inline-preview cards in the chat transcript. Use this tool when the user asks to "share", "attach", "present", "send", "show", "preview", "render", or "download" a file — or when you just created/edited a file (report, image, export, notes, html page) and want the user to see it inline with one click to download.
        \\
        \\INPUT: files (required, array of 1-10 objects). Each object: path (required, ABSOLUTE path to an existing file, e.g. "/home/user/report.md"), label (optional, short display name — defaults to the filename), caption (optional, note shown below the row).
        \\
        \\BEHAVIOUR: The server stats each file (existence, size, mime) and returns metadata only — file bytes are served on demand via GET /api/files/download (disposition=inline for previews, attachment for downloads). The card renders each file inline: images (jpg/png/gif/webp/svg) full-width with click-to-fullscreen, html in a sandboxed iframe with an "open in new tab" action, text/markdown/code (md/txt/json/csv/log/zig/ts/py/js/css) as fetched source with syntax-aware rendering, pdf embedded, video/audio with native players; every other type (zip, etc.) renders a file row with a download button. Files must be ≤ 50 MiB each; missing files, directories, relative paths, and oversized files are rejected with a structured error.
        \\
        \\OUTPUT (JSON success envelope): {"status":"presented","count":N,"files":[{"path":...,"bytes":...,"mime":...,"label":...}],"error":null}. On error: {"status":null,"count":0,"files":[],"error":"..."}.
        \\
        \\This tool does NOT write anything to disk — it only presents existing files. To show generated content inline, first save it with `write_file`, then present the saved file.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "files",
                    .type = "array",
                    .description = "1-10 file objects to present. Each: {path (absolute), label? (display name), caption? (note)}.",
                },
            },
            .required = &.{"files"},
        },
        .system_prompt = present_files_tool_system_prompt,
    },
};

// ─── JSON helpers ──────────────────────────────────────────────────────
//
// JSON payloads mirror the old `<present_files>` envelope 1:1: `status`,
// `count`, and `files` (one object per former `<file>` tag with `path`,
// `bytes`, `mime`, `label`). The old `<error>`-only envelope becomes the
// same object with an explicit `error` string and null `status`.
// Free-text fields are sanitized for control characters; `std.json`
// handles the remaining escaping.

pub const PresentFileJSON = struct {
    path: []const u8,
    bytes: u64,
    mime: []const u8,
    label: []const u8,
};

pub const PresentFilesJSON = struct {
    status: ?[]const u8 = null,
    count: usize = 0,
    files: []PresentFileJSON = &.{},
    @"error": ?[]const u8 = null,
};

const sanitize_control_chars = @import("helpers").sanitize_control_chars;

/// Build the error envelope: `{"error": ...}` with explicit nulls for
/// the success fields.
fn jsonErrorEnvelope(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitize_control_chars(allocator, msg);
    defer allocator.free(clean);
    return try std.json.Stringify.valueAlloc(allocator, PresentFilesJSON{
        .@"error" = clean,
    }, .{});
}

// ─── MIME detection ──────────────────────────────────────────────────────
//
// Extension-based, mirroring `static_files.zig:mimeForPath` (kept local
// per the tool self-containment convention). Unknown extensions fall
// back to `application/octet-stream` so the browser downloads instead
// of rendering.

const MimeEntry = struct {
    ext: []const u8,
    mime: []const u8,
};

const mime_table = [_]MimeEntry{
    .{ .ext = ".html", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".htm", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".css", .mime = "text/css; charset=utf-8" },
    .{ .ext = ".js", .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".mjs", .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".json", .mime = "application/json; charset=utf-8" },
    .{ .ext = ".md", .mime = "text/markdown; charset=utf-8" },
    .{ .ext = ".txt", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".csv", .mime = "text/csv; charset=utf-8" },
    .{ .ext = ".log", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".zig", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".ts", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".py", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".svg", .mime = "image/svg+xml" },
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".gif", .mime = "image/gif" },
    .{ .ext = ".webp", .mime = "image/webp" },
    .{ .ext = ".ico", .mime = "image/x-icon" },
    .{ .ext = ".pdf", .mime = "application/pdf" },
    .{ .ext = ".zip", .mime = "application/zip" },
    .{ .ext = ".mp3", .mime = "audio/mpeg" },
    .{ .ext = ".mp4", .mime = "video/mp4" },
};

/// Returns the mime string for `path`'s extension (case-insensitive
/// ASCII, last `.` after the final `/`). Unknown or missing extensions
/// yield `application/octet-stream`.
pub fn mimeForPath(path: []const u8) []const u8 {
    var dot_idx: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/') {
            dot_idx = null;
        } else if (c == '.') {
            dot_idx = i;
        }
    }
    const ext_start = dot_idx orelse return "application/octet-stream";
    const ext = path[ext_start..];
    for (mime_table) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.mime;
    }
    return "application/octet-stream";
}

// ─── Core execution ──────────────────────────────────────────────────────

/// Stat one file: open (rejecting directories) + size. Returns the size
/// on success. Errors:
///   - `error.FileNotFound` — missing, unreadable, or a directory.
///   - `error.FileTooLarge` — size exceeds `MAX_FILE_BYTES`.
fn statFileSize(io: std.Io, path: []const u8) !u64 {
    // Any open failure (missing, dir, permissions, device errors)
    // surfaces as FileNotFound — the caller reports "not found (or is
    // a directory)", which is the actionable signal for the LLM.
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch return error.FileNotFound;
    defer std.Io.File.close(file, io);
    const stat = std.Io.File.stat(file, io) catch return error.FileNotFound;
    if (stat.size > MAX_FILE_BYTES) return error.FileTooLarge;
    return stat.size;
}

/// Execute the tool: validate every file, then build the success
/// object. Any validation failure yields an `{"error": ...}` object
/// naming the offending path (never a Zig error return — the LLM sees a
/// structured failure it can act on).
pub fn executePresentFilesToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: PresentFilesInput,
) ![]u8 {
    if (input.files.len == 0) {
        return jsonErrorEnvelope(allocator, "present_files requires at least 1 file in `files`.");
    }
    // Every path here is model-supplied. On Windows a malformed NT name
    // panics the process inside std's Io backend instead of failing the
    // call, so validate before touching any of them.
    for (input.files) |f| {
        if (invalidPathReason(f.path)) |reason| {
            const msg = try std.fmt.allocPrint(
                allocator,
                "present_files: path \"{s}\" is not a valid path on this platform: {s}",
                .{ f.path, reason },
            );
            defer allocator.free(msg);
            return jsonErrorEnvelope(allocator, msg);
        }
    }
    if (input.files.len > MAX_FILES) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "present_files accepts at most {d} files per call (got {d}). Split across multiple calls.",
            .{ MAX_FILES, input.files.len },
        );
        defer allocator.free(msg);
        return jsonErrorEnvelope(allocator, msg);
    }

    var files = std.ArrayList(PresentFileJSON).empty;
    defer files.deinit(allocator);
    // Sanitized labels are owned here and freed after serialization
    // (`Stringify` copies every byte into the returned payload).
    var owned_labels = std.ArrayList([]u8).empty;
    defer {
        for (owned_labels.items) |l| allocator.free(l);
        owned_labels.deinit(allocator);
    }

    for (input.files) |f| {
        // Empty path is what an LLM that emits `"path": ""` produces
        // (the frontend's atomic-mode-switch trap in PR #291) — reject
        // with a clear message, never pass "" to isAbsolute/stat.
        if (f.path.len == 0) {
            return jsonErrorEnvelope(allocator, "present_files: one entry has an empty `path`. Each file needs a non-empty ABSOLUTE path.");
        }
        if (!std.fs.path.isAbsolute(f.path)) {
            const msg = try std.fmt.allocPrint(allocator, "present_files: path \"{s}\" is not absolute. Pass an ABSOLUTE path.", .{f.path});
            defer allocator.free(msg);
            return jsonErrorEnvelope(allocator, msg);
        }
        const size = statFileSize(io, f.path) catch |err| switch (err) {
            error.FileNotFound => {
                const msg = try std.fmt.allocPrint(allocator, "present_files: file not found (or is a directory): \"{s}\".", .{f.path});
                defer allocator.free(msg);
                return jsonErrorEnvelope(allocator, msg);
            },
            error.FileTooLarge => {
                const msg = try std.fmt.allocPrint(allocator, "present_files: file \"{s}\" exceeds the {d} MiB limit.", .{ f.path, MAX_FILE_BYTES / (1024 * 1024) });
                defer allocator.free(msg);
                return jsonErrorEnvelope(allocator, msg);
            },
        };

        const mime = mimeForPath(f.path);
        const raw_label = f.label orelse "";
        const base_label: []const u8 = if (raw_label.len > 0) raw_label else std.fs.path.basename(f.path);
        const clean_label = try sanitize_control_chars(allocator, base_label);
        try owned_labels.append(allocator, clean_label);

        try files.append(allocator, .{
            .path = f.path,
            .bytes = size,
            .mime = mime,
            .label = clean_label,
        });
    }

    return try std.json.Stringify.valueAlloc(allocator, PresentFilesJSON{
        .status = "presented",
        .count = files.items.len,
        .files = files.items,
    }, .{});
}

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;
const present_files = @import("present_files.zig");

const TOOL_PATH = "src/modules/agent/tools/present_files.zig";

// ─── Helpers ─────────────────────────────────────────────────────────────

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Open a fresh `std.Io.Threaded` runtime. Mirrors the setup helper
/// in `kanban_list.zig` (same pattern).
fn setupIo() std.Io.Threaded {
    const threaded = std.Io.Threaded.init(testing.allocator, .{});
    return threaded;
}

// ─── Static source-check tests ───────────────────────────────────────────

test "present_files tool definition has name \"present_files\"" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"present_files\"")) {
        std.debug.print("!! present_files.zig does not define the tool with .name = \"present_files\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "present_files schema has files property and required array" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"files\"")) {
        std.debug.print("!! present_files.zig schema is missing property: files !!\n", .{});
        return error.SchemaPropertyMissing;
    }
    if (!contains(source, "required = &.{\"files\"}")) {
        std.debug.print("!! present_files.zig schema required array is wrong (want the files singleton) !!\n", .{});
        return error.RequiredArrayWrong;
    }
}

test "present_files defines pub fn executePresentFilesToString" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn executePresentFilesToString(")) {
        std.debug.print("!! present_files.zig does not define pub fn executePresentFilesToString !!\n", .{});
        return error.ExecuteFnMissing;
    }
}

test "present_files defines MAX_FILES and MAX_FILE_BYTES caps" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "MAX_FILES")) {
        std.debug.print("!! present_files.zig does not define MAX_FILES constant !!\n", .{});
        return error.MaxFilesConstMissing;
    }
    if (!contains(source, "MAX_FILE_BYTES")) {
        std.debug.print("!! present_files.zig does not define MAX_FILE_BYTES constant !!\n", .{});
        return error.MaxFileBytesConstMissing;
    }
    if (!contains(source, "50 * 1024 * 1024")) {
        std.debug.print("!! present_files.zig does not include the 50 MiB cap (50 * 1024 * 1024) !!\n", .{});
        return error.FiftyMiBCapMissing;
    }
}

// ─── Behavioral tests ────────────────────────────────────────────────────

test "executePresentFilesToString rejects empty files list" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const input = PresentFilesInput{ .files = @constCast(&[_]PresentFileRef{}) };
    const payload = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("status").? == .null);
    try testing.expect(obj.get("error").? == .string);
}

test "executePresentFilesToString rejects relative path" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs = [_]PresentFileRef{.{ .path = "relative/path.txt" }};
    const input = PresentFilesInput{ .files = &refs };
    const payload = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("status").? == .null);
    try testing.expect(std.mem.indexOf(u8, obj.get("error").?.string, "not absolute") != null);
}

test "executePresentFilesToString rejects empty path" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs = [_]PresentFileRef{.{ .path = "" }};
    const input = PresentFilesInput{ .files = &refs };
    const payload = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error").? == .string);
}

test "executePresentFilesToString rejects missing file" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs = [_]PresentFileRef{.{ .path = "/tmp/nalar-present-files-does-not-exist-xyz.txt" }};
    const input = PresentFilesInput{ .files = &refs };
    const payload = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(std.mem.indexOf(u8, obj.get("error").?.string, "not found") != null);
}

test "executePresentFilesToString rejects too many files" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs: [11]PresentFileRef = undefined;
    for (&refs) |*r| r.* = .{ .path = "/tmp/x.txt" };
    const input = PresentFilesInput{ .files = &refs };
    const payload = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error").? == .string);
}

test "executePresentFilesToString returns success envelope for real files" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const tmp_dir = "/tmp/nalar-present-files-test";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const txt_path = "/tmp/nalar-present-files-test/notes.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "hello world");
    }
    const jpg_path = "/tmp/nalar-present-files-test/photo.jpg";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, jpg_path, .{});
        defer std.Io.File.close(f, io);
        // Minimal JPEG magic bytes (FF D8 FF) + payload.
        try std.Io.File.writeStreamingAll(f, io, &[_]u8{ 0xFF, 0xD8, 0xFF, 0x00, 0x01 });
    }

    var refs = [_]PresentFileRef{
        .{ .path = txt_path, .label = "notes" },
        .{ .path = jpg_path },
    };
    const input = PresentFilesInput{ .files = &refs };
    const payload = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("presented", obj.get("status").?.string);
    try testing.expectEqual(@as(i64, 2), obj.get("count").?.integer);
    const files = obj.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings("notes", files[0].object.get("label").?.string);
    try testing.expectEqualStrings(txt_path, files[0].object.get("path").?.string);
    try testing.expectEqualStrings("text/plain; charset=utf-8", files[0].object.get("mime").?.string);
    try testing.expectEqual(@as(i64, 11), files[0].object.get("bytes").?.integer);
    try testing.expectEqualStrings("photo.jpg", files[1].object.get("label").?.string);
    try testing.expectEqualStrings("image/jpeg", files[1].object.get("mime").?.string);
    try testing.expect(obj.get("error").? == .null);
}

test "mimeForPath maps common extensions and falls back to octet-stream" {
    try testing.expectEqualStrings("image/jpeg", present_files.mimeForPath("/a/photo.JPG"));
    try testing.expectEqualStrings("image/png", present_files.mimeForPath("/a/img.png"));
    try testing.expectEqualStrings("text/plain; charset=utf-8", present_files.mimeForPath("/a/notes.txt"));
    try testing.expectEqualStrings("application/pdf", present_files.mimeForPath("/a/doc.pdf"));
    try testing.expectEqualStrings("application/octet-stream", present_files.mimeForPath("/a/noext"));
    try testing.expectEqualStrings("application/octet-stream", present_files.mimeForPath("/a/file.unknownext"));
}
