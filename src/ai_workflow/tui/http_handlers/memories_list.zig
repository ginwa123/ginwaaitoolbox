const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const list_memory_mod = nalarcore.list_memory_tool;
const http_response = @import("http_response.zig");

/// GET /api/memories - List all global memory files (markdown) in
/// $XDG_CONFIG_HOME/nalar/memories/ or ~/.config/nalar/memories/.
///
/// Returns JSON: `{"memories":[{"name":"...","title":"...","path":"...","size":N}]}`
/// Empty list when no memories exist or the folder is missing — never throws.
pub fn memoriesListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;

    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const environment = di.environment orelse {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing environment" }),
        });
    };

    const list = memories_mod.listAllMemories(allocator, ctx.io, environment);
    defer memories_mod.freeMemoriesList(allocator, list);

    const json_response = try list_memory_mod.toJson(allocator, list);
    return res.jsonResponse(.{ .status_code = 200, .data = json_response });
}
