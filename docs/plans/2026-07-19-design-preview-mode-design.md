# Design Mode — Preview/Edit Mode Toggle (interactive HTML)

**Date:** 2026-07-19
**Branch:** `worktree/design-preview-mode`
**Scope:** A single new mode toggle. The user can switch the canvas into "Preview" mode where each element's iframe becomes interactive (typing into `<input>`, clicking buttons), without persistent state between elements.

---

## Problem

The canvas today is edit-only. The iframe inside each element has `pointer-events: none` (see `DesignElement.vue:336`) so all clicks fall through to the parent wrapper, which owns drag/resize/select. That makes typing into a `<input>` inside the iframe impossible during editing — clicks on the input select the element instead.

The user's `Design Chat` task produces static HTML mockups (e.g. a Task Detail dialog with form fields). To actually try out the mockup — type into "Task Name", toggle "Unattended mode", click "Save" — they have to leave the canvas and open the HTML file in another tool. The "Click this card → open dialog" mockup is static; clicks don't connect anything.

## Goal

Add a Preview/Edit mode toggle that lets the user interact with their HTML designs directly on the canvas. **No persistent state** — what they type is gone the moment they exit Preview (the iframe reloads with the saved HTML). This is intentionally local; cross-element wiring (Figma's prototype connections) is a separate feature.

## Non-Goals (deferred)

- **Cross-element wiring / prototype connections** (click X → open Y). Needs a data model for `on_click_target_id` + a drawing UX. Out of scope here.
- **State persistence** (typed values survive mode-switch). The iframe reloads from the saved HTML on every Preview entry; form values are ephemeral.
- **Animations / transitions** between elements (Figma's "Smart Animate"). Out of scope.
- **Frame clipping / coord-relative children.** Both depend on the `parent_id` work landing first (PR #115). Not in scope for this branch.

## Architecture

### Three pieces, minimal surface area:

**1. State** — `isPreviewMode: Ref<boolean>` lives in `DesignView.vue` (parent of all elements). Default `false`. Not persisted across page reloads — a transient mode.

**2. Toggle button** — top-right of the canvas header bar, next to the zoom toolbar. Two states:
- Edit mode (default): shows `▶ Preview` (or a "play" icon)
- Preview mode: shows `■ Edit` (or a "stop" icon) with a tinted background to make the active state obvious

Keyboard shortcut: `Cmd/Ctrl+P` toggles. `Esc` exits Preview (returns to Edit). Documented in the toggle button's `title` attribute.

**3. Prop drill** — `isPreviewMode` flows down to every `<DesignElement>` and to `<PropertiesPanel>`. Two effects when `true`:
- `DesignElement.vue` passes `pointer-events="auto"` (was `none`) to its inner `<DesignElementPreview>`. The iframe captures clicks. The wrapper div's drag handler (`@pointerdown`) is suppressed in Preview mode — clicks no longer start a drag.
- The selection chrome (resize handles, selection outline) is hidden in Preview mode even when `selected === true`. The user can't accidentally drag an element while "playing" the prototype.
- `<PropertiesPanel>` shows a banner ("Previewing — press Esc to exit") instead of the form fields.

### Layer toggle (each affected component):

| Component | Edit mode (default) | Preview mode |
|---|---|---|
| `DesignElementPreview.vue` iframe | `pointer-events: none` (clicks pass to wrapper) | `pointer-events: auto` (clicks stay in iframe) |
| `DesignElement.vue` wrapper div | drag/resize/select work normally | drag/resize suppressed |
| `DesignElement.vue` resize handles | show when `selected === true` | hidden |
| `DesignElement.vue` selection outline | show when `selected === true` | hidden |
| `PropertiesPanel.vue` | form fields visible | banner: "Previewing — press Esc to exit" |
| `LayersPanel.vue` | reorder buttons enabled | reorder buttons disabled (still readable) |
| `DesignView.vue` "+ Element" button | enabled | hidden |
| `DesignView.vue` element selection (clicking the canvas) | works | suppressed (clicks stay in iframes; the wrapper div never receives them) |

### Sidebar visibility decision

- **PropertiesPanel**: replaced by a banner — the form fields are meaningless when previewing (the user is interacting with the mockup, not editing its metadata).
- **LayersPanel**: kept visible but dimmed. The user might want to verify which element they're hovering over; hiding it entirely would lose that context. Reorder/delete buttons are disabled but the tree structure remains.
- **Page tabs**: kept visible. The user might want to switch pages while in Preview — clicking a different page tab just reloads the canvas with that page's elements (Preview mode is per-design-view, not per-page).

### Pan/zoom behavior in Preview

Keep the existing canvas pan (Space + drag) and zoom (Ctrl + wheel) working in Preview mode. Pan doesn't conflict with iframe interactivity — it's a different gesture. Zoom is also fine — the iframes scale with the canvas.

## Data Model Contract

**None.** This feature is purely UI state. No new columns, no new tables, no schema changes. The HTML the user types in Preview is ephemeral — it lives in the iframe's local DOM only.

If the user wants to keep their form values (or any other state), they hit "Save" in the mockup (which fires whatever event the mockup listens for) — but nalar doesn't subscribe to that. Saving the HTML body to disk would go through `update_element(id, html=...)`, which is what the user does explicitly via the PropertiesPanel today.

## Implementation Outline

**Files to change (small, surgical):**

- `src/apps/desktop/src/components/design/DesignView.vue` — add `isPreviewMode` ref, toggle button in header bar, Cmd/Ctrl+P keyboard shortcut, Esc to exit, pass `previewMode` prop to all children, hide "+ Element" button + page-size inputs in Preview.
- `src/apps/desktop/src/components/design/DesignElement.vue` — accept `previewMode` prop. When `true`: pass `pointer-events="auto"` to `<DesignElementPreview>`, suppress drag handler, hide resize handles + selection outline.
- `src/apps/desktop/src/components/design/PropertiesPanel.vue` — accept `previewMode` prop. When `true`: render a banner ("Previewing — press Esc to exit") instead of the form. (Doesn't touch the Monaco editor path; that's for editing, not previewing.)
- `src/apps/desktop/src/components/design/LayersPanel.vue` — accept `previewMode` prop. When `true`: disable reorder buttons (still show tree).
- `src/apps/desktop/src/__tests__/LayersPanel.spec.ts` — add a static-contract test for the new prop.

## Testing Strategy

**Static-contract tests** (matching the project's pattern):
- `LayersPanel.spec.ts` — verify `previewMode` prop is plumbed + reorder buttons are disabled when `previewMode={true}`.

**Manual smoke test (in PR description):**
1. Open a design item with elements that have interactive HTML (e.g. a frame containing `<input>` + `<button>` elements).
2. Click "Preview" in the canvas header. Verify:
   - Resize handles + selection outline disappear on the selected element
   - The "+ Element" button is hidden
   - The Properties panel shows the "Previewing — press Esc to exit" banner
   - Typing in the iframe's `<input>` actually types
   - Clicking the iframe's `<button>` fires its onclick handler
3. Press Esc → returns to Edit mode. Verify the typed values are gone (iframe reloaded from saved HTML).

## Rollout

- **No DB migration.** UI-only feature.
- **No data backfill.** Existing designs continue to render identically (Preview is opt-in via the toggle).
- **Forward compatible.** Future prototype-connection work (cross-element wiring) can build on the Preview-mode UI without changes here.

## Risks

| Risk | Mitigation |
|---|---|
| User clicks "+ Element" accidentally during Preview | Button is hidden in Preview mode |
| User drags an element while in Preview (iframe's `pointer-events: auto` doesn't stop the parent drag handler if it's listening on the same element) | Suppress the parent's `startDrag` handler when `previewMode === true` |
| Iframe captures a click the user meant for selection | Selection is the Edit-mode affordance; Preview mode is explicitly "play, don't edit". The chrome change makes this obvious. |
| Cmd+P conflicts with browser's Print shortcut | Use `Cmd/Ctrl+Shift+P` instead? Or override the browser default in canvas context. Going with `Cmd/Ctrl+P` first — users will tell us if it conflicts. Documented in the PR. |
| Monaco editor in Properties panel becomes interactive in Preview | The PropertiesPanel shows a banner (not the form/Monaco) in Preview mode. The Monaco editor isn't rendered. |

## File-Level Touch List

- `src/apps/desktop/src/components/design/DesignView.vue` — state + toggle button + shortcuts
- `src/apps/desktop/src/components/design/DesignElement.vue` — accept previewMode, conditionally enable iframe interactivity + suppress chrome
- `src/apps/desktop/src/components/design/PropertiesPanel.vue` — accept previewMode, show banner
- `src/apps/desktop/src/components/design/LayersPanel.vue` — accept previewMode, dim reorder
- `src/apps/desktop/src/__tests__/LayersPanel.spec.ts` — static-contract test for new prop

## Out of Scope (deferred follow-ups)

These are separate features, intentionally deferred:

1. **Prototype connections** (click X → navigate to Y). Needs `on_click_target_id` storage, drawing UX for connections, validation. ~3-4 days.
2. **Cross-iframe state** (form data passed to confirmation page). Needs a proto-DSL. ~2-3 days.
3. **Preview state persistence** (localStorage or per-element). Tiny but requires deciding semantics (per-element vs per-design). Skip for now.
