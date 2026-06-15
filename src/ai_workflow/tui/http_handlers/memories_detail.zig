const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const http_response = @import("http_response.zig");

/// Response shape for `GET /api/memories/:name`.
///
/// `memory` is non-null on success; `error_message` is non-null on
/// 4xx/5xx. Uses `std.json.Stringify.valueAlloc` (see `task_create.zig`,
/// `skill_detail.zig`) so `content` is JSON-escaped automatically — do
/// not hand-roll JSON for the body, it can break on memories that
/// contain `"` or backslash.
const MemoryDetailPayload = struct {
    name: []const u8,
    title: []const u8,
    path: []const u8,
    size: u64,
    content: []const u8,
};

const MemoryDetailResponse = struct {
    memory: ?MemoryDetailPayload = null,
    error_message: ?[]const u8 = null,
};

/// GET /api/memories/:name
///
/// On success: 200 with `{"memory":{"name","title","path","size","content"}}`.
/// Errors:
///   - 500  missing environment
///   - 400  missing `:name` path parameter
///   - 404  the file does not exist (or its name fails validation)
pub fn memoryDetailHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const environment = di.environment orelse {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing environment" }),
        });
    };

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

    // Reject path separators / `..` early. `readMemoryFile` would also
    // return null for these names, but we want a 400 (client error),
    // not a 404 (not found). `isValidMemoryName` lives in
    // `src/modules/agent/tools/memories.zig` and is `pub`.
    if (!memories_mod.isValidMemoryName(name)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid memory name" }),
        });
    }

    const content = memories_mod.readMemoryFile(allocator, ctx.io, environment, name) orelse {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Memory not found" }),
        });
    };
    defer allocator.free(content);

    // Look up title/path/size via a fresh list. The re-list is cheap
    // (a single `openDir` + iterate) and avoids re-parsing the file
    // to extract the title — `readMemoryFile` returns raw bytes.
    const list = memories_mod.listAllMemories(allocator, ctx.io, environment);
    defer memories_mod.freeMemoriesList(allocator, list);

    var found: ?memories_mod.MemoryInfo = null;
    for (list) |m| {
        if (std.mem.eql(u8, m.name, name)) {
            found = m;
            break;
        }
    }
    const m = found orelse {
        // Defensive: the file existed at read time but the re-list does
        // not see it. Treat as not-found rather than 200/empty.
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Memory not found" }),
        });
    };

    const payload = MemoryDetailPayload{
        .name = m.name,
        .title = m.title,
        .path = m.path,
        .size = m.size,
        .content = content,
    };
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, MemoryDetailResponse{ .memory = payload }, .{}),
    });
}
