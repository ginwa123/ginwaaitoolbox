//! POST /api/workspaces/tasks/:task_id/attachments
//!
//! Upload an image attachment for a kanban task. The body is the raw
//! file bytes (Content-Type: image/png, image/jpeg, etc.). The server
//! resolves the task's parent workspace_item.path, writes the file to
//! `<path>/.nalar/attachments/<task_id>/<n>.<ext>`, and returns a JSON
//! payload with the URL the frontend should embed in the markdown
//! description as `![name](<url>)`.
//!
//! Storage format (Option C of the rich description plan):
//!   - Files live on the user's filesystem inside the kanban's root
//!     directory (`<workspace_item.path>/.nalar/attachments/<task_id>/`).
//!   - The description column stores only the markdown + URL — no
//!     base64 inlining, no separate blob table.
//!   - Existing data: URLs in legacy descriptions continue to render
//!     correctly (MarkdownDescription passes them through marked
//!     unchanged).
//!
//! Why Option C (filesystem-backed):
//!   - One image attached to N tasks = one disk file (no duplication).
//!   - Card preview stays tiny (few hundred chars of markdown).
//!   - Backups work natively (the file is on the user's disk).
//!   - SSE re-broadcasts stay small (description is text-only).
//!
//! Query string: `?filename=<original>` lets the server pick the
//! extension. Falls back to Content-Type → extension mapping if the
//! filename has none.
//!
//! Cap: 10 MB per upload. Larger uploads return 413. The frontend's
//! KanbanDescriptionEditor pre-downscales via <canvas> in the browser,
//! so this cap is a safety net rather than a normal path.
//!
//! Plan: docs/superpowers/plans/2026-07-25-kanban-description-rich-editor.md
const std = @import("std");
const builtin = @import("builtin");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;

// 10 MB cap. Larger uploads are rejected with 413.
pub const MAX_UPLOAD_BYTES: usize = 10 * 1024 * 1024;

// Allowed file extensions (case-insensitive). ZIP-bombs / executables
// are blocked at the URL-extension layer.
pub const ALLOWED_EXTENSIONS = [_][]const u8{
    "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic", "heif",
};

/// Handler entry point.
///
/// POST /api/workspaces/tasks/:task_id/attachments?filename=<original>
///
/// Body: raw file bytes (Content-Type matches the file's MIME type).
///
/// Returns 200 with `{ success: true, url, size }` on success.
/// Returns 4xx for validation errors, 5xx for filesystem failures.
pub fn taskAttachmentPostHandler(
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

    // Resolve task -> workspace_item.path. Legacy kanbans (no `path`)
    // can't accept attachments — return 400 with a clear message.
    const item_path = resolveItemPath(allocator, db, task_id) catch |err| {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };
    defer allocator.free(item_path);

    // Pick the file extension from ?filename= or Content-Type.
    const filename_param = req.query.get("filename") orelse "";
    const ext = extensionFromFilename(filename_param, req.headers.get("content-type"));
    if (ext.len == 0 or !isAllowedExtension(ext)) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Unsupported file type; allowed: png, jpg, jpeg, gif, webp, svg, bmp, heic, heif" }) });
    }

    if (req.body.len > MAX_UPLOAD_BYTES) {
        return res.jsonResponse(.{ .status_code = 413, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "File too large; max 10 MB" }) });
    }

    // Build the attachments directory path.
    const attachments_dir = std.fs.path.join(allocator, &.{ item_path, ".nalar", "attachments", task_id }) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
    };
    defer allocator.free(attachments_dir);

    mkdirp(io, attachments_dir) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }) });
    };

    const chosen_name = nextAvailableName(io, allocator, attachments_dir, ext) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }) });
    };
    defer allocator.free(chosen_name);

    const full_path = std.fs.path.join(allocator, &.{ attachments_dir, chosen_name }) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
    };
    defer allocator.free(full_path);

    // Atomic write: place the tmp file in `attachments_dir` itself
    // (a sibling of `chosen_name`), NOT inside the not-yet-existent
    // target file. `path.join([full_path, ".tmp"])` would otherwise
    // produce `<dir>/1.png/.tmp` — i.e. a path through a directory
    // named `1.png`, which doesn't exist, so `createFile` returns
    // `FileNotFound`. Putting `.tmp.<name>` next to the target file
    // is the right path layout for the rename dance below.
    const tmp_filename = std.fmt.allocPrint(allocator, ".tmp.{s}", .{chosen_name}) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
    };
    defer allocator.free(tmp_filename);
    const tmp_path = std.fs.path.join(allocator, &.{ attachments_dir, tmp_filename }) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
    };
    defer allocator.free(tmp_path);

    writeFileAtomic(io, tmp_path, full_path, req.body) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }) });
    };

    const url_path = std.fs.path.join(allocator, &.{ "/api/workspaces/tasks", task_id, "attachments", chosen_name }) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
    };
    defer allocator.free(url_path);

    const escaped_url = jsonEscape(allocator, url_path) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
    };
    defer allocator.free(escaped_url);

    const body = std.fmt.allocPrint(allocator, "{{\"success\":true,\"url\":\"{s}\",\"size\":{d}}}", .{ escaped_url, req.body.len }) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
    };
    defer allocator.free(body);

    return res.jsonResponse(.{ .status_code = 200, .data = body });
}

// =====================================================================
// useCase helpers — exported so the test can hit them directly without
// spinning up a full HTTP request.
// =====================================================================

/// Resolve `task_id` -> `workspace_items.path` for the parent kanban.
/// Returns the path (caller frees), or an error if the task/item don't
/// exist or the item has no `path` set (legacy kanban).
pub fn resolveItemPath(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    task_id: []const u8,
) ![]u8 {
    var q = try db.query(allocator, "SELECT workspace_item_id FROM workspace_item_tasks WHERE id = ?", &.{task_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.TaskNotFound;
    defer row.deinit(allocator);
    const item_id = row.values[0];
    if (item_id.len == 0) return error.TaskNotFound;

    var q2 = try db.query(allocator, "SELECT COALESCE(path, '') FROM workspace_items WHERE id = ?", &.{item_id});
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.ItemPathNotSet;
    defer row2.deinit(allocator);
    const path = row2.values[0];
    if (path.len == 0) return error.ItemPathNotSet;
    return try allocator.dupe(u8, path);
}

/// Extract the file extension (without the leading dot) from a
/// filename string. Falls back to the Content-Type if the filename
/// has no extension. Empty string if unknown.
pub fn extensionFromFilename(filename: []const u8, content_type: ?[]const u8) []const u8 {
    if (filename.len > 0) {
        var last_dot: ?usize = null;
        for (filename, 0..) |c, i| {
            if (c == '.') last_dot = i;
        }
        if (last_dot) |dot| {
            if (dot > 0 and dot < filename.len - 1) {
                return filename[dot + 1 ..];
            }
        }
    }
    if (content_type) |ct| {
        return contentTypeToExtension(ct);
    }
    return "";
}

/// Map a Content-Type to a file extension. Empty string if unknown.
pub fn contentTypeToExtension(content_type: []const u8) []const u8 {
    if (std.ascii.startsWithIgnoreCase(content_type, "image/png")) return "png";
    if (std.ascii.startsWithIgnoreCase(content_type, "image/jpeg")) return "jpg";
    if (std.ascii.startsWithIgnoreCase(content_type, "image/jpg")) return "jpg";
    if (std.ascii.startsWithIgnoreCase(content_type, "image/gif")) return "gif";
    if (std.ascii.startsWithIgnoreCase(content_type, "image/webp")) return "webp";
    if (std.ascii.startsWithIgnoreCase(content_type, "image/svg+xml")) return "svg";
    if (std.ascii.startsWithIgnoreCase(content_type, "image/bmp")) return "bmp";
    if (std.ascii.startsWithIgnoreCase(content_type, "image/heic")) return "heic";
    if (std.ascii.startsWithIgnoreCase(content_type, "image/heif")) return "heif";
    return "";
}

/// Check if an extension is in the allow-list (case-insensitive).
pub fn isAllowedExtension(ext: []const u8) bool {
    for (ALLOWED_EXTENSIONS) |allowed| {
        if (std.ascii.eqlIgnoreCase(ext, allowed)) return true;
    }
    return false;
}

/// Find the next available `N.<ext>` filename in the directory.
/// Starts at 1, increments until a free slot is found.
pub fn nextAvailableName(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    ext: []const u8,
) ![]u8 {
    var dir_handle = try std.Io.Dir.openDirAbsolute(io, dir, .{});
    defer dir_handle.close(io);

    var n: u32 = 1;
    while (n < 100000) : (n += 1) {
        var buf: [32]u8 = undefined;
        const candidate = std.fmt.bufPrint(&buf, "{d}.{s}", .{ n, ext }) catch return error.OutOfMemory;
        if (dir_handle.openFile(io, candidate, .{})) |f| {
            f.close(io);
            continue;
        } else |_| {
            return try allocator.dupe(u8, candidate);
        }
    }
    return error.TooManyAttachments;
}

// =====================================================================
// std.fs helpers
// =====================================================================

/// `mkdir -p` — create the directory + any missing parents. Returns
/// success if the directory already exists. Uses raw POSIX mkdirat
/// to avoid relying on the project-specific std.fs path APIs which
/// differ between Zig versions.
pub fn mkdirp(io: std.Io, path: []const u8) !void {
    var it = std.fs.path.componentIterator(path);
    const gpa = std.heap.page_allocator;
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);
    if (path.len > 0 and path[0] == '/') try current.append(gpa, '/');

    while (it.next()) |comp| {
        if (comp.name.len == 0) continue;
        try current.appendSlice(gpa, comp.name);
        if (current.items.len == 0 or (current.items.len == 1 and current.items[0] == '/')) continue;
        // mkdirat returns EEXIST if the directory already exists — that's fine.
        switch (builtin.os.tag) {
            .linux, .macos => {
                // NUL-terminate the path for the C ABI. Use allocSentinel
                // so the result is `[:0]u8` which coerces to `[*:0]u8`.
                var path_z = try gpa.allocSentinel(u8, current.items.len, 0);
                defer gpa.free(path_z);
                @memcpy(path_z[0..current.items.len], current.items);
                const rc = std.c.mkdirat(std.c.AT.FDCWD, path_z, 0o755);
                if (rc != 0) {
                    const err = std.c.errno(rc);
                    if (err != .EXIST) return error.MkdirFailed;
                }
            },
            .windows => {
                std.fs.makeDirAbsolute(current.items) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            },
            else => return error.UnsupportedOs,
        }
        try current.append(gpa, '/');
    }
    _ = io;
}

/// Atomic file write: write to `tmp_path` then rename to `final_path`.
/// On failure the temp file is best-effort deleted; partial uploads
/// never overwrite existing files.
pub fn writeFileAtomic(io: std.Io, tmp_path: []const u8, final_path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    {
        const file = try cwd.createFile(io, tmp_path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, data);
    }
    // Atomic rename via std.Io.Dir.renameAbsolute.
    std.Io.Dir.renameAbsolute(tmp_path, final_path, io) catch |err| return err;
}

fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    for (value) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, c),
        }
    }
    return try result.toOwnedSlice(allocator);
}
