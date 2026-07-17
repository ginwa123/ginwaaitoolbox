# Refactor Frontend Components Folder — Design

**Date:** 2026-07-17
**Status:** Approved (user-approved 2026-07-17, pending implementation plan)
**Target:** `src/apps/desktop/src/components/` (Vue 3 frontend)
**Scope:** Pure folder reorganization. No file splits, no renames, no behavior changes.

---

## 1. Problem

`src/apps/desktop/src/components/` currently contains **67 `.vue` files flat at root** — every component in the nalar Vue app sits at the same directory level, including:

- 8 top-level "view" components (`ChatView.vue`, `ChatsList.vue`, `Chats.vue`, `CodeEditor.vue`, `SettingsView.vue`, `WorkspaceItemMemoriesView.vue`, `KanbanView.vue`, `DesignView.vue`, `LocalMemoryDetailView.vue`)
- 4 shell components (`AppLayout.vue`, `Sidebar.vue`, `NotificationContainer.vue`, `SseStatusBadge.vue`)
- ~25 generic UI primitives (`Bash.vue`, `Glob.vue`, `FileInput.vue`, `FilePreview.vue`, `FolderExplorer.vue`, `GitChanges.vue`, `GitFileViewer.vue`, `WorkspaceItem.vue`, `WorkspaceItemTaskCard.vue`, …)
- ~15 modal dialogs (`AddItemDialog.vue`, `ConfirmDialog.vue`, `CreatePrDialog.vue`, …)
- kanban / design / memory feature widgets

This makes the components folder hard to scan: a developer adding a new kanban column can't tell at a glance whether it belongs alongside the other kanban files or in the generic UI bucket. The flat listing also buries "what does this app contain?" answers in a 67-item `ls`.

Two partial reorgs already exist:
- `components/nalar/` (14 files: LLM config, profiles, sub-agents) — well-organized
- `components/tool_outputs/` (21 files + `_shared/` + `__tests__/`) — well-organized

These demonstrate the project's intended direction (domain-grouped subdirs) but left the rest of the components flat.

---

## 2. Goal

Reorganize the 67 flat components into **domain-grouped subdirs** so:
1. A new contributor can answer "where does my new X go?" by reading the folder names
2. The existing `components/nalar/` and `components/tool_outputs/` conventions are extended, not replaced
3. **Zero behavior changes** — only the on-disk layout and import paths

---

## 3. Proposed Layout

`src/apps/desktop/src/components/` after refactor:

```
components/
├── AppLayout.vue                          # stays at root (entry for every /app/* route)
│
├── shell/                                 # app chrome (always visible around views)
│   ├── Sidebar.vue
│   ├── NotificationContainer.vue
│   ├── SseStatusBadge.vue
│   ├── RightSidebar.vue                   # disabled in AppLayout (per task disable-rightsidebar-vue)
│   ├── RightSideBarSkillList.vue
│   └── SkillDetail.vue
│
├── views/                                 # top-level routed views (AppLayout renders one of these)
│   ├── ChatView.vue
│   ├── Chats.vue
│   ├── ChatsList.vue
│   ├── CodeEditor.vue
│   ├── SettingsView.vue
│   ├── WorkspaceItemMemoriesView.vue
│   └── LocalMemoryDetailView.vue
│                                          # (KanbanView and DesignView live in their feature folders)
│
├── kanban/                                # all kanban-feature components
│   ├── KanbanView.vue                     # the kanban view (top-level page)
│   ├── KanbanColumn.vue
│   ├── KanbanCard.vue
│   ├── KanbanColumnEditor.vue
│   ├── KanbanSettingsDialog.vue
│   └── KanbanTaskDetailDialog.vue
│
├── design/                                # all design-mode components
│   ├── DesignView.vue                     # the design view (top-level page)
│   ├── DesignElement.vue
│   ├── DesignElementPreview.vue
│   ├── DesignPageTabs.vue
│   ├── PropertiesPanel.vue
│   ├── LayersPanel.vue
│   ├── AddDesignDialog.vue
│   └── AddDesignElementDialog.vue
│
├── memory/                                # memory-feature bits
│   ├── MemoryDetail.vue
│   └── MemoriesSettings.vue
│
├── dialogs/                               # generic modal dialogs
│   ├── AddItemDialog.vue
│   ├── AddTaskDialog.vue
│   ├── AddTaskPickerDialog.vue
│   ├── AddMemoryDialog.vue
│   ├── AddKanbanDialog.vue
│   ├── AddRoutineDialog.vue
│   ├── EditRoutineDialog.vue
│   ├── CreatePrDialog.vue
│   ├── CreateWorktreeDialog.vue
│   ├── CopyKanbanSpecDialog.vue
│   ├── ConfirmDialog.vue
│   ├── RenameTaskModal.vue
│   ├── RenameWorkspaceModal.vue
│   └── WorkspaceModal.vue
│
├── git/                                   # git-integration widgets
│   ├── GitChanges.vue
│   └── GitFileViewer.vue
│
├── file/                                  # file-system widgets
│   ├── FileInput.vue
│   ├── FilePreview.vue
│   └── FolderExplorer.vue
│
├── preview/                               # preview / inline-display widgets
│   ├── Bash.vue
│   ├── Glob.vue
│   ├── PreviewSidePanel.vue
│   ├── ImagePreview.vue
│   ├── InlineEditableText.vue
│   ├── CompactionCard.vue
│   ├── ErrorNotification.vue
│   ├── GetSkill.vue
│   ├── SkillsPopup.vue
│   ├── SkillsSettings.vue
│   └── UpdateActivity.vue
│
├── workspace/                             # sidebar/list workspace-item primitives
│   ├── WorkspaceItem.vue
│   ├── WorkspaceItemTaskCard.vue
│   ├── WorkspaceItemTaskRow.vue
│   ├── WorkspaceList.vue
│   └── WorktreeMenu.vue
│
├── nalar/                                 # EXISTING — LLM config / profiles / sub-agents (unchanged)
│   └── …
│
└── tool_outputs/                          # EXISTING — tool result renderers (unchanged)
    └── …
```

**Total:** 11 new subdirs + 2 existing (`nalar/`, `tool_outputs/`) = 13 subdirs total.

---

## 4. Classification Rationale

Each subdir is a coherent feature/concern with one obvious purpose:

| Bucket | Purpose | Count |
|---|---|---|
| `shell/` | App chrome — what's always rendered around the active view | 6 |
| `views/` | Top-level routed pages that aren't tied to one feature | 7 |
| `kanban/` | Everything kanban (view + sub-widgets + dialogs) | 6 |
| `design/` | Everything design-mode | 8 |
| `memory/` | Local-memory feature | 2 |
| `dialogs/` | Modal dialogs not tied to a single feature | 14 |
| `git/` | Git integration widgets | 2 |
| `file/` | File-system browser widgets | 3 |
| `preview/` | Inline-display widgets (chat-message output previews) | 11 |
| `workspace/` | Sidebar / list workspace-item primitives | 5 |
| `nalar/` | (existing) LLM config / profiles / sub-agents | 14 |
| `tool_outputs/` | (existing) tool-result renderers | 21 |
| **Total .vue** | | **99** |

---

## 5. What Doesn't Move

- **`AppLayout.vue`** stays at `components/AppLayout.vue` — every `/app/*` route imports it by relative path; it's the natural entry point.
- **`components/nalar/`** stays as-is (already organized).
- **`components/tool_outputs/`** stays as-is (already organized; has its own `__tests__/` next to it).
- **All test files** stay where they are:
  - `src/apps/desktop/src/__tests__/` (117 files, flat top-level) — **untouched**
  - `src/apps/desktop/src/composables/__tests__/` — **untouched**
  - `src/apps/desktop/src/helpers/__tests__/` — **untouched**
  - `src/apps/desktop/src/components/tool_outputs/__tests__/` — **untouched**
- **No file content changes** — only `<script setup>` import paths.

---

## 6. Import-Path Rewriting

Every moved component is referenced from:
- The script of another `.vue` file: `import Foo from './Foo.vue'` → `import Foo from './<bucket>/Foo.vue'`
- (Optionally) `composables/`, `stores/`, `helpers/` — fewer references

Total rewrites (estimate): **~80 import lines across ~50 files**. Mechanical, codemod-friendly:

```bash
# Example: rewrite a single bucket (repeat per bucket)
cd src/apps/desktop/src
rg -l "from ['\"][^./]*Sidebar\.vue['\"]" --type vue
# → for each match, sed-replace `Sidebar.vue` → `shell/Sidebar.vue`
```

For every rewritable file, the new path is unambiguous (every component name is unique within `components/`, so the sed mapping is a single global replace per name → bucket).

---

## 7. Verification

After all moves:

1. **Type-check:** `bun run build` passes (vue-tsc validates every import).
2. **Tests:** `bunx vitest run` reports `126 passed` (baseline) — no new failures.
3. **No orphans:** `ls src/apps/desktop/src/components/*.vue` returns only `AppLayout.vue`.
4. **No broken imports:** `rg "from ['\"][^'\"]*components/[^/'\"]+\.vue['\"]" src/apps/desktop/src/` returns zero matches (every component import now has at least one `/` after `components/`).
5. **Visual smoke test:** `bun run build` then `bun run dev` → open the app, navigate to each route, confirm the page renders (regression catch for any missed path).

---

## 8. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Sed script miss-renames a path (typo in bucket mapping) | Compile-check step (`bun run build`) catches every broken path before any human sees it. |
| A `.vue` file imports a sibling by relative path that breaks after the move (e.g. `./Foo.vue` from a file now at `./dialogs/Foo.vue`) | Codemod handles the `from './X.vue'` → `from '../X.vue'` form by re-checking each file's new depth. Cross-bucket imports get the new bucket prefix. |
| Path aliases (`@/components/X.vue`) — if used, they all need rewriting too | The codebase uses **relative paths** for component imports (verified: `rg "@/components" src/apps/desktop/src/` shows no matches). All imports are `from './X.vue'` or `from '../components/X.vue'` — both forms are mechanical to rewrite. |
| Bundle size or build time regression | None expected: the bundler doesn't care about folder depth; only import paths matter. |

---

## 9. Out of Scope (Explicit)

- ❌ Moving any test file (user-confirmed)
- ❌ Splitting any large `.vue` file (`AppLayout.vue` is 1837 LOC; `ChatView.vue` is 3500+ LOC — both stay monolithic)
- ❌ Renaming any `.vue` file
- ❌ Refactoring internals of `components/nalar/` or `components/tool_outputs/`
- ❌ Reorganizing the top-level `__tests__/` folder
- ❌ Moving `components/__tests__/`-style test files into per-bucket subdirs (the project already has mixed conventions here; leaving alone for now)

---

## 10. Implementation Plan

Will be written by the `writing-plans` skill in a separate file at `docs/superpowers/plans/2026-07-17-refactor-frontend-components-folder.md` after this design is approved.

Expected plan structure:

1. **Setup:** verify baseline (126 tests pass), check git status clean.
2. **Bucket 1 (shell/):** create dir, `git mv` 6 files, rewrite imports, verify.
3. **Bucket 2 (views/):** same pattern, 7 files.
4. **Bucket 3 (kanban/):** 6 files including the view.
5. **Bucket 4 (design/):** 8 files including the view.
6. **Bucket 5 (memory/):** 2 files.
7. **Bucket 6 (dialogs/):** 14 files (the largest batch).
8. **Bucket 7 (git/):** 2 files.
9. **Bucket 8 (file/):** 3 files.
10. **Bucket 9 (preview/):** 11 files.
11. **Bucket 10 (workspace/):** 5 files.
12. **Final:** full verification — `bun run build`, `bunx vitest run`, `bun run dev` smoke test.

Each bucket is a self-contained commit (one logical change per commit, easy to revert). Estimated commits: 11. Estimated time: 1-2 hours including verification.

---

## 11. References

- Existing partial reorgs to extend:
  - `components/nalar/` (14 files) — LLM config feature
  - `components/tool_outputs/` (21 files + `_shared/` + `__tests__/`) — tool result renderers
- Router (single shallow layer): `src/apps/desktop/src/router/index.ts` — every `/app/*` route mounts `AppLayout.vue`.
- `AppLayout.vue` (1837 LOC) — top-level shell, imports each view to render based on route params.
- Baseline tests: `bunx vitest run` → 126 files / 1327 tests / ~13s / 0 failures.
- Project conventions:
  - `docs/plans/` for design docs (this file)
  - `docs/superpowers/plans/` for implementation plans
  - Worktrees in `.worktrees/<branch>/` (auto-ignored)