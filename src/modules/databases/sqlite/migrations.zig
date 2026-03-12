const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const SqliteBackend = sqlite.SqliteBackend;

pub const Migration = struct {
    version: u32,
    name: []const u8,
    up: *const fn (db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void,
};

pub const Migration001CreateLLMHistory = struct {
    pub const version: u32 = 1;
    pub const name = "create_llm_history";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS llm_history (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    model TEXT NOT NULL,
            \\    response_content TEXT,
            \\    tool_calls_json TEXT,
            \\    tool_results_json TEXT,
            \\    finish_reason TEXT,
            \\    usage_json TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_session ON llm_history(session_id)", &[_][]const u8{});
    }
};

pub const Migration002AddRoleToLLMHistory = struct {
    pub const version: u32 = 2;
    pub const name = "add_role_to_llm_history";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN role TEXT DEFAULT 'assistant'", &[_][]const u8{});
    }
};

pub const Migration003AddReasoningContent = struct {
    pub const version: u32 = 3;
    pub const name = "add_reasoning_content";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN reasoning_content TEXT", &[_][]const u8{});
    }
};

pub const Migration004AddSessionDir = struct {
    pub const version: u32 = 4;
    pub const name = "add_session_dir";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN session_dir TEXT", &[_][]const u8{});
    }
};

pub const Migration005AddIsFeedToLLM = struct {
    pub const version: u32 = 5;
    pub const name = "add_is_feed_to_llm";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN is_feed_to_llm INTEGER DEFAULT 1", &[_][]const u8{});
    }
};

pub const Migration006AddAgent = struct {
    pub const version: u32 = 6;
    pub const name = "add_agent";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN agent TEXT DEFAULT 'Agent'", &[_][]const u8{});
    }
};
pub const Migration007AddSessionTracking = struct {
    pub const version: u32 = 7;
    pub const name = "add_session_tracking";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN session_name TEXT", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN loop_index INTEGER DEFAULT 0", &[_][]const u8{});
    }
};
pub const Migration008AddSessionSkills = struct {
    pub const version: u32 = 8;
    pub const name = "add_session_skills";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "CREATE TABLE IF NOT EXISTS session_skills (session_id TEXT NOT NULL, skill_name TEXT NOT NULL, content TEXT NOT NULL, loaded_at INTEGER DEFAULT (strftime('%s', 'now')), PRIMARY KEY (session_id, skill_name))", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_session_skills_session ON session_skills(session_id)", &[_][]const u8{});
    }
};

pub const Migration009RemoveCreatedColumn = struct {
    pub const version: u32 = 9;
    pub const name = "remove_created_column";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Rename old table
        try db.exec(allocator, "ALTER TABLE llm_history RENAME TO llm_history_old", &[_][]const u8{});

        // Create new table without created column and with DATETIME created_at
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS llm_history (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    model TEXT NOT NULL,
            \\    response_content TEXT,
            \\    tool_calls_json TEXT,
            \\    tool_results_json TEXT,
            \\    finish_reason TEXT,
            \\    usage_json TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    role TEXT DEFAULT 'assistant',
            \\    reasoning_content TEXT,
            \\    session_dir TEXT,
            \\    is_feed_to_llm INTEGER DEFAULT 1,
            \\    agent TEXT DEFAULT 'Agent',
            \\    session_name TEXT,
            \\    loop_index INTEGER DEFAULT 0,
            \\    temperature REAL DEFAULT 0.2,
            \\    is_thinking INTEGER DEFAULT 0
            \\)
        , &[_][]const u8{});

        // Copy data from old table, converting created to created_at
        try db.exec(allocator,
            \\INSERT INTO llm_history (id, session_id, model, response_content, tool_calls_json,
            \\    tool_results_json, finish_reason, usage_json, created_at, role,
            \\    reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index, temperature, is_thinking)
            \\SELECT id, session_id, model, response_content, tool_calls_json,
            \\    tool_results_json, finish_reason, usage_json,
            \\    datetime(CAST(created AS INTEGER), 'unixepoch'),
            \\    COALESCE(role, 'assistant'), reasoning_content, session_dir,
            \\    COALESCE(is_feed_to_llm, 1), COALESCE(agent, 'Agent'),
            \\    session_name, COALESCE(loop_index, 0), 0.2, 0
            \\FROM llm_history_old
        , &[_][]const u8{});

        // Recreate index
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_session ON llm_history(session_id)", &[_][]const u8{});

        // Drop old table
        try db.exec(allocator, "DROP TABLE llm_history_old", &[_][]const u8{});
    }
};

pub const Migration011AddTemperatureAndThinking = struct {
    pub const version: u32 = 11;
    pub const name = "add_temperature_and_thinking";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN temperature REAL DEFAULT 0.2", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN is_thinking INTEGER DEFAULT 0", &[_][]const u8{});
    }
};

pub const Migration012AddParentTracking = struct {
    pub const version: u32 = 12;
    pub const name = "add_parent_tracking";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN parent_session_id TEXT", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN parent_id TEXT", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_parent_session ON llm_history(parent_session_id)", &[_][]const u8{});
    }
};

pub const MigrationManager = struct {
    allocator: std.mem.Allocator,
    db: *SqliteBackend,
    migrations: std.ArrayList(Migration),

    pub fn init(allocator: std.mem.Allocator, db: *SqliteBackend) MigrationManager {
        return .{
            .allocator = allocator,
            .db = db,
            .migrations = .{},
        };
    }

    pub fn registerMigration(self: *MigrationManager, migration: Migration) !void {
        try self.migrations.append(self.allocator, migration);
    }

    pub fn runMigrations(self: *MigrationManager) !void {
        try self.db.exec(self.allocator, "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL)", &[_][]const u8{});

        const currentVersion = self.getCurrentVersion();
        std.debug.print("Current schema version: {d}\n", .{currentVersion});

        for (self.migrations.items) |migration| {
            if (migration.version > currentVersion) {
                std.debug.print("Running migration: {s} (version {d})\n", .{ migration.name, migration.version });
                try migration.up(self.db, self.allocator);
                const versionStr = try std.fmt.allocPrint(self.allocator, "{}", .{migration.version});
                defer self.allocator.free(versionStr);
                try self.db.exec(self.allocator, "INSERT INTO schema_migrations (version, name) VALUES (?, ?)", &.{ versionStr, migration.name });
            }
        }
    }

    fn getCurrentVersion(self: *MigrationManager) u32 {
        var rows = self.db.query(self.allocator, "SELECT MAX(version) FROM schema_migrations", &[_][]const u8{}) catch return 0;
        defer rows.deinit();
        if (rows.next() catch return 0) |row| {
            defer row.deinit(self.allocator);
            if (row.values[0].len > 0) {
                return std.fmt.parseInt(u32, row.values[0], 10) catch 0;
            }
        }
        return 0;
    }

    pub fn deinit(self: *MigrationManager) void {
        self.migrations.deinit(self.allocator);
    }
};

test {
    _ = @import("migrations_test.zig");
}
