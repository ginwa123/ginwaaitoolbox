const std = @import("std");
const httpz = @import("httpz");

const PORT = 3000;

/// Server context shared across handlers
pub const AppContext = struct {
    allocator: std.mem.Allocator,
    workspaces_dir: []const u8,
};

/// Folder entry structure (matches TypeScript interface)
pub const FolderEntry = struct {
    name: []const u8,
    path: []const u8,
    is_directory: bool,
    is_symlink: bool,
};

/// Run the server with the given allocator and port
pub fn run(allocator: std.mem.Allocator, port: u16) !void {
    const ctx = AppContext{
        .allocator = allocator,
        .workspaces_dir = try allocator.dupe(u8, "workspaces"),
    };
    defer allocator.free(ctx.workspaces_dir);

    // Ensure workspaces directory exists
    std.fs.cwd().makePath(ctx.workspaces_dir) catch |err| {
        std.log.err("Failed to create workspaces directory: {s}", .{@errorName(err)});
        return err;
    };

    var server = try httpz.Server(AppContext).init(allocator, .{
        .address = .localhost(port),
    }, ctx);

    defer server.deinit();

    const router = try server.router(.{});

    // System folder routes
    router.get("/api/system/folder", getSystemFolder, .{});
    router.get("/api/system/folder/list", listFolder, .{});

    // Workspace routes
    router.get("/api/workspaces", listWorkspaces, .{});
    router.post("/api/workspaces", createWorkspace, .{});
    router.get("/api/workspaces/{id}", getWorkspace, .{});
    router.delete("/api/workspaces/{id}", deleteWorkspace, .{});

    // Task routes
    router.get("/api/workspaces/{workspace_id}/items/{item_id}/tasks", listTasks, .{});
    router.post("/api/workspaces/{workspace_id}/items/{item_id}/tasks", createTask, .{});
    router.put("/api/workspaces/{workspace_id}/items/{item_id}/tasks/{task_id}", updateTask, .{});
    router.delete("/api/workspaces/{workspace_id}/items/{item_id}/tasks/{task_id}", deleteTask, .{});

    // Chat routes (placeholder for future AI integration)
    router.post("/api/chat", chatMessage, .{});
    router.get("/api/chat/history/{session_id}", getChatHistory, .{});

    // Health check
    router.get("/health", healthCheck, .{});

    std.log.info("Server listening on http://localhost:{d}", .{port});
    try server.listen();
}

/// Helper to write error response using request arena
fn writeError(res: *httpz.Response, status: u16, msg: []const u8) !void {
    res.status = status;
    res.body = try std.fmt.allocPrint(res.arena, "{{\"error\":\"{s}\"}}", .{msg});
}

/// Health check handler
fn healthCheck(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(res.arena, "{{\"status\":\"ok\",\"timestamp\":{d}}}", .{std.time.timestamp()});
}

/// Escape string for JSON - handles basic escaping
fn jsonEscapeStr(input: []const u8) []const u8 {
    // For now, just return the string as-is
    // In production, you'd escape ", \, etc.
    return input;
}

/// GET /api/system/folder - Get system folder info
fn getSystemFolder(ctx: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;

    const cwd = std.fs.cwd().realpathAlloc(ctx.allocator, ".") catch {
        try writeError(res, 500, "Failed to get current directory");
        return;
    };
    defer ctx.allocator.free(cwd);

    const home = std.posix.getenv("HOME") orelse {
        try writeError(res, 500, "HOME not set");
        return;
    };

    const parent = std.fs.path.dirname(cwd);
    const basename = std.fs.path.basename(cwd);
    
    // Get entries
    const entries = listDirectoryEntries(ctx.allocator, cwd) catch &[_]FolderEntry{};
    
    // Build entries JSON
    var entries_json = std.ArrayList(u8).empty;
    defer entries_json.deinit(ctx.allocator);
    
    for (entries, 0..) |entry, i| {
        if (i > 0) try entries_json.appendSlice(ctx.allocator, ",");
        try entries_json.appendSlice(ctx.allocator, "{\"name\":\"");
        try entries_json.appendSlice(ctx.allocator, jsonEscapeStr(entry.name));
        try entries_json.appendSlice(ctx.allocator, "\",\"path\":\"");
        try entries_json.appendSlice(ctx.allocator, jsonEscapeStr(entry.path));
        try entries_json.appendSlice(ctx.allocator, "\",\"is_directory\":");
        try entries_json.appendSlice(ctx.allocator, if (entry.is_directory) "true" else "false");
        try entries_json.appendSlice(ctx.allocator, ",\"is_symlink\":");
        try entries_json.appendSlice(ctx.allocator, if (entry.is_symlink) "true" else "false");
        try entries_json.appendSlice(ctx.allocator, "}");
    }
    
    // Free entries memory
    for (entries) |entry| {
        ctx.allocator.free(entry.name);
        ctx.allocator.free(entry.path);
    }
    ctx.allocator.free(entries);

    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, 
        "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\",\"entries\":[{s}]}}", .{
        jsonEscapeStr(basename), jsonEscapeStr(cwd), jsonEscapeStr(home), 
        if (parent) |p| jsonEscapeStr(p) else "", entries_json.items
    });
}

/// GET /api/system/folder/list?path=xxx - List specific folder contents
fn listFolder(ctx: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const query_params = try req.query();
    const path_to_list = query_params.get("path") orelse ".";

    const absolute_path = std.fs.cwd().realpathAlloc(ctx.allocator, path_to_list) catch {
        try writeError(res, 500, "Failed to resolve path");
        return;
    };
    defer ctx.allocator.free(absolute_path);

    const home = std.posix.getenv("HOME") orelse "";
    const parent = std.fs.path.dirname(absolute_path);
    const basename = std.fs.path.basename(absolute_path);
    
    // Get entries
    const entries = listDirectoryEntries(ctx.allocator, absolute_path) catch &[_]FolderEntry{};
    
    // Build entries JSON
    var entries_json = std.ArrayList(u8).empty;
    defer entries_json.deinit(ctx.allocator);
    
    for (entries, 0..) |entry, i| {
        if (i > 0) try entries_json.appendSlice(ctx.allocator, ",");
        try entries_json.appendSlice(ctx.allocator, "{\"name\":\"");
        try entries_json.appendSlice(ctx.allocator, jsonEscapeStr(entry.name));
        try entries_json.appendSlice(ctx.allocator, "\",\"path\":\"");
        try entries_json.appendSlice(ctx.allocator, jsonEscapeStr(entry.path));
        try entries_json.appendSlice(ctx.allocator, "\",\"is_directory\":");
        try entries_json.appendSlice(ctx.allocator, if (entry.is_directory) "true" else "false");
        try entries_json.appendSlice(ctx.allocator, ",\"is_symlink\":");
        try entries_json.appendSlice(ctx.allocator, if (entry.is_symlink) "true" else "false");
        try entries_json.appendSlice(ctx.allocator, "}");
    }
    
    // Free entries memory
    for (entries) |entry| {
        ctx.allocator.free(entry.name);
        ctx.allocator.free(entry.path);
    }
    ctx.allocator.free(entries);

    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, 
        "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\",\"entries\":[{s}]}}", .{
        jsonEscapeStr(basename), jsonEscapeStr(absolute_path), jsonEscapeStr(home),
        if (parent) |p| jsonEscapeStr(p) else "", entries_json.items
    });
}

/// List workspaces
fn listWorkspaces(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.content_type = .JSON;
    res.body = "{\"workspaces\":[]}";
}

/// Create a new workspace
fn createWorkspace(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.body();
    res.content_type = .JSON;
    res.body = "{\"id\":\"placeholder\",\"name\":\"New Workspace\",\"items\":[]}";
}

/// Get workspace by ID
fn getWorkspace(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const workspace_id = req.param("id").?;
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(res.arena, "{{\"id\":\"{s}\",\"name\":\"Workspace\",\"items\":[]}}", .{workspace_id});
}

/// Delete workspace
fn deleteWorkspace(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.param("id").?;
    res.content_type = .JSON;
    res.body = "{\"success\":true}";
}

/// List tasks for a workspace item
fn listTasks(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.content_type = .JSON;
    res.body = "{\"tasks\":[]}";
}

/// Create a new task
fn createTask(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.body();
    res.content_type = .JSON;
    res.body = "{\"id\":\"placeholder\",\"name\":\"New Task\"}";
}

/// Update a task
fn updateTask(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.body();
    res.content_type = .JSON;
    res.body = "{\"success\":true}";
}

/// Delete a task
fn deleteTask(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.content_type = .JSON;
    res.body = "{\"success\":true}";
}

/// Chat message handler (placeholder)
fn chatMessage(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.body();
    res.content_type = .JSON;
    res.body = "{\"response\":\"AI integration coming soon\",\"session_id\":\"placeholder\"}";
}

/// Get chat history
fn getChatHistory(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.param("session_id").?;
    res.content_type = .JSON;
    res.body = "{\"messages\":[]}";
}

/// List directory entries for a path
fn listDirectoryEntries(allocator: std.mem.Allocator, path: []const u8) ![]FolderEntry {
    var entries = std.ArrayList(FolderEntry).empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        entries.deinit(allocator);
    }

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
        std.log.warn("Failed to open directory {s}: {s}", .{ path, @errorName(err) });
        return &[_]FolderEntry{};
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const is_symlink = entry.kind == .sym_link;

        var is_dir = entry.kind == .directory;
        if (is_symlink) {
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });
            const real_path = std.fs.cwd().realpathAlloc(allocator, full_path) catch null;
            allocator.free(full_path);
            if (real_path) |rp| {
                defer allocator.free(rp);
                is_dir = std.fs.openDirAbsolute(rp, .{}) catch null != null;
            }
        }

        const entry_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });

        try entries.append(allocator, FolderEntry{
            .name = try allocator.dupe(u8, entry.name),
            .path = entry_path,
            .is_directory = is_dir,
            .is_symlink = is_symlink,
        });
    }

    return entries.toOwnedSlice(allocator);
}