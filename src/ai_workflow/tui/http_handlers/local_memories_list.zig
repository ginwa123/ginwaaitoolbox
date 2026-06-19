const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const list_memory_mod = nalarcore.list_memory_tool;
const http_response = @import("http_response.zig");

/// GET /api/local-memories?cwd=...
///
/// Lists `.md` memory files in `<cwd>/.nalar/memories/`. The
/// `cwd` query param is optional — when omitted, the handler
/// falls back to the nalar server's own CWD via `io.realPath`.
///
/// Returns JSON: `{"memories":[{"name":"...","title":"...","path":"...","size":N}]}`
/// Empty list when the directory does not exist or has no .md files.
///
/// Errors:
///   - 500  cannot resolve the local memories directory (no cwd)
pub fn localMemoriesListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

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

    const list = memories_mod.listMemoriesInDir(allocator, ctx.io, dir_path);
    defer memories_mod.freeMemoriesList(allocator, list);

    const json_response = try list_memory_mod.toJson(allocator, list);
    return res.jsonResponse(.{ .status_code = 200, .data = json_response });
}
