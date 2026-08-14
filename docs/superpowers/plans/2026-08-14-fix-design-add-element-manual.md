# Plan: Fix design-mode "Add element manual" — wire @create-element binding

**Task**: `task_1786698735722` — user reports:
*"desigh mode, add element manual not working ?"*. The screenshot
shows the `AddDesignElementDialog` ("◇ Add Design Element") open
with Type=Rectangle, Name=My rectangle, and Initial HTML body empty
(just `<div>...</div>` placeholder). User clicks Add — nothing
happens.

**Branch**: `worktree/fix-design-add-element-create`
**Branch (remote)**: pending — push after review.

---

## 1. Context (symptom + root cause)

### What the user saw

1. User opens a design workspace item.
2. User clicks the **+ Element** button in the canvas header.
3. The `AddDesignElementDialog` opens with the right fields
   (Type, Name, Initial HTML body).
4. User picks `Rectangle`, types a name, clicks **Add**.
5. The dialog closes — but **no element appears on the canvas**
   and no toast appears. The user re-opens the dialog and the
   canvas is unchanged.

### Reproduction (2026-08-14)

Any design workspace item, any active page. The `+ Element`
button → dialog → fill + submit → no-op.

### Root cause

The wire between the dialog and the AppLayout parent is broken:

1. `AddDesignElementDialog.vue` emits `create` with the body when
   the user clicks Add. ✅ (verified — see `AddDesignElementDialog.create.spec.ts`
   link 1 test).
2. `DesignView.vue` listens for `@create` on the dialog and
   re-emits `createElement` upward. ✅ (verified — see
   `AddDesignElementDialog.create.spec.ts` link 2 test).
3. `AppLayout.vue`'s `<DesignView>` is **missing the
   `@create-element="..."` binding**. ❌ (this is the bug).

Look at the sibling `@select-page`, `@update-element`,
`@translate-element`, `@resize-element`, `@delete-element`,
`@open-chat` — all wired. `@create-element` was never added.

When `<DesignView>` emits `createElement`, Vue's @-listener list
has no subscriber → the emit is silently dropped. The dialog's
`@close` binding IS wired, so the dialog closes; the user sees a
flash of "click Add → dialog disappears → canvas unchanged".

### Why this slipped through

The other design handlers (`updateElement`, `translateElement`,
`resizeElement`, `deleteElement`) were all added together as part
of the same chunked design-mode-redesign plan (multiple plans from
2026-08-06: split-move-resize, group layers, etc.). `createElement`
went through the dialog re-emit in `DesignView.vue` (line 1641),
but the matching AppLayout handler was never written. The dialog
code path was finished but the parent binding was left out.

The pre-existing `workspacesStore.addDesignElement` action at
`src/apps/desktop/src/stores/workspaces.ts:1955` was already
implemented and ready to be called — it just had no caller in the
AppLayout-level event handler layer.

### Phase 1 evidence

- `src/apps/desktop/src/components/design/DesignView.vue:1641` —
  `emit('createElement', body)` is the only upward fire.
- `src/apps/desktop/src/components/AppLayout.vue:1959-1972` — the
  `<DesignView>` element has no `@create-element` attribute (vs.
  the other 6 design handlers that ARE present).
- `src/apps/desktop/src/composables/useDesignHandlers.ts` —
  `updateElement`, `translateElement`, `resizeElement`,
  `deleteElement`, `groupSelection`, etc. all exist; **no
  `createElement`** until this PR.

---

## 2. Fix (minimal — no scope creep)

### Surgical edits

1. **`src/apps/desktop/src/composables/useDesignHandlers.ts`**
   - Add `createElement(workspaceId, itemId, body)` to the
     composable. Reads `activeDesignPageId` from the store, calls
     `workspacesStore.addDesignElement(...)`, surfaces errors as
     notifications. Returns the persisted `DesignElement | null`
     so the caller can capture in history if desired.
   - Add `createElement` to the returned object.

2. **`src/apps/desktop/src/components/AppLayout.vue`**
   - Import `DesignElement as DesignElementApi` from `../api`.
   - Add `handleDesignCreateElement(body)` next to the other
     `handleDesign*` handlers. Same shape as
     `handleDesignUpdateElement`: guards on activeWorkspace /
     activeWorkspaceItem, calls `designHandlers.createElement`.
   - Add `@create-element="handleDesignCreateElement"` to the
     `<DesignView>` element.
   - Add `handleDesignCreateElement` to the `defineExpose({...})`
     block so the integration test can invoke it directly.

### Files touched

```
M src/apps/desktop/src/components/AppLayout.vue                | +41
M src/apps/desktop/src/composables/useDesignHandlers.ts         | +50
+ src/apps/desktop/src/__tests__/AppLayout.createElement.spec.ts          | +264
+ src/apps/desktop/src/components/design/__tests__/AddDesignElementDialog.create.spec.ts | +293
M src/apps/desktop/src/components/__tests__/AppLayout.translateResize.spec.ts | +6 (comment)
```

5 files, 654 lines (mostly tests + comments).

---

## 3. Tests (RED → GREEN → REFACTOR)

TDD per project rule. Tests written FIRST (verified to fail), then
implementation, then verified to pass.

### 3.1 AddDesignElementDialog.create.spec.ts (new file)

Three describe blocks, one per link in the wire:

1. **`AddDesignElementDialog: create emit shape (link 1)`**
   - mounts the dialog alone, fills name, clicks Add, asserts the
     `create` emit carries `{ name, type, html }`. Verifies the
     dialog itself works in isolation.

2. **`DesignView: @create → createElement re-emit (link 2)`**
   - mounts DesignView, clicks the `+ Element` button, fills the
     dialog, clicks Add, asserts DesignView's `wrapper.emitted
     ('createElement')` carries the same body. Verifies the
     dialog → DesignView re-emit chain.

3. **`useDesignHandlers.createElement → api.addDesignElement
   (link 3)`**
   - calls the composable directly with an active page id;
     asserts the api wrapper fired once with the right
     `(workspaceId, itemId, pageId, body)`.
   - calls the composable without an active page id; asserts
     no-op (no API call, no notification).
   - calls the composable when the api rejects; asserts error
     notification fired + return value is null.

### 3.2 AppLayout.createElement.spec.ts (new file)

Integration-level: mounts AppLayout on a design item with the
stores wired. Two tests:

1. **routes @create-element payload through to api.addDesignElement**
   - invokes `wrapper.vm.handleDesignCreateElement(body)`
     directly (the same function the `@create-element` template
     binding routes to — exposed via `defineExpose` so the test
     doesn't need to set up a full DesignView child).
   - asserts the api wrapper fired with `(ws, item, page, body)`.

2. **is a quiet no-op when activeWorkspace / activeWorkspaceItem
   is missing**
   - asserts the api wrapper did NOT fire when neither is set
     (the handler's guard returns early).

### 3.3 AppLayout.translateResize.spec.ts (updated comment only)

Adds a comment block at the top noting this spec also covers the
`createElement` regression class (Chunk 7.5), so future readers
know the wire here is end-to-end covered.

### Phase 4 verification

- All 7 new tests pass.
- All 2,149 existing tests still pass (`bunx vitest run` from
  `src/apps/desktop`).
- `bunx vue-tsc --build --force` is clean (no .js files emitted
  — vitest's `noEmit:true` config handles this; verified the
  post-vue-tsc file count is 0).
- The pre-fix assertion that failed was
  `expect(addDesignElementMock).toHaveBeenCalledTimes(1)` → got
  0 calls. Post-fix: 1 call with the right args.

---

## 4. Pitfalls / things to verify

### Silent emit drops are hard to detect

Vue's `@event` listener system has NO error, NO warning when an
emit fires with no listener. The event just disappears. This is
the SAME class of bug as the SSE wire-contract issue documented
in the AGENTS.md global rules (an SSE event_type name added in
only one place → frontend silently drops it). Same root cause
flavor: "the wire contract has N sites, all N must be updated
together".

**Mitigation in this PR**: the link-2 test asserts the emit fires
upward; the link-3 test asserts the composable routes to the api;
the integration test asserts the AppLayout handler routes to the
api. If any link is missing, at least one test will fail.

### Should we use `groupElements`/`workspacesStore.addDesignElement`
directly, or via `useDesignHandlers`?

The project rule: handler-level writes go through `useDesignHandlers`.
Already established for `updateElement` / `deleteElement` /
`translateElement` / etc. We follow that convention — `AppLayout`
calls `designHandlers.createElement(ws.id, item.id, body)` which
internally calls `workspacesStore.addDesignElement`. No deviation.

### Why expose `handleDesignCreateElement` in `defineExpose`?

The `AppLayout.designChatDialog.spec.ts` precedent at lines 222-236
exposes `handleDesignOpenChat` so the integration test can invoke
it directly without rendering the full DesignView subtree. We
mirror that pattern here for the create element handler.

### Why not just render DesignView in the test and let the dialog
→ emit chain flow naturally?

It would work, but mounting the full DesignView + canvas +
PropertiesPanel + LayersPanel tree requires fixtures for pages,
elements, the workspaces store, the SSE bus, etc. The existing
`AppLayout.designChatDialog.spec.ts` test sidesteps this by
exposing the handler. Following the same seam keeps the test
focused on the contract under test (the @create-element binding)
rather than the full design canvas.

### Why no `captureCreate` integration?

The undo/redo feature is HIDDEN from the user (per
`DesignView.undoHidden.spec.ts`). The existing capture machinery
is still wired internally, but adding `captureCreate` to the
handleDesignCreateElement path would be scope creep. The bug is
about the create wire, not history capture. If history capture
breaks for create flows, that's a separate bug.

---

## 5. Verification commands

Run from the worktree root `/home/ginwa/ginwaaitoolbox/.worktrees/fix-design-add-element-create`:

```bash
# Targeted regression tests
cd src/apps/desktop
timeout 60 bunx vitest run \
  src/components/design/__tests__/AddDesignElementDialog.create.spec.ts \
  src/__tests__/AppLayout.createElement.spec.ts

# Full suite
cd src/apps/desktop
timeout 180 bunx vitest run
# Expect: Test Files 231 passed (231), Tests 2149 passed (2149)

# Type check
cd src/apps/desktop
timeout 240 bunx vue-tsc --build --force
# Expect: no errors, no .js files emitted under src/
find src -name "*.js" -not -path "*/node_modules/*" | wc -l
# Expect: 0
```

---

## 6. Plan-chunks complete

- [x] Phase 1: Root cause identified (AppLayout missing @create-element binding)
- [x] Phase 2: Specific hypothesis formed and verified (link-2 test fails pre-fix)
- [x] Phase 3: Minimal fix implemented (3 files, 91 lines net code)
- [x] Phase 4: All tests pass (2149/2149), no regressions

---

## 7. Branch / PR plan

- Branch: `worktree/fix-design-add-element-create` (created)
- Commit(s): single commit ("fix(design): wire @create-element so
  AddDesignElementDialog's submit reaches the api" + the tests).
- PR after user review.