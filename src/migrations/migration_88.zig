const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

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
