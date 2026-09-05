const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const SystemFolder = nalarcore.system_folder.SystemFolder;
const SystemFolderError = nalarcore.system_folder.SystemFolderError;

/// Escape special characters for JSON string values
fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
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

/// System folder endpoint
///
/// GET /api/system/folder
/// GET /api/system/folder?path=/some/relative/path
/// GET /api/system/folder?path=/some/relative/path&action=list
/// GET /api/system/folder?path=/some/relative/path&action=read&file=filename.txt
pub fn systemFolderHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const path_param = req.query.get("path");
    const action = req.query.get("action");
    const do_list = std.mem.eql(u8, action orelse "", "list");

    const di = try nalarcore.getSingleton();
    const environment = di.environment;


    const home = SystemFolder.getHomeDirectory(allocator, environment) catch |err| {
        return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeSystemFolderErrorResponse(allocator, "Failed to get home directory", err) });
    };

    const target_path: []u8 = if (path_param) |p|
        SystemFolder.resolvePath(allocator, p, environment) catch |err| {
            return res.jsonResponse( .{ .status_code = 400, .data = try http_response.makeSystemFolderErrorResponse(allocator, "Invalid path", err) });
        }
    else blk: {
        const dup = allocator.dupe(u8, home) catch {
            return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
        };
        break :blk dup;
    };

    const relative = SystemFolder.getRelativePathFromHome(allocator, target_path, home) catch |err| {
        return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeSystemFolderErrorResponse(allocator, "Failed to compute relative path", err) });
    };

    const parent_opt = SystemFolder.getParentPath(allocator, target_path, environment) catch null;
    const parent_relative = if (parent_opt) |parent|
        SystemFolder.getRelativePathFromHome(allocator, parent, home) catch null
    else
        null;

    if (do_list) {
        const entries = SystemFolder.listDirectory(allocator, ctx.io, target_path) catch |err| {
            const err_msg: []const u8 = switch (err) {
                SystemFolderError.InvalidPath => "Directory not found",
                SystemFolderError.AccessDenied => "Access denied",
                SystemFolderError.NotDirectory => "Not a directory",
                else => @errorName(err),
            };
            return res.jsonResponse( .{ .status_code = 403, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
        };
        defer {
            for (entries) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.path);
            }
            allocator.free(entries);
        }

        // Build entries JSON manually
        var entries_json = std.ArrayList(u8).empty;
        defer entries_json.deinit(allocator);

        for (entries, 0..) |entry, i| {
            if (i > 0) try entries_json.append(allocator, ',');
            try entries_json.appendSlice(allocator, "{\"name\":\"");
            const escaped_name = jsonEscape(allocator, entry.name) catch "";
            const escaped_path = jsonEscape(allocator, entry.path) catch "";
            try entries_json.appendSlice(allocator, escaped_name);
            try entries_json.appendSlice(allocator, "\",\"path\":\"");
            try entries_json.appendSlice(allocator, escaped_path);
            try entries_json.appendSlice(allocator, "\",\"is_directory\":");
            try entries_json.appendSlice(allocator, if (entry.is_directory) "true" else "false");
            try entries_json.appendSlice(allocator, ",\"is_symlink\":");
            try entries_json.appendSlice(allocator, if (entry.is_symlink) "true" else "false");
            try entries_json.append(allocator, '}');
            allocator.free(escaped_name);
            allocator.free(escaped_path);
        }

        if (parent_relative) |pr| {
            // Escape top-level path fields: on Windows they contain
            // backslashes (`C:\Users\...`) which must be `\\`-escaped
            // for valid JSON. Entries above are already escaped; these
            // were inserted raw and broke JSON parsing on Windows.
            const esc_rel = jsonEscape(allocator, relative) catch relative;
            const esc_abs = jsonEscape(allocator, target_path) catch target_path;
            const esc_home = jsonEscape(allocator, home) catch home;
            const esc_parent = jsonEscape(allocator, pr) catch pr;
            defer {
                if (esc_rel.ptr != relative.ptr) allocator.free(esc_rel);
                if (esc_abs.ptr != target_path.ptr) allocator.free(esc_abs);
                if (esc_home.ptr != home.ptr) allocator.free(esc_home);
                if (esc_parent.ptr != pr.ptr) allocator.free(esc_parent);
            }
            return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
                "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\",\"entries\":[{s}]}}",
                .{ esc_rel, esc_abs, esc_home, esc_parent, entries_json.items }) });
        } else {
            const esc_rel = jsonEscape(allocator, relative) catch relative;
            const esc_abs = jsonEscape(allocator, target_path) catch target_path;
            const esc_home = jsonEscape(allocator, home) catch home;
            defer {
                if (esc_rel.ptr != relative.ptr) allocator.free(esc_rel);
                if (esc_abs.ptr != target_path.ptr) allocator.free(esc_abs);
                if (esc_home.ptr != home.ptr) allocator.free(esc_home);
            }
            return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
                "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"entries\":[{s}]}}",
                .{ esc_rel, esc_abs, esc_home, entries_json.items }) });
        }
    }

    // Handle read/write actions - read file content
    const do_read_write = std.mem.eql(u8, action orelse "", "read") or std.mem.eql(u8, action orelse "", "write");
    if (do_read_write) {
        const file_name = req.query.get("file") orelse "";

        // If file_name is an absolute path, use it directly
        // Otherwise, join with target_path. Windows absolutes
        // (`C:\...`, `C:/...`, `\\server\share`) must also count.
        const is_abs = std.mem.startsWith(u8, file_name, "/") or
            (file_name.len >= 2 and std.ascii.isAlphabetic(file_name[0]) and file_name[1] == ':') or
            std.mem.startsWith(u8, file_name, "\\\\");
        const full_path: []u8 = if (is_abs)
            allocator.dupe(u8, file_name) catch return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) })
        else
            std.fs.path.join(allocator, &.{ target_path, file_name }) catch return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to build path" }) });
        defer allocator.free(full_path);

        // Read file using std.Io.Dir.openFileAbsolute
        const file = std.Io.Dir.openFileAbsolute(ctx.io, full_path, .{}) catch return res.jsonResponse( .{ .status_code = 403, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Cannot open file" }) });
        defer file.close(ctx.io);

        var read_buf: [8192]u8 = undefined;
        var reader = file.reader(ctx.io, &read_buf);
        const file_content_init = reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 10)) catch return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read file" }) });
        defer allocator.free(file_content_init);

        // Escape content for JSON
        const escaped_content = jsonEscape(allocator, file_content_init) catch file_content_init;
        defer allocator.free(escaped_content);

        // Return as JSON with plain text content
        return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"content\":\"{s}\",\"encoding\":\"utf-8\"}}",
            .{ escaped_content }) });
    }

    if (parent_relative) |pr| {
        const esc_rel = jsonEscape(allocator, relative) catch relative;
        const esc_abs = jsonEscape(allocator, target_path) catch target_path;
        const esc_home = jsonEscape(allocator, home) catch home;
        const esc_parent = jsonEscape(allocator, pr) catch pr;
        defer {
            if (esc_rel.ptr != relative.ptr) allocator.free(esc_rel);
            if (esc_abs.ptr != target_path.ptr) allocator.free(esc_abs);
            if (esc_home.ptr != home.ptr) allocator.free(esc_home);
            if (esc_parent.ptr != pr.ptr) allocator.free(esc_parent);
        }
        return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\"}}",
            .{ esc_rel, esc_abs, esc_home, esc_parent }) });
    } else {
        const esc_rel = jsonEscape(allocator, relative) catch relative;
        const esc_abs = jsonEscape(allocator, target_path) catch target_path;
        const esc_home = jsonEscape(allocator, home) catch home;
        defer {
            if (esc_rel.ptr != relative.ptr) allocator.free(esc_rel);
            if (esc_abs.ptr != target_path.ptr) allocator.free(esc_abs);
            if (esc_home.ptr != home.ptr) allocator.free(esc_home);
        }
        return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\"}}",
            .{ esc_rel, esc_abs, esc_home }) });
    }
}

