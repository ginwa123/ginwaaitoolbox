const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;

/// JSON request body for `POST /api/memories`.
///
/// Both fields are required. `name` must be a single filename (no `/`,
/// no `..`, must end in `.md`) — see `memories.isValidMemoryName`.
const CreateMemoryBody = struct {
    name: []const u8,
    content: []const u8,
};

/// Response shape for `POST /api/memories`.
///
/// On success: 201 with `{"memory":{name,title,path,size}}` (no
/// `content` field — the create-then-GET-back pattern in the UI reads
/// the body via `GET /api/memories/:name`). On error: `error_message`
/// is set and `memory` is null.
const CreateMemoryResponse = struct {
    memory: ?memories_mod.MemoryInfo = null,
    error_message: ?[]const u8 = null,
};

/// POST /api/memories
///
/// Body: `{"name":"foo.md","content":"..."}`.
///
/// On success: 201 with `{"memory":{name,title,path,size}}`.
/// Errors:
///   - 500  missing environment
///   - 400  missing/invalid name, missing/empty body, bad JSON,
///          `writeMemoryFile` failed (IO or OOM)
///   - 409  a memory with the same name already exists
pub fn memoryCreateHandler(
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

    // Body is small enough to live entirely in the request slice (the
    // parser puts it in `req.body` directly). Per-request arena owns
    // the parsed value — no explicit deinit needed.
    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Request body required\"}",
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateMemoryBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Invalid JSON body\"}",
        });
    };

    const name = parsed.name;
    if (name.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"name is required\"}",
        });
    }
    if (!memories_mod.isValidMemoryName(name)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Invalid memory name (must end in .md, no /, no ..)\"}",
        });
    }

    // 409 on duplicate. `memoryExists` is the helper-side check; it
    // also validates the name (defense in depth) so a bad name here
    // returns 400 from the `isValidMemoryName` branch above and
    // would never reach `memoryExists`.
    if (memories_mod.memoryExists(allocator, ctx.io, environment, name)) {
        return res.jsonResponse(.{
            .status_code = 409,
            .data = "{\"error\":\"Memory already exists\"}",
        });
    }

    if (!memories_mod.writeMemoryFile(allocator, ctx.io, environment, name, parsed.content)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Failed to write memory file\"}",
        });
    }

    // Re-list to derive title/path/size. `listAllMemories` is a no-op
    // on a missing dir; the freshly-created file is always in the
    // list right after `writeMemoryFile` returns true.
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
        // The file was just written but the re-list cannot see it.
        // This should be impossible unless another process deleted
        // the file between writeMemoryFile and listAllMemories.
        return res.jsonResponse(.{
            .status_code = 500,
            .data = "{\"error\":\"Memory written but not visible in directory listing\"}",
        });
    };

    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(allocator, CreateMemoryResponse{ .memory = m }, .{}),
    });
}
