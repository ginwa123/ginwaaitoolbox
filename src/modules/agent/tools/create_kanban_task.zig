//! LLM tool: `create_kanban_task` — creates a new `workspace_item_tasks`
//! row under an existing kanban `workspace_item`.
//!
//! Flow (mirrors `task_create.zig::createStandardTask` exactly):
//!   1. Validate `workspace_id`, `item_id`, `name` (non-empty after trim).
//!   2. Verify the parent `workspace_items.id = item_id` has
//!      `item_type = 'kanban'`. Reject otherwise.
//!   3. INSERT into `workspace_item_tasks` via
//!      `nalarcore.ai_mod.llm_history.createWorkspaceItemTask` with
//!      `task_type = 'standard'` (every kanban task is a standard task
//!      whose PARENT has `item_type='kanban'`; the schema has no
//!      `task_type='kanban'`).
//!   4. Resolve the target column id. When `column_id` is null, pick
//!      the first column by `position ASC`. When supplied, verify the
//!      column belongs to the same `workspace_item_id`.
//!   5. UPDATE the task's `kanban_column_id` and `kanban_position`
//!      (set to MAX(position)+1 within the target column).
//!   6. Emit a `kanban_task` SSE event with `action="created"` for
//!      multi-tab sync (fire-and-forget; log + continue on error).
//!   7. Return the success XML to the LLM.
//!
//! Plan: docs/superpowers/plans/2026-07-29-create-kanban-task-tool.md
//! Parallel HTTP handler: `src/ai_workflow/tui/http_handlers/task_create.zig`
//!   ::createStandardTask (lines 337-503).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

/// Input structure for `create_kanban_task` tool.
///
/// The agent should pass `workspace_id` and `item_id` from the active
/// chat context (see the "## Workspace Context" section of the system
/// prompt). `name` is the card title. `description` is optional (the
/// task's tooltip text in the kanban UI). `column_id` is optional —
/// when omitted, the task is auto-assigned to the first column at
/// `MAX(kanban_position) + 1` (append-to-bottom semantics matching
/// the HTTP handler).
pub const CreateKanbanTaskInput = struct {
    /// The workspace that owns the kanban item. From chat context.
    workspace_id: []const u8 = "",
    /// The kanban workspace item id. From chat context. Must have
    /// `item_type='kanban'` (validated up front).
    item_id: []const u8 = "",
    /// Card title shown on the kanban board. Required, must be
    /// non-empty after trim of leading/trailing whitespace.
    name: []const u8 = "",
    /// Optional card description (tooltip text in the kanban UI).
    description: ?[]const u8 = null,
    /// Optional target column id. When omitted, the task is
    /// auto-assigned to the first column by `position ASC` at
    /// `MAX(kanban_position) + 1`. When supplied, the tool verifies
    /// the column belongs to the same kanban item.
    column_id: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM.
///
/// The description is the LLM's primary signal for WHEN to use this
/// tool — it tells the LLM:
///   1. The tool creates a NEW card on a kanban board (use this when
///      the user says "add a task to the kanban", "create a card
///      for X", etc.).
///   2. `workspace_id` and `item_id` come from the active chat's
///      "## Workspace Context" section (no hallucinated ids).
///   3. `column_id` is OPTIONAL — omit it to auto-assign to the
///      first column (append-to-bottom). Pass it only when the user
///      explicitly names a column.
pub const create_kanban_task_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "create_kanban_task",
        .description =
            \\Create a new task/card on a kanban board. Use this tool when the user asks to add a new task to a kanban, "create a card for X", "add 'do the thing' to the sprint", or any other instruction that means "make a new card". The task is auto-assigned to the first column at MAX(kanban_position)+1 unless column_id is supplied.
            \\
            \\The workspace_id and item_id must come from the chat context — see the "## Workspace Context" section of the system prompt. Each sibling item is rendered as `- **<name>** (id: <id>, item_type: <type>, path: <path>)` where the id is a backtick-quoted id (e.g. item_1782313125507292140). The id is the **canonical** lookup key — do NOT pass the human-readable name (e.g. "sprint 1"); the DB columns are indexed by id and a name lookup returns zero rows. The kanban item is the one with `item_type='kanban'` marked with `*(this task)*` in the Workspace Context.
            \\
            \\name is required (card title shown on the board). description is optional (tooltip text). column_id is optional — when omitted, the task is auto-assigned to the first kanban column at MAX(kanban_position)+1; when supplied, the column must belong to the same kanban item. To set a specific position, call kanban_move_task after this tool returns.
            \\
            \\Workflow: (1) call kanban_list first to discover the kanban item id and (optionally) the column id if the user named one, (2) call create_kanban_task with those ids, (3) use kanban_move_task if the task needs to land in a non-default position. On error, recover by: (1) verify item_id from the Workspace Context listing; (2) if the parent item is not a kanban, the tool returns a structured error — pick the item marked `*(this task)*` instead; (3) if column_id was rejected, omit it and let auto-assign place the card.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "workspace_id",
                    .type = "string",
                    .description = "The workspace that owns the kanban item. From chat context. Always starts with `ws_`.",
                },
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The kanban workspace item id (NOT the name). From chat context. The item has `item_type='kanban'`. Always starts with `item_`.",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Card title shown on the kanban board. Required, non-empty after trim. Used as the chat session's name when the user later opens the card.",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "Optional card description (tooltip text in the kanban UI). Omit when no description is needed.",
                },
                .{
                    .name = "column_id",
                    .type = "string",
                    .description = "Optional target column id (NOT name). When omitted, the task is auto-assigned to the first column at MAX(kanban_position)+1. Use kanban_list to discover column ids — never pass the human-readable name.",
                },
            },
            .required = &.{ "workspace_id", "item_id", "name" },
        },
    },
};

// =====================================================================
// Stub (replaced in Task 4)
// =====================================================================
//
// PLACEHOLDER — does nothing yet. Compiles so Task 3's behavioral
// tests can be written and run (RED phase). Replaced by the real
// implementation in Task 4 (GREEN phase).
//
// The stub returns a deliberately wrong XML so every behavioral test
// fails for the right reason: the tool is not implemented, not for
// an unrelated reason (DB error, missing field, etc.). This is the
// TDD RED-state discipline.

pub fn executeCreateKanbanTaskToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: CreateKanbanTaskInput,
) ![]u8 {
    _ = db;
    _ = input;
    return try allocator.dupe(u8, "<kanban_task><success>false</success><error>NOT_IMPLEMENTED</error></kanban_task>");
}