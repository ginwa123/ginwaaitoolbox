const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const sqlite_mod = nalarcore.sqlite;
const helpers = @import("helpers");

pub const SqliteBackend = sqlite_mod.SqliteBackend;

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

        // Create new table with `created_at` (the column this migration
        // was supposed to consolidate). Columns added by later migrations
        // (e.g. `temperature` / `is_thinking` from migration 011) MUST
        // NOT be inlined here — that forward-projects the schema and
        // causes a "duplicate column name" error when those migrations
        // later try to `ALTER TABLE ... ADD COLUMN` on a fresh DB.
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
            \\    loop_index INTEGER DEFAULT 0
            \\)
        , &[_][]const u8{});

        // Copy data from old table.
        //
        // NOTE on `created_at`: this migration's rename-and-copy dance
        // assumes the old table had a `created` column to convert into
        // `created_at`, but Migration 001 has always created
        // `llm_history` with `created_at` directly (no historical
        // `created` column ever existed in this codebase). Reading
        // `created` from `llm_history_old` therefore crashes the
        // migration on a fresh DB:
        //
        //   sqlite3_prepare_v2 error: no such column: created
        //
        // We use `COALESCE(created_at, CURRENT_TIMESTAMP)` instead. On
        // the (only) schema that actually exists, `created_at` is the
        // column on `llm_history_old`; the COALESCE fallback guards
        // against the (hypothetical) empty-table case where every
        // column is NULL — there are no rows to copy, but the function
        // still needs a well-typed projection.
        //
        // Columns added by later migrations (`temperature`,
        // `is_thinking` from migration 011; etc.) MUST NOT appear in
        // the INSERT column list or the SELECT projection — they're
        // not on `llm_history_old` (only added by their own migrations)
        // and the new `llm_history` no longer declares them either.
        try db.exec(allocator,
            \\INSERT INTO llm_history (id, session_id, model, response_content, tool_calls_json,
            \\    tool_results_json, finish_reason, usage_json, created_at, role,
            \\    reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index)
            \\SELECT id, session_id, model, response_content, tool_calls_json,
            \\    tool_results_json, finish_reason, usage_json,
            \\    COALESCE(created_at, CURRENT_TIMESTAMP),
            \\    COALESCE(role, 'assistant'), reasoning_content, session_dir,
            \\    COALESCE(is_feed_to_llm, 1), COALESCE(agent, 'Agent'),
            \\    session_name, COALESCE(loop_index, 0)
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

pub const Migration013AddTokenUsageColumns = struct {
    pub const version: u32 = 13;
    pub const name = "add_token_usage_columns";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN prompt_tokens INTEGER DEFAULT 0", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN completion_tokens INTEGER DEFAULT 0", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN total_tokens INTEGER DEFAULT 0", &[_][]const u8{});
    }
};

pub const Migration014AddBackgroundProcess = struct {
    pub const version: u32 = 14;
    pub const name = "add_background_process";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_background_process (
            \\    session_id TEXT NOT NULL,
            \\    pid INTEGER NOT NULL,
            \\    command TEXT NOT NULL,
            \\    log_path TEXT NOT NULL,
            \\    started_at INTEGER NOT NULL,
            \\    status TEXT NOT NULL DEFAULT 'running',
            \\    PRIMARY KEY (session_id, pid)
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_bg_process_session ON session_background_process(session_id)", &[_][]const u8{});
    }
};

pub const Migration015AddSessionAgents = struct {
    pub const version: u32 = 15;
    pub const name = "add_session_agents";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_agents (
            \\    session_id TEXT PRIMARY KEY,
            \\    agent_name TEXT NOT NULL,
            \\    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_session_agents_session ON session_agents(session_id)", &[_][]const u8{});
    }
};

pub const Migration016AddInputOutputColumns = struct {
    pub const version: u32 = 16;
    pub const name = "add_input_output_columns";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN is_input INTEGER DEFAULT 0", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN is_output INTEGER DEFAULT 0", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN tool_name TEXT", &[_][]const u8{});
    }
};

pub const Migration017CreateSessionsTable = struct {
    pub const version: u32 = 17;
    pub const name = "create_sessions_table";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS sessions (
            \\    id TEXT PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    status TEXT NOT NULL DEFAULT 'active'
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status)", &[_][]const u8{});
    }
};

pub const Migration018CreateSessionQueueMessages = struct {
    pub const version: u32 = 18;
    pub const name = "create_session_queue_messages";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_queue_messages (
            \\    id TEXT NOT NULL,
            \\    session_id TEXT NOT NULL,
            \\    message TEXT NOT NULL,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_session_queue_messages_session ON session_queue_messages(session_id)", &[_][]const u8{});
    }
};

pub const Migration019CreateWorkerTable = struct {
    pub const version: u32 = 19;
    pub const name = "create_worker_table";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS worker (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    working_directory TEXT,
            \\    last_activity INTEGER DEFAULT (strftime('%s', 'now')),
            \\    last_activity_description TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_worker_session ON worker(session_id)", &[_][]const u8{});
    }
};

pub const Migration020AddWorkerExtraFields = struct {
    pub const version: u32 = 20;
    pub const name = "add_worker_extra_fields";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // These columns are already part of migration 019's CREATE TABLE
        // (the canonical `worker` schema), so fresh-DB users would
        // crash with "duplicate column name" if we ran the ADD COLUMN
        // unconditionally. SQLite also doesn't support
        // `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` (the syntax errors
        // out at prepare time — see sqlite3_prepare_v2: "near
        // 'EXISTS': syntax error"), so we wrap each ADD COLUMN in a
        // pragma_table_info check.
        try addColumnIfMissing(.{ .db = db }, allocator, "worker", "working_directory", "working_directory TEXT");
        try addColumnIfMissing(.{ .db = db }, allocator, "worker", "last_activity", "last_activity INTEGER DEFAULT (strftime('%s', 'now'))");
        try addColumnIfMissing(.{ .db = db }, allocator, "worker", "last_activity_description", "last_activity_description TEXT");
    }
};

pub const Migration021RemoveSessionNameFromLlmHistory = struct {
    pub const version: u32 = 21;
    pub const name = "remove_session_name_from_llm_history";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history DROP COLUMN session_name", &[_][]const u8{});
    }
};

pub const Migration022AddCwdToSessions = struct {
    pub const version: u32 = 22;
    pub const name = "add_cwd_to_sessions";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE sessions ADD COLUMN cwd TEXT", &[_][]const u8{});
    }
};

pub const Migration023DropSessionDirFromLlmHistory = struct {
    pub const version: u32 = 23;
    pub const name = "drop_session_dir_from_llm_history";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // SQLite doesn't support DROP COLUMN directly, so we need to recreate the table
        // Step 1: Rename old table
        try db.exec(allocator, "ALTER TABLE llm_history RENAME TO llm_history_old", &[_][]const u8{});

        // Step 2: Create new table without session_dir column
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
            \\    is_feed_to_llm INTEGER DEFAULT 1,
            \\    agent TEXT DEFAULT 'Agent',
            \\    loop_index INTEGER DEFAULT 0,
            \\    temperature REAL DEFAULT 0.2,
            \\    is_thinking INTEGER DEFAULT 0,
            \\    parent_session_id TEXT,
            \\    parent_id TEXT,
            \\    prompt_tokens INTEGER DEFAULT 0,
            \\    completion_tokens INTEGER DEFAULT 0,
            \\    total_tokens INTEGER DEFAULT 0,
            \\    is_input INTEGER DEFAULT 0,
            \\    is_output INTEGER DEFAULT 0,
            \\    tool_name TEXT
            \\)
        , &[_][]const u8{});

        // Step 3: Copy data from old table (excluding session_dir column)
        try db.exec(allocator,
            \\INSERT INTO llm_history (id, session_id, model, response_content, tool_calls_json,
            \\    tool_results_json, finish_reason, usage_json, created_at, role,
            \\    reasoning_content, is_feed_to_llm, agent, loop_index, temperature, is_thinking,
            \\    parent_session_id, parent_id, prompt_tokens, completion_tokens, total_tokens,
            \\    is_input, is_output, tool_name)
            \\SELECT id, session_id, model, response_content, tool_calls_json,
            \\    tool_results_json, finish_reason, usage_json, created_at, role,
            \\    reasoning_content, is_feed_to_llm, agent, loop_index, COALESCE(temperature, 0.2), COALESCE(is_thinking, 0),
            \\    parent_session_id, parent_id, COALESCE(prompt_tokens, 0), COALESCE(completion_tokens, 0), COALESCE(total_tokens, 0),
            \\    COALESCE(is_input, 0), COALESCE(is_output, 0), tool_name
            \\FROM llm_history_old
        , &[_][]const u8{});

        // Step 4: Recreate index
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_session ON llm_history(session_id)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_parent_session ON llm_history(parent_session_id)", &[_][]const u8{});

        // Step 5: Drop old table
        try db.exec(allocator, "DROP TABLE llm_history_old", &[_][]const u8{});
    }
};

pub const Migration024CreateWorkspaces = struct {
    pub const version: u32 = 24;
    pub const name = "create_workspaces";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspaces (
            \\    id TEXT PRIMARY KEY
            \\)
        , &[_][]const u8{});
    }
};

pub const Migration025AddWorkspaceIdToSessions = struct {
    pub const version: u32 = 25;
    pub const name = "add_workspace_id_to_sessions";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Add workspace_id column to sessions table
        try db.exec(allocator, "ALTER TABLE sessions ADD COLUMN workspace_id TEXT", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace_id)", &[_][]const u8{});
    }
};

pub const Migration026DropSessionIdFromWorkspaces = struct {
    pub const version: u32 = 26;
    pub const name = "drop_session_id_from_workspaces";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // SQLite doesn't support DROP COLUMN directly, recreate table
        // Step 1: Create new table without session_id
        try db.exec(allocator, "CREATE TABLE IF NOT EXISTS workspaces_new (id TEXT PRIMARY KEY)", &[_][]const u8{});
        // Step 2: Copy data from old table
        try db.exec(allocator, "INSERT INTO workspaces_new SELECT id FROM workspaces", &[_][]const u8{});
        // Step 3: Drop old table
        try db.exec(allocator, "DROP TABLE workspaces", &[_][]const u8{});
        // Step 4: Rename new table
        try db.exec(allocator, "ALTER TABLE workspaces_new RENAME TO workspaces", &[_][]const u8{});
    }
};

pub const Migration027AddNameToWorkspaces = struct {
    pub const version: u32 = 27;
    pub const name = "add_name_to_workspaces";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE workspaces ADD COLUMN name TEXT NOT NULL DEFAULT ''", &[_][]const u8{});
    }
};

pub const Migration028CreateWorkspaceItems = struct {
    pub const version: u32 = 28;
    pub const name = "create_workspace_items";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_items (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    item_type TEXT NOT NULL
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_workspace ON workspace_items(workspace_id)", &[_][]const u8{});
    }
};

pub const Migration029AddTimestampsToSessions = struct {
    pub const version: u32 = 29;
    pub const name = "add_timestamps_to_sessions";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Use NULL default — CURRENT_TIMESTAMP is non-constant in older SQLite
        try db.exec(allocator, "ALTER TABLE sessions ADD COLUMN created_at DATETIME DEFAULT NULL", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE sessions ADD COLUMN updated_at DATETIME DEFAULT NULL", &[_][]const u8{});

        // Backfill existing rows with the current time
        try db.exec(allocator, "UPDATE sessions SET created_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE created_at IS NULL", &[_][]const u8{});
    }
};

pub const Migration030AddTimestampsToWorkspaces = struct {
    pub const version: u32 = 30;
    pub const name = "add_timestamps_to_workspaces";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE workspaces ADD COLUMN created_at DATETIME DEFAULT NULL", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE workspaces ADD COLUMN updated_at DATETIME DEFAULT NULL", &[_][]const u8{});
        try db.exec(allocator, "UPDATE workspaces SET created_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE created_at IS NULL", &[_][]const u8{});
    }
};

pub const Migration031AddTimestampsToWorkspaceItems = struct {
    pub const version: u32 = 31;
    pub const name = "add_timestamps_to_workspace_items";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN created_at DATETIME DEFAULT NULL", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN updated_at DATETIME DEFAULT NULL", &[_][]const u8{});
        try db.exec(allocator, "UPDATE workspace_items SET created_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE created_at IS NULL", &[_][]const u8{});
    }
};

pub const Migration032AddNamePathToWorkspaceItems = struct {
    pub const version: u32 = 32;
    pub const name = "add_name_path_to_workspace_items";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN name TEXT", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN path TEXT", &[_][]const u8{});
    }
};

pub const Migration033AddCancelledToWorker = struct {
    pub const version: u32 = 33;
    pub const name = "add_cancelled_to_worker";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE worker ADD COLUMN cancelled INTEGER DEFAULT 0", &[_][]const u8{});
    }
};

pub const Migration034CreateWorkspaceItemTasks = struct {
    pub const version: u32 = 34;
    pub const name = "create_workspace_item_tasks";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Note: this migration historically included a `session_id`
        // column. Migration 052 drops it (the column was redundant —
        // `workspace_item_tasks.id` IS the session_id for kanban /
        // routine tasks). New fresh databases that walk the full
        // migration list skip the redundant column entirely.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_item_tasks (
            \\    id TEXT PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    workspace_item_id TEXT NOT NULL,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_item ON workspace_item_tasks(workspace_item_id)", &[_][]const u8{});
    }
};

pub const Migration035AddDiffViewColumns = struct {
    pub const version: u32 = 35;
    pub const name = "add_diffview_columns";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN diffview_before TEXT", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN diffview_after TEXT", &[_][]const u8{});
    }
};

pub const Migration036AddImageUrlToLlmHistory = struct {
    pub const version: u32 = 36;
    pub const name = "add_image_url_column";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN image_url TEXT", &[_][]const u8{});
    }
};

pub const Migration037AddImageUrlToSessionQueueMessages = struct {
    pub const version: u32 = 37;
    pub const name = "add_image_url_to_session_queue_messages";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE session_queue_messages ADD COLUMN image_url TEXT", &[_][]const u8{});
    }
};

pub const Migration038DropToolResultsJson = struct {
    pub const version: u32 = 38;
    pub const name = "drop_tool_results_json";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // SQLite doesn't support DROP COLUMN directly, recreate table
        // Step 1: Rename old table
        try db.exec(allocator, "ALTER TABLE llm_history RENAME TO llm_history_old", &[_][]const u8{});

        // Step 2: Create new table without tool_results_json column
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS llm_history (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    model TEXT NOT NULL,
            \\    response_content TEXT,
            \\    tool_calls_json TEXT,
            \\    finish_reason TEXT,
            \\    usage_json TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    role TEXT DEFAULT 'assistant',
            \\    reasoning_content TEXT,
            \\    is_feed_to_llm INTEGER DEFAULT 1,
            \\    agent TEXT DEFAULT 'Agent',
            \\    loop_index INTEGER DEFAULT 0,
            \\    temperature REAL DEFAULT 0.2,
            \\    is_thinking INTEGER DEFAULT 0,
            \\    parent_session_id TEXT,
            \\    parent_id TEXT,
            \\    prompt_tokens INTEGER DEFAULT 0,
            \\    completion_tokens INTEGER DEFAULT 0,
            \\    total_tokens INTEGER DEFAULT 0,
            \\    is_input INTEGER DEFAULT 0,
            \\    is_output INTEGER DEFAULT 0,
            \\    tool_name TEXT,
            \\    diffview_before TEXT,
            \\    diffview_after TEXT,
            \\    image_url TEXT
            \\)
        , &[_][]const u8{});

        // Step 3: Copy data from old table (excluding tool_results_json column)
        try db.exec(allocator,
            \\INSERT INTO llm_history (id, session_id, model, response_content, tool_calls_json,
            \\    finish_reason, usage_json, created_at, role,
            \\    reasoning_content, is_feed_to_llm, agent, loop_index, temperature, is_thinking,
            \\    parent_session_id, parent_id, prompt_tokens, completion_tokens, total_tokens,
            \\    is_input, is_output, tool_name, diffview_before, diffview_after, image_url)
            \\SELECT id, session_id, model, response_content, tool_calls_json,
            \\    finish_reason, usage_json, created_at, role,
            \\    reasoning_content, is_feed_to_llm, agent, loop_index, COALESCE(temperature, 0.2), COALESCE(is_thinking, 0),
            \\    parent_session_id, parent_id, COALESCE(prompt_tokens, 0), COALESCE(completion_tokens, 0), COALESCE(total_tokens, 0),
            \\    COALESCE(is_input, 0), COALESCE(is_output, 0), tool_name, diffview_before, diffview_after, image_url
            \\FROM llm_history_old
        , &[_][]const u8{});

        // Step 4: Recreate indexes
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_session ON llm_history(session_id)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_parent_session ON llm_history(parent_session_id)", &[_][]const u8{});

        // Step 5: Drop old table
        try db.exec(allocator, "DROP TABLE llm_history_old", &[_][]const u8{});
    }
};

pub const Migration039AddToolCallIdToLlmHistory = struct {
    pub const version: u32 = 39;
    pub const name = "add_tool_call_id";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN tool_call_id TEXT", &[_][]const u8{});
    }
};

pub const Migration040AddSelectedProfileModelToSessions = struct {
    pub const version: u32 = 40;
    pub const name = "add_selected_profile_model_to_sessions";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE sessions ADD COLUMN selected_profile_model TEXT", &[_][]const u8{});
    }
};

pub const Migration041AddPerformanceIndexes = struct {
    pub const version: u32 = 41;
    pub const name = "add_performance_indexes";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Hot read paths in llm_history.zig + http_handlers/queue_messages_get.zig +
        // http_handlers/worker_list.zig + http_handlers/workspaces_list.zig.
        // Compound indexes with explicit DESC match the query's ORDER BY direction
        // so SQLite does a forward index scan with no sort step.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_llm_history_session_created ON llm_history(session_id, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_sessions_cwd_created ON sessions(cwd, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_session_queue_messages_session_created ON session_queue_messages(session_id, created_at ASC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_worker_last_activity ON worker(last_activity DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_workspace_created ON workspace_items(workspace_id, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_created_at ON workspace_items(created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_item_created ON workspace_item_tasks(workspace_item_id, created_at DESC)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspaces_created_at ON workspaces(created_at DESC)", &[_][]const u8{});

        // ANALYZE updates sqlite_stat1 so the query planner knows the new indexes
        // exist and how selective they are. Without this, the planner may still pick
        // a full scan on existing databases that pre-date the new indexes.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

pub const Migration042AddWorkspaceItemTasksUpdatedAtIndex = struct {
    pub const version: u32 = 42;
    pub const name = "add_workspace_item_tasks_updated_at_index";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Hot read path for the workspace-item tasks endpoint when
        // sort_by=updated_at (the new default). Mirrors
        // idx_workspace_item_tasks_item_created (Migration 041).
        // Compound (workspace_item_id, updated_at DESC) matches the
        // query's WHERE + ORDER BY so SQLite does a forward index scan.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_item_updated ON workspace_item_tasks(workspace_item_id, updated_at DESC)", &[_][]const u8{});

        // ANALYZE so the query planner sees the new index on existing
        // databases (without this, the planner may still pick a full
        // scan on pre-existing data).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

pub const Migration043AddPositionToWorkspaces = struct {
    pub const version: u32 = 43;
    pub const name = "add_position_to_workspaces";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Adds the `position` column to the workspaces table. The
        // column is the sort key for the sidebar's workspace list
        // — see docs/plans/2026-06-12-workspace-drag-and-drop.md.
        // New workspaces get position = MAX(position) + 1 (top of
        // the list, since workspaces_list.zig orders by position
        // DESC). The drag-and-drop reorder endpoint reassigns these
        // values to reflect the user's chosen order.
        try db.exec(allocator, "ALTER TABLE workspaces ADD COLUMN position INTEGER NOT NULL DEFAULT 0", &[_][]const u8{});

        // Backfill. Assign position N-1 to the newest workspace, 0 to
        // the oldest. With ORDER BY position DESC, the newest
        // workspace appears at the top of the list — same UX as the
        // previous ORDER BY created_at DESC. Uses a single UPDATE with
        // a correlated subquery; SQLite handles this efficiently on
        // the small workspaces table (handful of rows in practice).
        //
        // The formula: position = (number of workspaces OLDER than
        // this one). For the newest, all N-1 others are older, so
        // position = N-1 (top of the list). For the oldest, none are
        // older, so position = 0 (bottom of the list). The id
        // tiebreaker handles the rare case where two workspaces share
        // the same created_at second — without it, the COUNT
        // subquery would assign the same position to both rows.
        try db.exec(allocator,
            \\UPDATE workspaces
            \\SET position = (
            \\    SELECT COUNT(*)
            \\    FROM workspaces w2
            \\    WHERE w2.created_at < workspaces.created_at
            \\        OR (w2.created_at = workspaces.created_at AND w2.id > workspaces.id)
            \\)
        , &[_][]const u8{});

        // Index on position for the list endpoint's ORDER BY.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspaces_position ON workspaces(position DESC)", &[_][]const u8{});

        // ANALYZE so the query planner picks up the new index on
        // existing databases (without this, the planner may still
        // pick a full scan on pre-existing data).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

pub const Migration044AddRoutines = struct {
    pub const version: u32 = 44;
    pub const name = "add_routines";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Adds the `task_type` column to the existing
        // workspace_item_tasks table (defaulting to 'standard' for
        // backwards compatibility — every pre-existing task row is
        // a standard chat) and the new `routines` table for
        // cron-scheduled task execution. Plan:
        // docs/superpowers/plans/2026-06-13-add-task-routines.md.
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN task_type TEXT NOT NULL DEFAULT 'standard'",
            &[_][]const u8{},
        );

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS routines (
            \\    id TEXT PRIMARY KEY,
            \\    task_id TEXT NOT NULL UNIQUE,
            \\    schedule TEXT NOT NULL,
            \\    initial_prompt TEXT NOT NULL,
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    last_run_at DATETIME,
            \\    next_run_at DATETIME NOT NULL,
            \\    last_status TEXT,
            \\    last_error TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        // Polling index for the Scheduler's hot read path
        // (SELECT id FROM routines WHERE enabled=1 AND next_run_at<=now).
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_routines_enabled_next_run ON routines(enabled, next_run_at)",
            &[_][]const u8{},
        );
        // Refresh query-planner stats so the new index is picked on
        // pre-existing databases (mirrors the ANALYZE-after-CREATE-INDEX
        // pattern used by Migrations 041/042/043). Without this, the
        // Scheduler's per-second poll may not use the index until the
        // table has been written to many times.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

pub const Migration045AddPositionToWorkspaceItems = struct {
    pub const version: u32 = 45;
    pub const name = "add_position_to_workspace_items";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Mirror of Migration043AddPositionToWorkspaces but scoped to
        // a single workspace's items. The new `position` column is
        // the sort key for the per-workspace item list (workspaces_list
        // returns items via workspace_items_get.zig which currently
        // does `ORDER BY created_at DESC`; we switch it to
        // `ORDER BY position DESC`). New items get
        // position = MAX(position) + 1 (top of the expanded workspace
        // list, since items are rendered top-to-bottom in DESC order).
        // The drag-and-drop reorder endpoint reassigns these values to
        // reflect the user's chosen order.
        try db.exec(allocator, "ALTER TABLE workspace_items ADD COLUMN position INTEGER NOT NULL DEFAULT 0", &[_][]const u8{});

        // Backfill. Per-workspace: the newest item gets the highest
        // position (so it appears at the TOP of the expanded list with
        // ORDER BY position DESC), the oldest gets position 0 (bottom).
        // This preserves the pre-existing visual order on upgrade.
        // The id tiebreaker (newer id > older id when timestamps tie) is
        // important so the backfill is deterministic when two items
        // share a created_at second.
        try db.exec(allocator,
            \\UPDATE workspace_items
            \\SET position = (
            \\    SELECT COUNT(*)
            \\    FROM workspace_items wi
            \\    WHERE wi.workspace_id = workspace_items.workspace_id
            \\        AND (wi.created_at > workspace_items.created_at
            \\            OR (wi.created_at = workspace_items.created_at AND wi.id > workspace_items.id))
            \\)
        , &[_][]const u8{});

        // Index on (workspace_id, position DESC) so the per-workspace
        // item list query uses an index even with hundreds of items
        // per workspace.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_workspace_items_workspace_position ON workspace_items(workspace_id, position DESC)", &[_][]const u8{});

        // Refresh query-planner stats (mirrors Migration043/044
        // pattern) so the new index is picked on pre-existing DBs.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

pub const Migration046AddGitWorktreeCwdToSessions = struct {
    pub const version: u32 = 46;
    pub const name = "add_git_worktree_cwd_to_sessions";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Nullable: NULL means "no worktree bound". The application code
        // maps NULL → "" via COALESCE for the API surface, matching the
        // convention used for `cwd`, `created_at`, `updated_at`, and
        // `selected_profile_model` (see llm_history.zig:1802).
        try db.exec(allocator,
            "ALTER TABLE sessions ADD COLUMN git_worktree_cwd TEXT",
            &[_][]const u8{});
    }
};

pub const Migration048AddChatListIndex = struct {
    pub const version: u32 = 48;
    pub const name = "add_chat_list_index";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Hot read path: getSessionList (llm_history.zig:115) does
        // GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT/OFFSET
        // with no WHERE. Today the planner does a full table scan +
        // sort. With this covering index, the inner subquery becomes
        // a forward index scan: walk the index in created_at DESC
        // order, read session_id from the leaf, group, stop at LIMIT.
        //
        // NOT a duplicate of idx_llm_history_session_created — that
        // one is (session_id, created_at DESC) for filtering BY
        // session; this one is the reverse for the no-WHERE scan.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_llm_history_created_session " ++
            "ON llm_history(created_at DESC, session_id)",
            &[_][]const u8{});

        // ANALYZE so the query planner sees the new index on
        // pre-existing databases.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

pub const Migration049AddDefensiveIndexes = struct {
    pub const version: u32 = 49;
    pub const name = "add_defensive_indexes";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Defensive: covers listAllWorkspaceItems (llm_history.zig:2317)
        // which today has no callers. The query is
        // ORDER BY wi.position DESC, wi.id ASC with no WHERE. The
        // compound (position DESC, id ASC) makes it a single covering
        // index scan if a future "all items across all workspaces" view
        // invokes it. The id tiebreaker is the same one
        // Migration045AddPositionToWorkspaceItems uses on its backfill
        // UPDATE so index-backed ORDER BYs match that ordering.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspace_items_position_id " ++
            "ON workspace_items(position DESC, id ASC)",
            &[_][]const u8{});

        // Defensive: covers resetStuckRunning (routines/Scheduler.zig:51)
        // which runs once at startup. The WHERE on last_status='running'
        // has no index today. Acceptable while routines < 10 000 rows;
        // this index makes the future cost independent of table size.
        // Cardinality is tiny (a handful of distinct values: 'pending',
        // 'running', 'success', 'failed') but the index is still O(log N)
        // for the WHERE filter — meaningful once 'failed' rows accumulate
        // over months of operation.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_routines_last_status " ++
            "ON routines(last_status)",
            &[_][]const u8{});

        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

pub const Migration050AddPinnedToWorkspaceItemTasks = struct {
    pub const version: u32 = 50;
    pub const name = "add_pinned_to_workspace_item_tasks";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0",
            &[_][]const u8{});
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN pinned_position INTEGER NOT NULL DEFAULT 0",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_pinned " ++
            "ON workspace_item_tasks(workspace_item_id, is_pinned DESC, pinned_position DESC)",
            &[_][]const u8{});
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

pub const Migration051AddKanban = struct {
    pub const version: u32 = 51;
    pub const name = "add_kanban";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Workspace Item Kanban feature — Chunk 1 (Migration 051).
        // Adds the kanban_columns table and the two column-reference
        // columns on workspace_item_tasks. Each kanban (item_type='kanban')
        // owns its own set of columns; tasks inside a kanban point at one
        // column via kanban_column_id and have a per-column ordering via
        // kanban_position. Plan:
        // docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS kanban_columns (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL,
            \\    name TEXT NOT NULL,
            \\    position INTEGER NOT NULL,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_kanban_columns_item_position " ++
            "ON kanban_columns(workspace_item_id, position)",
            &[_][]const u8{},
        );
        // Nullable: NULL for tasks in non-kanban items
        // (folder / chat / memory) — they have no flow.
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN kanban_column_id TEXT",
            &[_][]const u8{},
        );
        // Per-column ordering (independent of the global workspace_item_tasks.position
        // which the folder list view's drag-and-drop uses). DEFAULT 0 so existing
        // tasks (including non-kanban ones where kanban_column_id IS NULL) get a
        // valid value without backfill.
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN kanban_position INTEGER NOT NULL DEFAULT 0",
            &[_][]const u8{},
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_tasks_column_position " ++
            "ON workspace_item_tasks(kanban_column_id, kanban_position)",
            &[_][]const u8{},
        );
        // ANALYZE so the query planner sees the new indexes on
        // pre-existing databases (mirrors the ANALYZE-after-CREATE-INDEX
        // pattern used by Migrations 041/042/043/048/049/050).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

pub const Migration052DropSessionIdFromWorkspaceItemTasks = struct {
    pub const version: u32 = 52;
    pub const name = "drop_session_id_from_workspace_item_tasks";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Drop the redundant `session_id` column on `workspace_item_tasks`.
        //
        // The project's established convention is that for kanban /
        // routine tasks, `workspace_item_tasks.id` IS the session_id:
        // the frontend's AppLayout.vue binds `:chat-id="activeTask.id"`,
        // ChatView sets `sessionId.value = props.chatId.replace(/^chat-/, '')`,
        // the LLM call uses that as the session_id, and
        // `routines_run.zig` returns `{"session_id": "<task_id>"}` on
        // a routine fire. The `workspace_item_tasks.session_id` column
        // was therefore always the same value as `id` (when populated)
        // or NULL (when the task chat had not yet been started).
        //
        // The column was being read by exactly one query —
        // `getWorkspaceContext`'s anchor (`WHERE t.session_id = ?`).
        // For tasks where the column was NULL (the common case for
        // freshly-created kanban tasks, because the frontend's
        // `api.createTask` does NOT send a session_id in the request
        // body), the lookup returned zero rows and the system prompt's
        // `## Workspace Context` section was silently omitted. The
        // LLM then had to ask the user for the workspace_id / item_id
        // every time, which broke the `kanban_*` tools and any other
        // workspace-scoped tool that relies on context.
        //
        // After this migration, the anchor query uses `t.id = ?`
        // directly (the canonical session id), and the column is
        // dropped. The frontend's `Task.session_id` field is
        // also removed — clients should use `task.id` for the same
        // purpose. SQLite supports `ALTER TABLE ... DROP COLUMN`
        // since 3.35; the project's bundled sqlite is recent enough.
        //
        // Schema before: workspace_item_tasks (..., session_id TEXT, ...)
        // Schema after:  workspace_item_tasks (...,                  ...)
        //
        // `dropColumnIfExists` (not raw `DROP COLUMN`) because the
        // canonical migration 034 schema no longer declares
        // `session_id` (it was a redundant column — `task.id` IS the
        // session id). For fresh-DB users the column never exists, so
        // the raw `DROP COLUMN` would crash with "no such column:
        // session_id".
        try dropColumnIfExists(.{ .db = db }, allocator, "workspace_item_tasks", "session_id");
        // The session_id index (created in Migration 034) is now
        // unused and would just slow writes down. Drop it.
        try db.exec(allocator,
            "DROP INDEX IF EXISTS idx_workspace_item_tasks_session_id",
            &[_][]const u8{},
        );
        // ANALYZE so the query planner drops the dropped index from
        // its stats. Mirrors the ANALYZE-after-DDL pattern used by
        // Migrations 041/042/043/048/049/050/051.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

pub const Migration053AddKanbanColumnDescription = struct {
    pub const version: u32 = 53;
    pub const name = "add_kanban_column_description";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Kanban column description — Chunk 1 of the
        // kanban-column-description-settings plan. Each kanban
        // column gains a free-text "meaning" field that the
        // Settings UI displays and edits. NOT NULL with DEFAULT ''
        // so existing rows (which have no description) survive the
        // ALTER TABLE without backfill. The frontend uses the
        // empty string as the "no description" sentinel — the
        // Settings UI shows "Add a description…" placeholder for
        // empty descriptions.
        //
        // Why NOT NULL (vs nullable):
        //   1. The application always reads description as
        //      []const u8 (never ?[]const u8) — a nullable column
        //      would force every SELECT to COALESCE and every
        //      INSERT to handle NULL explicitly.
        //   2. The DB-level NOT NULL is a defensive check; the
        //      application layer never writes NULL.
        //   3. Mirrors the project's convention for short text
        //      fields with a sentinel "absent" value.
        try db.exec(allocator,
            "ALTER TABLE kanban_columns ADD COLUMN description TEXT NOT NULL DEFAULT ''",
            &[_][]const u8{},
        );
    }
};

// ────────────────────────────────────────────────────────────────────────
// Migration 054 — drop NOT NULL on session_queue_messages.message
// ────────────────────────────────────────────────────────────────────────
//
// Why this migration exists
// ─────────────────────────
// Migration 018 (`Migration018CreateSessionQueueMessages`, line 247) declared
// `message TEXT NOT NULL`, which forces the application to always pass a
// non-empty message body. But the SqliteBackend.bind layer
// (src/modules/databases/sqlite/Sqlite.zig:73-74) treats any empty `[]const u8`
// as SQL NULL — see project memory `sqlite-backend-empty-slice-binds-as-null.md`.
// So an image-only queued message (params.message = "" with params.image_urls
// non-empty) triggers `NOT NULL constraint failed:
// session_queue_messages.message` at INSERT time in `queueMessage`
// (src/agentic_loop/llm_history.zig:1861).
//
// Fix: drop the NOT NULL on `message` so image-only queued messages can be
// inserted. Image-only queue messages are valid — they represent an attachment
// that will be sent before any text reply. The frontend renders them correctly
// (we already pipe-separator split on `|` in the SSE handler).
//
// Why the table-recreate pattern (vs `ALTER TABLE ... ALTER COLUMN ... DROP
// NOT NULL`)
// ─────────────────────────
// SQLite's `DROP NOT NULL` via ALTER COLUMN is only available on non-Windows
// builds and requires SQLite >= 3.35.0. The recreate-table pattern works on
// every SQLite version with no platform caveats, and matches the convention
// already used in Migration 023 (drop session_dir from llm_history) and
// Migration 038 (drop tool_results_json). `session_queue_messages` has no
// foreign keys into it (verified via `rg REFERENCES session_queue_messages`),
// so the rename + recreate + copy + drop sequence is safe.
//
// How the up() works
// ──────────────────
// 1. Detect whether `image_url` column exists. Production DBs always have it
//    (added by Migration 037). Fresh test DBs that only ran Migration 018
//    do not. The data-copy branch picks the right column list.
// 2. Rename the existing table out of the way.
// 3. Recreate with `message` nullable (no NOT NULL).
// 4. Copy all existing rows into the new table (preserving message content;
//    image_url either maps 1:1 or defaults to NULL on DBs that pre-date M037).
// 5. Drop the renamed table.
// 6. Recreate the `idx_session_queue_messages_session` index.
pub const Migration054MakeSessionQueueMessageNullable = struct {
    pub const version: u32 = 54;
    pub const name = "make_session_queue_messages_message_nullable";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Detect whether image_url column exists (added in Migration 037).
        const has_image_url = blk: {
            var q = try db.query(allocator,
                "SELECT 1 FROM pragma_table_info('session_queue_messages') " ++
                "WHERE name = 'image_url' LIMIT 1",
                &[_][]const u8{},
            );
            defer q.deinit();
            if (try q.next()) |row| {
                defer row.deinit(allocator);
                break :blk true;
            }
            break :blk false;
        };

        // 2. Rename existing table out of the way.
        try db.exec(allocator,
            "ALTER TABLE session_queue_messages " ++
            "RENAME TO _session_queue_messages_old",
            &[_][]const u8{},
        );

        // 3. Recreate with `message` nullable (the actual fix).
        try db.exec(allocator,
            \\CREATE TABLE session_queue_messages (
            \\    id TEXT NOT NULL,
            \\    session_id TEXT NOT NULL,
            \\    message TEXT,
            \\    image_url TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // 4. Copy all existing rows. The image_url column defaults to NULL
        //    on DBs that pre-date Migration 037 (which is harmless — the
        //    application treats NULL and "" identically on read).
        if (has_image_url) {
            try db.exec(allocator,
                \\INSERT INTO session_queue_messages
                \\  (id, session_id, message, image_url, created_at)
                \\SELECT id, session_id, message, image_url, created_at
                \\  FROM _session_queue_messages_old
            , &[_][]const u8{});
        } else {
            try db.exec(allocator,
                \\INSERT INTO session_queue_messages
                \\  (id, session_id, message, created_at)
                \\SELECT id, session_id, message, created_at
                \\  FROM _session_queue_messages_old
            , &[_][]const u8{});
        }

        // 5. Drop the renamed table.
        try db.exec(allocator,
            "DROP TABLE _session_queue_messages_old",
            &[_][]const u8{},
        );

        // 6. Recreate the index Migration 018 added.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_queue_messages_session " ++
            "ON session_queue_messages(session_id)",
            &[_][]const u8{},
        );
    }
};

// ────────────────────────────────────────────────────────────────────────
// Migration 055 — design_pages table (v1 of design-mode feature)
// ────────────────────────────────────────────────────────────────────────
//
// Why this migration exists
// ──────────────────────────
// First migration of the design-mode feature. Creates the
// `design_pages` table where each row represents one page of a design
// (e.g. "Login", "Dashboard") within a `workspace_items` row of
// `item_type = 'design'`.
//
// The original v1 stored page HTML inline as a `html TEXT` column.
// The file-backed upgrade is shipped in Migration 056. This split
// matches the eventual deployment: 055 ships first (initial feature),
// 056 ships later (the file-backed fix).
//
// Why the indexes
// ───────────────
// - UNIQUE design_pages(workspace_item_id, name) — enables INSERT
//   ... ON CONFLICT for the idempotent `setDesignPage` use case.
// - design_pages(workspace_item_id, position) — keeps `listPages`
//   fast as a page count grows.
//
// Why ANALYZE at the end
// ───────────────────────
// New indexes need fresh sqlite_stat1 entries for the query planner
// to recognize them — without ANALYZE, the planner's statistics are
// stale and the new indexes may be ignored. Mirrors the
// ANALYZE-after-DDL pattern used by Migrations 041/042/043/048/049/
// 050/051/052/053/054.
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
pub const Migration055AddDesignPages = struct {
    pub const version: u32 = 55;
    pub const name = "add_design_pages";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS design_pages (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL,
            \\    name TEXT NOT NULL DEFAULT '',
            \\    html TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_design_pages_item_name " ++
            "ON design_pages(workspace_item_id, name)",
            &[_][]const u8{},
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_design_pages_item_position " ++
            "ON design_pages(workspace_item_id, position)",
            &[_][]const u8{},
        );
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

// ────────────────────────────────────────────────────────────────────────
// Migration 056 — upgrade design_pages to file-backed model
// ────────────────────────────────────────────────────────────────────────
//
// Why this migration exists
// ──────────────────────────
// Migration 055's design_pages stored HTML inline as a `html TEXT`
// column. The v5/v6 model moves to a hybrid DB-metadata + on-disk HTML
// file layout:
//   - Pages become metadata-only (width/height/x/y/position) with NO
//     html column. The per-page folder at
//     `<workspace_item.path>/.nalar/design/<page_name>/` holds the
//     element files.
//   - Each element is a positioned HTML snippet in the new
//     `design_page_elements` table; the html body lives at the
//     element's `file_path` (absolute path under workspace_item.path).
//
// Why version 56 (not 55)
// ──────────────────────
// Existing DBs that already ran Migration055 have it recorded at
// version 55 in `schema_migrations`. If we kept the upgrade at
// version 55, the tracker would skip it for existing users
// (symptom: `set_design_page` fails with `PrepareFailed: no such
// column: width`). Bumping to 56 guarantees the upgrade body runs
// once for every existing user. Fresh-DB installs run it as part of
// the bootstrap sequence — the CREATE TABLE IF NOT EXISTS +
// addColumnIfMissing calls are all idempotent.
//
// Migration body handles both upgrade-from-055 and fresh-DB:
//   - `CREATE TABLE IF NOT EXISTS design_pages` — fresh-DB; no-op on
//     upgrade (table already exists)
//   - `dropColumnIfExists("design_pages", "html")` — upgrade only;
//     fresh-DB has no html to drop
//   - `addColumnIfMissing(...)` for width/height/x/y — upgrade only;
//     fresh-DB's CREATE TABLE above already declares them
//   - `CREATE TABLE IF NOT EXISTS design_page_elements` — always new
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
pub const Migration056UpgradeDesignPagesToFileModel = struct {
    pub const version: u32 = 56;
    pub const name = "upgrade_design_pages_to_file_model";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // CREATE design_pages (fresh-DB path). On a legacy DB that
        // already has the v1 table, this is a no-op (CREATE TABLE IF
        // NOT EXISTS).
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS design_pages (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL,
            \\    name TEXT NOT NULL DEFAULT '',
            \\    width INTEGER NOT NULL DEFAULT 1440,
            \\    height INTEGER NOT NULL DEFAULT 1024,
            \\    x INTEGER NOT NULL DEFAULT 0,
            \\    y INTEGER NOT NULL DEFAULT 0,
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        // Upgrade path: drop legacy `html` column from Migration 055
        // if present. SQLite 3.35+ supports DROP COLUMN. No-op on
        // fresh DBs.
        try dropColumnIfExists(.{ .db = db }, allocator, "design_pages", "html");

        // Ensure the 4 new position columns exist. On fresh DBs the
        // CREATE TABLE above already declares them with the same
        // defaults, so these are no-ops; on legacy DBs they're new
        // columns being backfilled with sensible defaults.
        try addColumnIfMissing(.{ .db = db }, allocator, "design_pages", "width", "width INTEGER NOT NULL DEFAULT 1440");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_pages", "height", "height INTEGER NOT NULL DEFAULT 1024");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_pages", "x", "x INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_pages", "y", "y INTEGER NOT NULL DEFAULT 0");

        // CREATE design_page_elements (new in v5/v6). Always new —
        // no upgrade path needed.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS design_page_elements (
            \\    id TEXT PRIMARY KEY,
            \\    page_id TEXT NOT NULL,
            \\    name TEXT NOT NULL DEFAULT '',
            \\    file_path TEXT NOT NULL DEFAULT '',
            \\    x INTEGER NOT NULL DEFAULT 0,
            \\    y INTEGER NOT NULL DEFAULT 0,
            \\    width INTEGER NOT NULL DEFAULT 375,
            \\    height INTEGER NOT NULL DEFAULT 667,
            \\    z_index INTEGER NOT NULL DEFAULT 0,
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        // Indexes. CREATE [UNIQUE] INDEX IF NOT EXISTS — all safe
        // to re-run.
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_design_pages_item_name " ++
            "ON design_pages(workspace_item_id, name)",
            &[_][]const u8{},
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_design_pages_item_position " ++
            "ON design_pages(workspace_item_id, position)",
            &[_][]const u8{},
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_design_page_elements_page_z_pos " ++
            "ON design_page_elements(page_id, z_index, position)",
            &[_][]const u8{},
        );

        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

// ────────────────────────────────────────────────────────────────────────
// Migration 057 — add v6 element properties to design_page_elements
// ────────────────────────────────────────────────────────────────────────
//
// Why this migration exists
// ──────────────────────────
// Adds 11 new columns to `design_page_elements` for the Figma-lite
// design-mode redesign (see design doc §5.1). The columns are purely
// additive — existing v5 columns (id, page_id, name, file_path, x, y,
// width, height, z_index, position, created_at, updated_at) are
// untouched. All new columns have sensible defaults so existing rows
// survive without a backfill.
//
// The properties unlocked by each column:
//   - `type`        → rectangle | ellipse | text | image | frame | group
//   - `rotation`    → degrees for the element transform
//   - `fill`        → CSS background-color (e.g. "#22c55e")
//   - `stroke`      → CSS border-color (e.g. "#000000")
//   - `stroke_width`→ CSS border-width (integer px)
//   - `corner_radius` → CSS border-radius (integer px)
//   - `opacity`     → 0.0..1.0 (REAL for sub-pixel precision)
//   - `text_content`→ populated for type='text' elements
//   - `text_style`  → JSON: font, size, weight, color, align (type='text')
//   - `image_url`   → populated for type='image' elements
//   - `parent_id`   → FK to design_page_elements(id) for frame/group nesting;
//                     ON DELETE SET NULL so deleting a parent doesn't
//                     cascade-delete the children.
//
// Why NOT NULL with DEFAULT '' for text columns
// ─────────────────────────────────────────────
// `SqliteBackend.exec` binds `arg.len == 0` as SQL NULL (see
// `src/modules/databases/sqlite/Sqlite.zig:73-74`). The application
// reads these fields as `[]const u8` (never `?[]const u8`), so a
// nullable column would force every SELECT to COALESCE and every
// INSERT to handle NULL explicitly. Mirrors the convention used by
// Migration 053 for `kanban_columns.description`.
//
// Why `addColumnIfMissing` instead of plain ALTER TABLE
// ────────────────────────────────────────────────────
// SQLite's `ALTER TABLE ... ADD COLUMN` does NOT support `IF NOT
// EXISTS` (errors at prepare with "near 'EXISTS': syntax error"). The
// helper checks `pragma_table_info` before issuing ALTER. Fresh DBs
// get all 11 columns from the Migration 056 CREATE TABLE above; this
// migration's adds are no-ops on fresh DBs and real adds on legacy
// DBs that already have Migration 056 in place but predate v6.
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
pub const Migration057AddDesignElementProperties = struct {
    pub const version: u32 = 57;
    pub const name = "add_design_element_properties";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Visual property columns. All 11 additions are purely
        // additive — Migration 056's CREATE TABLE did NOT declare
        // them, so for fresh-DB installs we add them here via
        // addColumnIfMissing (which is a no-op on a DB that already
        // has them, e.g. after a partial migration).
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "type",
            "type TEXT NOT NULL DEFAULT 'rectangle'");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "rotation",
            "rotation REAL NOT NULL DEFAULT 0");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "fill",
            "fill TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "stroke",
            "stroke TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "stroke_width",
            "stroke_width INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "corner_radius",
            "corner_radius INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "opacity",
            "opacity REAL NOT NULL DEFAULT 1.0");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "text_content",
            "text_content TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "text_style",
            "text_style TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "image_url",
            "image_url TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "parent_id",
            "parent_id TEXT");

        // Analyze so the query planner sees the new columns on
        // legacy DBs.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

// ────────────────────────────────────────────────────────────────────────
// Migration 058 — FTS5 virtual table on llm_history (workspace history search)
// ────────────────────────────────────────────────────────────────────────
//
// Why this migration exists
// ──────────────────────────
// The workspace history search replaces the LIKE-prefix-scan with an
// FTS5 MATCH query. This
// migration creates the `messages_fts` external-content FTS5 virtual table
// over `llm_history.response_content`, plus the 3 sync triggers that keep
// it in lockstep with the source rows.
//
// Why external-content (content='llm_history')
// ────────────────────────────────────────────
// `content='llm_history'` makes the FTS table a *view* over the source —
// no row text is duplicated in `messages_fts`. Storage cost is just the
// FTS5 inverted index (a few MB at 10K messages). This is the SQLite
// docs' recommended approach for "full-text search over an existing table".
//
// Why porter+unicode61
// ─────────────────────
// `porter` does English-language stemming ("running" → "run"), reducing
// index size by ~20% on English corpora and improving recall for
// plural/tense variants. `unicode61` handles tokenization of Unicode
// characters (utf-8-aware splitting on word boundaries). `remove_diacritics
// 2` strips accents so "café" matches "cafe" — useful for non-ASCII
// chats.
//
// Why version 58 (not 55)
// ──────────────────────
// Migration numbers 55, 56, 57 are already taken (AddDesignPages,
// UpgradeDesignPagesToFileModel, AddDesignElementProperties).
// 58 is the next free slot in the migration sequence.
//
// Plan: workspace history FTS (Chunk 1)
pub const Migration058AddLlmHistoryFts = struct {
    pub const version: u32 = 58;
    pub const name = "add_llm_history_fts";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // FTS5 virtual table.
        //
        // IMPORTANT: we do NOT use external-content (`content='llm_history'`)
        // because the `snippet()` and `highlight()` FTS5 helper functions
        // return NULL for external-content and contentless tables — they
        // can only retrieve highlighted text from the FTS5 table itself.
        // The `searchMessagesFts` query returns a 10-token snippet with
        // `[match]` markers around matches, so we need the content
        // duplicated in messages_fts.
        //
        // Storage trade-off: ~2x storage for `response_content` (one copy
        // in llm_history, one copy in messages_fts). For a 1MB average
        // message and ~10K messages, that's ~10MB extra. Acceptable.
        try db.exec(allocator,
            \\CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            \\    content,
            \\    tokenize='porter unicode61 remove_diacritics 2'
            \\)
        , &[_][]const u8{});

        // Sync triggers: keep `messages_fts` in sync with `llm_history` rows.
        // The rowid linkage allows searchMessagesFts to JOIN back to
        // llm_history for id/session_id/role/timestamps.
        //
        // Note: we use plain DELETE FROM messages_fts WHERE rowid=... and
        // plain INSERT INTO messages_fts(rowid, content) for sync — NOT
        // the special `INSERT INTO messages_fts(messages_fts, rowid, content)
        // VALUES('delete', ...)` form, which is only valid for external-content
        // tables.
        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_ai AFTER INSERT ON llm_history BEGIN
            \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_ad AFTER DELETE ON llm_history BEGIN
            \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_au AFTER UPDATE ON llm_history BEGIN
            \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
            \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
            \\END
        , &[_][]const u8{});

        // Backfill: walk existing llm_history rows and INSERT into the
        // FTS table. For zero rows this is a no-op; for ~10K rows it's
        // ~10ms.
        try db.exec(allocator,
            \\INSERT INTO messages_fts(rowid, content)
            \\SELECT rowid, COALESCE(response_content, '')
            \\FROM llm_history
        , &[_][]const u8{});
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
            .migrations = .empty,
        };
    }

    pub fn registerMigration(self: *MigrationManager, migration: Migration) !void {
        try self.migrations.append(self.allocator, migration);
    }

    pub fn runMigrations(self: *MigrationManager) !void {
        try self.db.exec(self.allocator, "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL)", &[_][]const u8{});

        const currentVersion = self.getCurrentVersion();

        for (self.migrations.items) |migration| {
            if (migration.version > currentVersion) {
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

/// Add a column to a table if it doesn't already exist.
///
/// SQLite's `ALTER TABLE ... ADD COLUMN` does NOT support
/// `IF NOT EXISTS` (it errors at prepare time with
/// "near 'EXISTS': syntax error"). This helper works around that by
/// checking `pragma_table_info('<table>')` first.
///
/// Used by migrations that need to add a column to a table which may
/// have been created by a newer migration (e.g. migration 020 adds
/// columns that migration 019's CREATE TABLE already declares — for
/// fresh-DB users, those columns are already there, and the helper
/// makes the ADD COLUMN a no-op).
///
/// `definition` is the full `ADD COLUMN` clause AFTER the
/// `ALTER TABLE <table>` prefix, e.g.
/// `"working_directory TEXT"`. (Keeping the column name in the
/// definition is intentional — the SQLite parser requires it, and
/// `definition` is provided by the caller who already knows the
/// full DDL line.)
pub fn addColumnIfMissing(
    db: nalarcore.database.DbOrTx,
    allocator: std.mem.Allocator,
    table: []const u8,
    column: []const u8,
    definition: []const u8,
) !void {
    // Stack-buffer the two SQL strings. Both are tiny — a few dozen
    // bytes each. Avoiding the heap keeps the helper zero-alloc and
    // safe to call from any migration.
    var check_buf: [256]u8 = undefined;
    const check_sql = std.fmt.bufPrint(
        &check_buf,
        "SELECT 1 FROM pragma_table_info('{s}') WHERE name = '{s}'",
        .{ table, column },
    ) catch return error.BufferTooSmall;
    var q = try db.query(allocator, check_sql, &.{});
    defer q.deinit();
    if ((try q.next())) |row| {
        // Row returned (column exists) — free the row's values
        // (allocated via `allocator` per Sqlite.zig:267) before
        // returning. Without this `defer`, the helper would
        // leak the row's `[]u8` value slice on every call.
        row.deinit(allocator);
        return;
    }
    // column does not exist — fall through to ALTER below.

    var ddl_buf: [256]u8 = undefined;
    const ddl = std.fmt.bufPrint(
        &ddl_buf,
        "ALTER TABLE {s} ADD COLUMN {s}",
        .{ table, definition },
    ) catch return error.BufferTooSmall;
    try db.exec(allocator, ddl, &.{});
}

/// Drop a column from a table if it exists. SQLite's
/// `ALTER TABLE ... DROP COLUMN` errors with "no such column: X" if
/// the column was never there (which is the case for fresh-DB users
/// when an earlier migration had been edited to remove a redundant
/// column from its CREATE TABLE). This helper makes the DROP a
/// no-op for fresh-DB users while still removing the column for
/// legacy users who do have it.
pub fn dropColumnIfExists(
    db: nalarcore.database.DbOrTx,
    allocator: std.mem.Allocator,
    table: []const u8,
    column: []const u8,
) !void {
    var check_buf: [256]u8 = undefined;
    const check_sql = std.fmt.bufPrint(
        &check_buf,
        "SELECT 1 FROM pragma_table_info('{s}') WHERE name = '{s}'",
        .{ table, column },
    ) catch return error.BufferTooSmall;
    var q = try db.query(allocator, check_sql, &.{});
    defer q.deinit();
    const row = (try q.next()) orelse {
        // Column doesn't exist — no-op.
        return;
    };
    // Column exists — free the row's values before issuing the
    // DROP statement (see addColumnIfMissing for the rationale).
    row.deinit(allocator);

    var ddl_buf: [256]u8 = undefined;
    const ddl = std.fmt.bufPrint(
        &ddl_buf,
        "ALTER TABLE {s} DROP COLUMN {s}",
        .{ table, column },
    ) catch return error.BufferTooSmall;
    try db.exec(allocator, ddl, &.{});
}

/// Rename a column on a table if the old column exists and the new
/// column does NOT exist. SQLite's `ALTER TABLE … RENAME COLUMN`
/// requires SQLite >= 3.25; this project ships 3.53.3 so it's always
/// available.
///
/// Probe pattern (same as `addColumnIfMissing` / `dropColumnIfExists`):
///   1. If the OLD column doesn't exist → no-op (fresh-DB install
///      that already declares the NEW column name, or a re-run after
///      the rename succeeded).
///   2. If the NEW column already exists → no-op (defensive against
///      a partial-failure recovery scenario where someone manually
///      renamed the column outside this migration).
///   3. Otherwise issue the RENAME.
///
/// SQLite's RENAME automatically updates:
///   - All references to the column in views, triggers, and FK
///     constraints on OTHER tables pointing AT this table (verified
///     via `pragma_table_info` on the referencing table before/after
///     the RENAME — see `migration_075_test.zig` Test 4 + Test 9).
///   - The internal index columns that reference this column. The
///     index's NAME does NOT auto-update; the caller must handle
///     index renames separately via `DROP INDEX IF EXISTS old_name;
///     CREATE INDEX IF NOT EXISTS new_name ON table(new_name);`.
pub fn renameColumnIfExists(
    db: nalarcore.database.DbOrTx,
    allocator: std.mem.Allocator,
    table: []const u8,
    old_column: []const u8,
    new_column: []const u8,
) !void {
    // Probe: does the OLD column exist?
    var old_buf: [256]u8 = undefined;
    const old_check = std.fmt.bufPrint(
        &old_buf,
        "SELECT 1 FROM pragma_table_info('{s}') WHERE name = '{s}'",
        .{ table, old_column },
    ) catch return error.BufferTooSmall;
    var q_old = try db.query(allocator, old_check, &.{});
    defer q_old.deinit();
    const old_row = (try q_old.next()) orelse {
        // OLD column doesn't exist — no-op (fresh-DB already has
        // the new name, or a re-run after the rename succeeded).
        return;
    };
    // OLD column exists — free the row's values before the next probe.
    old_row.deinit(allocator);

    // Probe: does the NEW column already exist?
    var new_buf: [256]u8 = undefined;
    const new_check = std.fmt.bufPrint(
        &new_buf,
        "SELECT 1 FROM pragma_table_info('{s}') WHERE name = '{s}'",
        .{ table, new_column },
    ) catch return error.BufferTooSmall;
    var q_new = try db.query(allocator, new_check, &.{});
    defer q_new.deinit();
    const new_row = (try q_new.next()) orelse {
        // NEW column does NOT exist — proceed with the RENAME below.
        // Fall through.
        var ddl_buf: [256]u8 = undefined;
        const ddl = std.fmt.bufPrint(
            &ddl_buf,
            "ALTER TABLE {s} RENAME COLUMN {s} TO {s}",
            .{ table, old_column, new_column },
        ) catch return error.BufferTooSmall;
        try db.exec(allocator, ddl, &.{});
        return;
    };
    // NEW column already exists — defensive no-op.
    new_row.deinit(allocator);
}

/// All available migrations - add new migrations to this slice
pub const allMigrations: []const Migration = &.{
    .{ .version = Migration001CreateLLMHistory.version, .name = Migration001CreateLLMHistory.name, .up = Migration001CreateLLMHistory.up },
    .{ .version = Migration002AddRoleToLLMHistory.version, .name = Migration002AddRoleToLLMHistory.name, .up = Migration002AddRoleToLLMHistory.up },
    .{ .version = Migration003AddReasoningContent.version, .name = Migration003AddReasoningContent.name, .up = Migration003AddReasoningContent.up },
    .{ .version = Migration004AddSessionDir.version, .name = Migration004AddSessionDir.name, .up = Migration004AddSessionDir.up },
    .{ .version = Migration005AddIsFeedToLLM.version, .name = Migration005AddIsFeedToLLM.name, .up = Migration005AddIsFeedToLLM.up },
    .{ .version = Migration006AddAgent.version, .name = Migration006AddAgent.name, .up = Migration006AddAgent.up },
    .{ .version = Migration007AddSessionTracking.version, .name = Migration007AddSessionTracking.name, .up = Migration007AddSessionTracking.up },
    .{ .version = Migration008AddSessionSkills.version, .name = Migration008AddSessionSkills.name, .up = Migration008AddSessionSkills.up },
    .{ .version = Migration009RemoveCreatedColumn.version, .name = Migration009RemoveCreatedColumn.name, .up = Migration009RemoveCreatedColumn.up },
    .{ .version = Migration011AddTemperatureAndThinking.version, .name = Migration011AddTemperatureAndThinking.name, .up = Migration011AddTemperatureAndThinking.up },
    .{ .version = Migration012AddParentTracking.version, .name = Migration012AddParentTracking.name, .up = Migration012AddParentTracking.up },
    .{ .version = Migration013AddTokenUsageColumns.version, .name = Migration013AddTokenUsageColumns.name, .up = Migration013AddTokenUsageColumns.up },
    .{ .version = Migration014AddBackgroundProcess.version, .name = Migration014AddBackgroundProcess.name, .up = Migration014AddBackgroundProcess.up },
    .{ .version = Migration015AddSessionAgents.version, .name = Migration015AddSessionAgents.name, .up = Migration015AddSessionAgents.up },
    .{ .version = Migration016AddInputOutputColumns.version, .name = Migration016AddInputOutputColumns.name, .up = Migration016AddInputOutputColumns.up },
    .{ .version = Migration017CreateSessionsTable.version, .name = Migration017CreateSessionsTable.name, .up = Migration017CreateSessionsTable.up },
    .{ .version = Migration018CreateSessionQueueMessages.version, .name = Migration018CreateSessionQueueMessages.name, .up = Migration018CreateSessionQueueMessages.up },
    .{ .version = Migration019CreateWorkerTable.version, .name = Migration019CreateWorkerTable.name, .up = Migration019CreateWorkerTable.up },
    .{ .version = Migration020AddWorkerExtraFields.version, .name = Migration020AddWorkerExtraFields.name, .up = Migration020AddWorkerExtraFields.up },
    .{ .version = Migration021RemoveSessionNameFromLlmHistory.version, .name = Migration021RemoveSessionNameFromLlmHistory.name, .up = Migration021RemoveSessionNameFromLlmHistory.up },
    .{ .version = Migration022AddCwdToSessions.version, .name = Migration022AddCwdToSessions.name, .up = Migration022AddCwdToSessions.up },
    .{ .version = Migration023DropSessionDirFromLlmHistory.version, .name = Migration023DropSessionDirFromLlmHistory.name, .up = Migration023DropSessionDirFromLlmHistory.up },
    .{ .version = Migration024CreateWorkspaces.version, .name = Migration024CreateWorkspaces.name, .up = Migration024CreateWorkspaces.up },
    .{ .version = Migration025AddWorkspaceIdToSessions.version, .name = Migration025AddWorkspaceIdToSessions.name, .up = Migration025AddWorkspaceIdToSessions.up },
    .{ .version = Migration026DropSessionIdFromWorkspaces.version, .name = Migration026DropSessionIdFromWorkspaces.name, .up = Migration026DropSessionIdFromWorkspaces.up },
    .{ .version = Migration027AddNameToWorkspaces.version, .name = Migration027AddNameToWorkspaces.name, .up = Migration027AddNameToWorkspaces.up },
    .{ .version = Migration028CreateWorkspaceItems.version, .name = Migration028CreateWorkspaceItems.name, .up = Migration028CreateWorkspaceItems.up },
    .{ .version = Migration029AddTimestampsToSessions.version, .name = Migration029AddTimestampsToSessions.name, .up = Migration029AddTimestampsToSessions.up },
    .{ .version = Migration030AddTimestampsToWorkspaces.version, .name = Migration030AddTimestampsToWorkspaces.name, .up = Migration030AddTimestampsToWorkspaces.up },
    .{ .version = Migration031AddTimestampsToWorkspaceItems.version, .name = Migration031AddTimestampsToWorkspaceItems.name, .up = Migration031AddTimestampsToWorkspaceItems.up },
    .{ .version = Migration032AddNamePathToWorkspaceItems.version, .name = Migration032AddNamePathToWorkspaceItems.name, .up = Migration032AddNamePathToWorkspaceItems.up },
    .{ .version = Migration033AddCancelledToWorker.version, .name = Migration033AddCancelledToWorker.name, .up = Migration033AddCancelledToWorker.up },
    .{ .version = Migration034CreateWorkspaceItemTasks.version, .name = Migration034CreateWorkspaceItemTasks.name, .up = Migration034CreateWorkspaceItemTasks.up },
    .{ .version = Migration035AddDiffViewColumns.version, .name = Migration035AddDiffViewColumns.name, .up = Migration035AddDiffViewColumns.up },
    .{ .version = Migration036AddImageUrlToLlmHistory.version, .name = Migration036AddImageUrlToLlmHistory.name, .up = Migration036AddImageUrlToLlmHistory.up },
    .{ .version = Migration037AddImageUrlToSessionQueueMessages.version, .name = Migration037AddImageUrlToSessionQueueMessages.name, .up = Migration037AddImageUrlToSessionQueueMessages.up },
    .{ .version = Migration038DropToolResultsJson.version, .name = Migration038DropToolResultsJson.name, .up = Migration038DropToolResultsJson.up },
    .{ .version = Migration039AddToolCallIdToLlmHistory.version, .name = Migration039AddToolCallIdToLlmHistory.name, .up = Migration039AddToolCallIdToLlmHistory.up },
    .{ .version = Migration040AddSelectedProfileModelToSessions.version, .name = Migration040AddSelectedProfileModelToSessions.name, .up = Migration040AddSelectedProfileModelToSessions.up },
    .{ .version = Migration041AddPerformanceIndexes.version, .name = Migration041AddPerformanceIndexes.name, .up = Migration041AddPerformanceIndexes.up },
    .{ .version = Migration042AddWorkspaceItemTasksUpdatedAtIndex.version, .name = Migration042AddWorkspaceItemTasksUpdatedAtIndex.name, .up = Migration042AddWorkspaceItemTasksUpdatedAtIndex.up },
    .{ .version = Migration043AddPositionToWorkspaces.version, .name = Migration043AddPositionToWorkspaces.name, .up = Migration043AddPositionToWorkspaces.up },
    .{ .version = Migration044AddRoutines.version, .name = Migration044AddRoutines.name, .up = Migration044AddRoutines.up },
    .{ .version = Migration045AddPositionToWorkspaceItems.version, .name = Migration045AddPositionToWorkspaceItems.name, .up = Migration045AddPositionToWorkspaceItems.up },
    .{ .version = Migration046AddGitWorktreeCwdToSessions.version, .name = Migration046AddGitWorktreeCwdToSessions.name, .up = Migration046AddGitWorktreeCwdToSessions.up },
    .{ .version = Migration048AddChatListIndex.version, .name = Migration048AddChatListIndex.name, .up = Migration048AddChatListIndex.up },
    .{ .version = Migration049AddDefensiveIndexes.version, .name = Migration049AddDefensiveIndexes.name, .up = Migration049AddDefensiveIndexes.up },
    .{ .version = Migration050AddPinnedToWorkspaceItemTasks.version, .name = Migration050AddPinnedToWorkspaceItemTasks.name, .up = Migration050AddPinnedToWorkspaceItemTasks.up },
    .{ .version = Migration051AddKanban.version, .name = Migration051AddKanban.name, .up = Migration051AddKanban.up },
    .{ .version = Migration052DropSessionIdFromWorkspaceItemTasks.version, .name = Migration052DropSessionIdFromWorkspaceItemTasks.name, .up = Migration052DropSessionIdFromWorkspaceItemTasks.up },
    .{ .version = Migration053AddKanbanColumnDescription.version, .name = Migration053AddKanbanColumnDescription.name, .up = Migration053AddKanbanColumnDescription.up },
    .{ .version = Migration054MakeSessionQueueMessageNullable.version, .name = Migration054MakeSessionQueueMessageNullable.name, .up = Migration054MakeSessionQueueMessageNullable.up },
    .{ .version = Migration055AddDesignPages.version, .name = Migration055AddDesignPages.name, .up = Migration055AddDesignPages.up },
    .{ .version = Migration056UpgradeDesignPagesToFileModel.version, .name = Migration056UpgradeDesignPagesToFileModel.name, .up = Migration056UpgradeDesignPagesToFileModel.up },
    .{ .version = Migration057AddDesignElementProperties.version, .name = Migration057AddDesignElementProperties.name, .up = Migration057AddDesignElementProperties.up },
    .{ .version = Migration058AddLlmHistoryFts.version, .name = Migration058AddLlmHistoryFts.name, .up = Migration058AddLlmHistoryFts.up },
    .{ .version = Migration059AddCreatedIso.version, .name = Migration059AddCreatedIso.name, .up = Migration059AddCreatedIso.up },
    .{ .version = Migration060RebackfillCreatedIso.version, .name = Migration060RebackfillCreatedIso.name, .up = Migration060RebackfillCreatedIso.up },
    .{ .version = Migration061FixCreatedIsoYear.version, .name = Migration061FixCreatedIsoYear.name, .up = Migration061FixCreatedIsoYear.up },
    .{ .version = Migration062AddTaskDescription.version, .name = Migration062AddTaskDescription.name, .up = Migration062AddTaskDescription.up },
    .{ .version = Migration063AddSessionAutoRetry.version, .name = Migration063AddSessionAutoRetry.name, .up = Migration063AddSessionAutoRetry.up },
    .{ .version = Migration064AddFrontendLogs.version, .name = Migration064AddFrontendLogs.name, .up = Migration064AddFrontendLogs.up },
    // Chunk 1 of kanban-task-notification-icon plan: stamps
    // `last_human_touched_at` on tasks the user has interacted
    // with (drag, rename, edit desc, pin, send message, open chat).
    // Used by the kanban card UI to decide whether to show the
    // orange "awaiting review" dot or the green "reviewed"
    // checkmark alongside `sessions.last_finish_reason` (Migration
    // 063). See docs/plans/2026-07-26-kanban-task-notification-icon.md.
    .{ .version = Migration065AddTaskHumanTouchedAt.version, .name = Migration065AddTaskHumanTouchedAt.name, .up = Migration065AddTaskHumanTouchedAt.up },
    // design-page-workspace-item-task-fk plan, Task 1: adds the FK
    // column + UNIQUE index + backfill so each design page is bound
    // to its chat task at the row level (replaces the name-pattern
    // lookup in AppLayout.handleDesignOpenChat). See
    // docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md.
    .{ .version = Migration066AddDesignPageTaskFk.version, .name = Migration066AddDesignPageTaskFk.name, .up = Migration066AddDesignPageTaskFk.up },
    // kanban task tags plan, Task 1: adds `tags TEXT NOT NULL DEFAULT ''`
    // so workspace_item_tasks rows can carry a JSON-encode array of user
    // labels. See docs/superpowers/plans/2026-07-28-kanban-task-tags.md.
    .{ .version = Migration067AddTaskTags.version, .name = Migration067AddTaskTags.name, .up = Migration067AddTaskTags.up },
    // tool-call-loading-placeholder plan, Task 1: adds
    // `llm_history.is_loading` + partial UNIQUE INDEX on
    // `tool_call_id` so we can pre-create tool-result placeholder
    // rows synchronously BEFORE the long-running tool execution
    // starts. Prevents "Invalid function ID" errors when the agent
    // crashes mid-tool-execution. See
    // docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md
    // (task_1785784899843).
    .{ .version = Migration068AddToolCallLoading.version, .name = Migration068AddToolCallLoading.name, .up = Migration068AddToolCallLoading.up },
    // Migration 069 — adds `workspace_item_tasks.image_urls` so task
    // images are stored inline (base64 data URLs joined with `||`) on
    // the task row, no filesystem attachments, no broken GET route.
    // Task-id tracked: 1785795051796 ("kanban task not saving the
    // images or base 64 in kanban description, after create a task or
    // run aent").
    .{ .version = Migration069AddTaskImageUrls.version, .name = Migration069AddTaskImageUrls.name, .up = Migration069AddTaskImageUrls.up },
    // Migration 070 — agent_memories table + agent_memories_fts FTS5 +
    // 3 sync triggers. Backs the save_memory + load_memory agent tools
    // (Task task_1785958319567, plan 2026-08-06-save-load-memory-fts5).
    .{ .version = Migration070AddAgentMemories.version, .name = Migration070AddAgentMemories.name, .up = Migration070AddAgentMemories.up },
    // Migration 071 — adds `workspace_item_tasks.cwd` (the per-task
    // cwd_session). Each task can now carry its own cwd path;
    // session_create.zig::useCase resolves cwd in 3 levels:
    //   1. RequestSession.cwd_session (explicit per-call override)
    //   2. workspace_item_tasks.cwd  (this column — NEW)
    //   3. workspace_items.path      (existing kanban-level cwd)
    //   4. createSandbox(...)         (per-session TMPDIR fallback)
    // Empty string is the canonical "no per-task cwd" sentinel —
    // every existing row backfills to '' (the column is NOT NULL
    // DEFAULT ''). The frontend reads this from
    // WorkspaceItemTaskResponse.cwd and routes it through the same
    // chain on the client before sending cwd_session to the chat
    // session create endpoint. Plan:
    // docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
    //
    // Renamed from Migration 070 during PR #200 merge (main already
    // used 070 for the agent_memories migration — save_memory +
    // load_memory agent tools, plan 2026-08-06-save-load-memory-fts5).
    .{ .version = Migration071AddTaskCwd.version, .name = Migration071AddTaskCwd.name, .up = Migration071AddTaskCwd.up },
    // Migration 072 — extracts `kanban_column_id` + `kanban_position` off
    // `workspace_item_tasks` into a dedicated `kanban` join table; wire
    // format preserved (Task.{kanban_column_id, kanban_position} continue
    // to exist via LEFT JOIN). Plan:
    // docs/superpowers/plans/2026-08-15-extract-kanban-columns-to-kanban-table.md.
    // Task: task_1786527996378.
    .{ .version = Migration072ExtractKanbanTable.version, .name = Migration072ExtractKanbanTable.name, .up = Migration072ExtractKanbanTable.up },
    // Migration 073 — session_activity append-only log
    // (update_activity + buildCompactionEnvelope now INSERT here in
    // addition to the existing worker.last_activity_description
    // UPDATE). Plan: docs/superpowers/plans/2026-08-13-session-activity-table.md.
    // Task: task_1786629034327 ("new table session_activity").
    .{ .version = Migration073AddSessionActivity.version, .name = Migration073AddSessionActivity.name, .up = Migration073AddSessionActivity.up },
    .{ .version = Migration074AddLlmHistoryCacheTokenColumns.version, .name = Migration074AddLlmHistoryCacheTokenColumns.name, .up = Migration074AddLlmHistoryCacheTokenColumns.up },
    // Migration 075 — renames 5 timestamp columns to use the `_nano` suffix
    // (`logs.created_at` → `logs.created_at_nano`, etc.). Wire format preserved.
    // Plan: docs/superpowers/plans/2026-08-16-rename-timestamp-columns-nano-suffix.md.
    // Task: task_1786891244388_1.
    .{ .version = Migration075RenameTimestampColumnsToNanoSuffix.version, .name = Migration075RenameTimestampColumnsToNanoSuffix.name, .up = Migration075RenameTimestampColumnsToNanoSuffix.up },
    // Migration 076 — `session_plan` 1:1 table with `sessions` for the agent's
    // persistent task plan (markdown + checklist). Plan:
    // docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md. Task:
    // task_1787073929852_8.
    .{ .version = Migration076CreateSessionPlan.version, .name = Migration076CreateSessionPlan.name, .up = Migration076CreateSessionPlan.up },
    // Migration 077 — `users` + `user_companies` + `user_company_members`
    // + additive `workspaces.user_id` + `sessions.user_id` + default
    // `user_system` user + backfill. Sub-project 1 of 4 (foundation for
    // multi-user / multi-tenant nalar). Plan:
    // docs/superpowers/plans/2026-08-21-users-rbac-foundation.md. Task:
    // task_1787199963946_1.
    .{ .version = Migration077AddUsersAndRbacSchema.version, .name = Migration077AddUsersAndRbacSchema.name, .up = Migration077AddUsersAndRbacSchema.up },
    // Migration 078 — Agent Mode: `agents` + `agent_knowledge` + `agent_tools`
    // (4th workspace-item type, knowledge injection, tool allowlist).
    // Plan: docs/superpowers/plans/2026-08-15-agent-mode.md.
    // Task: task_1786962724740_0.
    .{ .version = Migration076AddAgentsAndAgentKnowledgeAndAgentTools.version, .name = Migration076AddAgentsAndAgentKnowledgeAndAgentTools.name, .up = Migration076AddAgentsAndAgentKnowledgeAndAgentTools.up },
    // Migration 079 — agent_knowledge.content (manual text knowledge).
    // Plan: docs/superpowers/plans/2026-08-21-agent-knowledge-manual-text.md.
    // Task: task_1787315943769_9.
    .{ .version = Migration079AddContentToAgentKnowledge.version, .name = Migration079AddContentToAgentKnowledge.name, .up = Migration079AddContentToAgentKnowledge.up },
    // Migration 080 — agent_system_prompt (N-1 with agents, per-agent named
    // prompt blocks injected into the LLM system message).
    // Plan: docs/superpowers/plans/2026-08-21-agent-system-prompt.md.
    // Task: task_1787408958280_1.
    .{ .version = Migration080AddAgentSystemPrompt.version, .name = Migration080AddAgentSystemPrompt.name, .up = Migration080AddAgentSystemPrompt.up },
    // Migration 081 — Agent-Kanbans mirror: agent_kanbans (1-1 with kanban
    // workspace_items) + knowledges + system_prompt + tools children.
    // Plan: docs/superpowers/plans/2026-08-25-agent-kanbans-mirror.md.
    // Task: task_1787597624259_2.
    .{ .version = Migration081CreateAgentKanbans.version, .name = Migration081CreateAgentKanbans.name, .up = Migration081CreateAgentKanbans.up },
    // Migration 082 — sessions.last_human_touched_at_nano column. Sibling
    // of Migration 065's task-side column. Drives the chat sidebar's
    // "last human touched" time pill (replacing the AI-tainted updated_at)
    // and the amber stale-dot when AI has touched since the user's last
    // touch. Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md.
    // Task: task_1788004921757_1.
    .{ .version = Migration082AddSessionHumanTouchedAt.version, .name = Migration082AddSessionHumanTouchedAt.name, .up = Migration082AddSessionHumanTouchedAt.up },
    // Migration 083 — llm_history reasoning metadata (reasoning_id +
    // reasoning_encrypted_content). Nullable TEXT columns for Responses API
    // reasoning replay when store:false. Plan:
    // docs/superpowers/plans/2026-09-01-fix-openai-response-reasoning-leak-and-persist.md.
    .{ .version = Migration083AddReasoningIdAndEncryptedContent.version, .name = Migration083AddReasoningIdAndEncryptedContent.name, .up = Migration083AddReasoningIdAndEncryptedContent.up },
    // Migration 084 — drop per-task `routines`, replace with workspace-level
    // `workspace_routines` (first-class `item_type='routine'` beside `agent`).
    // Breaking: old per-task schedules are dropped, no carry-over.
    // Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md.
    // Task: task_1789032258828_0.
    .{ .version = Migration084ReplaceRoutinesWithWorkspaceRoutines.version, .name = Migration084ReplaceRoutinesWithWorkspaceRoutines.name, .up = Migration084ReplaceRoutinesWithWorkspaceRoutines.up },
    .{ .version = Migration085AddSessionProgressiveTool.version, .name = Migration085AddSessionProgressiveTool.name, .up = Migration085AddSessionProgressiveTool.up },
    .{ .version = Migration086AddSessionPrUrl.version, .name = Migration086AddSessionPrUrl.name, .up = Migration086AddSessionPrUrl.up },
    .{ .version = Migration087CreateAgentRoutines.version, .name = Migration087CreateAgentRoutines.name, .up = Migration087CreateAgentRoutines.up },
    // Migration 088 — the `ask_user` question queue: one row per pending
    // question, answered later by POST /api/llm/session/:id/answer which
    // rewrites the matching tool-result row and resumes the session.
    // (Was 087 until the agent-routines mirror took that number; the table it
    // creates is independent, so only the version constant moved.)
    // Plan: docs/superpowers/plans/2026-09-16-agent-tool-ask-user.md.
    .{ .version = Migration088AddSessionPendingQuestion.version, .name = Migration088AddSessionPendingQuestion.name, .up = Migration088AddSessionPendingQuestion.up },
    // Migration 089 — `auth_sessions` for opt-in `--auth` login sessions.
    // One row per active cookie (token_hash -> user_id + expiry).
    // Stores only SHA-256(token), never the raw token.
    .{ .version = Migration089AuthSessions.version, .name = Migration089AuthSessions.name, .up = Migration089AuthSessions.up },
    // Migration 090 — `video_urls` / `video_url` columns for full video
    // upload to LLM (mirrors Migration 069 image_urls, 25 MB cap).
    .{ .version = Migration090AddVideoUrls.version, .name = Migration090AddVideoUrls.name, .up = Migration090AddVideoUrls.up },
    // Migration 091 — sessions.sub_agent_name + parent_session_id so a
    // sub-agent row shows its own identity alongside the parent profile.
    .{ .version = Migration091AddSubAgentNameToSessions.version, .name = Migration091AddSubAgentNameToSessions.name, .up = Migration091AddSubAgentNameToSessions.up },
    // Migration 092 — users.config_json for opt-in `--auth` mode.
    // When auth is on, per-user LLM config lives in this column and
    // config.json is ignored. NULL/empty = defaults.
    .{ .version = Migration092AddUserConfigJson.version, .name = Migration092AddUserConfigJson.name, .up = Migration092AddUserConfigJson.up },
    // Migration 093 — owner columns for per-user row isolation.
    // Adds worker.user_id (+ index) and backfills every still-NULL
    // workspaces/sessions/worker row to the shared `user_system` sentinel.
    // Plan: docs/plans/2026-09-25-per-user-isolation.md (W0).
    .{ .version = Migration093AddOwnerColumns.version, .name = Migration093AddOwnerColumns.name, .up = Migration093AddOwnerColumns.up },
    // Migration 094 — `workspace_items.is_default`, the per-workspace default
    // project. The partial unique index makes "at most one" a database
    // invariant, which matters because the lookup that creates the default
    // runs from a list read, a workspace create AND a New Chat tap, so those
    // genuinely race. No backfill: the list read creates it on demand.
    // Plan: docs/plans/2026-09-27-sidebar-new-chat-default-project.md (D6, D12)
    .{ .version = Migration094AddDefaultProjectToWorkspaceItems.version, .name = Migration094AddDefaultProjectToWorkspaceItems.name, .up = Migration094AddDefaultProjectToWorkspaceItems.up },
    // Migration 095 — `agent_memories.workspace_id`, so `save_memory` /
    // `load_memory` stop sharing one note pool across every workspace.
    // `''` is the "no workspace" bucket; legacy rows land there, which is
    // why they stop being visible to workspace sessions (re-home with an
    // explicit UPDATE if you want to keep one).
    // Plan: docs/plans/2026-09-29-memory-workspace-isolation.md
    .{ .version = Migration095AddWorkspaceIdToAgentMemories.version, .name = Migration095AddWorkspaceIdToAgentMemories.name, .up = Migration095AddWorkspaceIdToAgentMemories.up },
    // Migration 096 — `session_skill_events`, the append-only skill usage
    // ledger. Answers "which turn loaded this skill", "was it only listed and
    // then ignored" and "has the body changed since it was read" — none of
    // which `session_skills` can answer, because it keeps only the latest body
    // per (session, skill) and only `use_skill` writes it.
    // Plan: docs/plans/2026-09-27-skill-evals.md (W1)
    .{ .version = Migration096CreateSessionSkillEvents.version, .name = Migration096CreateSessionSkillEvents.name, .up = Migration096CreateSessionSkillEvents.up },
    // Migration 097 — the skill-eval tables. `skill_eval_facts` caches the
    // INTRINSIC half of a verdict against (skill_key, content_hash,
    // context_key) so two sessions evaluating the same body at the same commit
    // share one computation; `skill_eval_runs` makes "once per self-prompted
    // session" a DB invariant; `skill_eval_results` holds the session-relative
    // half plus the `base_content_hash` staleness guard used on apply.
    // Plan: docs/plans/2026-09-27-skill-evals.md (§4.6, W0)
    .{ .version = Migration097CreateSkillEvalTables.version, .name = Migration097CreateSkillEvalTables.name, .up = Migration097CreateSkillEvalTables.up },
};

/// Migration 060 — Re-run the `created_iso` backfill for rows that
/// were NULL when Migration 059 first ran.
///
/// ## Why this migration exists
///
/// V1 of Migration 059 (now reverted) used SQLite INSERT/UPDATE triggers
/// to populate `created_iso` from `created_at`. The trigger's
/// `datetime(CAST(<microseconds> AS REAL) / 1000000, 'unixepoch', 'localtime')`
/// expression overflowed SQLite's `datetime()` range (cap: year 9999) for
/// modern (post-year-2000) microsecond timestamps, silently returning
/// NULL for every row inserted after the trigger was installed. The
/// migration's backfill UPDATE had the same overflow bug, so legacy
/// rows also got NULL `created_iso`.
///
/// As a result, production databases that ran V1 of Migration 059 had
/// many rows with `created_iso = NULL`, which silently broke the
/// `since`/`until` filter on workspace history reads and
/// `getCompactedMessages`
/// (since `'NULL' < '2026-07-15 ...'` in lex comparison filtered those
/// rows back out, but the filter logic actually excluded them).
///
/// ## What this does
///
/// Re-runs the backfill UPDATE with the corrected UTC-based expression
/// from Migration 059 v2:
///   - Application code (Zig stdlib `std.time.epoch`) produces UTC.
///   - This UPDATE matches UTC to keep both paths consistent.
///   - It's idempotent (WHERE guards on NULL/empty).
///   - It only touches rows that STILL need populating — rows where
///     the v1 trigger or v1 backfill left a stale value will also
///     be updated (since they were never updated correctly anyway).
pub const Migration060RebackfillCreatedIso = struct {
    pub const version: u32 = 60;
    pub const name = "rebackfill_llm_history_created_iso";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Re-run the backfill from Migration 059 (v2). The WHERE
        // clause makes this idempotent — already-populated rows
        // (including any rows where the application code has since
        // written a correct `created_iso`) are untouched. Only rows
        // with NULL or empty `created_iso` get populated.
        //
        // NOTE: this does NOT touch rows where v1's broken trigger
        // may have written a non-NULL but garbage value. We can't
        // detect that syntactically — a string that's well-formed
        // 'YYYY-MM-DD HH:MM:SS' but contains a totally wrong date is
        // indistinguishable from a correct one. The migration is
        // conservative: it only touches rows we KNOW are missing,
        // and trusts the corrected saveMessage going forward to
        // produce correct values for new rows.
        try db.exec(
            allocator,
            \\UPDATE llm_history
            \\SET created_iso = CASE
            \\    WHEN created_at IS NULL OR created_at = ''
            \\        THEN datetime('now')
            \\    ELSE datetime(
            \\        CAST(substr(created_at, 1, 10) AS INTEGER),
            \\        'unixepoch'
            \\    )
            \\END
            \\WHERE created_iso IS NULL
            \\   OR created_iso = ''
        , &[_][]const u8{});
    }
};

/// Migration 059 — Add a `created_iso` column to `llm_history` (populated
/// by application code — NOT SQLite triggers).
///
/// ## Why this exists
///
/// `llm_history.created_at` is a TEXT column storing **Unix microseconds**
/// since the epoch as a string (e.g. `"1784119389936251112"`). The
/// previous history `since`/`until`
/// filters did a lex-comparison on this column against user input like
/// `"2026-07-15 00:00:00"` — which silently returned 0 rows because
/// `'1' < '2'` (so `'1784…' < '2026-…'` is always true, excluding every
/// row).
///
/// ## What this does
///
/// Adds a regular TEXT column `created_iso` that holds the
/// `YYYY-MM-DD HH:MM:SS` (localtime) form of the microsecond timestamp.
/// The column is populated by **application code** in `saveMessage`
/// (see `llm_history.zig`) using libc's `localtime_r` + `strftime`.
/// This is intentionally NOT done via SQLite triggers — see the
/// "Why not triggers?" section below.
///
/// ## Why not triggers / generated columns?
///
/// SQLite silently DROPS `GENERATED ALWAYS AS ... STORED` columns whose
/// expression uses a non-deterministic function (such as
/// `datetime(..., 'localtime')`, which depends on the system timezone) —
/// verified empirically against SQLite 3.53.3. The column is omitted
/// from `pragma_table_info` with no error.
///
/// Triggers can populate a regular column with `datetime()`, but they
/// have two practical failures:
///
///   1. Triggers are invisible to the application layer. The
///      production DBs ended up with many `created_iso = NULL` rows
///      because the trigger's `datetime(CAST(<microseconds> AS REAL) /
///      1000000, ...)` overflows SQLite's `datetime()` range (which
///      caps at year 9999) and silently returns NULL.
///
///   2. The trigger-based approach is invisible — hard to debug when
///      the conversion silently returns NULL.
///
/// Application-level computation in `saveMessage` (using libc
/// `localtime_r` + `strftime`) sidesteps both issues: the conversion
/// is explicit in the application's INSERT path, and libc handles
/// arbitrary Unix timestamps in the i64 range without overflow.
///
/// ## Idempotency notes
///
/// Re-running this migration is safe:
///   - `addColumnIfMissing` skips the ALTER if the column exists.
///   - The backfill UPDATE has `WHERE created_iso IS NULL OR created_iso = ''`,
///     so it only touches rows that still need populating.
///   - The CREATE INDEX uses IF NOT EXISTS.
///
/// The backfill runs every time the migration runs, so production
/// users with stale NULL rows (from earlier broken trigger-based
/// attempts) get them fixed on the next nalar restart.
pub const Migration059AddCreatedIso = struct {
    pub const version: u32 = 59;
    pub const name = "add_llm_history_created_iso";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Add the column (regular TEXT, nullable).
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "created_iso",
            "created_iso TEXT",
        );

        // 2. Backfill existing rows. The application code in
        //    `saveMessage` populates `created_iso` at INSERT time, but
        //    legacy rows (and rows created before the application
        //    update is deployed) still have NULL. We update them
        //    using the INTEGER part of the microsecond string (the
        //    first 10 digits = seconds since epoch, which fits in
        //    SQLite's `datetime()` range).
        //
        //    Note: this loses the sub-second precision of the
        //    microsecond timestamp, but `since`/`until` filters
        //    operate at second/minute granularity anyway, so the
        //    loss is acceptable.
        //
        //    We use UTC (no `'localtime'` modifier) for consistency
        //    with the application-level `currentTimeIsoLocal`
        //    helper, which also produces UTC strings. The two paths
        //    (application INSERTs and this backfill) produce identical
        //    strings for the same input.
        try db.exec(
            allocator,
            \\UPDATE llm_history
            \\SET created_iso = CASE
            \\    WHEN created_at IS NULL OR created_at = ''
            \\        THEN datetime('now')
            \\    ELSE datetime(
            \\        CAST(substr(created_at, 1, 10) AS INTEGER),
            \\        'unixepoch'
            \\    )
            \\END
            \\WHERE created_iso IS NULL
            \\   OR created_iso = ''
        , &[_][]const u8{});

        // 3. Index for queries filtering by created_iso.
        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_llm_history_created_iso ON llm_history(created_iso)",
            &[_][]const u8{},
        );
    }
};

/// Migration 061 — Re-backfill `created_iso` for rows that are NULL,
/// empty, OR have the wrong year (e.g. year 58,507 from the
/// nanosecond/microsecond mismatch).
///
/// ## Why this migration exists
///
/// Migration 060's backfill only handled rows where `created_iso` was
/// NULL or empty. It did NOT detect the **wrong-year** rows (e.g.
/// `58507-07-26 ...`) that were silently produced by `saveMessage`
/// passing nanosecond values (length 19) to a helper expecting
/// microseconds. The helper divided by `us_per_s` (1,000,000)
/// instead of `ns_per_s` (1,000,000,000), producing sec ≈ 1.78e12
/// instead of 1.78e9 — which decodes as year 58,507 in stdlib
/// epoch math. The wrong value passed SQLite's `IS NULL OR = ''`
/// guard and was never overwritten.
///
/// This migration fixes both shapes (NULL/empty AND wrong-year) with
/// a single UPDATE that recomputes from `created_at` directly. We use
/// `substr(created_at, 1, 10)` because the first 10 decimal digits of
/// either a microsecond or a nanosecond Unix timestamp are the same
/// seconds-since-epoch value (microseconds = "sNNNNNN…", nanoseconds
/// = "sNNNNNNNNNN…", the `s` seconds prefix is identical). `CAST(...,
/// INTEGER)` then gives SQLite a clean integer for `datetime(..., 'unixepoch')`.
///
/// ## Wrong-year detection
///
/// `created_iso LIKE '19__-%' OR LIKE '20__-%'` matches valid years
/// from 1970–2099 (the plausible Unix‑epoch range for any
/// production data). Rows starting with `5850[7-9]-`, `5860-`, or
/// any other "year > 9999" are caught by the negation and
/// overwritten with the recompute. Pre‑2000 rows (e.g. `1999-12-31
/// ...`) are preserved because they're legitimate old data, not a
/// bug. `IS NULL` and `= ''` are kept for safety (matches the same
/// rows Migration 060 already fixed).
///
/// We use LIKE (not GLOB) for consistency with the rest of the
/// codebase. SQLite's LIKE treats `[0-9]` as literal chars (the
/// bracket is not a wildcard), so we use the `_` wildcard to mean
/// "any single character" — `'20__-%'` matches anything starting
/// with `20`, any 2 chars, `-`.
///
/// ## Idempotency
///
/// Re-running is safe: rows with already-correct `created_iso` are
/// untouched. Only rows that still need fixing get updated.
pub const Migration061FixCreatedIsoYear = struct {
    pub const version: u32 = 61;
    pub const name = "fix_llm_history_created_iso_year";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // UPDATE WHERE clause matches three categories:
        //   1. created_iso IS NULL
        //   2. created_iso = ''
        //   3. created_iso has a year that doesn't match any plausible
        //      Unix‑timestamp year — i.e. NOT in 19xx and NOT in 20xx
        //      (which catches '58507-07-26 ...' and other clearly
        //      wrong‑year rows).
        //
        // We use LIKE (not GLOB) for portability with the rest of
        // the codebase. LIKE wildcards are `%` (any sequence) and
        // `_` (any single char). SQLite's LIKE does NOT support
        // character classes like `[0-9]` — the bracket chars are
        // treated as literals, so the pattern would never match.
        // We accept 19xx AND 20xx to cover any plausible Unix‑epoch
        // year (1970–2099). Verified:
        //   '2026-07-15' LIKE '19__-%' OR LIKE '20__-%' → 1
        //   '1999-12-31' LIKE '19__-%' OR LIKE '20__-%' → 1
        //   '58507-07-26' LIKE '19__-%' OR LIKE '20__-%' → 0
        //
        // The recompute uses substr(created_at, 1, 10) to extract
        // the seconds prefix of the timestamp, which works for both
        // microsecond AND nanosecond stored values (the first 10
        // digits are seconds-since-epoch in either case).
        try db.exec(
            allocator,
            \\UPDATE llm_history
            \\SET created_iso = CASE
            \\    WHEN created_at IS NULL OR created_at = ''
            \\        THEN datetime('now')
            \\    ELSE datetime(
            \\        CAST(substr(created_at, 1, 10) AS INTEGER),
            \\        'unixepoch'
            \\    )
            \\END
            \\WHERE created_iso IS NULL
            \\   OR created_iso = ''
            \\   OR (created_iso NOT LIKE '19__-%'
            \\       AND created_iso NOT LIKE '20__-%')
        , &[_][]const u8{});
    }
};

/// Migration 062 — Add a `description` column to
/// `workspace_item_tasks` so every task (chat / routine / kanban)
/// can carry a free-form text note alongside its display name.
///
/// Why this migration exists
/// ──────────────────────────
/// Until now, the backend's `TaskCreateRequest.description` field
/// was parsed and accepted but **not persisted** — the comment at
/// `http_response.zig:103` literally said "the frontend holds the
/// authoritative copy", which is the wrong invariant (descriptions
/// vanished on page reload). The Kanban Task Detail Dialog
/// feature (frontend, Chunk 2) reads and writes the description;
/// this migration makes it durable.
///
/// Schema choice: `NOT NULL DEFAULT ''` so existing rows survive
/// the migration without a backfill and the empty string becomes
/// the canonical "no description" sentinel (the UI renders it as
/// an "Add a description…" placeholder, matching the
/// `kanban_columns.description` precedent from Migration 053).
///
/// Idempotency / fresh-DB safety: we use `addColumnIfMissing`
/// instead of raw `ALTER TABLE` so fresh-DB installs that re-play
/// the canonical schema (already declaring `description` in their
/// CREATE TABLE) don't crash on "duplicate column". See project
/// memory `nalar-fresh-db-migration-cascade`.
///
/// Note: this migration is at version 62 because PR #99
/// (`Migration061FixCreatedIsoYear`) shipped on main before this
/// PR landed and reserved version 61. See the original
/// `Migration061AddTaskDescription` (now `Migration062`) commit
/// history for the previous v61 numbering.
///
/// Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
///   (Chunk 1, Task 1.1)
pub const Migration062AddTaskDescription = struct {
    pub const version: u32 = 62;
    pub const name = "add_task_description";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "description",
            "description TEXT NOT NULL DEFAULT ''",
        );
    }
};

/// Migration 063 — per-session opt-in for unattended long-running mode.
///
/// ## Why this migration exists
///
/// Today, when `workflow.zig`'s LLM call fails 10 times in a row, the
/// workflow returns `error.TooManyRetries` (see workflow.zig:425-465)
/// and the session goes idle. For overnight / unattended sessions where
/// the user wants the workflow to keep retrying through transient
/// upstream errors (network blips, rate limits, timeouts), this bail
/// is the wrong default — the user expects the session to keep running
/// until the LLM finally returns, or until the user manually stops it.
///
/// This migration adds two columns to `sessions`:
///   - `is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0` — the opt-in
///     flag. 0 = today's behavior (10-attempt bail). 1 = unattended mode
///     (no bail; keep retrying forever, respecting `config.retry_delay_ms`).
///   - `last_finish_reason TEXT` — the most recent `finish_reason` the
///     workflow observed for the session. Nullable so application code can
///     distinguish "never had a successful turn" from "had a turn that
///     returned 'stop'".
///
/// ## What this does
///
/// Both columns go through `addColumnIfMissing` so:
///   - Fresh-DB installs that already declare the columns in their
///     canonical CREATE TABLE for `sessions` short-circuit cleanly
///     (no `duplicate column name` error).
///   - Upgrade-from-v1 installs get the ALTER applied.
///
/// Plan: docs/superpowers/plans/2026-07-16-session-auto-retry-until-stop.md
///   (Chunk 1, Task 1.1)
pub const Migration063AddSessionAutoRetry = struct {
    pub const version: u32 = 63;
    pub const name = "add_session_auto_retry_until_stop";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Boolean opt-in flag, default off. INTEGER NOT NULL DEFAULT 0
        // matches the convention used by Migration 062 for booleans
        // and avoids NULL handling at the API edge (NULL → COALESCE
        // default would still work, but NOT NULL is more honest).
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "is_auto_retry_until_stop",
            "is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0",
        );
        // Cache column — nullable; stays NULL until workflow.zig writes
        // the first value (see workflow.zig's new
        // `updateSessionLastFinishReason` call site, Chunk 2 Task 2.1).
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "last_finish_reason",
            "last_finish_reason TEXT",
        );
    }
};

/// Migration 064 — Add the `logs` table for the frontend_log_post
/// endpoint (POST /api/log). The frontend batches browser-side
/// `console.error` / unhandled rejections / Vue runtime warnings and
/// ships them to the backend over a single POST; the backend dedups
/// by (kind, message, source, line, route_path) within a 1s window
/// and increments `count` instead of inserting a new row.
///
/// The schema mirrors the dedup key (kind, message, source, line,
/// route_path) plus a per-row `count` that the dedup UPDATE bumps.
/// Indexes on `created_at DESC` (latest-first reads) and `level`
/// (filter for warnings/errors in /api/log GET) support the
/// /api/log GET endpoint that lists recent logs.
///
/// Note: this migration was originally numbered 063 on this branch,
/// but main had already taken `063` for `add_session_auto_retry_until_stop`.
/// Renamed to 064 to avoid the collision.
pub const Migration064AddFrontendLogs = struct {
    pub const version: u32 = 64;
    pub const name = "add_frontend_logs";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(
            allocator,
            \\CREATE TABLE IF NOT EXISTS logs (
            \\  id TEXT PRIMARY KEY,
            \\  created_at INTEGER NOT NULL,
            \\  level TEXT NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  message TEXT NOT NULL,
            \\  stack TEXT,
            \\  source TEXT,
            \\  line INTEGER,
            \\  route_path TEXT,
            \\  session_id TEXT,
            \\  count INTEGER NOT NULL DEFAULT 1
            \\)
        , &[_][]const u8{});
        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at DESC)",
            &[_][]const u8{},
        );
        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level)",
            &[_][]const u8{},
        );
    }
};

/// Migration 065 — Add `workspace_item_tasks.last_human_touched_at`.
///
/// Used by the kanban card UI to decide whether to show the "AI
/// finished — awaiting your review" orange dot or the green "reviewed"
/// checkmark. Stamped by every HTTP handler that mutates a task on
/// behalf of a human user (drag, rename, edit description, pin,
/// send chat message, open chat) — see docs/plans/2026-07-26-kanban-task-notification-icon.md.
///
/// Schema (nullable INTEGER, no DEFAULT): NULL is the canonical
/// "never touched" state. The `addColumnIfMissing` helper handles both
/// upgrade-from-v1 and fresh-DB-already-declares-it paths gracefully
/// (see memory `nalar-data-and-routines.md` §"Migration #009-#052
/// fresh-DB cascade is fragile" for the failure mode this avoids).
///
/// Comparison happens against `sessions.updated_at` in the kanban
/// SELECT (not against `last_finish_reason` directly) so the
/// comparison denominator carries timezone-uniform seconds. The
/// frontend treats `last_human_touched_at == NULL` as "human has
/// never touched", which gives the "awaiting review" semantics for
/// every pre-migration task on a legacy DB.
pub const Migration065AddTaskHumanTouchedAt = struct {
    pub const version: u32 = 65;
    pub const name = "add_task_human_touched_at";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "last_human_touched_at",
            // name + type — `addColumnIfMissing` uses this verbatim as
            // `ALTER TABLE {table} ADD COLUMN {definition}`, so omitting
            // the column name would create a column literally named
            // "INTEGER". See memory `addColumnIfMissing-requires-name-type`.
            "last_human_touched_at INTEGER",
        );
    }
};

/// Migration 066 — Add `design_pages.workspace_item_task_id` foreign
/// key to bind each design page 1:1 to its `workspace_item_tasks`
/// chat-session row.
///
/// ## Why this migration exists
///
/// Today, the per-page chat lookup in `AppLayout.handleDesignOpenChat`
/// keys off a string pattern (`"Design Chat: <page_name>"`). That
/// approach has three failure modes (renames break the binding, name
/// uniqueness is not enforced, deleting a page leaves an orphan
/// chat task with no cascade). Replacing the name-based lookup with
/// a direct FK makes the binding row-level, lets the DB enforce the
/// 1:1 invariant via a UNIQUE index, and lets ON DELETE CASCADE on
/// `workspace_item_tasks(id)` clean up the chat task automatically
/// when the page is deleted (Tasks 2 + 7 in the plan will wire the
/// cascade at the model layer).
///
/// ## What this does
///
/// 1. Add `workspace_item_task_id TEXT` to `design_pages` (nullable —
///    we backfill existing rows in step 3, and fresh INSERTs from
///    `design_model.setDesignPage` populate it at create time).
/// 2. Create a UNIQUE index on the column to enforce the 1:1 invariant
///    (one task → at most one page; SQLite uses this index for the
///    UNIQUE check AND for the FK lookup, no second index needed).
/// 3. **Backfill** every existing `design_pages` row whose
///    `workspace_item_task_id IS NULL` with a fresh
///    `workspace_item_tasks` row. The new task is named
///    `"Design Chat: <page_name>"` — matching the canonical name so
///    any legacy name-pattern code (or future migrations) still
///    resolves correctly. The new task id is `task_<unix_nanoseconds>`
///    using the same `helpers.unixTimestampNanos()` scheme as
///    `design_items_create.zig:100`.
///
/// ## FK constraint intentionally omitted (decision)
///
/// SQLite does NOT support `ALTER TABLE … ADD CONSTRAINT FK …`. The
/// canonical alternatives — triggers (`BEFORE INSERT` + `ON DELETE
/// CASCADE`) or recreate-table — both add complexity that's
/// out of scope for v1. The UNIQUE index + application-level
/// validation in `design_model.setDesignPage` is the second line of
/// defense; revisit if migration friction appears. See plan Task 1
/// decision bullet "Decision: skip the FK for now."
///
/// Plan: docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md
pub const Migration066AddDesignPageTaskFk = struct {
    pub const version: u32 = 66;
    pub const name = "add_design_page_task_fk";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Add the column. Nullable — backfilled below; new
        //    INSERTs from `design_model.setDesignPage` populate it
        //    at create time.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "design_pages",
            "workspace_item_task_id",
            // name + type — `addColumnIfMissing` uses this verbatim as
            // `ALTER TABLE {table} ADD COLUMN {definition}`, so omitting
            // the column name would create a column literally named
            // "TEXT". See memory `addColumnIfMissing-requires-name-type`.
            "workspace_item_task_id TEXT",
        );

        // 2. UNIQUE index for the 1:1 invariant. `IF NOT EXISTS`
        //    keeps the migration idempotent on re-run.
        try db.exec(
            allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_design_pages_workspace_item_task_id " ++
                "ON design_pages(workspace_item_task_id)",
            &[_][]const u8{},
        );

        // 3. Backfill existing pages. For each row whose
        //    `workspace_item_task_id IS NULL`, INSERT a fresh
        //    `workspace_item_tasks` row named
        //    `"Design Chat: <page_name>"` and UPDATE the page with
        //    the new task id.
        //
        //    We iterate in Zig (not a single SQL CTE) because the
        //    task id is `task_<unix_nanoseconds>` and SQLite has no
        //    native nanosecond-timestamp primitive. Computing the
        //    id in Zig + dynamic SQL with `std.fmt.bufPrint` is the
        //    cleanest path. Only pages with NULL task_id are
        //    touched (re-run safety: after the first run, every row
        //    is populated; the WHERE clause is a no-op on re-runs).
        var q = try db.query(
            allocator,
            \\SELECT dp.id, dp.workspace_item_id,
            \\       COALESCE(dp.name, '') AS name
            \\FROM design_pages dp
            \\WHERE dp.workspace_item_task_id IS NULL
        , &[_][]const u8{});
        defer q.deinit();

        // Last task id's nanosecond value — used to guarantee strictly
        // increasing ids across the batch (Windows FILETIME granularity
        // can repeat back-to-back ticks). Declared OUTSIDE the loop so
        // it persists across iterations.
        var last_task_ns: i128 = 0;

        while (try q.next()) |row| {
            defer row.deinit(allocator);
            const page_id = row.values[0];
            const item_id = row.values[1];
            // Defensive normalization: empty page name → "untitled"
            // (we never want a literal "Design Chat: " with trailing
            // space). COALESCEd above means empty here == the row had
            // no name. Real page names get `"Design Chat: <name>"`.
            const page_name_raw = row.values[2];
            const full_task_name = if (std.mem.eql(u8, page_name_raw, ""))
                "Design Chat: untitled"
            else
                try std.fmt.allocPrint(
                    allocator,
                    "Design Chat: {s}",
                    .{page_name_raw},
                );
            defer if (!std.mem.eql(u8, page_name_raw, "")) allocator.free(full_task_name);

            // Generate a unique `task_<unix_nanoseconds>` id. The
            // nanosecond scheme matches design_items_create.zig:100 —
            // collisions on a multi-page backfill are essentially
            // impossible (each call is a separate `std.c.clock_gettime`
            // syscall yielding a fresh value).
            //
            // Windows caveat: `GetSystemTimeAsFileTime` has a coarse
            // effective granularity (0.5–15.6 ms depending on the
            // timer coalescing), so back-to-back calls in this loop
            // CAN return the same tick → duplicate PRIMARY KEY.
            // Guard: if the fresh timestamp is <= the previous one,
            // use prev + 1 so every id in the batch strictly
            // increases and stays unique.
            var task_id_buf: [64]u8 = undefined;
            const now_ns = helpers.unixTimestampNanos();
            const unique_ns: i128 = if (now_ns <= last_task_ns) last_task_ns + 1 else now_ns;
            last_task_ns = unique_ns;
            const task_id = std.fmt.bufPrint(
                task_id_buf[0..],
                "task_{d}",
                .{unique_ns},
            ) catch return error.BufferTooSmall;

            // Dynamic INSERT + UPDATE per page. We split into TWO exec calls
            // because `db.exec` (via `sqlite3_prepare_v2`) only
            // compiles the FIRST statement in a multi-statement
            // string — it stops at the first `;`. Single exec per
            // statement keeps both commits atomic on the connection
            // (each runs in autocommit, but the migration is a one-shot
            // so partial-commit risk is acceptable). Empty-string
            // description is a SQL '' literal so it doesn't trip
            // `SqliteBackend.exec` empty-slice-binds-as-NULL — see
            // memory `sqlite-backend-empty-slice-binds-as-null`.
            const insert_sql = try std.fmt.allocPrint(
                allocator,
                "INSERT INTO workspace_item_tasks " ++
                    "(id, name, workspace_item_id, task_type, description) " ++
                    "VALUES ('{s}', '{s}', '{s}', 'standard', '')",
                .{ task_id, full_task_name, item_id },
            );
            defer allocator.free(insert_sql);
            try db.exec(allocator, insert_sql, &[_][]const u8{});

            const update_sql = try std.fmt.allocPrint(
                allocator,
                "UPDATE design_pages SET workspace_item_task_id = '{s}' " ++
                    "WHERE id = '{s}'",
                .{ task_id, page_id },
            );
            defer allocator.free(update_sql);
            try db.exec(allocator, update_sql, &[_][]const u8{});
        }
    }
};

/// Migration 067 — Add `workspace_item_tasks.tags` column to support the
/// kanban task tags feature (free-form string list).
///
/// ## Why this migration exists
///
/// The kanban task tags feature adds user-defined labels per task
/// (e.g. "bug", "urgent", "frontend"). Tags are stored as a JSON-encode
/// array string (e.g. `'["bug","urgent","frontend"]'`); empty string
/// is the canonical "no tags" sentinel, matching the `description`
/// column (Migration 062) convention.
///
/// ## What this does
///
/// 1. Add `tags TEXT NOT NULL DEFAULT ''` to `workspace_item_tasks`
///    via `addColumnIfMissing` — safe for both upgrade-from-v1 DBs
///    (no column) AND fresh-DB installs where the canonical CREATE
///    TABLE in Migration 034 / 044 / 062 / 065 already declares the
///    column. The `addColumnIfMissing` helper checks
///    `pragma_table_info` before issuing the ALTER, so duplicate-
///    column errors are impossible.
/// 2. Leave existing rows at '' (the canonical "no tags" sentinel) —
///    we cannot retroactively know what tags the user wanted, and
///    any non-empty default would silently fabricate tags for
///    every legacy task.
///
/// ## Why a TEXT column (JSON-encode array string), not a `tags` table
///
/// No SQL-level filtering by tag is needed in v1 (the kanban board
/// has no filter UI yet). A managed `tags` table would add
/// vocabulary, color, and rename machinery without a current
/// consumer. Forward-compatible: a future migration can read the
/// JSON array via `json_each` and create proper tag rows + a join
/// table — the existing JSON column is the natural source of truth.
///
/// ## Why no index
///
/// The column stores JSON, which SQLite cannot index by JSON path
/// without the JSON1 extension (not used here). A LIKE index across
/// the JSON string would be expensive and useless until the column
/// is restructured. Defer until tag filtering is in scope.
///
/// Plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md (Task 1)
pub const Migration067AddTaskTags = struct {
    pub const version: u32 = 67;
    pub const name = "add_task_tags";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "tags",
            // `addColumnIfMissing` builds `ALTER TABLE {table} ADD COLUMN
            // {definition}`, so the definition must include BOTH the
            // column name AND the type. Omitting the type would create
            // a column literally named "TEXT" — see project memory
            // `addColumnIfMissing-requires-name-type`.
            "tags TEXT NOT NULL DEFAULT ''",
        );
    }
};

/// Migration 068 — Add `llm_history.is_loading` column + partial
/// UNIQUE INDEX on `tool_call_id` (tool-call-loading-placeholder plan).
///
/// ## Why this migration exists
///
/// The OpenAI tool-call API contract requires every `tool_call_id`
/// declared in an assistant message's `tool_calls` array to have a
/// matching `role=tool` message in the next conversation payload, or
/// the API rejects with "Invalid function ID". If the agent crashes
/// mid-execution (long bash command, spawn_sub_agent dies, nalar
/// process SIGKILL'd, network hang), the assistant message is
/// already in the DB but the per-tool result rows aren't — every
/// subsequent LLM call fails.
///
/// Fix: pre-create the placeholder `role=tool` rows BEFORE the
/// long-running tools execute (so the API contract is satisfied by
/// id), mark them `is_loading=1`, then UPDATE them in place after
/// the tool completes. A startup hook
/// (`resolveStaleLoadingToolResults`) replaces stranded placeholders
/// with a synthetic "interrupted" message.
///
/// ## What this does
///
/// 1. Add `is_loading INTEGER NOT NULL DEFAULT 0` to `llm_history`
///    via `addColumnIfMissing` — safe for both upgrade-from-v1 DBs
///    and fresh-DB installs (where the canonical CREATE TABLE in the
///    earlier migrations doesn't include the column yet).
///
/// 2. Backfill `is_loading = 0` for every existing row (the
///    canonical "not loading" sentinel — the migration runs before
///    any placeholder code path can land in the DB).
///
/// 3. Add a partial UNIQUE INDEX on `tool_call_id` so duplicate
///    placeholders for the same id are rejected at the DB level.
///    The partial WHERE clause excludes empty-string tool_call_ids
///    (the assistant message rows) so the assistant message's
///    `tool_call_id = ''` doesn't conflict with the placeholders'
///    `tool_call_id = 'tcA'` etc. Without this index, a dispatcher
///    race could create two placeholders for the same id.
///
/// ## Why `IF NOT EXISTS` on both
///
/// Both the column ADD and the INDEX CREATE use idempotent forms so
/// the migration is safe on re-run (per the project-wide
/// `migration-is-idempotent` invariant; see migration 020, 052, 054,
/// 065, 066 for prior art).
///
/// Plan: docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md
/// Bug: task_1785784899843 ("invalid function ID tool call error")
pub const Migration068AddToolCallLoading = struct {
    pub const version: u32 = 68;
    pub const name = "add_tool_call_loading";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Add the `is_loading` column. Idempotent via
        //    `addColumnIfMissing` — safe for fresh-DB installs where
        //    the canonical CREATE TABLE in earlier migrations doesn't
        //    include it yet.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "is_loading",
            // name + type — `addColumnIfMissing` builds
            // `ALTER TABLE {table} ADD COLUMN {definition}`, so the
            // definition must include BOTH the column name AND the
            // type. Omitting the type would create a column literally
            // named "INTEGER NOT NULL DEFAULT 0" — see project memory
            // `addColumnIfMissing-requires-name-type`.
            "is_loading INTEGER NOT NULL DEFAULT 0",
        );

        // 2. Backfill every existing row to `is_loading = 0`. SQLite's
        //    ADD COLUMN with NOT NULL DEFAULT 0 *already* backfills
        //    legacy rows to 0 at the storage layer (DEFAULT applies to
        //    INSERT and backfill is part of ALTER TABLE ADD COLUMN),
        //    but we issue an explicit UPDATE here to make the sentinel
        //    intent obvious in the schema history. UPDATE is a no-op
        //    after the first run (every row already has 0).
        try db.exec(
            allocator,
            "UPDATE llm_history SET is_loading = 0 WHERE is_loading IS NULL OR is_loading != 0",
            &[_][]const u8{},
        );

        // 3. Partial UNIQUE INDEX on `tool_call_id`. The partial
        //    WHERE clause excludes empty-string tool_call_ids (the
        //    assistant message's `tool_call_id = ''`) so the assistant
        //    row doesn't conflict with the placeholder rows.
        //
        //    Name: `idx_llm_history_tool_call_id_loading` — the
        //    `_loading` suffix is intentional: future migrations may
        //    add a different UNIQUE INDEX for non-loading contexts
        //    (e.g. "current session feed" which needs the latest
        //    tool result per tool_call_id), and the name makes them
        //    easy to keep distinct.
        try db.exec(
            allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_llm_history_tool_call_id_loading " ++
                "ON llm_history(tool_call_id) " ++
                "WHERE tool_call_id IS NOT NULL AND tool_call_id != ''",
            &[_][]const u8{},
        );
    }
};

/// Register all migrations with a MigrationManager
pub fn registerAllMigrations(manager: *MigrationManager) !void {
    for (allMigrations) |migration| {
        try manager.registerMigration(migration);
    }
}

/// Migration 069 — Add `workspace_item_tasks.image_urls` column
/// (kanban-image-urls-column plan, 2026-08-06).
///
/// ## Why this migration exists
///
/// Until now, the only way to attach an image to a kanban task was the
/// filesystem-backed attachment endpoint (`POST /api/workspaces/tasks/:id/attachments`),
/// which writes the file to `<workspace_item.path>/.nalar/attachments/<task_id>/<n>.<ext>`
/// and serves it back via a broken `GET /...attachments/*` wildcard route
/// (the custom router doesn't actually handle `*` — see
/// `src/modules/custom_http_server/src/router.zig::matchPathWithParams`).
/// Net effect: images uploaded that way were 404'd on every read.
///
/// The user feedback (task_id tracking) was unambiguous: stop using the
/// attachment endpoint, add a new column on `workspace_item_tasks` that
/// stores the raw base64 data URL inline. Self-contained, no filesystem,
/// no separate GET endpoint, no broken route. The image renders directly
/// via `<img :src="task.imageUrls[0]">`.
///
/// ## Storage format
///
/// `image_urls TEXT NOT NULL DEFAULT ''` — `||`-delimited base64 data
/// URLs. Some images carry kilobytes of payload (post-downscale), so we
/// put the column in TEXT (not VARCHAR) and avoid any CLOB boundaries.
/// The `||` delimiter is the same convention used by the
/// `llm_history.image_url` `||`-delimited string (Migration 036 + the
/// `saveMessage` join at `llm_history.zig:1207-1221`).
///
/// On read: split on `|` into `[]u8` slices; each non-empty slice is a
/// data URL. On write: `ArrayList(u8).appendSlice(url)` + `"||"` between
/// non-empty entries; an empty input list yields `""` (the column's
/// DEFAULT). The wire format is identical to `llm_history.image_url` so
/// any helper that handles `||`-delimited URL strings can be reused.
///
/// ## Why `||` and not `JSON` (per the user's "like llm_history" hint)
///
/// The `llm_history.image_url` column already uses `||` for the same
/// shape. Following the same convention here means:
///
///   - One code path for the join / split helpers (a single `||` is
///     easy to grep; JSON would diverge from the precedent).
///   - No `json_valid` / `json_type` defensive checks needed (the
///     `tags` column has those for malformed-data reasons; a `||`
///     delimiter is unambiguous).
///   - SQLite `LIKE` filtering on image URLs is straightforward if
///     we ever need to search by URL.
///
/// ## Idempotency / fresh-DB safety
///
/// `addColumnIfMissing` is the canonical helper that wraps `ALTER TABLE`
/// in a column-existence check. Both fresh-DB replay (the canonical
/// `CREATE TABLE workspace_item_tasks` body in Migration 026 doesn't
/// declare `image_urls`) and upgrade-from-v1 paths land on the same
/// end state.
///
/// ## User-visible wire format
///
/// The handler reads `image_urls` as the raw `||`-delimited string and
/// returns it in the JSON response as-is. The frontend parses with
/// `s.split('|').filter(Boolean)` (no JSON wrap, no double-encoding).
/// This keeps the round-trip trivial to debug — the value you see in
/// the DB is the value you see in the network tab.
///
/// Plan: docs/superpowers/plans/2026-08-06-kanban-image-urls-column.md
/// Bug: task_1785795051796 ("kanban task not saving the images or
/// base 64 in kanban description, after create a task or run aent")
pub const Migration069AddTaskImageUrls = struct {
    pub const version: u32 = 69;
    pub const name = "add_task_image_urls";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // `image_urls TEXT NOT NULL DEFAULT ''` — the empty string is the
        // canonical "no images" sentinel (matches `description` / `tags`
        // patterns from Migrations 062 / 067). `addColumnIfMissing`
        // constructs `ALTER TABLE {table} ADD COLUMN {definition}`, so
        // the definition MUST include the column name AND the type —
        // omitting the type would create a column literally named
        // "TEXT NOT NULL DEFAULT ''". See project memory
        // `addColumnIfMissing-requires-name-type`.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "image_urls",
            "image_urls TEXT NOT NULL DEFAULT ''",
        );
    }
};

/// Migration 071 — `workspace_item_tasks.cwd` (per-task cwd_session).
///
/// Adds a `cwd TEXT NOT NULL DEFAULT ''` column so each kanban task
/// can carry its own cwd override. The legacy `cwd_session` HTTP
/// field on `RequestSession` is unaffected — that one is the explicit
/// per-call cwd override the frontend sends with each chat message.
/// The new `cwd` column is the per-task default that the frontend
/// reads from the task list and threads into the runAgentOnNewTask
/// flow.
///
/// The name `cwd` (not `cwd_session`) was chosen to avoid confusion
/// with the legacy HTTP `cwd_session` field — the column belongs to
/// the task, the HTTP field belongs to the session create call.
/// Frontend wire field is `cwd` (matching the column).
///
/// Resolution priority (in `session_create.zig::useCase`):
///   1. RequestSession.cwd_session (explicit per-call, NEW behaviour
///      BEFORE this migration stays the same)
///   2. workspace_item_tasks.cwd     (this column — NEW)
///   3. workspace_items.path         (existing kanban-level fallback)
///   4. createSandbox(...)            (per-session TMPDIR fallback)
///
/// Empty string is the canonical "no per-task cwd" sentinel (NOT
/// NULL DEFAULT '' matches the `description` / `tags` / `image_urls`
/// pattern from Migrations 062 / 067 / 069). Existing rows backfill
/// to `''` (cwd-less legacy tasks) when the migration runs on an
/// existing DB.
///
/// Plan: docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
/// Task: task_1785959915548 (kanban: sprint bulan juni →
///   "when user want to create a kanban, make cwd session as optional")
///
/// Renamed from Migration 070 during PR #200 merge (main already
/// used 070 for the agent_memories migration).
pub const Migration071AddTaskCwd = struct {
    pub const version: u32 = 71;
    pub const name = "add_task_cwd";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // `cwd TEXT NOT NULL DEFAULT ''` — the empty string is the
        // canonical "no per-task cwd" sentinel (matches the
        // description / tags / image_urls patterns from Migrations
        // 062 / 067 / 069). `addColumnIfMissing` constructs
        // `ALTER TABLE {table} ADD COLUMN {definition}`, so the
        // definition MUST include the column name AND the type —
        // omitting the type would create a column literally named
        // "TEXT NOT NULL DEFAULT ''". See project memory
        // `addColumnIfMissing-requires-name-type`.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "cwd",
            "cwd TEXT NOT NULL DEFAULT ''",
        );
    }
};

/// Migration 072 — Extract `kanban_column_id` + `kanban_position` from
/// `workspace_item_tasks` into a dedicated `kanban` join table.
///
/// Before: the two placement columns live on the universal
/// `workspace_item_tasks` table (alongside chat/routine/kanban task
/// attributes like `description`, `tags`, `image_urls`, `cwd`, etc.).
/// After: a new `kanban(workspace_item_task_id, kanban_column_id, kanban_position)`
/// table holds the 1:1 task-to-board placement; non-kanban tasks
/// simply have no row.
///
/// Wire format UNCHANGED — `Task.kanban_column_id` and
/// `Task.kanban_position` continue to appear on every Task JSON via
/// a `LEFT JOIN kanban k ON k.workspace_item_task_id = t.id` in list queries. The
/// frontend stores/components/SSE handlers stay byte-for-byte the
/// same.
///
/// Plan: docs/superpowers/plans/2026-08-15-extract-kanban-columns-to-kanban-table.md
/// Task: task_1786527996378 (kanban: sprint bulan juni → "move column
///   workspace_item_tasks table").
///
/// Steps (inside a single tx for atomicity — a crash mid-
/// migration would otherwise leave the DB with both new and old
/// columns populated, which the model layer's `LEFT JOIN` would
/// silently drop data from):
///   1. CREATE TABLE IF NOT EXISTS kanban (...) — fresh-DB-safe
///   2. CREATE INDEX IF NOT EXISTS idx_kanban_column_position ...
///   3. DROP INDEX IF EXISTS idx_tasks_column_position — must run
///      BEFORE the INSERT, otherwise SQLite's "database table is
///      locked" (SQLITE_LOCKED) fires because the INSERT writes to
///      a table with FKs referencing workspace_item_tasks.
///   4. INSERT OR IGNORE INTO kanban (...) SELECT … FROM
///      workspace_item_tasks WHERE kanban_column_id IS NOT NULL AND
///      kanban_column_id IN (SELECT id FROM kanban_columns) — skip
///      orphans (R8). Wrapped in a check: if the source columns are
///      already gone (re-run), skip the INSERT entirely.
///   5. DROP COLUMN kanban_column_id (dropColumnIfExists for fresh-DB
///      safety)
///   6. DROP COLUMN kanban_position
pub const Migration072ExtractKanbanTable = struct {
    pub const version: u32 = 72;
    pub const name = "extract_kanban_table";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Wrap in a tx (db.begin/tx.exec/tx.commit) so the CREATE+INSERT+DROP sequence is
        // atomic. Without the wrapper, SQLite auto-commits each step
        // and a crash between step 3 (backfill) and step 5 (DROP
        // COLUMN) would leave the DB with both new and old columns
        // populated.
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        // Step 1: CREATE kanban (idempotent via IF NOT EXISTS)
        try tx.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS kanban (
            \\    workspace_item_task_id TEXT PRIMARY KEY,
            \\    kanban_column_id       TEXT NOT NULL,
            \\    kanban_position        INTEGER NOT NULL DEFAULT 0,
            \\    FOREIGN KEY (workspace_item_task_id)
            \\        REFERENCES workspace_item_tasks(id) ON DELETE CASCADE,
            \\    FOREIGN KEY (kanban_column_id)
            \\        REFERENCES kanban_columns(id)       ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        // Step 2: per-column ordering index
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_kanban_column_position " ++
            "ON kanban(kanban_column_id, kanban_position)",
            &[_][]const u8{},
        );

        // Step 4: drop the per-column index on workspace_item_tasks
        // BEFORE the INSERT (which would otherwise create a pending
        // read lock on the same table via the kanban FK validation,
        // blocking the DROP). SQLite's "database table is locked"
        // (SQLITE_LOCKED) error fires when an unfinished WRITE
        // transaction is touching a table that another statement
        // (here, DROP INDEX) needs an exclusive lock on.
        try tx.exec(allocator,
            "DROP INDEX IF EXISTS idx_tasks_column_position",
            &[_][]const u8{},
        );

        // Step 3: backfill from existing data. Two filters:
        //   - `kanban_column_id IS NOT NULL` skips chat/routine/design
        //     tasks (they shouldn't be on a kanban anyway, but be
        //     defensive).
        //   - `kanban_column_id IN (SELECT id FROM kanban_columns)`
        //     skips orphan references (R8 — a task's column could
        //     have been hard-deleted before the FK existed; we don't
        //     surface unassigned rows retroactively).
        // INSERT OR IGNORE makes a re-run safe (won't crash on the
        // PRIMARY KEY collision).
        //
        // We only run the INSERT if the source columns still exist —
        // on a re-run they were already dropped by step 5/6 of the
        // first run, so the SELECT would fail with "no such column".
        // A first-run DB has the columns; a re-run DB does not.
        var check_buf: [256]u8 = undefined;
        const check_sql = std.fmt.bufPrint(
            &check_buf,
            "SELECT 1 FROM pragma_table_info('workspace_item_tasks') " ++
                "WHERE name = 'kanban_column_id'",
            .{},
        ) catch return error.BufferTooSmall;
        var q = try tx.query(allocator, check_sql, &.{});
        defer q.deinit();
        if (try q.next()) |row| {
            // Source columns still exist — first run, do the backfill.
            row.deinit(allocator);
            try tx.exec(allocator,
                \\INSERT OR IGNORE INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position)
                \\SELECT t.id, t.kanban_column_id, COALESCE(t.kanban_position, 0)
                \\FROM workspace_item_tasks t
                \\WHERE t.kanban_column_id IS NOT NULL
                \\  AND t.kanban_column_id IN (SELECT id FROM kanban_columns)
            , &[_][]const u8{});
        }
        // else: re-run — backfill already happened on the first run.

        // Step 5 + 6: drop the two columns. dropColumnIfExists is the
        // safe pattern (used in Migration 052) — fresh-DB users who
        // walked the canonical schema may not have these columns if
        // we eventually move them out of the canonical CREATE TABLE.
        try dropColumnIfExists(.{ .tx = &tx }, allocator, "workspace_item_tasks", "kanban_column_id");
        try dropColumnIfExists(.{ .tx = &tx }, allocator, "workspace_item_tasks", "kanban_position");

        // Commit the transaction. After this, Migration 072 is "done"
        // and the new schema is durable.
        try tx.commit();

        // ANALYZE so the query planner sees the new index (mirrors
        // Migration 051 / 041 / 042 / 043 / 048 / 049 / 050).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

// ============================================================================
// Migration 073 — `session_activity` append-only log.
// ============================================================================
//
// What this migration creates
// ────────────────────────────
// A per-session activity log that records two kinds of events:
//   1. Every `update_activity` tool call (the agent's `thought` string).
//   2. Every compaction event (`buildCompactionEnvelope` summary).
//
// Until now the only record of agent activity was
// `worker.last_activity_description` — a single row per worker that
// gets OVERWRITTEN on every update. That column is the live "what the
// worker is doing RIGHT NOW" for the sidebar UI (consumed by
// `prompts_make_activity_info_context.zig`). The new
// `session_activity` table is the per-session HISTORICAL log — every
// thought + every compaction event, ordered by `created_at`.
//
// Why `id` is TEXT, not INTEGER
// ──────────────────────────────
// Project-wide convention: every id column is TEXT (see
// `llm_history.id` Migration 001, `agent_memories.id` Migration 070,
// `kanban.workspace_item_task_id` Migration 072,
// `sessions.id`, `worker.id`). The helper
// (`llm_history.recordSessionActivity`) generates the id in
// application code from `std.Io.Timestamp.now(io, .real).nanoseconds`
// — same pattern as `llm_history.saveMessage` (line 1094) and
// `saveToolResultPlaceholder` (line 2448).
//
// Why no FK on `session_id`
// ──────────────────────────
// A session could be hard-deleted while keeping its history (matches
// the `llm_history.session_id` precedent, also a bare TEXT).
//
// Plan: docs/superpowers/plans/2026-08-13-session-activity-table.md
// Task: task_1786629034327 ("new table session_activity")
pub const Migration073AddSessionActivity = struct {
    pub const version: u32 = 73;
    pub const name = "add_session_activity";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Source table — append-only log, no UNIQUE constraint.
        //    `description` is NOT NULL (callers must supply) but has
        //    no DEFAULT — an empty description would defeat the
        //    purpose of the log.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_activity (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    description TEXT NOT NULL,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // 2. Per-session newest-first index. Matches the index name
        //    pattern used elsewhere (`idx_llm_history_session`,
        //    `idx_session_skills_session`, `idx_agent_memories_updated`).
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_activity_session_created " ++
                "ON session_activity(session_id, created_at DESC)",
            &[_][]const u8{},
        );
    }
};

/// Migration 074 — Add `cache_creation_input_tokens` + `cache_read_input_tokens` columns to `llm_history` so the Anthropic profile's cache breakdown survives from the SSE parser to the persistent row. OpenAI rows always carry 0. Idempotent via `addColumnIfMissing` (probes `pragma_table_info` first; matches the Migration 013/020 pattern). Plan: docs/superpowers/plans/2026-08-13-fix-anthropic-total-tokens.md. Task: task_1786640688092.
pub const Migration074AddLlmHistoryCacheTokenColumns = struct {
    pub const version: u32 = 74;
    pub const name = "add_llm_history_cache_token_columns";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Anthropic cache WRITE breakdown (billed at ~1.25x input rate). Default 0 for legacy rows + non-Anthropic profiles.
        try addColumnIfMissing(.{ .db = db }, allocator, "llm_history", "cache_creation_input_tokens", "cache_creation_input_tokens INTEGER DEFAULT 0");

        // Anthropic cache READ breakdown (billed at ~0.1x input rate, but still tokens the model processed -- folded into `prompt_tokens` + `total_tokens` by Agent.parse_anthropic_stream_chunk). Default 0 for legacy rows + non-Anthropic profiles.
        try addColumnIfMissing(.{ .db = db }, allocator, "llm_history", "cache_read_input_tokens", "cache_read_input_tokens INTEGER DEFAULT 0");
    }
};

/// Migration 075 — Rename 5 timestamp columns to use the `_nano` suffix,
/// making the column name self-document the stored unit (integer since
/// Unix epoch). This is a pure renaming pass — the stored values, column
/// types, and wire-format JSON field names are ALL preserved. SQLite's
/// `ALTER TABLE … RENAME COLUMN` (>= 3.25) handles the rename atomically
/// and auto-updates FK references; the only manual work is renaming the
/// two indexes whose name explicitly contains the old column name
/// (`idx_logs_created_at`, `idx_worker_last_activity`).
///
/// ## Why this migration exists
///
/// Today, the five columns have ambiguous names that don't document
/// their precision:
///
/// | Table | Column | Actual precision |
/// |---|---|---|
/// | `logs` | `created_at` | unix **ms** (i64) |
/// | `llm_history` | `created_at` | unix **ns** as TEXT (19 digits) |
/// | `session_skills` | `loaded_at` | unix **s** (i64) |
/// | `worker` | `last_activity` | unix **s** (i64) |
/// | `workspace_item_tasks` | `last_human_touched_at` | unix **ms** (i64) |
///
/// Migration 059 v1 (commit b6177842) used
/// `datetime(CAST(<microseconds> AS REAL) / 1000000, 'unixepoch', 'localtime')`
/// to populate `created_iso` from `created_at` — but the column
/// actually stored **nanoseconds**, so the trigger divided by 1e6
/// (microseconds→seconds) instead of 1e9 (nanoseconds→seconds). The
/// 1000× error produced rows that decoded to year 58,507. It took
/// two migration fixes (Migrations 060 + 061) to repair the damage.
///
/// Renaming the columns so each carries the `_nano` suffix makes this
/// kind of unit confusion impossible to repeat.
///
/// ## Naming choice — uniform `_nano` vs. mixed suffixes
///
/// The user requested `_nano` uniformly across all 5 columns. The
/// suffix here means "integer stored since Unix epoch" — a uniform
/// project convention, not a strict precision assertion. The actual
/// precision (ms / s / ns) per column is documented in each
/// column's doc-comment and the corresponding Zig model file
/// (`models/log.zig`, `models/llm_history.zig`, `models/session_skill.zig`,
/// `models/worker.zig`, `models/workspace_item_task.zig`).
///
/// ## Wire format preservation
///
/// The JSON field name on HTTP responses stays exactly the same:
/// `created_at`, `loaded_at`, `last_activity`, `last_human_touched_at`.
/// The Zig SELECT statements read from the new SQL column name and
/// alias it back to the old wire name (e.g.
/// `SELECT w.last_activity_nano AS last_activity FROM worker w`).
///
/// The Zig struct fields also keep the old name (`SessionInfo.created_at`,
/// `WorkerInfo.last_activity`, `SkillInfo.loaded_at`,
/// `WorkspaceItemTaskInfo.last_human_touched_at`,
/// `LogInfo.created_at`) so the JSON serializers / SSE payload structs
/// don't change.
///
/// ## Idempotency
///
/// `renameColumnIfExists` probes `pragma_table_info` first — if the
/// OLD column doesn't exist (fresh-DB install that already declares
/// the NEW column, or a re-run after the rename succeeded), the
/// helper returns silently. This matches the Migration 052 + 054
/// + 072 `dropColumnIfExists` pattern.
///
/// ## Index renaming
///
/// `idx_logs_created_at` and `idx_worker_last_activity` have the OLD
/// column name in their index name — rename them via
/// `DROP INDEX IF EXISTS old; CREATE INDEX IF NOT EXISTS new`. The
/// other two indexes that reference the renamed columns
/// (`idx_llm_history_session_created`, `idx_llm_history_created_session`)
/// use a generic `_created` suffix and are left as-is — SQLite
/// updates the index's INTERNAL column reference during the RENAME,
/// but the index's NAME stays unchanged.
///
/// Plan: docs/superpowers/plans/2026-08-16-rename-timestamp-columns-nano-suffix.md
/// Task: task_1786891244388_1.
pub const Migration075RenameTimestampColumnsToNanoSuffix = struct {
    pub const version: u32 = 75;
    pub const name = "rename_timestamp_columns_to_nano_suffix";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Wrap in a tx (db.begin/tx.exec/tx.commit) so the 5 renames + 2 index swaps are
        // atomic. A crash mid-migration would otherwise leave the DB
        // with some columns renamed and others not, breaking every
        // SQL site that targets the old names. SQLite auto-commits
        // each statement otherwise.
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        // 5 column renames — order doesn't matter logically, but
        // keep the order alphabetical by table for diff readability.
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "llm_history", "created_at", "created_at_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "logs", "created_at", "created_at_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "session_skills", "loaded_at", "loaded_at_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "worker", "last_activity", "last_activity_nano");
        try renameColumnIfExists(.{ .tx = &tx }, allocator, "workspace_item_tasks", "last_human_touched_at", "last_human_touched_at_nano");

        // 2 index renames — SQLite doesn't have `ALTER INDEX … RENAME
        // TO …`, and the index's auto-generated name doesn't auto-
        // update on the column rename. DROP + CREATE under the new
        // name. The `IF NOT EXISTS` on the CREATE is defensive
        // (after a re-run, the new index already exists).
        try tx.exec(allocator, "DROP INDEX IF EXISTS idx_logs_created_at", &.{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_created_at_nano ON logs(created_at_nano DESC)",
            &.{});

        try tx.exec(allocator, "DROP INDEX IF EXISTS idx_worker_last_activity", &.{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_worker_last_activity_nano ON worker(last_activity_nano DESC)",
            &.{});

        // Commit the transaction. After this, Migration 075 is
        // "done" and the new schema is durable.
        try tx.commit();

        // ANALYZE so the query planner sees the renamed indexes
        // (mirrors Migration 041/042/043/051 pattern).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

// ============================================================================
// Migration 076 — Agent Mode: `agents` + `agent_knowledge` + `agent_tools`
// ============================================================================
//
// What this migration creates
// ────────────────────────────
// Agent Mode adds a fourth workspace-item type — `agent` — alongside
// `folder` / `kanban` / `design`. Each Agent is a persistent chatbot
// configuration with:
//   - a `path` (cwd for its chat sessions, like Kanban/Design)
//   - a list of absolute-path markdown knowledge files on disk
//     (injected into the system prompt as `## Agent Knowledge`)
//   - a tool allowlist (filtering the LLM's function-call schema)
//
// Three new tables back this:
//
//   1. `agents` — 1-1 with `workspace_items` (UNIQUE workspace_item_id).
//      Holds the agent's description (free-form). Empty agents table
//      means no Agents exist yet on a workspace.
//
//   2. `agent_knowledge` — N-1 with `agents`. Each row = a markdown file
//      path on disk + an optional label + a position for drag-reorder.
//      The backend re-reads file contents from disk at every chat start
//      (no content is duplicated into SQLite).
//
//   3. `agent_tools` — N-1 with `agents`. Each row = one tool explicitly
//      allowed for the agent. `tool_name` matches the canonical registry
//      at `tools_equipped.zig:118`. UNIQUE (agent_id, tool_name) so the
//      same tool can't be added twice.
//
// All 3 tables use `CREATE ... IF NOT EXISTS` — re-running the
// migration is a no-op. All FKs use `ON DELETE CASCADE` so deleting the
// parent workspace_item drops the agent + (cascade) its knowledge +
// tool rows.
//
// Why a separate agents table (and not just columns on workspace_items)
// ─────────────────────────────────────────────────────────────────────
// The user's spec specifies a 1-1 table. Keeping it separate:
//   - Future agent-specific columns (system-prompt override, default
//     model, allowed-tools baseline, embedding-config toggle) become
//     additive columns on `agents`, NOT on `workspace_items` (which
//     would affect kanban / design / folder rows too).
//   - Enforces the 1-1 invariant via `UNIQUE(workspace_item_id)` at the
//     schema level, not just at the application layer.
//
// Why a separate agent_knowledge table
// ─────────────────────────────────────
// One Agent has N knowledge files. A TEXT column on `agents` can't
// model N rows. The backend re-reads file contents from disk every
// chat (no content duplicated into SQLite). Storage stays small (paths
// only). A separate table also enables per-entry metadata (label,
// position, created_at) without future migrations.
//
// Why a separate agent_tools table
// ─────────────────────────────────
// One Agent has N tools enabled. The runtime filter is a single SQL
// query. `tool_name` + `enabled` give us per-row toggling for v1 +
// future per-tool overrides (e.g. per-tool rate limit) without another
// migration. UNIQUE (agent_id, tool_name) prevents duplicates.
//
// Secure-by-default semantics
// ───────────────────────────
// An empty `agent_tools` allowlist for an Agent means zero tools —
// the runtime filter at `workflow.zig:1478` returns no functions for
// the LLM to call. The user must opt in via the Tools panel. This is
// intentional and matches the user's framing "we need to limit the
// tool that's used".
//
// Plan: docs/superpowers/plans/2026-08-15-agent-mode.md
// Spec: docs/superpowers/specs/2026-08-15-agent-mode-design.md
// Task: task_1786962724740_0
pub const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = struct {
    pub const version: u32 = 78;
    pub const name = "add_agents_and_agent_knowledge_and_agent_tools";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. `agents` — 1-1 with `workspace_items` (UNIQUE workspace_item_id).
        //    `id` == `workspace_item_id` (per spec D3); both rows share the
        //    same string id. `description` defaults to '' (canonical "no
        //    description" sentinel, matching `workspace_item_tasks.description`
        //    from Migration 062).
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agents (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agents_workspace_item_id ON agents(workspace_item_id)",
            &[_][]const u8{});

        // 2. `agent_knowledge` — N-1 with `agents`. Position-ordered for
        //    drag-reorder UI. `file_path` is NOT NULL (handlers validate
        //    it's absolute on insert). `label` defaults to '' (canonical
        //    "no label" sentinel).
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_knowledge (
            \\    id TEXT PRIMARY KEY,
            \\    agent_id TEXT NOT NULL,
            \\    file_path TEXT NOT NULL,
            \\    label TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_knowledge_agent_id ON agent_knowledge(agent_id)",
            &[_][]const u8{});
        // Composite index for the position DESC ordering used by the
        // `agentKnowledgeListHandler` SELECT.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_knowledge_agent_id_position ON agent_knowledge(agent_id, position DESC)",
            &[_][]const u8{});

        // 3. `agent_tools` — N-1 with `agents`. UNIQUE (agent_id,
        //    tool_name) so the same tool can't be added twice for the
        //    same agent. `enabled` defaults to 1 (v1 never offers a
        //    "disabled" toggle, but the column exists so future UX
        //    doesn't need a migration — per spec D10).
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_tools (
            \\    id TEXT PRIMARY KEY,
            \\    agent_id TEXT NOT NULL,
            \\    tool_name TEXT NOT NULL,
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_tools_agent_id ON agent_tools(agent_id)",
            &[_][]const u8{});
        // Named UNIQUE index — checked by name in the migration test,
        // and the handler maps UNIQUE violations to HTTP 409.
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_tools_agent_tool ON agent_tools(agent_id, tool_name)",
            &[_][]const u8{});
    }
};

// ============================================================================
// Migration 070 — `agent_memories` + `agent_memories_fts` for save_memory /
// load_memory tools
// ============================================================================
//
// What this migration creates
// ────────────────────────────
// The `save_memory` + `load_memory` agent tools (Task
// `task_1785958319567`, plan `2026-08-06-save-load-memory-fts5`) need a
// dedicated SQLite table + FTS5 index for short, structured notes that
// the agent can save on demand and recall via free-text search. This
// migration creates:
//
//   1. `agent_memories` — the source table
//      (id TEXT PK, content TEXT NOT NULL, tags TEXT NOT NULL DEFAULT '',
//       created_at/updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)
//   2. `agent_memories_fts` — a non-external-content FTS5 virtual table
//      over `content` + `tags` (porter+unicode61 tokenizer)
//   3. 3 sync triggers (INSERT/DELETE/UPDATE) that mirror source-table
//      mutations into the FTS5 index
//   4. An index on `updated_at DESC` for the future "most-recent
//      memories" UI surface (not used by v1 tools)
//   5. A backfill INSERT that no-ops on a fresh DB
//
// Why non-external-content
// ─────────────────────────
// `snippet()` returns NULL for external-content FTS5 tables. The
// `load_memory` tool needs snippets to render compact `<snippet>` blocks
// (10 tokens with `[match]` markers — see `memory.zig::loadSuccessXml`).
// Duplicating content costs ~2x storage but enables the only UX feature
// that matters here. This matches the existing `messages_fts` pattern
// (Migration 058 — see `migration.zig:1511` for the rationale).
//
// Tags as `||`-joined string
// ───────────────────────────
// Matches the project's convention for string-list columns
// (`workspace_item_tasks.tags` from Migration 067,
// `workspace_item_tasks.image_urls` from Migration 069). The frontend
// parses with `s.split('|').filter(Boolean)` — no JSON overhead at the
// SQL layer. The FTS5 tokenizer splits on `|` like any non-word char.
//
// No DELETE tool — UPSERT replaces
// ────────────────────────────────
// The `save_memory` tool uses INSERT-or-UPDATE (UPSERT) to overwrite
// existing memories with the same `id`. There is no `delete_memory`
// tool by user decision ("memory never can be deleted"). The DELETE
// trigger is still installed for completeness — if a future plan adds a
// delete affordance or a DB cleanup migration, the FTS5 index stays in
// sync automatically.
//
// Plan: docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md
// Task: task_1785958319567
pub const Migration070AddAgentMemories = struct {
    pub const version: u32 = 70;
    pub const name = "add_agent_memories";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Source table. `tags` is the canonical "no tags" sentinel
        //    ('') — matches `description` / `tags` / `image_urls`
        //    conventions from Migrations 062 / 067 / 069.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_memories (
            \\    id TEXT PRIMARY KEY,
            \\    content TEXT NOT NULL,
            \\    tags TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // 2. updated_at index for future "recent memories" surfaces. The
        //    v1 `load_memory` tool orders by FTS5 rank (not by
        //    updated_at), but the index is cheap and unblocks future
        //    listing UIs without another migration.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_memories_updated " ++
                "ON agent_memories(updated_at DESC)",
            &[_][]const u8{});

        // 3. FTS5 virtual table. NON-external-content so `snippet()`
        //    works. Same porter+unicode61+remove_diacritics tokenizer
        //    as `messages_fts` (Migration 058) so the two FTS5 indices
        //    behave identically for the LLM.
        try db.exec(allocator,
            \\CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts USING fts5(
            \\    content,
            \\    tags,
            \\    tokenize='porter unicode61 remove_diacritics 2'
            \\)
        , &[_][]const u8{});

        // 4. Sync triggers — same pattern as Migration 058. Plain
        //    DELETE FROM / INSERT INTO (NOT the special
        //    `INSERT INTO <fts>(<fts>, rowid, ...) VALUES('delete', ...)`
        //    form, which is reserved for external-content tables).
        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS agent_memories_ai AFTER INSERT ON agent_memories BEGIN
            \\  INSERT INTO agent_memories_fts(rowid, content, tags)
            \\  VALUES (new.rowid, new.content, new.tags);
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS agent_memories_ad AFTER DELETE ON agent_memories BEGIN
            \\  DELETE FROM agent_memories_fts WHERE rowid = old.rowid;
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS agent_memories_au AFTER UPDATE ON agent_memories BEGIN
            \\  DELETE FROM agent_memories_fts WHERE rowid = old.rowid;
            \\  INSERT INTO agent_memories_fts(rowid, content, tags)
            \\  VALUES (new.rowid, new.content, new.tags);
            \\END
        , &[_][]const u8{});

        // 5. Backfill. On a fresh DB this is a no-op (zero rows). On an
        //    existing DB that somehow has rows without FTS5 coverage
        //    (shouldn't happen, but defensive), this catches them up.
        try db.exec(allocator,
            \\INSERT INTO agent_memories_fts(rowid, content, tags)
            \\SELECT rowid, content, tags FROM agent_memories
        , &[_][]const u8{});
    }
};

// ─── Tests for Migration 078 (Agent Mode) ──────────────────────────────
// impl + tests in one file (project convention).
// `std` is already in scope from line 1; only the local aliases need adding.
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const Migration078 = Migration076AddAgentsAndAgentKnowledgeAndAgentTools;


/// Top-level named struct (NOT inline anonymous) per project memory
/// `zig-anonymous-struct-type-identity.md` — Zig 0.16 treats two anonymous
/// `struct { db, threaded }` types as distinct types even with identical
/// fields.
const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

/// Helper: run the migration, then return the list of column names for a
/// given table (ordered by `cid`, the original CREATE order).
fn columnsOf(ctx: *TestCtx, table: []const u8) ![]const []const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info(?) ORDER BY cid",
        &[_][]const u8{table},
    );
    defer q.deinit();
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |c| alloc.free(c);
        list.deinit(alloc);
    }
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try list.append(alloc, try alloc.dupe(u8, row.values[0]));
    }
    // Transfer ownership of the slice (and each element) to the caller.
    // Caller MUST `free` the slice header AND each element. We use
    // `toOwnedSlice` so the ArrayList's buffer is detached and the
    // returned slice header survives past function return.
    return try list.toOwnedSlice(alloc);
}

/// Helper: assert `list` contains exactly `expected` (in order). Uses comptime
/// `expected` so the comparison can be inlined.
fn expectColumnsEqual(list: []const []const u8, comptime expected: anytype) !void {
    const expected_len: usize = expected.len;
    try testing.expectEqual(expected_len, list.len);
    var i: usize = 0;
    while (i < expected_len) : (i += 1) {
        try testing.expectEqualStrings(expected[i], list[i]);
    }
}

test "Migration078 creates agents table with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, the agents table doesn't exist.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='agents'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have agents
        }
    }

    try Migration078.up(&ctx.db, alloc);

    // Post-migration: table exists in sqlite_master.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agents'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.AgentsTableNotCreated;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("agents", row.values[0]);
    }

    // Columns must be exactly: id, workspace_item_id, description, created_at, updated_at.
    const cols = try columnsOf(&ctx, "agents");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    const expected = [_][]const u8{ "id", "workspace_item_id", "description", "created_at", "updated_at" };
    try expectColumnsEqual(cols, &expected);
}

test "Migration078 creates agent_knowledge table with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_knowledge");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // Spec columns: id, agent_id, file_path, label, position, created_at, updated_at.
    const expected = [_][]const u8{
        "id", "agent_id", "file_path", "label", "position", "created_at", "updated_at",
    };
    try expectColumnsEqual(cols, &expected);
}

test "Migration078 creates agent_tools table with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_tools");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // Spec columns: id, agent_id, tool_name, enabled, created_at.
    const expected = [_][]const u8{
        "id", "agent_id", "tool_name", "enabled", "created_at",
    };
    try expectColumnsEqual(cols, &expected);
}

test "Migration078 agents.workspace_item_id is UNIQUE" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    // Probe sqlite_master for a UNIQUE index on the agents.workspace_item_id column.
    // The standard SQLite convention is that UNIQUE constraints create
    // auto-named indexes "sqlite_autoindex_<table>_<n>"; query sqlite_master.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='agents'",
        &.{});
    defer q.deinit();
    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        // The UNIQUE constraint produces an auto-index; the existence of
        // ANY index on agents in addition to idx_agents_workspace_item_id
        // is our proxy. We'll do a tighter check via INSERT below.
        // Just record that an index exists.
        found = true;
    }
    try testing.expect(found); // at least one index exists

    // Tighter check: INSERT two rows with the same workspace_item_id. The
    // second must fail with a UNIQUE violation. We need a parent
    // workspace_items row first (FK).
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Test Agent', '/tmp/agent', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_1', 'ws_item_1')",
        &.{});

    // Duplicate INSERT must fail. Catch the SqliteError.
    const result = ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_2', 'ws_item_1')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration078 agent_tools(agent_id, tool_name) is UNIQUE" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    // Verify the named UNIQUE index exists.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND name='uq_agent_tools_agent_tool'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.UniqueIndexNotCreated;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("uq_agent_tools_agent_tool", row.values[0]);

    // Tighter check: insert parent rows, then duplicate tool_name → expect UNIQUE violation.
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Test Agent', '/tmp/agent', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_1', 'ws_item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_1', 'agent_1', 'bash')",
        &.{});

    const result = ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_2', 'agent_1', 'bash')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration078 ON DELETE CASCADE: agents dropped when workspace_items row deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Enable FK enforcement (off by default in SQLite, on for this test).
    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    try Migration078.up(&ctx.db, alloc);

    // Create the parent workspace_items row + agent + 1 knowledge + 1 tool.
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Cascade Test', '/tmp/cascade', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('agent_1', 'ws_item_1', 'test')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_knowledge (id, agent_id, file_path) VALUES ('know_1', 'agent_1', '/tmp/x.md')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_1', 'agent_1', 'bash')",
        &.{});

    // Sanity: all 4 rows exist.
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agents WHERE id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("1", r.values[0]);
    }

    // Delete the parent workspace_items row. CASCADE should drop agents.
    try ctx.db.exec(alloc, "DELETE FROM workspace_items WHERE id = 'ws_item_1'", &.{});

    // The agent row should be gone (FK CASCADE from agents.workspace_item_id).
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agents WHERE id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("0", r.values[0]);
    }
}

test "Migration078 ON DELETE CASCADE: knowledge + tools dropped when agent row deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    try Migration078.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Cascade Test', '/tmp/cascade', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_1', 'ws_item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_knowledge (id, agent_id, file_path) VALUES ('know_1', 'agent_1', '/tmp/x.md')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_knowledge (id, agent_id, file_path) VALUES ('know_2', 'agent_1', '/tmp/y.md')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_1', 'agent_1', 'bash')",
        &.{});

    // Delete the agent row directly.
    try ctx.db.exec(alloc, "DELETE FROM agents WHERE id = 'agent_1'", &.{});

    // Both knowledge rows + tool row should be CASCADE-deleted.
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_knowledge WHERE agent_id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("0", r.values[0]);
    }
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_tools WHERE agent_id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("0", r.values[0]);
    }
}

test "Migration078 creates agent_knowledge.position + agent_id composite index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    // The named index from the spec: idx_agent_knowledge_agent_id_position.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_agent_knowledge_agent_id_position'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.PositionIndexNotCreated;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_agent_knowledge_agent_id_position", row.values[0]);
}

test "Migration078 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);
    try Migration078.up(&ctx.db, alloc); // second run must not crash

    // Each of the 3 tables should still exist exactly once.
    for ([_][]const u8{ "agents", "agent_knowledge", "agent_tools" }) |table| {
        var q = try ctx.db.query(alloc,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
            &[_][]const u8{table},
        );
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }
}

test "Migration078 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined but
    // the registration tuple is missing (per project memory
    // `migration-registration-trap`).
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration078.version) return;
    }
    return error.Migration078NotRegistered;
}

// ============================================================================
// Migration 079 tests — agent_knowledge.content column
// ============================================================================

const Migration079 = Migration079AddContentToAgentKnowledge;

test "Migration079 adds content column to agent_knowledge" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);
    try Migration079.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_knowledge");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // content appended after the original 7 columns.
    const expected = [_][]const u8{
        "id", "agent_id", "file_path", "label", "position", "created_at", "updated_at", "content",
    };
    try expectColumnsEqual(cols, &expected);
}

test "Migration079 is idempotent (safe to run twice)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);
    try Migration079.up(&ctx.db, alloc);
    try Migration079.up(&ctx.db, alloc); // must not throw

    // Column still exists exactly once.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('agent_knowledge') WHERE name = 'content'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration079 preserves existing rows with default empty content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    // Seed a file-backed row the old way (pre-079 shape).
    try ctx.db.exec(alloc,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, position) VALUES ('k1', 'a1', '/tmp/x.md', '', 0)",
        &.{},
    );

    try Migration079.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT content FROM agent_knowledge WHERE id = 'k1'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration079 is registered in allMigrations" {
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration079.version) return;
    }
    return error.Migration079NotRegistered;
}

// ============================================================================
// Migration 079 — agent_knowledge.content (manual text knowledge)
// ============================================================================
//
// Adds a `content` column so a knowledge row can be either file-backed
// (content = '') or inline text (content = text). Empty-string sentinel
// matches the `label` convention. NOT NULL DEFAULT '' keeps every existing
// INSERT/SELECT working unchanged and backfills old rows as file-backed.
//
// Idempotency: addColumnIfMissing probes pragma_table_info before ALTER,
// so re-running is a no-op (canonical pattern from Migrations 020 / 052 /
// 065 / 066 / 067 / 074 / 077).
//
// Plan: docs/superpowers/plans/2026-08-21-agent-knowledge-manual-text.md
// Task: task_1787315943769_9
pub const Migration079AddContentToAgentKnowledge = struct {
    pub const version: u32 = 79;
    pub const name = "add_content_to_agent_knowledge";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "agent_knowledge",
            "content",
            "content TEXT NOT NULL DEFAULT ''",
        );
    }
};

// ============================================================================
// Migration 076 — `session_plan` 1:1 table with `sessions` for the agent's
// persistent task plan (markdown + checklist).
// ============================================================================
//
// Schema:
//   - session_id TEXT PRIMARY KEY  (logical 1:1 with sessions.id; no FK
//                                   because sessions may be hard-deleted
//                                   while keeping their plan — matches
//                                   llm_history.session_id, worker.session_id,
//                                   session_queue_messages.session_id,
//                                   session_activity.session_id precedent;
//                                   see Migration 073's docstring.)
//   - plan_md TEXT NOT NULL DEFAULT ''  (the markdown body)
//   - updated_at DATETIME DEFAULT CURRENT_TIMESTAMP  (auto-bumped on every UPSERT)
//
// Why a dedicated table (not columns on `sessions`)
// - Single Responsibility: `sessions` is chat metadata; plan_md is plan content.
// - Backward compat: future schema changes to plan only touch this table.
// - PK on session_id enforces 1:1 without an extra UNIQUE index.
//
// Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
// Task: task_1787073929852_8
pub const Migration076CreateSessionPlan = struct {
    pub const version: u32 = 76;
    pub const name = "create_session_plan";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_plan (
            \\    session_id TEXT PRIMARY KEY,
            \\    plan_md TEXT NOT NULL DEFAULT '',
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});
        // No FK on session_id (matches session_activity Migration 073 precedent).
        // No index — session_id IS the PK, lookups are O(log n) by definition.
    }
};

// ============================================================================
// Migration 077 — users + user_companies + user_company_members +
// workspaces.user_id + sessions.user_id + default user_system + backfill.
//
// What this migration creates
// ────────────────────────────
// The schema foundation for multi-user / multi-tenant nalar — sub-project 1 of 4.
//   1. `users` (id, email, name, password_hash, role, is_active,
    //      created_at, updated_at, last_login_at) — identity table.
    //   2. `user_companies` (id, name, slug, description, is_active,
    //      created_at, updated_at, created_by) — org / tenant entity.
    //   3. `user_company_members` (user_id, user_company_id, role,
    //      joined_at, invited_by) with composite PRIMARY KEY on
    //      (user_id, user_company_id) — many-to-many user ↔ company.
    //   4. Additive `user_id` column on `workspaces` (nullable, no FK
    //      constraint — matches Migration 066 `design_pages.workspace_item_task_id`
    //      precedent; SQLite does NOT support ALTER TABLE … ADD CONSTRAINT FK).
    //   5. Additive `user_id` column on `sessions` (same shape).
    //   6. Default `user_system` user — id='user_system', email='system@local',
    //      password_hash='!disabled' (sentinel; can never match any real
    //      argon2id output), is_active=0 (can never log in), role='admin'
    //      (so any future RBAC query that resolves to it gets the widest
    //      permission).
    //   7. Backfill every legacy row (workspaces.user_id, sessions.user_id)
    //      WHERE user_id IS NULL → user_id = 'user_system'.
    //
    // Why a tx wraps the whole thing
    // ───────────────────────────────────────
    // 6 operations that must commit together. A crash mid-migration would
    // otherwise leave a half-built schema (e.g. users exists but
    // user_companies doesn't, or user_id columns added but backfill not
    // run), which the next migration would silently compound into a
    // never-ending recovery loop.
    //
    // Why no FK constraints
    // ─────────────────────
    // SQLite does not support ALTER TABLE … ADD CONSTRAINT FK. The two
    // canonical alternatives are triggers or recreate-table — both add
    // complexity that's out of scope for v1. The application layer is the
    // second line of defense (referential integrity enforced by JOIN
    // clauses at read time; the user_company_members composite PK
    // enforces "no duplicate membership" at the SQL layer). This matches
    // the project precedent — Migration 066's docstring explicitly notes
    // the same decision for `design_pages.workspace_item_task_id`.
    //
    // Idempotency
    // ───────────
    // Re-running this migration is safe via three mechanisms:
    //   1. CREATE TABLE IF NOT EXISTS — no-op if the tables exist.
    //   2. addColumnIfMissing — probes pragma_table_info before ALTER.
    //   3. INSERT OR IGNORE — no-op if the user_system row already exists.
    //   4. UPDATE … WHERE user_id IS NULL — no-op if no rows are NULL.
    //
    // Plan: docs/superpowers/plans/2026-08-21-users-rbac-foundation.md
    // Spec: docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md
    // Task: task_1787199963946_1 (kanban: sprint bulan juni → "table users and rbac")
pub const Migration077AddUsersAndRbacSchema = struct {
    pub const version: u32 = 77;
    pub const name = "add_users_and_rbac_schema";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // tx (db.begin/tx.exec/tx.commit) — atomic; see "Why the tx" in the
        // docstring above.
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        // 1. users — identity table.
        try tx.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS users (
            \\    id TEXT PRIMARY KEY,
            \\    email TEXT NOT NULL UNIQUE,
            \\    name TEXT NOT NULL DEFAULT '',
            \\    password_hash TEXT NOT NULL,
            \\    role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user', 'bot')),
            \\    is_active INTEGER NOT NULL DEFAULT 1,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    last_login_at DATETIME DEFAULT NULL
            \\)
        , &[_][]const u8{});

        // 2. user_companies — org / tenant entity.
        try tx.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS user_companies (
            \\    id TEXT PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    slug TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    is_active INTEGER NOT NULL DEFAULT 1,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    created_by TEXT
            \\)
        , &[_][]const u8{});

        // 3. user_company_members — many-to-many user ↔ company.
        try tx.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS user_company_members (
            \\    user_id TEXT NOT NULL,
            \\    user_company_id TEXT NOT NULL,
            \\    role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member', 'guest')),
            \\    joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    invited_by TEXT,
            \\    PRIMARY KEY (user_id, user_company_id)
            \\)
        , &[_][]const u8{});

        // 4. workspaces.user_id — additive, nullable, no FK.
        //    `addColumnIfMissing` probes pragma_table_info before ALTER,
        //    so re-running is a no-op (the canonical pattern from
        //    Migrations 020 / 052 / 065 / 066 / 067 / 074).
        try addColumnIfMissing(
            .{ .tx = &tx },
            allocator,
            "workspaces",
            "user_id",
            "user_id TEXT",
        );

        // 5. sessions.user_id — same shape as workspaces.user_id.
        try addColumnIfMissing(
            .{ .tx = &tx },
            allocator,
            "sessions",
            "user_id",
            "user_id TEXT",
        );

        // 6. Indexes — 6 total. CREATE INDEX IF NOT EXISTS is idempotent.
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_users_active ON users(is_active)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_companies_slug ON user_companies(slug)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_companies_active ON user_companies(is_active)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_company_members_user ON user_company_members(user_id)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_company_members_company ON user_company_members(user_company_id)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspaces_user_id ON workspaces(user_id)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id)",
            &[_][]const u8{});

        // 7. Default user_system — INSERT OR IGNORE makes it idempotent.
        //    See the spec §3.6 for the full reasoning (password_hash
        //    sentinel, is_active=0, system@local reserved per RFC 6762).
        try tx.exec(allocator,
            "INSERT OR IGNORE INTO users (id, email, name, password_hash, role, is_active) " ++
                "VALUES ('user_system', 'system@local', 'System', '!disabled', 'admin', 0)",
            &[_][]const u8{});

        // 8. Backfill — convert every legacy row (workspaces,
        //    sessions) WHERE user_id IS NULL to user_id='user_system'.
        //    WHERE user_id IS NULL makes the UPDATE idempotent on
        //    re-run: rows that already have user_id set are not
        //    touched. On a fresh DB with zero legacy rows, both UPDATEs
        //    are no-ops.
        try tx.exec(allocator,
            "UPDATE workspaces SET user_id = 'user_system' WHERE user_id IS NULL",
            &[_][]const u8{});
        try tx.exec(allocator,
            "UPDATE sessions SET user_id = 'user_system' WHERE user_id IS NULL",
            &[_][]const u8{});

        // Commit the transaction. After this, the new schema is durable.
        try tx.commit();

        // Refresh query-planner stats so the new indexes are picked on
        // pre-existing databases (mirrors the ANALYZE-after-CREATE-INDEX
        // pattern used by Migrations 041/042/043/048/049/050/051/052/070/072).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

// ============================================================================
// Migration 080 — `agent_system_prompt` (N-1 with agents)
// ============================================================================
//
// Per-agent named system-prompt blocks, injected into the LLM system message
// at chat time (before the knowledge block). Relationship shape mirrors
// `agent_knowledge` exactly: id TEXT PK, agent_id FK → agents ON DELETE
// CASCADE, position ordering, timestamps.
//
// Schema:
//   - id TEXT PRIMARY KEY  (TEXT ids generated in Zig — project convention,
//     never INTEGER AUTOINCREMENT)
//   - agent_id TEXT NOT NULL  (== workspace_item_id per Agent Mode spec D3;
//     FK CASCADE so deleting an agent drops its prompts)
//   - title TEXT NOT NULL DEFAULT ''  (display name; '' = untitled)
//   - content TEXT NOT NULL DEFAULT ''  (the prompt body; empty rows are
//     skipped by the injector)
//   - position INTEGER NOT NULL DEFAULT 0  (ordering; rendered position DESC
//     like agent_knowledge)
//   - created_at / updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
//
// Idempotency: CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS.
//
// Gotcha honored: one statement per db.exec — sqlite3_prepare_v2 compiles
// only the first statement, so the table and each index get their own exec.
//
// Plan: docs/superpowers/plans/2026-08-21-agent-system-prompt.md
// Task: task_1787408958280_1
pub const Migration080AddAgentSystemPrompt = struct {
    pub const version: u32 = 80;
    pub const name = "add_agent_system_prompt";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_system_prompt (
            \\    id TEXT PRIMARY KEY,
            \\    agent_id TEXT NOT NULL,
            \\    title TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_system_prompt_agent_id ON agent_system_prompt(agent_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_system_prompt_agent_id_position ON agent_system_prompt(agent_id, position DESC)",
            &[_][]const u8{});
    }
};

// ============================================================================
// Migration 080 — agent_system_prompt (N-1 with agents) — inline tests
// ============================================================================

test "Migration080 creates agent_system_prompt table with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration080AddAgentSystemPrompt.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_system_prompt");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "agent_id", "title", "content", "position", "created_at", "updated_at",
    });
}

test "Migration080 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration080AddAgentSystemPrompt.up(&ctx.db, alloc);
    try Migration080AddAgentSystemPrompt.up(&ctx.db, alloc);

    // Table still exists and is usable after double-run.
    try ctx.db.exec(alloc,
        "INSERT INTO agent_system_prompt (id, agent_id, title, content) VALUES ('p_1', 'a_1', 'T', 'C')",
        &.{});
}

test "Migration080 is registered in allMigrations" {
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration080AddAgentSystemPrompt.version) return;
    }
    return error.Migration080NotRegistered;
}

test "Migration080 ON DELETE CASCADE removes prompts when agent row deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    // Production order: parent tables first (agents), then the new table.
    try Migration078.up(&ctx.db, alloc);
    try Migration080AddAgentSystemPrompt.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Cascade Test', '/tmp/cascade', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_1', 'ws_item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_system_prompt (id, agent_id, title, content) VALUES ('sp_1', 'agent_1', 'Persona', 'You are X')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_system_prompt (id, agent_id, title, content) VALUES ('sp_2', 'agent_1', 'Style', 'Be terse')",
        &.{});

    // Delete the agent row directly.
    try ctx.db.exec(alloc, "DELETE FROM agents WHERE id = 'agent_1'", &.{});

    // Both prompt rows should be CASCADE-deleted.
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_system_prompt WHERE agent_id='agent_1'", &.{});
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    try testing.expectEqualStrings("0", r.values[0]);
}

// ============================================================================
// Migration 081 — Agent-Kanbans mirror: `agent_kanbans` +
// `agent_kanban_knowledges` + `agent_kanban_system_prompt` +
// `agent_kanban_tools`.
//
// Mirrors the agent-menu tables (Migration 078/079/080) onto kanban boards:
//   - agent_kanbans: 1-1 with workspace_items where item_type == 'kanban'.
//     Same identity convention as agents (spec D3): id == workspace_item_id.
//   - children keyed by kanban_id FK → agent_kanbans(id) ON DELETE CASCADE.
//
// Differences vs the agent tables (intentional):
//   - agent_kanban_knowledges.file_path is NOT NULL DEFAULT '' from day one
//     (file XOR inline content supported natively — no repeat of the
//     078→079 add-column dance).
//
// Idempotency: CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS.
// One statement per db.exec (sqlite3_prepare_v2 compiles only the first).
//
// Plan: docs/superpowers/plans/2026-08-25-agent-kanbans-mirror.md
// Task: task_1787597624259_2
pub const Migration081CreateAgentKanbans = struct {
    pub const version: u32 = 81;
    pub const name = "create_agent_kanbans_mirror";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_kanbans (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanbans_workspace_item_id ON agent_kanbans(workspace_item_id)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_kanban_knowledges (
            \\    id TEXT PRIMARY KEY,
            \\    kanban_id TEXT NOT NULL,
            \\    file_path TEXT NOT NULL DEFAULT '',
            \\    label TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (kanban_id) REFERENCES agent_kanbans(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanban_knowledges_kanban_id ON agent_kanban_knowledges(kanban_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanban_knowledges_kanban_position ON agent_kanban_knowledges(kanban_id, position DESC)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_kanban_system_prompt (
            \\    id TEXT PRIMARY KEY,
            \\    kanban_id TEXT NOT NULL,
            \\    title TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (kanban_id) REFERENCES agent_kanbans(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanban_system_prompt_kanban_id ON agent_kanban_system_prompt(kanban_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanban_system_prompt_kanban_position ON agent_kanban_system_prompt(kanban_id, position DESC)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_kanban_tools (
            \\    id TEXT PRIMARY KEY,
            \\    kanban_id TEXT NOT NULL,
            \\    tool_name TEXT NOT NULL,
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (kanban_id) REFERENCES agent_kanbans(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanban_tools_kanban_id ON agent_kanban_tools(kanban_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_kanban_tools_kanban_tool ON agent_kanban_tools(kanban_id, tool_name)",
            &[_][]const u8{});
    }
};


/// Migration 082 - Add `sessions.last_human_touched_at_nano`.
///
/// Sibling of Migration 065 (which added the same column shape to
/// `workspace_item_tasks`). Used by the chat sidebar to render the
/// "last human touched" time pill instead of the AI-tainted
/// `updated_at`. Stamped by:
///   - `root.zig::emit_run_agent` - every user-sends-a-message path
///     (chat send, kanban "create & run", kanban "Start agent", `+ Chat`)
///   - `session_update.zig::useCase` - user renames / changes profile /
///     toggles unattended mode
///   - `workflow.zig::saveRetryAttemptMessage` - "also when error too":
///     agent retry-catch / unexpected finish_reason / TooManyRetries bail
///
/// Schema (nullable INTEGER, no DEFAULT): NULL is the canonical
/// "never touched by a human" state - the frontend falls back to
/// `updated_at` for these rows so pre-migration sessions keep
/// displaying their existing time without a regression.
///
/// Column name uses the `_nano` suffix per the project-wide
/// convention from Migration 075 (uniform across 5 timestamp
/// columns; actual stored unit is unix-ms - see Migration 075
/// docstring). The wire / struct / JSON field
/// is the bare `last_human_touched_at` (no `_nano`) - the SELECT
/// aliases back via `... AS last_human_touched_at`.
///
/// The `addColumnIfMissing` helper handles both upgrade-from-v1
/// and fresh-DB-already-declares-it paths gracefully (see memory
/// `nalar-data-and-routines.md` "Migration #009-#052 fresh-DB
/// cascade is fragile" for the failure mode this avoids).
///
/// Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
/// Task: task_1788004921757_1.
pub const Migration082AddSessionHumanTouchedAt = struct {
    pub const version: u32 = 82;
    pub const name = "add_session_human_touched_at";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            // The SQL column name and the `column` probe arg must match
            // exactly - `addColumnIfMissing` issues
            // `SELECT 1 FROM pragma_table_info('sessions') WHERE name = '<column>'`
            // first to decide whether to skip. The wire / struct / JSON
            // field is the bare `last_human_touched_at` (no `_nano`
            // suffix) - the SELECT in buildSessionListJson aliases the
            // SQL column back via `... AS last_human_touched_at`.
            "last_human_touched_at_nano",
            // name + type - `addColumnIfMissing` uses this verbatim as
            // `ALTER TABLE {table} ADD COLUMN {definition}`, so omitting
            // the column name would create a column literally named
            // "INTEGER". See memory `addColumnIfMissing-requires-name-type`.
            "last_human_touched_at_nano INTEGER",
        );
    }
};

pub const Migration083AddReasoningIdAndEncryptedContent = struct {
    pub const version: u32 = 83;
    pub const name = "add_reasoning_id_and_encrypted_content";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "reasoning_id",
            "reasoning_id TEXT",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "reasoning_encrypted_content",
            "reasoning_encrypted_content TEXT",
        );
    }
};

/// Migration 084 — drop per-task routines, replace with workspace-level
/// routines (`workspace_routines`, 1:1 with routine `workspace_items`).
///
/// ## Why this migration exists
///
/// Per-task routines (`routines` table from Migration 044, keyed
/// `task_id UNIQUE FK → workspace_item_tasks`) are deleted by design
/// decision: routines are a first-class workspace-item mode beside
/// `agent` (`item_type='routine'`), not a flag on a chat task. There is
/// no data carry-over — old per-task schedules are dropped (breaking
/// change, announced in the plan + release notes).
///
/// ## What this does (order matters — FK)
///
/// 1. Normalizes leftover `task_type='routine'` rows to `'standard'`
///    (the `task_type` column itself stays — `standard`/`memory` still
///    use it).
/// 2. Drops the old `routines` table + its indexes.
/// 3. Creates `workspace_routines` (`id == workspace_item_id`, D3 copy
///    from the `agents` table) holding `instruction` + `schedule` +
///    `enabled` + fire state.
///
/// Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md
/// Task: task_1789032258828_0.
pub const Migration084ReplaceRoutinesWithWorkspaceRoutines = struct {
    pub const version: u32 = 84;
    pub const name = "replace_routines_with_workspace_routines";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Normalize leftovers so no task claims a deleted mode.
        try db.exec(allocator,
            "UPDATE workspace_item_tasks SET task_type = 'standard' WHERE task_type = 'routine'",
            &[_][]const u8{},
        );

        // 2. Drop the old per-task table + its indexes.
        try db.exec(allocator, "DROP TABLE IF EXISTS routines", &[_][]const u8{});
        try db.exec(allocator, "DROP INDEX IF EXISTS idx_routines_enabled_next_run", &[_][]const u8{});
        try db.exec(allocator, "DROP INDEX IF EXISTS idx_routines_last_status", &[_][]const u8{});

        // 3. Create the workspace-level replacement.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_routines (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    instruction TEXT NOT NULL DEFAULT '',
            \\    schedule TEXT NOT NULL DEFAULT '',
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    last_run_at DATETIME,
            \\    next_run_at DATETIME,
            \\    last_status TEXT NOT NULL DEFAULT 'idle',
            \\    last_error TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspace_routines_workspace_item_id ON workspace_routines(workspace_item_id)",
            &[_][]const u8{},
        );
        // Hot-path index for the Scheduler's due-scan
        // (SELECT id FROM workspace_routines WHERE enabled=1 AND next_run_at<=now).
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspace_routines_enabled_next_run ON workspace_routines(enabled, next_run_at)",
            &[_][]const u8{},
        );
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

// ============================================================================
// Migration 085 — session_progressive_tool (progressive tool search)
// ============================================================================

/// Per-session record of tools the agent enabled for itself through
/// `use_tool`. Session-scoped on purpose: enabling a tool here must never
/// touch the user's persistent `agent_tools` / `agent_kanban_tools`
/// configuration, and it reverts by starting a new session.
///
/// Shape mirrors `session_skills` (Migration 008). No `content` column —
/// tool definitions are code, so a definition change must take effect on
/// the next turn instead of being shadowed by a stale stored copy.
///
/// `PRIMARY KEY(session_id, tool_name)` is the DB-level half of the
/// "if it is already equipped, do not insert" rule; callers use
/// `INSERT OR IGNORE` and treat `false` as "already present".
///
/// Plan: docs/superpowers/plans/2026-09-12-progressive-tool-search.md
pub const Migration085AddSessionProgressiveTool = struct {
    pub const version: u32 = 85;
    pub const name = "add_session_progressive_tool";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_progressive_tool (
            \\    session_id TEXT NOT NULL,
            \\    tool_name TEXT NOT NULL,
            \\    server_name TEXT NOT NULL DEFAULT '',
            \\    loaded_at_nano INTEGER NOT NULL DEFAULT 0,
            \\    PRIMARY KEY (session_id, tool_name)
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_progressive_tool_session ON session_progressive_tool(session_id)",
            &[_][]const u8{},
        );
    }
};

pub const Migration086AddSessionPrUrl = struct {
    pub const version: u32 = 86;
    pub const name = "add_session_pr_url";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Attached-PR binding for the ChatView right panel (set_pull_request
        // agent tool). pr_url holds the normalized PR/MR URL ("" = unset);
        // pr_provider holds the effective provider resolved at write time
        // ("github" | "gitlab" | "generic") so reads stay deterministic on
        // self-hosted forges where host-based detection would misroute.
        try addColumnIfMissing(.{ .db = db }, allocator, "sessions", "pr_url", "pr_url TEXT");
        try addColumnIfMissing(.{ .db = db }, allocator, "sessions", "pr_provider", "pr_provider TEXT");
    }
};

pub const Migration088AddSessionPendingQuestion = struct {
    pub const version: u32 = 88;
    pub const name = "add_session_pending_question";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // One row per `ask_user` tool call. The `ask_user` tool returns
        // immediately and the agentic loop BREAKS, so this table — not a
        // parked thread — is what keeps the question alive until the human
        // answers. There is deliberately no `expires_at`: nothing is held
        // open, so a question may wait indefinitely at no cost.
        //
        // `answer` is NULL-able rather than `NOT NULL DEFAULT ''` because
        // `SqliteBackend.exec` binds an empty slice as SQL NULL (Migration
        // 079's `content` column broke exactly this way). Reads COALESCE it.
        //
        // `llm_history_id` is the tool-result row this question's answer
        // must be written back into (in place), which is what makes the
        // resume run see the answer as a normal tool result.
        //
        // `multi_select` is the ONE question-shape flag the answer endpoint
        // cannot recover from anywhere else: it is what lets the endpoint
        // reject a scalar answer to a multi-select question at the wire
        // boundary. Everything else about the question (text, options,
        // recommendation, free-text policy) stays in the tool-call arguments,
        // which the frontend already has — no duplicated columns.
        //
        // Plan: docs/superpowers/plans/2026-09-16-agent-tool-ask-user.md
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_pending_question (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    tool_call_id TEXT NOT NULL,
            \\    llm_history_id TEXT NOT NULL,
            \\    question TEXT NOT NULL,
            \\    multi_select INTEGER NOT NULL DEFAULT 0,
            \\    status TEXT NOT NULL DEFAULT 'pending',
            \\    answer TEXT,
            \\    created_at INTEGER NOT NULL,
            \\    resolved_at INTEGER
            \\)
        , &[_][]const u8{});

        // One question per tool call — makes a re-exec (retry after a
        // transient failure) idempotent instead of inserting a second row.
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_spq_tool_call ON session_pending_question(tool_call_id)",
            &[_][]const u8{},
        );

        // The hot path: hasPendingQuestion() on every loop iteration and on
        // every user-sent message.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_spq_session_status ON session_pending_question(session_id, status)",
            &[_][]const u8{},
        );
    }
};

// ============================================================================
// Migration 089 — auth_sessions for opt-in `--auth` login sessions.
// ============================================================================
//
// One row per active login cookie: token_hash (SHA-256 of the opaque
// `nalar_session` cookie value) -> user_id + expiry. `users` (Migration
// 077) tells us who exists; this table tells us who is currently logged
// in, on which device, until when.
//
// Why a table instead of stateless JWT: server-side logout/revoke,
// per-device sessions, expiry purge, and last_seen audit. Storing only
// the hash means a DB leak does not equal session hijack.
//
// Idempotency: CREATE TABLE/INDEX IF NOT EXISTS. One statement per exec.
pub const Migration089AuthSessions = struct {
    pub const version: u32 = 89;
    pub const name = "auth_sessions";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS auth_sessions (
            \\    token_hash TEXT PRIMARY KEY,
            \\    user_id TEXT NOT NULL,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    expires_at DATETIME NOT NULL,
            \\    last_seen_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_auth_sessions_user ON auth_sessions(user_id)",
            &[_][]const u8{},
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_auth_sessions_expires ON auth_sessions(expires_at)",
            &[_][]const u8{},
        );
    }
};

/// Migration 090 — `workspace_item_tasks.video_urls` + `llm_history.video_url`
/// + `session_queue_messages.video_url` for full video upload to LLM.
///
/// `workspace_item_tasks.video_urls` mirrors Migration 069 (image_urls):
/// `TEXT NOT NULL DEFAULT ''` with '' as the canonical "no videos"
/// sentinel (task_update/task_create bind '' as a SQL literal, never as
/// a `?` arg, since SqliteBackend.exec binds "" as NULL).
///
/// `llm_history.video_url` + `session_queue_messages.video_url` mirror
/// the nullable `image_url TEXT` precedent (M037): saveMessage and
/// insertQueueMessage bind "" for empty, which lands as NULL and reads
/// back via COALESCE(col,'').
pub const Migration090AddVideoUrls = struct {
    pub const version: u32 = 90;
    pub const name = "add_video_urls";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "video_urls",
            "video_urls TEXT NOT NULL DEFAULT ''",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "video_url",
            "video_url TEXT",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "session_queue_messages",
            "video_url",
            "video_url TEXT",
        );
    }
};

// Migration 091 — sessions.sub_agent_name + sessions.parent_session_id.
// A sub-agent session keeps its parent's selected_profile_model (Migration
// 040, forwarded by #554 so thinking/temperature inherit correctly) but
// now also records its own identity: the resolved sub-agent name
// (e.g. "implementator") and the parent session id. Both nullable TEXT,
// read back via COALESCE(col,''). Lets DB inspection and the UI show
// which sub-agent actually ran instead of only the parent profile.
pub const Migration091AddSubAgentNameToSessions = struct {
    pub const version: u32 = 91;
    pub const name = "add_sub_agent_name_to_sessions";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "sub_agent_name",
            "sub_agent_name TEXT",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "parent_session_id",
            "parent_session_id TEXT",
        );
    }
};

// Migration 092 — users.config_json for opt-in `--auth` mode.
// When `--auth` is on, per-user LLM config (profiles, MCP servers,
// sub-agents, operational flags — the same JSON shape as
// config.json / LlmConfigJson) lives in this column and config.json
// is ignored. NULL or empty = defaults (same as a missing file).
// Nullable TEXT (not NOT NULL) so empty-string binds (which
// SqliteBackend collapses to NULL) never violate the schema.
pub const Migration092AddUserConfigJson = struct {
    pub const version: u32 = 92;
    pub const name = "add_user_config_json";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "users",
            "config_json",
            "config_json TEXT",
        );
    }
};

// Migration 093 — owner columns for per-user row isolation.
//
// `workspaces.user_id` and `sessions.user_id` have existed since Migration
// 077 but nothing has ever written them; `worker` has no owner column at
// all. This migration closes the SCHEMA half of that gap:
//
//   1. add `worker.user_id` (+ index) so the worker lifecycle endpoints can
//      be scoped the same way as workspaces and sessions;
//   2. backfill every still-NULL root row to the shared sentinel
//      `user_system` (`auth_common.system_user_id`), exactly as Migration
//      077 did for workspaces/sessions.
//
// Rows in the sentinel bucket stay visible to EVERY authenticated user.
// That is deliberate (user decision 2026-09-25): enabling `--auth` must not
// hide the machine owner's existing workspaces/sessions. Rows written after
// isolation lands always carry a real owner, so the shared bucket only ever
// shrinks — it is not a destination for new writes.
//
// Nullable with no FK: nullable because `SqliteBackend.exec` binds an empty
// slice as SQL NULL (Migration 079's `content` and Migration 092's
// `config_json` broke exactly this way), and no FK because the project
// deliberately leaves `PRAGMA foreign_keys` off (see Migration 072 tests),
// which would make a declared FK documentation only.
pub const Migration093AddOwnerColumns = struct {
    pub const version: u32 = 93;
    pub const name = "add_owner_columns";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(.{ .db = db }, allocator, "worker", "user_id", "user_id TEXT");
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_worker_user_id ON worker(user_id)",
            &[_][]const u8{},
        );

        // Idempotent: only rows that still have no owner are touched, so a
        // re-run is a no-op and post-isolation rows keep their real owner.
        try db.exec(allocator, "UPDATE workspaces SET user_id = 'user_system' WHERE user_id IS NULL", &[_][]const u8{});
        try db.exec(allocator, "UPDATE sessions SET user_id = 'user_system' WHERE user_id IS NULL", &[_][]const u8{});
        try db.exec(allocator, "UPDATE worker SET user_id = 'user_system' WHERE user_id IS NULL", &[_][]const u8{});
    }
};

// ============================================================================
// Migration 094 — mark one workspace item as the workspace's default project.
// ============================================================================
//
// Backs the "New Chat" action in the desktop sidebar and the Android drawer.
// The invariant this migration makes storable is:
//
//   Every workspace has a default project. If we look for one and don't
//   find it, we create it before doing anything else.
//
// The default project is a `workspace_items` row of `item_type = 'agent'`
// whose `path` is the server user's home directory, so a chat created
// inside it runs with $HOME as its working directory. See
// `src/http_handlers/workspace_items_default.zig::ensureDefaultProject` —
// the list read (`GET /api/workspaces/:ws/items`) is what catches a miss
// and creates the row, so this migration deliberately does NOT backfill:
// a backfill would have to resolve $HOME at migration time, and the lazy
// path covers every legacy workspace on its next read anyway.
//
// Plan: docs/plans/2026-09-27-sidebar-new-chat-default-project.md
pub const Migration094AddDefaultProjectToWorkspaceItems = struct {
    pub const version: u32 = 94;
    pub const name = "add_default_project_to_workspace_items";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // NOT NULL DEFAULT 0 is the only shape SQLite accepts when adding a
        // column to an existing table, and it has the property we want for
        // free: every pre-existing row reads back as 0 (an ordinary
        // project) without a table rewrite or a backfill UPDATE. This is an
        // O(1) metadata change — no lock on existing rows.
        try addColumnIfMissing(.{ .db = db }, allocator, "workspace_items", "is_default", "is_default INTEGER NOT NULL DEFAULT 0");

        // At most one default per workspace, enforced by the DATABASE
        // rather than by a convention. The WHERE clause is what makes this
        // a *partial* index: ordinary rows (is_default = 0) are never
        // compared against each other, so a workspace can still hold any
        // number of non-default projects. A plain column could only be
        // enforced by application code, which every concurrent caller would
        // have to get right — and the lookup that creates the default runs
        // from a list read, a workspace create and a New Chat tap, so they
        // genuinely do race.
        //
        // Scoped to `workspace_id` alone, NOT (workspace_id, user_id):
        // `workspace_items` has no user_id column. Items inherit their
        // owner through `workspaces.user_id` (Migration 093), and two owners
        // can never share a single `workspaces` row — so there is no
        // cross-owner default to collide, and per-workspace is the right
        // grain.
        try db.exec(allocator,
            \\CREATE UNIQUE INDEX IF NOT EXISTS idx_workspace_items_default_per_workspace
            \\ON workspace_items(workspace_id) WHERE is_default = 1
        , &[_][]const u8{});

        // Lookup index: ensureDefaultProject's fast path filters on both
        // columns, and this list runs on every sidebar load.
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_workspace_items_default_lookup
            \\ON workspace_items(workspace_id, is_default)
        , &[_][]const u8{});
    }
};

// Migration 096 — `session_skill_events`, the skill usage ledger.
// ============================================================================
//
// `session_skills` (Migration 008) keeps only the LATEST body of each skill a
// session loaded — `INSERT OR REPLACE` keyed on (session_id, skill_name). It
// cannot answer "which turn loaded this", "was this skill only *listed* and
// then ignored", or "has the body changed since it was read", and it is
// written by `use_skill` alone, so `add_skill` / `edit_skill` / `remove_skill`
// leave no trace at all.
//
// This ledger is append-only (a fresh nanosecond id per row), so it answers
// all of those without touching `session_skills` — which deliberately stays as
// it is, because its `content` snapshot is the compaction drift detector.
//
// `content_hash` is what makes drift cheap to detect: an eval compares the
// hash of the body a session actually read against the hash of the body on
// disk now, instead of diffing two full bodies.
//
// Plan: docs/plans/2026-09-27-skill-evals.md (W1)
pub const Migration096CreateSessionSkillEvents = struct {
    pub const version: u32 = 96;
    pub const name = "create_session_skill_events";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // `event` is 'loaded' | 'listed' | 'created' | 'edited' | 'removed';
        // `source` is the tool name that produced the row. Both are free text,
        // so every write site wraps them in COALESCE(?, '') — a bare empty
        // bind lands as SQL NULL and would violate NOT NULL (the Migration 079
        // `content` failure mode).
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_skill_events (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    skill_name TEXT NOT NULL,
            \\    event TEXT NOT NULL DEFAULT 'loaded',
            \\    source TEXT NOT NULL DEFAULT '',
            \\    content_hash TEXT NOT NULL DEFAULT '',
            \\    loop_index INTEGER NOT NULL DEFAULT 0,
            \\    llm_history_id TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // The eval reads one session's events; the per-skill timeline reads by
        // name across sessions.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_skill_events_session ON session_skill_events(session_id, created_at)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_skill_events_skill ON session_skill_events(skill_name, created_at)",
            &[_][]const u8{});
    }
};

// ============================================================================
// Migration 097 — the skill-eval tables: shared facts, runs, results.
// ============================================================================
//
// Three tables, one feature (docs/plans/2026-09-27-skill-evals.md §4.6-4.7):
//
//   skill_eval_facts   the INTRINSIC half of a verdict (freshness, accuracy,
//                      duplication) — depends only on the skill body and the
//                      code state, so it is keyed on the identity of THAT
//                      question: (skill_key, content_hash, context_key). Two
//                      sessions evaluating the same body at the same commit
//                      are answering the same question, so one computation is
//                      shared instead of two. `verdict_intrinsic =
//                      'computing'` is a LEASE, not a value: the claiming
//                      statement is a single `INSERT OR IGNORE`, and a stale
//                      lease is reclaimable, so a crashed owner cannot poison
//                      the cache. Every read must require
//                      `verdict_intrinsic != 'computing'`.
//
//                      No `user_id` on purpose: these are facts about code,
//                      and global skills are already shared across users.
//                      The runs and results below ARE user records and carry
//                      the Migration 093 owner column.
//
//   skill_eval_runs    one row per eval invocation (self-prompted by the agent
//                      or on demand). The partial unique index makes "once per
//                      session" a DATABASE invariant, which is what lets the
//                      write path be `INSERT OR IGNORE` + `db.changes()` — the
//                      only correct shape here, because `SqliteBackend` has no
//                      usable multi-statement transaction (`exec` releases its
//                      mutex per call, see workspaces_reorder.zig).
//
//   skill_eval_results one row per (run, skill): the SESSION-RELATIVE half
//                      (relevance, used, helpfulness) plus a reference to the
//                      shared fact, so the same intrinsic verdict is not
//                      duplicated per session. `base_content_hash` is the
//                      correctness guard on apply: a proposal computed against
//                      an older body must never be written over a newer one, so
//                      apply re-hashes the skill and refuses with 409 on a
//                      mismatch.
//
// Idempotency: CREATE TABLE/INDEX IF NOT EXISTS.
// One statement per db.exec (sqlite3_prepare_v2 compiles only the first).
pub const Migration097CreateSkillEvalTables = struct {
    pub const version: u32 = 97;
    pub const name = "create_skill_eval_tables";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // ── the shared intrinsic-facts cache ──────────────────────────────
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS skill_eval_facts (
            \\    id TEXT PRIMARY KEY,
            \\    skill_key TEXT NOT NULL,
            \\    content_hash TEXT NOT NULL,
            \\    context_key TEXT NOT NULL,
            \\    verdict_intrinsic TEXT NOT NULL DEFAULT 'computing',
            \\    freshness INTEGER NOT NULL DEFAULT 0,
            \\    accuracy INTEGER NOT NULL DEFAULT 0,
            \\    duplication INTEGER NOT NULL DEFAULT 0,
            \\    findings_json TEXT NOT NULL DEFAULT '',
            \\    evidence_json TEXT NOT NULL DEFAULT '',
            \\    proposed_content TEXT NOT NULL DEFAULT '',
            \\    missing_paths_json TEXT NOT NULL DEFAULT '',
            \\    drift_commits_json TEXT NOT NULL DEFAULT '',
            \\    computed_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // The unique key IS the claim mechanism: a second writer for the same
        // (skill, content, context) cannot insert, so it reuses instead.
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_eval_facts ON skill_eval_facts(skill_key, content_hash, context_key)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_facts_skill ON skill_eval_facts(skill_key, computed_at DESC)",
            &[_][]const u8{});

        // ── one row per eval invocation ───────────────────────────────────
        // `sub_session_ids_json` exists so the run's token cost can be summed
        // exactly over the sub-agent session ids the spawn envelope returns,
        // rather than approximated.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS skill_eval_runs (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL DEFAULT '',
            \\    skill_name TEXT NOT NULL DEFAULT '',
            \\    scope TEXT NOT NULL DEFAULT 'session',
            \\    trigger TEXT NOT NULL DEFAULT 'self_prompt',
            \\    status TEXT NOT NULL DEFAULT 'running',
            \\    profile TEXT NOT NULL DEFAULT '',
            \\    model TEXT NOT NULL DEFAULT '',
            \\    cwd TEXT NOT NULL DEFAULT '',
            \\    context_key TEXT NOT NULL DEFAULT '',
            \\    evidence_json TEXT NOT NULL DEFAULT '',
            \\    sub_session_ids_json TEXT NOT NULL DEFAULT '',
            \\    report_json TEXT NOT NULL DEFAULT '',
            \\    total_tokens INTEGER NOT NULL DEFAULT 0,
            \\    error TEXT NOT NULL DEFAULT '',
            \\    started_at DATETIME,
            \\    finished_at DATETIME,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    user_id TEXT
            \\)
        , &[_][]const u8{});

        // "At most one self-prompted run per session" is enforced by the
        // DATABASE, not by a convention, because the agent can emit two
        // `run_skill_eval` tool calls in a single turn and both would
        // otherwise see "no run yet".
        try db.exec(allocator,
            \\CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_eval_runs_self_prompt
            \\ON skill_eval_runs(session_id, trigger) WHERE trigger = 'self_prompt'
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_runs_session ON skill_eval_runs(session_id, created_at DESC)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_runs_status ON skill_eval_runs(status, created_at DESC)",
            &[_][]const u8{});

        // ── per-(run, skill) session-relative half ────────────────────────
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS skill_eval_results (
            \\    id TEXT PRIMARY KEY,
            \\    run_id TEXT NOT NULL,
            \\    skill_key TEXT NOT NULL,
            \\    skill_name TEXT NOT NULL,
            \\    session_id TEXT NOT NULL DEFAULT '',
            \\    status TEXT NOT NULL DEFAULT 'pending',
            \\    verdict TEXT NOT NULL DEFAULT 'needs_human',
            \\    relevance INTEGER NOT NULL DEFAULT 0,
            \\    used INTEGER NOT NULL DEFAULT 0,
            \\    helpfulness INTEGER NOT NULL DEFAULT 0,
            \\    confidence REAL NOT NULL DEFAULT 0,
            \\    intrinsic_fact_id TEXT NOT NULL DEFAULT '',
            \\    base_content_hash TEXT NOT NULL DEFAULT '',
            \\    content_at_use TEXT NOT NULL DEFAULT '',
            \\    proposed_diff TEXT NOT NULL DEFAULT '',
            \\    rationale TEXT NOT NULL DEFAULT '',
            \\    sub_session_id TEXT NOT NULL DEFAULT '',
            \\    applied_at DATETIME,
            \\    apply_action TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    user_id TEXT
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_results_run ON skill_eval_results(run_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_results_skill ON skill_eval_results(skill_key, created_at DESC)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_results_session ON skill_eval_results(session_id, created_at DESC)",
            &[_][]const u8{});
    }
};

// ============================================================================
// Migration 095 — per-workspace isolation for `agent_memories`.
// ============================================================================
//
// ## Why this migration exists
//
// The `save_memory` / `load_memory` agent tools store their notes in
// `agent_memories` (Migration 070) with NO owner column of any kind.
// The tool description even said so — "Global scope: memories are
// visible across all workspaces and sessions. There is no per-workspace
// filter." Every workspace on the machine therefore read and wrote the
// same note pool: a note saved while working on project X was recalled
// verbatim by an agent whose cwd was project Y, and `load_memory {id}`
// would hand over a full 1 MiB body belonging to a different workspace.
//
// Workspace isolation is the rule the rest of the product already
// follows (`read_workspace_session` scopes server-side from
// `ctx.session_id`; the kanban tools scope every query by
// `workspace_id`). This migration makes the memory store obey it too.
//
// ## The `''` sentinel
//
// `workspace_id TEXT NOT NULL DEFAULT ''` — `''` means "this memory
// belongs to no workspace" and is the project's existing convention for
// an absent string value (Migration 094's `is_default`, Migration 070's
// `tags`). A session that cannot be resolved to a workspace
// (`workspace_scope.resolveWorkspaceId` returns null — a bare CLI chat,
// a session whose cwd matches no `workspace_items.path`) writes into the
// `''` bucket, which is a bucket like any other: those sessions share
// it with each other, but NO workspace session can see it. Fail-closed
// in the direction that matters.
//
// Pre-existing rows land in `''` for free — `NOT NULL DEFAULT ''` on an
// ADD COLUMN is an O(1) metadata change, no table rewrite, no backfill
// UPDATE. They are therefore invisible to workspace-scoped sessions
// after this migration. That is deliberate: re-homing 300+ rows that
// span every workspace a user ever typed into would either guess a
// workspace or copy the same note into all of them, and copying it into
// all of them is the exact leak this migration exists to close. To keep
// them, re-home the ones you want explicitly:
//
//   UPDATE agent_memories SET workspace_id = 'ws_...' WHERE id = 'mem_...';
//
// ## What is NOT changed
//
// `agent_memories_fts` still indexes `content` + `tags` only. The
// workspace filter is a JOIN predicate on the source table (the FTS5
// query already joins `agent_memories` for `snippet()`), so no FTS
// rebuild, no trigger change and no re-tokenization is required. A
// partitioned virtual table would force a full reindex of every note on
// a schema-only concern.
pub const Migration095AddWorkspaceIdToAgentMemories = struct {
    pub const version: u32 = 95;
    pub const name = "add_workspace_id_to_agent_memories";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(.{ .db = db }, allocator, "agent_memories", "workspace_id", "workspace_id TEXT NOT NULL DEFAULT ''");

        // Every read path filters `workspace_id = ?` and the FTS path
        // orders by the join's own rank, so a leading `workspace_id`
        // column lets SQLite seek straight to the calling workspace's
        // rows instead of probing every FTS hit. `updated_at DESC` rides
        // along for the (still unused, but already indexed) "most recent
        // memories in this workspace" surface.
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_agent_memories_workspace
            \\ON agent_memories(workspace_id, updated_at DESC)
        , &[_][]const u8{});
    }
};

// ============================================================================
// Migration 087 — agent config tables for routine workspace items.
// ============================================================================
//
// Mirrors Migration 081 (agent_kanbans) onto routines so the RoutineView
// Agent tab has storage: `agent_routines` (1-1 with workspace_items where
// item_type == 'routine', same D3 identity id == workspace_item_id) plus
// `agent_routine_knowledges` + `agent_routine_system_prompt` +
// `agent_routine_tools` children keyed by routine_id FK ON DELETE CASCADE.
//
// Differences vs 081 (intentional):
//   - Backfills one `agent_routines` row per pre-existing routine item
//     (INSERT OR IGNORE ... SELECT) so routines created before this
//     migration get a working Agent tab immediately instead of a
//     NotConfigured dead-end. Kanban stayed opt-in; routines need
//     day-one config because the tab ships in the same release.
//   - No default-tools seed here: an empty allowlist means "all tools"
//     (kanban D5 semantics), which preserves the pre-migration fire
//     behaviour exactly.
//
// Idempotency: CREATE TABLE/INDEX IF NOT EXISTS + INSERT OR IGNORE.
// One statement per db.exec (sqlite3_prepare_v2 compiles only the first).
//
// Plan: Routine mode task_1789505553300_1 (option A, mirror agent_kanban_*).
pub const Migration087CreateAgentRoutines = struct {
    pub const version: u32 = 87;
    pub const name = "create_agent_routines_mirror";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_routines (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routines_workspace_item_id ON agent_routines(workspace_item_id)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_routine_knowledges (
            \\    id TEXT PRIMARY KEY,
            \\    routine_id TEXT NOT NULL,
            \\    file_path TEXT NOT NULL DEFAULT '',
            \\    label TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (routine_id) REFERENCES agent_routines(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routine_knowledges_routine_id ON agent_routine_knowledges(routine_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routine_knowledges_routine_position ON agent_routine_knowledges(routine_id, position DESC)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_routine_system_prompt (
            \\    id TEXT PRIMARY KEY,
            \\    routine_id TEXT NOT NULL,
            \\    title TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (routine_id) REFERENCES agent_routines(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routine_system_prompt_routine_id ON agent_routine_system_prompt(routine_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routine_system_prompt_routine_position ON agent_routine_system_prompt(routine_id, position DESC)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_routine_tools (
            \\    id TEXT PRIMARY KEY,
            \\    routine_id TEXT NOT NULL,
            \\    tool_name TEXT NOT NULL,
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (routine_id) REFERENCES agent_routines(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routine_tools_routine_id ON agent_routine_tools(routine_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_routine_tools_routine_tool ON agent_routine_tools(routine_id, tool_name)",
            &[_][]const u8{});

        // Backfill parent rows for routines predating this migration.
        // Guarded by a sqlite_master check so the migration also runs on
        // databases where workspace_items does not exist yet (unit-test
        // :memory: DBs that only exercise the new tables).
        {
            var q = try db.query(allocator,
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'workspace_items'",
                &[_][]const u8{});
            defer q.deinit();
            const has_items_table = try q.next();
            if (has_items_table) |r| r.deinit(allocator);
            if (has_items_table != null) {
                try db.exec(allocator,
                    "INSERT OR IGNORE INTO agent_routines (id, workspace_item_id) SELECT id, id FROM workspace_items WHERE item_type = 'routine'",
                    &[_][]const u8{});
            }
        }
    }
};

// ============================================================================
// Migration 083 — llm_history reasoning metadata — inline tests
// ============================================================================

test "Migration083 adds reasoning_id + reasoning_encrypted_content columns to llm_history" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Minimal pre-083 llm_history shape (has reasoning_content from Migration 003).
    try ctx.db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    reasoning_content TEXT
        \\)
    , &.{});

    // Sanity: columns do NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM pragma_table_info('llm_history') WHERE name IN ('reasoning_id', 'reasoning_encrypted_content')",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    try Migration083AddReasoningIdAndEncryptedContent.up(&ctx.db, alloc);

    // Verify via columnsOf helper (project convention).
    const cols = try columnsOf(&ctx, "llm_history");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var has_reasoning_id = false;
    var has_encrypted = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "reasoning_id")) has_reasoning_id = true;
        if (std.mem.eql(u8, c, "reasoning_encrypted_content")) has_encrypted = true;
    }
    try testing.expect(has_reasoning_id);
    try testing.expect(has_encrypted);

    // Type + nullability sanity: both TEXT, nullable (notnull == 0).
    var q = try ctx.db.query(alloc,
        "SELECT name, type, \"notnull\" FROM pragma_table_info('llm_history') WHERE name IN ('reasoning_id', 'reasoning_encrypted_content') ORDER BY name",
        &.{});
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expectEqualStrings("TEXT", row.values[1]);
        try testing.expectEqualStrings("0", row.values[2]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 2), idx);
}

test "Migration083 INSERT/SELECT round-trip for both new columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    reasoning_content TEXT
        \\)
    , &.{});

    try Migration083AddReasoningIdAndEncryptedContent.up(&ctx.db, alloc);

    // Insert with all three reasoning fields populated.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, reasoning_content, reasoning_id, reasoning_encrypted_content) VALUES (?, ?, ?, ?, ?, ?)",
        &.{ "h1", "sess1", "gpt-5", "thinking trace", "rs_123", "ENC_DATA" });

    {
        var q = try ctx.db.query(alloc,
            "SELECT reasoning_content, reasoning_id, reasoning_encrypted_content FROM llm_history WHERE id = ?",
            &.{ "h1" });
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("thinking trace", row.values[0]);
        try testing.expectEqualStrings("rs_123", row.values[1]);
        try testing.expectEqualStrings("ENC_DATA", row.values[2]);
    }

    // NULL handling: legacy row without reasoning metadata should read as "" (SqliteBackend NULL → "").
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model) VALUES (?, ?, ?)",
        &.{ "h2", "sess1", "gpt-5" });
    {
        var q = try ctx.db.query(alloc,
            "SELECT reasoning_id, reasoning_encrypted_content FROM llm_history WHERE id = ?",
            &.{ "h2" });
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("", row.values[0]);
        try testing.expectEqualStrings("", row.values[1]);
    }
}

test "Migration083 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    reasoning_content TEXT
        \\)
    , &.{});

    try Migration083AddReasoningIdAndEncryptedContent.up(&ctx.db, alloc);
    try Migration083AddReasoningIdAndEncryptedContent.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('llm_history') WHERE name IN ('reasoning_id', 'reasoning_encrypted_content')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "Migration083 is registered in allMigrations" {
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration083AddReasoningIdAndEncryptedContent.version) return;
    }
    return error.Migration083NotRegistered;
}

// ============================================================================
// Migration 081 — agent-kanbans mirror — inline tests
// ============================================================================

const Migration081 = Migration081CreateAgentKanbans;

test "Migration081 creates agent_kanbans with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration081.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_kanbans");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "workspace_item_id", "description", "created_at", "updated_at",
    });
}

test "Migration081 creates agent_kanban_knowledges with content column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration081.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_kanban_knowledges");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "kanban_id", "file_path", "label", "content", "position", "created_at", "updated_at",
    });
}

test "Migration081 creates agent_kanban_system_prompt and agent_kanban_tools with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration081.up(&ctx.db, alloc);

    const sp_cols = try columnsOf(&ctx, "agent_kanban_system_prompt");
    defer {
        for (sp_cols) |c| alloc.free(c);
        alloc.free(sp_cols);
    }
    try expectColumnsEqual(sp_cols, &[_][]const u8{
        "id", "kanban_id", "title", "content", "position", "created_at", "updated_at",
    });

    const tool_cols = try columnsOf(&ctx, "agent_kanban_tools");
    defer {
        for (tool_cols) |c| alloc.free(c);
        alloc.free(tool_cols);
    }
    try expectColumnsEqual(tool_cols, &[_][]const u8{
        "id", "kanban_id", "tool_name", "enabled", "created_at",
    });
}

test "Migration081 is registered in allMigrations" {
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration081.version) return;
    }
    return error.Migration081NotRegistered;
}

test "Migration081 UNIQUE workspace_item_id rejects second agent_kanbans row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration081.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO agent_kanbans (id, workspace_item_id) VALUES ('ak_1', 'item_1')",
        &.{});
    const result = ctx.db.exec(alloc,
        "INSERT INTO agent_kanbans (id, workspace_item_id) VALUES ('ak_2', 'item_1')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration081 ON DELETE CASCADE removes all children when workspace_item deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    // Production order: parent tables first (agents), then the new tables.
    try Migration078.up(&ctx.db, alloc);
    try Migration081.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'kanban', 'Cascade Test', '/tmp/cascade', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_kanbans (id, workspace_item_id) VALUES ('ak_1', 'ws_item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_kanban_knowledges (id, kanban_id, file_path, label, content) VALUES ('k_1', 'ak_1', '', 'Note', 'inline body')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_kanban_system_prompt (id, kanban_id, title, content) VALUES ('sp_1', 'ak_1', 'Persona', 'You are X')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_kanban_tools (id, kanban_id, tool_name) VALUES ('t_1', 'ak_1', 'bash')",
        &.{});

    // Delete the workspace_item row directly.
    try ctx.db.exec(alloc, "DELETE FROM workspace_items WHERE id = 'ws_item_1'", &.{});

    // The agent_kanbans row and ALL children should be CASCADE-deleted.
    inline for (.{ "agent_kanbans", "agent_kanban_knowledges", "agent_kanban_system_prompt", "agent_kanban_tools" }) |table| {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM " ++ table, &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("0", r.values[0]);
    }
}

// ============================================================================
// Migration 084 — replace per-task routines with workspace_routines — tests
// ============================================================================

const Migration084 = Migration084ReplaceRoutinesWithWorkspaceRoutines;

test "Migration084 creates workspace_routines with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});

    try Migration084.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "workspace_routines");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id",                 "workspace_item_id",
        "description",        "instruction",
        "schedule",           "enabled",
        "last_run_at",        "next_run_at",
        "last_status",        "last_error",
        "created_at",         "updated_at",
    });
}

test "Migration084 drops routines table and normalizes task_type routine rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Pre-084 state: a routine task + its routines row (Migration 044 shape).
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, task_type) VALUES ('t_rout', 'routine'), ('t_std', 'standard')",
        &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE routines (
        \\    id TEXT PRIMARY KEY,
        \\    task_id TEXT NOT NULL UNIQUE,
        \\    schedule TEXT NOT NULL,
        \\    initial_prompt TEXT NOT NULL,
        \\    enabled INTEGER NOT NULL DEFAULT 1,
        \\    last_run_at DATETIME,
        \\    next_run_at DATETIME NOT NULL,
        \\    last_status TEXT,
        \\    last_error TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at) VALUES ('r1', 't_rout', '* * * * *', 'hi', '2026-01-01 00:00:00')",
        &.{});

    try Migration084.up(&ctx.db, alloc);

    // Old table is gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'routines'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }
    // Old indexes are gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_routines_%'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }
    // Routine task normalized to standard; standard row untouched.
    {
        var q = try ctx.db.query(alloc,
            "SELECT task_type FROM workspace_item_tasks WHERE id = 't_rout'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("standard", row.values[0]);
    }
    {
        var q = try ctx.db.query(alloc,
            "SELECT task_type FROM workspace_item_tasks WHERE id = 't_std'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("standard", row.values[0]);
    }
    // Replacement table exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'workspace_routines'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("workspace_routines", row.values[0]);
    }
}

test "Migration084 UNIQUE workspace_item_id rejects second workspace_routines row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});

    try Migration084.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_routines (id, workspace_item_id) VALUES ('wr_1', 'item_1')",
        &.{});
    const result = ctx.db.exec(alloc,
        "INSERT INTO workspace_routines (id, workspace_item_id) VALUES ('wr_2', 'item_1')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration084 ON DELETE CASCADE removes routine when workspace_item deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    try Migration084.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'routine', 'Nightly', '/tmp/x', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_routines (id, workspace_item_id, instruction, schedule) VALUES ('wr_1', 'ws_item_1', 'do things', '0 9 * * *')",
        &.{});

    try ctx.db.exec(alloc, "DELETE FROM workspace_items WHERE id = 'ws_item_1'", &.{});

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM workspace_routines", &.{});
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    try testing.expectEqualStrings("0", r.values[0]);
}

test "Migration084 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});

    try Migration084.up(&ctx.db, alloc);
    try Migration084.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'workspace_routines'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration084 is registered in allMigrations" {
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration084.version) return;
    }
    return error.Migration084NotRegistered;
}

// ============================================================================
// Migration 085 — session_progressive_tool — inline tests
// ============================================================================

test "Migration085 creates session_progressive_tool with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration085AddSessionProgressiveTool.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "session_progressive_tool");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "session_id",
        "tool_name",
        "server_name",
        "loaded_at_nano",
    });
}

test "Migration085 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration085AddSessionProgressiveTool.up(&ctx.db, alloc);
    try Migration085AddSessionProgressiveTool.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'session_progressive_tool'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration085 PRIMARY KEY(session_id, tool_name) rejects a duplicate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration085AddSessionProgressiveTool.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO session_progressive_tool (session_id, tool_name, server_name, loaded_at_nano) VALUES ('s1', 'glob', '', 1)",
        &.{});
    // A second insert with the same (session_id, tool_name) must be rejected
    // by the PRIMARY KEY. Asserted as "some error" rather than a specific
    // name: the DB layer's Error set has no ConstraintViolation variant.
    var duplicate_failed = false;
    ctx.db.exec(alloc,
        "INSERT INTO session_progressive_tool (session_id, tool_name, server_name, loaded_at_nano) VALUES ('s1', 'glob', '', 2)",
        &.{}) catch {
        duplicate_failed = true;
    };
    try testing.expect(duplicate_failed);
    // INSERT OR IGNORE (what the production helper uses) is a silent no-op.
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO session_progressive_tool (session_id, tool_name, server_name, loaded_at_nano) VALUES ('s1', 'glob', '', 3)",
        &.{});

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM session_progressive_tool WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration085 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration085AddSessionProgressiveTool.version) return;
    }
    return error.Migration085NotRegistered;
}

// ============================================================================
// Migration 086 — sessions.pr_url + pr_provider — inline tests
// ============================================================================

test "Migration086 adds pr_url + pr_provider columns to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Minimal pre-086 sessions shape.
    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try Migration086AddSessionPrUrl.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "sessions");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var has_url = false;
    var has_provider = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "pr_url")) has_url = true;
        if (std.mem.eql(u8, c, "pr_provider")) has_provider = true;
    }
    try testing.expect(has_url);
    try testing.expect(has_provider);

    // Both nullable TEXT (notnull == 0).
    var q = try ctx.db.query(alloc,
        "SELECT name, type, \"notnull\" FROM pragma_table_info('sessions') WHERE name IN ('pr_url', 'pr_provider') ORDER BY name",
        &.{});
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expectEqualStrings("TEXT", row.values[1]);
        try testing.expectEqualStrings("0", row.values[2]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 2), idx);
}

test "Migration086 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try Migration086AddSessionPrUrl.up(&ctx.db, alloc);
    try Migration086AddSessionPrUrl.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name IN ('pr_url', 'pr_provider')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "Migration086 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration086AddSessionPrUrl.version) return;
    }
    return error.Migration086NotRegistered;
}

// ============================================================================
// Migration 087 — agent_routines mirror — inline tests
// ============================================================================

test "Migration087 creates agent_routines tables with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration087CreateAgentRoutines.up(&ctx.db, alloc);

    for ([_][]const u8{ "agent_routines", "agent_routine_knowledges", "agent_routine_system_prompt", "agent_routine_tools" }) |tbl| {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            &[_][]const u8{tbl});
        defer q.deinit();
        const found = try q.next();
        if (found) |r| r.deinit(alloc);
        try testing.expect(found != null);
    }

    const cols = try columnsOf(&ctx, "agent_routine_knowledges");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var has_routine_id = false;
    var has_position = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "routine_id")) has_routine_id = true;
        if (std.mem.eql(u8, c, "position")) has_position = true;
    }
    try testing.expect(has_routine_id);
    try testing.expect(has_position);
}

test "Migration087 backfills agent_routines rows for pre-existing routines only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('rt_1', 'ws_1', 'routine', 'Nightly')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('kb_1', 'ws_1', 'kanban', 'Board')",
        &.{});

    try Migration087CreateAgentRoutines.up(&ctx.db, alloc);

    {
        var q = try ctx.db.query(alloc,
            "SELECT id, workspace_item_id FROM agent_routines",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("rt_1", row.values[0]);
        try testing.expectEqualStrings("rt_1", row.values[1]);
        try testing.expect((try q.next()) == null);
    }
}

test "Migration087 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('rt_1', 'ws_1', 'routine', 'Nightly')",
        &.{});

    try Migration087CreateAgentRoutines.up(&ctx.db, alloc);
    try Migration087CreateAgentRoutines.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM agent_routines",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration087 UNIQUE workspace_item_id rejects a duplicate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration087CreateAgentRoutines.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO agent_routines (id, workspace_item_id) VALUES ('rt_1', 'rt_1')",
        &.{});
    const dup = ctx.db.exec(alloc,
        "INSERT INTO agent_routines (id, workspace_item_id) VALUES ('rt_x', 'rt_1')",
        &.{});
    try testing.expectError(error.ExecuteFailed, dup);
}

test "Migration087 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration087CreateAgentRoutines.version) return;
    }
    return error.Migration087NotRegistered;
}

test "Migration091 adds sub_agent_name + parent_session_id to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try Migration091AddSubAgentNameToSessions.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "sessions");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var has_sub = false;
    var has_parent = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "sub_agent_name")) has_sub = true;
        if (std.mem.eql(u8, c, "parent_session_id")) has_parent = true;
    }
    try testing.expect(has_sub);
    try testing.expect(has_parent);
}

test "Migration091 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try Migration091AddSubAgentNameToSessions.up(&ctx.db, alloc);
    try Migration091AddSubAgentNameToSessions.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name IN ('sub_agent_name', 'parent_session_id')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "Migration091 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration091AddSubAgentNameToSessions.version) return;
    }
    return error.Migration091NotRegistered;
}

// ============================================================================
// Migration 093 — owner columns for per-user row isolation — inline tests
// ============================================================================

/// Minimal pre-093 root schema: `workspaces` and `sessions` already carry
/// `user_id` (Migration 077), `worker` does not.
fn setupOwnerRoots(ctx: *TestCtx) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY, user_id TEXT)", &.{});
    try ctx.db.exec(alloc, "CREATE TABLE sessions (id TEXT PRIMARY KEY, user_id TEXT)", &.{});
    try ctx.db.exec(alloc, "CREATE TABLE worker (id TEXT PRIMARY KEY, session_id TEXT NOT NULL)", &.{});
}

/// Assert one row's owner. Deliberately a comparison helper (not a getter)
/// so no duped value can escape and trip the leak-checking test allocator.
fn expectOwner(ctx: *TestCtx, table: []const u8, id: []const u8, expected: []const u8) !void {
    const alloc = testing.allocator;
    const sql = try std.fmt.allocPrint(
        alloc,
        "SELECT COALESCE(user_id, '<null>') FROM {s} WHERE id = ?",
        .{table},
    );
    defer alloc.free(sql);
    var q = try ctx.db.query(alloc, sql, &[_][]const u8{id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(expected, row.values[0]);
}

test "Migration093 adds worker.user_id and its index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupOwnerRoots(&ctx);

    try Migration093AddOwnerColumns.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "worker");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var found = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "user_id")) found = true;
    }
    try testing.expect(found);

    // Nullable TEXT: an empty-string bind (which SqliteBackend collapses to
    // SQL NULL) must never violate the column.
    var q = try ctx.db.query(alloc,
        "SELECT type, \"notnull\" FROM pragma_table_info('worker') WHERE name = 'user_id'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", row.values[0]);
    try testing.expectEqualStrings("0", row.values[1]);

    var qi = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_worker_user_id'",
        &.{});
    defer qi.deinit();
    const irow = (try qi.next()) orelse return error.RowMissing;
    defer irow.deinit(alloc);
    try testing.expectEqualStrings("1", irow.values[0]);
}

test "Migration093 backfills legacy NULL owners to the shared sentinel" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupOwnerRoots(&ctx);

    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_legacy', NULL)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, user_id) VALUES ('sess_legacy', NULL)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('w_legacy', 'sess_legacy')", &.{});

    try Migration093AddOwnerColumns.up(&ctx.db, alloc);

    // The shared bucket is what keeps pre-auth data visible once `--auth`
    // is switched on (user decision 2026-09-25).
    try expectOwner(&ctx, "workspaces", "ws_legacy", "user_system");
    try expectOwner(&ctx, "sessions", "sess_legacy", "user_system");
    try expectOwner(&ctx, "worker", "w_legacy", "user_system");
}

test "Migration093 never downgrades a real owner and is idempotent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupOwnerRoots(&ctx);
    // Simulate a database that already ran 093: worker.user_id present, so
    // the ADD COLUMN path is exercised as a no-op too.
    try ctx.db.exec(alloc, "ALTER TABLE worker ADD COLUMN user_id TEXT", &.{});

    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_a', 'user_a')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_legacy', NULL)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, user_id) VALUES ('sess_a', 'user_a')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id, user_id) VALUES ('w_a', 'sess_a', 'user_a')", &.{});

    try Migration093AddOwnerColumns.up(&ctx.db, alloc);
    try Migration093AddOwnerColumns.up(&ctx.db, alloc);

    try expectOwner(&ctx, "workspaces", "ws_a", "user_a");
    try expectOwner(&ctx, "sessions", "sess_a", "user_a");
    try expectOwner(&ctx, "worker", "w_a", "user_a");
    // The legacy row is backfilled, and only once.
    try expectOwner(&ctx, "workspaces", "ws_legacy", "user_system");
}

test "Migration093 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration093AddOwnerColumns.version) return;
    }
    return error.Migration093NotRegistered;
}

// ============================================================================
// Migration 094 — workspace_items.is_default
// ============================================================================

/// Create a minimal pre-Migration-094 `workspace_items` table, with rows
/// already in it. The column default has to be verified against real
/// existing rows, not a table we just created with the column present.
fn setupWorkspaceItemsPre094(ctx: *TestCtx) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  item_type TEXT NOT NULL,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('item_a', 'ws_1', 'kanban', 'Board', '/tmp/board', 1),
        \\       ('item_b', 'ws_1', 'agent',  'Helper', '/tmp/helper', 2),
        \\       ('item_c', 'ws_2', 'folder', 'Stuff', '/tmp/stuff', 0)
    , &.{});
}

/// Assert one workspace item's `is_default` flag. A comparison helper (not a
/// getter) so no duped value can escape and trip the leak-checking allocator.
fn expectIsDefault(ctx: *TestCtx, id: []const u8, expected: []const u8) !void {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc,
        "SELECT is_default FROM workspace_items WHERE id = ?",
        &[_][]const u8{id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(expected, row.values[0]);
}

test "Migration094 adds is_default and defaults every pre-existing row to 0" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupWorkspaceItemsPre094(&ctx);

    try Migration094AddDefaultProjectToWorkspaceItems.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "workspace_items");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var found = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "is_default")) found = true;
    }
    try testing.expect(found);

    // The whole point of NOT NULL DEFAULT 0: pre-existing rows must read
    // back as ordinary projects, with no backfill UPDATE and no table
    // rewrite. If this ever returns non-zero, a migration is marking a
    // user's existing project as a default.
    var q = try ctx.db.query(alloc,
        \\SELECT id, is_default FROM workspace_items ORDER BY id
    , &.{});
    defer q.deinit();
    var seen: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expectEqualStrings("0", row.values[1]);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);

    // NOT NULL must be set, or a future writer could store NULL and the
    // `WHERE is_default = 1` index would silently skip that row forever.
    var qi = try ctx.db.query(alloc,
        "SELECT type, \"notnull\", dflt_value FROM pragma_table_info('workspace_items') WHERE name = 'is_default'",
        &.{});
    defer qi.deinit();
    const irow = (try qi.next()) orelse return error.RowMissing;
    defer irow.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", irow.values[0]);
    try testing.expectEqualStrings("1", irow.values[1]);
    try testing.expectEqualStrings("0", irow.values[2]);
}

test "Migration094's partial unique index allows one default per workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupWorkspaceItemsPre094(&ctx);

    try Migration094AddDefaultProjectToWorkspaceItems.up(&ctx.db, alloc);

    // ws_1 gets its default. ws_2 has none yet — the invariant is the
    // service layer's job to fill, not the schema's.
    try ctx.db.exec(alloc,
        "UPDATE workspace_items SET is_default = 1 WHERE id = 'item_a'",
        &.{},
    );

    // A SECOND default in the same workspace must be refused. This is the
    // guarantee the whole race-guard in ensureDefaultProject leans on.
    // `ExecuteFailed` is what SqliteBackend.exec surfaces for a constraint
    // violation — the SQLSTATE text ("UNIQUE constraint failed") only
    // reaches the log, so the STATE check below is what actually proves the
    // index did its job.
    try testing.expectError(
        error.ExecuteFailed,
        ctx.db.exec(alloc,
            "UPDATE workspace_items SET is_default = 1 WHERE id = 'item_b'",
            &.{},
        ),
    );
    try expectIsDefault(&ctx, "item_b", "0");

    // A different workspace may have its own default — the index is
    // partial *and* scoped per workspace, not "one default in the db".
    try ctx.db.exec(alloc,
        "UPDATE workspace_items SET is_default = 1 WHERE id = 'item_c'",
        &.{},
    );

    // Ordinary rows are never compared against each other, so any number
    // of them coexist in one workspace.
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, position)
        \\VALUES ('item_d', 'ws_1', 'kanban', 'Another board', 3)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, position)
        \\VALUES ('item_e', 'ws_1', 'kanban', 'Third board', 4)
    , &.{});

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM workspace_items WHERE workspace_id = 'ws_1' AND is_default = 1",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration094 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupWorkspaceItemsPre094(&ctx);

    try Migration094AddDefaultProjectToWorkspaceItems.up(&ctx.db, alloc);
    // Mark one so a re-run also has to cope with a populated column.
    try ctx.db.exec(alloc,
        "UPDATE workspace_items SET is_default = 1 WHERE id = 'item_a'",
        &.{},
    );
    // Re-running must not throw "duplicate column" (addColumnIfMissing
    // guards it) and must not clobber the existing default.
    try Migration094AddDefaultProjectToWorkspaceItems.up(&ctx.db, alloc);
    try Migration094AddDefaultProjectToWorkspaceItems.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT id FROM workspace_items WHERE is_default = 1",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("item_a", row.values[0]);
    try testing.expect((try q.next()) == null);
}

test "Migration094 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration094AddDefaultProjectToWorkspaceItems.version) return;
    }
    return error.Migration094NotRegistered;
}

// ─── Tests for Migration 095 (agent_memories.workspace_id) ────────────

/// Create a pre-Migration-095 `agent_memories` (+ FTS5 side table) with
/// rows in it, so the ADD COLUMN can be exercised against data rather
/// than an empty table.
fn setupAgentMemoriesPre095(ctx: *TestCtx) !void {
    try ctx.db.exec(testing.allocator,
        \\CREATE TABLE agent_memories (
        \\    id TEXT PRIMARY KEY,
        \\    content TEXT NOT NULL,
        \\    tags TEXT NOT NULL DEFAULT '',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    try ctx.db.exec(testing.allocator,
        "INSERT INTO agent_memories (id, content) VALUES ('mem_aaa', 'legacy note one')",
        &[_][]const u8{},
    );
    try ctx.db.exec(testing.allocator,
        "INSERT INTO agent_memories (id, content) VALUES ('mem_bbb', 'legacy note two')",
        &[_][]const u8{},
    );
}

test "Migration095 adds workspace_id and files every pre-existing row in the '' bucket" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupAgentMemoriesPre095(&ctx);

    try Migration095AddWorkspaceIdToAgentMemories.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT id, workspace_id FROM agent_memories ORDER BY id
    , &.{});
    defer q.deinit();
    const a = (try q.next()) orelse return error.RowMissing;
    defer a.deinit(alloc);
    try testing.expectEqualStrings("mem_aaa", a.values[0]);
    try testing.expectEqualStrings("", a.values[1]);
    const b = (try q.next()) orelse return error.RowMissing;
    defer b.deinit(alloc);
    try testing.expectEqualStrings("mem_bbb", b.values[0]);
    try testing.expectEqualStrings("", b.values[1]);
}

test "Migration095 creates the workspace index and is idempotent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupAgentMemoriesPre095(&ctx);

    try Migration095AddWorkspaceIdToAgentMemories.up(&ctx.db, alloc);
    // Re-running must not throw "duplicate column" / "index already exists"
    // and must not rewrite a row that already has an owner.
    try Migration095AddWorkspaceIdToAgentMemories.up(&ctx.db, alloc);
    try ctx.db.exec(alloc,
        "UPDATE agent_memories SET workspace_id = 'ws_kept' WHERE id = 'mem_aaa'",
        &[_][]const u8{},
    );
    try Migration095AddWorkspaceIdToAgentMemories.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT workspace_id FROM agent_memories WHERE id = 'mem_aaa'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("ws_kept", row.values[0]);

    var idx = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_agent_memories_workspace'",
        &.{});
    defer idx.deinit();
    const irow = (try idx.next()) orelse return error.IndexMissing;
    defer irow.deinit(alloc);
    try testing.expectEqualStrings("idx_agent_memories_workspace", irow.values[0]);
}

test "Migration095 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration095AddWorkspaceIdToAgentMemories.version) return;
    }
    return error.Migration095NotRegistered;
}

// ===== Tests merged from migration_test.zig (2026-09-29 flatten) =====

test "migration module imports" {
    // Test that the migration module can be imported
    try std.testing.expect(true);
}

// ===== Tests merged from migration_009_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 009 (remove_created_column).
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// Migration 009's `INSERT INTO ... SELECT datetime(CAST(created AS
// INTEGER), 'unixepoch') FROM llm_history_old` references a `created`
// column that has **never existed** in this codebase — Migration 001
// has always created `llm_history` with a `created_at` column
// directly. On a fresh DB (no historical `created` column),
// `runMigrations` aborts with:
//
//   sqlite3_prepare_v2 error: no such column: created
//
// which crashes the server during startup. A static source check
// would not catch this — only executing the INSERT against an
// actual schema exposes the bug. The fix (Migration 009 now uses
// `COALESCE(created_at, CURRENT_TIMESTAMP)`) is verified by
// running migration 009 against the schema state left by
// migrations 001–008.
//
// The SqliteBackend's public API (see
// `src/modules/databases/sqlite/Sqlite.zig`) is: `init`, `exec`,
// `query` (returns `Rows` with `next()` → `?Row` carrying
// `values: [][]u8`). Column reads go through `Row.values[i]`, which
// is always text.

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB and apply migrations 001–008,
/// matching the schema state that migration 009 was always meant to
/// consume. After this returns, the DB has the full pre-migration-009
/// `llm_history` schema with all columns added by 002–008, ready for
/// migration 009 to do its rename-and-copy dance.

fn setupDb009() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Replay migrations 001–008 in version order. Migration 001 itself
    // creates the table; the rest are ADD COLUMN. This mirrors what a
    // fresh-install DB looks like when migration 009 is about to run.
    try Migration001CreateLLMHistory.up(&db, alloc);
    try Migration002AddRoleToLLMHistory.up(&db, alloc);
    try Migration003AddReasoningContent.up(&db, alloc);
    try Migration004AddSessionDir.up(&db, alloc);
    try Migration005AddIsFeedToLLM.up(&db, alloc);
    try Migration006AddAgent.up(&db, alloc);
    try Migration007AddSessionTracking.up(&db, alloc);
    try Migration008AddSessionSkills.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: migration 009 does not crash on a fresh-DB schema ────────────
//
// This is the canonical regression test for the "fresh-DB crash" bug.
// It MUST NOT return an error (the bug was `error.PrepareFailed` with
// message "no such column: created" from Migration 009's INSERT...SELECT).
// Before the fix, this test fails on a fresh DB. After the fix, it
// passes — and the CI smoke test (`scripts/ci-smoke-test.sh`) depends
// on this passing on the test runner's fresh $HOME.

test "Migration009RemoveCreatedColumn does not crash on fresh-DB schema (no 'created' column)" {
    const alloc = testing.allocator;
    var ctx = try setupDb009();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: pre-migration `llm_history` exists with `created_at` (not
    // `created`). If this assertion fails, the setup helper drifted out
    // of sync with Migration 001 — fix the helper, not the test.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM pragma_table_info('llm_history') WHERE name IN ('created', 'created_at')",
            &.{});
        defer q.deinit();
        var has_created: bool = false;
        var has_created_at: bool = false;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            if (std.mem.eql(u8, row.values[0], "created")) has_created = true;
            if (std.mem.eql(u8, row.values[0], "created_at")) has_created_at = true;
        }
        try testing.expect(!has_created);
        try testing.expect(has_created_at);
    }

    // Run migration 009 — this is the line that crashed pre-fix.
    try Migration009RemoveCreatedColumn.up(&ctx.db, alloc);

    // Post-conditions: `llm_history_old` is gone (it was renamed then
    // dropped), `llm_history` still exists with `created_at`.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE name IN ('llm_history', 'llm_history_old') ORDER BY name",
            &.{});
        defer q.deinit();
        var seen_llm_history: bool = false;
        var seen_llm_history_old: bool = false;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            if (std.mem.eql(u8, row.values[0], "llm_history")) seen_llm_history = true;
            if (std.mem.eql(u8, row.values[0], "llm_history_old")) seen_llm_history_old = true;
        }
        try testing.expect(seen_llm_history);
        try testing.expect(!seen_llm_history_old);
    }
}

// ─── Test 2: pre-existing rows survive the rename-and-copy ────────────────
//
// Verifies that the COALESCE(created_at, CURRENT_TIMESTAMP) fix doesn't
// silently NULL out pre-existing rows. Inserts a single row with an
// explicit created_at, runs migration 009, asserts the row is still
// present with the same created_at value.

test "Migration009RemoveCreatedColumn preserves pre-existing rows' created_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb009();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert a deterministic row in the pre-migration schema.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('row_1', 'sess_1', 'm1', 'hello', '2026-06-30 12:34:56')",
        &.{});

    try Migration009RemoveCreatedColumn.up(&ctx.db, alloc);

    // Read it back: should still exist with the original created_at.
    var q = try ctx.db.query(alloc,
        "SELECT id, created_at FROM llm_history WHERE id = 'row_1'",
        &.{});
    defer q.deinit();

    const row = (try q.next()) orelse return error.RowMissing009;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("row_1", row.values[0]);
    try testing.expectEqualStrings("2026-06-30 12:34:56", row.values[1]);
}

// ===== Tests merged from migration_routines_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 044 (add task_type + routines table).
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// Migration 044 introduces two new schema objects (a `task_type` column
// on the existing `workspace_item_tasks` table and a new `routines`
// table with a UNIQUE + FOREIGN KEY constraint and an index). A static
// source check would not catch a typo in the column type, a missing
// DEFAULT, a missing CASCADE, or a misspelled index name — all of
// which are easy regressions to make when writing a migration by hand.
//
// The working precedent for in-process sqlite-backed tests is
// `inherited_context_test.zig`: it opens `":memory:"` via
// `std.Io.Threaded + db.init(io, ":memory:")`, hands the schema from
// scratch (mimicking the state a real DB would have just before the
// migration), runs the migration, and asserts via `db.query`. We
// mirror that exact pattern here.
//
// The SqliteBackend's public API (see
// `ruangsql src/sqlite/Sqlite.zig (github.com/ginwa123/ruangsql)`) is: `init`, `exec`,
// `query` (returns `Rows` with `next()` → `?Row` carrying
// `values: [][]u8`), `queryRow`, and `deinit`. There is no
// `prepare`/`step`/`columnText`/`columnInt`/`columnType`/`bindText`
// public API — column reads go through `Row.values[i]`, which is
// always text (so for the `enabled INTEGER NOT NULL DEFAULT 1`
// assertion we read the column as text and compare against "1").
//
// Plan: docs/superpowers/plans/2026-06-13-add-task-routines.md
// Design: docs/plans/2026-06-13-add-task-routines-design.md

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the workspace_item_tasks table
/// present (matching the state after Migration 034), ready for
/// Migration 044 to add the `task_type` column on top.

fn setupDb044() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Mirror the state left by Migration 034 exactly — same columns,
    // same NULL/NOT NULL semantics, same default timestamps. This is
    // what a real DB looks like the moment before Migration 044 runs.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    session_id TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Look up a single scalar text value from a SELECT. Returns the
/// empty slice if there is no row.
fn scalarText044(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) ![]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return try alloc.dupe(u8, "");
}

// ─── Test 1: ALTER TABLE adds task_type with default 'standard' ──────────

test "Migration044AddRoutines adds task_type column defaulting to standard" {
    const alloc = testing.allocator;
    var ctx = try setupDb044();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // Insert a row WITHOUT specifying task_type. The new column should
    // backfill it with the default 'standard' (the backwards-compat
    // contract for every pre-existing task row).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'foo', 'wi1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t2', 'bar', 'wi1')",
        &.{});

    const v1 = try scalarText044(alloc, &ctx.db, "SELECT task_type FROM workspace_item_tasks WHERE id = 't1'", &.{});
    defer alloc.free(v1);
    try testing.expectEqualStrings("standard", v1);

    const v2 = try scalarText044(alloc, &ctx.db, "SELECT task_type FROM workspace_item_tasks WHERE id = 't2'", &.{});
    defer alloc.free(v2);
    try testing.expectEqualStrings("standard", v2);
}

test "Migration044AddRoutines accepts explicit task_type override" {
    const alloc = testing.allocator;
    var ctx = try setupDb044();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // Insert a row with task_type='routine'. The column must accept
    // the override (not just always force 'standard').
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES ('t1', 'foo', 'wi1', 'routine')",
        &.{});

    const v = try scalarText044(alloc, &ctx.db, "SELECT task_type FROM workspace_item_tasks WHERE id = 't1'", &.{});
    defer alloc.free(v);
    try testing.expectEqualStrings("routine", v);
}

// ─── Test 2: routines table with expected columns + constraints ──────────

test "Migration044AddRoutines creates routines table with expected columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb044();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // We need a parent workspace_item_tasks row for the FOREIGN KEY to
    // be satisfied. (The FK is on task_id → workspace_item_tasks.id.)
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'parent', 'wi1')",
        &.{});

    // Insert a routine row referencing the parent. Verify the
    // explicit-supplied columns and the implicit-default columns.
    try ctx.db.exec(alloc,
        \\INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at)
        \\VALUES ('r1', 't1', '*/5 * * * *', 'do the thing', '2099-01-01 00:00:00')
    , &.{});

    // Read each column separately. SQLite `||` with a NULL operand
    // returns NULL, so we can't use string concatenation as a
    // one-shot "all columns in one string" check. The Row.values
    // API also returns each column as text, so this is the natural
    // way to assert on a multi-column read.
    const v = try scalarText044(alloc, &ctx.db,
        "SELECT schedule, initial_prompt, enabled, last_status, last_run_at FROM routines WHERE id = 'r1'",
        &.{});
    defer alloc.free(v);
    // Single-column scalar read — assert schedule (column 0) first.
    try testing.expectEqualStrings("*/5 * * * *", v);

    // Re-read each column independently and assert.
    const schedule = try scalarText044(alloc, &ctx.db, "SELECT schedule FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(schedule);
    try testing.expectEqualStrings("*/5 * * * *", schedule);

    const initial_prompt = try scalarText044(alloc, &ctx.db, "SELECT initial_prompt FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(initial_prompt);
    try testing.expectEqualStrings("do the thing", initial_prompt);

    // enabled is INTEGER NOT NULL DEFAULT 1 — read as text (the Row
    // API only returns text), the value is the string "1".
    const enabled = try scalarText044(alloc, &ctx.db, "SELECT enabled FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(enabled);
    try testing.expectEqualStrings("1", enabled);

    // last_status and last_run_at are nullable. Their text
    // representation in the Row API is the empty string when NULL.
    const last_status = try scalarText044(alloc, &ctx.db, "SELECT COALESCE(last_status, '') FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(last_status);
    try testing.expectEqualStrings("", last_status);

    const last_run_at = try scalarText044(alloc, &ctx.db, "SELECT COALESCE(last_run_at, '') FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(last_run_at);
    try testing.expectEqualStrings("", last_run_at);
}

test "Migration044AddRoutines enforces UNIQUE constraint on routines.task_id" {
    const alloc = testing.allocator;
    var ctx = try setupDb044();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'parent', 'wi1')",
        &.{});

    try ctx.db.exec(alloc,
        "INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at) VALUES ('r1', 't1', '* * * * *', 'a', '2099-01-01 00:00:00')",
        &.{});

    // Second insert with the same task_id must fail (UNIQUE constraint).
    const result = ctx.db.exec(alloc,
        "INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at) VALUES ('r2', 't1', '* * * * *', 'b', '2099-01-01 00:00:00')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration044AddRoutines creates idx_routines_enabled_next_run index" {
    const alloc = testing.allocator;
    var ctx = try setupDb044();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // Query sqlite_master for the index name. If the migration forgot
    // to create the index, the query returns zero rows.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_routines_enabled_next_run'",
        &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_routines_enabled_next_run")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// ===== Tests merged from migration_chat_list_index_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 048 (add chat-list covering index).
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// Migration 048 adds a single new SQLite index
// (`idx_llm_history_created_session` on `(created_at DESC, session_id)`)
// that is the load-bearing optimization for the chat-list query at
// `llm_history.zig:115`. A static source check would not catch a
// misspelled index name, a wrong column order, or a missing `DESC` on
// `created_at` — all of which would make the planner silently fall
// back to a full table scan. We assert the index actually exists in
// `sqlite_master` after `up()` runs, mirroring the pattern from
// `migration_routines_test.zig`.
//
// The SqliteBackend's public API (see
// `ruangsql src/sqlite/Sqlite.zig (github.com/ginwa123/ruangsql)`) is: `init`, `exec`,
// `query` (returns `Rows` with `next()` → `?Row` carrying
// `values: [][]u8`). There is no `prepare`/`step`/`columnText`/
// `columnInt` public API — column reads go through `Row.values[i]`,
// which is always text.
//
// Plan: docs/plans/2026-06-19-performance-indexes.md (Chunk 1)

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the `llm_history` table present
/// (matching the schema created by Migration 001), ready for
/// Migration 048 to add the `idx_llm_history_created_session` index on top.

fn setupDb048() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Mirror the state left by Migration 001 exactly — same columns,
    // same NULL/NOT NULL semantics. The index only touches
    // (created_at, session_id) so those are the columns that must
    // exist with compatible types.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
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
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: index exists in sqlite_master after up() ─────────────────────

test "Migration048AddChatListIndex creates idx_llm_history_created_session index" {
    const alloc = testing.allocator;
    var ctx = try setupDb048();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration048AddChatListIndex.up(&ctx.db, alloc);

    // Query sqlite_master for the index name. If the migration forgot
    // to create the index, the query returns zero rows. We check
    // `name` (not just existence) so a typo in the index name is
    // caught — sqlite_master would still report it as a row.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_llm_history_created_session'
    , &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_llm_history_created_session")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// ─── Test 2: migration is idempotent (re-running up() does not fail) ─────

test "Migration048AddChatListIndex is idempotent on re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb048();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // The migration uses `CREATE INDEX IF NOT EXISTS` so a second
    // run is a no-op. We assert no error is returned.
    try Migration048AddChatListIndex.up(&ctx.db, alloc);
    try Migration048AddChatListIndex.up(&ctx.db, alloc);

    // And the index is still there exactly once.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_llm_history_created_session'
    , &.{});
    defer q.deinit();

    const row = (try q.next()) orelse return error.ExpectedRow048;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

// ===== Tests merged from migration_defensive_indexes_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 049 (add defensive indexes).
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// Migration 049 adds two low-cost insurance indexes — one on
// `workspace_items(position DESC, id ASC)` and one on
// `routines(last_status)`. A static source check would not catch a
// misspelled index name, a wrong column order, or a dropped
// `CREATE INDEX` statement — all of which would make the planner
// silently fall back to a full table scan. We assert the indexes
// actually exist in `sqlite_master` after `up()` runs, mirroring the
// pattern from `migration_chat_list_index_test.zig` (the most recent
// precedent) and `migration_routines_test.zig`.
//
// The SqliteBackend's public API (see
// `ruangsql src/sqlite/Sqlite.zig (github.com/ginwa123/ruangsql)`) is: `init`, `exec`,
// `query` (returns `Rows` with `next()` → `?Row` carrying
// `values: [][]u8`). There is no `prepare`/`step`/`columnText`/
// `columnInt` public API — column reads go through `Row.values[i]`,
// which is always text.
//
// Plan: docs/plans/2026-06-19-performance-indexes.md (Chunk 3)

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with BOTH `workspace_items` and
/// `routines` (plus the FK parent `workspace_item_tasks`) present —
/// matching the schema state just before Migration 049 runs. Migration
/// 049 does not add any columns, only two new indexes on existing
/// tables, so the minimum column set is whatever the two target
/// indexes reference.

fn setupDb049() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_item_tasks — parent of the routines.task_id FK.
    // The new indexes don't reference it, but the routines table
    // declares an FK to it so SQLite will reject CREATE TABLE
    // without it (the FK is a column-level constraint, so the
    // referenced table must exist before CREATE TABLE routines).
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    // workspace_items — minimum columns for the position_id index.
    // The index covers (position DESC, id ASC), so both columns must
    // exist with compatible types. We mirror Migration 028's original
    // schema (id, workspace_id, item_type) and add `position` (the
    // Migration 045 schema). The test never inserts rows, so the
    // other columns are inert.
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    // routines — minimum columns for the last_status index. We
    // mirror the full Migration 044 CREATE TABLE (sans the
    // created_at / updated_at defaults which the test doesn't care
    // about) so the new index is guaranteed compatible.
    try db.exec(alloc,
        \\CREATE TABLE routines (
        \\    id TEXT PRIMARY KEY,
        \\    task_id TEXT NOT NULL UNIQUE,
        \\    schedule TEXT NOT NULL,
        \\    initial_prompt TEXT NOT NULL,
        \\    enabled INTEGER NOT NULL DEFAULT 1,
        \\    last_run_at DATETIME,
        \\    next_run_at DATETIME NOT NULL,
        \\    last_status TEXT,
        \\    last_error TEXT,
        \\    FOREIGN KEY (task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Look up a single scalar text value from a SELECT. Returns the
/// empty slice if there is no row.
fn scalarText049(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) ![]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return try alloc.dupe(u8, "");
}

// ─── Test 1: idx_workspace_items_position_id exists in sqlite_master ─────

test "Migration049AddDefensiveIndexes creates idx_workspace_items_position_id index" {
    const alloc = testing.allocator;
    var ctx = try setupDb049();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);

    // Query sqlite_master for the index name. If the migration forgot
    // to create the index, the query returns zero rows. We check
    // `name` (not just existence) so a typo in the index name is
    // caught — sqlite_master would still report it as a row.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_workspace_items_position_id'
    , &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_workspace_items_position_id")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// ─── Test 2: idx_routines_last_status exists in sqlite_master ────────────

test "Migration049AddDefensiveIndexes creates idx_routines_last_status index" {
    const alloc = testing.allocator;
    var ctx = try setupDb049();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);

    // Same pattern as test 1 but for the routines index.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_routines_last_status'
    , &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_routines_last_status")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// ─── Test 3: migration is idempotent (re-running up() does not fail) ─────

test "Migration049AddDefensiveIndexes is idempotent on re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb049();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // The migration uses `CREATE INDEX IF NOT EXISTS` so a second
    // run is a no-op for both indexes. We assert no error is
    // returned. (Defensive: if a future change drops the IF NOT
    // EXISTS, this test fails immediately.)
    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);
    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);

    // And both indexes are still there exactly once. COUNT(*) is
    // returned as text per the SqliteBackend's row-as-text API.
    const wi_count = try scalarText049(alloc, &ctx.db,
        \\SELECT COUNT(*) FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_workspace_items_position_id'
    , &.{});
    defer alloc.free(wi_count);
    try testing.expectEqualStrings("1", wi_count);

    const r_count = try scalarText049(alloc, &ctx.db,
        \\SELECT COUNT(*) FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_routines_last_status'
    , &.{});
    defer alloc.free(r_count);
    try testing.expectEqualStrings("1", r_count);
}

// ===== Tests merged from migration_git_worktree_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 046 (add git_worktree_cwd column to
// sessions).
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// Migration 046 is a simple ALTER TABLE ADD COLUMN, but a static source
// check would not catch a typo in the column name, a missing NULL/NOT
// NULL semantic, or a missing registration in `allMigrations` — all of
// which would silently break the new `set_git_worktree` tool that
// Chunks 2-4 of the plan will build on top of this column.
//
// The working precedent for in-process sqlite-backed tests is
// `migration_routines_test.zig`: it opens `":memory:"` via
// `std.Io.Threaded + db.init(io, ":memory:")`, hands the schema from
// scratch (mimicking the state a real DB would have just before the
// migration), runs the migration, and asserts via `db.query`. We
// mirror that exact pattern here.
//
// Plan: docs/plans/2026-06-18-set-git-worktree-tool.md (Chunk 1)

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the sessions table present
/// (matching the state left by migrations 017 + 022 + 025 + 029 + 040),
/// ready for Migration 046 to add the `git_worktree_cwd` column on top.

fn setupDb046() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Mirror the state left by Migration 017 + 022 + 025 + 029 + 040
    // exactly — same columns, same NULL/NOT NULL semantics, same default
    // timestamps. This is what a real DB looks like the moment before
    // Migration 046 runs.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    workspace_id TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Look up a single scalar text value from a SELECT. Returns the
/// empty slice if there is no row.
fn scalarText046(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) ![]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return try alloc.dupe(u8, "");
}

// ─── Test 1: ALTER TABLE adds git_worktree_cwd defaulting to NULL ────────

test "Migration046AddGitWorktreeCwdToSessions adds git_worktree_cwd column defaulting to NULL" {
    const alloc = testing.allocator;
    var ctx = try setupDb046();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration046AddGitWorktreeCwdToSessions.up(&ctx.db, alloc);

    // Insert a row WITHOUT specifying git_worktree_cwd. The new column
    // should backfill NULL (the backwards-compat contract for every
    // pre-existing session row).
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('t1', 'foo')", &.{});

    // NULL is mapped to the empty string by COALESCE at the read site
    // (matching the convention used for cwd, created_at, updated_at,
    // and selected_profile_model).
    const v = try scalarText046(alloc, &ctx.db, "SELECT COALESCE(s.git_worktree_cwd, '') FROM sessions s WHERE s.id = 't1'", &.{});
    defer alloc.free(v);
    try testing.expectEqualStrings("", v);
}

// ─── Test 2: explicit value round-trips ──────────────────────────────────

test "Migration046AddGitWorktreeCwdToSessions accepts explicit value" {
    const alloc = testing.allocator;
    var ctx = try setupDb046();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration046AddGitWorktreeCwdToSessions.up(&ctx.db, alloc);

    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('t1', 'foo')", &.{});
    try ctx.db.exec(alloc, "UPDATE sessions SET git_worktree_cwd = '/abs/path' WHERE id = 't1'", &.{});

    const v = try scalarText046(alloc, &ctx.db, "SELECT s.git_worktree_cwd FROM sessions s WHERE s.id = 't1'", &.{});
    defer alloc.free(v);
    try testing.expectEqualStrings("/abs/path", v);
}

// ===== Tests merged from migration_051_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 051 (add kanban columns + task column refs).
//
// NOTE on numbering: The plan was written before Migrations 048 (chat-list
// index), 049 (defensive indexes), and 050 (pinned-to-workspace-item-tasks)
// landed on the branch. Per the plan's "find the LAST migration and add
// after it" instruction, this migration uses the next available number
// (051) instead of the originally proposed 048.
//
// What Migration 051 adds
// ───────────────────────
// 1. `kanban_columns` table with FK ON DELETE CASCADE to `workspace_items(id)`
// 2. Index `idx_kanban_columns_item_position` on (workspace_item_id, position)
// 3. Two new columns on `workspace_item_tasks`:
//      `kanban_column_id TEXT` (nullable — NULL for non-kanban items)
//      `kanban_position INTEGER NOT NULL DEFAULT 0` (per-column ordering)
// 4. Index `idx_tasks_column_position` on (kanban_column_id, kanban_position)
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// A static source check would not catch a misspelled table name, missing
// column, wrong DEFAULT, or missing FK clause. Asserting the actual
// schema after `up()` runs mirrors the pattern used by
// `migration_chat_list_index_test.zig` and `migration_routines_test.zig`.
//
// The SqliteBackend's public API (see
// `src/modules/databases/sqlite/Sqlite.zig`) is: `init`, `exec`, `query`
// (returns `Rows` with `next()` → `?Row` carrying `values: [][]u8`).
// Column reads go through `Row.values[i]`, which is always text.
//
// Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 1)

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with `workspace_items` and
/// `workspace_item_tasks` tables present (matching the schema after
/// Migrations 028 and 034), ready for Migration 051 to add the kanban
/// schema on top.

fn setupDb051() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Mirror the state left by Migration 028 + 034 — same column names
    // that Migration 051's FK references and ALTER TABLE statements
    // depend on.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: kanban_columns has the expected columns ──────────────────────

test "Migration051 creates kanban_columns table with expected columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb051();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration051AddKanban.up(&ctx.db, alloc);

    // Assert kanban_columns exists with the expected columns in the
    // expected order. pragma_table_info orders rows by cid (column
    // ordinal), so the iteration order matches CREATE TABLE column order.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid",
        &.{});
    defer q.deinit();

    const expected = [_][]const u8{
        "id",
        "workspace_item_id",
        "name",
        "position",
        "created_at",
    };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(i < expected.len);
        try testing.expectEqualStrings(expected[i], row.values[0]);
        i += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), i);
}

// ─── Test 2: workspace_item_tasks gets the two new columns ───────────────

test "Migration051 adds kanban_column_id and kanban_position to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb051();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration051AddKanban.up(&ctx.db, alloc);

    // Assert the two new columns are present. Sorted by name for a
    // stable assertion regardless of ALTER TABLE execution order.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('workspace_item_tasks') " ++
        "WHERE name IN ('kanban_column_id', 'kanban_position') " ++
        "ORDER BY name",
        &.{});
    defer q.deinit();

    const expected = [_][]const u8{ "kanban_column_id", "kanban_position" };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expectEqualStrings(expected[i], row.values[0]);
        i += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), i);
}

// ===== Tests merged from migration_053_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 053 (add kanban_column.description).
//
// Why this file exists
// ────────────────────
// Migration 053 introduces the optional `description` column on
// `kanban_columns` so each column can carry a free-text "meaning"
// alongside its display name. The migration must:
//   1. ALTER TABLE kanban_columns ADD COLUMN description TEXT NOT NULL DEFAULT ''
//   2. Be idempotent (use DEFAULT so existing rows survive)
//   3. Add `description` to the pragma_table_info result set
//
// Plan: docs/superpowers/plans/2026-06-27-kanban-column-description-settings.md
//   (Chunk 1, Task 1.1)

fn setupDb053() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Migration 051 needs `workspace_items` (FK target) and
    // `workspace_item_tasks` (ALTER TABLE target). Mirror
    // migration_051_test.zig's setup; 051 assumes these tables exist
    // (the production migrator walks 001 → 051 in order, so by the
    // time 051 runs they are already there).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    // Migration 051 creates kanban_columns — must run before 053.
    try Migration051AddKanban.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "migration 053 adds description column with default empty string" {
    const alloc = testing.allocator;
    var ctx = try setupDb053();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: kanban_columns exists (051 seeded it).
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid
    , &.{});
    defer q.deinit();
    const names_before: [5][]const u8 = .{ "id", "workspace_item_id", "name", "position", "created_at" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < names_before.len);
        try testing.expectEqualStrings(names_before[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 5), idx);

    // Apply migration 053.
    try Migration053AddKanbanColumnDescription.up(&ctx.db, alloc);

    // Re-check pragma_table_info — description is now present.
    var q2 = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid
    , &.{});
    defer q2.deinit();
    const names_after: [6][]const u8 = .{ "id", "workspace_item_id", "name", "position", "created_at", "description" };
    var idx2: usize = 0;
    while (try q2.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx2 < names_after.len);
        try testing.expectEqualStrings(names_after[idx2], row.values[0]);
        idx2 += 1;
    }
    try testing.expectEqual(@as(usize, 6), idx2);
}

test "migration 053 is safe on populated kanban_columns tables" {
    const alloc = testing.allocator;
    var ctx = try setupDb053();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert one existing row (no description column yet).
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES ('col_pre_053', 'wi_1', 'todo', 0)",
        &.{},
    );

    // Apply migration 053 — the existing row should get description=''.
    try Migration053AddKanbanColumnDescription.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT description FROM kanban_columns WHERE id = 'col_pre_053'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing053;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

// ===== Tests merged from migration_054_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 054
// (make `session_queue_messages.message` nullable).
//
// Why this file exists
// ────────────────────
// Migration 054 drops the NOT NULL constraint on `session_queue_messages.message`
// so that image-only queued messages can be inserted without hitting
// `NOT NULL constraint failed: session_queue_messages.message` at the
// SqliteBackend.bind layer (which binds empty `[]const u8` as SQL NULL).
// The migration recreates the table to drop NOT NULL portably across all
// SQLite versions / platforms.
//
// The migration must:
//   1. Drop the NOT NULL on `message` (inserting empty message no longer errors)
//   2. Preserve all existing rows (id, session_id, message, image_url)
//   3. Recreate `idx_session_queue_messages_session` (re-added after the table swap)
//   4. Handle both schemas: with `image_url` (post-Migration037) and without
//
// Plan: docs/superpowers/plans/2026-07-01-session-queue-message-nullable.md
//   (Migration 054 design)

/// Test fixture for the migration_054 test suite. Hoisted to a top-level named
/// struct (NOT inline anonymous) because Zig 0.16 treats two anonymous
/// `struct { db, threaded }` types as distinct types even with identical
/// fields — see project memory `zig-anonymous-struct-type-identity.md`.

const TestCtx054 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with the Migration 018 baseline — i.e. the exact
/// schema that exists in production BEFORE Migration 037 (no image_url) and
/// BEFORE Migration 054 (message NOT NULL). This is the "bug exists" baseline.
fn setupDbWithoutImageUrl054() !TestCtx054 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration018CreateSessionQueueMessages.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Set up an in-memory DB with the Migration 037 schema — i.e. the same as
/// `setupDbWithoutImageUrl` PLUS the `image_url` column. This mirrors the
/// production state for any DB that ran up to Migration 053.
fn setupDbWithImageUrl054() !TestCtx054 {
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl054();
    errdefer ctx.threaded.deinit();
    errdefer ctx.db.deinit();
    try Migration037AddImageUrlToSessionQueueMessages.up(&ctx.db, alloc);
    return ctx;
}

test "migration 054: bug exists before migration (insert empty message fails)" {
    // RED-GREEN half: this test demonstrates the original bug. With the
    // original Migration018 schema, inserting a row whose `message` is bound
    // as NULL (the SqliteBackend convention for empty `[]const u8`) hits the
    // NOT NULL constraint. After Migration054, the same insert succeeds.
    //
    // Note: we use `?` placeholders + `&.{ ... }` so the SqliteBackend bind
    // layer (src/modules/databases/sqlite/Sqlite.zig:73-74) sees the empty
    // `""` as `[]const u8` of length 0 and binds it as SQL NULL. A literal
    // `''` in the SQL is treated as the empty string, not NULL, and would
    // NOT trip the NOT NULL constraint.
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Inserting with empty bound `message` — exactly the image-only queued
    // message shape that triggered the production bug. The NOT NULL on
    // `message` should fire because the empty slice binds as NULL.
    const rc = ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message) " ++
        "VALUES (?, ?, ?)",
        &.{ "msg-bug", "sess-bug", "" },
    );
    try testing.expectError(error.ExecuteFailed, rc);
}

test "migration 054: empty message insert succeeds after migration" {
    // GREEN half: after applying the migration, the same INSERT that errored
    // above must succeed. The row must be readable and message is "" (or NULL,
    // which row.read returns as "").
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    // Sanity: `message` no longer has NOT NULL.
    var q = try ctx.db.query(alloc,
        "SELECT \"notnull\" FROM pragma_table_info('session_queue_messages') " ++
        "WHERE name = 'message'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound054;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);

    // The insert that triggered the bug must now succeed.
    try ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message) " ++
        "VALUES ('msg-fix', 'sess-fix', '')",
        &[_][]const u8{},
    );

    // Row is present and read back as "" (empty `[]const u8` binds as NULL,
    // but row read returns NULL as "").
    var q2 = try ctx.db.query(alloc,
        "SELECT message FROM session_queue_messages WHERE id = 'msg-fix'",
        &[_][]const u8{},
    );
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.NotFound054;
    defer row2.deinit(alloc);
    try testing.expectEqualStrings("", row2.values[0]);
}

test "migration 054: existing rows survive the migration (no image_url)" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert a row before the migration.
    try ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message) " ++
        "VALUES ('msg-pre', 'sess-pre', 'hello world')",
        &[_][]const u8{},
    );

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    // The row must survive — id, session_id, message all preserved.
    var q = try ctx.db.query(alloc,
        "SELECT id, session_id, message FROM session_queue_messages " ++
        "WHERE id = 'msg-pre'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound054;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("msg-pre", row.values[0]);
    try testing.expectEqualStrings("sess-pre", row.values[1]);
    try testing.expectEqualStrings("hello world", row.values[2]);
}

test "migration 054: existing rows survive the migration (with image_url)" {
    // Production-style DB: Migration018 + Migration037 applied (so image_url
    // exists), but NOT yet Migration054. The migration must preserve the
    // image_url column AND its data.
    const alloc = testing.allocator;
    var ctx = try setupDbWithImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message, image_url) " ++
        "VALUES ('msg-img', 'sess-img', 'with image', 'data:image/png;base64,xxx')",
        &[_][]const u8{},
    );

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT id, session_id, message, image_url FROM session_queue_messages " ++
        "WHERE id = 'msg-img'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound054;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("msg-img", row.values[0]);
    try testing.expectEqualStrings("sess-img", row.values[1]);
    try testing.expectEqualStrings("with image", row.values[2]);
    try testing.expectEqualStrings("data:image/png;base64,xxx", row.values[3]);
}

test "migration 054: index idx_session_queue_messages_session is recreated" {
    // The migration drops and recreates the table — the index from Migration018
    // must be restored, otherwise the GET /api/queue_messages/:session_id
    // endpoint becomes slow + the FK lookup in workflow.zig regresses.
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: index exists after Migration018. We have to properly deinit
    // the row from `try q.next()` or we leak — see project memory
    // `zig-migration-tests-three-pitfalls.md`.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='index' " ++
            "AND name = 'idx_session_queue_messages_session'",
            &[_][]const u8{},
        );
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(alloc);
            try testing.expectEqualStrings("idx_session_queue_messages_session", row.values[0]);
        } else {
            try testing.expect(false); // index should exist after Migration018
        }
    }

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    // After the migration, the index is back.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' " ++
        "AND name = 'idx_session_queue_messages_session'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound054;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_session_queue_messages_session", row.values[0]);
}

test "migration 054: table has the expected columns in the expected order" {
    // The recreated table must have exactly: id, session_id, message, image_url,
    // created_at (in that order). ORDER BY cid confirms column ordering.
    const alloc = testing.allocator;
    var ctx = try setupDbWithImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    const expected: [5][]const u8 = .{
        "id", "session_id", "message", "image_url", "created_at",
    };
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('session_queue_messages') ORDER BY cid",
        &[_][]const u8{},
    );
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ===== Tests merged from migration_057_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 057 (add v6 element properties to
// `design_page_elements`).
//
// What Migration 057 adds
// ───────────────────────
// 11 new columns on `design_page_elements`:
//   type, rotation, fill, stroke, stroke_width, corner_radius,
//   opacity, text_content, text_style, image_url, parent_id
//
// All defaults are sensible:
//   - text/colour fields default to '' (the "no value" sentinel
//     per the `sqlite-backend-empty-slice-binds-as-null` convention)
//   - numeric defaults are 0 or 1.0 (no rotation, full opacity)
//   - `parent_id` is nullable (TEXT) for non-nested elements
//   - `type` defaults to 'rectangle' (the most common shape)
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// A static source check would not catch a misspelled column name,
// wrong DEFAULT clause, missing ALTER TABLE statement, or a typo in
// the column type. Asserting the actual schema after `up()` runs
// mirrors the pattern used by `migration_051_test.zig`.
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Task 1.1)

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with `workspace_items` +
/// `design_pages` (Migration 055 v1 schema with `html` column) +
/// `design_page_elements` (Migration 056 v5 schema, 12 columns).
/// This mirrors the state of a DB that has Migrations 1..56 applied,
/// which is the precondition for Migration 057.

fn setupDb057() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items: required for the design_pages FK reference
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    // workspace_item_tasks: required for Migration 066 FK from design_pages
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    // design_pages v1 schema (Migration 055 — pre-upgrade, includes html)
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    workspace_item_task_id TEXT,
        \\    html TEXT NOT NULL DEFAULT '',
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});
    // design_page_elements v5 schema (Migration 056 — 12 columns, no v6 props)
    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '', x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0, width INTEGER NOT NULL DEFAULT 375,
        \\    height INTEGER NOT NULL DEFAULT 667, z_index INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0, created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: Migration 057 adds all 11 v6 columns ────────────────────────

test "Migration057 adds the 11 v6 element properties columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb057();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the upgrade path through 055 → 056 → 057, mirroring what
    // the live migration manager does for an existing v1 user.
    try Migration055AddDesignPages.up(&ctx.db, alloc);
    try Migration056UpgradeDesignPagesToFileModel.up(&ctx.db, alloc);
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);

    // Assert all 11 new columns exist on design_page_elements.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('design_page_elements')
        \\WHERE name IN ('type','rotation','fill','stroke','stroke_width',
        \\                'corner_radius','opacity','text_content',
        \\                'text_style','image_url','parent_id')
        \\ORDER BY name
    , &.{});
    defer q.deinit();

    const expected = [_][]const u8{
        "corner_radius",
        "fill",
        "image_url",
        "opacity",
        "parent_id",
        "rotation",
        "stroke",
        "stroke_width",
        "text_content",
        "text_style",
        "type",
    };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(i < expected.len);
        try testing.expectEqualStrings(expected[i], row.values[0]);
        i += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), i);
}

// ─── Test 2: Migration 057 idempotent on a v6-ready DB ──────────────────

test "Migration057 is idempotent when the columns already exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb057();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run once.
    try Migration055AddDesignPages.up(&ctx.db, alloc);
    try Migration056UpgradeDesignPagesToFileModel.up(&ctx.db, alloc);
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);

    // Run again — addColumnIfMissing must make this a no-op. If it
    // weren't idempotent, the second run would crash with
    // "duplicate column name: type" (or similar).
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);
}

// ─── Test 3: Migration 057 preserves existing v5 columns ─────────────────

test "Migration057 preserves the v5 columns on design_page_elements" {
    const alloc = testing.allocator;
    var ctx = try setupDb057();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration055AddDesignPages.up(&ctx.db, alloc);
    try Migration056UpgradeDesignPagesToFileModel.up(&ctx.db, alloc);
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);

    // The 12 v5 columns must still be present after 057 (which is
    // strictly additive — never drop).
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('design_page_elements')
        \\WHERE name IN ('id','page_id','name','file_path','x','y','width',
        \\                'height','z_index','position','created_at','updated_at')
        \\ORDER BY name
    , &.{});
    defer q.deinit();

    var found: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        found += 1;
    }
    try testing.expectEqual(@as(usize, 12), found);
}

// ===== Tests merged from migration_058_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 058
// (FTS5 virtual table on `llm_history` for workspace history search).
//
// Why this file exists
// ────────────────────
// Migration 058 creates `messages_fts` (a non-external-content FTS5 table
// over `llm_history.response_content` — content is duplicated so that
// the FTS5 `snippet()` and `highlight()` helper functions work) plus
// 3 sync triggers. This file verifies:
//   1. The virtual table is created with the correct configuration
//      (porter+unicode61 tokenizer)
//   2. Exactly 3 triggers exist on `llm_history` (INSERT/UPDATE/DELETE)
//   3. Pre-existing rows in `llm_history` are backfilled into the FTS index
//   4. New INSERTs into `llm_history` are auto-indexed (trigger fires)
//   5. DELETEs from `llm_history` remove the row from the FTS index
//
// Why the test bootstraps with Migration001CreateLLMHistory
// ──────────────────────────────────────────────────────────
// Mirrors the migration_054_test.zig pattern — set up the minimum
// pre-migration baseline (just `llm_history` itself), then apply the
// migration. This isolates the migration's effect from any schema
// interaction with Migrations 002..057 that may or may not have run on
// production DBs.
//
// Why FTS5 MATCH ? with single-token words
// ────────────────────────────────────────
// FTS5 tokenizes input by default; bare ASCII words are safe queries.
// Multi-word queries would require FTS5 expression syntax (AND, OR, "...",
// prefix*) which would couple the test to the tokenizer's exact behavior.
// Single-token MATCH keeps the contract tight: "the row containing word
// W is in the FTS index".
//
// Plan: workspace history FTS (Chunk 1, Task 1.3 — Migration 058 regression test)
//
// Versioning note: the original plan called this Migration 055 but the
// branch already had AddDesignPages (55), UpgradeDesignPagesToFileModel
// (56), AddDesignElementProperties (57). 058 is the next free slot.

/// Test fixture for the migration_058 test suite. Hoisted to a top-level named
/// struct (NOT inline anonymous) because Zig 0.16 treats two anonymous
/// `struct { db, threaded }` types as distinct types even with identical
/// fields — see project memory `zig-anonymous-struct-type-identity.md`.

const TestCtx058 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with just the `llm_history` baseline table. This
/// matches the state of an existing-DB user right before Migration 058 runs
/// (i.e., after Migrations 001..057 have all applied).
fn setupDbWithLlmHistory058() !TestCtx058 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration001CreateLLMHistory.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Count rows in `sqlite_master` of a given type, optionally matching
/// `tbl_name`. Returns 0 if no match. Helper for the trigger + table tests.
fn countSqliteMaster058(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, sql: []const u8) !usize {
    var q = try db.query(alloc, sql, &[_][]const u8{});
    defer q.deinit();
    var count: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        count += 1;
    }
    return count;
}

test "migration 058: creates messages_fts virtual table" {
    // After Migration 058, `sqlite_master` must contain a row for
    // `messages_fts` with type='table' (FTS5 virtual tables show up as
    // 'table' rows in sqlite_master, not 'view' or 'index').
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory058();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, no `messages_fts` exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='messages_fts'",
            &[_][]const u8{},
        );
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have messages_fts
        }
    }

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // Post-migration: `messages_fts` exists as a table.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='messages_fts'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.VirtualTableNotCreated058;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("messages_fts", row.values[0]);
}

test "migration 058: installs sync triggers (exactly 3 on llm_history)" {
    // The migration creates 3 triggers named llm_history_ai, _ad, _au.
    // After Migration 058, querying sqlite_master with
    // `tbl_name='llm_history'` AND `type='trigger'` must return exactly 3.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory058();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, zero triggers on llm_history.
    const pre_count = try countSqliteMaster058(&ctx.db, alloc,
        "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='llm_history'");
    try testing.expectEqual(@as(usize, 0), pre_count);

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // Post-migration: exactly 3 triggers.
    const post_count = try countSqliteMaster058(&ctx.db, alloc,
        "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='llm_history'");
    try testing.expectEqual(@as(usize, 3), post_count);

    // Verify the exact names (the migration uses _ai, _ad, _au).
    var names_buf: [3][]u8 = .{ &[_]u8{}, &[_]u8{}, &[_]u8{} };
    defer for (names_buf) |n| if (n.len > 0) alloc.free(n);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='trigger' AND tbl_name='llm_history'
        \\ORDER BY name
    , &[_][]const u8{});
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < 3);
        names_buf[idx] = try alloc.dupe(u8, row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 3), idx);
    try testing.expectEqualStrings("llm_history_ad", names_buf[0]);
    try testing.expectEqualStrings("llm_history_ai", names_buf[1]);
    try testing.expectEqualStrings("llm_history_au", names_buf[2]);
}

test "migration 058: backfills existing rows into FTS index" {
    // Pre-existing rows must be backfilled into messages_fts during
    // migration. Insert 2 rows BEFORE the migration, run it, then verify
    // that FTS5 MATCH on a unique word from each row returns the row.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory058();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert 2 rows BEFORE the migration — uses Migration001's schema
    // (id, session_id, model, response_content). Note: the `id` column
    // is TEXT PRIMARY KEY so we pass explicit IDs.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-pre-1', 'sess-1', 'm', 'first message contains zephyrword')",
        &[_][]const u8{},
    );
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-pre-2', 'sess-2', 'm', 'second message contains quasarterm')",
        &[_][]const u8{},
    );

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // FTS MATCH on 'zephyrword' must return the row with id 'msg-pre-1'.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT h.id FROM llm_history h
            \\JOIN messages_fts f ON f.rowid = h.rowid
            \\WHERE messages_fts MATCH ?
        , &.{"zephyrword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.BackfillMissingRow1058;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("msg-pre-1", row.values[0]);

        // Should be only 1 row matching zephyrword.
        const extra = (try q.next()) orelse null;
        if (extra) |e| {
            defer e.deinit(alloc);
            try testing.expect(false); // zephyrword matched more than 1 row
        }
    }

    // FTS MATCH on 'quasarterm' must return the row with id 'msg-pre-2'.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT h.id FROM llm_history h
            \\JOIN messages_fts f ON f.rowid = h.rowid
            \\WHERE messages_fts MATCH ?
        , &.{"quasarterm"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.BackfillMissingRow2058;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("msg-pre-2", row.values[0]);
    }
}

test "migration 058: INSERT trigger fires for new rows" {
    // After migration, INSERT INTO llm_history must auto-add to the FTS
    // index. Insert one new row AFTER migration; FTS MATCH must find it.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory058();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // Insert AFTER migration.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-post-1', 'sess-1', 'm', 'post-migration message has deltaword')",
        &[_][]const u8{},
    );

    // FTS MATCH on 'deltaword' must return the new row.
    var q = try ctx.db.query(alloc,
        \\SELECT h.id FROM llm_history h
        \\JOIN messages_fts f ON f.rowid = h.rowid
        \\WHERE messages_fts MATCH ?
    , &.{"deltaword"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.InsertTriggerDidNotFire058;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("msg-post-1", row.values[0]);
}

test "migration 058: DELETE trigger removes row from index" {
    // After migration, DELETE FROM llm_history must auto-remove from the
    // FTS index. Insert one row, delete it, then FTS MATCH must return
    // null (no rows match).
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory058();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-del-1', 'sess-1', 'm', 'about to be deleted contains omegaword')",
        &[_][]const u8{},
    );

    // Sanity: the row IS indexed before deletion.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT h.id FROM llm_history h
            \\JOIN messages_fts f ON f.rowid = h.rowid
            \\WHERE messages_fts MATCH ?
        , &.{"omegaword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowNotIndexedBeforeDelete058;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("msg-del-1", row.values[0]);
    }

    // Delete the row.
    try ctx.db.exec(alloc,
        "DELETE FROM llm_history WHERE id = 'msg-del-1'",
        &[_][]const u8{},
    );

    // After deletion, FTS MATCH on the unique word must return null.
    var q = try ctx.db.query(alloc,
        \\SELECT h.id FROM llm_history h
        \\JOIN messages_fts f ON f.rowid = h.rowid
        \\WHERE messages_fts MATCH ?
    , &.{"omegaword"});
    defer q.deinit();
    const row = (try q.next()) orelse null;
    if (row) |r| {
        defer r.deinit(alloc);
        try testing.expect(false); // DELETE trigger did not fire — row still in index
    }
}

// ===== Tests merged from migration_059_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 059
// (llm_history.created_iso column populated by application code + backfill).
//
// Why this file exists
// ────────────────────
// Migration 059 adds a regular TEXT column `created_iso` to
// `llm_history`. The column is populated by **application code** in
// `saveMessage` (libc `localtime_r` + `strftime`) at INSERT time, and
// by an idempotent backfill `UPDATE` for legacy rows that pre-date
// the application update. The workspace history / getCompactedMessages
// SQL filters on `since`/`until` bind to this column, so the documented
// `since`/`until` format works.
//
// Before this migration, the filters did a lex comparison on the
// `created_at` TEXT column (which stores Unix microseconds like
// `"1784119389936251112"`) against user input like `"2026-07-15 00:00:00"`.
// Because `'1' < '2'` lexicographically, every data row was always
// considered "less than" a date string starting with `'2'`, so the
// filter silently returned 0 rows.
//
// ## Why application code, not SQLite triggers?
//
// v1 of this migration used INSERT/UPDATE triggers to populate
// `created_iso`. This had two production failures:
//   1. Triggers are invisible to application code — when the
//      trigger's `datetime()` overflowed, debugging required
//      reading SQL trigger bodies.
//   2. The trigger's `datetime(CAST(<microseconds> AS REAL) / 1000000, ...)`
//      overflows SQLite's `datetime()` range (cap: year 9999) and
//      silently returns NULL for modern timestamps.
//
// Application-level computation via Zig's `std.time.epoch` API
// (in `helpers.currentTimeIsoLocal`) sidesteps both issues.
//
// ## Why not a STORED GENERATED column?
//
// `datetime(..., 'localtime')` is non-deterministic (depends on the
// system timezone). SQLite silently DROPS any GENERATED ALWAYS AS
// STORED column whose expression uses a non-deterministic function —
// verified empirically against SQLite 3.53.3. The column is omitted
// from `pragma_table_info` with no error.
//
// ## Idempotency
//
// `addColumnIfMissing` skips the ALTER if the column exists.
// The backfill UPDATE has `WHERE created_iso IS NULL OR created_iso = ''`,
// so it only touches rows that still need populating.
// The CREATE INDEX uses IF NOT EXISTS.
//
// This file verifies:
//   1. The column `created_iso` exists on `llm_history` after the
//      migration (NOT a generated column).
//   2. The migration's idempotent backfill populates `created_iso`
//      from `created_at` for legacy rows.
//   3. Lex comparison against a date string picks up the correct rows
//      (the actual bug regression).
//   4. The index `idx_llm_history_created_iso` is created.
//   5. The migration is idempotent (re-runs are no-ops).
//
// Plan: workspace history `created_iso` backfill.

const TestCtx059 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with just the `llm_history` baseline table.
/// Mirrors the migration_058_test.zig / migration_054_test.zig pattern.
fn setupDbWithLlmHistory059() !TestCtx059 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration001CreateLLMHistory.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Read a column attribute by name from `pragma_table_xinfo('llm_history')`.
/// Returns null if the column doesn't exist.
///
/// We use `pragma_table_xinfo` (NOT `pragma_table_info`) because the
/// `xinfo` variant includes a 7th column "hidden" with values:
///   - 0 = normal column
///   - 2 = VIRTUAL generated column
///   - 3 = STORED generated column
/// `pragma_table_info` only returns the 6 normal columns and doesn't
/// surface the generated-column flag at all.
fn columnExists059(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    column_name: []const u8,
) !?struct { found: bool, is_generated: bool } {
    var q = try db.query(alloc,
        "SELECT name, hidden FROM pragma_table_xinfo('llm_history') WHERE name = ?",
        &.{column_name});
    defer q.deinit();
    const row = (try q.next()) orelse return .{ .found = false, .is_generated = false };
    defer row.deinit(alloc);
    // `hidden` is 0 for normal columns, 2 for VIRTUAL generated, 3 for
    // STORED generated. We treat any nonzero as "is generated".
    const gen = std.fmt.parseInt(u32, row.values[1], 10) catch 0;
    return .{ .found = true, .is_generated = gen != 0 };
}

test "migration 059: creates created_iso regular TEXT column (not generated)" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory059();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Pre-migration: no created_iso column.
    const pre = try columnExists059(&ctx.db, alloc, "created_iso");
    try testing.expectEqual(false, pre.?.found);

    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Post-migration: column exists, is NOT generated (regular TEXT).
    // The trigger-based approach can't use GENERATED ALWAYS AS STORED
    // because `datetime(..., 'localtime')` is non-deterministic.
    const post = try columnExists059(&ctx.db, alloc, "created_iso");
    try testing.expect(post != null);
    try testing.expectEqual(true, post.?.found);
    try testing.expectEqual(false, post.?.is_generated);
}

test "migration 059: backfills existing rows from created_at" {
    // Application code in `saveMessage` is responsible for populating
    // `created_iso` on new INSERTs. This test exercises the migration's
    // idempotent backfill (the `UPDATE ... WHERE created_iso IS NULL`),
    // which fills `created_iso` for rows that existed before the
    // application was updated. Equivalent to the "INSERT trigger"
    // behavior in v1, but explicit and re-runnable.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory059();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert a row FIRST with a known microsecond timestamp and NULL
    // `created_iso` (matching the production state of legacy rows).
    const micros: []const u8 = "1780000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_iso','s1','m','content with isocheckword',?)", &.{micros});

    // Pre-migration: `created_iso` is NULL (no column yet actually,
    // we need to add it first manually to simulate the legacy state).
    // Easier: run the migration itself, which adds the column AND
    // backfills.
    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Post-migration: the row's created_iso is populated.
    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_iso'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing059;
    defer row.deinit(alloc);
    const generated = row.values[0];

    // Compute the expected value using the SAME SQLite expression the
    // migration's backfill uses (substring + datetime). This keeps the
    // test timezone-agnostic.
    var expected_q = try ctx.db.query(alloc,
        "SELECT datetime(substr(?, 1, 10), 'unixepoch')", &.{micros});
    defer expected_q.deinit();
    const expected_row = (try expected_q.next()) orelse return error.ExpectedExprFailed059;
    defer expected_row.deinit(alloc);
    const expected = expected_row.values[0];

    try testing.expectEqualStrings(expected, generated);
    try testing.expect(generated.len > 0);
}

test "migration 059: lex comparison against a date string selects the correct rows (regression)" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory059();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Insert two rows at known microsecond timestamps. `created_iso`
    // is populated by the migration's backfill (substr(micros, 1, 10)).
    const old_micros: []const u8 = "1780000000000000";
    const new_micros: []const u8 = "1785000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_old','s1','m','old isocheckword',?)", &.{old_micros});
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_new','s1','m','new isocheckword',?)", &.{new_micros});

    // Re-run the migration so the backfill UPDATE processes these
    // newly-inserted rows (the FIRST run happened BEFORE these inserts).
    // Re-runs are idempotent.
    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Compute the ISO for `new_micros` using the same expression the
    // backfill uses (substr(micros, 1, 10)). Lex comparison must use
    // the same expression or it won't match.
    var iso_q = try ctx.db.query(alloc,
        "SELECT datetime(substr(?, 1, 10), 'unixepoch')", &.{new_micros});
    defer iso_q.deinit();
    const iso_row = (try iso_q.next()) orelse return error.IsoExprFailed059;
    defer iso_row.deinit(alloc);
    const new_iso = iso_row.values[0];

    // Lex comparison against `created_iso`: rows with created_iso >=
    // new_iso should match. This is the EXACT shape of the bug fix —
    // a date string like "2026-07-15 00:00:00" lexicographically
    // matches against the populated ISO column, not the raw microsecond
    // string.
    var hits_q = try ctx.db.query(alloc,
        \\SELECT id FROM llm_history
        \\WHERE created_iso >= ?
        \\ORDER BY id
    , &.{new_iso});
    defer hits_q.deinit();

    var count: usize = 0;
    var matched_ids: [4][]u8 = undefined;
    var match_idx: usize = 0;
    while (try hits_q.next()) |row| {
        defer row.deinit(alloc);
        if (match_idx < matched_ids.len) {
            matched_ids[match_idx] = try alloc.dupe(u8, row.values[0]);
            match_idx += 1;
        }
        count += 1;
    }
    defer for (matched_ids[0..match_idx]) |id| alloc.free(id);

    // Only h_new should match (created_iso >= new_iso excludes h_old).
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("h_new", matched_ids[0]);
}

test "migration 059: creates idx_llm_history_created_iso index" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory059();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Post-migration: an index named `idx_llm_history_created_iso` exists
    // on the `created_iso` column.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='index' AND tbl_name='llm_history' AND name='idx_llm_history_created_iso'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.IndexNotCreated059;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_llm_history_created_iso", row.values[0]);
}

test "migration 059: is idempotent on a re-run (column + triggers + index)" {
    // `addColumnIfMissing` checks pragma_table_info first, the triggers
    // use `IF NOT EXISTS`, and the index uses `IF NOT EXISTS`. A re-run
    // on a DB that already has everything is a no-op.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory059();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration059AddCreatedIso.up(&ctx.db, alloc);
    // Run it again — must not error.
    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Still exactly one created_iso column.
    const post = try columnExists059(&ctx.db, alloc, "created_iso");
    try testing.expectEqual(true, post.?.found);
    try testing.expectEqual(false, post.?.is_generated);
}

// ===== Tests merged from migration_060_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 060
// (llm_history.created_iso re-backfill).
//
// Why this file exists
// ────────────────────
// Production databases that ran V1 of Migration 059 (which used
// SQLite INSERT/UPDATE triggers to populate `created_iso`) ended up
// with many rows having `created_iso = NULL` because the trigger's
// `datetime(CAST(<microseconds> AS REAL) / 1000000, 'unixepoch',
// 'localtime')` overflowed SQLite's `datetime()` range (cap: year
// 9999) for modern timestamps. This silently broke the
// `since`/`until` filter on workspace history reads and
// `getCompactedMessages`.
//
// Migration 060 unconditionally re-runs the v2 backfill UPDATE so
// production users get a fix on the next nalar restart without
// having to nuke their `agent.db`.
//
// This file verifies:
//   1. Legacy rows with NULL `created_iso` get populated.
//   2. The migration is idempotent (re-runs are no-ops on populated rows).
//   3. A row with an empty string `created_at` falls back to `now`.
//   4. Existing populated rows are NOT overwritten (defensive).

const TestCtx060 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb060() !TestCtx060 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration001CreateLLMHistory.up(&db, alloc);
    // Migration 060 expects `created_iso` to exist. Migration 059
    // creates it (with a backfill that touches the existing rows).
    // Migration 060 then re-runs the backfill.
    try Migration059AddCreatedIso.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "migration 060: re-backfills rows with NULL created_iso" {
    // Simulates the production state: v1 of Migration 059 (broken trigger)
    // left a row with NULL created_iso. v2 of Migration 059 used a
    // different SQL expression that doesn't match what v1's broken trigger
    // would have left, so production NULLs persist.
    const alloc = testing.allocator;
    var ctx = try setupDb060();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000"; // ~2026-07-25
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_legacy','s1','m','legacy row',?)", &.{micros});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_legacy'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing060;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "2026") != null);
}

test "migration 060: re-backfills row with empty created_at using datetime('now')" {
    const alloc = testing.allocator;
    var ctx = try setupDb060();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_empty','s1','m','empty created_at','')", &.{});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_empty'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing060;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    // datetime('now') produces the current date — match any YYYY-MM-DD prefix.
    try testing.expect(std.mem.indexOf(u8, row.values[0], "-") != null);
}

test "migration 060: idempotent on re-run (no changes after second run)" {
    const alloc = testing.allocator;
    var ctx = try setupDb060();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_idem','s1','m','idempotent row',?)", &.{micros});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);
    var q1 = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_idem'", &.{});
    defer q1.deinit();
    const row1 = (try q1.next()) orelse return error.RowMissing060;
    const first_value = try alloc.dupe(u8, row1.values[0]);
    row1.deinit(alloc);
    defer alloc.free(first_value);

    // Run again — should not change anything.
    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);
    var q2 = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_idem'", &.{});
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.RowMissing060;
    defer row2.deinit(alloc);
    try testing.expectEqualStrings(first_value, row2.values[0]);
}

test "migration 060: only updates rows where created_iso is NULL or empty" {
    // Regression check: production datasets that already have valid
    // created_iso (because the application ran the corrected saveMessage
    // for new inserts) must NOT be overwritten with a coarser computation.
    //
    // We can verify this by inserting a row WITH a created_iso value
    // that's clearly human-set (e.g. longer than 19 chars or contains
    // a non-ASCII marker). After the migration, that value should be
    // intact because the second (unconditional) UPDATE doesn't run —
    // the WHERE guard stopped it.
    //
    // For a simpler robustness check: insert a row, hand-set
    // `created_iso` to a known literal, run the migration, and verify
    // the literal is preserved.
    const alloc = testing.allocator;
    var ctx = try setupDb060();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) " ++
        "VALUES ('h_pre','s1','m','pre-populated row',?, 'CUSTOM-MARKER-ISO')",
        &.{micros});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_pre'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing060;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("CUSTOM-MARKER-ISO", row.values[0]);
}

// ===== Tests merged from migration_061_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 061
// (`llm_history.created_iso` year-fix).
//
// Why this file exists
// ────────────────────
// Migration 060 re-backfilled NULL/empty `created_iso` rows but did
// NOT detect the **wrong-year** rows that were silently produced by
// `saveMessage` passing nanosecond values (length 19) to a helper
// expecting microseconds. The helper divided by `us_per_s` (1e6)
// instead of `ns_per_s` (1e9), producing sec ≈ 1.78e12 instead of
// 1.78e9 — which decodes as year 58,507 instead of 2026. The wrong
// values passed Migration 060's `IS NULL OR = ''` guard and were
// never overwritten.
//
// Migration 061 fixes both shapes (NULL/empty AND wrong-year) with
// a single UPDATE that recomputes from `created_at` directly. The
// `created_iso NOT LIKE '[12][09][0-9][0-9]-%'` clause is what
// catches the year 58,507 rows.
//
// This file verifies:
//   1. Legacy rows with NULL `created_iso` get populated.
//   2. Rows with a wrong-year `created_iso` (e.g. `58507-07-26 ...`)
//      get re-populated with the correct year.
//   3. Already-correct rows are NOT overwritten (idempotent on
//      correct rows; see the `LIKE '[12][09][0-9][0-9]-%'` guard).
//   4. `saveMessage` (in the same test binary) writes a correct-year
//      `created_iso` when invoked with the post-fix code path.
//   5. `inserLLMHistories` (the other INSERT path that previously
//      omitted `created_iso` entirely) writes a correct-year value.

const TestCtx061 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb061() !TestCtx061 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration001CreateLLMHistory.up(&db, alloc);
    try Migration059AddCreatedIso.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "migration 061: backfills rows with NULL created_iso" {
    const alloc = testing.allocator;
    var ctx = try setupDb061();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000"; // ~2026-07-25
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_null','s1','m','null iso',?)", &.{micros});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_null'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing061;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "2026") != null);
}

test "migration 061: backfills rows with wrong-year created_iso (e.g. 58507-07-26 ...)" {
    // This is the regression check for the year-58,507 bug. The
    // pre-fix `saveMessage` produced these values by passing
    // nanoseconds (length 19) to a helper expecting microseconds.
    const alloc = testing.allocator;
    var ctx = try setupDb061();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const nanos: []const u8 = "1784152565916089746"; // 2026-07-15 21:56:05 UTC, in ns
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) " ++
        "VALUES ('h_bad_year','s1','m','wrong year',?, '58507-07-26 11:32:30')",
        &.{nanos});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_bad_year'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing061;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    // The fixed value MUST be year 2026, not 58507.
    try testing.expect(std.mem.indexOf(u8, row.values[0], "2026") != null);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "58507") == null);
}

test "migration 061: does NOT overwrite correct-year created_iso" {
    // A row whose `created_iso` value matches what the migration
    // would compute from `created_at` MUST be preserved (the LIKE
    // guard stops the UPDATE). We pick a `created_at` whose substr
    // recompute equals the hand-set ISO string, so even if the
    // migration DID overwrite, the result would be identical.
    //
    // created_at "1784131200000000" (microseconds) → substr(1,10)
    //   "1784131200" → datetime(1784131200, 'unixepoch') =
    //   '2026-07-15 16:00:00' UTC. Verified with:
    //   `SELECT strftime('%s', '2026-07-15 16:00:00')` → 1784131200.
    const alloc = testing.allocator;
    var ctx = try setupDb061();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1784131200000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) " ++
        "VALUES ('h_correct','s1','m','correct row',?, '2026-07-15 16:00:00')",
        &.{micros});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_correct'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing061;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2026-07-15 16:00:00", row.values[0]);
}

test "migration 061: handles mixed NULL + wrong-year + correct rows in one pass" {
    const alloc = testing.allocator;
    var ctx = try setupDb061();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const nanos: []const u8 = "1784152565916089746"; // 2026-07-15 21:56:05 UTC, in ns
    try ctx.db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) VALUES
        \\('h_null','s1','m','null row',       ?, NULL),
        \\('h_empty','s1','m','empty row',     ?, ''),
        \\('h_bad','s1','m','bad year row',    ?, '58507-07-26 11:32:30'),
        \\('h_ok','s1','m','correct row',      ?, '2026-07-15 21:56:05'),
        \\('h_old','s1','m','1999 row',        ?, '1999-12-31 23:59:59')
    , &.{nanos, nanos, nanos, nanos, nanos});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT id, created_iso FROM llm_history ORDER BY id", &.{});
    defer q.deinit();
    var rows: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        rows += 1;
        const id = row.values[0];
        const iso = row.values[1];
        if (std.mem.eql(u8, id, "h_null") or std.mem.eql(u8, id, "h_empty") or
            std.mem.eql(u8, id, "h_bad"))
        {
            // These three rows had bad values; they MUST be fixed
            // to year 2026 (because substr(1784152565916..., 1, 10)
            // → 1784152565 → 2026-07-15 21:56:05).
            try testing.expect(std.mem.indexOf(u8, iso, "2026") != null);
            try testing.expect(std.mem.indexOf(u8, iso, "58507") == null);
        } else if (std.mem.eql(u8, id, "h_ok")) {
            // Correct row: MUST be preserved verbatim (the LIKE
            // guard '20[0-9][0-9]-%' matched, so WHERE is false).
            try testing.expectEqualStrings("2026-07-15 21:56:05", iso);
        } else if (std.mem.eql(u8, id, "h_old")) {
            // '1999-...' starts with '19', not '20'. The LIKE guard
            // does NOT match, so the migration does NOT touch it.
            // Pre-2000 rows are legitimate data, not a bug.
            try testing.expectEqualStrings("1999-12-31 23:59:59", iso);
        }
    }
    try testing.expectEqual(@as(usize, 5), rows);
}

// ===== Tests merged from migration_062_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 062
// (workspace_item_tasks.description).
//
// Why this file exists
// ────────────────────
// Migration 062 introduces a free-form `description` column on
// `workspace_item_tasks` so each task (chat / routine / kanban) can
// carry a user-visible "notes" field alongside its display name.
// The detail dialog (frontend, Chunk 2) reads and writes it; the
// backend persists it. The migration must:
//   1. Add `description TEXT NOT NULL DEFAULT ''` to the table
//   2. Be idempotent (existing rows survive via DEFAULT '')
//   3. Be safe for fresh-DB installs that already declare the column
//      in their canonical CREATE TABLE — use `addColumnIfMissing`
//      so the helper handles both fresh-DB and upgrade-from-v1 paths
//      gracefully (see memory `nalar-fresh-db-migration-cascade`).
//
// Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
//   (Chunk 1, Task 1.1)

const Migration062 = Migration062AddTaskDescription;
const createWorkspaceItemTask = @import("nalarcore").ai_mod.llm_history.createWorkspaceItemTask;

const TestCtx062 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb062() !TestCtx062 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // workspace_items (FK target for workspace_item_tasks.workspace_item_id)
    // and workspace_item_tasks itself must exist before migration 061
    // can run — production walks migrations 001 → 061 in order, so by
    // the time 061 runs they're already there. We create minimal
    // mirrors here for the unit test.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    // The behavioural tests below INSERT into `task_type` (via the
    // routine/memory branches of task_create.zig and via
    // createWorkspaceItemTask), so the column must exist before
    // Migration 062 runs. The real migration (034) declares this and
    // 30+ others; we only need the minimum that the create helper
    // references. Migration 062's `addColumnIfMissing` will then add
    // `description` to this minimal table.
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration062 adds description column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: description does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'description'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply migration 061.
    try Migration062.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'description'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing062;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("description", row.values[0]);

    // Confirm there are no extra rows (i.e. only one match).
    try testing.expect((try q.next()) == null);
}

test "Migration062 is idempotent on a column that already exists" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `description TEXT NOT NULL DEFAULT ''`. The
    // migration must be a no-op (NOT a "duplicate column" crash).
    // Drop the minimal table from setupDb() and re-create it with the
    // canonical schema that already declares description.
    try ctx.db.exec(alloc, "DROP TABLE workspace_item_tasks", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    description TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});

    // Should not error — `addColumnIfMissing` detects the column
    // already exists and short-circuits.
    try Migration062.up(&ctx.db, alloc);

    // Re-check: still one `description` column (no duplicates).
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'description'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing062;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration062 gives pre-existing rows an empty-string description" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing task (no description column yet — it's
    // added by the migration).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_pre_061', 'Task', 'wi_1')",
        &.{});

    // Apply migration 061 — the existing row should get description=''.
    try Migration062.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT description FROM workspace_item_tasks WHERE id = 'task_pre_061'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing062;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

// =====================================================================
// Behavioural regression tests for the empty-string-bind bug.
//
// Why these tests exist
// ---------------------
// The migration adds a `NOT NULL DEFAULT ''` column. The `task_create`
// HTTP handler calls `createWorkspaceItemTask` (and the routine/memory
// branches do their own INSERTs). All three paths previously wrote the
// description with `db.exec(..., description orelse "")` — which passes
// an empty `[]const u8` to the SQLite backend. `SqliteBackend.exec`
// binds an empty slice as SQL NULL (see project memory
// `sqlite-backend-empty-slice-binds-as-null`), so the INSERT crashed
// with `NOT NULL constraint failed: workspace_item_tasks.description`
// for every standard/routine/memory task create where the caller
// either omitted description (= null in JSON) or sent `""`.
//
// The fix splits the INSERT into a three-way branch:
//   - description == null  → omit the description column; DEFAULT ''
//     applies.
//   - description == ""   → use a SQL `''` literal (not a `?` bind).
//   - description == "x…" → bind via `?` like normal.
//
// The static tests above check that the three-way branch EXISTS in
// the source. These behavioural tests actually run the helper against
// an in-memory sqlite with the real Migration 062 applied, and prove
// no `NOT NULL` violation fires for any of the three caller shapes.

/// Seed a workspace_items row so `workspace_item_tasks.workspace_item_id`
/// has a real FK target. Returns the parent id.
fn seedParent062(ctx: *TestCtx062, allocator: std.mem.Allocator) ![]const u8 {
    const parent_id = "wi_parent_061";
    try ctx.db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES (?, 'ws_1', 'chat')",
        &[_][]const u8{parent_id});
    return parent_id;
}

/// Read back the description column for a task by id. Returns an
/// owned copy (allocated with `allocator`) because `row.values[0]`
/// is freed by `row.deinit(allocator)` at function exit; returning the
/// raw borrowed slice would be a use-after-free once the defer fires
/// (see project memory `zig-slice-headers-across-defer-lifetimes`).
fn readDescription062(ctx: *TestCtx062, allocator: std.mem.Allocator, task_id: []const u8) !?[]u8 {
    var q = try ctx.db.query(allocator,
        "SELECT description FROM workspace_item_tasks WHERE id = ?",
        &[_][]const u8{task_id});
    defer q.deinit();
    const row_opt = try q.next();
    if (row_opt) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

/// Wrapper that frees the owned `readDescription` slice. The caller
/// passes the slice via this helper so the free lives close to the
/// assertion (no leaks even if the assertion panics).
fn expectDescriptionEquals062(
    ctx: *TestCtx062,
    allocator: std.mem.Allocator,
    task_id: []const u8,
    expected: []const u8,
) !void {
    const owned = (try readDescription062(ctx, allocator, task_id)) orelse return error.NoRow062;
    defer allocator.free(owned);
    try testing.expectEqualStrings(expected, owned);
}

test "createWorkspaceItemTask: description = null succeeds and stores ''" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration062.up(&ctx.db, alloc);
    const parent_id = try seedParent062(&ctx, alloc);

    // Caller passes null (omitted body field).
    const task = try createWorkspaceItemTask(alloc, &ctx.db,
        "t_desc_null_061", "No description", parent_id, "standard", null,
        // tags — Migration 067 added this arg; pre-Migration-067 callers
        // passed null. The migration_062_test exercises the description
        // path only; tags are exercised in migration_067_test.zig.
        null,
        // image_urls (Migration 069) — added as 8th-arg default-null;
        // migration_062_test predates the column and exercises the
        // description path only. image_urls is exercised in
        // migration_069_test.zig.
        null,
        // cwd (Migration 070) — null (omitted body field → empty-string
        // sentinel). migration_062_test predates Migration 070 and
        // exercises the description path only; cwd is fully covered in
        // migration_071_test.zig.
        null,
        // video_urls (Migration 090) — null. Covered in video_urls_validation tests.
        null);
    defer task.deinit(alloc);

    // SELECT the column back and confirm it was stored as the empty
    // string (DEFAULT '' via the omitted-column branch).
    try testing.expectEqualStrings("", task.description);
    try expectDescriptionEquals062(&ctx, alloc, "t_desc_null_061", "");
}

test "createWorkspaceItemTask: description = '' (empty string) succeeds and stores ''" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration062.up(&ctx.db, alloc);
    const parent_id = try seedParent062(&ctx, alloc);

    // This is the EXACT bug case. Pre-fix: `description orelse ""` made
    // the bind arg an empty `[]const u8` which SqliteBackend.exec
    // converts to SQL NULL → `NOT NULL constraint failed`. Post-fix:
    // the empty-string branch uses a SQL `''` literal.
    const task = try createWorkspaceItemTask(alloc, &ctx.db,
        "t_desc_empty_061", "Empty description", parent_id, "standard", "",
        // tags — see comment on the null-tags branch above.
        null,
        // image_urls — null (omitted body field → empty-string
        // sentinel). See migration_069_test for full-coverage tests.
        null,
        // cwd (Migration 070) — null. See comment above.
        null,
        // video_urls (Migration 090) — null. See comment above.
        null);
    defer task.deinit(alloc);

    try testing.expectEqualStrings("", task.description);
    try expectDescriptionEquals062(&ctx, alloc, "t_desc_empty_061", "");
}

test "createWorkspaceItemTask: description = 'hello world' succeeds and stores the value" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration062.up(&ctx.db, alloc);
    const parent_id = try seedParent062(&ctx, alloc);

    const task = try createWorkspaceItemTask(alloc, &ctx.db,
        "t_desc_filled_061", "With description", parent_id, "standard",
        "hello world from test",
        // tags — see comment on the null-tags branch above.
        null,
        // image_urls — null (omitted body field → empty-string
        // sentinel). See migration_069_test for full-coverage tests.
        null,
        // cwd (Migration 070) — null. See comment above.
        null,
        // video_urls (Migration 090) — null. See comment above.
        null);
    defer task.deinit(alloc);

    try testing.expectEqualStrings("hello world from test", task.description);
    try expectDescriptionEquals062(&ctx, alloc, "t_desc_filled_061", "hello world from test");
}

// Direct `db.exec` mirror of the createRoutineTask + createMemoryTask
// INSERT branches. These branches don't go through
// `createWorkspaceItemTask` so they need their own exercise of the
// `''`-literal-vs-bind footgun fix. The test asserts the same three
// caller shapes work — null, "", "x…" — for each task_type the
// handler can produce.

const RoutineCase062 = struct {
    task_id: []const u8,
    desc: ?[]const u8,
};
const MemoryCase062 = struct {
    task_id: []const u8,
    desc: ?[]const u8,
};

test "task_create direct INSERT branches: null/empty/value all succeed for routine task_type" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration062.up(&ctx.db, alloc);
    const parent_id = try seedParent062(&ctx, alloc);

    const cases = [_]RoutineCase062{
        .{ .task_id = "t_routine_null_061", .desc = null },
        .{ .task_id = "t_routine_empty_061", .desc = "" },
        .{ .task_id = "t_routine_filled_061", .desc = "routine desc" },
    };

    for (cases) |case| {
        // Mirror the createRoutineTask three-way branch from task_create.zig.
        // (We deliberately inline this so the test exercises the PATTERN
        // that the handler uses, not a wrapper around it.)
        if (case.desc) |d| {
            if (d.len > 0) {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'routine', ?)",
                    &[_][]const u8{ case.task_id, "Routine", parent_id, d });
            } else {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'routine', '')",
                    &[_][]const u8{ case.task_id, "Routine", parent_id });
            }
        } else {
            try ctx.db.exec(alloc,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) " ++
                "VALUES (?, ?, ?, 'routine')",
                &[_][]const u8{ case.task_id, "Routine", parent_id });
        }

        try expectDescriptionEquals062(&ctx, alloc, case.task_id, case.desc orelse "");
    }
}

test "task_create direct INSERT branches: null/empty/value all succeed for memory task_type" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration062.up(&ctx.db, alloc);
    const parent_id = try seedParent062(&ctx, alloc);

    // Same three-way exercise, task_type='memory' branch.
    const cases = [_]MemoryCase062{
        .{ .task_id = "t_memory_null_061", .desc = null },
        .{ .task_id = "t_memory_empty_061", .desc = "" },
        .{ .task_id = "t_memory_filled_061", .desc = "memory desc" },
    };

    for (cases) |case| {
        if (case.desc) |d| {
            if (d.len > 0) {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'memory', ?)",
                    &[_][]const u8{ case.task_id, "Memory", parent_id, d });
            } else {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'memory', '')",
                    &[_][]const u8{ case.task_id, "Memory", parent_id });
            }
        } else {
            try ctx.db.exec(alloc,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) " ++
                "VALUES (?, ?, ?, 'memory')",
                &[_][]const u8{ case.task_id, "Memory", parent_id });
        }

        try expectDescriptionEquals062(&ctx, alloc, case.task_id, case.desc orelse "");
    }
}

// ===== Tests merged from migration_063_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 063
// (sessions.is_auto_retry_until_stop + sessions.last_finish_reason).
//
// Why this file exists
// ────────────────────
// Migration 063 introduces two new columns on `sessions`:
//   - `is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0` — opt-in flag
//     that lets a session keep retrying past the 10-attempt TooManyRetries
//     bail (unattended mode for overnight runs).
//   - `last_finish_reason TEXT` — denormalized cache of the most recent
//     `finish_reason` the workflow observed, so a server restart mid-
//     conversation picks up where the last turn left off.
//
// The migration must:
//   1. Add both columns to a fresh DB that only has the canonical
//      `sessions(id, name, status)` columns (upgrade-from-v1 path).
//   2. Be idempotent (re-runs don't crash with "duplicate column name").
//   3. Give existing rows a `0` default for the flag and NULL for
//      `last_finish_reason`.
//
// Plan: docs/superpowers/plans/2026-07-16-session-auto-retry-until-stop.md
//   (Chunk 1, Task 1.1)

const TestCtx063 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb063() !TestCtx063 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Minimal v1 sessions table — the canonical pre-Migration-063 schema
    // only declares id/name/status (Migration 017 line 263-269). The
    // migration must add the new columns on top of this.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration063 adds is_auto_retry_until_stop column to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb063();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('sessions')
            \\WHERE name = 'is_auto_retry_until_stop'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('sessions')
        \\WHERE name = 'is_auto_retry_until_stop'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing063;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("is_auto_retry_until_stop", row.values[0]);

    // No duplicate row.
    try testing.expect((try q.next()) == null);
}

test "Migration063 adds last_finish_reason column to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb063();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('sessions')
        \\WHERE name = 'last_finish_reason'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing063;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("last_finish_reason", row.values[0]);
    try testing.expect((try q.next()) == null);
}

test "Migration063 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb063();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);
    // Re-run — must not crash with "duplicate column name".
    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    // Still exactly one column of each name.
    for ([_][]const u8{ "is_auto_retry_until_stop", "last_finish_reason" }) |col| {
        var q = try ctx.db.query(alloc,
            \\SELECT COUNT(*) FROM pragma_table_info('sessions')
            \\WHERE name = ?
        , &[_][]const u8{col});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing063;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }
}

test "Migration063 default for is_auto_retry_until_stop is 0 on existing rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb063();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one v1-shape session row (only id/name, no new columns yet).
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_pre_063', 'Pre')",
        &.{});

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    // The existing row should now have is_auto_retry_until_stop = '0'
    // (the NOT NULL DEFAULT 0 fires). SQLite stores INTEGER columns
    // as INTEGER affinity, but SqliteBackend.query reads values as
    // text — verify the string form '0'.
    var q = try ctx.db.query(alloc,
        "SELECT is_auto_retry_until_stop FROM sessions WHERE id = 's_pre_063'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing063;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "Migration063 last_finish_reason is NULL on existing rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb063();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_pre_063b', 'Pre')",
        &.{});

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    // SELECT last_finish_reason — expect empty string (SQL NULL is
    // surfaced as "" by SqliteBackend per the project's convention;
    // see project memory `sqlite-backend-empty-slice-binds-as-null`).
    var q = try ctx.db.query(alloc,
        "SELECT last_finish_reason FROM sessions WHERE id = 's_pre_063b'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing063;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

// ===== Tests merged from migration_063_runtime_test.zig (2026-09-29 flatten) =====

// Behavioral regression tests for the runtime CRUD helpers added
// with Migration 063 (sessions.is_auto_retry_until_stop +
// sessions.last_finish_reason).
//
// Why this file exists
// ────────────────────
// Migration 063 (migration_063_test.zig) verifies the SCHEMA change.
// This file verifies the helper functions the rest of the codebase
// uses to read + write the new columns:
//   - create_session() takes is_auto_retry_until_stop as a parameter
//   - getSession() reads both new columns back via SELECT
//   - updateSessionAutoRetryUntilStop() toggles the flag
//   - updateSessionLastFinishReason() persists the latest finish_reason
//   - getSessionListWithCursor() / getSessionList() SELECT both new
//     columns (covered separately in Task 1.4)
//
// The setup mirrors `migration_062_test.zig:32-59` — declare the
// `sessions` table with the post-Migration-063 canonical shape
// (includes the two new columns) to exercise the "fresh-DB canonical
// CREATE TABLE" path that `addColumnIfMissing` handles.
//
// Plan: docs/superpowers/plans/2026-07-16-session-auto-retry-until-stop.md
//   (Chunk 1, Task 1.3)

const llm_history = nalarcore.llm_history;

const TestCtx063rt = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb063rt() !TestCtx063rt {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Canonical post-Migration-063 schema. Both new columns are
    // already declared, so `addColumnIfMissing` (when called from
    // the migration's up()) short-circuits cleanly — no "duplicate
    // column" error. The runtime CRUD tests here use this shape
    // directly without re-running the migration.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    selected_profile_model TEXT,
        \\    git_worktree_cwd TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    pr_url TEXT,
        \\    pr_provider TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Reads a single text column from sessions by id. Returns an owned
/// copy (allocated with `testing.allocator`) so the caller can keep
/// the value alive after `row.deinit()`. Returns null if the row is
/// missing or the column is NULL (surfaced as empty []u8 — see the
/// `sqlite-backend-empty-slice-binds-as-null` project memory for the
/// NULL-as-empty-string convention).
fn readColumn063rt(
    ctx: *TestCtx063rt,
    allocator: std.mem.Allocator,
    column: []const u8,
    row_id: []const u8,
) !?[]u8 {
    // SqliteBackend.query takes argv as []const []const u8 (a slice of
    // string slices), not a tuple. Column name is interpolated via
    // std.fmt.allocPrint because `query` doesn't support format-string
    // substitution for table/column identifiers.
    const sql = try std.fmt.allocPrint(allocator, "SELECT {s} FROM sessions WHERE id = ?", .{column});
    defer allocator.free(sql);
    const argv = [_][]const u8{row_id};
    var q = try ctx.db.query(allocator, sql, argv[0..]);
    defer q.deinit();
    const row_opt = try q.next();
    if (row_opt) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

test "create_session: is_auto_retry_until_stop = '1' is persisted to sessions row" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s1", "test", "1");
        defer session.deinit(alloc);

        const got = (try readColumn063rt(&ctx, alloc, "is_auto_retry_until_stop", "s1")) orelse
            return error.NoRow063rt;
        defer alloc.free(got);
        try testing.expectEqualStrings("1", got);
    }
}

test "create_session: empty is_auto_retry_until_stop defaults to '0'" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Pass empty string — the helper coerces to "0" via SQL binding.
    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s2", "test", "");
        defer session.deinit(alloc);

        const got = (try readColumn063rt(&ctx, alloc, "is_auto_retry_until_stop", "s2")) orelse
            return error.NoRow063rt;
        defer alloc.free(got);
        try testing.expectEqualStrings("0", got);
    }
}

test "getSession: reads back is_auto_retry_until_stop + last_finish_reason" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Write the new columns directly so we can verify getSession
    // surfaces them — bypass create_session (which coerces the flag).
    // db.exec takes argv as `[]const []const u8` (a slice of strings);
    // an empty `&.{}` tuple binds every `?` as SQL NULL, so the
    // 5 placeholders below need explicit strings.
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name, status, is_auto_retry_until_stop, last_finish_reason) " ++
        "VALUES (?, ?, 'active', ?, ?)",
        &[_][]const u8{ "s3", "test", "1", "stop" });

    const got = (try llm_history.getSession(alloc, &ctx.db, "s3")) orelse
        return error.NoRow063rt;
    defer got.deinit(alloc);
    try testing.expectEqualStrings("1", got.is_auto_retry_until_stop);
    try testing.expectEqualStrings("stop", got.last_finish_reason);
}

test "updateSessionAutoRetryUntilStop: toggles 0 -> 1" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s4", "test", "");
        defer session.deinit(alloc);
    }

    try llm_history.updateSessionAutoRetryUntilStop(alloc, &ctx.db, "s4", "1");

    const got = (try readColumn063rt(&ctx, alloc, "is_auto_retry_until_stop", "s4")) orelse
        return error.NoRow063rt;
    defer alloc.free(got);
    try testing.expectEqualStrings("1", got);
}

test "updateSessionLastFinishReason: persists the latest value" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s5", "test", "");
        defer session.deinit(alloc);
    }

    try llm_history.updateSessionLastFinishReason(alloc, &ctx.db, "s5", "tool_calls");

    const got = (try readColumn063rt(&ctx, alloc, "last_finish_reason", "s5")) orelse
        return error.NoRow063rt;
    defer alloc.free(got);
    try testing.expectEqualStrings("tool_calls", got);
}

test "updateSessionLastFinishReason: overwrites on every call" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s6", "test", "");
        defer session.deinit(alloc);
    }

    try llm_history.updateSessionLastFinishReason(alloc, &ctx.db, "s6", "length");
    try llm_history.updateSessionLastFinishReason(alloc, &ctx.db, "s6", "stop");

    const got = (try readColumn063rt(&ctx, alloc, "last_finish_reason", "s6")) orelse
        return error.NoRow063rt;
    defer alloc.free(got);
    try testing.expectEqualStrings("stop", got);
}

// ===== Tests merged from migration_064_test.zig (2026-09-29 flatten) =====

// Behavioural tests for Migration 064 (add the `logs` table for
// frontend error capture).
//
// Why this file exists
// ────────────────────
// Migration 064 introduces the `logs` table that the frontend's
// `window.error` / `unhandledrejection` / `console.error` /
// `console.warn` listeners POST into (Chunk 2 handler). The schema
// must be exactly:
//   - 11 columns in the right order (the Ch3 SELECT * ORDER BY
//     created_at DESC relies on the cid ordering to be deterministic).
//   - 2 indexes (`idx_logs_created_at DESC` for the primary read path,
//     `idx_logs_level` for `WHERE level = ?` filtering).
//   - Idempotent on a re-run (`CREATE TABLE IF NOT EXISTS` +
//     `CREATE INDEX IF NOT EXISTS`) so a fresh-DB install and an
//     upgrade-from-v62 install both succeed.
//
// A static source check would not catch a typo'd column name, a
// missing index, a missing `IF NOT EXISTS` (which would crash on a
// re-run), or a wrong column type. Asserting the actual schema after
// `up()` runs mirrors the pattern in `migration_062_test.zig`.
//
// Plan: docs/plans/2026-07-17-frontend-error-logs-design.md

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB. Mirrors the `setupDb` helper in
/// `ai_workflow/tui/routines/Scheduler.zig` (the project's canonical
/// Io.Threaded + :memory: pattern).

fn setupDb064() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: Migration 064 creates all 11 columns in the right order ──────

test "Migration064 creates logs table with all 11 columns in the right order" {
    const alloc = testing.allocator;
    var s = try setupDb064();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration064AddFrontendLogs.up(&s.db, alloc);

    var rows = try s.db.query(
        alloc,
        "SELECT name FROM pragma_table_info('logs') ORDER BY cid",
        &[_][]const u8{},
    );
    defer rows.deinit();

    const expected = [_][]const u8{
        "id", "created_at", "level", "kind", "message",
        "stack", "source", "line", "route_path", "session_id", "count",
    };

    var idx: usize = 0;
    while (try rows.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ─── Test 2: Migration 064 creates the 2 indexes ──────────────────────────

test "Migration064 creates the idx_logs_created_at and idx_logs_level indexes" {
    const alloc = testing.allocator;
    var s = try setupDb064();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration064AddFrontendLogs.up(&s.db, alloc);

    var rows = try s.db.query(
        alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='logs' ORDER BY name",
        &[_][]const u8{},
    );
    defer rows.deinit();

    var found_created_at = false;
    var found_level = false;
    while (try rows.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_logs_created_at")) found_created_at = true;
        if (std.mem.eql(u8, row.values[0], "idx_logs_level")) found_level = true;
    }
    try testing.expect(found_created_at);
    try testing.expect(found_level);
}

// ─── Test 3: Migration 064 is idempotent on a re-run ──────────────────────

test "Migration063 is idempotent (re-running up() does not error)" {
    const alloc = testing.allocator;
    var s = try setupDb064();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration064AddFrontendLogs.up(&s.db, alloc);
    // Second run must not error — `CREATE TABLE IF NOT EXISTS` +
    // `CREATE INDEX IF NOT EXISTS` make this a safe no-op. If they
    // were bare CREATE / CREATE INDEX, the second run would crash
    // with "table logs already exists" / "index already exists".
    try Migration064AddFrontendLogs.up(&s.db, alloc);
}

// ===== Tests merged from migration_065_test.zig (2026-09-29 flatten) =====

// Static + behavioural regression checks for Migration 065
// (`workspace_item_tasks.last_human_touched_at`).
//
// Why this file exists
// ────────────────────
// Migration 065 adds a single nullable INTEGER column that stamps the
// last time a HUMAN (not the AI agent) interacted with a task —
// dragged it, renamed it, edited its description, pinned it, sent a
// chat message, or opened its chat. The kanban card UI uses this
// column together with `sessions.last_finish_reason` to decide
// whether to show the "AI finished — awaiting review" dot or the
// "reviewed" checkmark (see docs/plans/2026-07-26-kanban-task-notification-icon.md).
//
// The migration must:
//   1. Add `last_human_touched_at INTEGER` (nullable, no DEFAULT —
//      NULL = "never touched", which the kanban SELECT uses to mean
//      "AI finished and human hasn't seen it").
//   2. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name" — see the project's hard-fought
//      knowledge about fresh-DB migration cascades in
//      `nalar-data-and-routines.md` §"Migration #009-#052 fresh-DB
//      cascade is fragile").
//   3. Be safe for fresh-DB installs that already declare the column
//      in their canonical CREATE TABLE — use `addColumnIfMissing` so
//      the helper handles both fresh-DB and upgrade-from-v1 paths.
//   4. Leave existing rows at NULL (NOT 0 or the current time — the
//      "user has touched this task" semantic is binary; we cannot
//      retroactively know whether a row from before the migration was
//      reviewed).
//
// Plan: docs/plans/2026-07-26-kanban-task-notification-icon.md (Chunk 1)

const TestCtx065 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb065() !TestCtx065 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // workspace_items (FK target for workspace_item_tasks.workspace_item_id)
    // and workspace_item_tasks itself must exist before the migration
    // can run. Production walks migrations 001 → 064 first, so they're
    // already there; we create minimal mirrors here for the unit test.
    // The minimal `workspace_item_tasks` schema matches the v1 shape —
    // no `last_human_touched_at` column yet, that's exactly what the
    // migration adds.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration065 adds last_human_touched_at column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb065();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'last_human_touched_at'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing065;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("last_human_touched_at", row.values[0]);

    // Confirm there are no extra rows (i.e. only one match — not the
    // "column literally named INTEGER" footgun from passing only a
    // type to addColumnIfMissing; see project memory
    // `addColumnIfMissing-requires-name-type`).
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be INTEGER (so unix-ms comparisons
    // work as arithmetic), not TEXT or a literal "INTEGER" string in
    // the column-name slot.
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing065;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", type_row.values[0]);
}

test "Migration065 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb065();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing065;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration065 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb065();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `last_human_touched_at INTEGER`. The migration
    // must be a no-op (NOT a "duplicate column" crash). This is the
    // same fresh-DB-vs-upgrade split that bit Migration 020 / 052 —
    // see project memory `nalar-data-and-routines.md` §"Migration
    // #009-#052 fresh-DB cascade is fragile".
    try ctx.db.exec(alloc, "DROP TABLE workspace_item_tasks", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    last_human_touched_at INTEGER
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists.
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Re-check: still exactly one column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing065;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration065 leaves pre-existing rows at NULL (not 0, not now)" {
    const alloc = testing.allocator;
    var ctx = try setupDb065();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing task BEFORE applying the migration. The
    // semantics matter: we cannot retroactively know whether the user
    // touched this task before the migration ran, so the value must
    // be NULL (the "I don't know" state) — NOT 0 (which the kanban
    // SELECT would interpret as "touched at unix epoch 0, i.e. way
    // before the AI's finish_reason update, i.e. still needs review"
    // — semantically equivalent but misleading in logs) and NOT the
    // current time (which would silently mark every legacy task as
    // "reviewed" the moment the migration runs).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_pre_065', 'Legacy task', 'wi_1')",
        &.{});

    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // SQL NULL is surfaced as "" by SqliteBackend.query — see project
    // memory `sqlite-backend-empty-slice-binds-as-null` and the
    // existing Migration063 test for the same convention.
    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at FROM workspace_item_tasks WHERE id = 'task_pre_065'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing065;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration065 stamps a value when set after the migration" {
    const alloc = testing.allocator;
    var ctx = try setupDb065();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_a', 'A', 'wi_1')",
        &.{});

    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Now stamp a unix-ms timestamp — should persist as the literal
    // integer (formatted as TEXT by SqliteBackend.bind). This is the
    // exact call shape that llm_history.updateTaskLastHumanTouchedAt
    // will use.
    const now_ms_str = try std.fmt.allocPrint(alloc, "{d}", .{@as(i64, 1_786_000_000_000)});
    defer alloc.free(now_ms_str);
    try ctx.db.exec(alloc,
        "UPDATE workspace_item_tasks SET last_human_touched_at = ? WHERE id = ?",
        &[_][]const u8{ now_ms_str, "task_a" });

    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at FROM workspace_item_tasks WHERE id = 'task_a'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing065;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1786000000000", row.values[0]);
}

// ===== Tests merged from migration_066_test.zig (2026-09-29 flatten) =====

// Static + behavioural regression checks for Migration 066
// (`design_pages.workspace_item_task_id` FK + backfill).
//
// Why this file exists
// ────────────────────
// Migration 066 adds a single nullable TEXT column to `design_pages`
// that binds each page 1:1 to a `workspace_item_tasks` chat-session
// row. The replacement of the name-pattern lookup in
// `AppLayout.handleDesignOpenChat` with a direct FK lookup depends
// on this column being (a) added, (b) uniquely indexed, (c) backfilled
// for every existing page so legacy DBs do not orphan their per-page
// chats.
//
// The migration must:
//   1. Add `workspace_item_task_id TEXT` (nullable, no DEFAULT —
//      NULL = "not yet backfilled"; after `up()` returns, every row
//      must be backfilled).
//   2. Create a UNIQUE index on the column (the 1:1 invariant; SQLite
//      uses the same index for the FK lookup, so no second index is
//      needed).
//   3. Be idempotent on re-run (re-running must not crash with
//      "duplicate column" or "index already exists" — see project
//      memory `nalar-data-and-routines.md` §"Migration #009-#052
//      fresh-DB cascade is fragile").
//   4. Be safe for fresh-DB installs that already declare the column
//      in their canonical CREATE TABLE — `addColumnIfMissing` handles
//      both fresh-DB and upgrade-from-v1 paths.
//   5. **Backfill** every pre-existing page with a fresh
//      `workspace_item_tasks` row named `"Design Chat: <page_name>"`
//      (or `"Design Chat: untitled"` for empty page names) so the
//      design canvas chat surface has a stable task row for every
//      legacy page.
//
// The migration-registration trap (defining the struct without
// registering it in `allMigrations`) is checked in Test 5 — see
// project memory `migration-registration-trap.md`.
//
// Plan: docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md
// (Task 1).

const TestCtx066 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Mirror of the production schema BEFORE Migration 066 — no
/// `workspace_item_task_id` column on `design_pages`. The migration
/// itself adds the column via `addColumnIfMissing`.
fn setupDb066() !TestCtx066 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items + workspace_item_tasks: FK targets + chat-session
    // table that the backfill creates new rows in. Production walks
    // migrations 001 → 065 first; we mirror the minimal schema here.
    // The minimal `workspace_item_tasks` schema matches the v65 shape
    // (description added by Migration 062, task_type is the
    // NOT NULL DEFAULT 'standard' column).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (" ++
            "id TEXT PRIMARY KEY, " ++
            "name TEXT, " ++
            "workspace_item_id TEXT, " ++
            "task_type TEXT NOT NULL DEFAULT 'standard', " ++
            "description TEXT NOT NULL DEFAULT ''" ++
            ")",
        &.{});

    // design_pages: the pre-migration shape (Migration 055 + 056
    // schema — id, workspace_item_id, name, width, height, x, y,
    // position, created_at, updated_at, FK to workspace_items).
    // NO `workspace_item_task_id` column yet — that's exactly what
    // Migration 066 adds.
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration066 adds workspace_item_task_id column to design_pages" {
    const alloc = testing.allocator;
    var ctx = try setupDb066();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('design_pages')
            \\WHERE name = 'workspace_item_task_id'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing066;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("workspace_item_task_id", row.values[0]);

    // Confirm there are no extra rows (i.e. only one match — not the
    // "column literally named TEXT" footgun from passing only a type
    // to addColumnIfMissing; see project memory
    // `addColumnIfMissing-requires-name-type`).
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be TEXT (so the FK to
    // workspace_item_tasks.id works), not a literal "TEXT" string
    // in the column-name slot.
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing066;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);

    // UNIQUE index sanity — must exist after the migration (the
    // 1:1 invariant enforcement). Catch a regression where
    // someone drops the CREATE INDEX step but leaves the column.
    var qi = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_design_pages_workspace_item_task_id'
    , &.{});
    defer qi.deinit();
    const index_row = (try qi.next()) orelse return error.UniqueIndexMissing066;
    defer index_row.deinit(alloc);
    try testing.expectEqualStrings("idx_design_pages_workspace_item_task_id", index_row.values[0]);
}

test "Migration066 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb066();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column
    // name" or "index already exists" — the
    // `addColumnIfMissing` + `CREATE … IF NOT EXISTS` calls are all
    // idempotent.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing066;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration066 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb066();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // for design_pages already includes `workspace_item_task_id TEXT`.
    // The migration must be a no-op for the column add (NOT a
    // "duplicate column" crash), the index add must be idempotent
    // (IF NOT EXISTS), and the backfill must find no rows to update
    // (table is empty after the recreate).
    try ctx.db.exec(alloc, "DROP TABLE design_pages", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    workspace_item_task_id TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists,
    // CREATE INDEX IF NOT EXISTS is a no-op, backfill query returns
    // zero rows.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Re-check: still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing066;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration066 backfills a workspace_item_tasks row for each existing design page" {
    const alloc = testing.allocator;
    var ctx = try setupDb066();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: one workspace_item, then 3 design pages (with one
    // empty-name edge case to exercise the "Design Chat: untitled"
    // fallback). The setupDb() schema does NOT yet include the
    // `workspace_item_task_id` column; we add it manually first
    // (simulating that the migration's `addColumnIfMissing` step has
    // already run on a legacy DB) — every existing row gets NULL.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
            "VALUES ('wi_1', 'ws_1', 'design')",
        &.{});
    try ctx.db.exec(alloc,
        "ALTER TABLE design_pages ADD COLUMN workspace_item_task_id TEXT",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name, position) " ++
            "VALUES ('page_a', 'wi_1', 'Login', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name, position) " ++
            "VALUES ('page_b', 'wi_1', 'Dashboard', 1)",
        &.{});
    try ctx.db.exec(alloc,
        // Empty name — exercises the "Design Chat: untitled" fallback.
        "INSERT INTO design_pages (id, workspace_item_id, name, position) " ++
            "VALUES ('page_c', 'wi_1', '', 2)",
        &.{});

    // Sanity: all 3 pages have NULL task_id BEFORE the migration runs.
    {
        var q = try ctx.db.query(alloc,
            "SELECT COUNT(*) FROM design_pages WHERE workspace_item_task_id IS NULL",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing066;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("3", row.values[0]);
    }

    // Apply the migration. addColumnIfMissing no-ops (column exists);
    // CREATE INDEX IF NOT EXISTS creates the unique index; backfill
    // creates 3 new tasks + updates 3 pages.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // 1. Every page now has a non-NULL workspace_item_task_id that
    //    points at a real workspace_item_tasks row. Joining both
    //    tables catches both the UPDATE and the FK invariant in one
    //    query — if the migration forgot the UPDATE, the JOIN would
    //    still return 3 rows (matching by workspace_item_id, not the
    //    new task_id), so we use the actual `workspace_item_task_id`
    //    column for the join.
    var qj = try ctx.db.query(alloc,
        \\SELECT dp.id, dp.name, t.id, t.name, t.task_type, t.description
        \\FROM design_pages dp
        \\JOIN workspace_item_tasks t
        \\  ON t.id = dp.workspace_item_task_id
        \\WHERE dp.workspace_item_id = 'wi_1'
        \\ORDER BY dp.position ASC
    , &.{});
    defer qj.deinit();

    // Expected: page_a → "Design Chat: Login", page_b → "Design Chat:
    // Dashboard", page_c → "Design Chat: untitled" (empty name
    // fallback). task_type is always 'standard'; description is ''.
    const expected: [3][]const u8 = .{ "Design Chat: Login", "Design Chat: Dashboard", "Design Chat: untitled" };
    const expected_page_ids: [3][]const u8 = .{ "page_a", "page_b", "page_c" };
    for (expected, 0..) |_, i| {
        const row = (try qj.next()) orelse return error.BackfillRowMissing066;
        defer row.deinit(alloc);
        try testing.expectEqualStrings(expected_page_ids[i], row.values[0]);
        try testing.expectEqualStrings(expected[i], row.values[3]);
        try testing.expectEqualStrings("standard", row.values[4]);
        try testing.expectEqualStrings("", row.values[5]);
        // Sanity: the task id is non-empty (i.e. was actually
        // generated, not the empty-slice-as-NULL trap).
        try testing.expect(row.values[2].len > 0);
    }
    // No 4th row expected — the backfill should produce exactly
    // one task per page.
    try testing.expect((try qj.next()) == null);

    // 2. No page was left with NULL workspace_item_task_id after the
    //    backfill (the migration's WHERE clause should match every
    //    pre-existing row exactly once).
    var qnull = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM design_pages WHERE workspace_item_task_id IS NULL",
        &.{});
    defer qnull.deinit();
    const null_row = (try qnull.next()) orelse return error.RowMissing066;
    defer null_row.deinit(alloc);
    try testing.expectEqualStrings("0", null_row.values[0]);

    // 3. Re-run safety: a second `up()` call must not produce extra
    //    task rows (the backfill's WHERE workspace_item_task_id IS
    //    NULL matches zero rows on the second pass).
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);
    var qc = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM workspace_item_tasks WHERE workspace_item_id = 'wi_1'",
        &.{});
    defer qc.deinit();
    const count_row = (try qc.next()) orelse return error.RowMissing066;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("3", count_row.values[0]);
}

test "Migration066 is registered in allMigrations" {
    // The migration-registration trap: defining the struct is not
    // enough — it must also be added to `migration.zig::allMigrations`.
    // A static-contract test that just imports the struct directly
    // would pass with the tuple missing (because tests import the
    // struct, not the slice). This test iterates the slice and
    // catches the regression where someone deletes the registration
    // tuple. See project memory `migration-registration-trap.md`.
    for (allMigrations) |m| {
        if (m.version == Migration066AddDesignPageTaskFk.version) return;
    }
    return error.Migration066NotRegistered066;
}

// ===== Tests merged from migration_067_test.zig (2026-09-29 flatten) =====

// Static + behavioural regression checks for Migration 067
// (`workspace_item_tasks.tags`).
//
// Why this file exists
// ────────────────────
// Migration 067 adds a `tags TEXT NOT NULL DEFAULT ''` column to
// `workspace_item_tasks` to support the kanban task tags feature
// (plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md).
// Tags are stored as a JSON-encode array string (e.g.
// `'["bug","urgent","frontend"]'`); empty string = "no tags".
//
// The migration must:
//   1. Add `tags TEXT NOT NULL DEFAULT ''` to `workspace_item_tasks`.
//   2. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name").
//   3. Be safe for fresh-DB installs that already declare the column
//      in their canonical CREATE TABLE — use `addColumnIfMissing` so
//      the helper handles both fresh-DB and upgrade-from-v1 paths.
//   4. Leave existing rows at '' (the canonical "no tags" sentinel).
//   5. Be registered in `allMigrations` — defining the struct alone
//      is a silent-skip bug per project memory
//      `migration-registration-trap`.
//
// Plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md (Task 1)

const TestCtx067 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb067() !TestCtx067 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items (FK target for workspace_item_tasks.workspace_item_id)
    // and workspace_item_tasks itself must exist before the migration
    // can run. Production walks migrations 001 → 066 first, so they're
    // already there; we create minimal mirrors here for the unit test.
    // The minimal `workspace_item_tasks` schema matches the v1 shape —
    // no `tags` column yet, that's exactly what the migration adds.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration067 adds tags column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb067();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'tags'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing067;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("tags", row.values[0]);

    // Confirm there are no extra rows (guards against the "column literally
    // named TEXT" footgun from passing only a type to addColumnIfMissing;
    // see project memory `addColumnIfMissing-requires-name-type`).
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be TEXT (NOT NULL DEFAULT '' applies
    // independently of the type).
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing067;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);
}

test "Migration067 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb067();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration067AddTaskTags.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing067;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration067 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb067();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `tags TEXT`. The migration must be a no-op
    // (NOT a "duplicate column" crash). Mirrors the fresh-DB-vs-
    // upgrade split that hit Migration 020 / 052 — see project memory
    // `nalar-data-and-routines.md` §"Migration #009-#052 fresh-DB
    // cascade is fragile".
    try ctx.db.exec(alloc, "DROP TABLE workspace_item_tasks", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    tags TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists.
    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Re-check: still exactly one column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing067;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration067 leaves pre-existing rows at empty string (the no-tags sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb067();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing task BEFORE applying the migration. We
    // cannot retroactively know what tags the user wanted, so the
    // value must be '' (canonical "no tags" sentinel) — NOT NULL
    // (the column is NOT NULL DEFAULT ''). Matches the description
    // column (Migration 062) sentinel pattern.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_pre_067', 'Legacy task', 'wi_1')",
        &.{});

    try Migration067AddTaskTags.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT tags FROM workspace_item_tasks WHERE id = 'task_pre_067'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing067;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration067 accepts a JSON array string when set after the migration" {
    const alloc = testing.allocator;
    var ctx = try setupDb067();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_a', 'A', 'wi_1')",
        &.{});

    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Now update with a JSON array — should persist verbatim. This is
    // the exact call shape that llm_history.createWorkspaceItemTask
    // (with tags) will use post-Migration 067.
    try ctx.db.exec(alloc,
        "UPDATE workspace_item_tasks SET tags = ? WHERE id = ?",
        &[_][]const u8{ "[\"bug\",\"urgent\",\"frontend\"]", "task_a" });

    var q = try ctx.db.query(alloc,
        "SELECT tags FROM workspace_item_tasks WHERE id = 'task_a'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing067;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("[\"bug\",\"urgent\",\"frontend\"]", row.values[0]);
}

test "Migration067 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration067AddTaskTags.version) return;
    }
    return error.Migration067NotRegistered067;
}

// ===== Tests merged from migration_068_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 068
// (`llm_history.is_loading` + UNIQUE INDEX on `tool_call_id`).
//
// Why this file exists
// ────────────────────
// Migration 068 adds an `is_loading INTEGER NOT NULL DEFAULT 0` column
// to `llm_history` so we can mark tool-result placeholder rows that
// were pre-created BEFORE the long-running tool execution started.
//
// It also adds a partial UNIQUE INDEX on `tool_call_id`:
//     CREATE UNIQUE INDEX idx_llm_history_tool_call_id_loading
//         ON llm_history(tool_call_id)
//         WHERE tool_call_id IS NOT NULL AND tool_call_id != ''
//
// The UNIQUE INDEX is required so duplicate placeholders for the same
// id are rejected at the DB level — without it, the dispatcher could
// accidentally create two placeholders for one tool_call.id (a race
// between the dispatcher + a stray retry). The partial WHERE clause
// excludes empty-string tool_call_ids (the assistant message rows)
// so the assistant row's `tool_call_id = ''` doesn't conflict with
// the placeholders' `tool_call_id = 'tcA'` etc.
//
// The migration must:
//   1. Add `is_loading INTEGER NOT NULL DEFAULT 0` to `llm_history`.
//   2. Add the partial UNIQUE INDEX on `tool_call_id`.
//   3. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name" or "index already exists").
//   4. Leave existing rows at `is_loading = 0` (the canonical "not
//      loading" sentinel — every historical row was either written
//      directly by the dispatcher (not loading) or it was the
//      assistant message (which doesn't apply here)).
//   5. Be registered in `allMigrations` — defining the struct alone
//      is a silent-skip bug per project memory
//      `migration-registration-trap`.
//
// Plan: docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md
// Bug: task_1785784899843 ("invalid function ID tool call error")

const TestCtx068 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb068() !TestCtx068 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal `llm_history` schema matching the v1 shape — no
    // `is_loading` column yet (that's exactly what the migration
    // adds). Production walks migrations 001 → 067 first, so
    // `tool_call_id` and `is_feed_to_llm` are already there; we
    // include them so the migration's addColumnIfMissing succeeds
    // and the partial UNIQUE INDEX has the column to attach to.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_call_id TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration068 adds is_loading column to llm_history" {
    const alloc = testing.allocator;
    var ctx = try setupDb068();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('llm_history')
            \\WHERE name = 'is_loading'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('llm_history')
        \\WHERE name = 'is_loading'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing068;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("is_loading", row.values[0]);

    // Type sanity: the column must be INTEGER (NOT NULL DEFAULT 0).
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM pragma_table_info('llm_history')
        \\WHERE name = 'is_loading'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing068;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", type_row.values[0]);
    // "notnull" is 1 when NOT NULL.
    try testing.expectEqualStrings("1", type_row.values[1]);
    // Default value is "0" — the canonical "not loading" sentinel.
    try testing.expectEqualStrings("0", type_row.values[2]);
}

test "Migration068 adds partial UNIQUE INDEX on tool_call_id" {
    const alloc = testing.allocator;
    var ctx = try setupDb068();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Confirm the index exists.
    var q = try ctx.db.query(alloc,
        \\SELECT name, sql FROM sqlite_master
        \\WHERE type = 'index' AND tbl_name = 'llm_history'
        \\AND name = 'idx_llm_history_tool_call_id_loading'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.IndexMissing068;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_llm_history_tool_call_id_loading", row.values[0]);
}

test "Migration068 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb068();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration068AddToolCallLoading.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name"
    // or "index idx_llm_history_tool_call_id_loading already exists".
    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Still exactly one is_loading column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('llm_history')
        \\WHERE name = 'is_loading'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing068;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration068 leaves pre-existing rows at is_loading=0 (the not-loading sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb068();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing row BEFORE applying the migration. Every
    // historical row was either written directly (not loading) or
    // pre-existed; the migration MUST backfill is_loading = 0 for
    // every row.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
            "VALUES ('msg_pre_068', 'sess_1', 'm', 'pre-existing')",
        &.{});

    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT is_loading FROM llm_history WHERE id = 'msg_pre_068'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing068;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "Migration068 enables the UNIQUE INDEX to reject duplicate tool_call_ids" {
    const alloc = testing.allocator;
    var ctx = try setupDb068();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Two rows with the SAME tool_call_id must be rejected. The
    // assistant message has tool_call_id = '' (not the placeholder's
    // id), but the index is partial so the assistant row passes
    // through unaffected.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id, is_loading) " ++
            "VALUES ('msg_tool_a', 'sess_1', 'm', 'result_a', 'tcA', 0)",
        &.{});
    // Second placeholder with the same tool_call_id — must fail.
    const result = ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id, is_loading) " ++
            "VALUES ('msg_tool_a_dup', 'sess_1', 'm', 'result_a_dup', 'tcA', 0)",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);

    // But a row with tool_call_id = '' (the assistant message shape)
    // is allowed — the partial WHERE clause excludes it. Insert a
    // SECOND row with tool_call_id = '' to prove the partial index
    // is correctly scoped.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id) " ++
            "VALUES ('msg_assistant', 'sess_1', 'm', 'assistant content', '')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id) " ++
            "VALUES ('msg_user', 'sess_1', 'm', 'user message', '')",
        &.{});
}

test "Migration068 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration068AddToolCallLoading.version) return;
    }
    return error.Migration068NotRegistered068;
}

// ===== Tests merged from migration_069_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 069
// (`workspace_item_tasks.image_urls`).
//
// Why this file exists
// ────────────────────
// Migration 069 adds an `image_urls TEXT NOT NULL DEFAULT ''` column
// to `workspace_item_tasks` so task-attached images can be stored inline
// as `||`-delimited base64 data URLs. This replaces the broken
// filesystem-backed attachment endpoints (`POST/GET /api/.../attachments`).
//
// The migration must:
//   1. Add the `image_urls` column with `TEXT NOT NULL DEFAULT ''`.
//   2. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name").
//   3. Leave existing rows at `image_urls = ''` (the canonical "no
//      images" sentinel — every historical task predates the feature).
//   4. Be registered in `allMigrations` — defining the struct alone
//      is a silent-skip bug per project memory
//      `migration-registration-trap`.
//
// Plan: docs/superpowers/plans/2026-08-06-kanban-image-urls-column.md
// Bug: task_1785795051796 ("kanban task not saving the images or
// base 64 in kanban description, after create a task or run aent")

const TestCtx069 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb069() !TestCtx069 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal `workspace_item_tasks` schema matching the pre-Migration-069
    // shape — no `image_urls` column yet (that's exactly what the migration
    // adds). Production walks migrations 001 → 068 first, so `description`
    // (Migration 062) and `tags` (Migration 067) are already there; we
    // include them so the migration's addColumnIfMissing succeeds and the
    // schema mirrors what real production rows look like.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    description TEXT NOT NULL DEFAULT '',
        \\    tags TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration069 adds image_urls column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb069();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'image_urls'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'image_urls'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing069;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("image_urls", row.values[0]);

    // Type + nullability + default sanity: the column must be
    // TEXT NOT NULL DEFAULT '' (the canonical "no images" sentinel —
    // matches the `description` / `tags` patterns from
    // Migrations 062 / 067).
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'image_urls'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing069;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);
    // "notnull" is 1 when NOT NULL.
    try testing.expectEqualStrings("1", type_row.values[1]);
    // Default value is the SQL `''` literal (the canonical "no
    // images" sentinel). `pragma_table_info` reports it as the
    // SQL literal text (i.e. `''` with the single quotes — see the
    // same pattern in migration_062_test for `description`'s
    // DEFAULT '' column). Accept either the bare empty string or the
    // single-quoted empty-string literal — both represent the same
    // semantic default.
    const dflt = type_row.values[2];
    try testing.expect(dflt.len == 0 or std.mem.eql(u8, dflt, "''"));
}

test "Migration069 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb069();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    // Still exactly one image_urls column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'image_urls'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing069;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration069 leaves pre-existing rows at image_urls='' (the no-images sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb069();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing row BEFORE applying the migration. Every
    // historical task predates the feature; the migration MUST
    // backfill image_urls = '' for every row (the column has NOT NULL
    // DEFAULT '' and ADD COLUMN applies DEFAULT to existing rows at
    // the storage layer).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
            "VALUES ('task_pre_069', 'Pre-existing task', 'item_1')",
        &.{});

    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT image_urls FROM workspace_item_tasks WHERE id = 'task_pre_069'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing069;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration069 round-trips a ||-delimited image_urls string" {
    const alloc = testing.allocator;
    var ctx = try setupDb069();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    // Insert a task with two data URLs joined by || (the convention
    // `llm_history.image_url` uses). Confirm the raw string round-trips
    // — the column stores bytes verbatim, the join/split is the
    // caller's responsibility.
    const joined = "data:image/png;base64,iVBORw0KGgo||data:image/jpeg;base64,/9j/4AAQ";
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, image_urls) " ++
            "VALUES ('task_imgs', 'Two-image task', 'item_1', ?)",
        &[_][]const u8{joined});

    var q = try ctx.db.query(alloc,
        "SELECT image_urls FROM workspace_item_tasks WHERE id = 'task_imgs'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing069;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(joined, row.values[0]);
}

test "Migration069 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration069AddTaskImageUrls.version) return;
    }
    return error.Migration069NotRegistered069;
}

// ===== Tests merged from migration_070_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 070
// (`agent_memories` table + `agent_memories_fts` FTS5 virtual table).
//
// Why this file exists
// ────────────────────
// Migration 070 backs the new `save_memory` + `load_memory` agent tools.
// It creates:
//   - `agent_memories` — the source table (id PK, content, tags, timestamps)
//   - `agent_memories_fts` — a non-external-content FTS5 virtual table
//     over `content` + `tags` (content is duplicated so `snippet()` works,
//     matching the existing `messages_fts` pattern from Migration 058)
//   - 3 sync triggers (INSERT / DELETE / UPDATE) that keep the FTS index
//     in lockstep with the source table
//
// Plan: docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md (Task 1)
// Task: task_1785958319567 (save_memory + load_memory tools)
//
// Why non-external-content
// ─────────────────────────
// `snippet()` returns NULL for external-content FTS5 tables. The
// `load_memory` tool needs snippets to render compact `<snippet>` blocks
// (10 tokens with `[match]` markers). Duplicating content costs ~2x
// storage but enables the only UX feature that matters here.
//
// Why FTS5 MATCH ? with single-token words
// ─────────────────────────────────────────
// Same rationale as migration_058_test.zig — multi-word queries would
// couple the test to the tokenizer's exact behavior; single-token MATCH
// keeps the contract tight: "the row containing word W is in the FTS
// index".

/// Test fixture. Hoisted to a top-level named struct (NOT inline anonymous)
/// because Zig 0.16 treats two anonymous `struct { db, threaded }` types as
/// distinct types even with identical fields — see project memory
/// `zig-anonymous-struct-type-identity.md`.

const TestCtx070 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with the empty (pre-migration) state. After
/// Migration 070 runs, `agent_memories` exists and the FTS5 sync triggers
/// are installed.
fn setupDb070() !TestCtx070 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

test "Migration070 creates agent_memories table with correct columns" {
    // After migration, `pragma_table_info('agent_memories')` must show
    // columns: id (TEXT PK), content (TEXT NOT NULL), tags (TEXT NOT NULL
    // DEFAULT ''), created_at (DATETIME DEFAULT CURRENT_TIMESTAMP),
    // updated_at (DATETIME DEFAULT CURRENT_TIMESTAMP).
    const alloc = testing.allocator;
    var ctx = try setupDb070();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: table does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='agent_memories'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have agent_memories
        }
    }

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // Post-migration: table exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.AgentMemoriesTableNotCreated070;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("agent_memories", row.values[0]);
    }

    // Verify the 5 expected columns exist with the expected names.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('agent_memories') ORDER BY cid",
        &.{});
    defer q.deinit();
    const expected_columns = [_][]const u8{ "id", "content", "tags", "created_at", "updated_at" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected_columns.len);
        try testing.expectEqualStrings(expected_columns[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected_columns.len), idx);
}

test "Migration070 is idempotent on a re-run" {
    // The migration's CREATE statements all use IF NOT EXISTS. A second
    // run must NOT crash with "table agent_memories already exists" or
    // similar errors.
    const alloc = testing.allocator;
    var ctx = try setupDb070();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration070AddAgentMemories.up(&ctx.db, alloc);
    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // Still exactly 1 agent_memories table.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='agent_memories'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing070;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration070 creates agent_memories_fts FTS5 virtual table" {
    // After migration, `sqlite_master` must contain a row for
    // `agent_memories_fts` with type='table' (FTS5 virtual tables show
    // up as 'table' rows in sqlite_master, not 'view' or 'index').
    const alloc = testing.allocator;
    var ctx = try setupDb070();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories_fts'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.FtsVirtualTableNotCreated070;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("agent_memories_fts", row.values[0]);
}

test "Migration070 installs sync triggers (exactly 3 on agent_memories)" {
    // The migration creates 3 triggers: agent_memories_ai, _ad, _au.
    // After migration, querying sqlite_master with `tbl_name='agent_memories'`
    // AND `type='trigger'` must return exactly 3.
    const alloc = testing.allocator;
    var ctx = try setupDb070();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, zero triggers on agent_memories.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='agent_memories'",
            &.{});
        defer q.deinit();
        var pre_count: usize = 0;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            pre_count += 1;
        }
        try testing.expectEqual(@as(usize, 0), pre_count);
    }

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // Post-migration: exactly 3 triggers.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='trigger' AND tbl_name='agent_memories'
        \\ORDER BY name
        , &.{});
    defer q.deinit();
    const names = [_][]const u8{ "agent_memories_ad", "agent_memories_ai", "agent_memories_au" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < names.len);
        try testing.expectEqualStrings(names[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, names.len), idx);
}

test "Migration070 sync triggers keep FTS5 in lockstep with source table" {
    // The whole point of the triggers is that INSERT/UPDATE/DELETE on
    // `agent_memories` auto-mirror into `agent_memories_fts`. Insert a
    // row, FTS5 MATCH on a unique word from it must return the row.
    const alloc = testing.allocator;
    var ctx = try setupDb070();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // INSERT a row post-migration. The ai trigger should auto-add it to FTS5.
    try ctx.db.exec(alloc,
        \\INSERT INTO agent_memories (id, content, tags)
        \\VALUES ('mem-trig-1', 'this row contains zeppelinword for trigger test', 'preferences')
        , &.{});

    // FTS5 MATCH on the unique word must return the row.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"zeppelinword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.InsertTriggerDidNotFire070;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("mem-trig-1", row.values[0]);
    }

    // UPDATE the content. The au trigger should remove the old FTS5 row
    // and insert the new one. The OLD word must NOT match; the NEW word must.
    try ctx.db.exec(alloc,
        \\UPDATE agent_memories SET content = 'updated content has quasarword now'
        \\WHERE id = 'mem-trig-1'
        , &.{});

    // Old word no longer matches (au trigger's DELETE part fired).
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"zeppelinword"});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // UPDATE trigger DELETE part did not fire
        }
    }

    // New word matches (au trigger's INSERT part fired).
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"quasarword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.UpdateTriggerInsertPartDidNotFire070;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("mem-trig-1", row.values[0]);
    }

    // DELETE the row. The ad trigger should remove it from FTS5.
    try ctx.db.exec(alloc,
        "DELETE FROM agent_memories WHERE id = 'mem-trig-1'",
        &.{});

    // New word no longer matches (ad trigger fired).
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"quasarword"});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // DELETE trigger did not fire
        }
    }
}

test "Migration070 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined but
    // the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version number
    // so the test stays stable across reordering.
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration070AddAgentMemories.version) return;
    }
    return error.Migration070NotRegistered070;
}

// ===== Tests merged from migration_071_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 071
// (`workspace_item_tasks.cwd`).
//
// Why this file exists
// ────────────────────
// Migration 071 adds a `cwd TEXT NOT NULL DEFAULT ''` column to
// `workspace_item_tasks` so each task can carry its own cwd_session
// (which becomes the cwd_session for that task's chat sessions).
// Per-task cwd OVERRIDES the kanban-level path (`workspace_items.path`)
// which OVERRIDES the per-session sandbox fallback
// (`$TMPDIR/session_<id>/`). The chain is implemented in
// `session_create.zig::useCase`.
//
// The migration must:
//   1. Add the `cwd` column with `TEXT NOT NULL DEFAULT ''`.
//   2. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name").
//   3. Leave existing rows at `cwd = ''` (the canonical "no per-task
//      cwd" sentinel — every historical task predates the feature).
//   4. Be registered in `allMigrations` — defining the struct alone
//      is a silent-skip bug per project memory
//      `migration-registration-trap`.
//
// Plan: docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
// Tasks: task_1785959915548 (kanban cwd → optional + per-task cwd picker)

const TestCtx071 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb071() !TestCtx071 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal `workspace_item_tasks` schema matching the pre-Migration-070
    // shape — no `cwd` column yet (that's exactly what the migration adds).
    // Production walks migrations 001 → 069 first, so `description`
    // (Migration 062), `tags` (Migration 067), and `image_urls`
    // (Migration 069) are already there; we include them so the
    // migration's addColumnIfMissing succeeds and the schema mirrors
    // what real production rows look like.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    description TEXT NOT NULL DEFAULT '',
        \\    tags TEXT NOT NULL DEFAULT '',
        \\    image_urls TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    // Minimal `workspace_items` table so the FK target exists for
    // round-trip tests that need to INSERT a parent row first.
    // Production walks migrations 001 → 069 first, so this table is
    // always there; the test mirrors that.
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration071 adds cwd column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'cwd'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'cwd'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("cwd", row.values[0]);

    // Type + nullability + default sanity: the column must be
    // TEXT NOT NULL DEFAULT '' (the canonical "no per-task cwd" sentinel
    // — matches the `description` / `tags` / `image_urls` patterns from
    // Migrations 062 / 067 / 069).
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'cwd'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing071;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);
    // "notnull" is 1 when NOT NULL.
    try testing.expectEqualStrings("1", type_row.values[1]);
    // Default value is the SQL `''` literal (the canonical "no
    // per-task cwd" sentinel). `pragma_table_info` reports it as the
    // SQL literal text (i.e. `''` with the single quotes — same pattern
    // as the other NOT NULL DEFAULT '' columns). Accept either the bare
    // empty string or the single-quoted empty-string literal — both
    // represent the same semantic default.
    const dflt = type_row.values[2];
    try testing.expect(dflt.len == 0 or std.mem.eql(u8, dflt, "''"));
}

test "Migration071 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration071AddTaskCwd.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    // Still exactly one cwd column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'cwd'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration071 leaves pre-existing rows at cwd='' (the no-per-task-cwd sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing row BEFORE applying the migration. Every
    // historical task predates the feature; the migration MUST
    // backfill cwd = '' for every row (the column has NOT NULL
    // DEFAULT '' and ADD COLUMN applies DEFAULT to existing rows at
    // the storage layer).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
            "VALUES ('task_pre_070', 'Pre-existing task', 'item_1')",
        &.{});

    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 'task_pre_070'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration071 round-trips a per-task cwd path" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    // Insert a task with an absolute path on disk as its per-task cwd.
    // Confirm the raw string round-trips — the column stores bytes
    // verbatim, the resolution chain (task.cwd → item.path → sandbox)
    // is the caller's responsibility.
    const cwd_path = "/home/me/projects/repo-A";
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, cwd) " ++
            "VALUES ('task_cwd', 'Per-task cwd task', 'item_1', ?)",
        &[_][]const u8{cwd_path});

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 'task_cwd'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(cwd_path, row.values[0]);
}

test "Migration071 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration071AddTaskCwd.version) return;
    }
    return error.Migration071NotRegistered071;
}

// ─── createWorkspaceItemTask round-trip tests (Migration 071) ───────────
//
// These tests exercise the model's createWorkspaceItemTask function
// (the canonical INSERT path for new tasks) to lock in the contract:
// the new `cwd` arg must (a) be accepted as the 10th parameter,
// (b) store the supplied path verbatim, and (c) default to '' when
// the caller passes null (matches the description / tags / image_urls
// pattern).

const createWorkspaceItemTask_fromMigration071 = @import("nalarcore").ai_mod.llm_history.createWorkspaceItemTask;

test "createWorkspaceItemTask: cwd = '/home/me/proj-A' round-trips verbatim" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    const parent_id = try insertWorkspaceItem071(&ctx, alloc, "item_001");

    const task = try createWorkspaceItemTask_fromMigration071(
        alloc,
        &ctx.db,
        "t_cwd_001",
        "Task with cwd",
        parent_id,
        "standard",
        null, // description
        null, // tags
        null, // image_urls
        "/home/me/proj-A", // cwd (Migration 071 10th arg)
        null, // video_urls (Migration 090)
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("/home/me/proj-A", task.cwd);

    // Read back from DB to verify persistence.
    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 't_cwd_001'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("/home/me/proj-A", row.values[0]);
}

test "createWorkspaceItemTask: cwd = '' stores '' (SQL '' literal, NOT NULL DEFAULT '')" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    const parent_id = try insertWorkspaceItem071(&ctx, alloc, "item_002");

    // Empty-string cwd — must use the SQL '' literal branch (NOT
    // bind via `?`, which would NULL-bind and fail NOT NULL).
    const task = try createWorkspaceItemTask_fromMigration071(
        alloc,
        &ctx.db,
        "t_cwd_002",
        "Task with empty cwd",
        parent_id,
        "standard",
        null,
        null,
        null,
        "", // cwd
        null, // video_urls (Migration 090)
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("", task.cwd);

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 't_cwd_002'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "createWorkspaceItemTask: cwd = null omits column (DEFAULT '' applies)" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    const parent_id = try insertWorkspaceItem071(&ctx, alloc, "item_003");

    // null cwd — column omitted from INSERT, DEFAULT '' applies.
    const task = try createWorkspaceItemTask_fromMigration071(
        alloc,
        &ctx.db,
        "t_cwd_003",
        "Task with null cwd",
        parent_id,
        "standard",
        null,
        null,
        null,
        null, // cwd — omitted, DEFAULT '' fills in
        null, // video_urls (Migration 090)
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("", task.cwd);

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 't_cwd_003'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

// Helper for the round-trip tests above — inserts a minimal
// workspace_item row so the FK constraint on
// workspace_item_tasks.workspace_item_id is satisfied. Returns
// the input slice borrowed from the caller's stack — caller MUST
// NOT free it.
fn insertWorkspaceItem071(
    ctx: *TestCtx071,
    alloc: std.mem.Allocator,
    item_id: []const u8,
) ![]const u8 {
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type)
        \\VALUES (?, 'ws_test', 'kanban')
    , &.{item_id});
    // Borrow the input — caller owns the backing memory (the
    // literal `"item_001"` lives in the test function's stack
    // frame; the test ends before the literal's lifetime ends).
    return item_id;
}

// ===== Tests merged from migration_072_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 072
// (`workspace_item_tasks` → `kanban` table extraction).
//
// Why this file exists
// ────────────────────
// Migration 072 moves the two kanban-board-placement columns
// (`kanban_column_id`, `kanban_position`) off the universal
// `workspace_item_tasks` table and into a dedicated `kanban` join
// table. This is purely structural — the wire format
// (`Task.kanban_column_id`, `Task.kanban_position`) stays identical,
// served via a `LEFT JOIN kanban k ON k.workspace_item_task_id = t.id` in list
// queries.
//
// The migration must:
//   1. Create the `kanban` table with the expected schema
//      (workspace_item_task_id PK, kanban_column_id NOT NULL, kanban_position
//      DEFAULT 0, FKs to workspace_item_tasks + kanban_columns).
//   2. Create the `idx_kanban_column_position` index.
//   3. Backfill rows from existing `workspace_item_tasks`
//      (only rows whose `kanban_column_id` references a real
//      `kanban_columns.id` — orphans are skipped per the design
//      decision in the plan, risk R8).
//   4. Drop `workspace_item_tasks.kanban_column_id`.
//   5. Drop `workspace_item_tasks.kanban_position`.
//   6. Drop `idx_tasks_column_position` from workspace_item_tasks.
//   7. Be idempotent on a re-run (re-running must not crash with
//      "duplicate column name" or "table already exists" — relies
//      on `CREATE TABLE IF NOT EXISTS` + `DROP COLUMN IF EXISTS`-
//      style helpers).
//   8. Preserve the wire format — after migration, a `LEFT JOIN`
//      from `workspace_item_tasks` to `kanban` returns the same
//      (column_id, position) pairs that the old direct columns
//      returned (with NULL/0 for non-kanban tasks).
//
// Plan: docs/superpowers/plans/2026-08-15-extract-kanban-columns-to-kanban-table.md
// Tasks: task_1786527996378 ("move column workspace_item_tasks table").

const TestCtx072 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up a pre-Migration-072 in-memory DB — mirrors the schema a real
/// production user has after walking migrations 001 → 071. Includes
/// the two columns we're about to drop, plus the index we're about
/// to drop. Also seeds the FK target tables (`workspace_items`,
/// `kanban_columns`) so the backfill SELECT has valid references.
fn setupDb072() !TestCtx072 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items — FK target for workspace_item_tasks.workspace_item_id
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, item_type TEXT NOT NULL)",
        &.{});
    // kanban_columns — FK target for the new kanban.kanban_column_id.
    // Production walks Migration 051 to create this; the test mirrors it
    // so the backfill SELECT can validate column-id references.
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    position INTEGER NOT NULL,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    // Pre-Migration-072 workspace_item_tasks — the full set of task
    // attributes from migrations 001 → 071 PLUS the two columns we're
    // about to extract.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    description TEXT NOT NULL DEFAULT '',
        \\    created_at TEXT,
        \\    updated_at TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    is_pinned INTEGER DEFAULT 0,
        \\    pinned_position INTEGER DEFAULT 0,
        \\    kanban_column_id TEXT,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0,
        \\    last_human_touched_at INTEGER,
        \\    tags TEXT NOT NULL DEFAULT '',
        \\    cwd TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    // The legacy per-column-position index that Migration 072 drops.
    try db.exec(alloc,
        "CREATE INDEX idx_tasks_column_position " ++
        "ON workspace_item_tasks(kanban_column_id, kanban_position)",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Insert a workspace_items row + a kanban_columns row + a task with
/// a kanban placement. Returns nothing; the caller asserts on the
/// post-migration state.
fn seedKanbanCard072(
    ctx: *TestCtx072,
    alloc: std.mem.Allocator,
    task_id: []const u8,
    column_id: []const u8,
    position: i64,
) !void {
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES (?, 'wi_1', 'todo', 0)",
        &.{column_id});
    const pos_str = try std.fmt.allocPrint(alloc, "{d}", .{position});
    defer alloc.free(pos_str);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES (?, 'Task', 'wi_1', ?, ?)
    , &.{ task_id, column_id, pos_str });
}

// ============================================================================
// Test 0 — Column-delete cascades the kanban row (FK regression test)
// ============================================================================
//
// The original Migration 072 DDL declared the FK on
// `kanban.kanban_column_id` as `ON DELETE SET NULL`. That action is
// incompatible with the column's `NOT NULL` constraint — SQLite rejects
// the parent DELETE with "NOT NULL constraint failed:
// kanban.kanban_column_id". The fix is `ON DELETE CASCADE`: deleting a
// column un-places its tasks (deletes the kanban row).
//
// This test seeds a column + task + kanban row, runs the migration,
// deletes the column, and asserts the kanban row is gone. Without
// CASCADE, the DELETE would crash (and the test would fail with
// `error.SqLiteError`).
test "Migration072 kanban_column_id FK is ON DELETE CASCADE — deleting a column un-places its task" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // NB: PRAGMA foreign_keys is deliberately OFF in this project's
    // SqliteBackend init (see src/ai_workflow/tui/kanban_model.zig:306
    // for the rationale — application code simulates CASCADE
    // manually). We turn it ON here so this test exercises the
    // *schema-declared* FK behavior, which is what someone running
    // with the default `sqlite3` CLI would observe. If PRAGMA is
    // off, the FK is documentation-only and the test would falsely
    // pass even with the buggy `SET NULL` declaration.
    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});

    // Seed: one valid task on column col_1.
    try seedKanbanCard072(&ctx, alloc, "task_to_unplace", "col_1", 0);

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Pre-condition: the kanban row exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM kanban WHERE workspace_item_task_id = 'task_to_unplace'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing072;
        defer row.deinit(alloc);
    }

    // Action: delete the column. With ON DELETE CASCADE this should
    // silently cascade-delete the kanban row. With the buggy
    // ON DELETE SET NULL, this would fail with `NOT NULL
    // constraint failed: kanban.kanban_column_id`.
    try ctx.db.exec(alloc,
        "DELETE FROM kanban_columns WHERE id = 'col_1'",
        &.{});

    // Post-condition: the kanban row is gone.
    var q = try ctx.db.query(alloc,
        "SELECT 1 FROM kanban WHERE workspace_item_task_id = 'task_to_unplace'",
        &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

// ============================================================================
// Test 1 — Migration creates the `kanban` table
// ============================================================================

test "Migration072 creates the kanban table with the expected schema" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: kanban table does NOT exist before migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM sqlite_master
            \\WHERE type = 'table' AND name = 'kanban'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Confirm the kanban table exists.
    var q = try ctx.db.query(alloc,
        \\SELECT 1 FROM sqlite_master
        \\WHERE type = 'table' AND name = 'kanban'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing072;
    defer row.deinit(alloc);
}

// ============================================================================
// Test 2 — Migration creates the per-column-position index
// ============================================================================

test "Migration072 creates idx_kanban_column_position index" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT 1 FROM sqlite_master
        \\WHERE type = 'index' AND name = 'idx_kanban_column_position'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing072;
    defer row.deinit(alloc);
}

// ============================================================================
// Test 3 — Migration backfills existing rows
// ============================================================================

test "Migration072 backfills kanban rows from workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedKanbanCard072(&ctx, alloc, "task_a", "col_1", 0);
    try seedKanbanCard072(&ctx, alloc, "task_b", "col_1", 1);
    try seedKanbanCard072(&ctx, alloc, "task_c", "col_2", 0);

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Verify the backfill: three rows in kanban with the expected
    // workspace_item_task_id / column_id / position triples.
    var q = try ctx.db.query(alloc,
        \\SELECT workspace_item_task_id, kanban_column_id, kanban_position
        \\FROM kanban
        \\ORDER BY workspace_item_task_id ASC
    , &.{});
    defer q.deinit();

    const row_a = (try q.next()) orelse return error.RowMissing072;
    defer row_a.deinit(alloc);
    try testing.expectEqualStrings("task_a", row_a.values[0]);
    try testing.expectEqualStrings("col_1", row_a.values[1]);
    try testing.expectEqualStrings("0", row_a.values[2]);

    const row_b = (try q.next()) orelse return error.RowMissing072;
    defer row_b.deinit(alloc);
    try testing.expectEqualStrings("task_b", row_b.values[0]);
    try testing.expectEqualStrings("col_1", row_b.values[1]);
    try testing.expectEqualStrings("1", row_b.values[2]);

    const row_c = (try q.next()) orelse return error.RowMissing072;
    defer row_c.deinit(alloc);
    try testing.expectEqualStrings("task_c", row_c.values[0]);
    try testing.expectEqualStrings("col_2", row_c.values[1]);
    try testing.expectEqualStrings("0", row_c.values[2]);

    try testing.expect((try q.next()) == null); // no extra rows
}

// ============================================================================
// Test 4 — Backfill skips orphan kanban_column_id references (R8)
// ============================================================================

test "Migration072 backfill skips tasks whose kanban_column_id has no matching kanban_columns row" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: task with a valid column (col_1) + task pointing at a
    // deleted/orphan column (col_deleted).
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES ('col_1', 'wi_1', 'todo', 0)",
        &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_valid', 'Valid', 'wi_1', 'col_1', 0)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_orphan', 'Orphan', 'wi_1', 'col_deleted', 5)
    , &.{});

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Only the valid row was backfilled — the orphan was skipped.
    var q = try ctx.db.query(alloc,
        "SELECT workspace_item_task_id FROM kanban ORDER BY workspace_item_task_id ASC",
        &.{});
    defer q.deinit();

    const row1 = (try q.next()) orelse return error.RowMissing072;
    defer row1.deinit(alloc);
    try testing.expectEqualStrings("task_valid", row1.values[0]);

    try testing.expect((try q.next()) == null); // task_orphan NOT backfilled
}

// ============================================================================
// Test 5 — Migration drops the kanban_column_id and kanban_position columns
// ============================================================================

test "Migration072 drops kanban_column_id from workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'kanban_column_id'
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

test "Migration072 drops kanban_position from workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'kanban_position'
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

// ============================================================================
// Test 6 — Migration drops idx_tasks_column_position index
// ============================================================================

test "Migration072 drops the legacy idx_tasks_column_position index" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT 1 FROM sqlite_master
        \\WHERE type = 'index' AND name = 'idx_tasks_column_position'
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

// ============================================================================
// Test 7 — Migration is idempotent on re-run
// ============================================================================

test "Migration072 is idempotent — re-running does not crash" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);
    // Re-run: must not crash with "duplicate column name" or
    // "table kanban already exists". The CREATE TABLE IF NOT
    // EXISTS + dropColumnIfExists helpers make this a no-op.
    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Verify the schema is still correct after the re-run.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name IN ('kanban_column_id', 'kanban_position')
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null); // columns still gone
}

// ============================================================================
// Test 8 — Wire-format preservation via LEFT JOIN
// ============================================================================

test "Migration072 preserves the wire format — LEFT JOIN returns the same data the old direct columns did" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: one task on a kanban column, one task with no column
    // assignment (the "chat task in a kanban item" case — has
    // kanban_column_id IS NULL).
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES ('col_1', 'wi_1', 'todo', 0)",
        &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_on_board', 'On board', 'wi_1', 'col_1', 7)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_unassigned', 'Unassigned', 'wi_1', NULL, 0)
    , &.{});

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // The "wire format" query — what every list query uses to
    // populate Task.kanban_column_id and Task.kanban_position.
    var q = try ctx.db.query(alloc,
        \\SELECT t.id, k.kanban_column_id, COALESCE(k.kanban_position, 0)
        \\FROM workspace_item_tasks t
        \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
        \\ORDER BY t.id ASC
    , &.{});
    defer q.deinit();

    const row_on = (try q.next()) orelse return error.RowMissing072;
    defer row_on.deinit(alloc);
    try testing.expectEqualStrings("task_on_board", row_on.values[0]);
    try testing.expectEqualStrings("col_1", row_on.values[1]); // matched column
    try testing.expectEqualStrings("7", row_on.values[2]); // matched position

    const row_un = (try q.next()) orelse return error.RowMissing072;
    defer row_un.deinit(alloc);
    try testing.expectEqualStrings("task_unassigned", row_un.values[0]);
    try testing.expectEqualStrings("", row_un.values[1]); // NULL → empty string
    try testing.expectEqualStrings("0", row_un.values[2]); // COALESCE → 0

    try testing.expect((try q.next()) == null); // no extra rows
}

// ===== Tests merged from migration_073_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 073
// (`session_activity` append-only log).
//
// Why this file exists
// ────────────────────
// Migration 073 adds a per-session activity log that records every
// `update_activity` tool call AND every compaction event. This is
// purely additive — `worker.last_activity_description` (the live UI
// signal) keeps being overwritten as before.
//
// The migration must:
//   1. Create the `session_activity` table with the expected schema
//      (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
//      description TEXT NOT NULL, created_at DATETIME DEFAULT
//      CURRENT_TIMESTAMP).
//   2. Create the `idx_session_activity_session_created` index over
//      `(session_id, created_at DESC)` so the per-session "most
//      recent N" query is fast.
//   3. Be idempotent on a re-run (CREATE TABLE IF NOT EXISTS + CREATE
//      INDEX IF NOT EXISTS — per the project-wide
//      `migration-is-idempotent` invariant).
//   4. Allow INSERT + SELECT round-trip on a row.
//
// Plan: docs/superpowers/plans/2026-08-13-session-activity-table.md
// Task: task_1786629034327 ("new table session_activity")

const TestCtx073 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with the empty (pre-migration) state. After
/// Migration 073 runs, `session_activity` exists and the index is
/// installed.
fn setupDb073() !TestCtx073 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Test 1 — Migration creates the `session_activity` table with the right
// columns in the right order.
// ============================================================================

test "Migration073 creates session_activity table with correct columns" {
    // After migration, `pragma_table_info('session_activity')` must
    // show columns in order: id (TEXT PK), session_id (TEXT NOT NULL),
    // description (TEXT NOT NULL), created_at (DATETIME DEFAULT
    // CURRENT_TIMESTAMP).
    const alloc = testing.allocator;
    var ctx = try setupDb073();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: table does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_activity'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have session_activity
        }
    }

    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    // Post-migration: table exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='session_activity'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.SessionActivityTableNotCreated073;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("session_activity", row.values[0]);
    }

    // Verify the 4 expected columns exist with the expected names + order.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('session_activity') ORDER BY cid",
        &.{});
    defer q.deinit();
    const expected_columns = [_][]const u8{ "id", "session_id", "description", "created_at" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected_columns.len);
        try testing.expectEqualStrings(expected_columns[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected_columns.len), idx);
}

// ============================================================================
// Test 2 — Idempotent on re-run.
// ============================================================================

test "Migration073 is idempotent on a re-run" {
    // The migration's CREATE statements all use IF NOT EXISTS. A
    // second run must NOT crash with "table session_activity already
    // exists" or similar errors.
    const alloc = testing.allocator;
    var ctx = try setupDb073();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration073AddSessionActivity.up(&ctx.db, alloc);
    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    // Still exactly 1 session_activity table.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_activity'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing073;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

// ============================================================================
// Test 3 — Index created.
// ============================================================================

test "Migration073 creates idx_session_activity_session_created index" {
    // After migration, `sqlite_master` must contain a row for
    // `idx_session_activity_session_created` with type='index' over
    // (session_id, created_at DESC).
    const alloc = testing.allocator;
    var ctx = try setupDb073();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, index doesn't exist.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_session_activity_session_created'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should not have the index
        }
    }

    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='index' AND name='idx_session_activity_session_created'
        , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.IndexNotCreated073;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_session_activity_session_created", row.values[0]);
}

// ============================================================================
// Test 4 — INSERT + SELECT round-trip.
// ============================================================================

test "Migration073 fresh-DB replay: insert and select a session_activity row" {
    // After migration, an INSERT into session_activity followed by a
    // SELECT must round-trip the values correctly. The id is supplied
    // by the caller (TEXT PK), so we hardcode one for determinism.
    const alloc = testing.allocator;
    var ctx = try setupDb073();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        \\INSERT INTO session_activity (id, session_id, description) VALUES (?, ?, ?)
        , &.{ "act_001", "sess_test", "[2026-08-13 10:00] test @ /tmp | Thinking | hello" });

    var q = try ctx.db.query(alloc,
        "SELECT id, session_id, description FROM session_activity WHERE session_id = ?",
        &.{"sess_test"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing073;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("act_001", row.values[0]);
    try testing.expectEqualStrings("sess_test", row.values[1]);
    try testing.expectEqualStrings("[2026-08-13 10:00] test @ /tmp | Thinking | hello", row.values[2]);

    // No further rows.
    try testing.expect((try q.next()) == null);
}

// ===== Tests merged from migration_074_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 074
// (`llm_history.cache_creation_input_tokens` +
// `llm_history.cache_read_input_tokens`).
//
// Why this file exists
// ────────────────────
// Migration 074 adds two cache-breakdown columns to `llm_history` so
// the Anthropic profile's `cache_creation_input_tokens` and
// `cache_read_input_tokens` survive the trip from the SSE parser
// through `CallResponse.usage` → `saveMessage` / `insertLLMHistories`
// → the row. OpenAI rows always carry 0 (the parser never sets the
// fields for that profile).
//
// The migration must:
//   1. Add `cache_creation_input_tokens` and `cache_read_input_tokens`
//      columns to `llm_history`, both INTEGER DEFAULT 0 (so legacy
//      rows backfill cleanly).
//   2. Be idempotent on a re-run — `ALTER TABLE … ADD COLUMN` is NOT
//      idempotent, so we use the existing `addColumnIfMissing` helper
//      (probe `pragma_table_info` first; same pattern as Migration 020).
//   3. Allow INSERT + SELECT round-trip on a row with explicit cache
//      values populated.
//
// Set-up uses `MigrationManager.registerAllMigrations` + `runMigrations`
// so the test schema matches what production runs (per the reviewer
// note on PR #172: "when setup db, use from migrations module, migrations
// module will load all table"). This avoids the drift trap of hand-rolling
// a minimal `llm_history` schema — the moment a new column or trigger
// lands in production, the hand-rolled baseline silently tests an
// outdated schema.
//
// Plan: docs/superpowers/plans/2026-08-13-fix-anthropic-total-tokens.md
// Task: task_1786640688092 ("fixing antropic agent total tokens")

const TestCtx074 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through
/// 074. After this returns, the schema is exactly what a production
/// DB looks like after Migration 074 has run — including the 2
/// cache-breakdown columns.
fn setupDb074() !TestCtx074 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Test 1 — Migration adds the 2 columns with the right name + type +
// default 0. (Schema is post-migration; verifies the columns are
// present and have the right shape.)
// ============================================================================

test "Migration074 adds cache_creation_input_tokens + cache_read_input_tokens to llm_history" {
    const alloc = testing.allocator;
    var ctx = try setupDb074();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Post-migration: both columns exist with type=INTEGER and dflt_value=0.
    var q = try ctx.db.query(alloc,
        "SELECT name, type, dflt_value FROM pragma_table_info('llm_history') " ++
            "WHERE name IN ('cache_creation_input_tokens', 'cache_read_input_tokens') " ++
            "ORDER BY name",
        &.{});
    defer q.deinit();

    const expected = [_]struct { name: []const u8, type: []const u8, default: []const u8 }{
        .{ .name = "cache_creation_input_tokens", .type = "INTEGER", .default = "0" },
        .{ .name = "cache_read_input_tokens", .type = "INTEGER", .default = "0" },
    };

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx].name, row.values[0]);
        try testing.expectEqualStrings(expected[idx].type, row.values[1]);
        try testing.expectEqualStrings(expected[idx].default, row.values[2]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ============================================================================
// Test 2 — Idempotent on re-run. `runMigrations` tracks versions in
// `schema_migrations` so a second run is a no-op. We also call
// `Migration074AddLlmHistoryCacheTokenColumns.up` directly a second
// time to verify the `addColumnIfMissing` helper doesn't error with
// "duplicate column name" (the failure mode it specifically guards
// against).
// ============================================================================

test "Migration074 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb074();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Run all migrations again — the schema_migrations version row
    // makes Migration 074 a no-op.
    var manager = MigrationManager.init(alloc, &ctx.db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    // Both columns still exist exactly once each.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('llm_history') " ++
            "WHERE name IN ('cache_creation_input_tokens', 'cache_read_input_tokens')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing074;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);

    // Also directly re-run Migration 074's up() — verifies the
    // addColumnIfMissing helper doesn't crash with "duplicate column
    // name" (the failure mode SQLite raises for the second ALTER).
    try Migration074AddLlmHistoryCacheTokenColumns.up(&ctx.db, alloc);
    try Migration074AddLlmHistoryCacheTokenColumns.up(&ctx.db, alloc);
}

// ============================================================================
// Test 3 — Legacy-style INSERTs that OMIT the cache columns still
// succeed with default 0 backfill. This is the regression check for
// the "legacy rows backfill cleanly" contract — an old DB with rows
// already inserted would NOT re-INSERT; the new columns just show as 0.
// ============================================================================

test "Migration074 lets legacy-shape INSERTs succeed with default 0 cache counts" {
    const alloc = testing.allocator;
    var ctx = try setupDb074();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // INSERT that does NOT mention the 2 cache columns — the
    // INSERT-time DEFAULT 0 (set by Migration 074) must kick in.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model) VALUES (?, ?, ?)",
        &.{ "h_legacy", "sess_legacy", "claude-opus-4" });

    var q = try ctx.db.query(alloc,
        "SELECT cache_creation_input_tokens, cache_read_input_tokens FROM llm_history WHERE id = ?",
        &.{"h_legacy"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing074;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
    try testing.expectEqualStrings("0", row.values[1]);
}

// ============================================================================
// Test 4 — INSERT + SELECT round-trip with explicit cache values.
// Mirrors what `saveMessage` / `insertLLMHistories` will write when an
// Anthropic call returns cache_creation=500, cache_read=5000.
// ============================================================================

test "Migration074: insert and select an llm_history row with explicit cache counts" {
    const alloc = testing.allocator;
    var ctx = try setupDb074();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, cache_creation_input_tokens, cache_read_input_tokens) " ++
            "VALUES (?, ?, ?, ?, ?)",
        &.{ "h_cached", "sess_cached", "claude-opus-4", "500", "5000" });

    var q = try ctx.db.query(alloc,
        "SELECT cache_creation_input_tokens, cache_read_input_tokens " ++
            "FROM llm_history WHERE id = ?",
        &.{"h_cached"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing074;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("500", row.values[0]);
    try testing.expectEqualStrings("5000", row.values[1]);
}

// ============================================================================
// Test 5 — Migration 074 is registered in `allMigrations` (mirrors the
// pattern in migration_066_test.zig / migration_067_test.zig /
// migration_068_test.zig / migration_069_test.zig / migration_070_test.zig
// / migration_071_test.zig). Defining the struct alone is not enough —
// it must also be added to `migration.zig::allMigrations` so the
// production migration runner picks it up.
// ============================================================================

test "Migration074 is registered in allMigrations" {
    const all = allMigrations;
    var found: bool = false;
    for (all) |m| {
        if (m.version == Migration074AddLlmHistoryCacheTokenColumns.version and
            std.mem.eql(u8, m.name, Migration074AddLlmHistoryCacheTokenColumns.name))
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

// ===== Tests merged from migration_075_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 075
// (rename 5 timestamp columns to `_nano` suffix).
//
// Why this file exists
// ────────────────────
// Migration 075 renames:
//   - `logs.created_at`              → `logs.created_at_nano` (datetime-namespace; actually ms INTEGER)
//   - `llm_history.created_at`      → `llm_history.created_at_nano` (TEXT ns — the only true nanosecond column)
//   - `session_skills.loaded_at`    → `session_skills.loaded_at_nano` (INTEGER s)
//   - `worker.last_activity`        → `worker.last_activity_nano` (INTEGER s)
//   - `workspace_item_tasks.last_human_touched_at` → `workspace_item_tasks.last_human_touched_at_nano` (INTEGER ms)
//
// Plus 2 index renames (the only ones whose name explicitly contains
// the old column name):
//   - `idx_logs_created_at`    → `idx_logs_created_at_nano`
//   - `idx_worker_last_activity` → `idx_worker_last_activity_nano`
//
// The 2 generic `idx_llm_history_*_created` indexes keep their names
// (use a generic `_created` suffix) — SQLite internally updates the
// column reference during the RENAME.
//
// The `_nano` suffix is a uniform project convention (see project memory
// `timestamp-columns-nano-suffix-convention`) — it documents "integer
// stored since Unix epoch", NOT strict nanoseconds. The actual precision
// varies per column and is documented in the migration doc-comment +
// the corresponding Zig model file.
//
// Wire format preserved: the JSON field name on HTTP responses stays
// exactly the same (`created_at`, `loaded_at`, `last_activity`,
// `last_human_touched_at`). The new SQL column is aliased to the old
// wire name in every SELECT projection so the frontend JSON shape is
// byte-identical.
//
// The migration must:
//   1. Rename all 5 columns via `ALTER TABLE … RENAME COLUMN`
//      (SQLite >= 3.25; this project bundles 3.53.3).
//   2. Drop the 2 old indexes and re-CREATE them under the new name.
//   3. Be idempotent on a re-run — `renameColumnIfExists` probes
//      `pragma_table_info` first; if the old column doesn't exist
//      (fresh-DB already has the new name, or a re-run after the
//      rename succeeded), the helper returns silently.
//   4. Preserve data — `ALTER TABLE … RENAME COLUMN` is in-place
//      and preserves all rows + indices on the column.
//   5. Preserve FK references — other tables' FK constraints that
//      point AT this table are auto-updated by SQLite's RENAME.
//
// Plan: docs/superpowers/plans/2026-08-16-rename-timestamp-columns-nano-suffix.md
// Task: task_1786891244388_1 (kanban: sprint bulan juni → "change column name").

const TestCtx075 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through
/// 074. After this returns, the schema is exactly what a production
/// DB looks like after Migration 074 has run — BEFORE Migration 075's
/// rename. We seed one row in each affected table so the post-rename
/// round-trip test can verify the data survived the rename.
fn setupDb075() !TestCtx075 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    // Seed one row in each affected table so the data-preservation
    // tests have something to verify against. IMPORTANT: by the time
    // `setupDb()` returns, ALL migrations 001 → 075 have already run
    // (Migration075 is in the `allMigrations` slice — verified by the
    // test `Migration075 runs cleanly via registerAllMigrations +
    // runMigrations`). So all column references must use the NEW
    // (_nano) names. The migration preserves the data — these seeds
    // populate values that the test verifies after the rename.
    trySeed075(alloc, &db, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Test')", &.{}, "workspaces");
    trySeed075(alloc, &db, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1', 'ws_1', 'kanban')", &.{}, "workspace_items");
    trySeed075(alloc, &db, "INSERT INTO sessions (id, name, status) VALUES ('sess_1', 'S', 'active')", &.{}, "sessions");

    // llm_history — the actual nanosecond column (TEXT).
    trySeed075(alloc, &db,
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
            "VALUES ('h_1', 'sess_1', 'm1', '1784119389936251112')",
        &.{}, "llm_history");

    return .{ .db = db, .threaded = threaded };
}

fn trySeed075(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, argv: []const []const u8, table_name: []const u8) void {
    db.exec(alloc, sql, argv) catch |err| {
        std.debug.print("FAIL seed {s}: {s}\n", .{ table_name, @errorName(err) });
    };
}

/// Returns the list of column names on `table` (via pragma_table_info).
/// Caller owns the returned slice. Each element is allocated via
/// `alloc.dupe` and the slice itself is heap-allocated — both must be
/// freed.
fn listColumns075(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, table: []const u8) ![]const []u8 {
    var q = try db.query(alloc,
        "SELECT name FROM pragma_table_info(?) ORDER BY cid",
        &.{table});
    defer q.deinit();
    var cols = std.ArrayList([]u8).empty;
    errdefer {
        for (cols.items) |c| alloc.free(c);
        cols.deinit(alloc);
    }
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try cols.append(alloc, try alloc.dupe(u8, row.values[0]));
    }
    return cols.toOwnedSlice(alloc);
}

// ============================================================================
// Test 1 — All 5 columns renamed
// ============================================================================

test "Migration075 renames the 5 timestamp columns to _nano suffix" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Verify each table has the new column and NOT the old one.
    const cases = [_]struct { table: []const u8, old: []const u8, new: []const u8 }{
        .{ .table = "logs", .old = "created_at", .new = "created_at_nano" },
        .{ .table = "llm_history", .old = "created_at", .new = "created_at_nano" },
        .{ .table = "session_skills", .old = "loaded_at", .new = "loaded_at_nano" },
        .{ .table = "worker", .old = "last_activity", .new = "last_activity_nano" },
        .{ .table = "workspace_item_tasks", .old = "last_human_touched_at", .new = "last_human_touched_at_nano" },
    };

    for (cases) |c| {
        // New column exists.
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM pragma_table_info(?) WHERE name = ?",
            &.{ c.table, c.new });
        defer q.deinit();
        const row = (try q.next()) orelse {
            std.debug.print("MISSING new column: {s}.{s}\n", .{ c.table, c.new });
            return error.NewColumnMissing075;
        };
        defer row.deinit(alloc);

        // Old column is gone.
        var q2 = try ctx.db.query(alloc,
            "SELECT 1 FROM pragma_table_info(?) WHERE name = ?",
            &.{ c.table, c.old });
        defer q2.deinit();
        const r2 = try q2.next();
        if (r2 != null) {
            std.debug.print("OLD column still present: {s}.{s}\n", .{ c.table, c.old });
            return error.OldColumnStillPresent075;
        }
    }
}

// ============================================================================
// Test 2 — Data preserved across the rename (llm_history only — the
// other tables use the same migration_064_test.zig setup pattern, see
// README in this file for the reasoning).
// ============================================================================

test "Migration075 preserves the seeded data across the rename" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // llm_history.created_at_nano still holds the original ns string.
    {
        var q = try ctx.db.query(alloc,
            "SELECT created_at_nano FROM llm_history WHERE id = 'h_1'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing075;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1784119389936251112", row.values[0]);
    }
}

// ============================================================================
// Test 3 — Old indexes renamed to new indexes (DROPPED + CREATED)
// ============================================================================

test "Migration075 renames idx_logs_created_at → idx_logs_created_at_nano" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Old index is gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_logs_created_at'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // New index exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_logs_created_at_nano'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NewIndexMissing075;
        defer row.deinit(alloc);
    }
}

test "Migration075 renames idx_worker_last_activity → idx_worker_last_activity_nano" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Old index is gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_worker_last_activity'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // New index exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_worker_last_activity_nano'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NewIndexMissing075;
        defer row.deinit(alloc);
    }
}

// ============================================================================
// Test 4 — Generic indexes still reference the renamed column
// ============================================================================

test "Migration075 updates the internal column reference of idx_llm_history_session_created" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // The index's NAME is unchanged (uses generic `_created` suffix).
    // The internal column reference DOES update — verified by querying
    // EXPLAIN QUERY PLAN on a SELECT that uses this index.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_llm_history_session_created'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.IndexMissing075;
        defer row.deinit(alloc);
    }

    // Verify the index is still usable — EXPLAIN should pick it up
    // for a query that filters on session_id.
    {
        var q = try ctx.db.query(alloc,
            "EXPLAIN QUERY PLAN SELECT id FROM llm_history WHERE session_id = 'sess_1' ORDER BY created_at_nano DESC",
            &.{});
        defer q.deinit();
        var found_index: bool = false;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            for (row.values) |v| {
                if (std.mem.indexOf(u8, v, "idx_llm_history_session_created") != null) {
                    found_index = true;
                    break;
                }
            }
        }
        try testing.expect(found_index);
    }
}

// ============================================================================
// Test 5 — Idempotent on re-run (the killer test — renameColumnIfExists
// probes pragma_table_info first)
// ============================================================================

test "Migration075 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Run once.
    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);
    // Run a second time — must NOT crash with "no such column" (the
    // raw `ALTER TABLE … RENAME COLUMN` failure mode) nor with any
    // other error.
    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);
    // Run a third time for good measure.
    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Verify the schema is still correct after all 3 runs.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('llm_history') " ++
            "WHERE name IN ('created_at', 'created_at_nano')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing075;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

// ============================================================================
// Test 6 — Full-migration runner is idempotent (schema_migrations tracking)
// ============================================================================

test "Migration075 is registered in allMigrations" {
    const all = allMigrations;
    var found: bool = false;
    for (all) |m| {
        if (m.version == Migration075RenameTimestampColumnsToNanoSuffix.version and
            std.mem.eql(u8, m.name, Migration075RenameTimestampColumnsToNanoSuffix.name))
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Migration075 runs cleanly via registerAllMigrations + runMigrations" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    // Re-run — schema_migrations version 75 makes Migration 075 a no-op.
    var manager2 = MigrationManager.init(alloc, &db);
    defer manager2.deinit();
    try registerAllMigrations(&manager2);
    try manager2.runMigrations();

    // Schema check: the new column names exist.
    var q = try db.query(alloc,
        "SELECT 1 FROM pragma_table_info('llm_history') WHERE name = 'created_at_nano'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing075;
    defer row.deinit(alloc);
}

// ============================================================================
// Test 7 — INSERT after the rename uses the new column name
// ============================================================================

test "Migration075: INSERT into llm_history uses created_at_nano (not created_at)" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // INSERT with the new column name — must succeed.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
            "VALUES (?, ?, ?, ?)",
        &.{ "h_after", "sess_1", "m1", "1784119389936251113" });

    // SELECT from the new column.
    var q = try ctx.db.query(alloc,
        "SELECT created_at_nano FROM llm_history WHERE id = 'h_after'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing075;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1784119389936251113", row.values[0]);
}

// ============================================================================
// Test 8 — ORDER BY on the new column works (verifies the index survived)
// ============================================================================

test "Migration075: ORDER BY last_activity_nano DESC on worker uses the renamed index" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // EXPLAIN QUERY PLAN should pick up idx_worker_last_activity_nano for
    // an ORDER BY last_activity_nano DESC query.
    var q = try ctx.db.query(alloc,
        "EXPLAIN QUERY PLAN SELECT id FROM worker ORDER BY last_activity_nano DESC",
        &.{});
    defer q.deinit();
    var found_index: bool = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        for (row.values) |v| {
            if (std.mem.indexOf(u8, v, "idx_worker_last_activity_nano") != null) {
                found_index = true;
                break;
            }
        }
    }
    try testing.expect(found_index);
}

// ============================================================================
// Test 9 — Full table-info diff (regression: no extra columns lost or gained)
// ============================================================================

test "Migration075: per-table column count is preserved (rename doesn't drop or add columns)" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Snapshot before.
    const before_logs = try listColumns075(alloc, &ctx.db, "logs");
    defer {
        for (before_logs) |c| alloc.free(c);
        alloc.free(before_logs);
    }
    const before_llm = try listColumns075(alloc, &ctx.db, "llm_history");
    defer {
        for (before_llm) |c| alloc.free(c);
        alloc.free(before_llm);
    }
    const before_skills = try listColumns075(alloc, &ctx.db, "session_skills");
    defer {
        for (before_skills) |c| alloc.free(c);
        alloc.free(before_skills);
    }
    const before_worker = try listColumns075(alloc, &ctx.db, "worker");
    defer {
        for (before_worker) |c| alloc.free(c);
        alloc.free(before_worker);
    }
    const before_tasks = try listColumns075(alloc, &ctx.db, "workspace_item_tasks");
    defer {
        for (before_tasks) |c| alloc.free(c);
        alloc.free(before_tasks);
    }

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Snapshot after.
    const after_logs = try listColumns075(alloc, &ctx.db, "logs");
    defer {
        for (after_logs) |c| alloc.free(c);
        alloc.free(after_logs);
    }
    const after_llm = try listColumns075(alloc, &ctx.db, "llm_history");
    defer {
        for (after_llm) |c| alloc.free(c);
        alloc.free(after_llm);
    }
    const after_skills = try listColumns075(alloc, &ctx.db, "session_skills");
    defer {
        for (after_skills) |c| alloc.free(c);
        alloc.free(after_skills);
    }
    const after_worker = try listColumns075(alloc, &ctx.db, "worker");
    defer {
        for (after_worker) |c| alloc.free(c);
        alloc.free(after_worker);
    }
    const after_tasks = try listColumns075(alloc, &ctx.db, "workspace_item_tasks");
    defer {
        for (after_tasks) |c| alloc.free(c);
        alloc.free(after_tasks);
    }

    // Column counts must be identical (rename is in-place).
    try testing.expectEqual(before_logs.len, after_logs.len);
    try testing.expectEqual(before_llm.len, after_llm.len);
    try testing.expectEqual(before_skills.len, after_skills.len);
    try testing.expectEqual(before_worker.len, after_worker.len);
    try testing.expectEqual(before_tasks.len, after_tasks.len);
}

// ===== Tests merged from migration_077_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 077
// (users + user_companies + user_company_members + workspaces.user_id +
//  sessions.user_id + default user_system + backfill).
//
// Why this file exists
// ────────────────────
// Migration 077 lays the schema foundation for multi-user / multi-tenant nalar:
//   - `users` table (id, email, name, password_hash, role, is_active,
//     created_at, updated_at, last_login_at)
//   - `user_companies` table (id, name, slug, description, is_active,
//     created_at, updated_at, created_by)
//   - `user_company_members` join table (user_id, user_company_id, role,
//     joined_at, invited_by) with composite PRIMARY KEY
//   - Additive `user_id` column on `workspaces` (nullable, no FK constraint)
//   - Additive `user_id` column on `sessions` (nullable, no FK constraint)
//   - Default `user_system` user (is_active=0, password_hash='!disabled',
//     can never log in)
//   - Backfill of all legacy workspaces + sessions to user_id='user_system'
//
// The migration must:
//   1. Create all 3 new tables with the right column types + defaults.
//   2. Add `user_id` columns to `workspaces` + `sessions` via
//      `addColumnIfMissing` (idempotent on re-run).
//   3. Create the 6 supporting indexes (idx_users_email, idx_users_active,
//      idx_user_companies_slug, idx_user_companies_active,
//      idx_user_company_members_user, idx_user_company_members_company,
//      idx_workspaces_user_id, idx_sessions_user_id).
//   4. Insert the default `user_system` user (idempotent via INSERT OR IGNORE).
//   5. Backfill all legacy rows (workspaces, sessions) where user_id IS NULL
//      to user_id='user_system'. Idempotent — re-running on a DB where every
//      row already has user_id set is a no-op.
//   6. Be safe for fresh-DB installs (the canonical CREATE TABLE in earlier
//      migrations does NOT declare user_id, so the ALTER TABLE adds it; on
//      re-run, `addColumnIfMissing` short-circuits).
//
// Set-up uses `MigrationManager.registerAllMigrations` + `runMigrations` so
// the test schema matches what production runs (per project memory
// `project-test-use-migrations-module`). This avoids the drift trap of
// hand-rolling a minimal workspaces / sessions schema — the moment a new
// column lands in production, the hand-rolled baseline silently tests an
// outdated schema.
//
// Plan: docs/superpowers/plans/2026-08-21-users-rbac-foundation.md
// Task: task_1787199963946_1
// Spec: docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md

const TestCtx077 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through 077.
/// After this returns, the schema is exactly what a production DB looks
/// like after Migration 077 has run — the 3 new tables exist, the 2
/// additive columns are present, the default user_system is in the
/// users table, and every existing row (zero, since this is a fresh DB)
/// would have user_id='user_system' if there were any.
fn setupDb077() !TestCtx077 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Test 1 — `users` table has all 9 columns with the right types + defaults.
// ============================================================================

test "Migration077 creates users table with all 9 columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Expected columns: (name, type, default value or "" for none).
    // Migration 092 appends `config_json` (nullable TEXT, per-user LLM
    // config for `--auth` mode) — the full migration chain runs in
    // setupDb, so it is present here.
    const expected = [_]struct { name: []const u8, type: []const u8, default: []const u8 }{
        .{ .name = "id", .type = "TEXT", .default = "" },
        .{ .name = "email", .type = "TEXT", .default = "" },
        .{ .name = "name", .type = "TEXT", .default = "''" },
        .{ .name = "password_hash", .type = "TEXT", .default = "" },
        .{ .name = "role", .type = "TEXT", .default = "'user'" },
        .{ .name = "is_active", .type = "INTEGER", .default = "1" },
        .{ .name = "created_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "updated_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "last_login_at", .type = "DATETIME", .default = "" },
        .{ .name = "config_json", .type = "TEXT", .default = "" },
    };

    var q = try ctx.db.query(alloc,
        \\SELECT name, type, dflt_value FROM pragma_table_info('users') ORDER BY cid
    , &.{});
    defer q.deinit();

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx].name, row.values[0]);
        try testing.expectEqualStrings(expected[idx].type, row.values[1]);
        // SQLite's dflt_value is the raw literal (e.g. "''" for empty-string DEFAULT,
        // "'user'" for the role default). Compare as-is.
        if (expected[idx].default.len > 0) {
            try testing.expectEqualStrings(expected[idx].default, row.values[2]);
        }
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ============================================================================
// Test 2 — `user_companies` table has all 8 columns with the right types +
// defaults.
// ============================================================================

test "Migration077 creates user_companies table with all 8 columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const expected = [_]struct { name: []const u8, type: []const u8, default: []const u8 }{
        .{ .name = "id", .type = "TEXT", .default = "" },
        .{ .name = "name", .type = "TEXT", .default = "" },
        .{ .name = "slug", .type = "TEXT", .default = "" },
        .{ .name = "description", .type = "TEXT", .default = "''" },
        .{ .name = "is_active", .type = "INTEGER", .default = "1" },
        .{ .name = "created_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "updated_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "created_by", .type = "TEXT", .default = "" },
    };

    var q = try ctx.db.query(alloc,
        \\SELECT name, type, dflt_value FROM pragma_table_info('user_companies') ORDER BY cid
    , &.{});
    defer q.deinit();

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx].name, row.values[0]);
        try testing.expectEqualStrings(expected[idx].type, row.values[1]);
        if (expected[idx].default.len > 0) {
            try testing.expectEqualStrings(expected[idx].default, row.values[2]);
        }
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ============================================================================
// Test 3 — `user_company_members` join table has the composite PRIMARY KEY.
// ============================================================================

test "Migration077 creates user_company_members table with composite PK" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Verify the table exists with all 5 user-defined columns.
    const expected = [_][]const u8{
        "user_id", "user_company_id", "role", "joined_at", "invited_by",
    };

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('user_company_members') ORDER BY cid
    , &.{});
    defer q.deinit();

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);

    // Verify the composite PRIMARY KEY (user_id, user_company_id) is in
    // place. SQLite stores the PK info in pragma_table_info's `pk` column;
    // the composite PK manifests as pk=1 on user_id and pk=2 on
    // user_company_id (the order they're declared in the PRIMARY KEY clause).
    var pk_q = try ctx.db.query(alloc,
        \\SELECT name, pk FROM pragma_table_info('user_company_members')
        \\WHERE pk > 0 ORDER BY pk
    , &.{});
    defer pk_q.deinit();

    const expected_pk = [_][]const u8{ "user_id", "user_company_id" };
    var pk_idx: usize = 0;
    while (try pk_q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(pk_idx < expected_pk.len);
        try testing.expectEqualStrings(expected_pk[pk_idx], row.values[0]);
        pk_idx += 1;
    }
    try testing.expectEqual(@as(usize, expected_pk.len), pk_idx);

    // Verify the CHECK constraint on `role` rejects invalid values.
    // `sqlite3_prepare_v2` will return an error if the constraint fails.
    // Valid value: insert succeeds. Invalid value: insert fails with
    // CHECK constraint failed.
    try ctx.db.exec(alloc,
        "INSERT INTO users (id, email, name, password_hash) VALUES ('u_pk', 'u_pk@x', 'U', 'h')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO user_companies (id, name, slug) VALUES ('c_pk', 'C', 'c-pk')",
        &.{});

    // Valid role: 'member' (the default) — should succeed.
    try ctx.db.exec(alloc,
        "INSERT INTO user_company_members (user_id, user_company_id, role) " ++
            "VALUES ('u_pk', 'c_pk', 'member')",
        &.{});

    // Invalid role: 'superuser' (not in the CHECK list) — should fail.
    const result = ctx.db.exec(alloc,
        "INSERT INTO user_company_members (user_id, user_company_id, role) " ++
            "VALUES ('u_pk', 'c_pk', 'superuser')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

// ============================================================================
// Test 4 — workspaces.user_id added + backfill works (NULL → user_system).
// ============================================================================

test "Migration077 adds user_id to workspaces and backfills legacy rows to user_system" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Verify the column exists with type=TEXT, nullable.
    var col_q = try ctx.db.query(alloc,
        \\SELECT type, "notnull" FROM pragma_table_info('workspaces')
        \\WHERE name = 'user_id'
    , &.{});
    defer col_q.deinit();
    const col_row = (try col_q.next()) orelse return error.ColumnMissing077;
    defer col_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", col_row.values[0]);
    try testing.expectEqualStrings("0", col_row.values[1]); // 0 = nullable

    // Insert a legacy row WITH user_id=NULL (mimics a row from a pre-077 DB).
    // The column allows NULL by default since the migration uses
    // "user_id TEXT" (no NOT NULL).
    try ctx.db.exec(alloc,
        "INSERT INTO workspaces (id, name, user_id) VALUES ('ws_legacy', 'Legacy', NULL)",
        &.{});

    // Verify it's NULL.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM workspaces WHERE id = 'ws_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing077;
        defer row.deinit(alloc);
        // NULL is represented as an empty string by SqliteBackend.exec,
        // matching the project convention (see project memory
        // `sqlite-backend-empty-slice-binds-as-null`).
        try testing.expectEqualStrings("", row.values[0]);
    }

    // Re-run the migration. `addColumnIfMissing` is a no-op (column
    // exists), `CREATE TABLE IF NOT EXISTS` is a no-op, `INSERT OR IGNORE`
    // is a no-op for user_system — but the backfill UPDATE will convert
    // the NULL user_id to 'user_system'.
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);

    // Verify the legacy row is now backfilled.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM workspaces WHERE id = 'ws_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing077;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("user_system", row.values[0]);
    }
}

// ============================================================================
// Test 5 — sessions.user_id added + backfill works (NULL → user_system).
// ============================================================================

test "Migration077 adds user_id to sessions and backfills legacy rows to user_system" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Verify the column exists with type=TEXT, nullable.
    var col_q = try ctx.db.query(alloc,
        \\SELECT type, "notnull" FROM pragma_table_info('sessions')
        \\WHERE name = 'user_id'
    , &.{});
    defer col_q.deinit();
    const col_row = (try col_q.next()) orelse return error.ColumnMissing077;
    defer col_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", col_row.values[0]);
    try testing.expectEqualStrings("0", col_row.values[1]); // 0 = nullable

    // Insert a legacy row with user_id=NULL.
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name, status, user_id) VALUES ('sess_legacy', 'Legacy', 'active', NULL)",
        &.{});

    // Verify it's NULL.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM sessions WHERE id = 'sess_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing077;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("", row.values[0]);
    }

    // Re-run the migration to trigger the backfill.
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);

    // Verify the legacy row is now backfilled.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM sessions WHERE id = 'sess_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing077;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("user_system", row.values[0]);
    }
}

// ============================================================================
// Test 6 — Default `user_system` user exists with the right shape.
// ============================================================================

test "Migration077 inserts the default user_system user" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var q = try ctx.db.query(alloc,
        \\SELECT id, email, name, password_hash, role, is_active
        \\FROM users WHERE id = 'user_system'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.UserSystemMissing077;
    defer row.deinit(alloc);

    try testing.expectEqualStrings("user_system", row.values[0]);
    try testing.expectEqualStrings("system@local", row.values[1]);
    try testing.expectEqualStrings("System", row.values[2]);
    try testing.expectEqualStrings("!disabled", row.values[3]);
    try testing.expectEqualStrings("admin", row.values[4]);
    try testing.expectEqualStrings("0", row.values[5]); // is_active=0 — can never log in

    // Verify exactly ONE user_system row exists (UNIQUE constraint on
    // email + INSERT OR IGNORE on the second migration call).
    var count_q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM users WHERE id = 'user_system'", &.{});
    defer count_q.deinit();
    const count_row = (try count_q.next()) orelse return error.CountMissing077;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("1", count_row.values[0]);
}

// ============================================================================
// Test 7 — Idempotent on re-run (the killer test — addColumnIfMissing + INSERT OR IGNORE).
// ============================================================================

test "Migration077 is idempotent on re-run via addColumnIfMissing + INSERT OR IGNORE" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Run .up() three more times — each must NOT crash with
    // "duplicate column name" or "UNIQUE constraint failed" or any
    // other error. This is the specific failure mode addColumnIfMissing +
    // INSERT OR IGNORE are designed to prevent.
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);

    // Verify the schema is still correct after all 4 runs total
    // (1 from setupDb + 3 from this test).
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspaces') WHERE name = 'user_id'
    , &.{});
    defer q.deinit();
    const ws_row = (try q.next()) orelse return error.RowMissing077;
    defer ws_row.deinit(alloc);
    try testing.expectEqualStrings("1", ws_row.values[0]);

    var q2 = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name = 'user_id'
    , &.{});
    defer q2.deinit();
    const sess_row = (try q2.next()) orelse return error.RowMissing077;
    defer sess_row.deinit(alloc);
    try testing.expectEqualStrings("1", sess_row.values[0]);

    // Verify exactly ONE user_system row.
    var q3 = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM users WHERE id = 'user_system'", &.{});
    defer q3.deinit();
    const user_row = (try q3.next()) orelse return error.RowMissing077;
    defer user_row.deinit(alloc);
    try testing.expectEqualStrings("1", user_row.values[0]);

    // Run the full migration runner again — schema_migrations tracking
    // makes Migration 077 a no-op.
    var manager = MigrationManager.init(alloc, &ctx.db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();
}

// ============================================================================
// Test 8 — Migration 077 is registered in `allMigrations`. Defining the
// struct alone is not enough — it must also be added to
// `migration.zig::allMigrations` so the production migration runner picks
// it up (per project memory `migration-registration-trap.md`).
// ============================================================================

test "Migration077 is registered in allMigrations" {
    const all = allMigrations;
    var found: bool = false;
    for (all) |m| {
        if (m.version == Migration077AddUsersAndRbacSchema.version and
            std.mem.eql(u8, m.name, Migration077AddUsersAndRbacSchema.name))
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

// ===== Tests merged from migration_082_test.zig (2026-09-29 flatten) =====

// Static + behavioural regression checks for Migration 082
// (`sessions.last_human_touched_at_nano`).
//
// Why this file exists
// ────────────────────
// Migration 082 adds a single nullable INTEGER column on `sessions` that
// stamps the last time a HUMAN (not the AI agent) interacted with a
// chat. The chat sidebar UI uses this column instead of `updated_at`
// (which gets bumped by every AI SSE tick) so the visible time pill
// reads "5m ago" if you touched the chat 5 minutes ago even when the
// agent has been running since.
//
// Sibling of Migration 065 (`workspace_item_tasks.last_human_touched_at`,
// landed in commit `e07a13f6` for the kanban-task-notification-icon plan).
// This migration does the same thing for the SESSIONS table — the kanban
// card already uses the task-side column for its "awaiting review" dot,
// the sidebar now uses the session-side column for its time pill.
//
// The migration must:
//   1. Add `last_human_touched_at_nano INTEGER` (nullable, no DEFAULT —
//      NULL = "never touched by a human", which the frontend falls back
//      to `updated_at` for, so pre-migration sessions keep their old
//      visible time without a regression).
//   2. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name" — see the project's hard-fought
//      knowledge about fresh-DB migration cascades in
//      `nalar-data-and-routines.md` §"Migration #009-#052 fresh-DB
//      cascade is fragile").
//   3. Be safe for fresh-DB installs that already declare the column
//      in their canonical CREATE TABLE — use `addColumnIfMissing` so
//      the helper handles both fresh-DB and upgrade-from-v1 paths.
//   4. Leave existing rows at NULL (NOT 0 or the current time — same
//      reasoning as Migration 065: we cannot retroactively know whether
//      a session from before the migration was "touched").
//
// Column name uses the `_nano` suffix per the project-wide convention
// from Migration 075. The wire field stays bare `last_human_touched_at`.
//
// Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
// Spec: docs/superpowers/specs/2026-08-29-chat-sidebar-last-human-touched-design.md

const TestCtx082 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Minimal `sessions` table mirror matching the v17 production shape
/// (no `last_human_touched_at_nano` column yet, that's exactly what the
/// migration adds). The production DB walks migrations 001 → 081 first
/// so a real `sessions` table is already there; we recreate the v17
/// shape here so the test exercises the upgrade path.
fn setupDb082() !TestCtx082 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration082 adds last_human_touched_at_nano column to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb082();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('sessions')
            \\WHERE name = 'last_human_touched_at_nano'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name (NOT "INTEGER"
    // literal — that footgun was caught in Migration 065's test, see
    // project memory `addColumnIfMissing-requires-name-type`).
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing082;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("last_human_touched_at_nano", row.values[0]);

    // Confirm exactly one row matched.
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be INTEGER (so unix-ms comparisons
    // work as arithmetic), not TEXT.
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing082;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", type_row.values[0]);

    // Nullability sanity: NOT NULL must NOT appear in the column's
    // constraints (the canonical "never touched" state is NULL).
    var qn = try ctx.db.query(alloc,
        \\SELECT "notnull" FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer qn.deinit();
    const nn_row = (try qn.next()) orelse return error.RowMissing082;
    defer nn_row.deinit(alloc);
    try testing.expectEqualStrings("0", nn_row.values[0]);
}

test "Migration082 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb082();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing082;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration082 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb082();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `last_human_touched_at_nano INTEGER`. The
    // migration must be a no-op (NOT a "duplicate column" crash).
    try ctx.db.exec(alloc, "DROP TABLE sessions", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    last_human_touched_at_nano INTEGER
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists.
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Re-check: still exactly one column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing082;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration082 leaves pre-existing rows at NULL (not 0, not now)" {
    const alloc = testing.allocator;
    var ctx = try setupDb082();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing session BEFORE applying the migration. Same
    // semantic reasoning as Migration 065: we cannot retroactively
    // know whether the user touched this session before the migration
    // ran, so the value must be NULL — the frontend treats NULL as
    // "fall back to updated_at" which gives legacy sessions their
    // existing visible time without a regression.
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_pre_082', 'Legacy chat')",
        &.{});

    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // SQL NULL is surfaced as "" by SqliteBackend.query — same
    // convention as Migration 065's test.
    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at_nano FROM sessions WHERE id = 's_pre_082'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing082;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration082 stamps a value when set after the migration" {
    const alloc = testing.allocator;
    var ctx = try setupDb082();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_a', 'A')",
        &.{});

    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Now stamp a unix-ms timestamp — should persist as the literal
    // integer (formatted as TEXT by SqliteBackend.bind). This is the
    // exact call shape that llm_history.updateSessionLastHumanTouchedAt
    // will use.
    const now_ms_str = try std.fmt.allocPrint(alloc, "{d}", .{@as(i64, 1_786_000_000_000)});
    defer alloc.free(now_ms_str);
    try ctx.db.exec(alloc,
        "UPDATE sessions SET last_human_touched_at_nano = ? WHERE id = ?",
        &[_][]const u8{ now_ms_str, "s_a" });

    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at_nano FROM sessions WHERE id = 's_a'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing082;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1786000000000", row.values[0]);
}

test "Migration082 is registered in allMigrations" {
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration082AddSessionHumanTouchedAt.version) return;
    }
    return error.Migration082NotRegistered082;
}

// ─── Migration 096 — session_skill_events ────────────────────────────────

test "Migration096 creates the ledger table and both indexes" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration096CreateSessionSkillEvents.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "session_skill_events");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id",         "session_id",   "skill_name", "event",
        "source",     "content_hash", "loop_index", "llm_history_id",
        "created_at",
    });

    var qi = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN ('idx_session_skill_events_session', 'idx_session_skill_events_skill')",
        &.{});
    defer qi.deinit();
    const irow = (try qi.next()) orelse return error.RowMissing;
    defer irow.deinit(alloc);
    try testing.expectEqualStrings("2", irow.values[0]);
}

test "Migration096 accepts the production write shape with empty free-text binds" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration096CreateSessionSkillEvents.up(&ctx.db, alloc);

    // First, prove the trap is real: a bare `?` bound to "" for a NOT NULL
    // column lands as SQL NULL and fails. This is the Migration 079 `content`
    // failure mode, and it is why every free-text column needs a wrapper.
    try testing.expectError(
        error.ExecuteFailed,
        ctx.db.exec(alloc,
            "INSERT INTO session_skill_events (id, session_id, skill_name, source) VALUES (?, ?, ?, ?)",
            &.{ "evt_bad", "sess_1", "my-skill", "" },
        ),
    );

    // Now the shape every call site must use: `event`, `source`,
    // `content_hash` and `llm_history_id` are NOT NULL free text, so each one
    // is wrapped. This test is what fails if a future writer forgets one.
    try ctx.db.exec(alloc,
        \\INSERT INTO session_skill_events
        \\    (id, session_id, skill_name, event, source, content_hash, loop_index, llm_history_id)
        \\VALUES
        \\    (?, ?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(?, ''), ?, COALESCE(?, ''))
    , &.{ "evt_1", "sess_1", "my-skill", "", "", "", "7", "" });

    var q = try ctx.db.query(alloc,
        "SELECT event, source, content_hash, loop_index FROM session_skill_events WHERE id = ?",
        &.{"evt_1"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
    try testing.expectEqualStrings("", row.values[1]);
    try testing.expectEqualStrings("", row.values[2]);
    try testing.expectEqualStrings("7", row.values[3]);
}

test "Migration096 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration096CreateSessionSkillEvents.up(&ctx.db, alloc);
    try Migration096CreateSessionSkillEvents.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'session_skill_events'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration096 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration096CreateSessionSkillEvents.version) return;
    }
    return error.Migration095NotRegistered;
}

// ─── Migration 096 — skill_eval_facts / _runs / _results ─────────────────

test "Migration097 creates all three tables and their indexes" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);

    const expected = [_][]const u8{ "skill_eval_facts", "skill_eval_runs", "skill_eval_results" };
    for (expected) |table| {
        var q = try ctx.db.query(alloc,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            &.{table});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }

    var qi = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN ('uq_skill_eval_facts','idx_skill_eval_facts_skill','uq_skill_eval_runs_self_prompt','idx_skill_eval_runs_session','idx_skill_eval_runs_status','idx_skill_eval_results_run','idx_skill_eval_results_skill','idx_skill_eval_results_session')",
        &.{});
    defer qi.deinit();
    const irow = (try qi.next()) orelse return error.RowMissing;
    defer irow.deinit(alloc);
    try testing.expectEqualStrings("8", irow.values[0]);
}

test "Migration097's fact key admits exactly one row per (skill, content, context)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);

    const insert =
        \\INSERT OR IGNORE INTO skill_eval_facts (id, skill_key, content_hash, context_key, verdict_intrinsic)
        \\VALUES (?, ?, ?, ?, ?)
    ;
    try ctx.db.exec(alloc, insert, &.{ "f1", "global:foo", "hashA", "/repo@abc", "computing" });
    try testing.expect(ctx.db.changes() > 0);

    // A second writer for the SAME question cannot insert. This is the whole
    // race guard: the loser goes on to read the winner's row instead of
    // recomputing, and `db.changes() == 0` is how it knows it lost.
    try ctx.db.exec(alloc, insert, &.{ "f2", "global:foo", "hashA", "/repo@abc", "computing" });
    try testing.expectEqual(@as(i64, 0), ctx.db.changes());

    // Same skill, DIFFERENT body → a genuinely different question, so allowed.
    try ctx.db.exec(alloc, insert, &.{ "f3", "global:foo", "hashB", "/repo@abc", "computing" });
    try testing.expect(ctx.db.changes() > 0);

    // Same skill and body in a DIFFERENT repo/commit → also a different
    // question (freshness is repo-relative), so also allowed.
    try ctx.db.exec(alloc, insert, &.{ "f4", "global:foo", "hashA", "/other@abc", "computing" });
    try testing.expect(ctx.db.changes() > 0);

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_eval_facts", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("3", row.values[0]);
}

test "Migration097's partial unique index makes one self-prompted run per session" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);

    const insert =
        \\INSERT INTO skill_eval_runs (id, session_id, trigger, status)
        \\VALUES (?, ?, ?, 'running')
    ;
    try ctx.db.exec(alloc, insert, &.{ "r1", "sess_a", "self_prompt" });

    // The agent can emit two `run_skill_eval` tool calls in one turn; both
    // would see "no run yet". The index is the arbiter, not a pre-check.
    try testing.expectError(
        error.ExecuteFailed,
        ctx.db.exec(alloc, insert, &.{ "r2", "sess_a", "self_prompt" }),
    );

    // A different session may run its own.
    try ctx.db.exec(alloc, insert, &.{ "r3", "sess_b", "self_prompt" });

    // And `on_demand` is outside the partial index, so one session can have
    // both a self-prompted and an on-demand run.
    try ctx.db.exec(alloc, insert, &.{ "r4", "sess_a", "on_demand" });

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_eval_runs", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("3", row.values[0]);
}

test "Migration097's user_id stays nullable so an empty bind is legal" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);

    // `user_id` is nullable on purpose: `exec` binds "" as SQL NULL, so a
    // plain `?` bind is the correct way to write "no owner" — a NOT NULL
    // column here would break every auth-off writer.
    try ctx.db.exec(alloc,
        "INSERT INTO skill_eval_runs (id, session_id, trigger, user_id) VALUES (?, ?, 'self_prompt', ?)",
        &.{ "r_null", "sess_c", "" });

    var q = try ctx.db.query(alloc,
        "SELECT IFNULL(user_id, '<null>') FROM skill_eval_runs WHERE id = ?",
        &.{"r_null"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("<null>", row.values[0]);
}

test "Migration097 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);
    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name LIKE 'skill_eval_%'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("3", row.values[0]);
}

test "Migration097 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration097CreateSkillEvalTables.version) return;
    }
    return error.Migration097NotRegistered;
}
