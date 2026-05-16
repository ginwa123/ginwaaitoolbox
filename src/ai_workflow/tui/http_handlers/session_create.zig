const std = @import("std");
const nalarcore = @import("nalarcore");
const http_response = @import("http_response.zig");
const helpers = nalarcore.helpers;
const gserverz = nalarcore.gserverz;
const ai_workflow = nalarcore.ai_mod;

/// Helper to get nalar data directory (~/local/share/nalar/data/apps)
fn getDataAppsDir(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map) ![]u8 {
    _ = io;
    const home = environment.get("HOME") orelse {
        return error.HomeNotFound;
    };
    return std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".local",
        "share",
        "nalar",
        "data",
        "apps",
    });
}

/// Create a sandbox directory in data/apps and return the path
fn createSandbox(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map, session_id: []const u8) ![]u8 {
    const env = environment orelse return error.HomeNotFound;
    const data_apps_dir = try getDataAppsDir(allocator, io, env);
    defer allocator.free(data_apps_dir);

    // Create the data/apps directory and all parent directories if they don't exist
    try std.Io.Dir.cwd().createDirPath(io, data_apps_dir);

    // Generate a unique folder name using session_id
    const sandbox_name = try allocator.dupe(u8, session_id);
    errdefer allocator.free(sandbox_name);

    const sandbox_path = try std.fs.path.join(allocator, &[_][]const u8{
        data_apps_dir,
        sandbox_name,
    });
    errdefer allocator.free(sandbox_path);

    // Create the sandbox directory (ignore if already exists)
    std.Io.Dir.createDirAbsolute(io, sandbox_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    return sandbox_path;
}

/// Thread arguments for session creation workflow
const SessionCreateThreadArgs = struct {
    allocator: std.mem.Allocator,
    ctxTui: *ai_workflow.models.ContextIPCTui,
    session_id: []u8,
    session_name: []u8,
    queue_message: []u8,
    cwd_session: []u8,
    body_message: []u8,
    allowed_tools: []u8,
    environment: ?*const std.process.Environ.Map,
};

pub const Session = struct {
    session_id: []const u8 = "",
    session_name: []const u8 = "",
    queue_message: []const u8 = "",
    cwd_session: []const u8 = "",
    allowed_tools: []const u8 = "",
    body_message: []const u8 = "",
};

/// Create a new session
/// Request body (JSON, optional):
///   - name: session name (string, defaults to "New Session")
///   - session_id: custom session ID (string, optional, auto-generated if not provided)
///   - queue_message: initial message to add to session queue (string, optional)
///   - cwd_session: working directory (string, optional)
/// Returns JSON with created session info
pub fn session_create_handler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const di = try nalarcore.ai_mod.models.getSingleton();
    const environment = di.environment orelse return error.EnvironmentNotInitialized;
    const sqlite_db = di.db;
    const event_bus = di.event_bus;

    var session_id: []u8 = undefined;
    var session_name: []const u8 = "New Session";
    var queue_message: []const u8 = "";
    var cwd_session: []const u8 = "";
    var allowed_tools: []const u8 = "";
    var body_message: []const u8 = "";

    const parsed = std.json.parseFromSliceLeaky(Session, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.session_id.len > 0) {
        session_id = try allocator.dupe(u8, parsed.session_id);
    } else {
        session_id = try helpers.random.generateSessionId(allocator, io);
    }

    if (parsed.session_name.len > 0) {
        session_name = parsed.session_name;
    }

    if (parsed.queue_message.len > 0) {
        queue_message = parsed.queue_message;
    }

    if (parsed.cwd_session.len > 0) {
        cwd_session = parsed.cwd_session;
    }

    if (parsed.body_message.len > 0) {
        body_message = parsed.body_message;
    }

    if (parsed.allowed_tools.len > 0) {
        allowed_tools = parsed.allowed_tools;
    }

    const global_allocator = di.allocator;

    var effective_cwd: []const u8 = "";
    if (cwd_session.len > 0) {
        effective_cwd = try allocator.dupe(u8, cwd_session);
    } else {
        effective_cwd = createSandbox(allocator, io, environment, session_id) catch
            environment.get("TMPDIR") orelse "/tmp";
    }

    if (effective_cwd.len > 0) {
        const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at) VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)";
        const copy_session_name = try allocator.dupe(u8, session_name);
        const copy_cwd = try allocator.dupe(u8, effective_cwd);
        sqlite_db.exec(allocator, session_sql, &.{ session_id, copy_session_name, copy_cwd }) catch {};
    } else {
        const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status, created_at, updated_at) VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)";
        const copy_session_name = try allocator.dupe(u8, session_name);
        sqlite_db.exec(allocator, session_sql, &.{ session_id, copy_session_name }) catch {};
    }

    const dataa = ai_workflow.ai_workflow.RunParamsNew{ .parent_session_id = session_id, .session_id = session_id, .message = queue_message, .cwd = effective_cwd, .body = body_message, .allowed_tools = allowed_tools, .is_sub_agent = false };
    event_bus.emit(ai_workflow.ai_workflow.RunParamsNew, "ai_worker_flow", dataa);

    const data = try http_response.makeSessionCreateResponse(global_allocator, .{
        .id = session_id,
        .name = session_name,
        .status = "send",
    });

    return res.jsonResponse(.{ .status_code = 201, .data = data });
}
