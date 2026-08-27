# Fix: Chat-click URL gets clobbered to `?view=workspace` (the inverse of task_1785959660154)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `AppLayout`'s `[activeWorkspaceItemId, activeDesignPageId]` mirror watcher from overwriting the URL with `?view=workspace` when the user navigates AWAY from a workspace item to a chat session (or anywhere else). This is the inverse race of `task_1785959660154` / `e0ac21392604` (which added `isNavigatingToTask` for the navigation-TO direction).

**Architecture:** Capture the previous `[itemId, pageId]` tuple in the watcher and early-return when `itemId` transitions from a truthy value to null/empty. That signals "navigating AWAY from workspace" — the destination's own `router.push/replace` (e.g. `Sidebar.handleChatsNavigate`'s `router.replace({view: 'chat', session})`) is the authoritative URL update, and this watcher must not race against it. The fix is a single early-return inside the existing watcher — no new store flag, no new composable, no new public surface.

**Tech Stack:** Vue 3 (`watch`, reactivity), vue-router (route.query, router.replace), Pinia (`workspacesStore.activeWorkspaceItemId` / `activeDesignPageId`), vitest + @vue/test-utils (existing test pattern).

## Global Constraints

<!--
  Project-wide requirements — version floors, dependency limits, naming rules,
  platform requirements
-->

- TDD: every fix lands with a failing test that exercises the exact reproduction steps from the user report, then a minimal code change that turns it green.
- One regression test + one regression-guard test (mirrors the structure of `AppLayout.taskClickUrlOverwrite.spec.ts` which proves the opposite direction).
- Do not touch `isNavigatingToTask` — that flag guards the TO direction and is unrelated.
- Do not refactor the watcher into a composable. Extraction is out of scope; the watcher stays inline in `AppLayout.vue` to match the existing style of `isNavigatingToTask`'s sibling flag check.
- File-naming: `AppLayout.chatClickUrlOverwrite.spec.ts` mirrors `AppLayout.taskClickUrlOverwrite.spec.ts` (the existing fix for the inverse race).

## File Structure

<!--
  Before defining tasks, map out which files will be created or modified.
-->

| File | Change | Purpose |
| --- | --- | --- |
| `src/apps/desktop/src/__tests__/AppLayout.chatClickUrlOverwrite.spec.ts` | NEW | Regression test for the bug + regression-guard test that the watcher still mirrors when `itemId` is set to a truthy value (proves we didn't over-broaden the early-return). |
| `src/apps/desktop/src/components/AppLayout.vue` | EDIT (line ~298) | Capture old value of `[activeWorkspaceItemId, activeDesignPageId]`; add early-return when `itemId` transitions truthy → null/empty. |

No backend, no router, no store changes. No migration.

## Tasks

### Task 1 — Write the failing test (RED)

**Files:**
- Create: `src/apps/desktop/src/__tests__/AppLayout.chatClickUrlOverwrite.spec.ts`

**Steps:**

- [ ] Copy `src/apps/desktop/src/__tests__/AppLayout.taskClickUrlOverwrite.spec.ts` to `AppLayout.chatClickUrlOverwrite.spec.ts` as a starting scaffold — it already imports `mountAppLayout`, mocks `vue-router`, sets up the workspaces store with `ws_taskurl`/`item_folder_taskurl`, and stubs all the heavy children (`Sidebar`, `KanbanView`, `DesignView`, etc.). Strip out the two `taskClickUrlOverwrite` cases and the `setActiveTask`-specific logic; keep the `mountAppLayout` helper, the `beforeEach` `vi.spyOn` block (`getChats` / `getWorkspaces` / `getWorkspacesItems` / `getTasks` / `getSystemFolder`), and the `__resetSseBus` / `installSseBus` plumbing.

- [ ] Replace the suite header with a doc comment that names the new bug:
  ```ts
  /**
   * Tests for AppLayout's URL sync watcher when navigating AWAY from a
   * workspace item to a chat session (or anywhere else) via Sidebar.
   *
   * Bug (user report, task_1787844892180_2, 2026-08-27):
   *   Steps to reproduce:
   *     1. Create a kanban workspace item.
   *     2. Create a task on that kanban.
   *     3. Click the task — KanbanChatDialog opens, URL becomes
   *        `?view=workspace&workspaceId=X&itemId=Y/chat/task_Z`.
   *     4. Close the chat dialog — URL becomes
   *        `?view=workspace&workspaceId=X&itemId=Y`,
   *        activeWorkspaceItemId = Y, activeTask = null.
   *     5. Click any chat session in the sidebar.
   *   Expected URL: `?view=chat&session=S`.
   *   Actual URL: `?view=workspace` (clobbered by the mirror watcher).
   *
   * Root cause: same race as task_1785959660154 in the opposite
   * direction. Sidebar.handleChatsNavigate synchronously calls
   * setActiveWorkspaceItem(null) and then router.replace({view: 'chat',
   * session: S}). The mirror watcher at AppLayout.vue:298 fires on the
   * next microtask — BEFORE Vue Router's URL change has propagated to
   * route.query.view. The guard `if (currentView !== 'workspace' && ...
   * ) return` does NOT return early (currentView is still 'workspace'
   * from step 4), so the watcher clobbers the URL with
   * router.replace({view: 'workspace'}).
   *
   * The previous fix for the inverse direction used a flag
   * (`isNavigatingToTask`). The mirror watcher can detect the
   * AWAY-from-workspace direction without a flag: the itemId
   * transition is from truthy → null. We early-return on that
   * transition.
   *
   * Plan: docs/superpowers/plans/2026-08-27-fix-chat-click-url-overwrite.md
   */
  ```

- [ ] **Test 1 — the regression.** Reproduce the user's flow exactly.
  ```ts
  it('clicking a chat session after closing a kanban task does NOT clobber the URL to ?view=workspace', async () => {
    const replaceMock = vi.fn()
    const pushMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock } as any)

    // Step 1+2: kanban workspace item exists, task created on it. Active
    // workspace item is the kanban (Y); active task is null (post-close).
    const wrapper = mountAppLayout({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: FOLDER_ID, // reuse the folder id from the scaffold; semantically a kanban
    })
    await nextTick(); await nextTick()
    const ws = useWorkspacesStore()
    ws.workspaces = [makeWorkspace()]
    ws.setActiveWorkspaceItem(FOLDER_ID)
    await nextTick(); await nextTick()
    replaceMock.mockClear(); pushMock.mockClear()

    // Step 5: simulate Sidebar.handleChatsNavigate. Synchronously:
    //   - setActiveChat (delegated to navigationStore — not the watcher's concern)
    //   - setActiveWorkspaceItem(null)
    //   - setActiveTask(null)
    //   - router.replace({view: 'chat', session: SID})
    const SID = 'session_xyz'
    ws.setActiveWorkspaceItem(null)
    ws.setActiveTask(null)
    replaceMock({
      path: '/app',
      query: { view: 'chat', session: SID },
    })
    await nextTick(); await nextTick()

    // Assert: the mirror watcher did NOT call router.replace with
    // ?view=workspace (the bug). It MUST NOT have written any URL at all
    // — the destination's own router.replace is the authoritative URL
    // update and must not be clobbered.
    const clobber = replaceMock.mock.calls.filter(
      (call: any[]) => call[0]?.query?.view === 'workspace',
    )
    expect(clobber).toHaveLength(0)
    wrapper.unmount()
  })
  ```

- [ ] **Test 2 — the regression-guard.** Programmatic `setActiveWorkspaceItem(truthy)` from a fresh state (e.g. a future keyboard-shortcut path) still mirrors to the URL. Without this test, a future refactor that broadens the early-return too far would silently break the mirror feature.
  ```ts
  it('mirror watcher STILL mirrors when activeWorkspaceItemId goes from null to a truthy value (regression-guard)', async () => {
    const replaceMock = vi.fn()
    const pushMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock } as any)

    // Start with NO active workspace item (e.g. user is on chat, then
    // a future keyboard shortcut / deep link sets the item).
    useRouteMock.mockReturnValue({
      query: {},
      path: '/app',
      fullPath: '/app',
    } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [makeWorkspace()]
    const wrapper = mount(AppLayout, { global: { stubs: {/* same stubs as mountAppLayout */} } })
    await nextTick(); await nextTick()
    ws.workspaces = [makeWorkspace()]
    replaceMock.mockClear(); pushMock.mockClear()

    // Programmatic setActiveWorkspaceItem(FOLDER_ID) — old value is null,
    // new value is truthy. Watcher MUST mirror to ?view=workspace&...
    ws.setActiveWorkspaceItem(FOLDER_ID)
    await nextTick(); await nextTick()

    const mirror = replaceMock.mock.calls.find(
      (call: any[]) => call[0]?.query?.itemId === FOLDER_ID,
    )
    expect(mirror).toBeDefined()
    wrapper.unmount()
  })
  ```

- [ ] Run the tests and confirm they fail for the right reason. Expected: Test 1 fails (the watcher clobbers `?view=workspace`), Test 2 passes (mirror still works today).
  ```bash
  cd /home/ginwa/ginwaaitoolbox
  timeout 120 npx vitest run src/apps/desktop/src/__tests__/AppLayout.chatClickUrlOverwrite.spec.ts 2>&1 | tail -n 60
  ```
  Look for `Test 1 → expected 0 calls but got 1` (or similar). Test 2 must already be green.

- [ ] Commit the failing test on the new worktree.
  ```bash
  git add src/apps/desktop/src/__tests__/AppLayout.chatClickUrlOverwrite.spec.ts
  git commit -m "test(chat-click-url-overwrite): failing regression + guard for inverse task-url race

  Reproduces task_1787844892180_2 (user-reported): after closing a kanban
  task and clicking a chat in the sidebar, the URL stays at
  ?view=workspace instead of becoming ?view=chat&session=S.

  The test mirrors AppLayout.taskClickUrlOverwrite.spec.ts (the existing
  fix for the TO-direction race) and is the RED half of the TDD pair."
  ```

### Task 2 — Fix the watcher (GREEN)

**Files:**
- Edit: `src/apps/desktop/src/components/AppLayout.vue` (the `watch` block at line 298)

**Steps:**

- [ ] Capture the previous value tuple in the watcher's callback. Change the signature on line 300 from
  ```ts
  ([itemId, pageId]) => {
  ```
  to
  ```ts
  ([itemId, pageId], [oldItemId, oldPageId]) => {
  ```
  (Note: `oldPageId` is referenced only for symmetry; the bug only cares about `oldItemId`. The parameter name makes the watcher's intent self-documenting.)

- [ ] Add the early-return immediately after the `isNavigatingToTask` guard (around line 339). Match the docstring style of the surrounding watcher (full prose, references the plan + the inverse fix by id).
  ```ts
  // FIX (chat-click-url-overwrite, task_1787844892180_2, 2026-08-27):
  // Inverse of the task_1785959660154 race: when the user navigates
  // AWAY from a workspace item (e.g. Sidebar.handleChatsNavigate
  // clearing activeWorkspaceItemId before its own router.replace
  // applies), this watcher fires with itemId = null while
  // route.query.view is still 'workspace' from the previous page.
  // The currentView guard does NOT return early in that window and
  // the watcher would clobber the destination's URL with
  // router.replace({view: 'workspace'}). The fix: skip the mirror
  // when itemId is being cleared from a previously-truthy value —
  // the destination's router call wins, this watcher must not race.
  // The mirror still fires for the truthy→truthy and null→truthy
  // transitions (regression-guarded by Test 2 in
  // AppLayout.chatClickUrlOverwrite.spec.ts).
  if (!itemId && oldItemId) return
  ```

- [ ] Run the new spec and confirm it goes GREEN.
  ```bash
  cd /home/ginwa/ginwaaitoolbox
  timeout 120 npx vitest run src/apps/desktop/src/__tests__/AppLayout.chatClickUrlOverwrite.spec.ts 2>&1 | tail -n 30
  ```
  Expected: Test 1 PASSES (no more clobber), Test 2 still PASSES (mirror still works).

- [ ] Run the entire frontend suite to make sure no existing test regressed. The AppLayout URL tests are the load-bearing ones; the kanban and design tests touch the same watcher.
  ```bash
  cd /home/ginwa/ginwaaitoolbox
  timeout 240 npx vitest run src/apps/desktop/src/__tests__/ 2>&1 | tail -n 40
  ```
  Expected: same pass count as before, no new failures. If `AppLayout.urlPersist.spec.ts`, `AppLayout.taskClickUrlOverwrite.spec.ts`, `AppLayout.simplifyUrl.spec.ts`, `AppLayout.chatSuffixRoundTrip.spec.ts`, or `AppLayout.kanban.spec.ts` regresses, the fix is too broad — narrow the early-return (most likely the truthy→truthy-with-different-value path is being short-circuited; check that `oldItemId` is the literal previous ref value, not the comparison).

- [ ] Commit.
  ```bash
  git add src/apps/desktop/src/components/AppLayout.vue
  git commit -m "fix(AppLayout): chat-click no longer clobbers URL to ?view=workspace

  Inverse of task_1785959660154. Sidebar.handleChatsNavigate clears
  activeWorkspaceItemId and then router.replace({view: 'chat', session}).
  The mirror watcher fires BEFORE the router URL update propagates to
  route.query.view, sees the stale 'workspace' view, and clobbers the
  chat URL with router.replace({view: 'workspace'}). Fix: early-return
  on the truthy→null transition so the destination's router call wins.
  The mirror still fires for null→truthy and truthy→truthy (covered
  by AppLayout.chatClickUrlOverwrite.spec.ts regression-guard test)."
  ```

### Task 3 — Verify + report

**Files:** none (read-only).

**Steps:**

- [ ] Run the full frontend suite end-to-end one more time as a smoke check.
  ```bash
  cd /home/ginwa/ginwaaitoolbox
  timeout 600 npx vitest run src/apps/desktop/ 2>&1 | tail -n 5
  ```
  Expected: pass count unchanged or +2 (the two new tests). 0 new failures.

- [ ] Spot-check the AppLayout watcher with a real browser (dev server). Optional but recommended — the user-facing report came from a manual repro.
  ```bash
  cd /home/ginwa/ginwaaitoolbox
  npm run dev    # or whatever the project uses
  # Then: create kanban, create task, click+close task, click a chat in the
  # sidebar. Confirm the URL bar reads ?view=chat&session=... (NOT
  # ?view=workspace).
  ```
  Skip this step if the dev server is unavailable in the sandbox — the vitest spec is the load-bearing check.

- [ ] Move the kanban card to `in_review_task` (not `merged` — only the human moves to `merged`).
  ```ts
  kanban_move_task({
    workspace_id: 'ws_1785055733544_28e79c9db8950100',
    item_id: 'item_1785055824163739523',
    task_id: 'task_1787844892180_2',
    target_column_id: 'col_1826ecca367f0000',
  })
  ```

## Pitfalls

<!--
  Known failure modes and how to avoid or recover from them.
-->

- **Don't add a new store flag.** The inverse race needs a different flag (`isNavigatingAw ay`?) but flags are caller-managed and easy to forget. The truthy→null old-value check is implicit and works for every caller without coordination. If a reviewer pushes back on that, the flag alternative is acceptable too — just don't do BOTH.
- **Don't broaden the early-return to `!itemId`.** That would also skip the legitimate `null → Y` case (future keyboard shortcut, deep link) and silently break the mirror feature. The guard is `!itemId && oldItemId` — both halves matter. Test 2 in the new spec is the regression-guard that catches a too-broad fix.
- **Vue watchers fire AFTER Vue Router's URL change in unit tests but the order is timing-dependent.** `@vue/test-utils` uses jsdom which runs both effects in the same tick. Test 1 must exercise the actual production race: `setActiveWorkspaceItem(null)` synchronously, THEN `router.replace(...)` (the mock just records the call — it doesn't propagate to `route.query` because `useRouterMock.mockReturnValue` returns a plain object). So the test scenario matches the real-browser race window.
- **`useRouteMock.mockReturnValue` is set at mount time and re-read inside the watcher.** If you re-mock between the setup and the assertion, the watcher's `route.query` won't match. The existing `taskClickUrlOverwrite` spec uses `useRouteMock.mockReturnValue(...)` inside the test body AND after mount, which is fine because the watcher closes over the returned object reference (not the mock function).

## Verification

- [ ] New test file passes after the fix; fails before.
- [ ] Full frontend vitest suite passes with no new regressions.
- [ ] Manual browser repro (steps 1–5 above) shows the URL ending at `?view=chat&session=...`.
- [ ] Plan committed to `docs/superpowers/plans/2026-08-27-fix-chat-click-url-overwrite.md` in the worktree.
- [ ] Kanban card moved to `in_review_task`.
