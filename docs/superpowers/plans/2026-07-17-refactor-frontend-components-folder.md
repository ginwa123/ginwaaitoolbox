# Refactor Frontend Components Folder — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move 67 flat `.vue` files in `src/apps/desktop/src/components/` into 10 domain-grouped subdirs, updating all import paths. Zero behavior changes.

**Architecture:** Each bucket is one `git mv` batch + one codemod pass to update every importer's path. After each bucket, run `bun run build` to confirm the type-check still passes. The test suite (126 files / 1327 tests) is the regression catch — pure refactor, so all tests should stay green throughout.

**Tech Stack:** Vue 3 + TypeScript + Vite + vue-tsc + Vitest + Bun.

**Design doc:** `docs/plans/2026-07-17-refactor-frontend-components-folder-design.md`

**Worktree:** `.worktrees/refactor-components-folder` on branch `worktree/refactor-components-folder`. All commands below are run from this worktree root unless otherwise noted.

---

## Codemod Helper (use for every bucket)

The same shell pattern is reused for every bucket. Define it once as a documented snippet in your shell notes; don't re-derive it.

For each `Foo.vue` moving from `components/Foo.vue` to `components/<bucket>/Foo.vue`:

```bash
# 1. Find every file that imports the moved file by relative path
rg -l --type-add 'vue:*.vue' --type vue -l "from ['\"]\\./Foo\\.vue['\"]" src/apps/desktop/src/

# 2. Rewrite each match's import to the new path (preserves the quote style)
#    .vue files use single quotes almost exclusively; verify with rg first:
rg "from ['\"]\\./Foo\\.vue['\"]" src/apps/desktop/src/ | head -n 5
#    If all single quotes, the sed below is correct. Adjust if mixed.
```

Two import-path patterns need rewriting depending on the importer's depth:

| Importer location (after move) | Original | Rewritten |
|---|---|---|
| Stays at `components/AppLayout.vue` | `from './Foo.vue'` | `from './<bucket>/Foo.vue'` |
| Moves to `components/<bucket>/X.vue` (same bucket) | `from './Foo.vue'` | `from './Foo.vue'` (UNCHANGED — same dir) |
| Moves to `components/<other>/X.vue` (different bucket) | `from './Foo.vue'` | `from '../<bucket>/Foo.vue'` |

**Critical:** every importer stays in its ORIGINAL position during the move step, then moves in its own bucket's task. So during the `<bucket>` task, the importer is still at `components/<other-bucket>/X.vue` if `<other-bucket>` was processed before. If `<other-bucket>` hasn't been processed yet, the importer is still at `components/X.vue` (flat).

The codemod therefore needs to handle THREE rewrite targets per moved file:

```bash
# Find every importer of Foo.vue, wherever it lives in src/apps/desktop/src/
IMPORTERS=$(rg -l --type-add 'vue:*.vue' --type vue -l \
    "from ['\"]\\./Foo\\.vue['\"]" src/apps/desktop/src/)

# For each importer, compute its CURRENT path and rewrite correctly
for imp in $IMPORTERS; do
    IMP_DIR=$(dirname "$imp")
    IMP_NAME=$(basename "$imp")
    # The new path is: relative-from-importer to components/<bucket>/Foo.vue
    #   - if imp is in components/<bucket>/, the path is "./Foo.vue" (unchanged)
    #   - if imp is in components/X/, the path is "../<bucket>/Foo.vue"
    #   - if imp is in components/AppLayout.vue (root), the path is "./<bucket>/Foo.vue"
    case "$IMP_DIR" in
        src/apps/desktop/src/components/<bucket>)
            NEW_PATH="./Foo.vue" ;;   # unchanged
        src/apps/desktop/src/components)
            NEW_PATH="./<bucket>/Foo.vue" ;;   # from root
        src/apps/desktop/src/components/*)
            NEW_PATH="../<bucket>/Foo.vue" ;;   # from sibling bucket
        src/apps/desktop/src/composables|src/apps/desktop/src/helpers|src/apps/desktop/src/stores|src/apps/desktop/src/__tests__|src/apps/desktop/src/api)
            NEW_PATH="../../components/<bucket>/Foo.vue" ;;   # from sibling src dir
        *)
            echo "UNHANDLED IMPORTER DIR: $IMP_DIR" >&2; exit 1 ;;
    esac
    sed -i "s|from '\\./Foo\\.vue'|from '$NEW_PATH'|g" "$imp"
done
```

Replace `Foo` with the moved file's basename and `<bucket>` with the target directory for each iteration. The "same bucket" case is a no-op rewrite.

---

## Chunk 0: Setup & Baseline

### Task 0.1: Verify clean baseline

**Files:** none (verification only)

- [ ] **Step 1: Confirm worktree + clean status**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
git status
```
Expected: "On branch worktree/refactor-components-folder", nothing to commit (only the design-doc commit shows in `git log`).

- [ ] **Step 2: Run the full test suite**

Run:
```bash
cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5
```
Expected: `Test Files 126 passed (126)`, `Tests 1327 passed (1327)`, exit code 0. The trailing `ERR_INVALID_URL` warnings in some tests are intentional negative-path assertions, not failures.

- [ ] **Step 3: Confirm type-check baseline**

Run:
```bash
cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 10
```
Expected: type-check + bundle succeeds, exit code 0. (If this fails on the baseline, fix it before any refactor — the failure would be pre-existing, not caused by this plan.)

- [ ] **Step 4: Commit nothing**

This task is verification only — no code changes. Don't commit.

---

## Chunk 1: shell/ (6 files)

### Task 1.1: Move shell components

**Files (move):**
- `src/apps/desktop/src/components/Sidebar.vue` → `src/apps/desktop/src/components/shell/Sidebar.vue`
- `src/apps/desktop/src/components/NotificationContainer.vue` → `src/apps/desktop/src/components/shell/NotificationContainer.vue`
- `src/apps/desktop/src/components/SseStatusBadge.vue` → `src/apps/desktop/src/components/shell/SseStatusBadge.vue`
- `src/apps/desktop/src/components/RightSidebar.vue` → `src/apps/desktop/src/components/shell/RightSidebar.vue`
- `src/apps/desktop/src/components/RightSideBarSkillList.vue` → `src/apps/desktop/src/components/shell/RightSideBarSkillList.vue`
- `src/apps/desktop/src/components/SkillDetail.vue` → `src/apps/desktop/src/components/shell/SkillDetail.vue`

- [ ] **Step 1: Move the files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
mkdir -p src/apps/desktop/src/components/shell
git mv src/apps/desktop/src/components/Sidebar.vue src/apps/desktop/src/components/shell/
git mv src/apps/desktop/src/components/NotificationContainer.vue src/apps/desktop/src/components/shell/
git mv src/apps/desktop/src/components/SseStatusBadge.vue src/apps/desktop/src/components/shell/
git mv src/apps/desktop/src/components/RightSidebar.vue src/apps/desktop/src/components/shell/
git mv src/apps/desktop/src/components/RightSideBarSkillList.vue src/apps/desktop/src/components/shell/
git mv src/apps/desktop/src/components/SkillDetail.vue src/apps/desktop/src/components/shell/
```

Expected: `git status` shows 6 renamed files + 1 new directory.

- [ ] **Step 2: Discover every importer**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in Sidebar.vue NotificationContainer.vue SseStatusBadge.vue RightSidebar.vue RightSideBarSkillList.vue SkillDetail.vue; do
    echo "=== $f ==="
    rg -l --type-add 'vue:*.vue' --type vue -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/
done
```

Expected: `Sidebar.vue` is imported by `src/apps/desktop/src/components/AppLayout.vue`. `NotificationContainer.vue` and `SseStatusBadge.vue` are also imported by `AppLayout.vue`. `RightSidebar.vue`, `RightSideBarSkillList.vue`, `SkillDetail.vue` are currently imported by `AppLayout.vue` (the latter 2 inside a commented-out import block per `disable-rightsidebar-vue` task — read the file to confirm). Other importers (in `components/*.vue`, `__tests__/*`, etc.) may exist — record each.

- [ ] **Step 3: Rewrite import paths**

For each importer found in Step 2, rewrite the import to point at the new shell/ path. Use the codemod helper above; here it is filled in for this batch:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder

# AppLayout.vue lives at components/ — its imports become './shell/X.vue'
sed -i "s|from '\\./Sidebar\\.vue'|from './shell/Sidebar.vue'|g" \
    src/apps/desktop/src/components/AppLayout.vue
sed -i "s|from '\\./NotificationContainer\\.vue'|from './shell/NotificationContainer.vue'|g" \
    src/apps/desktop/src/components/AppLayout.vue
sed -i "s|from '\\./SseStatusBadge\\.vue'|from './shell/SseStatusBadge.vue'|g" \
    src/apps/desktop/src/components/AppLayout.vue
sed -i "s|from '\\./RightSidebar\\.vue'|from './shell/RightSidebar.vue'|g" \
    src/apps/desktop/src/components/AppLayout.vue
sed -i "s|from '\\./RightSideBarSkillList\\.vue'|from './shell/RightSideBarSkillList.vue'|g" \
    src/apps/desktop/src/components/AppLayout.vue
sed -i "s|from '\\./SkillDetail\\.vue'|from './shell/SkillDetail.vue'|g" \
    src/apps/desktop/src/components/AppLayout.vue

# If any other importers were found (in components/* — should be none yet since
# no other buckets are moved), rewrite them to '../shell/X.vue':
#   sed -i "s|from '\\./X\\.vue'|from '../shell/X.vue'|g" <importer path>
```

If a test file or a non-`AppLayout.vue` component imports any of these six files, apply the matching case from the codemod table. As of the design doc, only `AppLayout.vue` imports them.

- [ ] **Step 4: Type-check**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
```
Expected: build succeeds. If a path is wrong, the error will name it (`Cannot find module './shell/X.vue'` or similar) — fix the sed step and re-run.

- [ ] **Step 5: Run tests**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bunx vitest run 2>&1 | tail -n 5
```
Expected: `Test Files 126 passed (126)`, `Tests 1327 passed (1327)`. No new failures.

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
git add -A
git commit -m "refactor(components): move 6 shell components into components/shell/

Moves Sidebar.vue, NotificationContainer.vue, SseStatusBadge.vue,
RightSidebar.vue, RightSideBarSkillList.vue, SkillDetail.vue into
components/shell/. Updates all import paths (currently only
AppLayout.vue). Pure file moves + path rewrites; no behavior changes.

Part of the components-folder reorg (Chunk 1/11)."
```

---

## Chunk 2: views/ (7 files)

### Task 2.1: Move view components

**Files (move):**
- `ChatView.vue`, `Chats.vue`, `ChatsList.vue`, `CodeEditor.vue`, `SettingsView.vue`, `WorkspaceItemMemoriesView.vue`, `LocalMemoryDetailView.vue` → `src/apps/desktop/src/components/views/`

- [ ] **Step 1: Move the files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
mkdir -p src/apps/desktop/src/components/views
git mv src/apps/desktop/src/components/ChatView.vue src/apps/desktop/src/components/views/
git mv src/apps/desktop/src/components/Chats.vue src/apps/desktop/src/components/views/
git mv src/apps/desktop/src/components/ChatsList.vue src/apps/desktop/src/components/views/
git mv src/apps/desktop/src/components/CodeEditor.vue src/apps/desktop/src/components/views/
git mv src/apps/desktop/src/components/SettingsView.vue src/apps/desktop/src/components/views/
git mv src/apps/desktop/src/components/WorkspaceItemMemoriesView.vue src/apps/desktop/src/components/views/
git mv src/apps/desktop/src/components/LocalMemoryDetailView.vue src/apps/desktop/src/components/views/
```

- [ ] **Step 2: Discover every importer**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in ChatView.vue Chats.vue ChatsList.vue CodeEditor.vue SettingsView.vue WorkspaceItemMemoriesView.vue LocalMemoryDetailView.vue; do
    echo "=== $f ==="
    rg -l --type-add 'vue:*.vue' --type vue -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/
done
```

Expected: every view is imported by `src/apps/desktop/src/components/AppLayout.vue`. Some may also be referenced by `App.vue` (router mounting), `__tests__/*.spec.ts`, or `composables/`. Record all.

- [ ] **Step 3: Rewrite import paths**

For each importer:
- `AppLayout.vue` (at `components/`) → `from './views/X.vue'`
- Other `components/X.vue` (a sibling bucket like `shell/`) → `from '../views/X.vue'`
- `__tests__/X.spec.ts` (at `src/__tests__/`) → `from '../../components/views/X.vue'`
- `composables/X.ts` (at `src/composables/`) → `from '../../components/views/X.vue'`

Concrete sed for AppLayout.vue (the bulk of importers):

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in ChatView.vue Chats.vue ChatsList.vue CodeEditor.vue SettingsView.vue WorkspaceItemMemoriesView.vue LocalMemoryDetailView.vue; do
    sed -i "s|from '\\./${f}'|from './views/${f}'|g" \
        src/apps/desktop/src/components/AppLayout.vue
done
```

For any other importers found, write the matching sed per the codemod table.

- [ ] **Step 4: Type-check + test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 5
```
Expected: build OK, 1327 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
git add -A
git commit -m "refactor(components): move 7 top-level views into components/views/

Moves ChatView, Chats, ChatsList, CodeEditor, SettingsView,
WorkspaceItemMemoriesView, LocalMemoryDetailView into components/views/.
Updates all import paths. KanbanView and DesignView stay in their own
feature buckets (kanban/, design/).

Part of the components-folder reorg (Chunk 2/11)."
```

---

## Chunk 3: kanban/ (6 files)

### Task 3.1: Move kanban components

**Files (move):**
- `KanbanView.vue`, `KanbanColumn.vue`, `KanbanCard.vue`, `KanbanColumnEditor.vue`, `KanbanSettingsDialog.vue`, `KanbanTaskDetailDialog.vue` → `src/apps/desktop/src/components/kanban/`

- [ ] **Step 1: Move the files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
mkdir -p src/apps/desktop/src/components/kanban
git mv src/apps/desktop/src/components/KanbanView.vue src/apps/desktop/src/components/kanban/
git mv src/apps/desktop/src/components/KanbanColumn.vue src/apps/desktop/src/components/kanban/
git mv src/apps/desktop/src/components/KanbanCard.vue src/apps/desktop/src/components/kanban/
git mv src/apps/desktop/src/components/KanbanColumnEditor.vue src/apps/desktop/src/components/kanban/
git mv src/apps/desktop/src/components/KanbanSettingsDialog.vue src/apps/desktop/src/components/kanban/
git mv src/apps/desktop/src/components/KanbanTaskDetailDialog.vue src/apps/desktop/src/components/kanban/
```

- [ ] **Step 2: Discover every importer**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in KanbanView.vue KanbanColumn.vue KanbanCard.vue KanbanColumnEditor.vue KanbanSettingsDialog.vue KanbanTaskDetailDialog.vue; do
    echo "=== $f ==="
    rg -l --type-add 'vue:*.vue' --type vue -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/
done
```

Expected: `KanbanView` imported by `AppLayout.vue` (at `components/`) and many of its peers by other `components/*.vue` files (still flat). Record all.

- [ ] **Step 3: Rewrite import paths**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder

# AppLayout.vue → './kanban/X.vue'
for f in KanbanView.vue; do
    sed -i "s|from '\\./${f}'|from './kanban/${f}'|g" \
        src/apps/desktop/src/components/AppLayout.vue
done

# All other flat components/*.vue that import any of the 6 (still in components/ root)
# → '../kanban/X.vue'
for f in KanbanColumn.vue KanbanCard.vue KanbanColumnEditor.vue KanbanSettingsDialog.vue KanbanTaskDetailDialog.vue; do
    # Find every importer at components/*.vue (root, not in a subdir)
    for imp in $(rg -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/components/ --type vue); do
        # Skip if it's already in kanban/ (won't happen on this batch but safe)
        if [[ "$imp" != src/apps/desktop/src/components/kanban/* ]]; then
            sed -i "s|from '\\./${f}'|from '../kanban/${f}'|g" "$imp"
        fi
    done
done
```

- [ ] **Step 4: Type-check + test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 5
```
Expected: build OK, 1327 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
git add -A
git commit -m "refactor(components): move 6 kanban components into components/kanban/

Moves KanbanView, KanbanColumn, KanbanCard, KanbanColumnEditor,
KanbanSettingsDialog, KanbanTaskDetailDialog into components/kanban/.
Updates all import paths.

Part of the components-folder reorg (Chunk 3/11)."
```

---

## Chunk 4: design/ (8 files)

### Task 4.1: Move design components

**Files (move):**
- `DesignView.vue`, `DesignElement.vue`, `DesignElementPreview.vue`, `DesignPageTabs.vue`, `PropertiesPanel.vue`, `LayersPanel.vue`, `AddDesignDialog.vue`, `AddDesignElementDialog.vue` → `src/apps/desktop/src/components/design/`

- [ ] **Step 1: Move the files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
mkdir -p src/apps/desktop/src/components/design
git mv src/apps/desktop/src/components/DesignView.vue src/apps/desktop/src/components/design/
git mv src/apps/desktop/src/components/DesignElement.vue src/apps/desktop/src/components/design/
git mv src/apps/desktop/src/components/DesignElementPreview.vue src/apps/desktop/src/components/design/
git mv src/apps/desktop/src/components/DesignPageTabs.vue src/apps/desktop/src/components/design/
git mv src/apps/desktop/src/components/PropertiesPanel.vue src/apps/desktop/src/components/design/
git mv src/apps/desktop/src/components/LayersPanel.vue src/apps/desktop/src/components/design/
git mv src/apps/desktop/src/components/AddDesignDialog.vue src/apps/desktop/src/components/design/
git mv src/apps/desktop/src/components/AddDesignElementDialog.vue src/apps/desktop/src/components/design/
```

- [ ] **Step 2: Discover every importer**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in DesignView.vue DesignElement.vue DesignElementPreview.vue DesignPageTabs.vue PropertiesPanel.vue LayersPanel.vue AddDesignDialog.vue AddDesignElementDialog.vue; do
    echo "=== $f ==="
    rg -l --type-add 'vue:*.vue' --type vue -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/
done
```

- [ ] **Step 3: Rewrite import paths**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder

# AppLayout.vue → './design/X.vue'
for f in DesignView.vue; do
    sed -i "s|from '\\./${f}'|from './design/${f}'|g" \
        src/apps/desktop/src/components/AppLayout.vue
done

# All other flat components/*.vue → '../design/X.vue'
for f in DesignElement.vue DesignElementPreview.vue DesignPageTabs.vue PropertiesPanel.vue LayersPanel.vue AddDesignDialog.vue AddDesignElementDialog.vue; do
    for imp in $(rg -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/components/ --type vue); do
        if [[ "$imp" != src/apps/desktop/src/components/design/* ]]; then
            sed -i "s|from '\\./${f}'|from '../design/${f}'|g" "$imp"
        fi
    done
done
```

- [ ] **Step 4: Type-check + test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 5
```

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
git add -A
git commit -m "refactor(components): move 8 design-mode components into components/design/

Moves DesignView, DesignElement, DesignElementPreview, DesignPageTabs,
PropertiesPanel, LayersPanel, AddDesignDialog, AddDesignElementDialog
into components/design/. Updates all import paths.

Part of the components-folder reorg (Chunk 4/11)."
```

---

## Chunk 5: memory/ (2 files)

### Task 5.1: Move memory components

**Files (move):**
- `MemoryDetail.vue`, `MemoriesSettings.vue` → `src/apps/desktop/src/components/memory/`

- [ ] **Step 1: Move the files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
mkdir -p src/apps/desktop/src/components/memory
git mv src/apps/desktop/src/components/MemoryDetail.vue src/apps/desktop/src/components/memory/
git mv src/apps/desktop/src/components/MemoriesSettings.vue src/apps/desktop/src/components/memory/
```

- [ ] **Step 2: Discover every importer**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in MemoryDetail.vue MemoriesSettings.vue; do
    rg -l --type-add 'vue:*.vue' --type vue -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/
done
```

- [ ] **Step 3: Rewrite import paths**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in MemoryDetail.vue MemoriesSettings.vue; do
    for imp in $(rg -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/components/ --type vue); do
        if [[ "$imp" != src/apps/desktop/src/components/memory/* ]]; then
            sed -i "s|from '\\./${f}'|from '../memory/${f}'|g" "$imp"
        fi
    done
done
```

- [ ] **Step 4: Type-check + test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 5
```

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
git add -A
git commit -m "refactor(components): move 2 memory components into components/memory/

Moves MemoryDetail.vue, MemoriesSettings.vue into components/memory/.

Part of the components-folder reorg (Chunk 5/11)."
```

---

## Chunk 6: dialogs/ (14 files)

### Task 6.1: Move dialog components

**Files (move):**
- `AddItemDialog.vue`, `AddTaskDialog.vue`, `AddTaskPickerDialog.vue`, `AddMemoryDialog.vue`, `AddKanbanDialog.vue`, `AddRoutineDialog.vue`, `EditRoutineDialog.vue`, `CreatePrDialog.vue`, `CreateWorktreeDialog.vue`, `CopyKanbanSpecDialog.vue`, `ConfirmDialog.vue`, `RenameTaskModal.vue`, `RenameWorkspaceModal.vue`, `WorkspaceModal.vue` → `src/apps/desktop/src/components/dialogs/`

- [ ] **Step 1: Move the files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
mkdir -p src/apps/desktop/src/components/dialogs
for f in AddItemDialog.vue AddTaskDialog.vue AddTaskPickerDialog.vue AddMemoryDialog.vue \
         AddKanbanDialog.vue AddRoutineDialog.vue EditRoutineDialog.vue CreatePrDialog.vue \
         CreateWorktreeDialog.vue CopyKanbanSpecDialog.vue ConfirmDialog.vue \
         RenameTaskModal.vue RenameWorkspaceModal.vue WorkspaceModal.vue; do
    git mv "src/apps/desktop/src/components/${f}" "src/apps/desktop/src/components/dialogs/"
done
```

- [ ] **Step 2: Discover every importer**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in AddItemDialog.vue AddTaskDialog.vue AddTaskPickerDialog.vue AddMemoryDialog.vue \
         AddKanbanDialog.vue AddRoutineDialog.vue EditRoutineDialog.vue CreatePrDialog.vue \
         CreateWorktreeDialog.vue CopyKanbanSpecDialog.vue ConfirmDialog.vue \
         RenameTaskModal.vue RenameWorkspaceModal.vue WorkspaceModal.vue; do
    echo "=== $f ==="
    rg -l --type-add 'vue:*.vue' --type vue -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/
done
```

Expected: many importers — dialogs are widely used inside views (`WorkspaceList.vue` → `AddItemDialog.vue`, `Sidebar.vue` → `ConfirmDialog.vue`, etc.). `Sidebar.vue` was already moved to `shell/Sidebar.vue` in Chunk 1, so its imports need `'../dialogs/X.vue'`.

- [ ] **Step 3: Rewrite import paths**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in AddItemDialog.vue AddTaskDialog.vue AddTaskPickerDialog.vue AddMemoryDialog.vue \
         AddKanbanDialog.vue AddRoutineDialog.vue EditRoutineDialog.vue CreatePrDialog.vue \
         CreateWorktreeDialog.vue CopyKanbanSpecDialog.vue ConfirmDialog.vue \
         RenameTaskModal.vue RenameWorkspaceModal.vue WorkspaceModal.vue; do
    # All importers at components/*.vue (root, not yet moved to another bucket) → '../dialogs/X.vue'
    for imp in $(rg -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/components/ --type vue); do
        if [[ "$imp" != src/apps/desktop/src/components/dialogs/* ]]; then
            sed -i "s|from '\\./${f}'|from '../dialogs/${f}'|g" "$imp"
        fi
    done
done
```

- [ ] **Step 4: Type-check + test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 5
```

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
git add -A
git commit -m "refactor(components): move 14 dialog components into components/dialogs/

Moves Add*/Edit*/Create*/Confirm*/Rename*/WorkspaceModal dialogs
into components/dialogs/. Updates all import paths.

Part of the components-folder reorg (Chunk 6/11)."
```

---

## Chunk 7: git/ (2 files)

### Task 7.1: Move git components

**Files (move):**
- `GitChanges.vue`, `GitFileViewer.vue` → `src/apps/desktop/src/components/git/`

- [ ] **Step 1: Move the files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
mkdir -p src/apps/desktop/src/components/git
git mv src/apps/desktop/src/components/GitChanges.vue src/apps/desktop/src/components/git/
git mv src/apps/desktop/src/components/GitFileViewer.vue src/apps/desktop/src/components/git/
```

- [ ] **Step 2: Discover every importer**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in GitChanges.vue GitFileViewer.vue; do
    rg -l --type-add 'vue:*.vue' --type vue -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/
done
```

- [ ] **Step 3: Rewrite import paths**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in GitChanges.vue GitFileViewer.vue; do
    for imp in $(rg -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/components/ --type vue); do
        if [[ "$imp" != src/apps/desktop/src/components/git/* ]]; then
            sed -i "s|from '\\./${f}'|from '../git/${f}'|g" "$imp"
        fi
    done
done
```

- [ ] **Step 4: Type-check + test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 5
```

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
git add -A
git commit -m "refactor(components): move 2 git widgets into components/git/

Moves GitChanges.vue, GitFileViewer.vue into components/git/.

Part of the components-folder reorg (Chunk 7/11)."
```

---

## Chunk 8: file/ (3 files)

### Task 8.1: Move file components

**Files (move):**
- `FileInput.vue`, `FilePreview.vue`, `FolderExplorer.vue` → `src/apps/desktop/src/components/file/`

- [ ] **Step 1: Move the files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
mkdir -p src/apps/desktop/src/components/file
git mv src/apps/desktop/src/components/FileInput.vue src/apps/desktop/src/components/file/
git mv src/apps/desktop/src/components/FilePreview.vue src/apps/desktop/src/components/file/
git mv src/apps/desktop/src/components/FolderExplorer.vue src/apps/desktop/src/components/file/
```

- [ ] **Step 2: Discover every importer**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in FileInput.vue FilePreview.vue FolderExplorer.vue; do
    rg -l --type-add 'vue:*.vue' --type vue -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/
done
```

- [ ] **Step 3: Rewrite import paths**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in FileInput.vue FilePreview.vue FolderExplorer.vue; do
    for imp in $(rg -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/components/ --type vue); do
        if [[ "$imp" != src/apps/desktop/src/components/file/* ]]; then
            sed -i "s|from '\\./${f}'|from '../file/${f}'|g" "$imp"
        fi
    done
done
```

- [ ] **Step 4: Type-check + test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 5
```

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
git add -A
git commit -m "refactor(components): move 3 file widgets into components/file/

Moves FileInput.vue, FilePreview.vue, FolderExplorer.vue into
components/file/.

Part of the components-folder reorg (Chunk 8/11)."
```

---

## Chunk 9: preview/ (11 files)

### Task 9.1: Move preview components

**Files (move):**
- `Bash.vue`, `Glob.vue`, `PreviewSidePanel.vue`, `ImagePreview.vue`, `InlineEditableText.vue`, `CompactionCard.vue`, `ErrorNotification.vue`, `GetSkill.vue`, `SkillsPopup.vue`, `SkillsSettings.vue`, `UpdateActivity.vue` → `src/apps/desktop/src/components/preview/`

- [ ] **Step 1: Move the files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
mkdir -p src/apps/desktop/src/components/preview
for f in Bash.vue Glob.vue PreviewSidePanel.vue ImagePreview.vue InlineEditableText.vue \
         CompactionCard.vue ErrorNotification.vue GetSkill.vue SkillsPopup.vue \
         SkillsSettings.vue UpdateActivity.vue; do
    git mv "src/apps/desktop/src/components/${f}" "src/apps/desktop/src/components/preview/"
done
```

- [ ] **Step 2: Discover every importer**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in Bash.vue Glob.vue PreviewSidePanel.vue ImagePreview.vue InlineEditableText.vue \
         CompactionCard.vue ErrorNotification.vue GetSkill.vue SkillsPopup.vue \
         SkillsSettings.vue UpdateActivity.vue; do
    echo "=== $f ==="
    rg -l --type-add 'vue:*.vue' --type vue -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/
done
```

Expected: large batch — these are used inside `ChatView.vue` (`Bash.vue`, `Glob.vue`, `CompactionCard.vue`, `PreviewSidePanel.vue`, `ImagePreview.vue`, `InlineEditableText.vue`, `ErrorNotification.vue`) and inside `sidebar` widgets.

- [ ] **Step 3: Rewrite import paths**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in Bash.vue Glob.vue PreviewSidePanel.vue ImagePreview.vue InlineEditableText.vue \
         CompactionCard.vue ErrorNotification.vue GetSkill.vue SkillsPopup.vue \
         SkillsSettings.vue UpdateActivity.vue; do
    for imp in $(rg -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/components/ --type vue); do
        if [[ "$imp" != src/apps/desktop/src/components/preview/* ]]; then
            sed -i "s|from '\\./${f}'|from '../preview/${f}'|g" "$imp"
        fi
    done
done
```

- [ ] **Step 4: Type-check + test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 5
```

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
git add -A
git commit -m "refactor(components): move 11 preview widgets into components/preview/

Moves Bash, Glob, PreviewSidePanel, ImagePreview, InlineEditableText,
CompactionCard, ErrorNotification, GetSkill, SkillsPopup,
SkillsSettings, UpdateActivity into components/preview/.

Part of the components-folder reorg (Chunk 9/11)."
```

---

## Chunk 10: workspace/ (5 files)

### Task 10.1: Move workspace components

**Files (move):**
- `WorkspaceItem.vue`, `WorkspaceItemTaskCard.vue`, `WorkspaceItemTaskRow.vue`, `WorkspaceList.vue`, `WorktreeMenu.vue` → `src/apps/desktop/src/components/workspace/`

- [ ] **Step 1: Move the files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
mkdir -p src/apps/desktop/src/components/workspace
for f in WorkspaceItem.vue WorkspaceItemTaskCard.vue WorkspaceItemTaskRow.vue \
         WorkspaceList.vue WorktreeMenu.vue; do
    git mv "src/apps/desktop/src/components/${f}" "src/apps/desktop/src/components/workspace/"
done
```

- [ ] **Step 2: Discover every importer**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in WorkspaceItem.vue WorkspaceItemTaskCard.vue WorkspaceItemTaskRow.vue \
         WorkspaceList.vue WorktreeMenu.vue; do
    echo "=== $f ==="
    rg -l --type-add 'vue:*.vue' --type vue -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/
done
```

- [ ] **Step 3: Rewrite import paths**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
for f in WorkspaceItem.vue WorkspaceItemTaskCard.vue WorkspaceItemTaskRow.vue \
         WorkspaceList.vue WorktreeMenu.vue; do
    for imp in $(rg -l "from ['\"]\\./${f}['\"]" src/apps/desktop/src/components/ --type vue); do
        if [[ "$imp" != src/apps/desktop/src/components/workspace/* ]]; then
            sed -i "s|from '\\./${f}'|from '../workspace/${f}'|g" "$imp"
        fi
    done
done
```

- [ ] **Step 4: Type-check + test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 5
```

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
git add -A
git commit -m "refactor(components): move 5 workspace primitives into components/workspace/

Moves WorkspaceItem, WorkspaceItemTaskCard, WorkspaceItemTaskRow,
WorkspaceList, WorktreeMenu into components/workspace/.

Part of the components-folder reorg (Chunk 10/11)."
```

---

## Chunk 11: Final Verification

### Task 11.1: Confirm no orphan .vue files at root + no broken imports

- [ ] **Step 1: Confirm only AppLayout.vue remains at components/ root**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
ls src/apps/desktop/src/components/*.vue
```
Expected: exactly one line — `AppLayout.vue`.

- [ ] **Step 2: Confirm zero dangling single-bare-name imports**

Every component import must have at least one `/` after `components/`. A `from './X.vue'` pattern (single-segment after components/) means a missed rewrite.

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder
rg "from ['\"]\\./([A-Z][a-zA-Z]*\\.vue)['\"]" src/apps/desktop/src/components/AppLayout.vue
```
Expected: zero matches (every `<script setup>` import in AppLayout.vue should now point at `./<bucket>/X.vue` or use the comments preserved from disable-rightsidebar-vue). If any match: re-check the corresponding bucket's task; the import wasn't updated.

- [ ] **Step 3: Final type-check + full test run**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 5
```
Expected: build OK, 1327 tests pass.

- [ ] **Step 4: Visual smoke test (optional, recommended)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/refactor-components-folder/src/apps/desktop
timeout 60 bun run dev 2>&1 &
DEV_PID=$!
sleep 15
# In a separate terminal, navigate to /app/, /app/chat/test, /app/settings
# and confirm the page renders. Then kill the dev server.
kill $DEV_PID
```
If a route 500s, check the browser DevTools Network tab for the failing resource path — it'll be a missed rewrite.

- [ ] **Step 5: Final commit (if any cleanup needed)**

If Steps 1-3 surfaced anything, fix it and commit. If everything is green, this task is verification only — no commit.

---

## Summary

| Chunk | Bucket | Files | Commit |
|---|---|---|---|
| 0 | (setup) | 0 | none |
| 1 | shell/ | 6 | one |
| 2 | views/ | 7 | one |
| 3 | kanban/ | 6 | one |
| 4 | design/ | 8 | one |
| 5 | memory/ | 2 | one |
| 6 | dialogs/ | 14 | one |
| 7 | git/ | 2 | one |
| 8 | file/ | 3 | one |
| 9 | preview/ | 11 | one |
| 10 | workspace/ | 5 | one |
| 11 | (verify) | 0 | none |
| **Total** | | **64** moved | **10 commits** |

(Plus `AppLayout.vue` stays at root, and `components/nalar/` + `components/tool_outputs/` untouched — totalling 99 `.vue` files in `components/` after the refactor.)

## Out-of-scope (explicit, do NOT do)

- ❌ Moving any test file (per user)
- ❌ Splitting any large `.vue` file (e.g. `AppLayout.vue` 1837 LOC stays monolithic)
- ❌ Renaming any file
- ❌ Reorganizing `components/nalar/` or `components/tool_outputs/`
- ❌ Reorganizing `__tests__/`, `composables/__tests__/`, `helpers/__tests__/`, `components/tool_outputs/__tests__/`
- ❌ Editing any non-import line of any `.vue` file

## Pitfalls (lessons from Chunk 1, `3efe641c`)

These pitfalls are confirmed by the Chunk 1 implementer. Every chunk will hit at least #1 and #3.

1. **`git mv` is required, not `mv`** — preserves rename detection in `git log --follow` and gives a cleaner diff.
2. **Each bucket's importers are NOT just `AppLayout.vue`** — Chunk 1 found 5 importers (one extra in `components/SkillsSettings.vue`, the commented-out `RightSidebar` in AppLayout, the sibling in `shell/RightSidebar.vue`, plus 3 test files). **Always run the discovery step broadly** — every chunk will have more importers than the plan anticipated. The implementer for Chunk 1 also rewrote the `// DISABLED: import RightSidebar` commented-out line in AppLayout.vue (per the plan's instruction); preserve any DISABLED/commented imports and update them.
3. **Internal relative paths inside the moved files break** — Chunk 1 found 5 distinct broken paths. `'../api'`, `'../stores/*'`, `'../helpers/*'`, `'./<SiblingAtComponentsRoot>.vue'` all need updating because the moved file is now 1 level deeper. The fix:
   - `'../api'` → `'../../api'`
   - `'../stores/X'` → `'../../stores/X'`
   - `'../helpers/X'` → `'../../helpers/X'`
   - `'./X.vue'` (where X is still at `components/` root) → `'../X.vue'`
   - `'./X.vue'` (where X is in the SAME new subdir) → unchanged
   - `'./X.vue'` (where X is in a DIFFERENT new subdir) → `'../<other-bucket>/X.vue'`
   The `bun run build` step is the safety net — it will fail with `[UNRESOLVED_IMPORT]` for any missed path. Iterate sed → build until clean.
4. **Test files have non-`import` path strings too** — Chunk 1 found 3 test files with stale paths: a regex literal (`./AddDesignDialog.vue` in a `toMatch` regex), a `fs.readFileSync` arg, and a `path.resolve` arg. After the move these all need rewriting. Search broadly:
   ```bash
   rg -l "${MOVED_BASENAME}" src/apps/desktop/src/__tests__/ src/apps/desktop/src/composables/ src/apps/desktop/src/stores/ src/apps/desktop/src/helpers/
   ```
   Any match is a candidate — examine and rewrite. These are NOT test-logic changes, just path-string updates.
5. **Quote styles in imports** — the sed patterns assume single quotes (the codebase convention). If `rg` shows mixed quote styles, expand the sed to handle both.
6. **TypeScript files (`composables/*.ts`, `stores/*.ts`)** may also import `.vue` files (e.g. `defineComponent` returns). Search `rg "from ['\"]\\./X\\.vue['\"]"` in those dirs; rewrite to `'../components/<bucket>/X.vue'`.
7. **Stale comments referencing old paths** — Chunk 1 caught one in `PreviewSidePanel.vue:11` (a `// (src/apps/desktop/src/components/RightSidebar.vue:20-64)` reference). Optional cleanup: search for the old path string anywhere in the source and decide case-by-case.

---

**Plan complete and saved to `docs/superpowers/plans/2026-07-17-refactor-frontend-components-folder.md`. Ready to execute?**