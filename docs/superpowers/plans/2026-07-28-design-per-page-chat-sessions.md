# Per-Page Design Chat Sessions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each design page (tab) gets its own chat session. Clicking 💬 on "AI Chat View" opens the chat for that page; clicking 💬 on "Kanban Mode" opens a separate chat for that page. Switching pages while a chat is open does NOT swap chats (the chat stays bound to the page that opened it; closing + reopening binds to the current page).

**Architecture:** Frontend-only change. No backend schema migration, no new HTTP endpoints. The chat is still a `WorkspaceItemTask` row — the change is in how AppLayout picks the task:

1. **Naming convention:** per-page canonical name `Design Chat: <page_name>` (e.g., `Design Chat: AI Chat View`). Falls back to `Design Chat` for legacy data; first open migrates the legacy task in place.
2. **Page-aware lookup:** `handleDesignOpenChat` reads the *active* page from `workspacesStore.activeDesignPageId` + the page's `name` (from DesignView's local `pages` list), and looks up `(item.tasks ∋ t where t.name === "Design Chat: " + pageName)`.
3. **First-open migration:** if a legacy `"Design Chat"` task exists and no per-page task exists for the active page, rename it via `api.updateTask` to `"Design Chat: " + pageName` in-place. The task keeps its id and message history; only the `name` field changes. The next time the user opens a different page, that page will get a freshly-created task.

**Tech Stack:** Vue 3 + TypeScript + Pinia (`useWorkspacesStore`, `useNotificationStore`) + Vue Router. Backend: no changes — uses the existing `api.updateTask` / `api.createTask` / `api.getChatHistory` endpoints.

## Global Constraints

- Existing cross-platform + Zig 0.16 + Vue 3 constraints from `AGENTS.md` apply unchanged.
- **Do not** rename or delete any legacy task that already has messages — only rename via `api.updateTask` so the id (and `llm_history` rows keyed on it) stay intact.
- **Do not** auto-create a chat task for a page that has never been opened — chats are still opened lazily via 💬 click.
- **Do not** auto-swap the active chat when the user switches design pages (the chat is bound to the page that opened it; switching pages leaves the conversation alone). Closing the chat and reopening on a new page binds to the new page.
- **Bun-as-runtime caveat** for `vue-tsc`: see `.nalar/memories/nalar-frontend-patterns.md` — always run `bun run build` (NOT just `bunx vitest run`) before declaring done.
- All new tests must follow the project's static-contract convention (lock the source via regex) OR the behavioral convention (mount via Pinia + `mount()` helper). See `DesignChatToggle.spec.ts` for the established static-contract template.

---

## Design Background (read first)

### Problem

Currently, `AppLayout.handleDesignOpenChat` finds an existing canonical `"Design Chat"` task on the active design item — there is exactly one chat per design item regardless of how many pages it has. If the user:

1. Opens the "AI Chat View" page → clicks 💬 → chats about the AI chat (17 messages).
2. Switches to the "Kanban Mode" page → clicks 💬 → **sees the same 17 messages**.

They expected each page to have a separate design feedback channel. The legacy implementation was designed when most design items had a single page; the "per page" affordance is newer.

### Why not a backend schema migration

A `design_page_id` column on `workspace_item_tasks` would be the textbook answer, but:

- Every chat-related surface in the backend (`fireRoutine`, `llm_history.session_id` indexing, the `/api/llm/session/.../messages` route) reads `session_id = task_id` and assumes the task IS the chat. A foreign key is unnecessary indirection.
- The user-visible chat list (Chats sidebar) is keyed by task; a hidden FK would be invisible to users.
- The naming convention `Design Chat: <page_name>` already gives users a clean answer to "which chat is this for?" in the sidebar.
- No migration risk for users with existing design chats.

### Naming convention

- Canonical per-page task name: **`Design Chat: <page_name>`** (the colon-space separator is human-readable, locale-stable, and identical to the existing `"Design Chat"` constant's case).
- Each page name may legally contain any string the user types (including `:` itself, but extremely unlikely). Collision risk is low (the page name is shown in the tab strip and would already be unique visually).
- If the user renames a page (currently no UI for this — see `DesignPageTabs.vue`; rename is a future plan), the old chat keeps its old name and stays visible in the sidebar. New chats for the renamed page use the new name. This is a tolerable stale state for now.

### Migration of legacy data

For each user with an existing design item that has a legacy `"Design Chat"` task and NO `"Design Chat: <page>"` task yet:

- On the first 💬 click (on any page), rename the legacy task in place via `api.updateTask` to `"Design Chat: <currentPageName>"`.
- The task id is preserved; all chat history stays attached.
- New pages the user visits later get fresh `Design Chat: <newPageName>` tasks via the existing `addTask` path.

If the design item has BOTH a legacy `"Design Chat"` AND existing `"Design Chat: X"` tasks (e.g. user already migrated some pages manually, partial rollout, etc.), leave the legacy alone and create a new task for the active page if missing.

### Chat-during-page-switch behavior

Switching design pages while a chat is open does NOT swap the active chat. The chat task bound to the old page is still active. Reasons:

1. The user might be mid-conversation and toggling pages to compare layouts / reference another page; silently changing the chat is disorienting.
2. Closing the chat (`✕` on the chat pane) and reopening on the new page will pick the new page's chat via the per-page lookup. That's the predictable behavior.

Documented in code (comment in `handleDesignOpenChat` and on the page-switch watcher in AppLayout). No code change for this — the current behavior is correct; we just need to make sure we don't break it.

---

## File Structure

Files touched by this plan:

| File | What changes |
|---|---|
| `src/apps/desktop/src/components/design/DesignView.vue` | Add `activePage` to the `@open-chat` emit payload (page id + name) so the parent has the page context without re-fetching. |
| `src/apps/desktop/src/components/AppLayout.vue` | Rewrite `handleDesignOpenChat` to accept a `(pageId, pageName)` payload; look up by per-page name; do the one-shot legacy migration; update existing static-contract tests. |
| `src/apps/desktop/src/__tests__/DesignChatToggle.spec.ts` | Replace the "finds an existing 'Design Chat' task" test with the per-page version; add tests for per-page creation, legacy migration, multi-page disjoint chats, and the unchanged `name === DESIGN_CHAT_TASK_NAME` constant is removed. |
| `src/apps/desktop/src/composables/useDesignHandlers.ts` | No code change — already keyed on `activeDesignPageId`. Add a comment explaining the chat handler lives in AppLayout. |
| `src/apps/desktop/src/stores/workspaces.ts` | No code change. Add a comment on `activeDesignPageId` explaining the chat scope. |

No backend changes. No new API functions. No new migrations.

---

## Task 1 — Pass the active page to the open-chat handler

**Files:** `src/apps/desktop/src/components/design/DesignView.vue`

**Why:** Right now `handleOpenChat` emits `openChat` with no payload. The parent (AppLayout) has to fish out the active page from the store's `activeDesignPageId` ref AND also know the page's name (which lives in DesignView's local `pages` ref, not in the store). Cleanest fix: pass `(pageId, pageName)` in the emit payload.

**Steps:**

- [ ] Open `src/apps/desktop/src/components/design/DesignView.vue` and find the `openChat` emit declaration (in `defineEmits`) and the `handleOpenChat` function.
- [ ] Change the `openChat` emit payload type from `[]` to `[payload: { pageId: string; pageName: string }]`.
- [ ] Change `handleOpenChat` to look up the active page via `activePage.value` (already a `computed` ref) and emit `{ pageId: activePage.value.id, pageName: activePage.value.name }`.
- [ ] If `activePage.value` is `null` (no pages loaded yet, or no active page), fall back to emitting `{ pageId: '', pageName: '' }` — AppLayout will treat this as "no active page" and short-circuit (it should not create a chat with an empty name).
- [ ] Add an inline comment above the emit noting that this payload drives the per-page chat lookup.
- [ ] Commit: `feat(design): include active page in @open-chat payload for per-page chat scoping`.

**Verification (after this task alone):**

```bash
cd src/apps/desktop
timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js --build
timeout 60 bunx vitest run src/__tests__/DesignChatToggle.spec.ts
```

Expect `vue-tsc` to error out at every `<DesignView @open-chat=...>` listener that calls `handleDesignOpenChat` with zero args — that's expected; we'll fix it in Task 2. The vitest suite will still pass because the static-contract tests don't enforce the emit signature (they grep for the constant name only).

---

## Task 2 — Rewrite `handleDesignOpenChat` for per-page sessions

**Files:** `src/apps/desktop/src/components/AppLayout.vue`

**Why:** The current handler finds a single canonical `"Design Chat"` task across the whole design item. We need to:

1. Accept `(payload: { pageId, pageName })` from the new emit.
2. Look up the active page's chat task via name pattern `Design Chat: <pageName>`.
3. Create a task with that name if none exists.
4. Migrate the legacy `"Design Chat"` task in place on first open (if no per-page task exists yet).

**Steps:**

- [ ] Find the existing `DESIGN_CHAT_TASK_NAME` constant and the `handleDesignOpenChat` function in `AppLayout.vue`. The constant will be retired for lookup, but kept for the legacy-migration comparison only.
- [ ] Update the two `<DesignView ... @open-chat="handleDesignOpenChat" />` invocations in the template to read `@open-chat="(p) => handleDesignOpenChat(p)"` (or `@open-chat="(p) => handleDesignOpenChat(p)"` explicitly typed).
- [ ] Rewrite `handleDesignOpenChat` to take `(payload: { pageId: string; pageName: string })`:
  - Early-return if `!payload.pageId || !payload.pageName` (no active page).
  - Compute `perPageName = "Design Chat: " + payload.pageName`.
  - **Step A — per-page task already exists:** find `item.tasks?.find((t) => t.name === perPageName)`. If found AND has messages (cheap probe via the existing `taskHasMessages` helper), `setActiveTask` and return. If found AND empty (race condition: a previous click on this page created it but never got a message), `setActiveTask` and return — empty per-page chats are not orphans; they belong to this page.
  - **Step B — legacy `"Design Chat"` migration:** find `item.tasks?.find((t) => t.name === DESIGN_CHAT_TASK_NAME)` (= the legacy `"Design Chat"` task). If found AND not empty (probe via `taskHasMessages`), call `api.updateTask(ws.id, item.id, legacyTask.id, { name: perPageName })`, mirror the rename into the local `item.tasks` array, `setActiveTask(legacyTask.id)`, and return.
  - **Step C — no per-page task, legacy exists but is empty (prior broken-click artifact from the 2026-07-26 fix):** if `setActiveTask(legacyTask.id)` would land the user on an empty canonical, that's the legacy-empty case — create a fresh per-page task via `workspacesStore.addTask(...)` with name `perPageName`. (Don't reuse the empty legacy; it was a side-effect of the bug, not a user-owned conversation.)
  - **Step D — neither exists:** create a fresh per-page task via `addTask`.
  - **Step E — fallback for the existing user who has multi-task design items with multiple legacy chats (rare):** do NOT iterate all tasks looking for any-with-messages anymore — that's the previous design that masked this per-page scoping. Replace with: if none of A–D produced a task, just create.
- [ ] Above the function, add a comment block explaining the per-page scoping + legacy migration. Remove the now-stale "Step 1 / Step 2 / Step 3" comments that referred to the old single-canonical behavior.
- [ ] Commit: `feat(design): per-page chat session lookup + one-shot legacy migration`.

**Watch out for:**

- Don't break the "empty canonical is not orphan" rule from the 2026-07-26 fix. If the per-page task exists but is empty (race / never-used yet), reuse it.
- Don't probe all tasks for messages anymore — the N+1 message-probe fallback was a workaround for the single-canonical bug; the per-page lookup is now deterministic.
- The `setActiveTask` function clears `useNavigationStore().clearActiveChat()` (see `workspaces.ts:1567`). Per design this is correct behavior — entering a task fully exits any chat-list state.
- An error in `api.updateTask` should NOT take down the whole flow — wrap in try/catch; on failure, fall through to Step C/D and create a fresh task. Log the error to console.

**Verification:**

```bash
cd src/apps/desktop
timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js --build   # MUST be clean
timeout 60 bunx vitest run src/__tests__/DesignChatToggle.spec.ts
```

Expected: `vue-tsc` clean (all `@open-chat` listeners match the new payload signature); existing 7 static-contract tests in `DesignChatToggle.spec.ts` will FAIL because they assert the OLD behavior. That's fine — Task 4 updates them.

---

## Task 3 — Document the page-switch behavior

**Files:** `src/apps/desktop/src/components/AppLayout.vue`, `src/apps/desktop/src/stores/workspaces.ts`

**Why:** Switching design pages while a chat is open should NOT swap the active chat (per the design background). The current behavior is correct but undocumented; a future refactor could easily "fix" it the wrong way. Add comments at the two relevant sites.

**Steps:**

- [ ] In `AppLayout.vue`, find the watcher that mirrors `route.query` for design-related navigation (around the `watch(() => route.query, ...)` block in the file). Add an inline comment block explaining: "When the user switches design pages, do NOT swap `activeTask`. The chat task is bound to the page that opened it; switching pages leaves the chat alone. Closing + reopening binds to the new page via `handleDesignOpenChat`."
- [ ] In `workspaces.ts`, find the `activeDesignPageId` ref declaration (around line 187). Add an inline comment: "Active design page id, used by both the canvas (DesignView) and the chat-open handler (AppLayout) to scope chat tasks per-page. Switching pages does NOT swap the active chat; that's deliberate."
- [ ] No code change. This task is comments only.
- [ ] Commit: `docs(design): document the per-page chat scope and page-switch non-swap`.

**Verification:**

```bash
cd src/apps/desktop
timeout 60 bunx vitest run   # all existing tests still pass
```

---

## Task 4 — Update `DesignChatToggle.spec.ts` for per-page behavior

**Files:** `src/apps/desktop/src/__tests__/DesignChatToggle.spec.ts`

**Why:** The 7 existing static-contract tests in this file all assert the OLD single-canonical behavior. They need to be rewritten to lock in the NEW per-page behavior. Add new tests for: per-page creation, legacy migration, no auto-swap on page switch.

**Steps:**

- [ ] Open `src/apps/desktop/src/__tests__/DesignChatToggle.spec.ts`.
- [ ] **Replace** the existing test `'handleDesignOpenChat finds an existing "Design Chat" task'` (line ~76) with:
  - `'handleDesignOpenChat looks up the per-page canonical "Design Chat: <pageName>"'` — assert the source contains a pattern that builds the per-page name (regex like `/['"]Design Chat: ['"]?\s*\+\s*payload\.pageName|["']Design Chat: \$\{payload\.pageName\}/`).
  - `'handleDesignOpenChat accepts the (pageId, pageName) payload from the @open-chat emit'` — assert `handleDesignOpenChat\s*\(\s*payload` or `handleDesignOpenChat\s*\(\s*\{\s*pageId` appears in AppLayout's source.
- [ ] **Replace** the existing test `'declares the "Design Chat" task-name constant'` (line ~120) with two tests:
  - `'handleDesignOpenChat retains DESIGN_CHAT_TASK_NAME constant for legacy migration'` — assert the constant declaration is still present (the legacy comparison uses it).
  - `'handleDesignOpenChat renames the legacy task via api.updateTask'` — assert `api\.updateTask\(` appears in AppLayout's source.
- [ ] **Add** new tests:
  - `'DesignView @open-chat emit includes the active pageId and pageName'` — read DesignView.vue source; assert `defineEmits` declares the payload as a record/object with `pageId` and `pageName` fields.
  - `'AppLayout wires @open-chat listener with the new payload signature on every <DesignView>'` — find both `<DesignView ...>` tags; assert both have an `@open-chat=` listener (currently the listener exists but the signature changed).
  - `'handleDesignOpenChat does not iterate all item.tasks for the message-probe fallback'` — regex-negative: assert the source does NOT contain the loop pattern `for\s*\(\s*const\s+t\s+of\s+item\.tasks` (the old fallback that masked the bug).
- [ ] Run the test suite:
  ```bash
  cd src/apps/desktop
  timeout 60 bunx vitest run src/__tests__/DesignChatToggle.spec.ts
  ```
  Expect all tests green.
- [ ] Commit: `test(design): lock per-page chat behavior in DesignChatToggle.spec`.

**Pitfalls (per `.nalar/memories/zig-language-quirks.md` analogue):**

- Static-contract tests grep SOURCE — they only catch regressions that change the source. Don't trust them as behavioral coverage.
- `bun run build` (vue-tsc) catches `vue-tsc` errors that `bunx vitest run` does not. Both must be green before declaring done.

---

## Task 5 — Verify end-to-end against the running server

**Files:** none (manual smoke test + read-only DB check)

**Why:** Static-contract tests can't catch a real-wire bug (e.g., the per-page name format doesn't match the created task). Drive a real design item through the live API to confirm each page gets a disjoint chat.

**Steps:**

- [ ] Identify the design item to use: the workspace context provides `item_1785067707003783748` (`design` type, path `/home/ginwa/ginwaaitoolbox`). Inspect current pages + tasks:
  ```bash
  curl -sS "http://127.0.0.1:8081/api/workspaces/ws_1785055733544_28e79c9db8950100/items/item_1785067707003783748/design/pages" \
    | python3 -m json.tool
  curl -sS "http://127.0.0.1:8081/api/workspaces/ws_1785055733544_28e79c9db8950100/items/item_1785067707003783748/tasks" \
    | python3 -m json.tool
  ```
- [ ] Note the existing page names (e.g., `"AI Chat View"`, `"Kanban Mode"`) and the existing tasks (currently includes the legacy `Design Chat` task `task_1785079182914`).
- [ ] Boot the dev-mode UI and click 💬 on the first page. In the network panel, verify the `POST /api/workspaces/.../tasks` (or `PATCH /api/.../tasks/<id>`) call uses the per-page name like `"Design Chat: AI Chat View"`. If you see the legacy `"Design Chat"` name still being created, Task 2's lookup missed somewhere — debug.
- [ ] Switch to the second page (no chat open), click 💬. Verify a SEPARATE task is created (or found) with name `"Design Chat: Kanban Mode"`. Verify the two task ids differ.
- [ ] Send a message in each chat, then refresh the page. Verify each page's chat shows its own messages, not the other's.
- [ ] Inspect the DB directly to confirm the per-page task names match what the handler should produce:
  ```bash
  sqlite3 ~/.config/nalar/agent.db "SELECT id, name FROM workspace_item_tasks WHERE workspace_item_id = 'item_1785067707003783748' ORDER BY name"
  ```
- [ ] If anything regresses, use this rollback path:
  ```bash
  curl -sS -X DELETE "http://127.0.0.1:8081/api/workspaces/ws_.../items/item_.../tasks/<accidentally-created-task-id>"
  ```
- [ ] Commit: (no commit — manual verification only).

---

## Task 6 — Full pre-commit verification

**Why:** The project mandates a 4-command pre-commit checklist (`AGENTS.md §Pre-commit checklist`). This plan touches frontend only, so the relevant subset is:

**Steps:**

- [ ] Static type-check:
  ```bash
  cd src/apps/desktop
  timeout 180 bun run build 2>&1 | tail -n 30
  ```
  Expect: clean vue-tsc + vite build output, no `TS2532` or other TS errors.
- [ ] Unit tests (frontend):
  ```bash
  timeout 180 bunx vitest run 2>&1 | tail -n 30
  ```
  Expect all suites green.
- [ ] Memory note — write a memory file documenting the per-page pattern (so future agents don't regress it):
  - File: `.nalar/memories/design-chat-per-page-sessions.md`
  - Contents: symptom of the original bug, root cause (single canonical task), fix shape (per-page name + legacy migration + comment-documented non-swap), and verification commands. Mirror the structure of the existing `design-chat-canonical-name-lookup-orphans-prior-chats.md`.
- [ ] Update `docs/SPEC.md` §3.8 (Design Canvas) if it has a "Per-page chat" section — add the per-page scoping + migration. If the section doesn't exist, add one. Mirror the structure of existing §3.8 chunks.
- [ ] Commit (all docs): `docs(design): per-page chat session spec + memory note`.

---

## Out of Scope (deferred)

- Renaming a page → re-associating the chat task with the new name. Would need a "rename" UI in `DesignPageTabs` and a "rename chat" API call. For now: when user renames a page, the old chat stays at its old name (visible in sidebar as a "stale" entry); a new chat is created for the new page name. Document this limitation in the per-page memory file.
- Cascading delete: deleting a design page should also delete its chat task (and llm_history rows). Today's `deleteDesignPage` handler only deletes the page + element rows; it leaves chat tasks orphaned. Out of scope; file a follow-up.
- A `design_page_id` foreign-key column on `workspace_item_tasks` for tooling/queries (e.g., "show me all chats for page X across all design items"). The naming convention is sufficient for in-DB and via API; the FK is a future optimization.
- A "Show 0 of N: this chat is empty (you can start typing)" hint when a new per-page chat is created. The chat-pane already shows an empty state — no work needed.

---

## Reference

- Context: Kanban task `task_1785171603196` ("design mode, per design mode is different chat session") on workspace `ws_1785055733544_28e79c9db8950100`, item `item_1785055824163739523`.
- Existing related work: `.nalar/memories/design-chat-canonical-name-lookup-orphans-prior-chats.md` (the 2026-07-26 fix that this plan supersedes for the design domain).
- Existing test file: `src/apps/desktop/src/__tests__/DesignChatToggle.spec.ts` (template for static-contract tests).
- Existing handler site: `src/apps/desktop/src/components/AppLayout.vue:1383-1453` (`DESIGN_CHAT_TASK_NAME` + `handleDesignOpenChat`).
- Existing emit site: `src/apps/desktop/src/components/design/DesignView.vue:642-644` (`handleOpenChat`).
- Existing store refs: `src/apps/desktop/src/stores/workspaces.ts:187-190` (`activeDesignPageId` + `setActiveDesignPage`).
- Existing API used: `api.updateTask` at `src/apps/desktop/src/api/index.ts:549` (no new endpoint).
- Cross-platform note: this PR is frontend-only — Zig 0.16 + Windows/macOS constraints do not apply to the changed files. The standard `vue-tsc` + `vitest` checks still apply.
