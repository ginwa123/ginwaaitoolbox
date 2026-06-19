const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const http_response = @import("http_response.zig");

/// JSON request body for `PUT /api/local-memories/:name`.
///
/// `content` is the new file body (required). `cwd` is optional —
/// when omitted, the handler falls back to the nalar server's CWD.
const UpdateLocalMemoryBody = struct {
    content: []const u8,
    cwd: ?[]const u8 = null,
};

/// Response shape for `PUT /api/local-memories/:name`.
const UpdateLocalMemoryResponse = struct {
    memory: ?memories_mod.MemoryInfo = null,
    error_message: ?[]const u8 = null,
};

/// PUT /api/local-memories/:name?cwd=...
///
/// Body: `{"content":"...","cwd":"/abs/path"}`.
///
/// On success: 200 with `{"memory":{name,title,path,size}}`.
/// Errors:
///   - 500  cannot resolve the local memories directory (no cwd)
///   - 400  missing `:name`, invalid name, missing body, bad JSON,
///          `writeLocalMemoryFile` failed
///   - 404  the memory does not exist (cannot edit a non-existent one)
pub fn localMemoryUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const name = req.params.get("name") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing :name" }),
        });
    };
    if (name.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing :name" }),
        });
    }
    if (!memories_mod.isValidMemoryName(name)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid memory name (must end in .md, no /, no ..)" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateLocalMemoryBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // Resolve the local memories directory: prefer explicit `cwd`
    // from the body, fall back to the nalar server's CWD.
    var dir_path_alloc: ?[]const u8 = null;
    if (parsed.cwd) |cwd| {
        if (cwd.len > 0) {
            dir_path_alloc = memories_mod.get_local_memories_path_for_dir(allocator, cwd);
        }
    }
    if (dir_path_alloc == null) {
        dir_path_alloc = memories_mod.get_local_memories_path_from_io(allocator, ctx.io);
    }
    const dir_path = dir_path_alloc orelse {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Could not resolve local memories directory (no cwd available)" }),
        });
    };
    defer allocator.free(dir_path);

    // Update only succeeds for existing memories. 404 (not 400) so the
    // UI can distinguish "edit non-existent" from "bad input".
    if (!memories_mod.localMemoryExists(allocator, ctx.io, dir_path, name)) {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Memory not found" }),
        });
    }

    if (!memories_mod.writeLocalMemoryFile(allocator, ctx.io, dir_path, name, parsed.content)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to write memory file" }),
        });
    }

    // Re-list for the response payload (matches the create handler).
    const list = memories_mod.listMemoriesInDir(allocator, ctx.io, dir_path);
    defer memories_mod.freeMemoriesList(allocator, list);

    var found: ?memories_mod.MemoryInfo = null;
    for (list) |m| {
        if (std.mem.eql(u8, m.name, name)) {
            found = m;
            break;
        }
    }
    const m = found orelse {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Memory updated but not visible in directory listing" }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, UpdateLocalMemoryResponse{ .memory = m }, .{}),
    });
}
