# Add Task Routines — Chunks 5-7: Frontend (Index)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Vue 3 + TypeScript frontend pieces for the Task Routines feature: extend the `Task` interface and `api/index.ts` to carry routine metadata, build the picker / add / edit dialogs, and wire `WorkspaceItemTask.vue` + `Sidebar.vue` to the new flow.

**Architecture:** The frontend mirrors the backend's two-task-type model. Standard tasks are unchanged; routine tasks carry an inline `routine: RoutineMeta` object describing schedule, initial prompt, run state. A new `AddTaskPickerDialog` sits between the green `+` button and the existing `AddTaskDialog`; the `AddRoutineDialog` / `EditRoutineDialog` are full forms with preset schedule chips + a custom cron input. `WorkspaceItemTask.vue` branches on `task.task_type`: routine rows render a clock icon, a "Run now" button, a status dot, and a tooltip. `Sidebar.vue` replaces the fast-path `handleAddTask` with the picker → dialog flow.

**Tech Stack:** Vue 3 (`<script setup lang="ts">`), TypeScript, Pinia, Vitest + @vue/test-utils + jsdom, `vue-tsc` (type-check via `bun run build`).

**Spec:** [`docs/plans/2026-06-13-add-task-routines-design.md`](../plans/2026-06-13-add-task-routines-design.md) (Sections: "Frontend UX", "Frontend state management", "API surface").
**Parent plan:** [`docs/superpowers/plans/2026-06-13-add-task-routines.md`](2026-06-13-add-task-routines.md) (Chunk 1 is the backend data model + cron parser; Chunks 2-4 are backend fire / scheduler / HTTP).

---

## File map (frontend portion of this plan)

| File | Purpose |
|---|---|
| `docs/superpowers/plans/2026-06-13-add-task-routines-chunks-5-7.md` | This index file. |
| `docs/superpowers/plans/2026-06-13-add-task-routines-chunks-5.md` | **Chunk 5**: Frontend types & API client. `Task` interface gains `task_type` + `routine`; `api/index.ts` extended; `runRoutine` / `updateRoutine` actions. |
| `docs/superpowers/plans/2026-06-13-add-task-routines-chunks-6.md` | **Chunk 6 (components)**: Frontend dialogs. `AddTaskPickerDialog`, `AddRoutineDialog`, `EditRoutineDialog`, wire `AddTaskDialog` for standard. (Tasks 6.1-6.4) |
| `docs/superpowers/plans/2026-06-13-add-task-routines-chunks-6-tests.md` | **Chunk 6 (tests)**: Spec files for the three dialogs. (Tasks 6.5-6.7) |
| `docs/superpowers/plans/2026-06-13-add-task-routines-chunks-7.md` | **Chunk 7**: Frontend integration. `WorkspaceItemTask` routine rendering, `Sidebar` picker flow, E2E. |

---

## Cross-references

- **Existing component style reference:** `src/apps/desktop/src/components/AddTaskDialog.vue` (modal pattern, Teleport + Transition + backdrop + `var(--semantic-card-bg)` / `var(--color-border)` styling). Reuse the same wrapper verbatim for all three new dialogs.
- **Existing prefilled-dialog reference:** `src/apps/desktop/src/components/RenameTaskModal.vue` (the `currentName` prop + reset-on-open `watch` + Enter-to-submit pattern). Reuse for `EditRoutineDialog`.
- **Existing row-layout reference:** `src/apps/desktop/src/components/WorkspaceItemTask.vue` (the existing bullet / spinner / hover-buttons / `stopPropagation` pattern). Add clock icon + Run Now + status dot in the same row.
- **Existing store-action style reference:** `src/apps/desktop/src/stores/workspaces.ts` (the optimistic-update + rollback pattern in `renameTask` / `deleteTask`, plus the SSE subscription in `subscribeToSessionEvents`).
- **Existing api-style reference:** `src/apps/desktop/src/api/index.ts:180-272` (`getTasks` / `createTask` / `updateTask` / `updateTaskSimple` / `deleteTask`).
- **Existing picker-style reference:** `src/apps/desktop/src/components/AddItemDialog.vue` (the folder-picker modal — same backdrop / Transition / `var(--color-aqua)` selected styling that the new picker cards use).

---

## Conventions (frontend)

1. **TDD always.** Every task writes a failing test first, then implements, then commits. Frontend tasks add a `bun run build` type-check after the test passes.
2. **`bun run build` is the type-check.** Per project memory, `vue-tsc` only runs in `bun run build`, not in `bunx vitest run`. The plan calls out the type-check explicitly because TS-strict errors (TS2532 etc.) don't surface in vitest's runtime-only pass.
3. **No refactoring.** The plan surgically modifies existing files (`AddTaskDialog.vue`, `Sidebar.vue`, `WorkspaceItemTask.vue`, `stores/workspaces.ts`, `api/index.ts`). It does not refactor unrelated code.
4. **Defensive test fixtures.** The store's `init()` calls `getWorkspaces` / `getWorkspacesItems` / `getTasks`. Tests that drive individual actions seed the store directly OR mock those three functions defensively, matching the pattern in `workspacesStoreRenameTask.spec.ts:32-35`.
5. **Modal style match.** The three new dialogs reuse the exact Teleport / Transition / backdrop / card wrapper from `AddTaskDialog.vue:44-143` so the visual language stays consistent.

---

## Type-check + verification sequence (applies to all frontend chunks)

After each task's TDD loop:

```bash
cd src/apps/desktop
# 1. Run only the new/modified spec file
timeout 120 bunx vitest run src/__tests__/<spec-file>.spec.ts 2>&1 | tail -n 30
# 2. Authoritative type-check (vue-tsc --build)
timeout 120 bun run build 2>&1 | tail -n 20
```

A task is "done" when both commands exit clean. Per project memory, `bun run build` is the only authoritative type-check; `bun run build-only` skips it and is forbidden.

At the end of Chunks 5-7:

```bash
cd src/apps/desktop
# 3. Full unit-test suite (catch regressions in unrelated tests)
timeout 180 bunx vitest run 2>&1 | tail -n 20
# 4. Full type-check + bundle
timeout 180 bun run build 2>&1 | tail -n 20
```

---

*See `chunks-5.md`, `chunks-6.md` (components), `chunks-6-tests.md` (dialog spec files), and `chunks-7.md` for the per-chunk task breakdown.*
