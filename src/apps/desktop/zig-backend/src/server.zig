const std = @import("std");
const httpz = @import("httpz");

const PORT = 3000;

/// Server context shared across handlers
pub const AppContext = struct {
    allocator: std.mem.Allocator,
    workspaces_dir: []const u8,
    root_dir: []const u8,
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
    const home = std.posix.getenv("HOME") orelse "/tmp";
    
    const ctx = AppContext{
        .allocator = allocator,
        .workspaces_dir = try allocator.dupe(u8, "workspaces"),
        .root_dir = try allocator.dupe(u8, home),
    };
    defer allocator.free(ctx.workspaces_dir);
    defer allocator.free(ctx.root_dir);

    std.fs.cwd().makePath(ctx.workspaces_dir) catch |err| {
        std.log.err("Failed to create workspaces directory: {s}", .{@errorName(err)});
        return err;
    };

    var server = try httpz.Server(AppContext).init(allocator, .{
        .address = .localhost(port),
    }, ctx);

    defer server.deinit();

    const router = try server.router(.{});

    router.get("/api/system/folder", getSystemFolder, .{});
    router.get("/api/system/folder/list", listFolder, .{});
    router.get("/api/workspaces", listWorkspaces, .{});
    router.post("/api/workspaces", createWorkspace, .{});
    router.get("/api/workspaces/{id}", getWorkspace, .{});
    router.delete("/api/workspaces/{id}", deleteWorkspace, .{});
    router.get("/api/workspaces/{workspace_id}/items/{item_id}/tasks", listTasks, .{});
    router.post("/api/workspaces/{workspace_id}/items/{item_id}/tasks", createTask, .{});
    router.put("/api/workspaces/{workspace_id}/items/{item_id}/tasks/{task_id}", updateTask, .{});
    router.delete("/api/workspaces/{workspace_id}/items/{item_id}/tasks/{task_id}", deleteTask, .{});
    router.post("/api/chat", chatMessage, .{});
    router.get("/api/chat/history/{session_id}", getChatHistory, .{});
    router.get("/health", healthCheck, .{});

    std.log.info("Server listening on http://localhost:{d}", .{port});
    try server.listen();
}

/// Helper to write error response
fn writeError(res: *httpz.Response, status: u16, msg: []const u8) !void {
    res.status = status;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(res.arena);
    try buf.writer(res.arena).print("{{\"error\":\"{s}\"}}", .{msg});
    res.body = try buf.toOwnedSlice(res.arena);
}

/// Health check handler
fn healthCheck(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.content_type = .JSON;
    const resp = .{
        .status = "ok",
        .timestamp = std.time.timestamp(),
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(res.arena);
    try buf.writer(res.arena).print("{f}", .{std.json.fmt(resp, .{})});
    res.body = try buf.toOwnedSlice(res.arena);
}

/// Build a JSON string for an entry
fn buildEntryJson(allocator: std.mem.Allocator, entry: FolderEntry) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.writer(allocator).print("{f}", .{std.json.fmt(entry, .{})});

    return buf.toOwnedSlice(allocator);
}

/// Response struct for folder listing
const FolderResponse = struct {
    path: []const u8,
    absolute: []const u8,
    home: []const u8,
    parent: ?[]const u8,
    entries: []const FolderEntry,
};

/// GET /api/system/folder
fn getSystemFolder(ctx: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;

    const absolute_path = std.fs.cwd().realpathAlloc(ctx.allocator, ctx.root_dir) catch {
        try writeError(res, 500, "Failed to resolve root directory");
        return;
    };
    defer ctx.allocator.free(absolute_path);

    const parent = std.fs.path.dirname(absolute_path);
    const basename = std.fs.path.basename(absolute_path);

    const entries = listDirectoryEntries(ctx.allocator, absolute_path) catch &[0]FolderEntry{};
    defer {
        for (entries) |entry| {
            ctx.allocator.free(entry.name);
            ctx.allocator.free(entry.path);
        }
        ctx.allocator.free(entries);
    }

    const resp = FolderResponse{
        .path = basename,
        .absolute = absolute_path,
        .home = ctx.root_dir,
        .parent = parent,
        .entries = entries,
    };

    res.content_type = .JSON;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(ctx.allocator);
    try buf.writer(ctx.allocator).print("{f}", .{std.json.fmt(resp, .{})});
    res.body = try buf.toOwnedSlice(ctx.allocator);
}

/// GET /api/system/folder/list
fn listFolder(ctx: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const query_params = try req.query();
    const path_to_list = query_params.get("path") orelse ".";

    const absolute_path = std.fs.cwd().realpathAlloc(ctx.allocator, path_to_list) catch {
        try writeError(res, 500, "Failed to resolve path");
        return;
    };
    defer ctx.allocator.free(absolute_path);

    const parent = std.fs.path.dirname(absolute_path);
    const basename = std.fs.path.basename(absolute_path);

    const entries = listDirectoryEntries(ctx.allocator, absolute_path) catch &[0]FolderEntry{};
    defer {
        for (entries) |entry| {
            ctx.allocator.free(entry.name);
            ctx.allocator.free(entry.path);
        }
        ctx.allocator.free(entries);
    }

    const resp = FolderResponse{
        .path = basename,
        .absolute = absolute_path,
        .home = ctx.root_dir,
        .parent = parent,
        .entries = entries,
    };

    res.content_type = .JSON;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(ctx.allocator);
    try buf.writer(ctx.allocator).print("{f}", .{std.json.fmt(resp, .{})});
    res.body = try buf.toOwnedSlice(ctx.allocator);
}

fn listWorkspaces(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.content_type = .JSON;
    res.body = "{\"workspaces\":[]}";
}

fn createWorkspace(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.body();
    res.content_type = .JSON;
    res.body = "{\"id\":\"placeholder\",\"name\":\"New Workspace\",\"items\":[]}";
}

fn getWorkspace(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const workspace_id = req.param("id").?;
    res.content_type = .JSON;
    const resp = .{
        .id = workspace_id,
        .name = "Workspace",
        .items = &[_]u8{},
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(res.arena);
    try buf.writer(res.arena).print("{f}", .{std.json.fmt(resp, .{})});
    res.body = try buf.toOwnedSlice(res.arena);
}

fn deleteWorkspace(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.param("id").?;
    res.content_type = .JSON;
    res.body = "{\"success\":true}";
}

fn listTasks(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.content_type = .JSON;
    res.body = "{\"tasks\":[]}";
}

fn createTask(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.body();
    res.content_type = .JSON;
    res.body = "{\"id\":\"placeholder\",\"name\":\"New Task\"}";
}

fn updateTask(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.body();
    res.content_type = .JSON;
    res.body = "{\"success\":true}";
}

fn deleteTask(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.content_type = .JSON;
    res.body = "{\"success\":true}";
}

fn chatMessage(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.body();
    res.content_type = .JSON;
    res.body = "{\"response\":\"AI integration coming soon\",\"session_id\":\"placeholder\"}";
}

fn getChatHistory(_: AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.param("session_id").?;
    res.content_type = .JSON;
    res.body = "{\"messages\":[]}";
}

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
