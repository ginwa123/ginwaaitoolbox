### 2026-08-19: Agent tools `update_plan` + `get_plan` — session-scoped markdown plan with checklist

**What landed.** Two new agent-callable tools (`update_plan` overwrites the plan; `get_plan` fetches it) backed by a new `session_plan` SQLite table (1:1 with `sessions`, `session_id TEXT PRIMARY KEY`, `plan_md TEXT NOT NULL DEFAULT ''`, `updated_at DATETIME DEFAULT CURRENT_TIMESTAMP`). Migration 076 (`create_session_plan`) creates the table on a fresh DB. The plan is plain markdown with a `- [ ]` / `- [x]` checklist; the agent overwrites on every call (UPSERT, 256 KiB hard cap). Plan is re-injected into every agent iteration via the system prompt (new `prompts_make_plan_context.zig` adds a `## Current Plan` section under the existing `agent_memories` block) AND embedded as a `<plan>` section in the compaction envelope (via `enrichCompactionXml`) so the next agent after compaction knows what the prior agent was doing. CDATA-escaping splits `]]>` sequences the same way `enrichCompactionXml`'s `session_skills` block does. No FK constraint to `sessions.id` (matches the `session_activity` / `llm_history` precedent). `session_id` is implicit (pulled from `ToolExecContext`); the LLM never passes it. `update_plan` returns `<update_plan><session_id>...</session_id><updated_at>...</updated_at></update_plan>`; `get_plan` returns `<get_plan><plan><![CDATA[...markdown...]]></plan></get_plan>` or `<get_plan><empty/></get_plan>` when no plan row exists. Optional UI: `UpdatePlan.vue` + `GetPlan.vue` Vue components render the tool result as a collapsible checklist card in the chatview. Both files in `src/apps/desktop/src/components/tool_outputs/`; registered in the existing `ToolOutputRegistry` alongside `UpdateMemory` / `LoadMemory`. The chip on the chat bubble shows a checkbox-count summary (`3/5 done`); clicking expands the full checklist.

**Wire (backend).** Two new LLM tools registered in `UNIFIED_TOOL_REGISTRY`: `update_plan` (input: `content: string` — the markdown body; rejects empty string with `<error>`) and `get_plan` (no input). Both delegate to the pure-fn helpers in `src/modules/agent/session_plan.zig` (`upsertPlan` / `getPlanOpt`). The exec adapter at `src/ai_workflow/tui/agentic_loop/tools_exec_update_plan.zig` pulls `ctx.session_id` from `ToolExecContext` and threads it into the helper. New system-prompt context builder `src/ai_workflow/tui/agentic_loop/prompts_make_plan_context.zig` reads the plan via `getPlanOpt` and emits the `## Current Plan` block when present (omitted entirely when no plan row exists — same convention as the existing `agent_memories` block). New `fetchSessionPlan` helper in `workflow_compact_message.zig` + a new `plan: ?PlanRow` parameter on `enrichCompactionXml`; the caller in `workflow_commpact_message.zig` fetches the plan BEFORE `mark_history_not_for_llmrun` so the enriched INSERT carries the plan forward.

**Files.** 13 (5 NEW, 8 EDIT). Backend + frontend + migration. No schema changes beyond the new table.

**Plan:** docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
**Branch:** worktree/agent-plan-tool
**Task:** task_1787066122956_5

### 2026-08-13: kanban task name = session name

**What landed.** Kanban task `name` and the linked session `name` now bind to the same trimmed title at create time. The sidebar (ChatsList), chat header (`ChatView.chatName`), and kanban card (`task.name`) all show the same string the user typed at create time — no manual rename, no LLM auto-rename required.

**Files.** 6 (1 NEW, 5 EDIT). Backend-only — no migration, no schema change, no frontend change.

**Plan:** docs/superpowers/plans/2026-08-13-kanban-task-session-name-match.md
**Branch:** worktree/kanban-task-session-name-match
**Task:** task_1786626864861

### 2026-08-18: kanban task detail — Start agent button

**What landed.** New `▶ Start agent` button in the kanban task-detail dialog (edit mode only). Mirrors the create-mode `▶ Create task & run agent` button. Clicking kicks off an LLM worker on the task's existing session WITHOUT queueing a new user message; the agent runs on whatever chat history is already in the session. The button is `:disabled` while `processingState[task.id]` is true (via the existing App.vue map), so it's safe to spam and discoverable as "greyed out = a worker is already running". On success the dialog closes and the user stays on the kanban; on failure the dialog stays open with an errorMessage banner.

**Wire (backend).** New dedicated endpoint `POST /api/workspaces/:ws/items/:i/tasks/:task_id/start_agent` — NOT a wrapper around `/api/llm/session` (which always queues a message). Validates task exists (404), no worker running (409), then calls `di.emit_run_agent` with a new `skip_initial_queue_message: true` flag that threads through `EmitRunAgentInput` → `RunParamsNew` → `runAgenticMultiStepnew`. The workflow's `insertQueueMessage` call is wrapped in `if (!params.skip_initial_queue_message)`, so the agent loop runs on the existing chat history alone.

**Files.** 14 (5 NEW, 9 EDIT). Backend + frontend, no migration, no schema change.

**Plan:** docs/superpowers/plans/2026-08-18-kanban-task-detail-start-agent.md
**Spec:** docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent-design.md
**Branch:** worktree/kanban-task-detail-start-agent
**Task:** task_1787036138314_0

### 2026-08-19: Kanban "Create task" now inits session, no agent run

**What landed.** The plain `Create task` button in the kanban New Task dialog now also inserts a `sessions` row + emits the `session_created` SSE (new mode `'create_session'` on the existing `POST /api/workspaces/:wid/items/:iid/kanban/tasks` endpoint) but does NOT call `emit_run_agent`. The user can click the card to open the chatview on a pre-existing empty session with no lazy-creation race when they type their first message. The chatview's profile picker + unattended toggle now reflect the dialog's choice immediately (selected_profile_model is persisted on the new sessions row). Two-button story: `Create task` = prep everything, you open the chat yourself; `Create task & run agent` = prep everything + kick off the agent with the title + description as the first message. Backward compat: legacy `mode='create'` on the API surface keeps the old behaviour (no session insert) for any external consumer.

**Wire (backend).** New mode value `'create_session'` on the existing `POST /api/workspaces/:wid/items/:iid/kanban/tasks` endpoint. Shares the sessions-INSERT + session_created-SSE plumbing with `create_and_run`, but the `emit_run_agent` call is narrowed behind a fresh `if (is_create_and_run)` guard so the worker never fires for the new mode. Response wire: `status: 'idle'` (vs `'send'` for create_and_run) so the frontend can distinguish at a glance. 5 new static-contract tests in `kanban_tasks_create_test.zig` lock in the wire contract.

**Files.** 8 (2 NEW, 6 EDIT). Backend + frontend, no migration, no schema change.

**Plan:** docs/superpowers/plans/2026-08-19-kanban-create-task-inits-session.md
**Branch:** worktree/kanban-create-task-inits-session
**Task:** task_1787066122956_5