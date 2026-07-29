# Constrain Design Elements to the Canvas Background

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the canvas background an *enforced* boundary for every design element. Today, elements can be positioned (or dragged, or typed) freely outside the page rectangle — e.g. `context-panel-2` at `x=890, y=1098, w=440, h=900` on a 1440×1024 page. After this fix, every write path (REST, LLM tool, drag, arrow-key nudge, PropertiesPanel input) clamps `x` and `y` so the element stays on-canvas (with the existing 10-px sliver rule preserved for partial overlap).

**Architecture:** Backend-first clamp (source of truth) + frontend defense-in-depth. New `design_model.clampToCanvasBounds` helper (Zig) and `clampToCanvas` pure function (TS) implement the same algorithm. Applied at all four write paths in `design_model.zig`: `addElement`, `updateElement`, `groupElements` (union bbox of children → clamp the parent), and the cascade into the REST handlers + LLM tool wrappers. Frontend clamps at `workspacesStore.updateDesignElementGeometry` (defense) and `PropertiesPanel.handleNumericChange` (immediate UX while typing). Existing drag/nudge clamps in `DesignView.vue` stay as-is (they already use the same algorithm).

**Tech Stack:** Zig 0.16 (backend), Vue 3 + TypeScript + Pinia (frontend), SQLite (no schema change). Cross-platform support: Linux + macOS + Windows.

---

## Global Constraints

- Existing cross-platform + Zig 0.16 + Vue 3 constraints from `AGENTS.md` apply unchanged.
- **Every feature must work on Linux, macOS, AND Windows.** This is a hard requirement.
- **Do NOT kill the process on port 8081** (the always-running nalar). Use 8080 for any local smoke tests.
- Use `git worktree` for parallel development. This plan targets `worktree/constrain-canvas`.
- No SQL migration is needed — the fix is pure application logic.
- The pre-commit checklist from `AGENTS.md` must pass before declaring done: `zig build test --summary all`, `zig build install:linux:system`, `rm -rf zig-out/bin && zig build`, cross-compile to Windows/macOS, `bun run build` (vue-tsc), `bunx vitest run`.

---

## Design Background (read first)

### The bug surface — six write paths, four bypass the clamp

| Path | Where | Currently clamps? | Outcome |
|---|---|---|---|
| Drag (single element) | `DesignElement.vue` → `DesignView.vue` group drag | ✅ 10px sliver (line 1032-1039) | OK |
| Drag (multi-select) | `DesignView.vue::applyGroupDragDelta` | ✅ 10px sliver (line 1032-1039) | OK |
| Arrow-key nudge | `DesignView.vue::handleKeydown` | ✅ 10px sliver (line 565-568) | OK |
| PropertiesPanel X/Y input | `PropertiesPanel.vue::handleNumericChange` | ❌ emits raw value (line 95-97) | **BUG** — user types 9999 in Y → DB stores 9999 |
| REST `PATCH /geometry` | `design_elements_geometry_update.zig::useCase` | ❌ writes whatever (line 92-102) | **BUG** — direct curl bypass |
| REST `PUT /elements/:id` | `design_elements_update.zig::useCase` | ❌ writes x/y/width/height verbatim | **BUG** — LLM tool entry + REST |
| REST `POST /elements` | `design_elements_create.zig::useCase` | ❌ writes x/y/width/height verbatim | **BUG** — initial-position bypass |
| REST `POST /elements/group` | `design_elements_group.zig::useCase` (union bbox) | ❌ writes union bbox of children | **BUG** — group's parent position unconstrained |
| LLM tool `add_element` | `tools_exec_add_element.zig` → REST | ❌ same as POST /elements | **BUG** |
| LLM tool `update_element` | `tools_exec_update_element.zig` → REST | ❌ same as PUT /elements | **BUG** |
| LLM tool `group_elements` | `tools_exec_group_elements.zig` → REST | ❌ same as POST /group | **BUG** |

The user's screenshot shows `context-panel-2` at Y=1098 on a 1024-tall page. The element was either typed into PropertiesPanel, or moved via an LLM tool call, or resized in a way that pushed the top past the bottom edge (the drag clamp allows this if width/height make the bbox large enough).

### The clamp rule (single source of truth)

For an element with width `w`, height `h`, on a page of width `W`, height `H`:

```
min_x = -(w - 10)    // left edge at -(w-10), right edge at 10
max_x = W - 10       // left edge at W-10, right edge at W-10+w
min_y = -(h - 10)
max_y = H - 10
```

After clamp: at least 10 px of the element's left OR right edge overlaps horizontally, AND at least 10 px of top OR bottom overlaps vertically. Matches the existing drag clamp exactly.

Notes:
- **Position only.** Width/height are NOT clamped — large elements can legitimately hang off the canvas (e.g., a 2000px banner on a 1440px page).
- **Sliver rule preserved.** The 10-px partial-overlap rule is intentional UX: drag is responsive (elements slide until 10 px is visible, then stop) without rejecting moves entirely. Hard-reject would be hostile UX.
- **Frame children's positions are in the frame's local coordinate system** — they don't need to be clamped against the page; only the frame's own `x/y` does. `groupElements` runs on the page's coordinate system, so the same `clampToCanvasBounds` applies.
- **Page dimensions** are fetched via `design_model.getPageById` (already exists, just not exposed in the agent tools). The clamp helper takes `(x, y, w, h, pageW, pageH)` directly — caller looks up the page.
- **Pre-existing off-canvas elements are NOT auto-migrated.** They were "valid" when written; if the user wants to bring them in, they can drag them in manually. The new clamp only applies to new writes. (Documented in `§3.8` of `docs/SPEC.md`.)

### Why backend-first

1. **Source of truth.** A 4th client (mobile, CLI, agent code we haven't written yet) might call REST directly. The backend clamp protects them all.
2. **Cheap lookup.** The page row is already loaded for SSE context. The clamp is `O(1)` math.
3. **Symmetric.** Frontend and backend use the same algorithm; the same values round-trip.

### What does NOT change

- Drag/nudge clamps in `DesignView.vue` stay as-is (same algorithm — keep them; defense in depth).
- The visual canvas border / page-rectangle rendering stays unchanged.
- The `10px` sliver rule stays.
- The `1440 × 1024` page default stays.
- Existing elements with off-canvas positions are not modified.

---

## File Structure

| File | Action | Notes |
|---|---|---|
| `src/ai_workflow/tui/design_model.zig` | EDIT | Add `clampToCanvasBounds` helper + `getPageDimensions` helper. Inject clamp calls into `addElement`, `updateElement`, `groupElements`. |
| `src/ai_workflow/tui/design_model_test.zig` | EDIT | 8 new behavioral tests for the clamp helper + clamp injection in each write path. |
| `src/ai_workflow/tui/http_handlers/design_elements_create.zig` | EDIT | Static-contract tests verifying the handler delegates to `useCase` (which now clamps). No behavior change at the handler boundary — clamp happens in the useCase. |
| `src/ai_workflow/tui/http_handlers/design_elements_update.zig` | EDIT | Same. |
| `src/ai_workflow/tui/http_handlers/design_elements_geometry_update.zig` | EDIT | Same. |
| `src/ai_workflow/tui/http_handlers/design_elements_group.zig` | EDIT | Same. |
| `src/apps/desktop/src/composables/useDesignClamp.ts` | NEW | `clampToCanvas(x, y, w, h, pageW, pageH)` pure function + unit tests. |
| `src/apps/desktop/src/composables/__tests__/useDesignClamp.spec.ts` | NEW | 6 unit tests for the pure function. |
| `src/apps/desktop/src/components/design/PropertiesPanel.vue` | EDIT | `handleNumericChange` clamps x/y before emit. Accepts `pageWidth` + `pageHeight` as props. |
| `src/apps/desktop/src/__tests__/PropertiesPanel.clamp.spec.ts` | NEW | 4 static-contract + behavioral tests locking the clamp behavior. |
| `src/apps/desktop/src/stores/workspaces.ts` | EDIT | `updateDesignElementGeometry` fetches the page's `width` + `height` and clamps before the API call. |
| `src/apps/desktop/src/__tests__/workspacesStore.clampGeometry.spec.ts` | NEW | 3 behavioral tests for the store clamp. |
| `src/apps/desktop/src/api/index.ts` | EDIT | Add `getDesignPage(pageId)` (or extend existing endpoint to return width/height — verify which is canonical). |
| `src/apps/desktop/src/components/design/DesignView.vue` | EDIT | Pass `pageWidth` + `pageHeight` to `<PropertiesPanel>` via prop. |

---

## Implementation Tasks

### Task 0 — Add `clampToCanvasBounds` + `getPageDimensions` to `design_model.zig`

> **Why this is Task 0:** every backend write path depends on these helpers.

Add to `src/ai_workflow/tui/design_model.zig`:

```zig
/// Clamp an element's (x, y) so it stays on-canvas with a 10-px
/// sliver rule (matches the existing drag/nudge clamp in
/// DesignView.vue).
///
///   left edge of canvas (x=0)                right edge (x=W)
///   ┌─────────────────────────────────────────┐
///   │       element can hang off-canvas        │
///   │       if w > W (it's clipped visually)   │
///   │                                          │
///   └─────────────────────────────────────────┘
///
///   After clamp, at least 10 px of the element's LEFT OR RIGHT
///   edge overlaps horizontally (and similarly for top/bottom).
///   The element's width/height are unchanged.
///
///   Used by addElement, updateElement, groupElements so every write
///   path respects the canvas boundary.
pub fn clampToCanvasBounds(
    x: i64, y: i64, w: i64, h: i64, page_w: i64, page_h: i64,
) struct { x: i64, y: i64 } {
    const sliver: i64 = 10;
    const min_x: i64 = -(w - sliver);          // left edge at -(w-10)
    const max_x: i64 = page_w - sliver;        // left edge at W-10
    const min_y: i64 = -(h - sliver);
    const max_y: i64 = page_h - sliver;
    return .{
        .x = std.math.clamp(x, min_x, max_x),
        .y = std.math.clamp(y, min_y, max_y),
    };
}

/// Fetch a page's width + height by id. Returns PageNotFound if
/// no such page. Both fields are returned as i64 (consistent with
/// the rest of the design_model API).
pub fn getPageDimensions(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) anyerror!struct { width: i64, height: i64 } {
    var q = try db.query(allocator,
        "SELECT dp.width, dp.height FROM design_pages dp WHERE dp.id = ?",
        &.{page_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.PageNotFound;
    defer row.deinit(allocator);
    return .{
        .width = std.fmt.parseInt(i64, row.values[0], 10) catch 0,
        .height = std.fmt.parseInt(i64, row.values[1], 10) catch 0,
    };
}
```

**Verification:** `zig build test --summary all` passes (no behavioral tests yet).

- [ ] Add `clampToCanvasBounds` and `getPageDimensions` to `design_model.zig`.
- [ ] Verify the file still compiles (`zig build install:linux:system`).

### Task 1 — `addElement` clamps x/y to canvas

In `src/ai_workflow/tui/design_model.zig::addElement` (around line 580, where x_str/y_str are built):

```zig
// BEFORE building x_str/y_str, fetch page dims and clamp input.x / input.y.
const dims = try getPageDimensions(allocator, db, input.page_id);
const clamped = clampToCanvasBounds(input.x, input.y, input.width, input.height, dims.width, dims.height);

// Use clamped.x / clamped.y instead of input.x / input.y below.
const x_str = try std.fmt.allocPrint(allocator, "{d}", .{clamped.x});
const y_str = try std.fmt.allocPrint(allocator, "{d}", .{clamped.y});
```

- [ ] Inject the clamp into `addElement`.
- [ ] Add 2 behavioral tests in `design_model_test.zig`:
  - `addElement clamps out-of-bounds x/y to canvas bounds`
  - `addElement preserves width/height even when element is larger than canvas`

### Task 2 — `updateElement` clamps x/y to canvas

In `src/ai_workflow/tui/design_model.zig::updateElement` (around line 700, after the SSE pre-lookup):

```zig
// After the ctx: ElementContext pre-lookup, fetch page dims and
// clamp any user-provided x/y before building the UPDATE SQL.
const dims = try getPageDimensions(allocator, db, ctx.page_id);
var clamped_x: ?i64 = input.x;
var clamped_y: ?i64 = input.y;
if (input.x != null or input.y != null) {
    // We need the current width/height to clamp against. Fetch the
    // existing row's w/h via getElement — cheap, single-row query.
    var existing = try getElement(allocator, db, input.element_id);
    defer freeElement(allocator, existing);
    const cl = clampToCanvasBounds(
        input.x orelse existing.x,
        input.y orelse existing.y,
        existing.width,
        existing.height,
        dims.width,
        dims.height,
    );
    clamped_x = cl.x;
    clamped_y = cl.y;
}

// Use clamped_x / clamped_y in the UPDATE SET clause below.
```

- [ ] Inject the clamp into `updateElement`.
- [ ] Add 3 behavioral tests:
  - `updateElement clamps x when x would push element off-canvas`
  - `updateElement preserves existing x when only y is in the patch`
  - `updateElement preserves existing y when only x is in the patch`

### Task 3 — `groupElements` clamps the new parent's x/y

In `src/ai_workflow/tui/design_model.zig::groupElements` (around line 954, where the union bbox is computed):

```zig
// After computing the union bbox (x, y, width, height), clamp the
// new parent's x and y to the canvas bounds before the INSERT.
const dims = try getPageDimensions(allocator, db, input.page_id);
const cl = clampToCanvasBounds(x, y, width, height, dims.width, dims.height);
const x = cl.x;
const y = cl.y;
```

- [ ] Inject the clamp into `groupElements`.
- [ ] Add 2 behavioral tests:
  - `groupElements clamps the parent's x/y to canvas when children span past the edge`
  - `groupElements preserves width/height of the union bbox (does not shrink)`

### Task 4 — Backend static-contract regression tests

For each of `design_elements_create.zig`, `design_elements_update.zig`, `design_elements_geometry_update.zig`, `design_elements_group.zig`, add one test:

```zig
test "<handler> calls design_model.addElement/updateElement/groupElements (which clamps)" {
    const source = try readSource(alloc, HANDLER_PATH);
    defer alloc.free(source);
    if (std.mem.indexOf(u8, source, "design_model.addElement") == null and
        std.mem.indexOf(u8, source, "design_model.updateElement") == null and
        std.mem.indexOf(u8, source, "design_model.groupElements") == null) {
        std.debug.print("!! {s} does NOT delegate to design_model (clamp won't apply) !!\n", .{HANDLER_PATH});
        return error.HandlerDoesNotDelegate;
    }
}
```

This locks the delegation — if a future refactor inlines the SQL in the handler (bypassing the model), the clamp breaks silently. The static-contract test catches that.

- [ ] Add 1 test in each of the 4 handler test files.

### Task 5 — Frontend `useDesignClamp` pure function

Create `src/apps/desktop/src/composables/useDesignClamp.ts`:

```ts
/**
 * Clamp an element's (x, y) so it stays on-canvas with a 10-px sliver
 * rule. Mirrors the backend `clampToCanvasBounds` in
 * `src/ai_workflow/tui/design_model.zig`. After clamp, at least 10 px
 * of the element's LEFT OR RIGHT edge overlaps horizontally (and
 * similarly for top/bottom).
 *
 * Width and height are NOT clamped — large elements can legitimately
 * hang off the canvas (clipped visually).
 */
export function clampToCanvas(
  x: number,
  y: number,
  w: number,
  h: number,
  pageW: number,
  pageH: number,
): { x: number; y: number } {
  const sliver = 10
  const minX = -(w - sliver)
  const maxX = pageW - sliver
  const minY = -(h - sliver)
  const maxY = pageH - sliver
  return {
    x: Math.max(minX, Math.min(maxX, x)),
    y: Math.max(minY, Math.min(maxY, y)),
  }
}
```

- [ ] Create the file.
- [ ] Add 6 unit tests in `__tests__/useDesignClamp.spec.ts`:
  - `clamps x > pageW - 10`
  - `clamps y > pageH - 10`
  - `clamps x < -(w - 10)` (left edge would be off-canvas)
  - `clamps y < -(h - 10)`
  - `returns input unchanged when within bounds`
  - `preserves x when y is out of bounds (and vice versa)`

### Task 6 — `PropertiesPanel.handleNumericChange` clamps x/y

In `src/apps/desktop/src/components/design/PropertiesPanel.vue`:

1. Add `pageWidth: number` + `pageHeight: number` to `Props`. Default `1440` / `1024` (matches the canvas default).

```ts
const props = withDefaults(defineProps<Props>(), {
  pageWidth: 1440,
  pageHeight: 1024,
})
```

2. Update `handleNumericChange`:

```ts
const handleNumericChange = (field: NumericField, value: number): void => {
  if (field === 'x' || field === 'y') {
    if (!singleElement.value) return
    const w = singleElement.value.width
    const h = singleElement.value.height
    const cl = clampToCanvas(
      field === 'x' ? value : singleElement.value.x,
      field === 'y' ? value : singleElement.value.y,
      w, h, props.pageWidth, props.pageHeight,
    )
    const patch: Partial<DesignElement> =
      field === 'x' ? { x: cl.x } : { y: cl.y }
    emit('update', patch)
    return
  }
  emit('update', { [field]: value } as Partial<DesignElement>)
}
```

3. In `DesignView.vue`, pass `pageWidth` + `pageHeight` to `<PropertiesPanel>`:

```vue
<PropertiesPanel
  :elements="selectedElementsArray"
  :workspace-id="workspaceId"
  :item-id="effectiveItemId"
  :page-width="canvasWidth"
  :page-height="canvasHeight"
  ...
/>
```

- [ ] Add `pageWidth` / `pageHeight` props to `PropertiesPanel`.
- [ ] Update `handleNumericChange` to clamp x/y.
- [ ] Pass `:page-width` + `:page-height` from `DesignView.vue`.
- [ ] Add 4 static-contract tests in `PropertiesPanel.clamp.spec.ts`:
  - `handleNumericChange clamps x via clampToCanvas when field is 'x'`
  - `handleNumericChange clamps y via clampToCanvas when field is 'y'`
  - `handleNumericChange does NOT clamp width / height (large elements allowed)`
  - `handleNumericChange falls through unchanged for non-geometry fields (rotation, opacity, ...)`

### Task 7 — `workspacesStore.updateDesignElementGeometry` clamps

In `src/apps/desktop/src/stores/workspaces.ts` (around line 1196):

```ts
async function updateDesignElementGeometry(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  geometry: { x?: number; y?: number; width?: number; height?: number; rotation?: number },
): Promise<DesignElement> {
  // Fetch the page + element to clamp x/y against canvas bounds.
  if (geometry.x !== undefined || geometry.y !== undefined) {
    const page = await apiGetDesignPage(workspaceId, itemId, pageId)  // NEW helper
    const el = await apiGetDesignElement(workspaceId, itemId, pageId, elementId)  // NEW helper (or reuse listPages response)
    const w = geometry.width ?? el.width
    const h = geometry.height ?? el.height
    const cl = clampToCanvas(
      geometry.x ?? el.x,
      geometry.y ?? el.y,
      w, h, page.width, page.height,
    )
    if (geometry.x !== undefined) geometry.x = cl.x
    if (geometry.y !== undefined) geometry.y = cl.y
  }
  return await updateDesignElementGeometryApi(workspaceId, itemId, pageId, elementId, geometry)
}
```

Verify which API endpoint returns a single page's `width` + `height`. The candidates:
- `GET /api/.../design/pages/:page_id` → returns `{ page: { id, name, width, height, ... }, elements: [...] }` — already exists, used by DesignView.
- The store may already have the page data (DesignView loads pages on mount) — check.

If the page is already in store state (DesignView manages it locally), the store doesn't need a new fetch — it can accept `pageWidth` + `pageHeight` as params to `updateDesignElementGeometry`. That's cleaner (avoids the extra round-trip). Implement that variant:

```ts
async function updateDesignElementGeometry(
  workspaceId, itemId, pageId, elementId,
  geometry, pageWidth = 1440, pageHeight = 1024,
) { ... }
```

Call sites pass `canvasWidth.value` + `canvasHeight.value` from DesignView. Check the current callers in `DesignView.vue` (the group drag, single-element drag, arrow-key nudge, snap guides).

- [ ] Add `pageWidth` + `pageHeight` params to `updateDesignElementGeometry` (default 1440/1024).
- [ ] Inject the clamp into the action.
- [ ] Update all 4 DesignView call sites to pass `canvasWidth.value` + `canvasHeight.value`.
- [ ] Add 3 behavioral tests in `workspacesStore.clampGeometry.spec.ts`:
  - `updateDesignElementGeometry clamps x when input exceeds pageWidth - 10`
  - `updateDesignElementGeometry clamps y when input exceeds pageHeight - 10`
  - `updateDesignElementGeometry passes width/height through unchanged`

### Task 8 — Wire `clampToCanvas` into the static-contract regression tests

Add 3 static-contract regression tests that grep the codebase for the clamp helper and verify it's wired everywhere:

```ts
// In useDesignClamp.spec.ts (or a new designClampWiring.spec.ts):

test('PropertiesPanel calls clampToCanvas for x and y', () => {
  const src = readFileSync('src/components/design/PropertiesPanel.vue', 'utf8')
  expect(src).toContain('clampToCanvas')
  expect(src).toMatch(/handleNumericChange.*field === ['"]x['"]/)
})

test('workspacesStore.updateDesignElementGeometry calls clampToCanvas', () => {
  const src = readFileSync('src/stores/workspaces.ts', 'utf8')
  expect(src).toContain('clampToCanvas')
  expect(src).toMatch(/updateDesignElementGeometry.*geometry\.x.*geometry\.y/)
})

test('DesignView passes canvasWidth + canvasHeight to <PropertiesPanel>', () => {
  const src = readFileSync('src/components/design/DesignView.vue', 'utf8')
  expect(src).toMatch(/:page-width="canvasWidth"/)
  expect(src).toMatch(/:page-height="canvasHeight"/)
})
```

These tests catch refactors that drop the clamp wiring. (Pattern matches `project-working-patterns.md` "Naming conventions for new tools / handlers / migrations".)

- [ ] Add the 3 wiring tests.

### Task 9 — End-to-end smoke verification

Smoke against port 8080 (NOT 8081 — see `AGENTS.md`):

```bash
# Start isolated server.
rm -rf /tmp/nalar-clamp-smoke && mkdir -p /tmp/nalar-clamp-smoke
env -i HOME=/tmp/nalar-clamp-smoke PATH=$PATH \
  nohup /home/ginwa/.../zig-out/bin/nalarcore-linux-x86_64 --port 8080 \
  >/tmp/nalar-clamp-smoke.log 2>&1 &
disown
sleep 4

# Create a workspace + design item + page.
WS=$(curl ... POST /api/workspaces -d '{"name":"smoke"}' | jq -r .id)
ITEM=$(curl ... POST /api/workspaces/$WS/items/design -d '{"name":"clamp test","path":"/tmp"}' | jq -r .id)
# Set a known page (1440x1024 by default).
PAGE=$(curl ... POST /api/workspaces/$WS/items/$ITEM/design/pages -d '{"name":"home"}' | jq -r .id)

# 1. Try to create an element at (10000, 10000) — should be clamped.
ELEM=$(curl ... POST /api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements \
  -d '{"name":"e1","type":"rectangle","html":"<div></div>","x":10000,"y":10000,"width":50,"height":50}' \
  | jq '.x,.y')
# Expect: x=1390 (1440-50=1390, since element w=50 → max x = 1440-10=1430, then -50+10=-40 wait...)
# Actually: clamp formula: max_x = pageW - sliver = 1440-10 = 1430. min_x = -(w-sliver) = -(50-10) = -40.
# For x=10000: clamp(10000, -40, 1430) = 1430.
# So expect x=1430, y=1014 (1024-10).

# 2. Verify the clamped value persisted:
curl ... GET /api/workspaces/$WS/items/$ITEM/design/pages/$PAGE | jq '.elements[0].x,.elements[0].y'
# Expect: 1430, 1014.

# 3. Try to drag-past-the-bottom via PATCH /geometry:
curl ... -X PATCH /api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements/$ELEM/geometry \
  -d '{"x":500,"y":99999}'
# Expect: 200 OK. Re-GET the element: y is clamped to 1014.

# 4. Group clamping: create 2 elements far apart, group them.
ELEM2=$(curl ... POST /api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements \
  -d '{"name":"e2","type":"rectangle","html":"<div></div>","x":1200,"y":900,"width":50,"height":50}' \
  | jq -r '.id')
curl ... POST /api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements/group \
  -d "{\"child_ids\":[\"$ELEM\",\"$ELEM2\"]}" | jq '.parent.x,.parent.y'
# The parent takes the union bbox (min_x=500, min_y=900, max_x=1250, max_y=950)
# i.e. x=500, y=900, w=750, h=50. Both within bounds, so no clamp visible.
# But try with children that span past the bottom:
# (already past bounds → after clamping, parent uses children's CLAMPED positions,
# so the parent is also within bounds.)

# Cleanup
SMOKE_PID=$(ps aux | grep nalarcore-linux-x86_64 | grep -v grep | awk '{print $2}')
[ -n "$SMOKE_PID" ] && kill $SMOKE_PID
```

- [ ] Run the smoke recipe.
- [ ] All 4 scenarios return clamped values; existing legitimate elements within bounds are unchanged.

### Task 10 — SPEC.md update

Append a row to `docs/SPEC.md` §3.8 (Frontend — Design Canvas):

```markdown
| `2026-07-29-constrain-design-elements-to-canvas.md` | ✅ | Canvas background enforced as a boundary — 10-px sliver rule at every write path (REST, LLM tool, drag, nudge, PropertiesPanel). Pre-existing off-canvas elements NOT auto-migrated. |
```

- [ ] Update SPEC.md.

---

## Pre-existing elements: what happens?

**Decision: do NOT auto-migrate.**

Reasoning:
1. **They were "valid" when written.** No user-visible bug at creation time — only now does the constraint become visible to the user (because they're editing the element and see "this is outside the canvas").
2. **Auto-migration changes user data.** A 2000-pixel-wide element hanging off-canvas (used as a long banner background) would be clamped on next edit, surprising the user.
3. **The user can fix manually.** Drag the element in, or type new x/y in PropertiesPanel (which now clamps correctly).
4. **Migration cost vs. benefit is low.** Most users have a few off-canvas elements; fixing them manually is fast.

Document this decision in `docs/SPEC.md` §3.8 (the row added in Task 10 above includes the note).

---

## Pitfalls

- **Don't clamp width/height.** Large elements can hang off the canvas (clipped visually). Clamping `w` would silently shrink banners, hero images, etc.
- **Don't hard-reject moves.** Drag is responsive because of the sliver rule. Hard-reject (return `error.OutOfBounds`) would be hostile UX — the element would jitter-stop at the boundary. The clamp + sliver keeps drag smooth.
- **Don't migrate existing off-canvas elements.** Documented above.
- **`std.math.clamp(min, max, value)` is `value.clamp(min, max)` in Zig 0.16.** Verify the exact signature with `zig std lib` before writing. If `std.math.clamp` doesn't exist in 0.16, use an inline `if/else` chain.
- **The clamp lookup is one extra DB query** (`getPageDimensions`). For `updateElement`, we already do an SSE pre-lookup (single SELECT). The new query is another single SELECT. Two SELECTs per drag-finalize (which is the only time `updateElement` runs for drag — pointermove uses `PATCH /geometry` which also runs `updateElement`). For the LLM tool path, it's a one-time cost. Acceptable.
- **Group children are already on-canvas (after Task 1 + 2 fix).** The group's parent x/y is computed from the union bbox, then clamped. Children's x/y are unchanged when grouped — so children don't move. Good UX.
- **Frame children's positions are in the frame's local coordinate system.** Frames do NOT have their children's positions re-clamped against the page. The clamp applies to the FRAME's `x/y` (page-coords), not the children's (frame-local coords). This is correct: the frame can be anywhere on the page, and children stay inside the frame.
- **Page resize is OUT OF SCOPE.** If the user shrinks a page from 1024 to 500, existing elements may end up off-canvas. We do NOT auto-reclamp them on page resize — that's a follow-up if requested.

---

## Verification

After all tasks complete, the pre-commit checklist from `AGENTS.md`:

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all
# Expect: 1956/1956+ pass (the existing 6 pre-existing workflow_retry_delay_test failures are unrelated)

timeout 200 zig build install:linux:system
# Binary builds; cp-to-/usr/local/bin/nalar permission error is harmless.

rm -rf zig-out/bin
timeout 240 zig build

# Cross-compile smoke:
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# Both must exit 0.

# Frontend:
cd src/apps/desktop
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build
# Expect: 0 errors. (Critical — vue-tsc catches the prop type errors.)

timeout 180 bunx vitest run
# Expect: all tests pass (existing + 16 new from this plan).

timeout 180 bun run build
# Expect: vue-tsc + vite clean.
```

End-to-end smoke (Task 9) on port 8080 must pass all 4 scenarios.

---

## Reference

- Bug source: `context-panel-2` at Y=1098 on a 1024-tall page (visible in user's screenshot).
- Existing partial clamp: `src/apps/desktop/src/components/design/DesignView.vue` lines 565-568 (nudge) and 1032-1039 (group drag).
- Backend model: `src/ai_workflow/tui/design_model.zig::addElement`, `::updateElement`, `::groupElements`.
- Backend handlers: `src/ai_workflow/tui/http_handlers/design_elements_{create,update,geometry_update,group}.zig`.
- Frontend bypass: `src/apps/desktop/src/components/design/PropertiesPanel.vue::handleNumericChange` (line 95-97) + `src/apps/desktop/src/stores/workspaces.ts::updateDesignElementGeometry` (line 1196-1216).
- LLM tools: `src/modules/agent/tools/add_design_element.zig`, `update_design_element.zig`, `group_design_elements.zig` (all call the same backend handlers).
- Plan format precedent: `docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md` (the FK plan this one mirrors in style).