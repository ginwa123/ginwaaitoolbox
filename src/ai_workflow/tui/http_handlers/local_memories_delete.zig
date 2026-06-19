const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const http_response = @import("http_response.zig");

/// Response shape for `DELETE /api/local-memories/:name`.
///
/// Idempotent: `deleteLocalMemoryFile` returns true when the file
/// is deleted OR was already missing (matches the
/// `deleteMemoryFile` global helper's contract). The handler
/// therefore always returns 200 with `success=true` on a valid
/// name.
const DeleteLocalMemoryResponse = struct {
    success: bool = true,
    name: []const u8,
};

/// DELETE /api/local-memories/:name?cwd=...
///
/// No body. On success: 200 with `{"success":true,"name":"..."}`.
/// Errors:
///   - 500  cannot resolve the local memories directory (no cwd)
///   - 400  missing `:name`, invalid name, or unexpected IO failure
///
/// Idempotent: deleting a memory that does not exist still returns
/// 200 (matches the `deleteLocalMemoryFile` helper's contract).
pub fn localMemoryDeleteHandler(
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

    if (!memories_mod.deleteLocalMemoryFile(allocator, ctx.io, dir_path, name)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to delete memory file" }),
        });
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, DeleteLocalMemoryResponse{ .name = name }, .{}),
    });
}
