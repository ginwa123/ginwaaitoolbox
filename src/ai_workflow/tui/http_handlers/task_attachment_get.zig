//! GET /api/workspaces/tasks/:task_id/attachments/<n>
//!
//! Serve an attachment file written by `task_attachment_post.zig`. The
//! path is `<workspace_item.path>/.nalar/attachments/<task_id>/<n>` —
//! resolved via the same DB lookup chain (task → item → path).
//!
//! Content-Type is detected from the file extension (mime_guess).
//!
//! 404 if the task / item / file doesn't exist.
//!
//! Plan: docs/superpowers/plans/2026-07-25-kanban-description-rich-editor.md
const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;

/// GET /api/workspaces/tasks/:task_id/attachments/:filename
///
/// The route is registered as `/api/workspaces/tasks/:task_id/attachments/*`
/// (wildcard) in main.zig, so `:filename` is the wildcard capture.
pub fn taskAttachmentGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) anyerror!gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const di = try nalarcore.getSingleton();
    const db = di.db;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    // The filename comes from the wildcard route capture. Look it up
    // in `req.params` (key `filename` since that's the route pattern).
    // Fall back to a path-suffix match if `req.params` doesn't carry it.
    const filename = req.params.get("filename") orelse extractFilenameFromPath(req.path, task_id) orelse "";
    if (filename.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "filename required" }) });
    }

    // Resolve task -> item.path (same as the POST handler).
    const item_path = task_attachment_post.resolveItemPath(allocator, db, task_id) catch |err| {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };
    defer allocator.free(item_path);

    const full_path = std.fs.path.join(allocator, &.{ item_path, ".nalar", "attachments", task_id, filename }) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
    };
    defer allocator.free(full_path);

    // Read the file (cap at 10 MB to prevent memory blowup on a
    // malicious huge file).
    const cwd = std.Io.Dir.cwd();
    const file_stat = cwd.statFile(io, full_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Attachment not found" }) });
        }
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }) });
    };
    const file_size = file_stat.size;
    if (file_size > task_attachment_post.MAX_UPLOAD_BYTES) {
        return res.jsonResponse(.{ .status_code = 413, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Attachment too large" }) });
    }

    const file = cwd.openFile(io, full_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Attachment not found" }) });
        }
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }) });
    };
    defer file.close(io);

    // Read in chunks via readPositional (takes []const []u8 buffer-of-buffers in 0.16).
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var buf: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (body.items.len < task_attachment_post.MAX_UPLOAD_BYTES) {
        const remaining = task_attachment_post.MAX_UPLOAD_BYTES - body.items.len;
        const to_read = @min(buf.len, remaining);
        const amt = file.readPositional(io, &.{buf[0..to_read]}, offset) catch |err| {
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }) });
        };
        if (amt == 0) break;
        try body.appendSlice(allocator, buf[0..amt]);
        offset += amt;
    }

    const content_type = contentTypeFromFilename(filename);
    var resp = gserverz.HttpResponse.init(200, "OK", allocator);
    const len_str = std.fmt.allocPrint(allocator, "{d}", .{body.items.len}) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
    };
    try resp.headers.put("Content-Type", content_type);
    try resp.headers.put("Content-Length", len_str);
    resp.body = body.items;
    return resp;
}

const task_attachment_post = @import("task_attachment_post.zig");

/// Extract the filename portion from a request path when the route
/// uses a wildcard that isn't bound to a named `:param`. E.g., for
/// path `/api/workspaces/tasks/task_123/attachments/1.png` and
/// task_id `task_123`, returns `1.png`.
fn extractFilenameFromPath(req_path: []const u8, task_id: []const u8) ?[]const u8 {
    // Strip query string if present.
    const path = if (std.mem.indexOfScalar(u8, req_path, '?')) |q| req_path[0..q] else req_path;
    // Find the suffix `/attachments/<file>`.
    const marker = "/attachments/";
    const idx = std.mem.lastIndexOf(u8, path, marker) orelse return null;
    const suffix = path[idx + marker.len ..];
    if (suffix.len == 0) return null;
    // Reject path traversal: filename must not contain `/` or `..`.
    if (std.mem.indexOfScalar(u8, suffix, '/') != null) return null;
    if (std.mem.eql(u8, suffix, "..") or std.mem.startsWith(u8, suffix, "../")) return null;
    _ = task_id; // not used here — included for symmetry / future logging
    return suffix;
}

/// Map a filename extension to a Content-Type. Defaults to
/// `application/octet-stream` if the extension is unknown.
fn contentTypeFromFilename(filename: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.');
    const ext = if (dot) |d| filename[d + 1 ..] else "";
    if (std.ascii.eqlIgnoreCase(ext, "png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, "gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, "webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, "svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(ext, "bmp")) return "image/bmp";
    if (std.ascii.eqlIgnoreCase(ext, "heic")) return "image/heic";
    if (std.ascii.eqlIgnoreCase(ext, "heif")) return "image/heif";
    return "application/octet-stream";
}
