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