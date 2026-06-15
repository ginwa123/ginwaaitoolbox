const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;

/// JSON request body for `PUT /api/memories/:name`.
///
/// Only the new content is editable; the filename is fixed by the URL
/// path parameter. A separate `POST /api/memories` (with a new name)
/// is the way to create an additional memory.
const UpdateMemoryBody = struct {
    content: []const u8,
};

/// Response shape for `PUT /api/memories/:name`.
const UpdateMemoryResponse = struct {
    memory: ?memories_mod.MemoryInfo = null,
    error_message: ?[]const u8 = null,
};

/// PUT /api/memories/:name
///
/// Body: `{"content":"..."}`.
///
/// On success: 200 with `{"memory":{name,title,path,size}}`.
/// Errors:
///   - 500  missing environment
///   - 400  missing `:name`, invalid name, missing body, bad JSON,
///          `writeMemoryFile` failed
///   - 404  the memory does not exist (cannot edit a non-existent one)
pub fn memoryUpdateHandler(
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

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Request body required\"}",
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateMemoryBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Invalid JSON body\"}",
        });
    };

    // Update only succeeds for existing memories. `editMemoryFile`
    // returns false on a missing file, but we want a clean 404 (not
    // 400) so the UI can distinguish "edit non-existent" from
    // "edit existing with bad input".
    if (!memories_mod.memoryExists(allocator, ctx.io, environment, name)) {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = "{\"error\":\"Memory not found\"}",
        });
    }

    if (!memories_mod.writeMemoryFile(allocator, ctx.io, environment, name, parsed.content)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Failed to write memory file\"}",
        });
    }

    // Re-list for the response payload (matches the create handler).
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
        return res.jsonResponse(.{
            .status_code = 500,
            .data = "{\"error\":\"Memory updated but not visible in directory listing\"}",
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, UpdateMemoryResponse{ .memory = m }, .{}),
    });
}
