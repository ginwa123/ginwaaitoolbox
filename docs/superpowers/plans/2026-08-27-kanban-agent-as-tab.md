# Kanban Agent Config: Modal Dialog → Settings Tab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the `KanbanAgentSettings` centered modal dialog (Migration 081, `src/apps/desktop/src/components/kanban/KanbanAgentSettings.vue`, 538 lines) and merge its three sections (Knowledge, System Prompt, Tools checkbox grid) into the existing dedicated Kanban Settings page as a third tab (`🤖 Agent`). The `🤖 Agent` button on the kanban board header navigates to `/app/kanban/:itemId/settings?tab=agent` instead of opening a modal — so reload preserves the page, **← Back** returns to the kanban board, the URL is the source of truth, and there is one settings home per board instead of two (modal + page).

**Architecture:** The body of the old dialog (everything inside the `<Teleport to="body">` *except* the three sub-dialogs) is extracted into a new self-contained component `KanbanAgentPanel.vue` that lives under `src/apps/desktop/src/components/views/` (sibling of `KanbanSettingsView.vue`, `WorkspaceItemMemoriesView.vue`, etc.). The three sub-dialogs (`AgentKnowledgeDialog`, `AgentKnowledgeDetailDialog`, `AgentSystemPromptDialog`) stay unchanged — they are already generic props-driven modals used identically by the agent menu. `KanbanSettingsView` gains a third `settingsMode === 'agent'` tab that mounts the new panel, and its active tab is now URL-backed via `?tab=columns|memories|agent` so deep-links and reloads work. The `🤖 Agent` button on `KanbanView`'s toolbar swaps from `emit('openAgentSettings')` (AppLayout-level dialog ref) to a direct `router.push` — so the AppLayout wiring (the `showKanbanAgentSettings` ref + `<KanbanAgentSettings>` mount) goes away entirely.

The user said *"follow the ui kanban agent"* — interpreted as: keep the **exact same UX** (3-section layout: Knowledge / System Prompt / Tools, identical copy, identical controls, identical sub-dialogs, identical `data-testid` names so existing `tests/functional/agent_kanbans_test.py` stays meaningful). Only the **frame** changes: full-page tab instead of centered modal.

**Tech Stack:** Vue 3 (Composition API + `<script setup>`), TypeScript, Pinia, `@vue/test-utils` + Vitest, `vue-tsc --build` for type-check. **Zero backend changes** — all 14 `/api/agent-kanbans/...` endpoints (Migration 081) are reused unchanged.

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-agent-as-tab` on branch `worktree/kanban-agent-as-tab`.

---

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows.
- **No port 8081**: smoke tests use port 8080.
- **Behavioural Vue tests use `@vue/test-utils` `mount` with `setActivePinia(createPinia())`** in `beforeEach`. Mock `useRoute` / `useRouter` via `vi.mock('vue-router', ...)` (mirror `KanbanSettingsView.spec.ts`).
- **TDD discipline**: every implementation task starts with a failing test, then minimal code to make it pass, then a commit.
- **Teleport-based dialog tests** must use `attachTo: document.body` and `document.querySelector(...)` for DOM assertions (skill `.pabrik/skills/vue-teleport-vitest-document-queryselector/SKILL.MD`).
- **Pure architectural relocation**: no UX/visual change to the agent panels themselves (Knowledge rows, System Prompt rows, Tools checkboxes, sub-dialogs) — they are byte-identical in content, only their **container** changes (full-page panel instead of centered modal).
- **URL is source of truth**: the active tab is `route.query.tab`; every click on a tab calls `router.replace`; the `ref<SettingsMode>` is initialized from + synced to `route.query.tab`. No in-memory flag drift between URL and component state.
- **API endpoints unchanged**: `getAgentKanban`, `addAgentKanbanKnowledge`, `enableAgentKanbanTool`, etc. all already exist (Migration 081). Don't add new endpoints or modify existing ones.
- **`data-testid` preserved**: keep every `data-testid="kanban-agent-..."` from the old dialog so the existing functional test suite (`tests/functional/agent_kanbans_test.py`) is still meaningful and any future vitest specs can target the same selectors.

---

## File map

| File | Action | Why |
|---|---|---|
| `src/apps/desktop/src/components/views/KanbanAgentPanel.vue` | NEW | Self-contained panel hosting the 3 sections (Knowledge / System Prompt / Tools) + 3 reused sub-dialogs. Body of the old dialog, minus the modal chrome. |
| `src/apps/desktop/src/__tests__/KanbanAgentPanel.spec.ts` | NEW | Behavioural tests: load + mutations (tool toggle, knowledge add/remove, system-prompt add/remove). |
| `src/apps/desktop/src/components/views/KanbanSettingsView.vue` | EDIT | Add `'agent'` to `SettingsMode` + 3rd tab button + 3rd body branch mounting `<KanbanAgentPanel>`. Read active tab from `route.query.tab`, write via `router.replace`. |
| `src/apps/desktop/src/__tests__/KanbanSettingsView.spec.ts` | EDIT | Extend spec for the new Agent tab + query-param tab tracking. |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | EDIT | Change `🤖 Agent` button from `emit('openAgentSettings')` → `router.push({ path: '/app/kanban/:itemId/settings', query: { tab: 'agent' } })`. Remove `openAgentSettings` from `defineEmits` + `handleOpenAgentSettings`. |
| `src/apps/desktop/src/components/AppLayout.vue` | EDIT | Remove `import KanbanAgentSettings`, `showKanbanAgentSettings` ref, `handleOpenKanbanAgentSettings`, `handleCloseKanbanAgentSettings`, the `<KanbanAgentSettings>` mount, and the `@open-agent-settings` listener on `<KanbanView>`. |
| `src/apps/desktop/src/components/kanban/KanbanAgentSettings.vue` | DELETE | Replaced by `KanbanAgentPanel.vue` (its body, no chrome). |
| `docs/SPEC.md` | EDIT | Append new entry to the kanban settings §X changelog / spec index. |
| `PABRIK.md` | EDIT | Append "### 2026-08-27: kanban agent config moved into Settings page (third tab)" changelog entry. |

Total: **9 files** (2 NEW, 4 EDIT, 1 DELETE, 2 doc). No backend changes, no migration, no Zig changes.

---

## Tasks

### Task 1 — Extract the dialog body into `KanbanAgentPanel.vue`

**Why:** The old dialog mixes chrome (Teleport + backdrop + header + close button + animation) with content (3 sections + 3 sub-dialogs). Strip the chrome and keep only the content so it can be mounted as a tab body inside the dedicated settings page.

**Files:**
- `src/apps/desktop/src/components/views/KanbanAgentPanel.vue` — NEW
- `src/apps/desktop/src/__tests__/KanbanAgentPanel.spec.ts` — NEW

**Steps:**

1. **Read the source of the old dialog** at `src/apps/desktop/src/components/kanban/KanbanAgentSettings.vue` (538 lines — already in the explore agent's output). The body to extract is lines 327-470 (the 3 sections inside `<div v-else-if="config" class="px-5 pb-5 overflow-y-auto flex flex-col gap-5">`) + lines 473-496 (the unconfigured empty state with the tools-to-enable list) + lines 502-525 (the 3 reused sub-dialogs).
2. **Write failing test FIRST** in `KanbanAgentPanel.spec.ts`:
   - Mount with `props: { item: { id: 'wi_kanban', name: 'Sprint' }, workspaceId: 'ws_1' }`.
   - Stub `global.fetch` (or mock the api module via `vi.mock('@/api', ...)`) to return `{ agent_kanban: { id: 'wi_kanban', workspace_item_id: 'wi_kanban', description: '', created_at: '', updated_at: '' }, knowledges: [], tools: [], system_prompts: [] }` for `GET /api/workspaces/ws_1/items/wi_kanban/agent_kanban`.
   - Stub `GET /api/agent-tools/registry` to return `{ tools: [{ name: 'bash', description: 'shell' }, { name: 'read_file', description: 'read' }] }`.
   - Assert `data-testid="kanban-agent-knowledge-panel"` + `kanban-agent-system-prompt-panel` + `kanban-agent-tools-panel` are present (the 3 sections render).
   - Assert the loading state shows `data-testid="kanban-agent-settings-loading"` then resolves to the body.
   - Run — should FAIL (file doesn't exist yet).
3. **Implement `KanbanAgentPanel.vue`**:
   - `<script setup lang="ts">` — copy ALL the `<script setup>` from `KanbanAgentSettings.vue` lines 25-276 (every ref, computed, handler, errText helper, load, mutation handlers, busy/dialogError refs) verbatim — change ONLY:
     - Drop the `props.show` reactive watcher (lines 136-142) — replace with an `onMounted(() => load())` watcher (the panel mounts = it loads; there's no "open/close" lifecycle when there's no modal).
     - Drop the `handleClose` (line 144) — no modal close handler needed.
     - Drop the `defineEmits<{ close: [] }>()` (line 58).
     - Keep `defineProps<{ item: { id: string; name?: string } | null; workspaceId?: string }>()` — same shape, no `show`.
   - `<template>` — copy from `KanbanAgentSettings.vue` lines 327-525 (3 sections + 3 sub-dialogs), wrapping in a single root `<div data-testid="kanban-agent-panel">` instead of the modal `<Teleport>` + backdrop + header. **Preserve every `data-testid="kanban-agent-..."` value** so existing functional tests + any future specs still target the same selectors.
   - `<style>` — drop the `.kanban-agent-settings-modal-*` transition classes (line 529-537) — they're chrome for the modal enter/leave animation. If the panel ever needs an enter animation, add a fresh `.kanban-agent-panel-*` class set; until then, no styles block.
4. **Run the test** — should PASS now. Run the existing `agent_kanbans_test.py` functional suite — should still pass (wire contract unchanged).
5. **Commit:** `kanban-agent-as-tab: extract KanbanAgentPanel.vue (modal body, no chrome)`.

### Task 2 — Add `agent` tab to `KanbanSettingsView` + URL-backed active tab

**Why:** The user clicks `🤖 Agent` and lands on `/app/kanban/:itemId/settings?tab=agent`. Reload preserves the tab. Clicking the **🤖 Agent** tab in the page itself updates `?tab=agent` so the URL is always in sync. `useCurrentMainView` already routes the URL to `kanban-settings` kind — no composable changes needed (the `?tab=` query is opaque to that composable).

**Files:**
- `src/apps/desktop/src/components/views/KanbanSettingsView.vue` — EDIT
- `src/apps/desktop/src/__tests__/KanbanSettingsView.spec.ts` — EDIT

**Steps:**

1. **Write failing tests FIRST** in `KanbanSettingsView.spec.ts`:
   - Test: mounting with `route.query.tab === 'agent'` renders `data-testid="kanban-settings-page-tab-agent"` with the active-tab style and mounts `<KanbanAgentPanel data-testid="kanban-agent-panel">` inside the body (assert via `document.querySelector` since the panel might wrap a Teleport).
   - Test: clicking the `🤖 Agent` tab button calls `router.replace` with `{ query: { ..., tab: 'agent' } }` and updates `settingsMode.value`.
   - Test: deep-link `?tab=memories` renders memories panel (regression — the existing 'memories' tab still works with the URL-backed init).
   - Test: invalid `?tab=foo` falls back to `'columns'` (defensive — unknown tabs default).
   - Run — should FAIL (current implementation uses component-local ref, not URL).
2. **Implement the URL-backed tab in `KanbanSettingsView.vue`**:
   - Replace `const settingsMode = ref<SettingsMode>('columns')` with a writable computed synced to `route.query.tab`:
     ```ts
     const VALID_TABS: readonly SettingsMode[] = ['columns', 'memories', 'agent']
     const settingsMode = computed<SettingsMode>({
       get: () => {
         const raw = route.query.tab
         const s = Array.isArray(raw) ? raw[0] : raw
         return (VALID_TABS as readonly string[]).includes(s ?? '') ? (s as SettingsMode) : 'columns'
       },
       set: (next) => {
         // Persist to URL — preserve any other query params.
         const rest = { ...route.query }
         if (next === 'columns') {
           delete rest.tab // keep URL clean for the default
         } else {
           rest.tab = next
         }
         void router.replace({ query: rest })
       },
     })
     ```
   - Extend `type SettingsMode = 'columns' | 'memories' | 'agent'` (line 35).
   - In the `watch(() => itemId.value, ...)` block (line 188-195), reset to `'columns'` so navigating between kanban boards always starts on Columns. **The URL `?tab=agent` is intentionally NOT preserved across itemId changes** (matching the existing reset-to-'columns' behaviour).
   - Add a third `<button>` in the tab strip (after the `🧠 Local Memories` button at line 304-316), `data-testid="kanban-settings-page-tab-agent"`, label `🤖 Agent`, always visible (no `v-if="item.path"` gate like the memories button has). Click handler: `settingsMode = 'agent'`.
   - In the body, after the `<template v-if="settingsMode === 'columns'">` and before the memories branches, add:
     ```vue
     <div v-else-if="settingsMode === 'agent'" class="flex-1 min-h-0 overflow-hidden" data-testid="kanban-settings-page-agent-panel">
       <KanbanAgentPanel
         :item="item"
         :workspace-id="workspaceId"
       />
     </div>
     ```
   - Import `KanbanAgentPanel` from `./KanbanAgentPanel.vue` at the top of `<script setup>` (alongside `KanbanColumnEditor`, `InlineEditableText`, `WorkspaceItemMemoriesView`).
3. **Run all tests** — should PASS. The 4 new tests verify the URL contract; existing tests (path-driven mount, columns tab, memories tab, copy spec, back button, rename) continue to pass with the URL-backed setter (clicking a tab now calls `router.replace` instead of writing to a ref — adjust any test that mocked router if needed).
4. **Commit:** `kanban-agent-as-tab: add Agent tab to KanbanSettingsView + URL-backed ?tab=`.

### Task 3 — Wire the `🤖 Agent` toolbar button to navigate

**Why:** Today the button emits `openAgentSettings` → AppLayout flips a ref → a modal opens. After this change, the button navigates directly to the settings page with the Agent tab active — no AppLayout coordination needed.

**Files:**
- `src/apps/desktop/src/components/kanban/KanbanView.vue` — EDIT

**Steps:**

1. **Write a failing test FIRST** in `KanbanView.spec.ts` (find/create the spec — if absent, add to `__tests__/KanbanView.spec.ts` or co-locate as `KanbanView.spec.ts` next to the source):
   - Mount `KanbanView` with the toolbar visible and `item.id = 'wi_test'`.
   - Stub `useRouter` to capture `push` calls.
   - Click the `🤖 Agent` button (`data-testid="kanban-view-${item.id}-open-agent-settings"`).
   - Assert `router.push` was called with `{ path: '/app/kanban/wi_test/settings', query: { tab: 'agent' } }`.
   - Assert no `openAgentSettings` emit was fired (the dialog wiring is gone).
   - Run — should FAIL (current handler emits, doesn't push).
2. **Edit `KanbanView.vue`**:
   - Remove `openAgentSettings: []` from `defineEmits<{ … }>` at line 318-321.
   - Remove `handleOpenAgentSettings` at line 583-585.
   - Change the `🤖 Agent` button `@click` at line 1162 from `@click="handleOpenAgentSettings"` to `@click="handleOpenAgentSettings"` → wait, replace with: `@click="router.push({ path: \`/app/kanban/${item.id}/settings\`, query: { tab: 'agent' } })"`. (Use the existing `useRouter()` instance — `KanbanView` already has it imported, find the import — if not, add `import { useRouter } from 'vue-router'` and `const router = useRouter()` near the top of `<script setup>`.)
   - Update the button title (line 1163) from `"Open agent config (knowledge, system prompt, tools)"` to `"Open agent config in board settings"`.
3. **Run tests** — should PASS.
4. **Commit:** `kanban-agent-as-tab: Agent toolbar button navigates to settings?tab=agent`.

### Task 4 — Strip the dialog wiring from `AppLayout`

**Why:** With the button now navigating directly, AppLayout no longer needs the `showKanbanAgentSettings` ref, the open/close handlers, the dialog import, or the `<KanbanAgentSettings>` mount. Removing them shrinks AppLayout by ~30 lines and eliminates the dead `openAgentSettings` event plumbing.

**Files:**
- `src/apps/desktop/src/components/AppLayout.vue` — EDIT

**Steps:**

1. **Edit `AppLayout.vue`**:
   - Remove `import KanbanAgentSettings from './kanban/KanbanAgentSettings.vue'` (line 25).
   - Remove the entire block at lines 1668-1681 (`// ─── KanbanAgentSettings — per-board agent config …` comment + `showKanbanAgentSettings` ref + `handleOpenKanbanAgentSettings` + `handleCloseKanbanAgentSettings`).
   - Remove `@open-agent-settings="handleOpenKanbanAgentSettings"` from the `<KanbanView>` consumer at line 2417.
   - Remove the entire `<KanbanAgentSettings …>` mount block at lines 2783-2796 (the `<!-- KanbanAgentSettings — per-board agent config … -->` comment + 5-line component mount).
2. **Verify:** `vue-tsc --build` clean. `git grep "KanbanAgentSettings\|showKanbanAgentSettings\|handleOpenKanbanAgentSettings\|handleCloseKanbanAgentSettings\|open-agent-settings\|openAgentSettings"` in `src/apps/desktop/src/components/AppLayout.vue` returns zero hits.
3. **Run unit tests** — should PASS (no AppLayout-level change affects tested behaviour).
4. **Commit:** `kanban-agent-as-tab: remove KanbanAgentSettings dialog wiring from AppLayout`.

### Task 5 — Delete the now-unused `KanbanAgentSettings.vue`

**Why:** Task 1 extracted the body into `KanbanAgentPanel.vue`. Task 4 removed the only consumer. The file is dead weight — `git grep "KanbanAgentSettings"` should only match the new spec file's assertions and any test imports (which we'll clean in Task 6).

**Files:**
- `src/apps/desktop/src/components/kanban/KanbanAgentSettings.vue` — DELETE

**Steps:**

1. **`git rm src/apps/desktop/src/components/kanban/KanbanAgentSettings.vue`** — no spec file exists for it (confirmed during exploration: `KanbanAgentSettings.spec.*` returns zero hits), so no companion spec to remove.
2. **Verify no orphans:** `git grep "KanbanAgentSettings\b"` in `src/apps/desktop/src` returns zero hits. If any test or fixture references it, fix them (likely candidates: `KanbanView.spec.ts` assertion about emitting `openAgentSettings` — already removed in Task 3's test update; AppLayout — already cleaned in Task 4).
3. **Commit:** `kanban-agent-as-tab: delete KanbanAgentSettings.vue (replaced by KanbanAgentPanel.vue)`.

### Task 6 — Extend the `KanbanSettingsView` spec for the Agent tab

**Why:** Task 2 already added the 4 failing tests in the implementation step. This task verifies they stay passing, adds a couple more defensive tests, and ensures the existing 7-8 tests in the spec continue to pass with the URL-backed setter.

**Files:**
- `src/apps/desktop/src/__tests__/KanbanSettingsView.spec.ts` — EDIT

**Steps:**

1. **Existing tests to update:**
   - Any test that clicked a tab button and asserted `wrapper.vm.settingsMode === 'memories'` directly — change to assert `route.query.tab === 'memories'` (since `settingsMode` is now a computed backed by the route, and clicking calls `router.replace` which the test's mock router records).
   - Any test that called `setupRoute({})` without `tab` and then expected `'columns'` to be default — still passes (the computed returns `'columns'` when query.tab is absent).
2. **Add 2 more defensive tests:**
   - When `?tab=agent` is in the URL AND `item.path` is null, the Agent tab still renders (no `v-if="item.path"` gate like the memories button has).
   - When `?tab=memories` is in the URL AND `item.path` is null, the memories panel renders the `data-testid="kanban-settings-page-memories-no-path"` empty hint (regression — verify memories tab still gated by `item.path`).
3. **Run `npm run test:unit`** — all KanbanSettingsView.spec.ts tests green.
4. **No commit needed here** (the spec edits ride with Task 2's commit; this is just defensive follow-up). Or commit separately as `kanban-agent-as-tab: extend KanbanSettingsView spec for defensive cases`.

### Task 7 — Final verification + docs

**Files:**
- `docs/SPEC.md` — EDIT
- `PABRIK.md` — EDIT

**Steps:**

1. **Run the full verification sweep:**
   ```bash
   cd /home/ginwa/ginwaaitoolbox
   zig build test --summary all                                              # backend unchanged → all green
   cd src/apps/desktop && npm run test:unit                                  # 3 new + extended tests green
   cd src/apps/desktop && npm run type-check                                 # vue-tsc clean (no orphan type references)
   cd src/apps/desktop && npm run build                                      # production build succeeds (codegen + asset embed)
   PABRIK_BIN=$(pwd)/../../zig-out/bin/pabrikcore-linux-x86_64 \
     python3 -m pytest tests/functional/agent_kanbans_test.py -v             # wire contract still passes
   ```
2. **Manual smoke test (build the desktop binary, point at port 8080):**
   - Open a kanban board.
   - Click `🤖 Agent` button → page navigates to `/app/kanban/:itemId/settings?tab=agent`, Agent tab is highlighted.
   - Toggle a tool checkbox → POST to `/api/agent-kanbans/:id/tools` → row appears in the kanban session's tool list on next agent run.
   - Add a knowledge row → POST → row appears.
   - Add a system prompt → POST → row appears.
   - Click `← Back` → returns to the kanban board (no `?view=` confusion).
   - Reload the page while on Agent tab → tab still Agent (URL-backed).
   - Click the `⚙️ Settings` button on the kanban toolbar → lands on `?tab=columns` (default).
   - Click `🧠 Local Memories` tab → URL becomes `?tab=memories`; reload preserves.
3. **Delete stray `.js` files** emitted by vue-tsc (skill `.pabrik/skills/vue-tsc-build-emits-js-files/SKILL.MD`):
   ```bash
   cd /home/ginwa/ginwaaitoolbox && git status --porcelain | rg '\.js$' | rg -v '^..\s+(node_modules|zig-out|\.zig-cache)/' | awk '{print $2}' | xargs -r git rm
   ```
4. **Update `docs/SPEC.md`**: append a row to the changelog/spec index — *"2026-08-27: Kanban agent config merged into dedicated Settings page as a 3rd `🤖 Agent` tab (replaces `KanbanAgentSettings` modal). URL `?tab=columns|memories|agent`. `🤖 Agent` toolbar button navigates instead of opening a modal."*
5. **Update `PABRIK.md`**: append a new "### 2026-08-27: kanban agent config moved into Settings page (third tab)" changelog entry following the same shape as the existing entries (Files, Wire, Branch, Task, Plan, Verification).
6. **Commit:** `kanban-agent-as-tab: docs (SPEC.md changelog + PABRIK.md entry)`. Push branch `worktree/kanban-agent-as-tab`, open PR for human review.

---

## Pitfalls

- **URL-backed vs ref-backed tab:** converting `settingsMode` from `ref` to a `computed` with `get/set` is a non-trivial change. The getter reads `route.query.tab`, the setter calls `router.replace`. Tests that mocked `router.replace` need to assert the right call shape (`{ query: { ..., tab: 'X' } }`). Don't try to keep both a ref AND a watcher — pick one source of truth.
- **Default tab when query is invalid:** `?tab=foo` must fall back to `'columns'` (don't crash vue-router). The `VALID_TABS` includes guard handles this.
- **`?tab=` preserved across itemId changes?** NO — `watch(itemId, () => settingsMode = 'columns')` resets to `'columns'` regardless of query.tab. This matches the existing reset behaviour. Document this in code comments so a future refactor doesn't accidentally preserve tab across kanban switches.
- **`v-if="item.path"` gate on tab strip:** currently the entire tab strip is hidden when `item.path` is null (the memories tab needs a path). The Agent tab should NOT need a path (agent config is independent of local memories). Two options:
  - (a) Always show the tab strip; hide just the memories tab button when `item.path` is null.
  - (b) Show the tab strip when EITHER `item.path` is truthy OR there's an agent config.
  - Recommended: **(a)** — always show the strip; the memories button does its own `v-if="item.path"` (like the existing tab does, sort of — actually today the whole strip is hidden, so this needs care). Simpler alternative: just always show all 3 tabs and let each panel render its own "no path" empty hint. The memories panel already does this (`kanban-settings-page-memories-no-path`). Implement the simpler approach.
- **Test mocks for `useRoute` reactivity:** the existing `setupRoute` helper returns a `reactive` object so post-mount mutations trigger the computed. This must continue to work — when `router.replace` is called inside a test, the mocked `replace` should mutate the reactive `query` object so the computed re-evaluates. Verify by clicking a tab in a test and re-reading `wrapper.find('[data-testid="kanban-settings-page-tab-agent"]')` active-state assertion.
- **`KanbanAgentPanel` re-mounts when switching tabs:** when the user goes Columns → Agent → Columns → Agent, the panel remounts each time (each tab body is a separate `v-if`/`v-else-if` branch). That means state like the local `loading` / `loadError` / sub-dialog open flags is fresh on every visit. **This is intentional** — matches the existing Columns/Memories tab re-mount behaviour. The Knowledge/System Prompt rows still need to be re-fetched via `getAgentKanban` every time (the dialog did this on `show=true` watcher — the panel does it on `onMounted`). The fresh load is what gives the "reload preserves state" UX win the user wants.
- **Sub-dialogs teleported to body stay alive after panel unmount?** Vue's Teleport content survives its parent's unmount by default (`Teleport` defers teardown to its target). When the user switches to Columns tab and back to Agent, the `AgentKnowledgeDialog` instances may still be in `document.body`. Verify by checking that clicking `✚ Add` on Knowledge after a tab round-trip opens a fresh, empty dialog (not a stale one with the prior row's data). If stale, add `:key="item.id"` to the `<KanbanAgentPanel>` mount in `KanbanSettingsView` to force full remount on itemId change (already implemented at line `:key="kanban-settings-${itemId}"` at AppLayout level — but the body v-else-if branch DOES need explicit re-mount on tab change; add a `:key` inside the v-else-if to force remount when entering the tab fresh).

---

## Verification

- [ ] Plan saved to `docs/superpowers/plans/2026-08-27-kanban-agent-as-tab.md`
- [ ] `KanbanAgentPanel.vue` extracted + spec covers load + mutations
- [ ] `KanbanSettingsView.vue` has 3 tabs + URL-backed `?tab=` + spec covers the new tab + URL contract
- [ ] `🤖 Agent` toolbar button navigates to `?tab=agent` (no emit)
- [ ] `AppLayout.vue` stripped of dialog wiring (zero `KanbanAgentSettings` references)
- [ ] `KanbanAgentSettings.vue` deleted
- [ ] `zig build test --summary all` green (backend unchanged)
- [ ] `npm run test:unit` green (KanbanSettingsView + KanbanAgentPanel + KanbanView specs all pass)
- [ ] `npm run type-check` clean (no orphan types)
- [ ] `npm run build` green (no asset embed errors)
- [ ] `tests/functional/agent_kanbans_test.py` 8/8 passing (wire contract unchanged)
- [ ] Manual smoke test in dev: Agent button navigates, mutations persist, back button works, reload preserves tab
- [ ] `docs/SPEC.md` + `PABRIK.md` updated
- [ ] Stray `.js` files cleaned up before commit
- [ ] Branch `worktree/kanban-agent-as-tab` pushed; PR opened for human review; kanban card moved to `in_review_task`