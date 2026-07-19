# Design Mode — Layers Panel Nesting (parent_id end-to-end)

**Date:** 2026-07-19
**Branch:** `worktree/design-layers-nesting`
**Scope:** Option C — real tree in layers panel, NO canvas clipping yet.

---

## Problem

The Layers panel shows all elements on a page as a flat list, ordered only by `z_index` then `position`. The DB schema (`design_page_elements.parent_id`) and the LLM-facing tool descriptions both *suggest* that `frame` and `group` element types are containers, but:

1. The DB column is **dead code** — `DesignElement` struct doesn't read it, `DesignElementResponse` doesn't expose it, `AddElementInput` / `UpdateElementInput` don't accept it.
2. The LLM is **explicitly lied to**: the system-prompt text in `BuildDesignCanvasPrompt` says *"children are added by calling `add_element` with subsequent `position` numbers in the same group."* — that's just sort order, not parenting.
3. `LayersPanel.vue` and `DesignElement.vue` both render flat.

Result: an LLM asked to draw "an app window with 4 callouts inside it" produces 5 sibling rows. The user sees a flat layers list and can't navigate the design.

## Goal

Make nesting a first-class concept end-to-end so:

1. The LLM can call `add_element(..., parent_id=<frame_id>)` to put an element inside a frame/group.
2. `update_element(..., parent_id=...)` can re-parent an existing element (or detach via `parent_id=""`).
3. The Layers panel renders a real tree — indented children, expand/collapse triangles on parents that have children.
4. The system prompt describes nesting accurately (the lie gets replaced with the truth).
5. The canvas DOES NOT change in this iteration — children still use absolute page coords; the layers panel becomes useful for navigation without introducing a coord-transform rewrite.

## Non-Goals (deferred)

- Canvas clipping for frames (Figma-style `overflow: hidden` on `type=frame`).
- Coordinate transform for children (relative coords inside a parent).
- "Drag element into frame" UX (the canvas drag-to-reparent gesture).
- A dedicated `set_parent_element` tool (re-parenting goes through `update_element`'s new `parent_id` field).
- Multi-page drag (children must belong to the same `page_id` as their parent).

## Architecture

**Three layers, minimal surface area:**

### Layer 1 — Backend (Zig)

Wire `parent_id` through the existing element plumbing. The DB column already exists (line 546 of `design_model.zig`); the work is mostly to make it *live*:

- **`design_model.DesignElement` struct** — add `parent_id: ?[]u8 = null`. Read it in `getElement` / `listElements` (the SQL `SELECT` already returns it; just destructure).
- **`design_model.AddElementInput`** — add `parent_id: ?[]const u8 = null`. Validate: when set, the referenced element must exist, belong to the same `page_id`, and be of `type=frame` or `type=group` (reject `parent_id` pointing at a non-container, with a clear error).
- **`design_model.UpdateElementInput`** — add `parent_id: ?[]const u8 = null`. Same validation. When passed as `""` (empty string), treat as "detach" (set DB column to NULL).
- **`http_response.DesignElementResponse`** — add `parent_id: ?[]const u8` to the struct + `makeDesignElementResponse` mapper. NULL serializes as JSON `null` (not `""`), so the frontend can distinguish "no parent" from "empty string" cleanly.
- **HTTP handlers** — `design_elements_create.zig` and `design_elements_update.zig` accept `parent_id` in their bodies and pass it through to `addElement` / `updateElement`.

### Layer 2 — Frontend interface (TypeScript)

- **`src/apps/desktop/src/api/index.ts`** — add `parent_id?: string | null` to `DesignElement`. (Optional because legacy designs pre-dating this field will return `undefined`; nullable because the backend now serializes explicit `null`.)

### Layer 3 — Frontend UI (Vue)

- **`LayersPanel.vue`** — render a tree, not a list. The flat `layers` computed becomes a `tree` computed that walks the elements, builds a parent→children adjacency map, and produces a depth-first traversal. Each row gets a `depth` (0 for top-level, 1 for children of top-level, etc.) and an `isExpanded` ref per parent. Click a chevron to collapse/expand; clicking the row itself still selects. Children render at `padding-left: depth * 16px` so the visual hierarchy matches Figma.
- **`set_design_page.zig` LLM tool XML response** — `elementToXml` includes `parent_id="..."` attribute when present. Lets the LLM verify its nest during a multi-step add.
- **`build_messages_for_agent_prompt.zig`** — rewrite the misleading "children are added by calling add_element with subsequent position numbers" sentence to the truth ("set `parent_id=<parent_element_id>` to nest this element inside a frame or group; the element must be of type `frame` or `group`"). Optionally: render the existing element list as a tree (`- frame\n  - rectangle\n  - rectangle`) so the LLM sees the hierarchy it built.

## Data Model Contract

```ts
interface DesignElement {
  // ... existing 19 fields ...
  parent_id?: string | null  // NEW: id of the parent frame/group, or null for top-level
}
```

**Parent rules:**
- `parent_id` is `null` (or absent) → top-level element.
- `parent_id` points to an element with `type ∈ {frame, group}` on the SAME page → nested.
- `parent_id` pointing to anything else → 400 with `"parent_id must reference a frame or group element"`.

**Cycle prevention:**
- When `parent_id` is set, the backend rejects with 400 if the referenced element's transitive ancestors include the element being updated (prevents self-loops via any depth).
- Tested in `design_model.zig::updateElement` — when `parent_id` is provided, walk the ancestor chain.

**Delete semantics:**
- When a parent is deleted, its children's `parent_id` is automatically set to NULL (the SQL `UPDATE` runs in the same transaction as the `DELETE`).

## Testing Strategy

- **Unit tests** — `design_model_test.zig::addElement_with_parent_id`, `updateElement_set_parent`, `updateElement_rejects_self_parent`, `deleteElement_cascades_children_to_null`. Static-contract tests for the LLM tool's `parent_id` parameter.
- **Frontend tests** — `LayersPanel.spec.ts`: tree rendering with depth-based indentation, expand/collapse on chevron click, expand-state persists across re-renders. Use `mount(LayersPanel, { props: { elements: [frame, child1, child2, topLevel] } })`.
- **Smoke test** — `zig build test` stays at the baseline 1806/1813 (4 pre-existing `search_test` failures unaffected). Frontend `bun run build` clean; `bunx vitest run` green.

## Rollout

- **No DB migration.** `parent_id` already exists in `design_page_elements` (added in Migration 057). No data backfill needed: existing rows have `parent_id = NULL`, which is exactly what "no parent" means.
- **Backward compatible.** Old clients that don't know about `parent_id` ignore it. The frontend already coerces extra JSON fields to nothing.
- **Forward compatible.** Future canvas-clipping work can read the same `parent_id` column without another schema change.

## Risks

| Risk | Mitigation |
|---|---|
| LLM over-nests (puts everything in one frame) | Prompt explicitly: "frames/group are for spatial grouping; small unrelated elements should stay top-level" |
| LLM under-nests (never sets parent_id) | The system-prompt tree-listing makes existing nesting visible; copy what you see |
| Cycle prevention regresses | Unit test on `updateElement_rejects_self_parent` |
| Layers panel tree-state breaks across re-renders | `isExpanded` lives on a Map keyed by parent id, not on individual elements — survives reactive updates |
| Re-parent race during SSE update | Re-parent is atomic per `UPDATE` statement; SSE fires `element_updated` after the row is committed |

## Out of Scope (deferred to a follow-up)

- **Canvas clipping for `frame` type** — wrap frame children in a div with `overflow: hidden` and shift their `x/y` so the visual position is unchanged but the clip rect follows the frame. Big plan on its own.
- **Coordinate-relative children** — store child `x/y` as offsets from parent's top-left. Requires migration of existing absolute coords.
- **Drag-to-reparent gesture on canvas** — Alt+drop on a frame sets `parent_id`. Requires canvas hit-testing against the frame's z-order.

These together make up Option B. They're blocked on this PR landing first so the data model exists.

## File-Level Touch List (for the implementation plan)

**Backend (Zig):**
- `src/ai_workflow/tui/design_model.zig` — `DesignElement` struct, `AddElementInput`, `UpdateElementInput`, validation logic, SQL reads
- `src/ai_workflow/tui/http_handlers/http_response.zig` — `DesignElementResponse`, `makeDesignElementResponse`
- `src/ai_workflow/tui/http_handlers/design_elements_create.zig` — body parsing
- `src/ai_workflow/tui/http_handlers/design_elements_update.zig` — body parsing
- `src/modules/agent/tools/add_design_element.zig` — `parent_id` param + XML attribute
- `src/modules/agent/tools/update_design_element.zig` — `parent_id` param + XML attribute
- `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` — rewrite the misleading text + optional tree listing

**Frontend (Vue + TypeScript):**
- `src/apps/desktop/src/api/index.ts` — `parent_id?: string | null` on `DesignElement`
- `src/apps/desktop/src/components/design/LayersPanel.vue` — tree rendering, expand/collapse

**Tests:**
- `src/ai_workflow/tui/design_model_test.zig` — new test cases
- `src/modules/agent/tools/add_design_element_test.zig` — `parent_id` schema check
- `src/modules/agent/tools/update_design_element_test.zig` — `parent_id` schema check
- `src/apps/desktop/src/__tests__/LayersPanel.spec.ts` — tree rendering (new file)