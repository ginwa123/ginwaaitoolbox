//! Builds the `## Agent Knowledge` system-prompt section for sessions
//! bound to an Agent workspace-item.
//!
//! Reads every `agent_knowledge` row's markdown file from disk and
//! concatenates them into a section appended after `## Workspace Context`.
//! No content cap (per user "no need caps") — the full contents of every
//! file are read. A 100 MiB per-file OOM safety prevents pathological
//! inputs like `/dev/zero`.
//!
//! Behaviour:
//!   - Empty for non-agent items (item_type != 'agent') → returns ""
//!   - Empty for agents with no knowledge rows → returns ""
//!   - Missing / unreadable file paths: log + skip, continue
//!   - Files > 100 MiB: log + skip, continue
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 10)
//! Spec: docs/superpowers/specs/2026-08-15-agent-mode-design.md (D5, D6)

const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

/// 100 MiB per-file OOM safety. NOT a content budget — the user
/// explicitly removed the content cap. This is purely to prevent the
/// server from OOM-ing on a misconfigured path like `/dev/zero`.
pub const MAX_FILE_BYTES_OOM_SAFETY: usize = 100 * 1024 * 1024;

/// Resolve the workspace_item_id for a session. Returns "" when the
/// session doesn't exist (no workspace_item_tasks row).
fn resolveWorkspaceItemId(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]u8 {
    var q = db.query(allocator,
        "SELECT workspace_item_id FROM workspace_item_tasks WHERE id = ?",
        &[_][]const u8{session_id},
    ) catch return try allocator.dupe(u8, "");
    defer q.deinit();
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return try allocator.dupe(u8, "");
}

/// Read a single file's full contents. Caller owns the returned slice.
/// Returns `null` (logged + skipped by caller) on failure.
fn readFileContents(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, file_path, .{
        .mode = .read_only,
    }) catch |err| {
        std.log.warn("makeAgentKnowledge: failed to open {s}: {}", .{ file_path, err });
        return null;
    };
    defer std.Io.File.close(file, io);

    const contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        file_path,
        allocator,
        std.Io.Limit.limited(MAX_FILE_BYTES_OOM_SAFETY),
    ) catch |err| {
        std.log.warn("makeAgentKnowledge: failed to read {s}: {}", .{ file_path, err });
        return null;
    };
    return contents;
}

/// Resolve `workspace_item_id` → `agent_id` (= workspace_item_id per
/// spec D3). Returns empty slice when the workspace_item doesn't exist
/// OR isn't an agent.
fn isAgentItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) !bool {
    if (workspace_item_id.len == 0) return false;
    var q = db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{workspace_item_id},
    ) catch return false;
    defer q.deinit();
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return std.mem.eql(u8, row.values[0], "agent");
    }
    return false;
}

/// Build the `## Agent Knowledge` system-prompt section. Returns an
/// owned slice (empty for non-agent sessions). Caller frees.
pub fn makeAgentKnowledge(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return try allocator.dupe(u8, "");

    const workspace_item_id = try resolveWorkspaceItemId(allocator, db, session_id);
    defer allocator.free(workspace_item_id);

    if (!try isAgentItem(allocator, db, workspace_item_id)) {
        return try allocator.dupe(u8, "");
    }

    // Fetch the knowledge rows.
    var q = db.query(allocator,
        \\SELECT file_path, label FROM agent_knowledge
        \\WHERE agent_id = ? ORDER BY position DESC
    , &[_][]const u8{workspace_item_id}) catch return try allocator.dupe(u8, "");
    defer q.deinit();

    // Collect rows first so the query is closed before we read files.
    var rows: std.ArrayList(struct {
        file_path: []const u8,
        label: []const u8,
    }) = .empty;
    defer rows.deinit(allocator);

    while ((q.next() catch null)) |r| {
        defer r.deinit(allocator);
        try rows.append(allocator, .{
            .file_path = try allocator.dupe(u8, r.values[0]),
            .label = try allocator.dupe(u8, r.values[1]),
        });
    }

    if (rows.items.len == 0) return try allocator.dupe(u8, "");

    // Build the section.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator,
        \\n## Agent Knowledge
        \\
        \\The following markdown files are part of this Agent's knowledge. Treat
        \\them as authoritative reference for any user question that touches
        \\their topics; do not invent details that contradict them.
        \\
        \\
    );

    for (rows.items) |row| {
        defer allocator.free(row.file_path);
        defer allocator.free(row.label);

        const contents = readFileContents(io, allocator, row.file_path) catch continue;
        const owned = contents orelse continue;
        defer allocator.free(owned);

        // Section header per file.
        try out.appendSlice(allocator, "\n### ");
        if (row.label.len > 0) {
            try out.appendSlice(allocator, row.label);
        } else {
            // Basename fallback.
            const basename = std.fs.path.basename(row.file_path);
            try out.appendSlice(allocator, basename);
        }
        try out.appendSlice(allocator, "\n<file: ");
        try out.appendSlice(allocator, row.file_path);
        try out.appendSlice(allocator, ">\n\n");
        try out.appendSlice(allocator, owned);
        try out.appendSlice(allocator, "\n");
    }

    return try out.toOwnedSlice(allocator);
}