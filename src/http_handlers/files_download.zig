//! `GET /api/files/download?session_id=<id>&path=<abs>&disposition=<inline|attachment>`
//!
//! Serves workspace file bytes for the `present_files` agent tool card
//! (`src/modules/agent/tools/present_files.zig`, rendered by
//! `PresentFiles.vue`). Cookie-based auth like every other `/api`
//! route, so plain `<a href>` (download) and `<img src>` (thumbnail
//! preview) carry credentials with no JS blob dance.
//!
//! - `disposition=attachment` (default): `Content-Disposition: attachment;
//!   filename="<basename>"` — the browser shows a save dialog.
//! - `disposition=inline`: `Content-Disposition: inline;
//!   filename="<basename>"` — the browser renders (used for `<img>`
//!   thumbnails of jpg/png/gif/webp).
//!
//! Sandbox: `path` must be absolute and must canonicalize (symlinks +
//! `..` resolved via `realPathFileAbsoluteAlloc`) to inside the
//! session's working directory (`git_worktree_cwd` when set, else
//! `cwd` from the `sessions` row). Violations are 403, missing files
//! 404, oversized files 413. Same trust story as `read_file` — the
//! LLM names the path — with cwd-containment as defense in depth so a
//! confused model can't turn the browser into an arbitrary-file
//! exfiltration primitive.
//!
//! Layered as pure helpers (`parseDisposition`, `mimeForPath`,
//! `isInsideRoot`, `resolveSessionRoot`) plus a thin handler, mirroring
//! `background_process_log_get.zig`. The helpers are unit-tested
//! in-file; the wire round-trip (route order, byte identity,
//! 403/404/413) is covered by the functional harness
//! (`tests/functional/agent_present_files_test.py`).

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
// The one containment rule, shared with the `present_files` agent tool. The
// two disagreed once — the tool accepted any absolute path while this
// handler 403'd anything outside the session working directory — and the
// result was a rendered card whose every preview / download failed.
// See docs/plans/2026-09-29-present-files-sandbox-parity.md.
const file_sandbox = @import("../modules/agent/tools/file_sandbox.zig");

/// Cap mirrors `present_files.zig:MAX_FILE_BYTES` so every presented
/// file is downloadable. Must stay in sync (see the sync test below).
pub const MAX_DOWNLOAD_BYTES: usize = 50 * 1024 * 1024;

pub const Disposition = enum {
    inline_preview,
    attachment,
};

/// Parse the `?disposition=` query value. Absent → attachment (the
/// safe default: browsers download rather than render). Present but
/// unknown → error (fail loud so a frontend typo surfaces as 400, not
/// a silently wrong rendering mode).
pub fn parseDisposition(raw: ?[]const u8) !Disposition {
    const s = raw orelse return .attachment;
    if (std.mem.eql(u8, s, "attachment")) return .attachment;
    if (std.mem.eql(u8, s, "inline")) return .inline_preview;
    return error.InvalidDisposition;
}

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

/// Extension-based mime (case-insensitive ASCII, last `.` after the
/// final `/`). Unknown → `application/octet-stream` so the browser
/// downloads instead of sniffing. Mirrors `static_files.zig` +
/// `present_files.zig:mimeForPath` (duplicated per project convention).
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

// =====================================================================
// Handler
// =====================================================================

pub fn filesDownloadHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;
    _ = res;

    const session_id = req.query.get("session_id") orelse {
        return gserverz.HttpResponse.init(400, "Bad Request", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id query parameter" }),
        );
    };
    const path_param = req.query.get("path") orelse {
        return gserverz.HttpResponse.init(400, "Bad Request", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing path query parameter" }),
        );
    };

    const disposition = parseDisposition(req.query.get("disposition")) catch {
        return gserverz.HttpResponse.init(400, "Bad Request", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid disposition (want \"inline\" or \"attachment\")" }),
        );
    };

    // Empty path is the PR #291 trap (`""` binds as NULL / fails
    // `isAbsolute`) — reject before touching the filesystem.
    if (path_param.len == 0) {
        return gserverz.HttpResponse.init(400, "Bad Request", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Empty path" }),
        );
    }
    if (!std.fs.path.isAbsolute(path_param)) {
        return gserverz.HttpResponse.init(400, "Bad Request", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Path must be absolute" }),
        );
    }
    // Defense in depth (mirrors `static_files.resolve`): the
    // canonicalization below is the real protection. Segments only — a
    // filename may legitimately contain dots (`report..html`), and the
    // shared helper is what the `present_files` tool checks with, so both
    // sides of the contract agree on what a traversal is.
    if (file_sandbox.hasParentSegment(path_param)) {
        return gserverz.HttpResponse.init(403, "Forbidden", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Path traversal rejected" }),
        );
    }

    const di = try pabrikcore.getSingleton();
    const root = file_sandbox.resolveSessionRoot(allocator, di.db, session_id) catch |err| switch (err) {
        error.SessionNotFound => return gserverz.HttpResponse.init(404, "Not Found", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Session not found" }),
        ),
        else => return gserverz.HttpResponse.init(403, "Forbidden", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Session has no working directory" }),
        ),
    };
    defer allocator.free(root);

    // Canonicalize the target (resolves symlinks + `.` segments). A
    // file-level symlink pointing outside the root resolves outside
    // and is rejected by the prefix check below.
    const canon_z = std.Io.Dir.realPathFileAbsoluteAlloc(io, path_param, allocator) catch {
        return gserverz.HttpResponse.init(404, "Not Found", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "File not found" }),
        );
    };
    defer allocator.free(canon_z);
    const canon: []const u8 = canon_z;

    // Canonicalize the root the same way so the prefix comparison is
    // canonical-vs-canonical (a symlinked cwd would otherwise false-
    // reject every file inside it).
    const root_canon_z = std.Io.Dir.realPathFileAbsoluteAlloc(io, root, allocator) catch {
        return gserverz.HttpResponse.init(403, "Forbidden", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Session working directory is not accessible" }),
        );
    };
    defer allocator.free(root_canon_z);
    const root_canon: []const u8 = root_canon_z;

    if (!file_sandbox.isInsideRoot(root_canon, canon, file_sandbox.nativeStyle())) {
        return gserverz.HttpResponse.init(403, "Forbidden", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Path escapes the session working directory" }),
        );
    }

    // Open with directories rejected deterministically, then size-cap.
    const file = std.Io.Dir.cwd().openFile(io, canon, .{ .allow_directory = false }) catch |err| switch (err) {
        error.IsDir => return gserverz.HttpResponse.init(403, "Forbidden", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Path is a directory" }),
        ),
        else => return gserverz.HttpResponse.init(404, "Not Found", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "File not found" }),
        ),
    };
    defer std.Io.File.close(file, io);

    const stat = std.Io.File.stat(file, io) catch {
        return gserverz.HttpResponse.init(404, "Not Found", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "File not found" }),
        );
    };
    if (stat.size > MAX_DOWNLOAD_BYTES) {
        return gserverz.HttpResponse.init(413, "Content Too Large", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "File exceeds the 50 MiB download limit" }),
        );
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, canon, allocator, .limited(MAX_DOWNLOAD_BYTES + 1)) catch {
        return gserverz.HttpResponse.init(500, "Internal Server Error", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read file" }),
        );
    };

    const mime = mimeForPath(canon);
    const basename = std.fs.path.basename(canon);
    // `withHeader` stores the slice by reference (same as `setContentType`
    // and every `makeErrorResponse` payload in this codebase) — do NOT
    // free it; it lives in the per-request allocator like all other
    // handler output. Freeing here is a use-after-free: the header
    // serializes after we return (caught by the functional wire test
    // as garbage bytes in Content-Disposition).
    const disp_value = switch (disposition) {
        .attachment => try std.fmt.allocPrint(allocator, "attachment; filename=\"{s}\"", .{basename}),
        .inline_preview => try std.fmt.allocPrint(allocator, "inline; filename=\"{s}\"", .{basename}),
    };

    // `withBody` sets Content-Length; `setContentType` sets
    // Content-Type. No `Cache-Control: no-store` on inline (thumbnails
    // re-render on every history revisit otherwise); attachment
    // responses are one-shot downloads.
    var resp = gserverz.HttpResponse.init(200, "OK", allocator).withBody(bytes).setContentType(mime).withHeader(
        "Content-Disposition",
        disp_value,
    );
    if (disposition == .inline_preview) {
        resp = resp.withHeader("Cache-Control", "private, max-age=3600");
    } else {
        resp = resp.withHeader("Cache-Control", "no-store");
    }
    return resp;
}

const testing = std.testing;

const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/files_download.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(256 * 1024));
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "parseDisposition defaults to attachment and rejects unknown" {
    try testing.expectEqual(Disposition.attachment, try parseDisposition(null));
    try testing.expectEqual(Disposition.attachment, try parseDisposition("attachment"));
    try testing.expectEqual(Disposition.inline_preview, try parseDisposition("inline"));
    try testing.expectError(error.InvalidDisposition, parseDisposition("download"));
    try testing.expectError(error.InvalidDisposition, parseDisposition(""));
}

test "mimeForPath maps common extensions and falls back to octet-stream" {
    try testing.expectEqualStrings("image/jpeg", mimeForPath("/a/photo.JPG"));
    try testing.expectEqualStrings("image/png", mimeForPath("/a/img.png"));
    try testing.expectEqualStrings("text/plain; charset=utf-8", mimeForPath("/a/notes.txt"));
    try testing.expectEqualStrings("application/pdf", mimeForPath("/a/doc.pdf"));
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("/a/noext"));
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("/a/file.unknownext"));
}

test "the shared rule is the one this endpoint applies" {
    // The container / sibling / drive-letter cases live in
    // `file_sandbox.zig` (they need the explicit PathStyle to be testable
    // from a posix host). This only pins that the handler reaches for it.
    const style = file_sandbox.nativeStyle();
    try testing.expect(file_sandbox.isInsideRoot("/tmp/abc", "/tmp/abc", style));
    try testing.expect(file_sandbox.isInsideRoot("/tmp/abc", "/tmp/abc/file.txt", style));
    try testing.expect(!file_sandbox.isInsideRoot("/tmp/abc", "/tmp/abcd/file.txt", style));
    try testing.expect(!file_sandbox.isInsideRoot("/tmp/abc", "/etc/passwd", style));
    // `..` is a traversal; a dotted filename is not (the tool agrees).
    try testing.expect(file_sandbox.hasParentSegment("/tmp/abc/../x"));
    try testing.expect(!file_sandbox.hasParentSegment("/tmp/abc/report..html"));
}

test "MAX_DOWNLOAD_BYTES stays in sync with the tool cap" {
    const present_files = @import("../modules/agent/tools/present_files.zig");
    try testing.expectEqual(present_files.MAX_FILE_BYTES, MAX_DOWNLOAD_BYTES);
}

test "the download endpoint delegates containment to the shared file_sandbox rule" {
    // The two halves of one contract must not keep private copies: the tool
    // accepted any absolute path while this handler 403'd anything outside
    // the session working directory, so a presented card could never be
    // previewed. Plan: docs/plans/2026-09-29-present-files-sandbox-parity.md
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (!contains(source, "@import(\"../modules/agent/tools/file_sandbox.zig\")")) {
        std.debug.print("!! files_download.zig does not import the shared file_sandbox rule !!\n", .{});
        return error.SharedRuleNotImported;
    }
}

test "the download endpoint has no private containment copy" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    // Assembled at runtime: a literal needle in this file would match itself.
    const private_is_inside = "fn isInside" ++ "Root";
    const private_root = "fn resolveSession" ++ "Root";
    if (contains(source, private_is_inside)) {
        std.debug.print("!! files_download.zig defines its own isInsideRoot — the shared rule is file_sandbox.isInsideRoot !!\n", .{});
        return error.PrivateContainmentCopy;
    }
    if (contains(source, private_root)) {
        std.debug.print("!! files_download.zig defines its own resolveSessionRoot — the shared rule is file_sandbox.resolveSessionRoot !!\n", .{});
        return error.PrivateRootResolutionCopy;
    }
}
