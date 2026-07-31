# [fix: design-mode resize handles bubble to wrapper, element MOVES instead of resizing] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the bug where clicking a design element's resize handle (any of the 8 corner/edge handles) causes the element to **translate** under the cursor instead of **resizing**. The user expects Figma-style "drag the SE handle to make the element bigger"; instead they see "drag the SE handle and the element slides to the upper-right". Width/height stay unchanged; only x/y move.

**Architecture:**

1. **EDIT** `src/apps/desktop/src/components/design/DesignElement.vue` — at the top of `startDrag`, call `event.stopPropagation()` whenever `mode !== 'move'` (i.e. on every resize-handle gesture). This prevents the `pointerdown` event from bubbling to the parent `.design-element` wrapper, whose own `@pointerdown` would otherwise start a **second** gesture (the move handler) that steals pointer capture from the handle and starves the resize handler. ~3 lines + ~6-line comment.

2. **EDIT** `src/apps/desktop/src/components/design/__tests__/DesignElement.drag.spec.ts` — add ONE behavioural regression test that dispatches `pointerdown` on a handle (the existing `nw` test already covers the resize math) and asserts the wrapper's `@pointerdown` handler was **NOT** invoked. The simplest invariant: the `select` event is emitted exactly **once** (not twice). The bug's surface is "duplicate handler invocation" — pre-fix, both the handle's and the wrapper's `startDrag` run; post-fix, only the handle's runs.

3. **NEW** `~/.config/nalar/memories/design-resize-handle-pointerdown-bubbles-to-wrapper.md` — capture the root-cause pattern (nested-element @pointerdown + pointer-capture steal + sibling gesture) as a cross-project memory so future agents don't re-introduce the bug when adding new interactive children to gesture-driven components.

**Tech Stack:** Vue 3 `<script setup>` SFCs, `@vue/test-utils` mount + `pointerdown` dispatch, `PointerEvent` API, `setPointerCapture` (browser DOM, no library). No backend, no DB, no migrations.

**Decisions taken (with rationale):**

1. **Fix is inside `startDrag`, NOT on the template binding.** Considered `@pointerdown.stop="(e) => startDrag(e, { resize: handle })"` on the 8 handle bindings — but that scatters the same intent across 8 places and is easy to forget on a future handle addition. Centralizing inside `startDrag` (one check, one `event.stopPropagation()`, covers all current AND future handles) is defensive and matches the codebase's "single source of truth for gesture logic" pattern (compare `useDesignHandlers`, `useDesignHistory`, etc.). The check runs BEFORE the readonly/previewMode/button early-returns so even an early-returning handle click doesn't accidentally let the wrapper's `startDrag` fire (defensive — keeps the bubble decision independent of the gesture-eligibility decision).

2. **`stopPropagation` is unconditional on non-`move` modes** (no conditional on `event.button`, no conditional on `readonly`). Even a right-click on a resize handle shouldn't bubble to the wrapper — the handle owns the click target, full stop. The canvas's `@contextmenu` still fires (it's a separate event, not affected by pointerdown propagation).

3. **Regression test asserts on `select` emit count, not on `update` patch shape.** The existing resize test (`'resize handle emits width/height patch with sign flip'` at line 140) already verifies the patch shape — it passes pre-fix because the test stubs the handle's `addEventListener` and directly invokes the handle's `onMove`, bypassing the wrapper entirely. That test cannot catch this bug (see "Why the existing test didn't catch it" below). The new test goes the OTHER way: count the `select` emits. With the bug, both handle and wrapper fire `startDrag` → both emit `select` → count is 2. With the fix, only the handle fires → count is 1.

4. **New memory file, not a project-local memory.** The bug pattern (nested-element `@pointerdown` + `setPointerCapture` steal + sibling gesture) is a generic Vue 3 + DOM gotcha that any future agent could re-introduce on a different component (e.g. a kanban card with internal buttons). A global memory is the right scope.

5. **Out of scope (acknowledged but NOT in this plan):**
   - The 8 resize handles themselves could be re-rendered as a single overlay (e.g. via `<svg>` + foreignObject) to avoid the bubble issue structurally. The current 8-`<div>`-handles pattern is fine and matches Figma's DOM; the surgical fix is cheaper and safer than a structural rewrite.
   - Generalising the gesture-start pattern into a composable (`usePointerDrag(elements)`) that takes a target ref + mode and owns all the capture/bubble logic. Worthwhile follow-up but out of scope; this plan fixes the specific bug.

## Symptom (with code references)

**User observation:** "Design mode, when user want to resize the element move too". In a design canvas with 1+ element selected, the user clicks a corner handle (e.g. `se` = bottom-right) and drags toward the upper-left. Expected: the element grows (width increases, height increases, x/y stay put — bottom-right anchored). Observed: the element moves diagonally to the upper-left, with width/height unchanged. Same bug on all 8 handles (corners + edges).

**Why this matters:** Resize is a core design-canvas primitive (Figma parity). When every resize attempt silently becomes a move, the design tool is unusable for any sizing workflow. The bug is silent — no error toast, no console warning — and the throttle-emit pattern (50 ms gap + trailing pointerup emit) makes the user's click briefly look responsive before the element drifts.

## Root cause

The resize handle `<div>`s are **children** of the `.design-element` wrapper `<div>`. Both elements have `@pointerdown` listeners:

```vue
<!-- src/apps/desktop/src/components/design/DesignElement.vue:452 -->
<div class="design-element absolute" ...
     @pointerdown="(e) => startDrag(e, 'move')">
  ...
  <!-- Handle (one of 8) -->
  <div ... @pointerdown="(e) => startDrag(e, { resize: handle })" />
</div>
```

When the user clicks a handle, the event fires on the handle FIRST (resize gesture), then bubbles to the wrapper (move gesture). Both `startDrag` calls succeed:

1. **Handle's `startDrag(e, { resize: handle })`** (line 604 / 618): emits `select`, calls `handle.setPointerCapture(pointerId)`, registers `onMove`/`onUp` on the handle.
2. **Wrapper's `startDrag(e, 'move')`** (line 452): emits `select` AGAIN (duplicate, harmless), calls `wrapper.setPointerCapture(pointerId)` — **THIS STEALS CAPTURE FROM THE HANDLE** (per W3C Pointer Events spec, most recent `setPointerCapture` wins), registers `onMove`/`onUp` on the wrapper.

When the user moves the mouse, the browser routes `pointermove` to the element with capture = **the wrapper**. The handle's `onMove` is starved (never fires). The wrapper's `onMove` runs with `mode === 'move'`, so `computePatch(dx, dy)` returns `{ x: start.x + dx, y: start.y + dy }`. `emit('update', { x, y })` — the element moves. Width/height never appear in the patch.

**Why the existing test passes:** `DesignElement.drag.spec.ts:140` ("resize handle emits width/height patch with sign flip") stubs the handle's `addEventListener` to capture the move handler, then directly invokes `moveHandler(...)`. The wrapper's `@pointerdown` still fires (the event has `bubbles: true`) and its move handler is registered on the wrapper, but the test never dispatches a `pointermove` on the wrapper — it calls the handle's `onMove` directly. So the test exercises the resize math in isolation, bypassing the bubble → wrapper-steal path that production hits.

**Why this was hard to catch:** The bug doesn't surface in any single call to the resize handler — the math IS correct. The bug surfaces in the **event flow**, where the DOM bubbling + capture-steal combo causes the wrong handler to win. TypeScript / vue-tsc don't model DOM event bubbling, and jsdom's `setPointerCapture` stub (line 21-29 of the test) is a no-op — so even a careful unit test wouldn't notice. A real browser interaction (or a test that simulates the full bubble → capture-steal sequence) is the only way to expose it.

## Global Constraints

- **Cross-platform (Linux + macOS + Windows)** — pure DOM event logic, no platform-specific code. The fix (`event.stopPropagation()` inside a Vue event handler) is browser-implementation-defined and behaves identically on all major browsers per the W3C Pointer Events spec.
- **Vue 3** — `.design-element` SFC, no Pinia / no router changes.
- **TDD** — regression test first (RED), then fix (GREEN).
- **Surgical patch** — 3 lines in `DesignElement.vue`, plus the regression test. No refactoring of `computePatch`, no restructuring of the 8 handle `<div>`s, no changes to the throttle logic.
- **Verification before completion** — `bun run build` (vue-tsc type-check) + `bunx vitest run` (unit tests) must both pass before any task is marked complete.
- **No backend changes** — frontend-only fix.
- **No DB migrations** — n/a.

## File Touch Map

| File | Action | Lines changed (est.) |
|---|---|---|
| `src/apps/desktop/src/components/design/DesignElement.vue` | EDIT | +9 / -0 |
| `src/apps/desktop/src/components/design/__tests__/DesignElement.drag.spec.ts` | EDIT | +20 / -0 |
| `~/.config/nalar/memories/design-resize-handle-pointerdown-bubbles-to-wrapper.md` | NEW | ~80 |

Total: 3 files, ~+110 net. No backend, no DB, no new dependencies.

---

## Tasks

### Task 1 — Behavioural regression test (RED)

**Goal:** Write a test that clicks a resize handle and asserts the wrapper's `@pointerdown` handler was NOT invoked (the symptom of the bubble → steal bug). Pre-fix, the test fails because both handle and wrapper fire `startDrag` → two `select` emits. Post-fix, the test passes because only the handle fires → one `select` emit.

**File:** `src/apps/desktop/src/components/design/__tests__/DesignElement.drag.spec.ts`

- [ ] **Step 1.1** — Open the test file and locate the end of the resize-handle section (after `'resize clamps width/height to minimum 10px'` at line 168-190, before the `// ─── Chunk 2: multi-select ───` divider at line 226).

- [ ] **Step 1.2** — Insert the new test. Copy the existing `'resize handle emits width/height patch with sign flip'` test's preamble (the `setPointerCapture` stubs, the `nwHandle` lookup) and replace the body with this:

  ```typescript
  // Symptom of the bug fixed in 2026-07-30: when the user clicks a
  // resize handle, the handle's pointerdown fires startDrag(e, {
  // resize: handle }) which then bubbles to the wrapper's @pointerdown
  // (startDrag(e, 'move')). The wrapper's setPointerCapture steals
  // capture from the handle, and the wrapper's move handler runs
  // instead of the handle's resize handler. The element MOVES instead
  // of resizing. The simplest invariant to test is the duplicate
  // handler invocation: with the bug, both handle and wrapper fire
  // startDrag, so 'select' is emitted twice. With the fix, only the
  // handle fires (startDrag calls event.stopPropagation() for any
  // non-'move' mode), so 'select' is emitted once.
  it('resize handle pointerdown does NOT bubble to the wrapper (single select emit, no duplicate handler)', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const nwHandle = wrapper.find(`[data-testid="design-element-handle-${ELEMENT.id}-nw"]`)
    const nwEl = nwHandle.element as HTMLElement
    nwEl.setPointerCapture = () => {}
    nwEl.releasePointerCapture = () => {}
    nwEl.hasPointerCapture = (): boolean => true
    // Deliberately do NOT stub addEventListener on the handle — let
    // both the handle's and the wrapper's listeners register normally
    // so we can verify the bubble behaviour. (Stubbing the handle's
    // addEventListener is what hid the bug in the existing test.)

    nwEl.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))

    // Pre-fix: 'select' emitted TWICE (handle + wrapper).
    // Post-fix: 'select' emitted ONCE (handle only — wrapper's
    // @pointerdown never fired because the handle called
    // event.stopPropagation()).
    const selects = wrapper.emitted('select') ?? []
    expect(selects).toHaveLength(1)
    // Also assert 'dragStart' is emitted once (same duplicate-handler
    // pattern would cause a duplicate dragStart).
    const dragStarts = wrapper.emitted('dragStart') ?? []
    expect(dragStarts).toHaveLength(1)
  })
  ```

- [ ] **Step 1.3** — Run `cd src/apps/desktop && timeout 60 bunx vitest run src/components/design/__tests__/DesignElement.drag.spec.ts 2>&1 | tail -n 30`. The new test should FAIL with:
  ```
  FAIL  src/components/design/__tests__/DesignElement.drag.spec.ts > DesignElement drag > resize handle pointerdown does NOT bubble to the wrapper (single select emit, no duplicate handler)
  AssertionError: expected 2 to equal 1
  ```
  (Two `select` emits because both handle and wrapper fire `startDrag`.)

  If the test passes deterministically pre-fix (the bubble somehow doesn't fire), the test setup is wrong — verify `nwEl.dispatchEvent` is on the handle element (not the wrapper), and the event has `bubbles: true`.

- [ ] **Step 1.4** — Commit: `git add src/apps/desktop/src/components/design/__tests__/DesignElement.drag.spec.ts && git commit -m "test(DesignElement): red — assert resize handle pointerdown does not bubble to wrapper's move handler"`.

### Task 2 — Apply the `stopPropagation` fix (GREEN)

**Goal:** Add `event.stopPropagation()` at the top of `startDrag` in `DesignElement.vue`, before any early returns. The check fires for any `mode !== 'move'` gesture (resize handles only — `'move'` is the only mode that legitimately should bubble, because it's the wrapper's own gesture).

**File:** `src/apps/desktop/src/components/design/DesignElement.vue`

- [ ] **Step 2.1** — Open the file and locate `startDrag` at line 152. The current signature:
  ```typescript
  const startDrag = (event: PointerEvent, mode: DragMode): void => {
    if (props.readonly) return
    // In Preview mode, the canvas is "playing" the mockup — clicks
    // on element bodies are absorbed by the inner iframe (typed text,
    // button activations). Don't start a drag, don't emit select.
    if (props.previewMode) return
    // Don't initiate a drag if the click was on an interactive child
    // (e.g. the iframe content) — pointer-events:none on the iframe
    // already prevents that, but we double-check.
    if (event.button !== 0) return
    ...
  ```

- [ ] **Step 2.2** — Insert a `stopPropagation` block BEFORE the readonly check. Place it as the FIRST thing inside the function body, immediately after the opening brace:

  ```typescript
  const startDrag = (event: PointerEvent, mode: DragMode): void => {
    // The 8 resize handles are children of the .design-element wrapper.
    // The wrapper also has a @pointerdown handler (for 'move'). Without
    // stopping propagation, clicking a handle would bubble to the wrapper
    // and start TWO gestures: the resize (on the handle) and a move
    // (on the wrapper). The wrapper's setPointerCapture then steals
    // capture from the handle — the W3C Pointer Events spec says most
    // recent setPointerCapture wins — leaving the resize handler starved
    // and the move handler running instead. Result: the element MOVES
    // instead of resizing. Symptom: "design mode, when user want to
    // resize the element move too".
    //
    // Fix: stopPropagation on any non-'move' gesture. The check runs
    // before the readonly/previewMode/button early-returns so even an
    // early-returning handle click doesn't bubble (defensive — the
    // bubble decision is independent of gesture eligibility). The
    // canvas's @contextmenu (right-click menu) is a separate event and
    // unaffected by pointerdown propagation, so right-click handling
    // still works.
    if (mode !== 'move') {
      event.stopPropagation()
    }
    if (props.readonly) return
    ...
  ```

- [ ] **Step 2.3** — Run `cd src/apps/desktop && timeout 60 bunx vitest run src/components/design/__tests__/DesignElement.drag.spec.ts 2>&1 | grep -E "resize handle pointerdown does NOT bubble"`. The test from Task 1 should now PASS (GREEN). All 9 existing drag tests should also still pass (the fix is additive — no test relied on the bubble).

- [ ] **Step 2.4** — Run the full frontend test suite to catch any regressions in tests that mounted `DesignElement` with different prop combinations:
  ```bash
  cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5
  ```
  Expect the same pass/fail counts as before (the new test adds +1 passing test on top of the previous 9 drag tests).

- [ ] **Step 2.5** — Run the type-check (per the project memory `bun run build is the type-check, NOT vitest run`):
  ```bash
  cd src/apps/desktop && timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build 2>&1 | tail -n 10
  ```
  Expect clean (no TS errors).

- [ ] **Step 2.6** — Run the full build (vue-tsc + vite bundle):
  ```bash
  cd src/apps/desktop && timeout 240 bun run build 2>&1 | tail -n 10
  ```
  Expect clean (no TS errors, no Vite errors).

- [ ] **Step 2.7** — Commit: `git add src/apps/desktop/src/components/design/DesignElement.vue && git commit -m "fix(design): resize handles call stopPropagation to prevent bubble stealing pointer capture from wrapper's move handler"`.

### Task 3 — Cross-project memory file

**Goal:** Capture the root-cause pattern (nested-element `@pointerdown` + `setPointerCapture` steal + sibling gesture) as a global memory. The bug is a generic Vue 3 + DOM gotcha that any future agent could re-introduce on a different component; the memory makes the pattern searchable.

**File:** `~/.config/nalar/memories/design-resize-handle-pointerdown-bubbles-to-wrapper.md`

- [ ] **Step 3.1** — Create the memory file at the global path. Use the format from existing memories (see `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md` as a template):

  ```markdown
  # Nested @pointerdown handlers + setPointerCapture — the bubble-steals-capture bug

  ## Symptom

  User clicks a child element with its own `@pointerdown` handler (e.g. a resize handle inside a draggable wrapper). The child element moves / re-emits its intended behaviour, AND a second, unrelated gesture fires on the parent. Most commonly: clicking a resize handle causes the element to **translate** instead of **resize** — the parent's move handler wins, the child's resize handler never fires.

  ## Root cause

  Two siblings (or parent + child) both have `@pointerdown` handlers. When the user clicks the inner one:
  1. The inner element's `startDrag(e, { mode: A })` fires first — sets up gesture A, calls `inner.setPointerCapture(pointerId)`.
  2. The event bubbles to the outer element.
  3. The outer element's `startDrag(e, { mode: B })` fires second — sets up gesture B, calls `outer.setPointerCapture(pointerId)`.
  4. Per W3C Pointer Events spec: **most recent `setPointerCapture` wins**. The outer's call steals capture from the inner.
  5. Pointermove events route to the OUTER element. The inner's move handler never fires. The outer emits `{ mode: B }` patches.

  The element "moves" instead of "resizing" because mode B = move won the capture race. The inner handler is starved.

  ## Why tests don't catch it

  Existing tests typically stub `addEventListener` on the inner element and directly invoke its `onMove` handler. The outer's `@pointerdown` still fires (event has `bubbles: true`), but the test never dispatches a `pointermove` on the outer — the outer's move handler is registered but never exercised. The test sees the inner's emit, which is correct in isolation. Production sees the outer's emit (because capture was stolen), which is the bug.

  ## Fix (Vue 3)

  Inside the inner element's pointerdown handler, call `event.stopPropagation()` BEFORE any gesture setup. Do this conditionally on mode if the same handler is used by both siblings:

  ```ts
  const startDrag = (event: PointerEvent, mode: DragMode): void => {
    if (mode !== 'move') {  // ← only handles need to stop, the body is mode 'move'
      event.stopPropagation()
    }
    // ... gesture setup
  }
  ```

  Or unconditionally on the binding with the `.stop` modifier (more explicit, less defensive against future handle additions):

  ```vue
  <div @pointerdown.stop="(e) => startDrag(e, { resize: handle })" />
  ```

  ## Why `event.preventDefault()` alone doesn't fix it

  `preventDefault()` blocks the browser's default action (text selection, scroll). It does NOT stop event bubbling. The wrapper's `@pointerdown` STILL fires. Capture is STILL stolen.

  ## Detection recipe

  ```bash
  # Find any element with @pointerdown that's a child of another element
  # with @pointerdown. Both will fire on click.
  rg -n '@pointerdown' src/apps/desktop/src/components/
  ```

  For each match, ask: "is the inner element's handler meant to be exclusive?" If yes → add `.stop` modifier or call `event.stopPropagation()` inside the inner handler.

  ## When this bites

  - Resize handles inside a draggable element (this instance).
  - Inline edit buttons inside a row that also has click-to-select.
  - Dropdown triggers inside a click-to-dismiss parent.
  - Any nested "two siblings, both want the click" pattern.

  ## Reference

  - Real instance: design mode resize bug, plan `docs/superpowers/plans/2026-07-30-fix-design-resize-handles-bubble-bug.md`
  - W3C Pointer Events spec: "setPointerCapture" — most recent call wins.
  - The existing resize test (`DesignElement.drag.spec.ts:140`) passes against the buggy code because it stubs the inner element's `addEventListener` and bypasses the bubble. Use the regression test from this plan's Task 1 as the template for catching the bug.
  ```

- [ ] **Step 3.2** — Verify the memory appears in `list_memory` output (sanity check that the file is in the right location and the frontmatter is parseable).

- [ ] **Step 3.3** — No commit needed (memory files are local config, not in any git repo).

---

## End-to-end smoke test (verification, run by hand)

**Optional** — the unit test in Task 1 reliably reproduces the bug in jsdom (the bubble → capture-steal sequence is deterministic), so a live browser smoke is redundant. Run if a human reviewer wants visual confirmation.

```bash
# 1. Build the desktop app with the fix
cd src/apps/desktop && timeout 240 bun run build 2>&1 | tail -n 5

# 2. Boot nalar on port 8080 (NEVER 8081)
cd /home/ginwa/ginwaaitoolbox
rm -rf /tmp/nalar-resize-smoke && mkdir -p /tmp/nalar-resize-smoke
env -i HOME=/tmp/nalar-resize-smoke PATH=$PATH \
  setsid -f ./zig-out/bin/nalar --port 8080 \
  >/tmp/nalar-resize-smoke.log 2>&1 < /dev/null
sleep 6

# 3. Open the design item in nalar-desktop (Vite dev mode), select an
#    element, and click-drag the SE handle down-right.
#    Pre-fix: element slides up-left (move gesture wins).
#    Post-fix: element grows (resize gesture wins; bottom-right anchored).

# 4. Cleanup
pkill -f "nalar --port 8080"
rm -rf /tmp/nalar-resize-smoke
```

**Success criteria:** width and height grow as the SE handle is dragged; x/y stay anchored to the original top-left corner.

---

## Reference

- **Bug location:** `src/apps/desktop/src/components/design/DesignElement.vue:152` (the `startDrag` function — needs the `stopPropagation` guard) and `:452` / `:604` / `:618` (the @pointerdown bindings that bubble to each other).
- **Existing resize test (DOES NOT catch the bug):** `src/apps/desktop/src/components/design/__tests__/DesignElement.drag.spec.ts:140` — stubs the handle's `addEventListener` and directly invokes the handle's move handler, bypassing the bubble.
- **W3C spec:** Pointer Events §5.4 `setPointerCapture` — "If a different element has already captured the pointer, the existing capture is released."
- **Related bug (similar shape):** `~/.config/nalar/memories/design-group-drag-sse-stale-positions.md` — different root cause (SSE re-fetch compounds position), same visual symptom (element jumps ahead of cursor). The two memories together cover both axes of "element position drifts under cursor during a gesture".
- **Related bug (similar pattern):** `vue-3-async-onmounted-click-race.md` (global memory) — event handler races; same defensive-thinking pattern.