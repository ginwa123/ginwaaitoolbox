//! `present_files` — an agent tool that presents workspace files of ANY
//! type (text, jpg/png, pdf, zip, code, etc.) as downloadable cards in
//! the chat transcript.
//!
//! The LLM calls this tool with a list of ABSOLUTE file paths. The
//! server stats each file (existence, size, mime) and returns an XML
//! envelope listing them. The frontend's `<PresentFiles>` card renders
//! one row per file: images (`image/*`) show a thumbnail preview
//! (served from `GET /api/files/download?disposition=inline`) before
//! download, everything else shows a generic row. Every row links to
//! `GET /api/files/download?disposition=attachment` so clicking
//! downloads the bytes with the original filename (cookie-based auth,
//! so plain `<a href>` + `<img src>` carry credentials).
//!
//! Response shape (per project convention, like `generate_image.zig`):
//!   <present_files>
//!     <status>presented</status>
//!     <count>2</count>
//!     <files>
//!       <file path="/abs/a.txt" bytes="12" mime="text/plain; charset=utf-8" label="notes"/>
//!       <file path="/abs/b.jpg" bytes="48211" mime="image/jpeg" label=""/>
//!     </files>
//!   </present_files>
//!
//! On error (any file fails validation):
//!   <present_files><error>...</error></present_files>
//!
//! Design: docs/plans/2026-09-14-agent-tool-present-files.md
//! Unlike `show_preview` (1 MiB inline cap, base64 data URLs), this tool
//! never reads file bytes — only `stat` — so the SSE payload stays tiny
//! and images render via URL instead of data URI.

const std = @import("std");
const schemas = @import("schemas.zig");
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
    \\Use `present_files` to present workspace files (any type: text, images, pdf, zip, code) as downloadable cards in the chat.
    \\- Provide `files` with ABSOLUTE `path` entries (1-10). Each file must exist and be ≤ 50 MiB.
    \\- Images (jpg/png/gif/webp) show a thumbnail preview before download; other types show a file row with a download button.
    \\- Optional `label` overrides the displayed name; optional `caption` adds a note below the row.
    \\
;

pub const present_files_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "present_files",
        .description =
            \\Present one or more workspace files as downloadable cards in the chat transcript. Use this tool when the user asks to "share", "attach", "present", "send", or "download" a file — or when you just created/edited a file (report, image, export, notes) and want the user to grab it with one click.
            \\
            \\INPUT: files (required, array of 1-10 objects). Each object: path (required, ABSOLUTE path to an existing file, e.g. "/home/user/report.md"), label (optional, short display name — defaults to the filename), caption (optional, note shown below the row).
            \\
            \\BEHAVIOUR: The server stats each file (existence, size, mime) and returns metadata only — file bytes are served on demand via GET /api/files/download when the user clicks. Images (jpg/png/gif/webp) render a thumbnail preview in the card before download; every other type (text, code, pdf, zip, etc.) renders a file row with a download button. Files must be ≤ 50 MiB each; missing files, directories, relative paths, and oversized files are rejected with a structured error.
            \\
            \\OUTPUT (XML success envelope): <present_files><status>presented</status><count>N</count><files><file path="..." bytes="..." mime="..." label="..."/>...</files></present_files>. On error: <present_files><error>...</error></present_files>.
            \\
            \\This tool does NOT write anything to disk and does NOT render inline content — it only lists files for download. To show rich content inline, use `show_preview` instead.
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

// ─── XML helpers ─────────────────────────────────────────────────────────
//
// Local helpers — kept private to this file (the project convention
// is to duplicate `xmlEscape` in every tool file rather than share
// via a public module — see `kanban_list.zig:115`, `list_memory.zig`,
// `show_preview.zig:149`).

/// Escape XML special characters. Mirrors the helper in
/// `show_preview.zig` / `kanban_list.zig` / `list_memory.zig`.
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

/// Escape XML special characters for an attribute value. Same escaping
/// as `xmlEscape` — attributes are double-quoted, so `"` must be
/// escaped (which `xmlEscape` already does).
fn xmlEscapeAttr(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return xmlEscape(allocator, s);
}

/// Build the error envelope: `<present_files><error>...</error></present_files>`.
fn errorEnvelope(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const emsg = try xmlEscape(allocator, msg);
    defer allocator.free(emsg);
    return try std.fmt.allocPrint(allocator, "<present_files><error>{s}</error></present_files>", .{emsg});
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
/// envelope. Any validation failure yields an `<error>` envelope naming
/// the offending path (never a Zig error return — the LLM sees a
/// structured failure it can act on).
pub fn executePresentFilesToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: PresentFilesInput,
) ![]u8 {
    if (input.files.len == 0) {
        return errorEnvelope(allocator, "present_files requires at least 1 file in `files`.");
    }
    if (input.files.len > MAX_FILES) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "present_files accepts at most {d} files per call (got {d}). Split across multiple calls.",
            .{ MAX_FILES, input.files.len },
        );
        defer allocator.free(msg);
        return errorEnvelope(allocator, msg);
    }

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<present_files><status>presented</status>");
    const count_str = try std.fmt.allocPrint(allocator, "<count>{d}</count><files>", .{input.files.len});
    defer allocator.free(count_str);
    try xml.appendSlice(allocator, count_str);

    for (input.files) |f| {
        // Empty path is what an LLM that emits `"path": ""` produces
        // (the frontend's atomic-mode-switch trap in PR #291) — reject
        // with a clear message, never pass "" to isAbsolute/stat.
        if (f.path.len == 0) {
            allocator.free(try xml.toOwnedSlice(allocator));
            return errorEnvelope(allocator, "present_files: one entry has an empty `path`. Each file needs a non-empty ABSOLUTE path.");
        }
        if (!std.fs.path.isAbsolute(f.path)) {
            const msg = try std.fmt.allocPrint(allocator, "present_files: path \"{s}\" is not absolute. Pass an ABSOLUTE path.", .{f.path});
            defer allocator.free(msg);
            allocator.free(try xml.toOwnedSlice(allocator));
            return errorEnvelope(allocator, msg);
        }
        const size = statFileSize(io, f.path) catch |err| switch (err) {
            error.FileNotFound => {
                const msg = try std.fmt.allocPrint(allocator, "present_files: file not found (or is a directory): \"{s}\".", .{f.path});
                defer allocator.free(msg);
                allocator.free(try xml.toOwnedSlice(allocator));
                return errorEnvelope(allocator, msg);
            },
            error.FileTooLarge => {
                const msg = try std.fmt.allocPrint(allocator, "present_files: file \"{s}\" exceeds the {d} MiB limit.", .{ f.path, MAX_FILE_BYTES / (1024 * 1024) });
                defer allocator.free(msg);
                allocator.free(try xml.toOwnedSlice(allocator));
                return errorEnvelope(allocator, msg);
            },
        };

        const mime = mimeForPath(f.path);
        const raw_label = f.label orelse "";
        const label: []const u8 = if (raw_label.len > 0) raw_label else std.fs.path.basename(f.path);

        const epath = try xmlEscapeAttr(allocator, f.path);
        defer allocator.free(epath);
        const elabel = try xmlEscapeAttr(allocator, label);
        defer allocator.free(elabel);
        const emime = try xmlEscapeAttr(allocator, mime);
        defer allocator.free(emime);

        const row = try std.fmt.allocPrint(
            allocator,
            "<file path=\"{s}\" bytes=\"{d}\" mime=\"{s}\" label=\"{s}\"/>",
            .{ epath, size, emime, elabel },
        );
        defer allocator.free(row);
        try xml.appendSlice(allocator, row);
    }

    try xml.appendSlice(allocator, "</files></present_files>");
    return try xml.toOwnedSlice(allocator);
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
/// in `show_preview.zig:653`.
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
    const xml = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<present_files>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
}

test "executePresentFilesToString rejects relative path" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs = [_]PresentFileRef{.{ .path = "relative/path.txt" }};
    const input = PresentFilesInput{ .files = &refs };
    const xml = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "not absolute") != null);
}

test "executePresentFilesToString rejects empty path" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs = [_]PresentFileRef{.{ .path = "" }};
    const input = PresentFilesInput{ .files = &refs };
    const xml = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
}

test "executePresentFilesToString rejects missing file" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs = [_]PresentFileRef{.{ .path = "/tmp/nalar-present-files-does-not-exist-xyz.txt" }};
    const input = PresentFilesInput{ .files = &refs };
    const xml = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "not found") != null);
}

test "executePresentFilesToString rejects too many files" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs: [11]PresentFileRef = undefined;
    for (&refs) |*r| r.* = .{ .path = "/tmp/x.txt" };
    const input = PresentFilesInput{ .files = &refs };
    const xml = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
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
    const xml = try present_files.executePresentFilesToString(alloc, io, input);
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<present_files>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<status>presented</status>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>2</count>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "label=\"notes\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "label=\"notes.txt\"") == null); // label overrides basename
    try testing.expect(std.mem.indexOf(u8, xml, "label=\"photo.jpg\"") != null); // basename fallback
    try testing.expect(std.mem.indexOf(u8, xml, "mime=\"text/plain; charset=utf-8\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "mime=\"image/jpeg\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "bytes=\"11\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);
}

test "mimeForPath maps common extensions and falls back to octet-stream" {
    try testing.expectEqualStrings("image/jpeg", present_files.mimeForPath("/a/photo.JPG"));
    try testing.expectEqualStrings("image/png", present_files.mimeForPath("/a/img.png"));
    try testing.expectEqualStrings("text/plain; charset=utf-8", present_files.mimeForPath("/a/notes.txt"));
    try testing.expectEqualStrings("application/pdf", present_files.mimeForPath("/a/doc.pdf"));
    try testing.expectEqualStrings("application/octet-stream", present_files.mimeForPath("/a/noext"));
    try testing.expectEqualStrings("application/octet-stream", present_files.mimeForPath("/a/file.unknownext"));
}
