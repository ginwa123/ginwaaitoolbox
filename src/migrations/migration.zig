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
        try addColumnIfMissing(db, allocator, "worker", "working_directory", "working_directory TEXT");
        try addColumnIfMissing(db, allocator, "worker", "last_activity", "last_activity INTEGER DEFAULT (strftime('%s', 'now'))");
        try addColumnIfMissing(db, allocator, "worker", "last_activity_description", "last_activity_description TEXT");
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
        try dropColumnIfExists(db, allocator, "workspace_item_tasks", "session_id");
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
        try dropColumnIfExists(db, allocator, "design_pages", "html");

        // Ensure the 4 new position columns exist. On fresh DBs the
        // CREATE TABLE above already declares them with the same
        // defaults, so these are no-ops; on legacy DBs they're new
        // columns being backfilled with sensible defaults.
        try addColumnIfMissing(db, allocator, "design_pages", "width", "width INTEGER NOT NULL DEFAULT 1440");
        try addColumnIfMissing(db, allocator, "design_pages", "height", "height INTEGER NOT NULL DEFAULT 1024");
        try addColumnIfMissing(db, allocator, "design_pages", "x", "x INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(db, allocator, "design_pages", "y", "y INTEGER NOT NULL DEFAULT 0");

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
        try addColumnIfMissing(db, allocator, "design_page_elements", "type",
            "type TEXT NOT NULL DEFAULT 'rectangle'");
        try addColumnIfMissing(db, allocator, "design_page_elements", "rotation",
            "rotation REAL NOT NULL DEFAULT 0");
        try addColumnIfMissing(db, allocator, "design_page_elements", "fill",
            "fill TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(db, allocator, "design_page_elements", "stroke",
            "stroke TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(db, allocator, "design_page_elements", "stroke_width",
            "stroke_width INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(db, allocator, "design_page_elements", "corner_radius",
            "corner_radius INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(db, allocator, "design_page_elements", "opacity",
            "opacity REAL NOT NULL DEFAULT 1.0");
        try addColumnIfMissing(db, allocator, "design_page_elements", "text_content",
            "text_content TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(db, allocator, "design_page_elements", "text_style",
            "text_style TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(db, allocator, "design_page_elements", "image_url",
            "image_url TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(db, allocator, "design_page_elements", "parent_id",
            "parent_id TEXT");

        // Analyze so the query planner sees the new columns on
        // legacy DBs.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

// ────────────────────────────────────────────────────────────────────────
// Migration 058 — FTS5 virtual table on llm_history (search-history rewrite)
// ────────────────────────────────────────────────────────────────────────
//
// Why this migration exists
// ──────────────────────────
// The search-history rewrite (plan docs/superpowers/plans/2026-07-16-search-history-rewrite.md,
// Chunk 3) replaces the LIKE-prefix-scan with an FTS5 MATCH query. This
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
// UpgradeDesignPagesToFileModel, AddDesignElementProperties — see
// search-history-rewrite branch as of 2026-07-21). 58 is the next free
// slot in the migration sequence. See Chunk 1 / Task 1.2 of the plan.
//
// Plan: docs/superpowers/plans/2026-07-16-search-history-rewrite.md (Chunk 1)
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
    db: *SqliteBackend,
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
    db: *SqliteBackend,
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
    db: *SqliteBackend,
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
/// `since`/`until` filter on `search_history` and `getCompactedMessages`
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
/// previous `search_history` / `getCompactedMessages` `since`/`until`
/// filters did a lex-comparison on this column against user input like
/// `"2026-07-15 00:00:00"` — which silently returned 0 rows because
/// `'1' < '2'` (so `'1784…' < '2026-…'` is always true, excluding every
/// row). See `docs/superpowers/plans/2026-07-15-search-history-since-until-bug.md`.
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
            db,
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
            db,
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
            db,
            allocator,
            "sessions",
            "is_auto_retry_until_stop",
            "is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0",
        );
        // Cache column — nullable; stays NULL until workflow.zig writes
        // the first value (see workflow.zig's new
        // `updateSessionLastFinishReason` call site, Chunk 2 Task 2.1).
        try addColumnIfMissing(
            db,
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
            db,
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
            db,
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
            db,
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
            db,
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
            db,
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
            db,
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
/// Steps (inside a single BEGIN..COMMIT for atomicity — a crash mid-
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
        // Wrap in BEGIN..COMMIT so the CREATE+INSERT+DROP sequence is
        // atomic. Without the wrapper, SQLite auto-commits each step
        // and a crash between step 3 (backfill) and step 5 (DROP
        // COLUMN) would leave the DB with both new and old columns
        // populated.
        try db.exec(allocator, "BEGIN", &.{});
        errdefer {
            // If anything below errors, rollback best-effort. The
            // errdefer doesn't run on the success path (the explicit
            // COMMIT runs first).
            db.exec(allocator, "ROLLBACK", &.{}) catch {};
        }

        // Step 1: CREATE kanban (idempotent via IF NOT EXISTS)
        try db.exec(allocator,
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
        try db.exec(allocator,
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
        try db.exec(allocator,
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
        var q = try db.query(allocator, check_sql, &.{});
        defer q.deinit();
        if (try q.next()) |row| {
            // Source columns still exist — first run, do the backfill.
            row.deinit(allocator);
            try db.exec(allocator,
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
        try dropColumnIfExists(db, allocator, "workspace_item_tasks", "kanban_column_id");
        try dropColumnIfExists(db, allocator, "workspace_item_tasks", "kanban_position");

        // Commit the transaction. After this, Migration 072 is "done"
        // and the new schema is durable.
        try db.exec(allocator, "COMMIT", &[_][]const u8{});

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
        try addColumnIfMissing(db, allocator, "llm_history", "cache_creation_input_tokens", "cache_creation_input_tokens INTEGER DEFAULT 0");

        // Anthropic cache READ breakdown (billed at ~0.1x input rate, but still tokens the model processed -- folded into `prompt_tokens` + `total_tokens` by Agent.parse_anthropic_stream_chunk). Default 0 for legacy rows + non-Anthropic profiles.
        try addColumnIfMissing(db, allocator, "llm_history", "cache_read_input_tokens", "cache_read_input_tokens INTEGER DEFAULT 0");
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
        // Wrap in BEGIN..COMMIT so the 5 renames + 2 index swaps are
        // atomic. A crash mid-migration would otherwise leave the DB
        // with some columns renamed and others not, breaking every
        // SQL site that targets the old names. SQLite auto-commits
        // each statement otherwise.
        try db.exec(allocator, "BEGIN", &.{});
        errdefer {
            // Best-effort rollback on any error below.
            db.exec(allocator, "ROLLBACK", &.{}) catch {};
        }

        // 5 column renames — order doesn't matter logically, but
        // keep the order alphabetical by table for diff readability.
        try renameColumnIfExists(db, allocator, "llm_history", "created_at", "created_at_nano");
        try renameColumnIfExists(db, allocator, "logs", "created_at", "created_at_nano");
        try renameColumnIfExists(db, allocator, "session_skills", "loaded_at", "loaded_at_nano");
        try renameColumnIfExists(db, allocator, "worker", "last_activity", "last_activity_nano");
        try renameColumnIfExists(db, allocator, "workspace_item_tasks", "last_human_touched_at", "last_human_touched_at_nano");

        // 2 index renames — SQLite doesn't have `ALTER INDEX … RENAME
        // TO …`, and the index's auto-generated name doesn't auto-
        // update on the column rename. DROP + CREATE under the new
        // name. The `IF NOT EXISTS` on the CREATE is defensive
        // (after a re-run, the new index already exists).
        try db.exec(allocator, "DROP INDEX IF EXISTS idx_logs_created_at", &.{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_created_at_nano ON logs(created_at_nano DESC)",
            &.{});

        try db.exec(allocator, "DROP INDEX IF EXISTS idx_worker_last_activity", &.{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_worker_last_activity_nano ON worker(last_activity_nano DESC)",
            &.{});

        // Commit the transaction. After this, Migration 075 is
        // "done" and the new schema is durable.
        try db.exec(allocator, "COMMIT", &[_][]const u8{});

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
            db,
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
    // Why BEGIN..COMMIT wraps the whole thing
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
        // BEGIN..COMMIT — atomic; see "Why BEGIN..COMMIT" in the
        // docstring above.
        try db.exec(allocator, "BEGIN", &.{});
        errdefer {
            // Best-effort rollback on any error below. The errdefer
            // doesn't fire on the success path (the explicit COMMIT runs
            // first).
            db.exec(allocator, "ROLLBACK", &.{}) catch {};
        }

        // 1. users — identity table.
        try db.exec(allocator,
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
        try db.exec(allocator,
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
        try db.exec(allocator,
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
            db,
            allocator,
            "workspaces",
            "user_id",
            "user_id TEXT",
        );

        // 5. sessions.user_id — same shape as workspaces.user_id.
        try addColumnIfMissing(
            db,
            allocator,
            "sessions",
            "user_id",
            "user_id TEXT",
        );

        // 6. Indexes — 6 total. CREATE INDEX IF NOT EXISTS is idempotent.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_users_active ON users(is_active)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_companies_slug ON user_companies(slug)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_companies_active ON user_companies(is_active)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_company_members_user ON user_company_members(user_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_company_members_company ON user_company_members(user_company_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspaces_user_id ON workspaces(user_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id)",
            &[_][]const u8{});

        // 7. Default user_system — INSERT OR IGNORE makes it idempotent.
        //    See the spec §3.6 for the full reasoning (password_hash
        //    sentinel, is_active=0, system@local reserved per RFC 6762).
        try db.exec(allocator,
            "INSERT OR IGNORE INTO users (id, email, name, password_hash, role, is_active) " ++
                "VALUES ('user_system', 'system@local', 'System', '!disabled', 'admin', 0)",
            &[_][]const u8{});

        // 8. Backfill — convert every legacy row (workspaces,
        //    sessions) WHERE user_id IS NULL to user_id='user_system'.
        //    WHERE user_id IS NULL makes the UPDATE idempotent on
        //    re-run: rows that already have user_id set are not
        //    touched. On a fresh DB with zero legacy rows, both UPDATEs
        //    are no-ops.
        try db.exec(allocator,
            "UPDATE workspaces SET user_id = 'user_system' WHERE user_id IS NULL",
            &[_][]const u8{});
        try db.exec(allocator,
            "UPDATE sessions SET user_id = 'user_system' WHERE user_id IS NULL",
            &[_][]const u8{});

        // Commit the transaction. After this, the new schema is durable.
        try db.exec(allocator, "COMMIT", &[_][]const u8{});

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
            db,
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
            db,
            allocator,
            "llm_history",
            "reasoning_id",
            "reasoning_id TEXT",
        );
        try addColumnIfMissing(
            db,
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
