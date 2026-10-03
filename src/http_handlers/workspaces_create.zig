const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const process = @import("helpers").process;
const getCurrentProcessId = process.getCurrentProcessId;
const sqlite = nalarcore.sqlite;
const auth_common = @import("auth_common.zig");
const workspace_default = @import("workspace_items_default.zig");

/// Process-local monotonic counter for workspace_id generation. The
/// (PID ^ ts_ms)-only generator collided when 2+ workspaces were
/// created in the same wall-clock millisecond from the same process
/// — the 2nd and later hits returned HTTP 500 "Failed to create
/// workspace" because the SQLite INSERT tripped the PRIMARY KEY
/// constraint. Observed on Mac ARM64 CI run 31863092055's
/// `test_reorder_workspaces_changes_position` (3 workspaces created
/// in <1ms collectively) and `test_list_workspaces_returns_created`.
var workspace_id_counter: std.atomic.Value(u64) = .init(0);

pub const WorkspacesCreateError = error{
    OutOfMemory,
    InvalidJson,
    MissingBody,
    MissingName,
    NameNotString,
    DatabaseError,
};

/// POST /api/workspaces
pub fn workspacesCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // The owner is derived server-side from the `nalar_session` cookie —
    // never from the request body, which a client controls (a body-supplied
    // owner id would be a spoofing vector). Auth off / no cookie resolves to
    // the shared `user_system` sentinel, so auth-off behaviour is unchanged.
    const owner = auth_common.resolveRequestUserId(allocator, sqlite_db, di.auth_enabled, req.headers) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
        });
    };
    defer allocator.free(owner);

    const result = useCase(allocator, sqlite_db, ctx.io, req.body, owner, di.environment) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidJson, error.MissingBody, error.MissingName, error.NameNotString => 400,
            error.DatabaseError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidJson => "Invalid JSON",
            error.MissingBody => "name required",
            error.MissingName => "name required",
            error.NameNotString => "name must be a string",
            error.DatabaseError => "Failed to create workspace",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 201, .data = try http_response.makeWorkspaceResponse(allocator, .{
        .id = result.id,
        .name = result.name,
        .created_at = null,
        .updated_at = null,
    }) });
}

const WorkspacesCreateResult = struct {
    id: []const u8,
    name: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    sqlite_db: *sqlite.SqliteBackend,
    io: std.Io,
    body: []const u8,
    owner: []const u8,
    /// Needed to resolve the default project's `path` ($HOME). Read from
    /// the singleton by the handler, never from the request body.
    environment: ?*const std.process.Environ.Map,
) WorkspacesCreateError!WorkspacesCreateResult {
    if (body.len == 0) return error.MissingBody;

    // Per nalar-http-handler-thin-wrapper-pattern.md: parseFromSliceLeaky
    // is the correct API for per-request arena allocators.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return error.InvalidJson;
    };
    const root = parsed.object;
    const name = root.get("name") orelse return error.MissingName;
    if (name != .string) return error.NameNotString;

    // Generate workspace ID — ts_nanos (ms) + atomic counter suffix.
    // The (PID ^ ts_ms) hash used previously collided when 2+
    // workspaces were created in the same millisecond from the same
    // process — the 2nd and later inserts returned HTTP 500
    // "Failed to create workspace" (PRIMARY KEY violation). The
    // atomic counter guarantees uniqueness within a single process;
    // PIDs distinguish processes.
    const ts = std.Io.Timestamp.now(io, .real);
    const ts_nanos: i64 = @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
    const counter = workspace_id_counter.fetchAdd(1, .seq_cst);
    const pid = getCurrentProcessId();
    const entropy: u64 = (@as(u64, @intCast(pid)) << 32) ^ (@as(u64, @intCast(ts_nanos)) << 16) ^ @as(u64, @intCast(counter));
    var random_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &random_bytes, entropy, .little);
    var hex_buf: [16]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex_buf[i * 2] = process.hex_digits[b >> 4];
        hex_buf[i * 2 + 1] = process.hex_digits[b & 0xF];
    }
    const workspace_id = try std.fmt.allocPrint(allocator, "ws_{d}_{s}", .{ ts_nanos, &hex_buf });

    createWorkspace(allocator, sqlite_db, workspace_id, name.string, owner) catch {
        return error.DatabaseError;
    };

    // Every workspace has a default project (see
    // workspace_items_default.zig). Creating it HERE means a brand-new
    // workspace shows its default in the Projects list on the very first
    // paint, instead of only after the list read fills it in.
    //
    // Deliberately NON-FATAL. A workspace with no default is fully
    // recoverable — the next `GET /api/workspaces/:ws/items` ensures it —
    // whereas failing this whole request over a home directory we could not
    // resolve would leave the user with NO workspace at all. That is
    // strictly the worse outcome.
    const defaulted = workspace_default.ensureDefaultProject(
        allocator,
        sqlite_db,
        workspace_id,
        environment,
        null,
    );
    if (defaulted) |project| {
        defer project.deinit(allocator);
    } else |err| {
        std.log.warn("workspaces_create: default project ensure failed (non-fatal, the items list will heal it): {s}", .{@errorName(err)});
    }

    return .{ .id = workspace_id, .name = name.string };
}

/// Insert a new workspace row. Position = MAX(position) + 1 so the new
/// workspace appears at the TOP of the list (workspaces_list.zig orders
/// by position DESC). The COALESCE(..., -1) makes the very first
/// workspace in an empty table get position 0 (= -1 + 1).
/// See docs/plans/2026-06-12-workspace-drag-and-drop.md.
///
/// `owner` is the server-derived owner id (see the handler). Rows created
/// from now on carry a real owner and are private to it; rows from before
/// per-user isolation keep the shared `user_system` sentinel.
fn createWorkspace(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, workspace_id: []const u8, name: []const u8, owner: []const u8) !void {
    // `workspace_members.user_id` is NOT NULL and `SqliteBackend.exec` binds
    // an empty slice as SQL NULL, so an unresolved owner has to be normalised
    // BEFORE it reaches a bind list — binding the raw "" would fail the whole
    // create with a constraint violation instead of storing a member row.
    const member = auth_common.normaliseOwnerId(owner);

    // One transaction: a workspace must never exist without the membership
    // row that makes it visible to its own creator.
    var tx = try db.begin();
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    _ = try tx.exec(allocator,
        \\INSERT INTO workspaces (id, name, position, created_at, updated_at, user_id)
        \\VALUES (?, ?,
        \\    COALESCE((SELECT MAX(position) FROM workspaces), -1) + 1,
        \\    datetime('now'), datetime('now'), ?)
    , &[_][]const u8{ workspace_id, name, member });

    // The membership row IS the visibility grant (Migration 100). `user_id`
    // on `workspaces` is kept in sync deliberately — it is the rollback path
    // and is dropped in Migration 101.
    _ = try tx.exec(
        allocator,
        "INSERT OR IGNORE INTO workspace_members (workspace_id, user_id, role) VALUES (?, ?, 'owner')",
        &[_][]const u8{ workspace_id, member },
    );

    try tx.commit();
}
