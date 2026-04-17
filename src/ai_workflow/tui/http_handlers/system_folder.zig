const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;
const SystemFolder = root_mod.system_folder.SystemFolder;
const FolderEntry = root_mod.system_folder.FolderEntry;
const SystemFolderError = root_mod.system_folder.SystemFolderError;

/// Escape special characters for JSON string values
fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
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
    return result.toOwnedSlice(allocator);
}

/// System folder endpoint
/// 
/// GET /api/system/folder
/// GET /api/system/folder?path=/some/relative/path
/// GET /api/system/folder?path=/some/relative/path&action=list
/// 
/// Query params:
///   - path: Relative path from home (optional, defaults to cwd)
///   - action: "list" to list directory contents (optional)
/// 
/// Response JSON (default):
/// {
///   "path": "/projects/myapp/src",
///   "absolute": "/home/user/projects/myapp/src",
///   "home": "/home/user",
///   "parent": "/projects/myapp"  // optional
/// }
/// 
/// Response JSON (action=list):
/// {
///   "path": "/projects/myapp/src",
///   "absolute": "/home/user/projects/myapp/src",
///   "home": "/home/user",
///   "parent": "/projects/myapp",
///   "entries": [
///     { "name": "src", "path": "/home/user/projects/myapp/src", "is_directory": true, "is_symlink": false },
///     { "name": "file.txt", "path": "/home/user/projects/myapp/file.txt", "is_directory": false, "is_symlink": false }
///   ]
/// }
pub fn system_folder_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    
    const allocator = req.arena;
    
    // Get query params
    const query = try req.query();
    const path_param = query.get("path");
    const action = query.get("action");
    const do_list = std.mem.eql(u8, action orelse "", "list");
    
    // Get home directory
    const home = SystemFolder.getHomeDirectory(allocator) catch |err| {
        res.status = 500;
        res.body = try std.fmt.allocPrint(allocator, "{{\"error\":\"Failed to get home directory: {s}\"}}", .{@errorName(err)});
        return;
    };
    
    // Determine target path - default to home if no path provided
    const target_path: []u8 = if (path_param) |p| 
        SystemFolder.resolvePath(allocator, p) catch |err| {
            res.status = 400;
            res.body = try std.fmt.allocPrint(allocator, "{{\"error\":\"Invalid path: {s}\"}}", .{@errorName(err)});
            return;
        }
    else blk: {
        const dup = allocator.dupe(u8, home) catch {
            res.status = 500;
            res.body = try std.fmt.allocPrint(allocator, "{{\"error\":\"Out of memory\"}}", .{});
            return;
        };
        break :blk dup;
    };
    
    // Get relative path from home
    const relative = SystemFolder.getRelativePathFromHome(allocator, target_path, home) catch |err| {
        res.status = 500;
        res.body = try std.fmt.allocPrint(allocator, "{{\"error\":\"Failed to compute relative path: {s}\"}}", .{@errorName(err)});
        return;
    };
    
    // Get parent path if not at home
    const parent_opt = SystemFolder.getParentPath(allocator, target_path) catch null;
    const parent_relative = if (parent_opt) |parent| 
        SystemFolder.getRelativePathFromHome(allocator, parent, home) catch null
    else 
        null;
    
    // Handle list action
    if (do_list) {
        const entries = SystemFolder.listDirectory(allocator, target_path) catch |err| {
            const err_msg: []const u8 = switch (err) {
                SystemFolderError.InvalidPath => "Directory not found",
                SystemFolderError.AccessDenied => "Access denied",
                SystemFolderError.NotDirectory => "Not a directory",
                else => @errorName(err),
            };
            res.status = 403;
            res.body = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{err_msg});
            return;
        };
        defer {
            for (entries) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.path);
            }
            allocator.free(entries);
        }
        
        // Build entries JSON
        var entries_json = std.ArrayList(u8).empty;
        for (entries, 0..) |entry, i| {
            if (i > 0) try entries_json.append(allocator, ',');
            
            // Escape name and path for JSON
            const escaped_name = jsonEscape(allocator, entry.name) catch "";
            const escaped_path = jsonEscape(allocator, entry.path) catch "";
            defer {
                allocator.free(escaped_name);
                allocator.free(escaped_path);
            }
            
            try entries_json.writer(allocator).print(
                "{{\"name\":\"{s}\",\"path\":\"{s}\",\"is_directory\":{},\"is_symlink\":{}}}",
                .{
                    escaped_name,
                    escaped_path,
                    entry.is_directory,
                    entry.is_symlink,
                }
            );
        }
        
        // Build full response
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
    
    // Default response (no list action)
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
