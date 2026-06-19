const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const http_response = @import("http_response.zig");

/// JSON request body for `POST /api/local-memories`.
///
/// `cwd` is optional in the body — when omitted, the handler falls
/// back to the nalar server's own CWD via `io.realPath` (matches
/// the skill-detail handler's behavior). `name` and `content` are
/// required. `name` must end in `.md`, with no path separators or
/// `..` segments (see `memories.isValidMemoryName`).
const CreateLocalMemoryBody = struct {
    name: []const u8,
    content: []const u8,
    /// Optional. When omitted, falls back to the nalar server's CWD.
    cwd: ?[]const u8 = null,
};

/// Response shape for `POST /api/local-memories`.
///
/// On success: 201 with `{"memory":{name,title,path,size}}` (no
/// `content` field — the create-then-GET-back pattern in the UI
/// reads the body via `GET /api/local-memories/:name`). On error:
/// `error_message` is set and `memory` is null.
const CreateLocalMemoryResponse = struct {
    memory: ?memories_mod.MemoryInfo = null,
    error_message: ?[]const u8 = null,
};

/// POST /api/local-memories
///
/// Body: `{"name":"foo.md","content":"...","cwd":"/abs/path"}`.
///
/// On success: 201 with `{"memory":{name,title,path,size}}`.
/// Errors:
///   - 500  cannot resolve the local memories directory (no cwd available)
///   - 400  missing/invalid name, missing/empty body, bad JSON,
///          `writeLocalMemoryFile` failed (IO or OOM)
///   - 409  a memory with the same name already exists
pub fn localMemoryCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateLocalMemoryBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const name = parsed.name;
    if (name.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }
    if (!memories_mod.isValidMemoryName(name)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid memory name (must end in .md, no /, no ..)" }),
        });
    }

    // Resolve the local memories directory: prefer explicit `cwd`
    // from the body, fall back to the nalar server's CWD. Mirrors
    // the skill handlers' cwd-resolution strategy.
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

    // 409 on duplicate. Validates the name (defense in depth) so
    // an invalid name returns 400 above, never reaching this check.
    if (memories_mod.localMemoryExists(allocator, ctx.io, dir_path, name)) {
        return res.jsonResponse(.{
            .status_code = 409,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Memory already exists" }),
        });
    }

    if (!memories_mod.writeLocalMemoryFile(allocator, ctx.io, dir_path, name, parsed.content)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to write memory file" }),
        });
    }

    // Re-list the local directory to derive title/path/size. The
    // freshly-created file is always in the list right after the
    // write succeeds.
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
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Memory written but not visible in directory listing" }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(allocator, CreateLocalMemoryResponse{ .memory = m }, .{}),
    });
}
