# Kanban Create-Task Message Format + Git-Worktree Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the user message stored in `llm_history` on kanban task create to the `Task :` / `Description:` format, and add a "use git worktree" toggle next to unattended mode that appends `#Notes UseGitWorktree`.

**Architecture:** Frontend-only (per user direction — no backend changes). A small pure-TS formatter builds the new message for the `create_and_run` path (`queue_message` passes through the backend verbatim); the dialog gains a worktree checkbox below the unattended toggle. `create_session` (plain Create) is deliberately untouched: its message is composed server-side from `name`/`description`, and `description` also feeds the card display, so reformatting it frontend-side would pollute the card.

**Tech Stack:** Zig 0.16 backend (`kanban_tasks_create.zig`), Vue 3 + Pinia frontend (`KanbanTaskDetailDialog.vue`, `KanbanView.vue`, `stores/workspaces.ts`, `api/index.ts`), SQLite `llm_history`, existing `set_git_worktree` agent tool.

## Global Constraints

- FRONTEND-ONLY: no backend changes — no endpoint, wire-field, migration, schema, SSE, or prompt-rule edits.
- No new wire field needed: the toggle state never leaves the frontend; it is baked into `queue_message`, which the backend passes through verbatim (`kanban_tasks_create.zig:241,270-283`).
- Scope limit (accepted): exact new format applies to `create_and_run` only. `create_session` keeps today's `name + "\n\n" + description` server composition (changing it frontend-side would pollute the kanban card, which shares the `description` field).
- `DONT KILL THE PORT 8081 SERVER` — functional tests use the harness (ports 8080..8199 excl. 8081), never a live server + curl.

## Message format contract (`create_and_run` only)

`__TaskWhen__Create` was a placeholder for the task name (confirmed Q0). Real format:

```
Task : <task name>
Description: <description>        <- OMIT this line entirely when description is empty/whitespace
                                     <- blank line +
#Notes UseGitWorktree              <- ONLY when toggle ON (confirmed Q1: plain note text is enough, the agent creates the worktree itself — no prompt rule needed, Task 5 dropped)
```

Examples:
- Name only, toggle off: `Task : __TaskWhen__Create`
- Name + desc, toggle off: `Task : __TaskWhen__Create\nDescription: blablabla`
- Name + desc, toggle on: `Task : __TaskWhen__Create\nDescription: blablabla\n\n#Notes UseGitWorktree`
- Name only, toggle on: `Task : __TaskWhen__Create\n\n#Notes UseGitWorktree`

## Files to touch (frontend only)

| # | File | Change |
|---|------|--------|
| 1 | `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | Worktree checkbox below unattended section (~L1557-1598), state + both emits |
| 2 | `src/apps/desktop/src/components/kanban/KanbanView.vue` | `queue_message` builder (:1029-1034) uses new formatter for `create_and_run` |
| 3 | (NEW or co-located) formatter helper + spec, e.g. `buildTaskCreateMessage(name?, description, useGitWorktree)` | Pure function + vitest |
| 4 | `tests/functional/kanban_task_create_message_format_test.py` (NEW) | Wire-level verification via harness |

NOT touched: `src/http_handlers/kanban_tasks_create.zig`, `stores/workspaces.ts`, `api/index.ts` (no new wire field — flag is baked into `queue_message`), agent prompt files.

## Open questions — RESOLVED (user, 2026-09-11)

- [x] Q0: `__TaskWhen__Create` was a placeholder for the task name. Format uses `Task : <name>`.
- [x] Q1: No backend prompt rule — the plain `#Notes UseGitWorktree` note text is enough; the agent creates the worktree itself. Task 5 dropped.

## Tasks (frontend only)

### Task 1 — Formatter helper + unit tests

- [ ] Write failing vitest for `buildTaskCreateMessage(description, useGitWorktree)`: empty desc omits `Description` line; with-desc includes it; toggle on appends `\n\n#Notes UseGitWorktree`; toggle off does not.
- [ ] Run it, confirm it fails (helper does not exist yet).
- [ ] Implement the pure helper (trim description; empty → omit line).
- [ ] Vitest green.
- [ ] Commit.

### Task 2 — Dialog toggle UI

- [ ] Add `useGitWorktree` checkbox below the unattended section (`KanbanTaskDetailDialog.vue` ~L1557-1598, new `data-testid=kanban-task-detail-use-git-worktree`), default OFF.
- [ ] Include the flag in both `create` and `create-and-run` emits (the `create` path ignores it — documented scope limit; no backend to receive it).
- [ ] Vitest: toggle defaults off; toggling on flows into the emitted payload; existing unattended tests still pass.
- [ ] Commit.

### Task 3 — `KanbanView.vue` builder uses the formatter

- [ ] Replace the `:1029-1034` builder (`name + "\n\n" + description`) with the helper for `mode === 'create_and_run'`.
- [ ] `create_session` path untouched (no `queue_message` — spec asserts this).
- [ ] Commit.

### Task 4 — Functional verification (wire-level, harness only)

- [ ] NEW `tests/functional/kanban_task_create_message_format_test.py` driving the real frontend wire body (`queue_message` preformatted): (a) name-only → exactly `Task : __TaskWhen__Create`; (b) with description → two-line form; (c) toggle on → `+ "\n\n#Notes UseGitWorktree"`; (d) `create_session` regression — old server composition unchanged.
- [ ] Run with `PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/kanban_task_create_message_format_test.py -v`, all pass.
- [ ] Relevant `pnpm test:unit` green.
- [ ] Commit.

### Task 5 — DROPPED (per Q1: no backend prompt rule; the note text suffices)

- [ ] Needs user approval: a short system-prompt rule (`MemoryToolRule` precedent) telling the agent that `#Notes UseGitWorktree` means "call `set_git_worktree` before any file work". Without this, the note is inert text the agent may ignore.
- [ ] If approved: implement + static-contract test + commit. If not: drop this task.

## Verification

- [ ] Plan saved here (`docs/superpowers/plans/2026-09-11-kanban-create-task-message-format-worktree-toggle.md`)
- [ ] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] User has reviewed the plan before execution begins
