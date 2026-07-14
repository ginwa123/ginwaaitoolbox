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
};

/// Register all migrations with a MigrationManager
pub fn registerAllMigrations(manager: *MigrationManager) !void {
    for (allMigrations) |migration| {
        try manager.registerMigration(migration);
    }
}

