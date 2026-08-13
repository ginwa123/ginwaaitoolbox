### 2026-08-13: kanban task name = session name

**What landed.** Kanban task `name` and the linked session `name` now bind to the same trimmed title at create time. The sidebar (ChatsList), chat header (`ChatView.chatName`), and kanban card (`task.name`) all show the same string the user typed at create time — no manual rename, no LLM auto-rename required.

**Files.** 6 (1 NEW, 5 EDIT). Backend-only — no migration, no schema change, no frontend change.

**Plan:** docs/superpowers/plans/2026-08-13-kanban-task-session-name-match.md
**Branch:** worktree/kanban-task-session-name-match
**Task:** task_1786626864861