//! HTTP Handlers module - one file per endpoint for better organization
//!
//! This module exports all HTTP handlers used by the TUI HTTP server.
//! Each handler is in its own file for maintainability.

const std = @import("std");
pub const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const loggermod = nalarcore.loggermod;

const config = nalarcore.config;
pub const http_response = nalarcore.http_response;

// =============================================================================
// Re-exports
// =============================================================================

// Re-export all handlers
pub const corsPreflightHandler = @import("cors.zig").corsPreflightHandler;
pub const sessionCreateHandler = @import("session_create.zig").sessionCreateHandler;
pub const sessionUpdateHandler = @import("session_update.zig").sessionUpdateHandler;
pub const sessionListHandler = @import("session_list.zig").sessionListHandler;
pub const sessionStopHandler = @import("session_stop.zig").sessionStopHandler;
pub const sessionExistHandler = @import("session_exist.zig").sessionExistHandler;
pub const sessionMessagesHandler = @import("session_messages_get.zig").sessionMessagesHandler;
// GET /api/llm/session/:session_id/stream — in-flight stream snapshot
// (task_1787673548905_0 stream-resume-on-reselect).
pub const streamGetHandler = @import("stream_get.zig").streamGetHandler;
// GET /api/subagent/progress/:tool_call_id — live spawn-batch snapshot
// (task_1788505292766_1 spawn-subagent-refresh-persist).
pub const subAgentProgressGetHandler = @import("subagent_progress_get.zig").subAgentProgressGetHandler;
pub const sessionLatestHandler = @import("session_latest.zig").sessionLatestHandler;
pub const sseDisconnectHandler = @import("sse_disconnect.zig").sseDisconnectHandler;
pub const pingHandler = @import("ping.zig").pingHandler;
pub const sessionCompactHandler = @import("session_compact.zig").sessionCompactHandler;
pub const systemFolderHandler = @import("system_folder.zig").systemFolderHandler;
pub const healthHandler = @import("health.zig").healthHandler;
pub const shutdownHandler = @import("shutdown.zig").shutdownHandler;

// Workspace handlers (stub implementations for desktop app compatibility)
pub const workspacesListHandler = @import("workspaces_list.zig").workspacesListHandler;
pub const workspacesCreateHandler = @import("workspaces_create.zig").workspacesCreateHandler;
pub const workspacesReorderHandler = @import("workspaces_reorder.zig").workspacesReorderHandler;
pub const workspaceGetHandler = @import("workspace_get.zig").workspaceGetHandler;
pub const workspaceUpdateHandler = @import("workspace_update.zig").workspaceUpdateHandler;
pub const workspaceDeleteHandler = @import("workspace_delete.zig").workspaceDeleteHandler;
pub const workspaceItemsCreateHandler = @import("workspace_items_create.zig").workspaceItemsCreateHandler;
pub const workspaceItemsListHandler = @import("workspace_items_get.zig").workspaceItemsListHandler;
pub const workspaceItemsGetHandler = @import("workspace_items_get.zig").workspaceItemsGetHandler;
pub const workspaceItemsUpdateHandler = @import("workspace_items_update.zig").workspaceItemsUpdateHandler;
pub const workspaceItemsReorderHandler = @import("workspace_items_reorder.zig").workspaceItemsReorderHandler;
pub const workspaceItemsDeleteHandler = @import("workspace_items_delete.zig").workspaceItemsDeleteHandler;
pub const workspaceItemsCreateKanbanHandler = @import("workspace_items_create_kanban.zig").workspaceItemsCreateKanbanHandler;
pub const workspaceItemsCreateDesignHandler = @import("design_items_create.zig").workspaceItemsCreateDesignHandler;
// Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0) — 4th
// workspace-item type. See workspace_items_create_agent.zig.
pub const workspaceItemsCreateAgentHandler = @import("workspace_items_create_agent.zig").workspaceItemsCreateAgentHandler;
pub const agentsGetHandler = @import("agents_get.zig").agentsGetHandler;
pub const agentsUpdateHandler = @import("agents_update.zig").agentsUpdateHandler;
// Agent Mode knowledge CRUD (Task 6)
pub const agentKnowledgeCreateHandler = @import("agent_knowledge_create.zig").agentKnowledgeCreateHandler;
pub const agentKnowledgeUpdateHandler = @import("agent_knowledge_update.zig").agentKnowledgeUpdateHandler;
pub const agentKnowledgeDeleteHandler = @import("agent_knowledge_delete.zig").agentKnowledgeDeleteHandler;
pub const agentKnowledgeReorderHandler = @import("agent_knowledge_reorder.zig").agentKnowledgeReorderHandler;
// Test-only SSE emit (dev_sse_emit.zig) — gated by NALAR_TEST_SSE_EMIT=1,
// returns 404 when the gate is off. Used by functional UI tests to drive
// the chatview's SSE streaming path without a real LLM.
pub const devSseEmitLlmHandler = @import("dev_sse_emit.zig").emitLlmHandler;
// MCP server "Test" probe — fires a tools/list request against a
// candidate config (without persisting anything) so the user can
// verify their command / args / env / cwd (or URL + headers) before
// clicking Save in the MCP server modal.
pub const mcpTestHandler = @import("mcp_test.zig").mcpTestHandler;
// Agent Mode tools CRUD (Tasks 7-8)
pub const agentToolsRegistryHandler = @import("agent_tools_registry.zig").agentToolsRegistryHandler;
pub const agentToolsListHandler = @import("agent_tools_list.zig").agentToolsListHandler;
pub const agentToolsCreateHandler = @import("agent_tools_create.zig").agentToolsCreateHandler;
pub const agentToolsDeleteHandler = @import("agent_tools_delete.zig").agentToolsDeleteHandler;
// Agent Mode system-prompt CRUD (Migration 080)
pub const agentSystemPromptCreateHandler = @import("agent_system_prompt_create.zig").agentSystemPromptCreateHandler;
pub const agentSystemPromptUpdateHandler = @import("agent_system_prompt_update.zig").agentSystemPromptUpdateHandler;
pub const agentSystemPromptDeleteHandler = @import("agent_system_prompt_delete.zig").agentSystemPromptDeleteHandler;
pub const agentSystemPromptReorderHandler = @import("agent_system_prompt_reorder.zig").agentSystemPromptReorderHandler;

// Agent-Kanbans mirror (Migration 081, plan 2026-08-25-agent-kanbans-mirror)
pub const agentKanbansGetHandler = @import("agent_kanbans_get.zig").agentKanbansGetHandler;
pub const agentKanbansUpdateHandler = @import("agent_kanbans_update.zig").agentKanbansUpdateHandler;
pub const agentKanbanKnowledgeCreateHandler = @import("agent_kanban_knowledge_create.zig").agentKanbanKnowledgeCreateHandler;
pub const agentKanbanKnowledgeUpdateHandler = @import("agent_kanban_knowledge_update.zig").agentKanbanKnowledgeUpdateHandler;
pub const agentKanbanKnowledgeDeleteHandler = @import("agent_kanban_knowledge_delete.zig").agentKanbanKnowledgeDeleteHandler;
pub const agentKanbanKnowledgeReorderHandler = @import("agent_kanban_knowledge_reorder.zig").agentKanbanKnowledgeReorderHandler;
pub const agentKanbanSystemPromptCreateHandler = @import("agent_kanban_system_prompt_create.zig").agentKanbanSystemPromptCreateHandler;
pub const agentKanbanSystemPromptUpdateHandler = @import("agent_kanban_system_prompt_update.zig").agentKanbanSystemPromptUpdateHandler;
pub const agentKanbanSystemPromptDeleteHandler = @import("agent_kanban_system_prompt_delete.zig").agentKanbanSystemPromptDeleteHandler;
pub const agentKanbanSystemPromptReorderHandler = @import("agent_kanban_system_prompt_reorder.zig").agentKanbanSystemPromptReorderHandler;
pub const agentKanbanToolsListHandler = @import("agent_kanban_tools_list.zig").agentKanbanToolsListHandler;
pub const agentKanbanToolsCreateHandler = @import("agent_kanban_tools_create.zig").agentKanbanToolsCreateHandler;
pub const agentKanbanToolsDeleteHandler = @import("agent_kanban_tools_delete.zig").agentKanbanToolsDeleteHandler;

// Kanban column CRUD handlers (item_type='kanban' sub-resources).
// See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 3).
pub const kanbanColumnsListHandler = @import("kanban_columns_list.zig").kanbanColumnsListHandler;
pub const kanbanColumnsCreateHandler = @import("kanban_columns_create.zig").kanbanColumnsCreateHandler;
// POST /api/workspaces/:workspace_id/items/:item_id/kanban/tasks with
// `mode` discriminator ('create' | 'create_and_run'). See
// docs/superpowers/plans/2026-08-13-kanban-task-create-endpoint.md (Task 1).
pub const kanbanTasksCreateHandler = @import("kanban_tasks_create.zig").kanbanTasksCreateHandler;
pub const kanbanColumnsUpdateHandler = @import("kanban_columns_update.zig").kanbanColumnsUpdateHandler;
pub const kanbanColumnsDeleteHandler = @import("kanban_columns_delete.zig").kanbanColumnsDeleteHandler;
// Copy a kanban's column spec (names + descriptions, preserving order)
// from a source kanban to a target kanban. Tasks are NOT copied.
// Body: `{mode: "replace" | "append"}`. See plan
// docs/superpowers/plans/2026-07-04-copy-kanban-spec.md (Chunk 2).
pub const kanbanCopySpecHandler = @import("kanban_copy_spec.zig").kanbanCopySpecHandler;
pub const tasksMoveHandler = @import("tasks_move.zig").tasksMoveHandler;
pub const tasksListHandler = @import("tasks_list.zig").tasksListHandler;
// Single-task GET endpoint (plan:
// docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md).
pub const tasksGetHandler = @import("tasks_get.zig").tasksGetHandler;
// Kanban tag autocomplete endpoint (Chunk 1 of plan
// docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md).
// Stub-only in this commit — Task 1.4 implements the useCase body.
pub const kanbanTagsListHandler = @import("kanban_tags_list.zig").kanbanTagsListHandler;
pub const tasksCreateHandler = @import("task_create.zig").tasksCreateHandler;
pub const tasksUpdateHandler = @import("task_update.zig").tasksUpdateHandler;
pub const tasksUpdateByIdHandler = @import("task_update.zig").tasksUpdateByIdHandler;
pub const tasksDeleteHandler = @import("task_delete.zig").tasksDeleteHandler;
// Use-case + outcome type live in the same file as the handler
// (DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id).
// The handler is a thin orchestrator over `deleteTaskUseCase`; both
// are scoped under `nalarcore.http_handlers.*` per the project
// convention (see `nalar_config_profile_delete.zig`'s re-exports).
pub const deleteTaskUseCase = @import("task_delete.zig").deleteTaskUseCase;
pub const TaskDeleteOutcome = @import("task_delete.zig").TaskDeleteOutcome;
pub const taskPinHandler = @import("task_pin.zig").taskPinHandler;
// Chunk 3 of kanban-task-notification-icon: thin handler that stamps
// `last_human_touched_at` and emits the `kanban_task.human_touched`
// SSE event. See docs/plans/2026-07-26-kanban-task-notification-icon.md.
pub const taskMarkHumanTouchedHandler = @import("task_mark_human_touched.zig").taskMarkHumanTouchedHandler;
pub const tasksReorderPinnedHandler = @import("tasks_reorder_pinned.zig").tasksReorderPinnedHandler;
// Task attachment upload/download handlers — REMOVED 2026-08-06
// (Migration 069 / kanban-image-urls-column plan). Replaced by the
// `workspace_item_tasks.image_urls` column (`||`-delimited base64
// data URLs) — see image_urls_validation.zig for the wire format
// and validation. No filesystem path lookup, no broken `*` GET
// wildcard route. The handler files task_attachment_post.zig and
// task_attachment_get.zig have been deleted.
pub const routinesRunHandler = @import("routines_run.zig").routinesRunHandler;
// NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Dedicated
// endpoint for triggering an LLM worker on an existing task's
// session WITHOUT queueing a new user message. Distinct from
// `sessionCreateHandler` (POST /api/llm/session) which always
// inserts a queue message.
pub const startAgentHandler = @import("start_agent.zig").startAgentHandler;
// NEW (plan: 2026-08-18-kanban-task-detail-start-agent). The split
// use-case, re-exported so callers + tests can reach it as
// `nalarcore.http_handlers.startAgentUseCase` (matches the
// `task_delete.zig::deleteTaskUseCase` re-export convention).
pub const startAgentUseCase = @import("start_agent.zig").startAgentUseCase;
pub const runAllAgentsHandler = @import("run_all_agents.zig").runAllAgentsHandler;
pub const routinesListHandler = @import("routines_list.zig").routinesListHandler;

// Worker API handlers
pub const workerGetHandler = @import("worker_get.zig").workerGetHandler;
pub const workerListHandler = @import("worker_list.zig").workerListHandler;

// Unified SSE handler — single endpoint that fans out all event families.
// Replaces the 5 dedicated routes registered in main.zig. See
// unified_events_sse.zig for the channel grammar (?channels=).
pub const unifiedEventsStreamHandler = @import("unified_events_sse.zig").unifiedEventsStreamHandler;

// Skills API handlers
pub const skillsListHandler = @import("skills_list.zig").skillsListHandler;
pub const skillDetailHandler = @import("skill_detail.zig").skillDetailHandler;
pub const skillDeleteHandler = @import("skill_delete.zig").skillDeleteHandler;

// Memories API handlers
pub const memoriesListHandler = @import("memories_list.zig").memoriesListHandler;
pub const memoryDetailHandler = @import("memories_detail.zig").memoryDetailHandler;
pub const memoryCreateHandler = @import("memories_create.zig").memoryCreateHandler;
pub const memoryUpdateHandler = @import("memories_update.zig").memoryUpdateHandler;
pub const memoryDeleteHandler = @import("memories_delete.zig").memoryDeleteHandler;

// Local Memories API handlers — same CRUD shape as the global memories
// handlers above but operating on `<cwd>/.nalar/memories/` instead of
// `~/.config/nalar/memories/`. The `cwd` resolution prefers the body
// (for POST/PUT) or the query string (for GET/DELETE), falling back
// to the nalar server's CWD via `io.realPath` when no explicit cwd
// is provided. See `docs/plans/2026-06-20-add-markdown-memory.md`.
pub const localMemoriesListHandler = @import("local_memories_list.zig").localMemoriesListHandler;
pub const localMemoryDetailHandler = @import("local_memories_detail.zig").localMemoryDetailHandler;
pub const localMemoryCreateHandler = @import("local_memories_create.zig").localMemoryCreateHandler;
pub const localMemoryUpdateHandler = @import("local_memories_update.zig").localMemoryUpdateHandler;
pub const localMemoryDeleteHandler = @import("local_memories_delete.zig").localMemoryDeleteHandler;

// Git API handlers
pub const gitStatusHandler = @import("git_status.zig").gitStatusHandler;
pub const gitChangesHandler = @import("git_changes.zig").gitChangesHandler;
pub const gitFileDiffHandler = @import("git_file_diff.zig").gitFileDiffHandler;
pub const gitFileReadHandler = @import("git_file_diff.zig").gitFileReadHandler;
pub const gitStageHandler = @import("git_file_stage.zig").gitStageHandler;
pub const gitUnstageHandler = @import("git_file_stage.zig").gitUnstageHandler;
pub const gitWorktreeInfoHandler = @import("git_worktree_info.zig").gitWorktreeInfoHandler;
pub const gitPrCreateHandler = @import("git_pr_create.zig").gitPrCreateHandler;

// Queue messages handlers
pub const queueMessagesGetHandler = @import("queue_messages_get.zig").queueMessagesGetHandler;
// Session background-process handlers — list + log tail for
// `command background=true` rows (no new SSE event, no migration).
pub const backgroundProcessesListHandler = @import("background_processes_list.zig").backgroundProcessesListHandler;
pub const backgroundProcessLogGetHandler = @import("background_process_log_get.zig").backgroundProcessLogGetHandler;

// Design-mode HTTP handlers (item_type='design') — v6 of the
// design-mode redesign. See
// docs/superpowers/plans/2026-07-08-design-mode-redesign.md
// (Chunk 3) for the full route table.
pub const designPagesListHandler = @import("design_pages_list.zig").designPagesListHandler;
pub const designPagesCreateHandler = @import("design_pages_create.zig").designPagesCreateHandler;
pub const designPagesGetHandler = @import("design_pages_get.zig").designPagesGetHandler;
pub const designPagesUpdateHandler = @import("design_pages_update.zig").designPagesUpdateHandler;
pub const designPagesDeleteHandler = @import("design_pages_delete.zig").designPagesDeleteHandler; // 2026-07-25-design-page-delete-button (Chunk 1)
pub const designElementsCreateHandler = @import("design_elements_create.zig").designElementsCreateHandler;
pub const designElementsUpdateHandler = @import("design_elements_update.zig").designElementsUpdateHandler;
pub const designElementsDeleteHandler = @import("design_elements_delete.zig").designElementsDeleteHandler;
pub const designElementsHtmlGetHandler = @import("design_elements_html_get.zig").designElementsHtmlGetHandler;
pub const designElementsHtmlUpdateHandler = @import("design_elements_html_update.zig").designElementsHtmlUpdateHandler;
// DEPRECATED — PATCH .../geometry. Use POST .../translate (move) or
// POST .../resize (resize) instead. Kept for back-compat with
// any client still wired to the old single endpoint.
pub const designElementsGeometryUpdateHandler = @import("design_elements_geometry_update.zig").designElementsGeometryUpdateHandler;
// DEPRECATED — POST .../geometry-batch. Replaced by POST .../move-batch
// (server-side cascade) for multi-element translation. Kept for
// back-compat with any client still wired to the old endpoint.
pub const designElementsGeometryBatchHandler = @import("design_elements_geometry_batch.zig").designElementsGeometryBatchHandler;
// NEW (2026-08-06) — POST .../translate. Single-element move with
// delta. Cascades to descendants when the element is a group/frame.
// See docs/superpowers/plans/2026-08-06-split-move-resize.md.
pub const designElementsTranslateHandler = @import("design_elements_translate.zig").designElementsTranslateHandler;
pub const designElementsTranslateUseCase = @import("design_elements_translate.zig").useCase;
pub const designElementsTranslateError = @import("design_elements_translate.zig").DesignElementTranslateError;
// NEW (2026-08-06) — POST .../resize. Single-element resize with
// absolute x/y/width/height/rotation. No cascade (resize is per-element
// by Figma convention).
// See docs/superpowers/plans/2026-08-06-split-move-resize.md.
pub const designElementsResizeHandler = @import("design_elements_resize.zig").designElementsResizeHandler;
pub const designElementsResizeUseCase = @import("design_elements_resize.zig").useCase;
pub const designElementsResizeError = @import("design_elements_resize.zig").DesignElementResizeError;
// Group 2+ elements into a new `group`/`frame` parent. POST
// /api/workspaces/:w/items/:i/design/pages/:p/elements/group — see
// docs/superpowers/plans/2026-07-28-grouped-layers.md (Chunk 3).
pub const designElementsGroupHandler = @import("design_elements_group.zig").designElementsGroupHandler;
pub const designElementsReorderHandler = @import("design_elements_reorder.zig").designElementsReorderHandler;
pub const designElementsReparentBatchHandler = @import("design_elements_reparent.zig").designElementsReparentBatchHandler;
// Server-side cascade move. POST /api/workspaces/:w/items/:i/design/pages/:p/elements/move-batch
// — see docs/superpowers/plans/2026-08-06-move-element-with-descendants.md (Chunk 2).
pub const designElementsMoveBatchHandler = @import("design_elements_move_batch.zig").designElementsMoveBatchHandler;
// Cross-page element relocate. POST /api/workspaces/:w/items/:i/design/pages/:p/elements/:eid/move-to-page
// — see docs/superpowers/plans/2026-08-06-move-element-to-page.md (Chunk 2).
pub const designElementsMoveToPageHandler = @import("design_elements_move_to_page.zig").designElementsMoveToPageHandler;
pub const designElementsUngroupHandler = @import("design_elements_ungroup.zig").designElementsUngroupHandler;

// Session to client IDs monitoring
pub const sessionToClientIdsHandler = @import("session_to_client_ids.zig").sessionToClientIdsHandler;

// Debug/inspection endpoint — returns the rendered system prompt for a
// session. See `system_prompt_get.zig` for the full contract.
pub const systemPromptGetHandler = @import("system_prompt_get.zig").systemPromptGetHandler;

// Nalar config handlers
pub const nalarConfigGetHandler = @import("nalar_config_get.zig").nalarConfigGetHandler;
pub const nalarConfigPutHandler = @import("nalar_config_put.zig").nalarConfigPutHandler;
pub const nalarConfigProfileDeleteHandler = @import("nalar_config_profile_delete.zig").nalarConfigProfileDeleteHandler;
// Use-case + domain types live in the same file as the handler. The
// handler is a thin orchestrator over the use-case; both are scoped
// under `nalarcore.http_handlers.*` (the convention for handler
// internals — see `nalar_config_profile_delete_test.zig`'s header).
pub const removeProfileFromConfig = @import("nalar_config_profile_delete.zig").removeProfileFromConfig;
pub const NalarConfigJsonForDelete = @import("nalar_config_profile_delete.zig").NalarConfigJsonForDelete;
// `ConfigInput` is the wire format for `PUT /api/config/nalar`. It is
// `pub` so the test file can re-parse the same body the handler would
// and lock in the parse-step tolerance (the on-disk object map vs the
// granular array-of-changes shape). Exposed alongside `parseConfigInput`
// for the same reason.
pub const ConfigInput = @import("nalar_config_put.zig").ConfigInput;
pub const parseConfigInput = @import("nalar_config_put.zig").parseConfigInput;

// OS notification test handler — fires a real OS notification so the
// user can verify their system can display them without running a
// full LLM stream. See /docs/superpowers/plans/2026-01-15-llm-completion-notification.md
pub const notifyTestHandler = @import("notify_test.zig").notifyTestHandler;

// Frontend error log handlers — persist and query the
// window.error / unhandledrejection / console.error / console.warn
// events in the `logs` table. See
// docs/plans/2026-07-17-frontend-error-logs-design.md.
pub const frontendLogPostHandler = @import("frontend_log_post.zig").frontendLogPostHandler;
pub const frontendLogGetHandler = @import("frontend_log_get.zig").frontendLogGetHandler;

// =============================================================================
// Shared Types & Helpers
// =============================================================================

/// Response format types
pub const ResponseFormat = enum { json, xml };

/// Determine response format from Accept header or query param
pub fn getResponseFormat(req: gserverz.HttpRequest) ResponseFormat {
    // First check Accept header (higher priority)
    if (req.header("accept")) |accept| {
        if (std.mem.indexOf(u8, accept, "text/xml") != null or
            std.mem.indexOf(u8, accept, "application/xml") != null)
        {
            return .xml;
        }
        if (std.mem.indexOf(u8, accept, "application/json") != null) {
            return .json;
        }
    }

    // Fallback to query parameter
    const query = req.query() catch return .json;
    const format_param = query.get("format") orelse return .json;

    if (std.mem.eql(u8, format_param, "xml")) {
        return .xml;
    }
    return .json;
}

/// Build error response based on format
pub fn buildErrorResponse(allocator: std.mem.Allocator, format: ResponseFormat, error_msg: []const u8) ![]u8 {
    if (format == .xml) {
        return std.fmt.allocPrint(allocator, "<error>{s}</error>", .{error_msg});
    } else {
        return http_response.makeErrorResponse(allocator, .{ .@"error" = error_msg });
    }
}

/// SSE stream context for persistent connections
pub const SseStreamCtx = struct {
    server: *nalarcore.gserverz.GinwaServer,
    session_id: []const u8,
};
