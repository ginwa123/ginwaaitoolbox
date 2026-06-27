# Add "Create worktree" Option to WorktreeMenu Dropdown

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third menu item — **"Create worktree"** — to the `WorktreeMenu` dropdown's `hasWorktree=false` branch (the branch that currently shows only "Open in folder" and "Refresh status"). Clicking it opens a small modal where the user types a short name (e.g. `auth-fix`); on submit the frontend sends a system message to the LLM asking it to call `set_git_worktree(path=...)`. The LLM runs the existing `set_git_worktree` tool, which creates the worktree, persists `sessions.git_worktree_cwd`, and emits the SSE event that flips the status bar to the worktree-bound view. No new backend code, no new agent tool — this plan re-uses the existing `set_git_worktree` tool path end-to-end.

**Architecture:**
- **Frontend only.** One new Vue component (`CreateWorktreeDialog.vue`), 2 new emits on `WorktreeMenu.vue`, 1 new handler in `ChatView.vue` that calls the existing `api.sendChatMessage(...)` (same pattern as the existing `onWorktreeMenuClear` at `ChatView.vue:602-620`). Zero backend changes.
- **LLM-mediated action.** Mirrors `onWorktreeMenuClear` exactly. The frontend does NOT call any new HTTP endpoint — it sends a system-style message to `/api/llm/session` (the same route the chat uses), the LLM processes it, calls `set_git_worktree`, and the SSE event updates the UI. This keeps the worktree creation path singular (tool handles validation, persistence, worktree-add subprocess, error XML) and avoids drift between the LLM-driven and UI-driven paths.
- **Smart path default.** The dialog pre-fills `<session_cwd>/.worktrees/<user-typed-name>` — the project-local convention the `using-git-worktrees` skill recommends — but the user can edit the name. Branch is auto-derived as `worktree/<name>` (the tool's default). For v1 the dialog does NOT expose the full absolute path or the branch as editable fields — the user typed a short name is enough, and matching the tool's default keeps the mental model simple.

**Tech Stack:** Vue 3 + TypeScript + Vite + Bun. Vitest + @vue/test-utils + jsdom. No backend changes, no new dependencies.

---

## Current state (verified by exploration)

| Component | Status | Reference |
|---|---|---|
| `set_git_worktree` agent tool | ✅ Exists, handles `path` / `branch` / `clear` | `src/modules/agent/tools/set_git_worktree.zig` |
| `sessions.git_worktree_cwd` column | ✅ Migration 046 | `src/ai_workflow/tui/migration.zig` |
| `WorktreeMenu.vue` `hasWorktree=true` actions | ✅ "Create a PR", "View in folder", "Clear worktree" | `src/apps/desktop/src/components/WorktreeMenu.vue:101-130` |
| `WorktreeMenu.vue` `hasWorktree=false` actions | ✅ "Open in folder", "Refresh status" (no Create) | `src/apps/desktop/src/components/WorktreeMenu.vue:132-152` |
| LLM-mediated clear pattern | ✅ `onWorktreeMenuClear` in `ChatView.vue` | `src/apps/desktop/src/components/ChatView.vue:602-620` |
| `api.sendChatMessage(...)` | ✅ Posts to `/api/llm/session` | `src/apps/desktop/src/api/index.ts:504` |
| `cwd_override` runtime override | ❌ Dead-letter (separate plan) | `docs/plans/2026-06-18-set-git-worktree-cwd-override.md` |
| `CreateWorktreeDialog.vue` component | ❌ Does not exist | — |
| WorktreeMenu "Create worktree" item | ❌ Does not exist | — |

## Design decisions locked during brainstorming

1. **LLM-mediated, not direct API.** The "Create worktree" action sends a system message to the LLM via the existing `api.sendChatMessage(sessionId, message, cwd, [], selectedProfile)` path (same as the `onWorktreeMenuClear` handler at `ChatView.vue:602-620`). The LLM calls `set_git_worktree(path=<full_path>, branch=<branch>)`; the tool handles validation, `git worktree add` subprocess, DB update, and SSE event emission. We do NOT add a `POST /api/session/:id/worktree` HTTP handler because the `set_git_worktree` tool already implements everything correctly and the plan's principle is "one path, no drift" (matches design decision #5 of the previous git-worktree-cwd-pr plan).

2. **Smart path default = `<session_cwd>/.worktrees/<name>`.** Matches the convention the `using-git-worktrees` skill recommends (project-local, hidden). The dialog's text input collects the `<name>` portion (e.g. `auth-fix`, `bug-123`); the full path is derived in JS as `${sessionCwd}/.worktrees/${name}`. The `.worktrees` directory will be created by `git worktree add` (git creates intermediate dirs in the path) — but only the **leaf** directory. If `<session_cwd>/.worktrees` doesn't exist, the tool will fail with `parent directory does not exist` (per `set_git_worktree.zig:288-289`). The user can either:
   - (a) Let the user manually `mkdir -p .worktrees` first (the recommended path), OR
   - (b) Pre-check and auto-create `.worktrees` in the dialog submit handler (if missing → `fs.mkdir(.worktrees, { recursive: true })` via a new `POST /api/system/mkdir` endpoint or similar).
   - **For v1: do NOT auto-create.** Show a clear error in the toast / log if the tool returns `parent directory does not exist`. The user runs `mkdir -p .worktrees` once per repo. This is YAGNI for v1 and keeps the plan frontend-only.

3. **Auto-derive the branch as `worktree/<name>`.** The `set_git_worktree` tool defaults `branch` to `worktree/<basename(path)>` when the LLM doesn't pass one (see `set_git_worktree.zig:293-298`). The dialog's submit message tells the LLM to pass `path` only and let the branch default; the LLM will then call `set_git_worktree(path=<path>)` (no branch arg) and the tool will derive `worktree/<name>`. If the user wants a custom branch, they can edit the message in the input — but for v1 we don't expose a branch field in the dialog. Matches the principle: "smart defaults, single field, less to type."

4. **Reuse the existing "Open in folder" emit for the post-create success action.** When the worktree is created, the SSE event flips `gitWorktreeCwd` to the new path. The status bar re-renders with the worktree-bound view. No special "open the new worktree folder" action — the worktree-bound menu's "View in folder" already copies the path. The user clicks it manually.

5. **Path validation lives in the tool, NOT the dialog.** The dialog accepts any non-empty string; the `set_git_worktree` tool's `validatePath` function (set_git_worktree.zig:68-79) enforces: absolute, no `..`, no null bytes, ≤ 4096 chars, basename matches `[A-Za-z0-9._-]{1,100}`. The dialog does NOT duplicate this — adding a `?` regex check in TS would drift from the tool's actual rules (the tool is the source of truth). On validation failure, the tool returns `<error>...` in the wrapped XML, the LLM surfaces it as a tool result message, the chat view renders the `SetGitWorktree.vue` tool component (which already handles error display), and the user sees a clear message. This matches the existing `SetGitWorktree.vue` tool-output display.

6. **Dialog is a small modal, NOT a full-screen wizard.** Two text inputs (name, optional) and Cancel/Create buttons. Closes on `Esc`, backdrop click, or Cancel. Mirrors the layout/colors of `CreatePrDialog.vue` for consistency (same `bg var(--semantic-card-bg)`, `border var(--color-border)`, `data-testid` patterns).

7. **WorktreeMenu gains 2 new emits: `create-worktree` and (in the `hasWorktree=false` branch only) the new menu item.** The `hasWorktree=true` branch is unchanged. Mirroring the existing `create-pr` emit, `create-worktree` triggers the parent (ChatView) to open the dialog; the menu closes itself via the existing `close` emit.

8. **Static-test pattern follows `worktreeMenu.spec.ts`.** The existing tests are static (mount the component, click buttons, assert emitted events). The new tests add: (a) "Create worktree" item is present in the no-worktree menu, (b) clicking it emits `create-worktree` and `close`, (c) the worktree-bound menu does NOT contain it.

9. **Out of scope for v1:** "Switch worktree" (re-bind to existing), "List all worktrees" dropdown, "Open in new tab" (new chat pre-bound to worktree), "Pick existing branch" branch override field. The user can do all of these by editing the LLM message or running the `set_git_worktree` tool directly via a chat message.

10. **The plan does NOT touch the `cwd_override` dead-letter field on `ToolExecContext`.** That's a separate plan (`2026-06-18-set-git-worktree-cwd-override.md`, 307 LoC, 5 chunks). The current `set_git_worktree` tool binds the worktree in the DB and the chat view displays it; the LLM's tool calls inside the new worktree still operate from the original cwd until that plan lands. That's a known limitation, not in scope for this user-facing menu addition.

---

## File structure

### New files

```
src/apps/desktop/src/
├── components/
│   └── CreateWorktreeDialog.vue        "Create worktree" modal (name input + Create/Cancel)
└── __tests__/
    ├── createWorktreeDialog.spec.ts    dialog open/submit/error/cancel tests
    └── worktreeMenuCreate.spec.ts      extension to worktreeMenu.spec.ts OR new spec for the new menu item
```

For organization: rather than extending `worktreeMenu.spec.ts` (which would force the existing describe block to be split), **create a new spec `worktreeMenuCreate.spec.ts`** dedicated to the new item. Mirrors the per-feature spec pattern used for `chatViewWorktree.spec.ts` (a separate file for the new worktree display logic).

### Modified files

```
src/apps/desktop/src/components/
├── WorktreeMenu.vue                    add `create-worktree` emit + button in hasWorktree=false branch
└── ChatView.vue                        add showCreateWorktreeDialog ref, onWorktreeMenuCreateWorktree handler, mount CreateWorktreeDialog

src/apps/desktop/src/
└── __tests__/                          (no changes to existing files; new specs only)
```

### No backend changes

- No new HTTP endpoints
- No new agent tools
- No new migrations
- No `tool_registry.zig` changes
- No `set_git_worktree.zig` changes (re-uses as-is)

---

## Verification commands (run throughout)

```bash
# Frontend type-check + build (NOT just vitest — see memory desktop-typescript-bun-build-as-typecheck.md)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
# Expected: clean. No TS errors, no vue-tsc errors.

# Frontend unit tests
timeout 120 bunx vitest run 2>&1 | tail -n 20
# Expected: all pass; new specs for the menu item and the dialog.

# Backend tests (regression — should not be affected)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
# Expected: test success with the same test count as before (no backend changes).

# Manual smoke test
zig build install:linux:system 2>&1 | tail -n 5
nohup ./zig-out/bin/nalar --port 8080 > /tmp/nalar-smoke.log 2>&1 &
# 1) Open a session whose cwd is inside a git repo with no worktree bound.
# 2) Verify the status bar shows 🌿 <branch> ✓ (unchanged behavior).
# 3) Click the status bar. The dropdown opens with 3 items: "Create worktree", "Open in folder", "Refresh status".
# 4) Click "Create worktree". The dialog opens with a single text input ("Name") and Cancel/Create buttons.
# 5) Type a name like "smoke-test-x" and click Create. The dialog closes.
# 6) The chat view sends a system message to the LLM. Wait 2-5s for the LLM to process.
# 7) The LLM calls set_git_worktree(path=.../.worktrees/smoke-test-x). The tool runs git worktree add.
# 8) The SetGitWorktree tool-output component renders in the chat (matching the existing tool display).
# 9) The status bar now shows 🌿 <worktree-branch> · 🌳 smoke-test-x with the worktree-bound menu.
# 10) Verify: ls <session_cwd>/.worktrees/smoke-test-x exists; git -C ... branch shows worktree/smoke-test-x.
```

---

## Chunk 1: `WorktreeMenu.vue` — add "Create worktree" item to the no-worktree branch

The simplest change: add 1 button to the existing `v-else` block (lines 132-152 of `WorktreeMenu.vue`) and 1 emit to the `defineEmits` block (lines 29-35).

**Files:**
- Modify: `src/apps/desktop/src/components/WorktreeMenu.vue`

- [ ] **Step 1.1: Add the `create-worktree` emit to the `defineEmits` block**

Find the existing emits (lines 29-35):

```ts
const emit = defineEmits<{
  (e: 'create-pr'): void
  (e: 'view-folder'): void
  (e: 'clear'): void
  (e: 'refresh'): void
  (e: 'close'): void
}>()
```

Add `create-worktree`:

```ts
const emit = defineEmits<{
  (e: 'create-pr'): void
  (e: 'create-worktree'): void    // NEW — no-worktree menu only
  (e: 'view-folder'): void
  (e: 'clear'): void
  (e: 'refresh'): void
  (e: 'close'): void
}>()
```

- [ ] **Step 1.2: Add the `onCreateWorktree` handler function**

Find the existing handlers (lines 53-70), add the new one after `onRefresh`:

```ts
const onCreateWorktree = () => {
  emit('create-worktree')
  emit('close')
}
```

- [ ] **Step 1.3: Add the new button to the `hasWorktree=false` branch**

Find the `v-else` block (line 133 onwards). The current shape is:

```vue
<template v-else>
  <button
    data-testid="worktree-menu-view-folder"
    @click="onViewFolder"
    class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
    style="color: var(--semantic-text)"
  >
    <span>📁</span>
    <span>Open in folder</span>
  </button>
  <button
    data-testid="worktree-menu-refresh"
    @click="onRefresh"
    class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
    style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
  >
    <span>🔄</span>
    <span>Refresh status</span>
  </button>
</template>
```

Add a new "Create worktree" button ABOVE "Open in folder" (the most prominent action, since this is the primary no-worktree action — per design decision #2, the user has just realized they want a worktree, the most useful next step is to create one):

```vue
<template v-else>
  <button
    data-testid="worktree-menu-create-worktree"
    @click="onCreateWorktree"
    class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
    style="color: var(--semantic-text)"
  >
    <span>🌳</span>
    <span>Create worktree</span>
  </button>
  <button
    data-testid="worktree-menu-view-folder"
    @click="onViewFolder"
    class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
    style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
  >
    <span>📁</span>
    <span>Open in folder</span>
  </button>
  <button
    data-testid="worktree-menu-refresh"
    @click="onRefresh"
    class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
    style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
  >
    <span>🔄</span>
    <span>Refresh status</span>
  </button>
</template>
```

- [ ] **Step 1.4: Update the JSDoc at the top of the file (lines 1-17)**

The docstring lists the actions per branch. Update the `hasWorktree=false` section:

```ts
 * Without worktree (`hasWorktree=false`):
 *   - 🌳 "Create worktree" — emits 'create-worktree' (parent opens CreateWorktreeDialog)
 *   - 📁 "Open in folder" — emits 'view-folder' (parent copies session cwd to clipboard)
 *   - 🔄 "Refresh status" — emits 'refresh' so the parent re-fetches git status
```

- [ ] **Step 1.5: Verify the type-check passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean. No TS errors.

- [ ] **Step 1.6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/WorktreeMenu.vue
git commit -m "feat(ui): add 'Create worktree' item to WorktreeMenu no-worktree branch"
```

---

## Chunk 2: `CreateWorktreeDialog.vue` — name input + Create/Cancel modal

A small modal that collects a name and emits `create(name)`. Mirrors `CreatePrDialog.vue`'s visual style but is much simpler (one text input, two buttons, no async loading, no auto-fill). The parent (ChatView) does the actual work after receiving the event.

**Files:**
- Create: `src/apps/desktop/src/components/CreateWorktreeDialog.vue`

- [ ] **Step 2.1: Create the component file**

```vue
<script setup lang="ts">
/**
 * "Create worktree" dialog. Mounted by ChatView.vue when the user clicks
 * "Create worktree" in the WorktreeMenu (no-worktree branch).
 *
 * The dialog collects a SHORT NAME (e.g. "auth-fix", "bug-123") and
 * emits `create(name)`. The parent derives the full path as
 * `${sessionCwd}/.worktrees/${name}` and the branch as
 * `worktree/${name}`, then sends a system message to the LLM asking
 * it to call set_git_worktree(path=<full_path>). Branch defaults to
 * worktree/<name> in the tool, so the LLM doesn't need to pass it.
 *
 * Why this is simpler than CreatePrDialog:
 *   - No async pre-fill (no getGitWorktreeInfo call)
 *   - No base branch field (tool's default is correct for new worktrees)
 *   - No full path field (smart default + tool's validation handles it)
 *   - The actual work is done by the LLM after the user clicks Create,
 *     so the dialog itself is fire-and-forget
 *
 * The dialog closes itself via the parent's v-if binding.
 */
import { ref, onMounted, onUnmounted } from 'vue'

const emit = defineEmits<{
  (e: 'create', name: string): void
  (e: 'close'): void
}>()

const name = ref('')
const isSubmitting = ref(false)
const inputRef = ref<HTMLInputElement | null>(null)

onMounted(() => {
  // Focus the input on open so the user can start typing immediately
  setTimeout(() => inputRef.value?.focus(), 0)
  // Esc closes the dialog (no submit guard needed — name is empty)
  document.addEventListener('keydown', handleKeydown)
})

onUnmounted(() => {
  document.removeEventListener('keydown', handleKeydown)
})

const handleKeydown = (e: KeyboardEvent) => {
  if (e.key === 'Escape' && !isSubmitting.value) emit('close')
}

const onSubmit = () => {
  if (isSubmitting.value) return
  const trimmed = name.value.trim()
  if (trimmed === '') return
  isSubmitting.value = true
  emit('create', trimmed)
  // Don't close here — the parent may show an error inline. Parent
  // decides when to close (on success, on error, on Cancel).
}

const onClose = () => {
  if (!isSubmitting.value) emit('close')
}
</script>

<template>
  <div
    class="fixed inset-0 z-50 flex items-center justify-center p-4"
    style="background-color: rgba(0, 0, 0, 0.5)"
    @click.self="onClose"
  >
    <div
      class="w-full max-w-md rounded-lg shadow-xl overflow-hidden"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      data-testid="create-worktree-dialog"
    >
      <div
        class="px-4 py-3 flex items-center justify-between"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <h2 class="text-sm font-semibold" style="color: var(--semantic-text)">
          🌳 Create a worktree
        </h2>
        <button
          @click="onClose"
          :disabled="isSubmitting"
          data-testid="create-worktree-close"
          class="opacity-60 hover:opacity-100"
          style="color: var(--semantic-text)"
        >
          ✕
        </button>
      </div>

      <div class="px-4 py-4 space-y-2">
        <label class="block text-xs font-medium" style="color: var(--semantic-text-dim)">
          Name
        </label>
        <input
          ref="inputRef"
          v-model="name"
          data-testid="create-worktree-name"
          type="text"
          class="w-full px-2 py-1.5 text-xs rounded font-mono"
          style="
            background-color: var(--semantic-input-bg, var(--semantic-card-bg));
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
            color-scheme: dark;
          "
          placeholder="auth-fix"
          @keyup.enter="onSubmit"
        />
        <p class="text-[10px] mt-1" style="color: var(--semantic-text-dim)">
          The worktree will be created at
          <code style="font-family: monospace;">&lt;session_cwd&gt;/.worktrees/&lt;name&gt;</code>
          and the branch will be
          <code style="font-family: monospace;">worktree/&lt;name&gt;</code>.
          Make sure
          <code style="font-family: monospace;">.worktrees/</code>
          exists in your project root (or change the name to use a different parent).
        </p>
      </div>

      <div
        class="px-4 py-3 flex items-center justify-end gap-2"
        style="border-top: 1px solid var(--color-border)"
      >
        <button
          @click="onClose"
          :disabled="isSubmitting"
          data-testid="create-worktree-cancel"
          class="px-3 py-1.5 text-xs rounded"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
        >
          Cancel
        </button>
        <button
          @click="onSubmit"
          :disabled="isSubmitting || name.trim() === ''"
          data-testid="create-worktree-submit"
          class="px-3 py-1.5 text-xs font-medium rounded"
          :class="
            isSubmitting || name.trim() === ''
              ? 'opacity-50 cursor-not-allowed'
              : 'hover:opacity-80'
          "
          style="
            background-color: var(--color-violet);
            color: white;
          "
        >
          <span>{{ isSubmitting ? 'Creating...' : 'Create' }}</span>
        </button>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 2.2: Verify the type-check passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean. No TS errors, no vue-tsc errors.

- [ ] **Step 2.3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/CreateWorktreeDialog.vue
git commit -m "feat(ui): add CreateWorktreeDialog component"
```

---

## Chunk 3: `ChatView.vue` — wire the menu emit to the dialog and the dialog to the LLM

Three small edits: (1) import the dialog, (2) add the `showCreateWorktreeDialog` ref and the `onWorktreeMenuCreateWorktree` handler, (3) mount the dialog in the template. The handler builds the system message using the same `api.sendChatMessage(...)` pattern as `onWorktreeMenuClear` (lines 602-620).

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 3.1: Import the new component**

Find the existing imports near line 39 (where `WorktreeMenu` is imported):

```ts
import WorktreeMenu from './WorktreeMenu.vue'
```

Add right after:

```ts
import CreateWorktreeDialog from './CreateWorktreeDialog.vue'
```

- [ ] **Step 3.2: Add the `showCreateWorktreeDialog` ref**

Find the existing worktree refs (around line 575-577):

```ts
const showWorktreeMenu = ref(false)
const worktreeMenuRef = ref<HTMLElement | null>(null)
const showCreatePrDialog = ref(false)
```

Add right after:

```ts
const showCreateWorktreeDialog = ref(false)
```

- [ ] **Step 3.3: Add the menu handler**

Find the existing `onWorktreeMenuCreatePr` handler (line 579-581). Add the new handler right after:

```ts
// User clicked "Create worktree" in the WorktreeMenu no-worktree branch.
// Open the CreateWorktreeDialog so the user can type a name. The actual
// worktree creation happens after the user submits the dialog (handled
// by onCreateWorktree below).
const onWorktreeMenuCreateWorktree = () => {
  showCreateWorktreeDialog.value = true
}
```

- [ ] **Step 3.4: Add the dialog submit handler**

Find the existing `onWorktreeMenuClear` handler (line 602-620). Add the new handler right after `onPrError` (line 629-633). The handler builds the path, builds the system message, and posts to `/api/llm/session` — exactly mirroring `onWorktreeMenuClear`:

```ts
// User submitted the CreateWorktreeDialog with a name. Build the full
// path as `<session_cwd>/.worktrees/<name>` and send a system message
// to the LLM asking it to call set_git_worktree(path=<full_path>).
// The LLM runs the existing tool, which creates the worktree, persists
// sessions.git_worktree_cwd, and emits the SSE event that flips the
// status bar to the worktree-bound view.
//
// We do NOT call any HTTP endpoint directly — the LLM-mediated path
// re-uses set_git_worktree's validation (path must be absolute, no ..,
// basename matches [A-Za-z0-9._-]{1,100}) and gives the user a chance
// to see the tool call in the chat (via the SetGitWorktree.vue tool
// output component). Matches onWorktreeMenuClear's pattern at line 602.
//
// Failure mode: if `<session_cwd>/.worktrees/` doesn't exist, the
// tool returns <error>parent directory does not exist: ...</error>,
// the LLM surfaces it as a tool result, and the SetGitWorktree
// component renders the error. The user can `mkdir -p .worktrees` and
// try again. (Per design decision #2, we do NOT auto-create the
// parent dir in v1 — YAGNI.)
const onCreateWorktree = async (name: string) => {
  if (!sessionId.value) return
  if (!cwd.value) {
    console.error('Create worktree: no session cwd available')
    showCreateWorktreeDialog.value = false
    return
  }
  // Build the full path. Strip any trailing slash from cwd to avoid
  // double-slash in the path (cwd comes from the session row and may
  // or may not have a trailing slash depending on the OS).
  const cleanCwd = cwd.value.endsWith('/') ? cwd.value.slice(0, -1) : cwd.value
  const fullPath = `${cleanCwd}/.worktrees/${name}`
  // Build the system message. Be explicit about the path and the
  // expected behavior so the LLM doesn't surprise the user (e.g.
  // creating the worktree at a different path because it interpreted
  // the request as a hint).
  const message = `Please call set_git_worktree with path=${fullPath} to create a new worktree for me.`
  try {
    await api.sendChatMessage(
      sessionId.value,
      message,
      cwd.value,
      [],
      selectedProfile.value ?? undefined,
    )
  } catch (err) {
    console.error('Failed to send create-worktree message:', err)
  }
  // Close the dialog immediately. The LLM may take 2-5s to process
  // and the SetGitWorktree tool-output component will appear in the
  // chat when the tool call completes. Keeping the dialog open would
  // block the user from seeing the chat activity.
  showCreateWorktreeDialog.value = false
}
```

- [ ] **Step 3.5: Mount the dialog in the template**

Find where `CreatePrDialog` is mounted (search for `showCreatePrDialog` in the `<template>` block, around line 2400-ish). Add the new dialog mount right after:

```vue
<CreateWorktreeDialog
  v-if="showCreateWorktreeDialog"
  @create="onCreateWorktree"
  @close="showCreateWorktreeDialog = false"
/>
```

- [ ] **Step 3.6: Wire the `create-worktree` emit on the `<WorktreeMenu>` mount**

Find the existing `<WorktreeMenu>` mount (around line 2370-2378):

```vue
<WorktreeMenu
  v-if="showWorktreeMenu"
  @create-pr="onWorktreeMenuCreatePr"
  @view-folder="onWorktreeMenuViewFolder"
  @clear="onWorktreeMenuClear"
  @close="showWorktreeMenu = false"
/>
```

Add the new emit binding (alphabetical order matches the existing block):

```vue
<WorktreeMenu
  v-if="showWorktreeMenu"
  @create-pr="onWorktreeMenuCreatePr"
  @create-worktree="onWorktreeMenuCreateWorktree"
  @view-folder="onWorktreeMenuViewFolder"
  @clear="onWorktreeMenuClear"
  @refresh="onWorktreeMenuRefresh"
  @close="showWorktreeMenu = false"
/>
```

Note: the `@refresh` binding is also added (if missing) — this is a pre-existing bug fix (the `WorktreeMenu` emits `refresh` but the `<WorktreeMenu>` mount in ChatView doesn't listen for it; the `onWorktreeMenuRefresh` handler at line 596-600 already exists, so the missing binding means the menu's Refresh button does nothing today). Adding `@refresh` here is a one-line fix to make the existing handler actually fire.

- [ ] **Step 3.7: Verify the type-check passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean. No TS errors.

- [ ] **Step 3.8: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(ui): wire WorktreeMenu 'Create worktree' emit to LLM-mediated handler"
```

---

## Chunk 4: Frontend tests — menu item + dialog

Two new spec files: one for the new menu item (a focused test that asserts the button is present in the no-worktree branch and emits the right events) and one for the dialog (open/focus, type name, submit, cancel, escape, empty name).

**Files:**
- Create: `src/apps/desktop/src/__tests__/worktreeMenuCreate.spec.ts`
- Create: `src/apps/desktop/src/__tests__/createWorktreeDialog.spec.ts`

- [ ] **Step 4.1: Write `worktreeMenuCreate.spec.ts`**

Tests:
1. `hasWorktree=false` menu renders 3 items: "Create worktree", "Open in folder", "Refresh status" (in that order)
2. `hasWorktree=true` menu does NOT contain "Create worktree"
3. Clicking "Create worktree" emits `create-worktree` and `close`
4. The new item's data-testid is `worktree-menu-create-worktree`

```ts
/**
 * Tests for the new "Create worktree" item in WorktreeMenu's
 * no-worktree branch. The other menu items are tested in
 * worktreeMenu.spec.ts (regression tests for the v1.0 WorktreeMenu).
 * This spec is intentionally scoped to the new item only — keeps the
 * test files small and the failure messages specific.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

import WorktreeMenu from '../components/WorktreeMenu.vue'

function mountMenu(hasWorktree: boolean) {
  return mount(WorktreeMenu, {
    props: { hasWorktree, branch: 'main', status: 'clean' },
  })
}

describe('WorktreeMenu — Create worktree item (hasWorktree=false)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders "Create worktree" with the correct data-testid', () => {
    wrapper = mountMenu(false)
    expect(wrapper.find('[data-testid="worktree-menu-create-worktree"]').exists()).toBe(true)
  })

  it('renders the 3 no-worktree items in the correct order: Create, Open, Refresh', () => {
    wrapper = mountMenu(false)
    const buttons = wrapper.findAll('button[data-testid^="worktree-menu-"]')
    expect(buttons.length).toBe(3)
    expect(buttons[0]!.attributes('data-testid')).toBe('worktree-menu-create-worktree')
    expect(buttons[1]!.attributes('data-testid')).toBe('worktree-menu-view-folder')
    expect(buttons[2]!.attributes('data-testid')).toBe('worktree-menu-refresh')
  })

  it('clicking "Create worktree" emits create-worktree and close', async () => {
    wrapper = mountMenu(false)
    await wrapper.find('[data-testid="worktree-menu-create-worktree"]').trigger('click')
    expect(wrapper.emitted('create-worktree')).toBeTruthy()
    expect(wrapper.emitted('create-worktree')!.length).toBe(1)
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('close')!.length).toBe(1)
  })
})

describe('WorktreeMenu — Create worktree is hidden when hasWorktree=true', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('does NOT render the create-worktree item when a worktree is already bound', () => {
    wrapper = mountMenu(true)
    expect(wrapper.find('[data-testid="worktree-menu-create-worktree"]').exists()).toBe(false)
  })
})
```

- [ ] **Step 4.2: Write `createWorktreeDialog.spec.ts`**

Tests:
1. On mount, focuses the name input
2. Typing a name and clicking Create emits `create` with the trimmed name
3. Pressing Enter in the input emits `create` (same as clicking Create)
4. Empty name disables the Create button
5. Whitespace-only name disables the Create button
6. Clicking Cancel emits `close`
7. Pressing Escape emits `close`
8. Clicking the backdrop emits `close`

```ts
/**
 * Tests for the CreateWorktreeDialog component. The dialog is purely
 * presentational (no API calls) — it collects a name, emits `create`,
 * and lets the parent do the actual worktree creation. Mirrors the
 * testing style of createPrDialog.spec.ts.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

import CreateWorktreeDialog from '../components/CreateWorktreeDialog.vue'

function mountDialog() {
  return mount(CreateWorktreeDialog, {
    attachTo: document.body,  // Teleport-style positioning + body click for backdrop
  })
}

describe('CreateWorktreeDialog', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the dialog with a name input and Create/Cancel buttons', () => {
    wrapper = mountDialog()
    expect(wrapper.find('[data-testid="create-worktree-dialog"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-name"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-submit"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-cancel"]').exists()).toBe(true)
  })

  it('focuses the name input on mount', async () => {
    wrapper = mountDialog()
    // The component uses setTimeout(0) to focus, so wait one tick
    await new Promise((r) => setTimeout(r, 5))
    const input = wrapper.find('[data-testid="create-worktree-name"]').element as HTMLInputElement
    expect(document.activeElement).toBe(input)
  })

  it('clicking Create with a name emits create(name) and close is NOT emitted (parent closes)', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('auth-fix')
    await wrapper.find('[data-testid="create-worktree-submit"]').trigger('click')
    // The component emits `create` but does NOT emit `close` — the parent
    // decides when to close the dialog (so it can show an error first).
    expect(wrapper.emitted('create')).toBeTruthy()
    expect(wrapper.emitted('create')![0]).toEqual(['auth-fix'])
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('trims whitespace from the name before emitting', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('  bug-123  ')
    await wrapper.find('[data-testid="create-worktree-submit"]').trigger('click')
    expect(wrapper.emitted('create')![0]).toEqual(['bug-123'])
  })

  it('Create button is disabled when the name is empty', () => {
    wrapper = mountDialog()
    const submit = wrapper.find('[data-testid="create-worktree-submit"]')
    expect(submit.attributes('disabled')).toBeDefined()
  })

  it('Create button is disabled when the name is whitespace-only', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('   ')
    const submit = wrapper.find('[data-testid="create-worktree-submit"]')
    expect(submit.attributes('disabled')).toBeDefined()
  })

  it('Create button is enabled when the name has at least one non-whitespace char', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('x')
    const submit = wrapper.find('[data-testid="create-worktree-submit"]')
    expect(submit.attributes('disabled')).toBeUndefined()
  })

  it('pressing Enter in the input emits create', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('feature-x')
    await wrapper.find('[data-testid="create-worktree-name"]').trigger('keyup.enter')
    expect(wrapper.emitted('create')).toBeTruthy()
    expect(wrapper.emitted('create')![0]).toEqual(['feature-x'])
  })

  it('clicking Cancel emits close', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-cancel"]').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('pressing Escape emits close', async () => {
    wrapper = mountDialog()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await new Promise((r) => setTimeout(r, 0))  // wait for the event handler
    expect(wrapper.emitted('close')).toBeTruthy()
  })
})
```

- [ ] **Step 4.3: Run the frontend tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 30`
Expected: all pass. New test count includes the 4 menu tests + 10 dialog tests = 14 new tests.

- [ ] **Step 4.4: Run the type-check**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean. (Per the project's `bun run build` vs `vitest run` rule — `vue-tsc` is the authoritative type-check.)

- [ ] **Step 4.5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/__tests__/worktreeMenuCreate.spec.ts src/apps/desktop/src/__tests__/createWorktreeDialog.spec.ts
git commit -m "test(ui): worktree menu 'Create worktree' item + CreateWorktreeDialog"
```

---

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| User clicks Create before `.worktrees/` exists in the project | High | The tool returns `<error>parent directory does not exist: ...</error>`, the LLM surfaces it as a tool result message, the existing `SetGitWorktree.vue` tool-output component renders the error. The dialog's hint text (`Make sure .worktrees/ exists in your project root`) tells the user the prerequisite. |
| The LLM interprets the system message differently than intended (e.g. creates the worktree at a different path) | Low | The message is explicit: `Please call set_git_worktree with path=<full_path> to create a new worktree for me.` The full path is computed in JS and substituted; the LLM has no room to vary it. |
| The LLM takes >5s to process the message | Medium | The dialog closes immediately after submit (Step 3.4 line `showCreateWorktreeDialog.value = false`). The user sees the chat's normal "thinking" indicator and the eventual `SetGitWorktree` tool-output component. |
| The session has no `cwd` (rare — new session before `cwd` is set) | Low | The handler logs `Create worktree: no session cwd available` to the console and closes the dialog. The user can refresh the page to re-fetch the session. |
| The user types a name with spaces or special chars | Low | The tool's `validatePath` rejects names that don't match `[A-Za-z0-9._-]{1,100}` and returns `<error>invalid basename: ...</error>`. The user sees the error in the chat and can try again. |
| Multiple sessions share the same `.worktrees/` name | Low | `git worktree add` fails with "fatal: '<branch>' already exists" if the branch is taken, or "fatal: '<path>' already exists" if the dir exists. The tool surfaces the git error verbatim; the user picks a different name. |
| The `@refresh` binding fix in Step 3.6 breaks the existing chatViewWorktree test | Low | The test at `chatViewWorktree.spec.ts` is for the worktree-DISPLAY behavior (🌳 suffix, clickable status bar), not for the menu's Refresh button. Adding `@refresh` to the `<WorktreeMenu>` mount is additive — no existing emit binding is removed. If the test fails, it's because it was checking that Refresh is not bound (which would be a stale test assumption). |
| The `cwd_override` dead-letter field means new worktree file ops still run from the original cwd | Medium | This is a pre-existing limitation (separate plan: `2026-06-18-set-git-worktree-cwd-override.md`). The status bar correctly displays the worktree branch; the LLM's tool calls inside the worktree use the original cwd until the follow-up plan lands. The user can work around by typing `cd <worktree_path> && <command>` in chat or by re-binding the worktree. Documented as a follow-up. |
| The user types a name that creates a path that goes outside the session's cwd (e.g. `../../etc/foo`) | Low | The tool's `validatePath` rejects `..` segments. The dialog's input field is a free text input, so the user CAN type that — but the tool catches it and returns a clear error. |

---

## Out of scope (follow-up plans)

1. **"Switch worktree" dropdown action.** Re-bind the session to a different worktree path via a direct API call. Would mirror the v1.0 `set_git_worktree` clear pattern (LLM-mediated system message). Out of scope for v1; the user can re-call `set_git_worktree` with a different path via chat.

2. **"List all worktrees" dropdown item.** Show a sub-menu of all worktrees in the repo. Out of scope for v1; the user can run `git worktree list` in chat.

3. **"Open worktree in new tab"** — open a new chat pre-bound to the worktree. Out of scope for v1; would need a new chat creation flow with pre-set `git_worktree_cwd`.

4. **Auto-create `.worktrees/` on submit if missing.** A small new endpoint (`POST /api/system/mkdir?path=...`) that creates the directory. YAGNI for v1 — the user runs `mkdir -p .worktrees` once per repo. Easy to add later if it becomes a friction point.

5. **Editable branch field in the dialog.** Some users want to name the branch differently from the folder. Out of scope for v1 — the tool's default (`worktree/<name>`) is the established convention; users with custom needs can edit the LLM message or call the tool directly via chat.

6. **`cwd_override` runtime work.** Separate plan (`2026-06-18-set-git-worktree-cwd-override.md`, 307 LoC, 5 chunks). This plan does NOT depend on it — the user-facing menu works today; the worktree's branch shows correctly; the only limitation is that the LLM's tool calls inside the new worktree still operate from the original cwd.

---

## Definition of done

- [ ] All 4 chunks complete.
- [ ] `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` is clean. No TS errors, no vue-tsc errors.
- [ ] `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 30` is clean. New test count includes ~14 new component tests (4 menu + 10 dialog).
- [ ] `timeout 180 zig build test --summary all 2>&1 | tail -n 5` shows `test success` with the SAME test count as before (no backend changes).
- [ ] Manual smoke test (see "Verification commands" at the top) passes all 10 steps: load chat (no worktree), click status bar, see 3-item menu (Create worktree, Open, Refresh), click Create worktree, dialog opens with focused input, type name, click Create, dialog closes, LLM processes, SetGitWorktree tool-output renders, status bar flips to worktree-bound view with 🌳 suffix.
- [ ] No new test regressions in either backend or frontend test suite.
- [ ] No backend files modified. (The plan is frontend-only; backend regression check is for safety.)
- [ ] No changes to `set_git_worktree.zig`, `tool_registry.zig`, `migration.zig`, or any other Zig file.
- [ ] The pre-existing latent bug "Refresh button does nothing" is fixed (the `@refresh` binding in Step 3.6 is a one-line addition to the existing `<WorktreeMenu>` mount).

---

## Estimated LoC

| File | Change | LoC estimate |
|---|---|---|
| `src/apps/desktop/src/components/WorktreeMenu.vue` | Add 1 emit, 1 handler, 1 button, update JSDoc | +15 |
| `src/apps/desktop/src/components/CreateWorktreeDialog.vue` | New component | +130 |
| `src/apps/desktop/src/components/ChatView.vue` | Import + 1 ref + 2 handlers + 1 dialog mount + 1 menu emit binding | +50 |
| `src/apps/desktop/src/__tests__/worktreeMenuCreate.spec.ts` | 4 new tests for the new menu item | +75 |
| `src/apps/desktop/src/__tests__/createWorktreeDialog.spec.ts` | 10 new tests for the dialog | +160 |
| **Total** | **1 file modified (WorktreeMenu.vue), 1 file modified (ChatView.vue), 3 files created** | **~430 LoC** |

This is a small, focused change that re-uses the existing `set_git_worktree` tool path end-to-end. No new backend code, no new agent tools, no new endpoints. The user gets a one-click path to "Create worktree" that the LLM can then act on.
