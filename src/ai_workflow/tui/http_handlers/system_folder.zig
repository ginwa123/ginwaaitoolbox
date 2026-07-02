const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const SystemFolder = nalarcore.system_folder.SystemFolder;
const SystemFolderError = nalarcore.system_folder.SystemFolderError;

pub const SystemFolderError_ = error{
    OutOfMemory,
    FailedToGetHomeDirectory,
    InvalidPath,
    FailedToComputeRelativePath,
    DirectoryListFailed,
    CannotOpenFile,
    FailedToReadFile,
};

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

const SystemFolderInput = struct {
    /// Optional relative path under `$HOME` (the `?path=` query param).
    /// When `null`, the useCase operates on `$HOME` itself.
    path: ?[]const u8,
    /// When "list", enumerate directory entries. When "read" or "write",
    /// read a file (combined with `file`).
    action: ?[]const u8,
    /// Optional file name to read. Joined onto `target_path` when relative,
    /// used verbatim when absolute.
    file: ?[]const u8,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
};

/// Tagged result of the use case. Lists are materialised into JSON-ish
/// pre-rendered strings so the handler only encodes the outer envelope.
const SystemFolderResult = union(enum) {
    /// `?action=list`: included entries as a serialized JSON array
    /// (without surrounding `[]` brackets — the handler wraps it).
    list_with_parent: ListWithParent,
    list_no_parent: ListNoParent,
    /// `?action=read|write`: file content (already JSON-escaped) and encoding hint.
    file_content: FileContent,
    /// No action — directory metadata only.
    meta_with_parent: MetaWithParent,
    meta_no_parent: MetaNoParent,

    const ListWithParent = struct {
        relative: []const u8,
        target_path: []const u8,
        home: []const u8,
        parent: []const u8,
        entries_json: []const u8,
    };
    const ListNoParent = struct {
        relative: []const u8,
        target_path: []const u8,
        home: []const u8,
        entries_json: []const u8,
    };
    const FileContent = struct {
        escaped_content: []const u8,
    };
    const MetaWithParent = struct {
        relative: []const u8,
        target_path: []const u8,
        home: []const u8,
        parent: []const u8,
    };
    const MetaNoParent = struct {
        relative: []const u8,
        target_path: []const u8,
        home: []const u8,
    };
};

/// System folder endpoint
///
/// GET /api/system/folder
/// GET /api/system/folder?path=/some/relative/path
/// GET /api/system/folder?path=/some/relative/path&action=list
/// GET /api/system/folder?path=/some/relative/path&action=read&file=filename.txt
pub fn systemFolderHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();

    const result = useCase(allocator, .{
        .path = req.query.get("path"),
        .action = req.query.get("action"),
        .file = req.query.get("file"),
        .io = ctx.io,
        .environment = di.environment,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidPath => 400,
            error.CannotOpenFile => 403,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.FailedToGetHomeDirectory => "Failed to get home directory",
            error.InvalidPath => "Invalid path",
            error.FailedToComputeRelativePath => "Failed to compute relative path",
            error.DirectoryListFailed => "Failed to list directory",
            error.CannotOpenFile => "Cannot open file",
            error.FailedToReadFile => "Failed to read file",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{ .status_code = status, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }) });
    };

    return switch (result) {
        .list_with_parent => |r| res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\",\"entries\":[{s}]}}",
            .{ r.relative, r.target_path, r.home, r.parent, r.entries_json }) }),
        .list_no_parent => |r| res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"entries\":[{s}]}}",
            .{ r.relative, r.target_path, r.home, r.entries_json }) }),
        .file_content => |r| res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"content\":\"{s}\",\"encoding\":\"utf-8\"}}",
            .{ r.escaped_content }) }),
        .meta_with_parent => |r| res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\"}}",
            .{ r.relative, r.target_path, r.home, r.parent }) }),
        .meta_no_parent => |r| res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\"}}",
            .{ r.relative, r.target_path, r.home }) }),
    };
}

fn useCase(allocator: std.mem.Allocator, input: SystemFolderInput) SystemFolderError_!SystemFolderResult {
    const do_list = std.mem.eql(u8, input.action orelse "", "list");
    const do_read_write = std.mem.eql(u8, input.action orelse "", "read") or std.mem.eql(u8, input.action orelse "", "write");

    const home = SystemFolder.getHomeDirectory(allocator, input_environment(input)) catch {
        return error.FailedToGetHomeDirectory;
    };

    const target_path: []u8 = if (input.path) |p|
        SystemFolder.resolvePath(allocator, p, input_environment(input)) catch {
        allocator.free(home);
        return error.InvalidPath;
    }
    else blk: {
        const dup = allocator.dupe(u8, home) catch {
            allocator.free(home);
            return error.OutOfMemory;
        };
        break :blk dup;
    };
    defer allocator.free(target_path);
    defer allocator.free(home);

    const relative = SystemFolder.getRelativePathFromHome(allocator, target_path, home) catch {
        return error.FailedToComputeRelativePath;
    };

    const parent_opt = SystemFolder.getParentPath(allocator, target_path, input_environment(input)) catch null;
    const parent_relative: ?[]u8 = if (parent_opt) |parent|
        SystemFolder.getRelativePathFromHome(allocator, parent, home) catch null
    else
        null;

    if (do_list) {
        const entries = SystemFolder.listDirectory(allocator, input.io, target_path) catch |err| {
            const err_msg: []const u8 = switch (err) {
                SystemFolderError.InvalidPath => "Directory not found",
                SystemFolderError.AccessDenied => "Access denied",
                SystemFolderError.NotDirectory => "Not a directory",
                else => @errorName(err),
            };
            std.log.warn("system_folder listDirectory failed: {s}", .{err_msg});
            return error.DirectoryListFailed;
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
            return .{ .list_with_parent = .{
                .relative = relative,
                .target_path = target_path,
                .home = home,
                .parent = pr,
                .entries_json = entries_json.items,
            } };
        }
        return .{ .list_no_parent = .{
            .relative = relative,
            .target_path = target_path,
            .home = home,
            .entries_json = entries_json.items,
        } };
    }

    if (do_read_write) {
        const file_name = input.file orelse "";
        // If file_name is an absolute path, use it directly.
        // Otherwise, join with target_path.
        const full_path: []u8 = if (std.mem.startsWith(u8, file_name, "/"))
            allocator.dupe(u8, file_name) catch return error.OutOfMemory
        else
            std.fs.path.join(allocator, &.{ target_path, file_name }) catch return error.OutOfMemory;
        defer allocator.free(full_path);

        // Read file using std.Io.Dir.openFileAbsolute
        const file = std.Io.Dir.openFileAbsolute(input.io, full_path, .{}) catch {
            return error.CannotOpenFile;
        };
        defer file.close(input.io);

        var read_buf: [8192]u8 = undefined;
        var reader = file.reader(input.io, &read_buf);
        const file_content_init = reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 10)) catch {
            return error.FailedToReadFile;
        };
        defer allocator.free(file_content_init);

        // Escape content for JSON
        const escaped_content = jsonEscape(allocator, file_content_init) catch file_content_init;

        return .{ .file_content = .{ .escaped_content = escaped_content } };
    }

    if (parent_relative) |pr| {
        return .{ .meta_with_parent = .{
            .relative = relative,
            .target_path = target_path,
            .home = home,
            .parent = pr,
        } };
    }
    return .{ .meta_no_parent = .{
        .relative = relative,
        .target_path = target_path,
        .home = home,
    } };
}

fn input_environment(input: SystemFolderInput) *const std.process.Environ.Map {
    return input.environment.?;
}