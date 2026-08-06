# design z-index reorder — visual stacking fix (2026-08-06)

## Symptom (user report, task_1785988530202)

User: "design mode, index z element. how to forward or backward, the element? its our app can do that?"
Followup: "i try that and its not work".

Right-click reorder menu (Bring to front / forward / Send backward / back) + keyboard shortcuts Ctrl+]/[ ALL updated the DB z_index correctly but the canvas visual stacking didn't change.

## Root cause

`DesignElement.vue::elementStyle` did NOT include `zIndex`. For `position: absolute` elements without explicit z-index CSS, DOM order = visual stacking. Combined with the frontend's `reorderDesignElements` mirroring the response IN-PLACE (preserves array order), neither the DOM order nor the CSS z-index changed. Net: z_index changes in DB but visual stacking stays identical.

## Fix (1 line, surgical)

In `src/apps/desktop/src/components/design/DesignElement.vue` around line 163, add `zIndex: props.element.z_index` to the elementStyle returned object. CSS handles the stacking correctly. No need to sort the DOM array (which would break parent-child containment for groups/frames — children must come AFTER their parent in DOM so they render on top of the parent's iframe content).

## Tests (5 new behavioural tests)

`src/apps/desktop/src/__tests__/DesignElement.zIndexInlineStyle.spec.ts`:
1. z-index: 0 renders inline for z_index=0
2. z-index: 5 renders inline for z_index=5 (regression: must apply, not be dropped)
3. z-index: -1 renders inline for negative z_index (valid)
4. Reactively updates z-index when element.z_index changes (simulates the store mirror after Bring to front)
5. Regression guard for the existing 6 fields (left/top/width/height/transform/opacity)

All 5 tests RED on pre-fix code, GREEN after the fix.

Selector note: the wrapper has `data-testid="design-element-<id>"` (dynamic) AND static `data-design-element="true"` (line 732-733). Use `[data-design-element="true"]` for stable test selectors.

## Verification

- `bun run build` — clean (type-check passes + vite build)
- `bunx vitest run src/__tests__/DesignElement.zIndexInlineStyle.spec.ts` — 5/5 pass
- `bunx vitest run` (full suite) — 2008 pass / 14 fail. The 14 failures are PRE-EXISTING on main (AppLayout.memoriesGate ×4, AppLayout.urlPersist ×7, DesignView.nudge ×1, sidebarKanbanSortUrl ×2). Zero regressions.
- `zig build test --summary all` — 2339 pass / 6 skip / 6 fail / 1 crash / 93 leaks, IDENTICAL to main baseline.

## Files

- Modified: `src/apps/desktop/src/components/design/DesignElement.vue` (+13 lines, single behavioural change + comment block)
- New: `src/apps/desktop/src/__tests__/DesignElement.zIndexInlineStyle.spec.ts` (5 tests)

## Branch / commit

- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/fix-design-zindex-visual`
- Branch: `worktree/fix-design-zindex-visual`
- Commit: pending (this is the commit being prepared)

## Related

- Backend correctness: `src/ai_workflow/tui/design_model.zig` (listElements sorts by z_index; reorderElements updates z_index correctly). No backend changes needed.
- Frontend store: `src/apps/desktop/src/stores/workspaces.ts::reorderDesignElements` (in-place mirror is intentional — preserves array order for parent-child rendering). No changes needed.
- Frontend bug location: `src/apps/desktop/src/components/design/DesignElement.vue::elementStyle` (missing zIndex). The 1-line fix.
- Cross-project memory: `~/.config/nalar/memories/design-element-style-missing-zindex-2026-08-06.md`
