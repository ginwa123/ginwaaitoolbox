# design group drag — SSE re-fetch compounds the cursor delta on every pointermove

## Symptom

Dragging a single `group` / `frame` element (or a multi-select of 2+ elements)
in the design canvas causes the element to move **further than the cursor**
with each pointermove. The user reports it as "design mode drag element
moves so fast" — the element visually jumps ahead of the cursor, and the
gap widens as the pointer moves.

## Root cause

The group-drag handler in `DesignView.vue::handleGroupDrag` computes the
PATCH position as `el.x + finalDx`, where `el.x` is read from
`elements.value` (the LIVE Pinia store). The cursor delta is `finalDx`.

After the first PATCH round-trips, the backend emits a
`design_element_updated` SSE event. The SSE handler in
`stores/designSse.ts` calls `fetchDesignElements`, which overwrites
`item.design_elements` with the latest server state. So `el.x` is now
the SSE'd position, not the pointerdown-time position.

On the NEXT pointermove, the formula `el.x + finalDx` adds the cursor
delta to the ALREADY-MOVED position. The element jumps ahead by the
delta again. Repeat: the element moves further than the cursor on every
pointermove.

Tracing the math (zoom=1, original X=0):
- Pointermove 1: cursor at +50. PATCH = `0 + 50 = 50`. SSE arrives,
  `el.x = 50`.
- Pointermove 2: cursor at +100. PATCH = `50 + 100 = 150`. WRONG.
  Cursor is at +100, element should be at +100.
- Pointermove 3: cursor at +150. PATCH = `150 + 150 = 300`. WRONG.

The single-element drag doesn't have this bug because
`DesignElement.vue::startDrag` captures `start = { x: props.element.x, ... }`
at pointerdown and computes `patch.x = start.x + dx` (absolute position
from the START, not the current position). The `start` reference is a
local const — it doesn't change as the SSE re-fetch updates the store.

## Fix

Capture each element's ORIGINAL position on the FIRST pointermove
(drag start), then use that snapshot for every subsequent PATCH in
the same drag. Reset the snapshot on dragEnd (the pointerup event).

```ts
// Source of truth for the PATCH math — captured on the first
// pointermove, reset on dragEnd. `elements.value` may change
// mid-drag via SSE re-fetch, but the snapshot stays stable.
let dragStartPositions: Map<string, { x: number; y: number }> | null = null

const handleGroupDrag = (delta: { dx: number; dy: number }): void => {
  // ... existing checks ...

  const dragIds = expandSelectionWithDescendants(...)
  const selected = elements.value.filter((e) => dragIds.has(e.id))
  if (selected.length > 0) {
    // Capture ONCE — on the first pointermove, `el.x` is the
    // pointerdown-time position (no SSE update has happened yet).
    if (dragStartPositions === null) {
      dragStartPositions = new Map()
      for (const el of selected) {
        dragStartPositions.set(el.id, { x: el.x, y: el.y })
      }
    }
    const originalPos = (e: DesignElementApi) =>
      dragStartPositions!.get(e.id) ?? { x: e.x, y: e.y }

    // Snap math uses ORIGINAL positions + delta (not live `el.x`).
    const minX = Math.min(...selected.map((e) => originalPos(e).x + delta.dx))
    // ... etc ...

    for (const el of selected) {
      const orig = originalPos(el)
      void workspacesStore.updateDesignElementGeometry(
        workspaceId, itemId, pageId, el.id,
        { x: Math.round(orig.x + finalDx), y: Math.round(orig.y + finalDy) },
      )
    }
  }
}

const handleDragEnd = (): void => {
  // CRITICAL: reset the snapshot between drags. PR #144 (undo/redo)
  // removed the previous `clearSnapGuides → dragStartPositions = null`
  // pattern by replacing it with this `handleDragEnd`, which did
  // NOT include the reset. Without the reset, the SECOND consecutive
  // drag reuses the FIRST drag's snapshot → element lags cursor by
  // `firstDelta` design-px on the second drag.
  dragStartPositions = null
  // ... rest of post-state capture + snapGuides clear ...
}
```

The fix mirrors the single-element drag's pattern: `start.x + dx` where
`start` is captured at drag start and never re-read.

## Footgun: PR #144 silently broke the reset

The original fix reset `dragStartPositions = null` inside a function
called `clearSnapGuides`, which was the `@drag-end` handler in the
template. PR #144 (`feat(design): undo/redo for design mode`)
replaced `clearSnapGuides` with a new function `handleDragEnd` to
hook into the gesture-boundary capture. The new function focused on
the history composable and forgot to reset `dragStartPositions`.

The first regression test (mid-drag SSE re-fetch) still passed, so
the breakage was invisible until a second consecutive drag was
exercised — the second drag PATCH math now uses the FIRST drag's
baseline, so the element ends up at `firstOriginal + secondDelta`
(correct relative motion, wrong absolute position from cursor).

A second regression test ("group drag RESETS the original-position
snapshot between consecutive drags") was added in the 2026-07-30
follow-up commit. It performs two drags back-to-back, mutates the
prop between them to simulate the SSE update, and asserts the second
drag's final PATCH uses the SECOND drag's original position
(expected `{x: 330, y: 270}`, bug returns `{x: 280, y: 240}` =
`firstOriginal + secondDelta`).

**Lesson for future maintainers:** when refactoring a `@drag-end`
or any other handler that owns reset semantics, search the file for
`dragStartPositions` and any other state-initializing reads inside
the handler being replaced. The new handler must preserve every
state mutation — including ones that aren't obviously related to
the new feature being added.

## Why the existing test didn't catch it

The existing test in `DesignView.groupDrag.spec.ts` simulates a single
pointermove from (100,100) to (150,130) — no SSE re-fetch happens
between pointerdown and pointerup. So `el.x` stays at the original 0
throughout the drag, and the buggy formula `el.x + delta = 50` happens
to give the correct answer.

The reproduction requires:
1. First pointermove (PATCH goes out).
2. SSE re-fetch updates `elements.value` with the new server positions.
3. Second pointermove (PATCH should use original positions, not SSE'd ones).

The new test simulates step 2 by mutating `props.item.design_elements`
directly between pointermoves. Without the fix, the test asserts
`x=100, y=60` but the actual PATCH is `x=150, y=90` (proving the bug).

## Why this bites (the same shape of bug can hit other handlers)

Any handler that applies a delta to a live store value will compound
on every store update. Look for:
- `el.x + delta` where `delta` is the cursor's offset from drag start.
- `parent.x + childOffset` where `parent` is read from a live store.
- `currentValue + accumulatedDelta` where `accumulatedDelta` accumulates
  across async updates.

The fix pattern is the same: capture the original value at the start
of the operation, use the snapshot for the math, reset on operation
end.

## Where to look (the same shape in other parts of the codebase)

- `expandSelectionWithDescendants` reads `parent_id` from `elements.value`
  — but only for the UE-aware set expansion, not for the PATCH math.
  Same risk if a future change moves descendants to a live store.
- The `nudgeOffsets` Map in `DesignView.vue` is the same pattern
  applied correctly: a Map of `{x, y}` per element, accumulated
  from `start.x + offset` to provide continuity across the
  store's missing reactive-update. Read the comment above the
  declaration for the full rationale.

## Verification

```bash
# 1. Confirm the test fails without the fix
git stash push src/apps/desktop/src/components/design/DesignView.vue
bunx vitest run src/__tests__/DesignView.groupDrag.spec.ts
# Expected: 1 test fails (the new "uses ORIGINAL positions" test)
# with `expected { x: 150, y: 90 } to deeply equal { x: 100, y: 60 }`

# 2. Restore the fix
git stash pop
bunx vitest run src/__tests__/DesignView.groupDrag.spec.ts
# Expected: 3 tests pass

# 3. Full test suite (the new test is the only design-drag change)
bunx vitest run
# Expected: 1606/1607 pass (1 pre-existing nudge test failure unrelated)
```

The bug only manifests during `groupDrag` (multi-select or single
group/frame element). The single-element drag is unaffected because
`DesignElement.vue::startDrag` captures `start.x` at pointerdown and
uses `start.x + dx` (the correct pattern).

## Cross-platform / cross-tool

This is a frontend-only bug. The backend stores what the frontend
sends and emits the SSE event — the formula is the client's problem.
No Zig changes needed.

## Reference

- Fix: `src/apps/desktop/src/components/design/DesignView.vue`
  - `handleGroupDrag` (line ~1202) — added `dragStartPositions` snapshot
  - `clearSnapGuides` (line ~1338) — reset snapshot on dragEnd
- Test: `src/apps/desktop/src/__tests__/DesignView.groupDrag.spec.ts`
  - New test "group drag uses ORIGINAL positions (not stale SSE'd
    positions) after a mid-drag SSE re-fetch" — captures the bug
    with a fake SSE update between pointermoves.
- Plan: `docs/superpowers/plans/2026-07-29-design-drag-element-move-too-fast.md`
- Spec: `docs/SPEC.md` §3.8 (Design Canvas — drag fix)
- Branch: `worktree/design-drag-element-move-too-fast`
