const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const http_response = @import("http_response.zig");

/// Response shape for `GET /api/local-memories/:name`.
///
/// `memory` is non-null on success; `error_message` is non-null on
/// 4xx/5xx. Uses `std.json.Stringify.valueAlloc` so `content` is
/// JSON-escaped automatically — do not hand-roll JSON for the body.
const LocalMemoryDetailPayload = struct {
    name: []const u8,
    title: []const u8,
    path: []const u8,
    size: u64,
    content: []const u8,
};

const LocalMemoryDetailResponse = struct {
    memory: ?LocalMemoryDetailPayload = null,
    error_message: ?[]const u8 = null,
};

/// GET /api/local-memories/:name?cwd=...
///
/// On success: 200 with `{"memory":{"name","title","path","size","content"}}`.
/// Errors:
///   - 500  cannot resolve the local memories directory (no cwd)
///   - 400  missing `:name`, invalid name
///   - 404  the file does not exist (or its name fails validation)
pub fn localMemoryDetailHandler(
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
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid memory name" }),
        });
    }

    // Resolve the local memories directory: prefer explicit `cwd`
    // from the query, fall back to the nalar server's CWD.
    var dir_path_alloc: ?[]const u8 = null;
    if (req.query.get("cwd")) |cwd| {
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

    const content = memories_mod.readLocalMemoryFile(allocator, ctx.io, dir_path, name) orelse {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Memory not found" }),
        });
    };
    defer allocator.free(content);

    // Re-list the local directory to find the title/path/size entry
    // for the loaded file. The list is cheap (single openDir + iterate).
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
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Memory not found" }),
        });
    };

    const payload = LocalMemoryDetailPayload{
        .name = m.name,
        .title = m.title,
        .path = m.path,
        .size = m.size,
        .content = content,
    };
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, LocalMemoryDetailResponse{ .memory = payload }, .{}),
    });
}
