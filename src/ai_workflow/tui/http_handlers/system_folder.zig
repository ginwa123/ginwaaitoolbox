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
pub fn system_folder_handler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
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
            return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
                "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\",\"entries\":[{s}]}}",
                .{ relative, target_path, home, pr, entries_json.items }) });
        } else {
            return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
                "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"entries\":[{s}]}}",
                .{ relative, target_path, home, entries_json.items }) });
        }
    }

    if (parent_relative) |pr| {
        return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\"}}",
            .{ relative, target_path, home, pr }) });
    } else {
        return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\"}}",
            .{ relative, target_path, home }) });
    }
}
