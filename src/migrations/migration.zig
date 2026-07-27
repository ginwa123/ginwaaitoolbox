const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const sqlite_mod = nalarcore.sqlite;

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
// (src/ai_workflow/tui/llm_history.zig:1861).
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

/// Register all migrations with a MigrationManager
pub fn registerAllMigrations(manager: *MigrationManager) !void {
    for (allMigrations) |migration| {
        try manager.registerMigration(migration);
    }
}

