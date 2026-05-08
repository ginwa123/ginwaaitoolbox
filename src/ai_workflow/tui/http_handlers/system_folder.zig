const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const http_response = root_mod.http_response;

const httpz = http_server.httpz;
const SystemFolder = root_mod.system_folder.SystemFolder;
const SystemFolderError = root_mod.system_folder.SystemFolderError;

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
pub fn system_folder_handler(handler: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;

    const allocator = req.arena;

    const query = try req.query();
    const path_param = query.get("path");
    const action = query.get("action");
    const do_list = std.mem.eql(u8, action orelse "", "list");

    const home = SystemFolder.getHomeDirectory(allocator, handler.server.environment) catch |err| {
        res.status = 500;
        res.body = try http_response.makeSystemFolderErrorResponse(allocator, "Failed to get home directory", err);
        return;
    };

    const target_path: []u8 = if (path_param) |p|
        SystemFolder.resolvePath(allocator, p, handler.server.environment) catch |err| {
            res.status = 400;
            res.body = try http_response.makeSystemFolderErrorResponse(allocator, "Invalid path", err);
            return;
        }
    else blk: {
        const dup = allocator.dupe(u8, home) catch {
            res.status = 500;
            res.body = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" });
            return;
        };
        break :blk dup;
    };

    const relative = SystemFolder.getRelativePathFromHome(allocator, target_path, home) catch |err| {
        res.status = 500;
        res.body = try http_response.makeSystemFolderErrorResponse(allocator, "Failed to compute relative path", err);
        return;
    };

    const parent_opt = SystemFolder.getParentPath(allocator, target_path, handler.server.environment) catch null;
    const parent_relative = if (parent_opt) |parent|
        SystemFolder.getRelativePathFromHome(allocator, parent, home) catch null
    else
        null;

    if (do_list) {
        const entries = SystemFolder.listDirectory(allocator, handler.server.io, target_path) catch |err| {
            const err_msg: []const u8 = switch (err) {
                SystemFolderError.InvalidPath => "Directory not found",
                SystemFolderError.AccessDenied => "Access denied",
                SystemFolderError.NotDirectory => "Not a directory",
                else => @errorName(err),
            };
            res.status = 403;
            res.body = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg });
            return;
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

        res.status = 200;
        if (parent_relative) |pr| {
            res.body = try std.fmt.allocPrint(allocator,
                "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\",\"entries\":[{s}]}}",
                .{ relative, target_path, home, pr, entries_json.items }
            );
        } else {
            res.body = try std.fmt.allocPrint(allocator,
                "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"entries\":[{s}]}}",
                .{ relative, target_path, home, entries_json.items }
            );
        }
        return;
    }

    res.status = 200;
    if (parent_relative) |pr| {
        res.body = try std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\"}}",
            .{ relative, target_path, home, pr }
        );
    } else {
        res.body = try std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\"}}",
            .{ relative, target_path, home }
        );
    }
}