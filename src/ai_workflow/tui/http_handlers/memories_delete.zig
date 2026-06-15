const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;

/// Response shape for `DELETE /api/memories/:name`.
///
/// Idempotent: `deleteMemoryFile` returns true when the file is
/// deleted OR was already missing (see `src/modules/agent/tools/memories.zig`).
/// The handler therefore always returns 200 with `success=true` on a
/// valid name.
const DeleteMemoryResponse = struct {
    success: bool = true,
    name: []const u8,
};

/// DELETE /api/memories/:name
///
/// No body. On success: 200 with `{"success":true,"name":"..."}`.
/// Errors:
///   - 500  missing environment
///   - 400  missing `:name`, invalid name, or unexpected IO failure
///
/// Idempotent: deleting a memory that does not exist still returns
/// 200 (matches the `deleteMemoryFile` helper's contract).
pub fn memoryDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const environment = di.environment orelse {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = "{\"error\":\"Missing environment\"}",
        });
    };

    const name = req.params.get("name") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Missing :name\"}",
        });
    };
    if (name.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Missing :name\"}",
        });
    }
    if (!memories_mod.isValidMemoryName(name)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Invalid memory name (must end in .md, no /, no ..)\"}",
        });
    }

    if (!memories_mod.deleteMemoryFile(allocator, ctx.io, environment, name)) {
        // `deleteMemoryFile` only returns false on validation error,
        // missing environment, or a non-`FileNotFound` IO error.
        // Validation already passed and the environment is set, so
        // 400 is the right "we could not fulfill this request" status.
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Failed to delete memory file\"}",
        });
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, DeleteMemoryResponse{ .name = name }, .{}),
    });
}
