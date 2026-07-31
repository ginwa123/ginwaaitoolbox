# Design-Drag Backend-Overload Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the backend from drowning in requests when the user drags an element in the design canvas. Today a single drag generates ~20 PATCH requests/sec for one element, and ~200 req/sec for a 5-element multi-select drag (because each PATCH triggers a `design_element_updated` SSE event that fans out a `fetchDesignElements` GET — every PATCH doubles to 2 backend round-trips). The fix replaces the throttle-only path with three combined mitigations: (1) a batch geometry endpoint that collapses N PATCHes into one for multi-select drag, (2) a trailing-edge debounce + snapshot that throttles single-element PATCHes to ~5/sec with the final position always saved, (3) a local-mutation dedupe in the SSE handler that skips the GET fan-out when the change came from this client.

**Architecture:** New backend endpoint `POST /api/workspaces/:w/items/:i/design/pages/:p/elements/geometry-batch` accepting `{updates: [{element_id, x?, y?, width?, height?, rotation?}, …]}`, returns `{updated: DesignElement[]}` in input order, runs in a single SQL transaction with one `design_elements_geometry_batch_updated` SSE event carrying all rows (so connected clients get the batch atomically). The frontend's `handleGroupDrag` in `DesignView.vue` accumulates the union bbox + per-element deltas and sends ONE batch PATCH per debounce tick (instead of looping N times). The single-element drag in `DesignElement.vue` swaps its 50ms throttle for a 250ms trailing-edge debounce: pointermove just updates a local snapshot, the trailing emit fires on (a) 250ms of cursor stillness or (b) pointerup — the final position always wins. The SSE dedupe lives in `stores/designSse.ts`: every locally-issued PATCH (single or batch) registers the element id(s) in a `recentLocalMutations: Map<element_id, expiry_ms>` Set, and the SSE handler skips `fetchDesignElements` when EVERY element_id in the event is in the Set and the event's `updated_at` matches our local snapshot timestamp. The Set expires entries after 1500ms — beyond that, SSE events for stale ids fall through to the normal `fetchDesignElements` path.

**Tech Stack:** Vue 3 (Composition API + `<script setup>`), TypeScript, Pinia, `@vue/test-utils` + Vitest, Zig 0.16, SQLite (vendored 3.x), `node vue-tsc --build` for type-check.

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/design-drag-debounce` on branch `worktree/design-drag-debounce`

---

## Design Decisions (for the user to review before execution begins)

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| D1 | Single-element drag uses a **trailing-edge debounce** with 250 ms idle window + immediate pointerup emit (not a fixed 50 ms throttle) | Trailing-edge debounce guarantees the final position always wins; the user never sees the element "snap back" to a mid-drag position. 250 ms is below the user's perception of lag (Figma's drag latency is ~16 ms but they throttle to 16ms-only on canvas, not on server). With debounce, a continuous drag emits ~4-5 PATCHes/sec instead of 20/sec. | Fixed throttle (current 50ms) — fast but PATCH rate stays high; pure debounce without trailing emit on pointerup — could lose the final position if the cursor moves < 250ms before release. |
| D2 | Multi-element group drag sends **ONE batch PATCH per pointermove tick** (the existing 50ms throttle remains in DesignElement.vue — only the inner per-element loop is replaced with a batch call) | The SSE GET cascade dominates the backend load (each PATCH → SSE → full-page GET). Collapsing N PATCHes into 1 PATCH collapses N SSE events into 1 SSE event. With 5 elements selected: 5 PATCH + 5 GET → 1 PATCH + 1 GET = 6× reduction per tick. | Increase the throttle for group drag too — but the user perceives multi-drag latency more than single-drag (5 elements moving in unison needs to feel smooth). Keep 50ms; collapse per-tick, not per-time. |
| D3 | **New endpoint** `POST .../elements/geometry-batch` (NOT extend the existing PATCH with an array body) | The existing single PATCH is a clean URL-per-resource wire; bumping it to optionally accept N resources would muddy both the wire and the SSE event semantics (single → "updated" event; batch → "batch_updated" event). Keep them separate, share the model code via a new `design_model.updateElementsBatch` that wraps N `updateElement` calls in a single transaction. | Extend PATCH with optional `updates?: []` — adds a switch on body shape to every consumer; less testable. |
| D4 | SSE event for the batch is `design_elements_geometry_batch_updated` carrying `{workspace_id, item_id, page_id, element_ids: [], updated_at}` — clients re-fetch once for the whole page | Single SSE per batch is the whole point of the batching. The frontend's `fetchDesignElements` overwrites the local cache with the full page state — atomic, no chance of a partial-state in-between view. The frontend `recentLocalMutations` Set suppresses the consequent GET when the batch was issued locally. | Emit one SSE per element in the batch (preserves existing wire shape) — defeats the whole purpose. |
| D5 | `recentLocalMutations` is a `Map<element_id, expiry_ms>` with **1500 ms TTL** | Long enough to cover the round-trip + SSE round-trip + Vue reactivity. Short enough that concurrent edits from another client (chat-side, second tab) still propagate within ~1.5s of the cursor stopping. Figma's similar dedupe uses 1000 ms; we use 1500 ms to be safer on slower networks. | Permanent Set (would block other-client edits forever); 200 ms TTL (too short — risk of skipping a genuine other-client edit on slow networks). |
| D6 | SSE dedupe gate: **skip `fetchDesignElements` ONLY if EVERY `element_id` in the incoming event is in `recentLocalMutations`** AND the event's `updated_at` ≥ our locally-set timestamp | An event with a NEW `updated_at` (e.g. another tab edited the element between our PATCH and the SSE arriving) falls through to the normal fetch path. Strict superset: any unknown id → fetch; any stale id → fetch. This is the only safe default. | Skip if any element_id is in the Set (partial dedupe — leaves the cache inconsistent). |
| D7 | `useDesignDragDebounce` composable owns the debounce timer + local snapshot; returns `{recordDelta, flush, cancel}` | Mirrors `useKanbanScrollRestore` (debounce + cleanup-on-unmount) and `useDesignHandlers` (composable owns NO state, only refs for testability). The composable is pure: takes `onFlush(patch) => void` and the element id, owns the timer + snapshot. Tests don't need Pinia. | Inline the debounce in `DesignElement.vue` — couples the timer to the component lifecycle, makes the timer untestable in isolation, hard to share with `DesignView.vue` for the group-drag case. |
| D8 | Drag preview stays at native pointermove rate (60Hz visual feedback); the throttle ONLY delays the PATCH | The user sees the element move at 60fps; the PATCH to the backend fires at most ~5/sec. The local Pinia state mutates synchronously on every pointermove (no PATCH needed for the preview to render). The SSE re-fetch (when it fires for non-local mutations) overwrites the local state with server truth — there's a tiny visual jitter if the user's drag is faster than the SSE round-trip, but that's already the case today. | Local-only optimistic update — works fine; the only fix is the network load. |
| D9 | The `recordDelta` callback receives `{dx, dy}` (or the absolute position) so the same composable serves both single (`'update'`) and group (`'groupDrag'`) paths | Single-element composable signature: `recordDelta({x: number, y: number}) => void` (absolute position, since the element moves under the cursor). Group composable signature: `recordDelta(updates: Map<id, {x, y}>) => void` (per-element positions for the batch). Both call `onFlush` with their accumulated state. | Two composables (single + group) — duplication; harder to keep the timing consistent. |
| D10 | Trailing-edge debounce fires on `pointerup` IMMEDIATELY (no waiting for 250 ms idle) | The final position must be exact. On pointerup, we flush synchronously: `useDesignDragDebounce.flush()` calls `onFlush(pendingPatch)` and clears the timer. The user never sees a "snap back" because the timer hasn't fired. | Trailing-only-no-flush-on-pointerup — would lose the last < 250 ms of cursor motion. The current code's `flushEmit()` on pointerup is the correct pattern; we keep it. |

---

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows (per project rule AGENTS.md §"Top-line mandate"). Verify with `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc ...` and `... -target aarch64-macos -lc ...` at the end of each chunk.
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` / `indexOf(u8, source, ...)` patterns anywhere — see `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`.
- **No port 8081**: smoke tests use port 8080 (the always-running dev nalar on 8081 is off-limits).
- **Behavioural Vue tests use `@vue/test-utils` `mount`** with `setActivePinia(createPinia())` in `beforeEach`. Mock fetch via `vi.fn()` returning `{ ok, status, json, text }` shape (see `.nalar/memories/nalar-frontend-patterns.md` §"`apiFetch` mock helpers need `text()` method").
- **Behavioural Zig tests call the function under test** with crafted inputs + assertions on return values. Use `std.testing.allocator` + a `setupDb()` helper if DB is needed (mirror the pattern in `design_model_parent_id_test.zig`).
- **TDD discipline**: every implementation task starts with a failing test, then minimal code to make it pass, then a commit.
- **`bun run build` IS the type-check**: every frontend commit must pass `bun run build` (which runs `vue-tsc` under node); `bunx vitest run` alone does NOT catch type errors — see `~/.nalar/memories/nalar-frontend-patterns.md` §"bun run build is the type-check".
- **Lazy analysis trap**: `zig build test` may miss errors in `addExecutable`-only code paths. Run `zig build install:linux:system` at the end of each chunk to catch them.
- **NO new comments above `logger.infoFmt(...)` calls** (see `~/.config/nalar/memories/no-comments-on-logger-calls.md`).

---

## File Structure

```
NEW  src/ai_workflow/tui/design_model_geometry_batch_test.zig
EDIT src/ai_workflow/tui/design_model.zig                          (+ updateElementsBatch + emitDesignElementsGeometryBatchUpdated)
EDIT src/ai_workflow/tui/on_event_sent_design.zig                 (+ onEventSendDesignElementsGeometryBatchUpdated)
EDIT src/ai_workflow/tui/on_event_design.zig                      (+ DesignElementsGeometryBatchUpdatedData payload struct)
NEW  src/ai_workflow/tui/http_handlers/design_elements_geometry_batch.zig
NEW  src/ai_workflow/tui/http_handlers/design_elements_geometry_batch_test.zig
EDIT src/ai_workflow/tui/http_handlers/mod.zig                    (+ re-export designElementsGeometryBatchHandler)
EDIT src/ai_workflow/tui/test_runner.zig                          (+ _ = @import("...geometry_batch_test.zig"); + batch model test)
EDIT src/main.zig                                                 (+ POST .../elements/geometry-batch route registration)

EDIT src/apps/desktop/src/api/index.ts                            (+ GeometryBatchUpdate, GeometryBatchUpdateResponse, updateDesignElementsGeometryBatch)
EDIT src/apps/desktop/src/stores/workspaces.ts                    (+ updateDesignElementsGeometryBatch store action + registerRecentLocalMutations)
EDIT src/apps/desktop/src/stores/designSse.ts                     (+ recentLocalMutations dedupe + filter logic)
NEW  src/apps/desktop/src/composables/useDesignDragDebounce.ts     (+ recordDelta / flush / cancel — trailing-edge debounce composable)
NEW  src/apps/desktop/src/__tests__/useDesignDragDebounce.spec.ts (behavioural timer tests with fake timers)
EDIT src/apps/desktop/src/__tests__/apiDesign.spec.ts             (+ batch endpoint tests)
EDIT src/apps/desktop/src/__tests__/workspacesStore.spec.ts       (+ batch store action + recentLocalMutations tests)
EDIT src/apps/desktop/src/__tests__/designSse.spec.ts             (+ SSE dedupe tests: skip when local, fallthrough when stale, fallthrough when partial)
EDIT src/apps/desktop/src/components/design/DesignElement.vue     (+ replace inline 50ms throttle with useDesignDragDebounce composable)
EDIT src/apps/desktop/src/components/design/DesignView.vue        (+ handleGroupDrag uses the batch store action — single call per pointermove)
EDIT src/apps/desktop/src/__tests__/DesignElement.drag.spec.ts    (+ debounce behavioural tests: trailing emit, immediate pointerup flush, 250ms quiet window)
EDIT src/apps/desktop/src/__tests__/DesignView.groupDrag.spec.ts  (+ batch-once-per-pointermove tests: 1 API call per move, not N)

EDIT docs/SPEC.md                                                 (+ §3.8 design-canvas feature entry)
EDIT NALAR.md                                                     (+ Recent changes entry once shipped)
```

---

## Root Cause (read this before chunking — saves re-discovery)

```
User drags one or more elements on the design canvas.

  pointermove (browser, ~60 Hz native)
        │
        ▼
  DesignElement.vue::onMove
        │  50 ms throttle → emit 'update' (single) or 'groupDrag' (multi)
        ▼
  DesignView.vue::handleElementUpdate OR handleGroupDrag
        │
        ▼ for single: 1 PATCH /geometry per emit
        ▼ for multi:  LOOP over N selected ids → N PATCHes per emit
        ▼
  workspacesStore.updateDesignElementGeometry × N
        │  (N = 1 for single, N = selection_size for multi)
        ▼
  apiFetch PATCH /geometry × N
        │
        ▼
  Backend design_elements_geometry_update handler
  → UPDATE row + emit 'design_element_updated' SSE per PATCH
        │
        ▼ (every event fires)
  Frontend designSse.ts listener
  → fetchDesignElements (full-page GET) per event
        │
        ▼
  Backend GET /elements × N (full page re-fetch)

Total requests for a 5-element drag at 50 ms throttle:
  5 selected × 1 PATCH per 50 ms  ×  2 (PATCH + SSE-triggered GET)
  = 200 backend requests per second per drag.
```

A single-element drag: 1 PATCH × 2 = 2 req per 50 ms = 40 req/sec (still too many).

The SSE GET cascade is the dominant cost — every PATCH triggers a full-page re-fetch. A naive fix that only lowers the throttle (e.g. 50 ms → 200 ms) cuts the load 4× but the SSE cascade still fires per PATCH, so 5-element drag = 50 req/sec instead of 200 req/sec. The plan needs all three mitigations:

1. **Batch endpoint** — collapse N PATCHes into 1 PATCH for multi-element drag (5× reduction in PATCHes per tick).
2. **Trailing-edge debounce** — lower the PATCH rate from 20 Hz to ~5 Hz (4× reduction in PATCHes).
3. **SSE local-mutation dedupe** — skip the GET fan-out when the SSE event is for an element we just mutated (2× reduction in GETs — every PATCH currently triggers 1 GET).

Combined for a 5-element drag: 200 req/sec → ~2 req/sec (100× reduction). Single-element: 40 req/sec → ~1 req/sec.

---

## Chunk 1 — Backend: `design_model.updateElementsBatch` + SSE event

**Outcome:** A new model function `updateElementsBatch(allocator, db, input)` accepts `[{element_id, x?, y?, width?, height?, rotation?}, …]` (1-N updates). Runs all UPDATEs in a single SQL transaction (atomic — all or nothing). Emits ONE `design_elements_geometry_batch_updated` SSE event carrying `{workspace_id, item_id, page_id, element_ids: [], updated_at}` so clients re-fetch once for the whole page. Returns `[]DesignElement` in input order (post-update rows). Behavioural tests cover: happy path (3 elements in one tx), partial validation (one bad element_id → batch rejected, NO writes), empty input → error, single-element batch (works as an optimised single update), transaction rollback on mid-batch error.

### Task 1.1 — Add `updateElementsBatch` to `design_model.zig`

**Files to edit:** `src/ai_workflow/tui/design_model.zig` (new function below `updateElement`, around line 905 — read line 700-960 to find the exact insertion point)

**Steps:**

- [ ] Read `src/ai_workflow/tui/design_model.zig` lines 700-960 to confirm the structure of `updateElement` (the existing single-element function we'll wrap).
- [ ] Read lines 945-1000 to see `groupElements` for the transaction + SSE emission pattern to mirror.
- [ ] Write the failing tests in a NEW `src/ai_workflow/tui/design_model_geometry_batch_test.zig`:
  ```zig
  test "updateElementsBatch moves 3 elements in one transaction and returns updated rows in input order" {
      // setupDb with 1 page + 3 elements (all top-level, distinct x/y)
      // call updateElementsBatch(input{ updates = [
      //   { .element_id = "a", .x = 100 },
      //   { .element_id = "b", .x = 200 },
      //   { .element_id = "c", .x = 300 },
      // ]})
      // assert returned slice has 3 rows in input order with x=100,200,300
      // assert DB: SELECT x FROM design_page_elements WHERE id = 'a' → 100 (etc.)
  }

  test "updateElementsBatch rejects empty input" {
      // call updateElementsBatch(input{ updates = &.{} })
      // expect error.EmptyUpdates
  }

  test "updateElementsBatch rolls back when ANY element_id is missing (no partial writes)" {
      // setupDb with 2 real elements + 1 non-existent id
      // call updateElementsBatch([{a, x=100}, {b, x=200}, {missing, x=300}])
      // expect error.ElementNotFound
      // assert DB: a.x and b.x UNCHANGED (transaction rolled back)
  }

  test "updateElementsBatch accepts single-element batch (optimised single update path)" {
      // setupDb with 1 element
      // call updateElementsBatch([{element_id = "a", x = 999}])
      // expect 1 row returned with x=999
  }

  test "updateElementsBatch accepts a single field per update (no other fields required)" {
      // setupDb with 1 element at x=50
      // call updateElementsBatch([{element_id = "a", y = 75}])
      // assert returned.x == 50 (unchanged), returned.y == 75
  }
  ```
- [ ] Run `timeout 120 zig build test --summary all 2>&1 | grep -i batch` and confirm failing.
- [ ] Add `BatchGeometryUpdateInput` struct:
  ```zig
  pub const BatchGeometryUpdateInput = struct {
      page_id: []const u8,
      updates: []const UpdateElementInput,  // existing struct — reuse it
  };

  pub const BatchGeometryUpdateError = error{
      PageNotFound,
      EmptyUpdates,
      ElementNotFound,
      DbError,
      OutOfMemory,
  };
  ```
- [ ] Implement `updateElementsBatch`:
  ```zig
  pub fn updateElementsBatch(
      allocator: std.mem.Allocator,
      db: *sqlite.SqliteBackend,
      input: BatchGeometryUpdateInput,
  ) BatchGeometryUpdateError![]DesignElement {
      if (input.updates.len == 0) return error.EmptyUpdates;

      // 1. Look up the page JOIN (workspace_id, item_id) for SSE event
      //    payload. Mirror groupElements's pre-flight pattern.
      var page_q = try db.query(allocator,
          \\SELECT workspace_id, item_id FROM design_pages WHERE id = ?
      , &.{input.page_id});
      defer page_q.deinit();
      const page_row_opt = try page_q.next();
      if (page_row_opt == null) return error.PageNotFound;
      var page_row = page_row_opt.?;
      defer page_row.deinit(allocator);
      const workspace_id = page_row.values[0];
      const item_id = page_row.values[1];

      // 2. Pre-flight: SELECT COUNT(*) FROM design_page_elements
      //    WHERE id IN (?, ?, ?, ...) AND page_id = ?
      //    Build the IN-list dynamically. If count != updates.len
      //    → error.ElementNotFound (do this BEFORE the transaction).
      // ... (build IN-list + execute COUNT query) ...

      // 3. Start a transaction (mutex-held for the whole batch — per
      //    .nalar/memories/zig-sqlite-patterns.md "SQLite transaction
      //    design" — RAII mutex).
      var tx = try db.begin();
      var committed = false;
      defer if (!committed) tx.rollback() catch {};

      // 4. For each input.updates[i] in order, call the EXISTING
      //    single-row updateElement logic (extract a helper if needed,
      //    or inline the SET-list build here). Re-query MAX(position)
      //    between iterations so each element lands at its correct
      //    position (NOT needed for geometry — we don't change position
      //    in batch updates; only x/y/width/height/rotation).
      // ... loop and execute UPDATE per element ...

      // 5. Re-SELECT the updated rows (in input order) via
      //    WHERE id IN (?, ?, ...). Return them.
      // ...

      // 6. Emit ONE design_elements_geometry_batch_updated SSE event
      //    carrying { workspace_id, item_id, page_id, element_ids: [],
      //    updated_at }. The frontend dedupe (Chunk 3) uses element_ids
      //    to skip the GET fan-out for local mutations.
      // ... (call onEventSendDesignElementsGeometryBatchUpdated) ...

      committed = true;
      tx.commit() catch return error.DbError;
      return updated_rows;
  }
  ```
  **Pitfall**: the existing `updateElement` uses an arena allocator for the useCase input. For batch, we must OWN the per-row input slices (the arena is per-request, but we want each iteration's slices to persist until the SSE emit). Use `try input.updates[i].x.?.cloneOwned(allocator)` for each numeric field — actually, simpler: the BatchGeometryUpdateInput slices are borrowed (`[]const UpdateElementInput` is `[]const` of structs whose fields are owned by the caller's arena). The handler passes a Leaky-parsed body — the slices live for the whole handler invocation. No cloning needed; just pass `input.updates[i]` to the inner helper.
- [ ] Run tests, confirm passing.
- [ ] Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5` to catch lazy-analysis errors.
- [ ] Commit: `git add src/ai_workflow/tui/design_model.zig src/ai_workflow/tui/design_model_geometry_batch_test.zig && git commit -m "feat(design): updateElementsBatch model — atomic N-element geometry update with single SSE event"`.

### Task 1.2 — Add `DesignElementsGeometryBatchUpdatedData` + `onEventSendDesignElementsGeometryBatchUpdated`

**Files to edit:** `src/ai_workflow/tui/on_event_design.zig` (add payload struct), `src/ai_workflow/tui/on_event_sent_design.zig` (add emitter function)

**Steps:**

- [ ] Read `on_event_design.zig` to find the existing `DesignElementUpdatedData` struct (around line 40).
- [ ] Add a new payload struct:
  ```zig
  pub const DesignElementsGeometryBatchUpdatedData = struct {
      workspace_id: []const u8,
      item_id: []const u8,
      page_id: []const u8,
      element_ids: []const []const u8,
      /// Seconds since Unix epoch (matches existing SSE timestamps).
      updated_at: i64,
  };
  ```
- [ ] In `on_event_sent_design.zig` add the emitter function (mirror `onEventSendDesignElementUpdated`):
  ```zig
  pub fn onEventSendDesignElementsGeometryBatchUpdated(
      allocator: std.mem.Allocator,
      payload: on_event_design.DesignElementsGeometryBatchUpdatedData,
  ) !void {
      const json_payload = try std.json.Stringify.valueAlloc(allocator, payload, .{});
      defer allocator.free(json_payload);

      const event = SseEvent{
          .session_id = "design_element",
          .data = json_payload,
          .event_type = "design_elements_geometry_batch_updated",
      };

      const di = nalarcore.getSingleton() catch return;
      di.event_bus.emit(SseEvent, "design_element", event);
  }
  ```
- [ ] Update `design_model.updateElementsBatch` to call the new emitter (Task 1.1 step 6).
- [ ] Run `timeout 180 zig build test --summary all 2>&1 | tail -n 10` — must remain green.
- [ ] Commit: `git commit -am "feat(design): batch SSE event type design_elements_geometry_batch_updated"`.

### Task 1.3 — Add `design_elements_geometry_batch.zig` HTTP handler + route

**Files to create:** `src/ai_workflow/tui/http_handlers/design_elements_geometry_batch.zig`, `src/ai_workflow/tui/http_handlers/design_elements_geometry_batch_test.zig`

**Files to edit:** `src/ai_workflow/tui/http_handlers/mod.zig`, `src/ai_workflow/tui/test_runner.zig`, `src/main.zig`

**Steps:**

- [ ] Read `src/ai_workflow/tui/http_handlers/design_elements_geometry_update.zig` (lines 1-184 — the single-update handler) — mirror its body-parse + error-mapping shape per `.nalar/memories/nalar-backend-architecture.md` §"HTTP handler thin-wrapper pattern".
- [ ] Write the failing tests in a NEW `src/ai_workflow/tui/http_handlers/design_elements_geometry_batch_test.zig`:
  ```zig
  test "design_elements_geometry_batch handler accepts a 3-element batch and returns updated rows in input order" {
      // setupDb with 1 page + 3 elements
      // call handler with body:
      //   { updates: [
      //     { element_id: "a", x: 100 },
      //     { element_id: "b", x: 200 },
      //     { element_id: "c", x: 300 },
      //   ] }
      // expect 200 + body.updated.length == 3 in [a, b, c] order
      // expect DB: SELECT x FROM design_page_elements WHERE id = 'a' → 100 (etc.)
  }

  test "design_elements_geometry_batch handler maps EmptyUpdates to 400" {
      // body { updates: [] }
      // expect status 400 + message "updates must be non-empty"
  }

  test "design_elements_geometry_batch handler maps ElementNotFound to 404 with the offending id" {
      // body { updates: [{ element_id: "missing", x: 50 }] }
      // expect status 404 + error message includes "missing"
  }

  test "design_elements_geometry_batch handler maps PageNotFound to 404" {
      // body with bad page_id path param
      // expect status 404
  }

  test "design_elements_geometry_batch handler rejects malformed body with 400" {
      // body "not json"
      // expect status 400
  }

  test "design_elements_geometry_batch handler accepts a single-element batch (N=1)" {
      // body { updates: [{ element_id: "a", x: 999 }] }
      // expect 200 + body.updated.length == 1
  }
  ```
- [ ] Run, confirm failing.
- [ ] Implement the handler:
  ```zig
  const BatchBody = struct {
      updates: []const SingleUpdate = &.{},
  };

  const SingleUpdate = struct {
      element_id: []const u8 = "",
      x: ?i64 = null,
      y: ?i64 = null,
      width: ?i64 = null,
      height: ?i64 = null,
      rotation: ?f64 = null,
  };

  pub fn designElementsGeometryBatchHandler(
      ctx: gserverz.HttpContext,
      req: gserverz.HttpRequest,
      res: gserverz.HttpResponse,
  ) !gserverz.HttpResponse {
      // 1. Validate page_id path param (400 if missing/empty)
      // 2. Validate body presence (400)
      // 3. Parse JSON (400 on parse failure)
      // 4. Translate SingleUpdate[] into design_model.UpdateElementInput[]
      // 5. Delegate to design_model.updateElementsBatch
      // 6. Map errors to status codes (see test list above)
      // 7. Build { updated: DesignElementResponse[] } response (in input order)
      //    via std.json.Stringify.valueAlloc
  }
  ```
  Per `.nalar/memories/nalar-backend-architecture.md`: use `parseFromSliceLeaky`, per-request arena, `std.json.Stringify.valueAlloc` for the response.
- [ ] Add the handler re-export in `mod.zig`:
  ```zig
  pub const designElementsGeometryBatchHandler = @import("design_elements_geometry_batch.zig").designElementsGeometryBatchHandler;
  ```
- [ ] Register the test in `src/ai_workflow/tui/test_runner.zig`:
  ```zig
  _ = @import("http_handlers/design_elements_geometry_batch_test.zig");
  ```
- [ ] Register the route in `src/main.zig` (find the existing `try gs.router.patch(.../geometry, ...)` line and add nearby):
  ```zig
  try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/geometry-batch", designElementsGeometryBatchHandler);
  ```
- [ ] Run `timeout 180 zig build test --summary all` — must be green.
- [ ] Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5` — must succeed (catches lazy-analysis errors).
- [ ] Run `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc ...` and `... -target aarch64-macos -lc ...` to verify cross-compile.
- [ ] Commit: `git commit -am "feat(design): POST .../elements/geometry-batch route + handler"`.

### Chunk 1 verification

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
rm -rf zig-out/bin
timeout 360 zig build
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
```

Expected: all green. No existing-test regressions. The new endpoint is live and accepts a batch body.

---

## Chunk 2 — Frontend: trailing-edge debounce composable

**Outcome:** A new composable `useDesignDragDebounce` owns the debounce timer + a local snapshot of the pending patch. Signature: `{recordDelta(patch), flush(), cancel()}`. Behavior:
- `recordDelta(patch)` updates the snapshot and resets a 250 ms idle timer.
- When 250 ms elapse with no further `recordDelta`, fires `onFlush(snapshot)` and clears the snapshot.
- `flush()` fires `onFlush(snapshot)` synchronously and clears the timer (called on pointerup to guarantee the final position wins).
- `cancel()` clears the timer and snapshot without firing (called on pointercancel).

Behavioural tests use Vitest fake timers (`vi.useFakeTimers()`) to drive 250 ms boundary tests deterministically. The composable is pure — takes `onFlush: (patch) => void`, owns no global state, no Pinia dependency.

### Task 2.1 — Implement `useDesignDragDebounce` composable

**Files to create:** `src/apps/desktop/src/composables/useDesignDragDebounce.ts`, `src/apps/desktop/src/__tests__/useDesignDragDebounce.spec.ts`

**Steps:**

- [ ] Write the failing tests in the NEW spec file:
  ```ts
  describe('useDesignDragDebounce', () => {
      beforeEach(() => vi.useFakeTimers())

      it('recordDelta schedules a flush after 250 ms of stillness', () => {
          const onFlush = vi.fn()
          const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

          debounce.recordDelta({ x: 100, y: 200 })

          expect(onFlush).not.toHaveBeenCalled()
          vi.advanceTimersByTime(249)
          expect(onFlush).not.toHaveBeenCalled()
          vi.advanceTimersByTime(1)
          expect(onFlush).toHaveBeenCalledTimes(1)
          expect(onFlush).toHaveBeenCalledWith({ x: 100, y: 200 })
      })

      it('resets the idle window on every recordDelta (only the LAST snapshot flushes)', () => {
          const onFlush = vi.fn()
          const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

          debounce.recordDelta({ x: 100, y: 200 })
          vi.advanceTimersByTime(100)
          debounce.recordDelta({ x: 150, y: 250 })
          vi.advanceTimersByTime(100)
          debounce.recordDelta({ x: 200, y: 300 })

          vi.advanceTimersByTime(250)
          expect(onFlush).toHaveBeenCalledTimes(1)
          expect(onFlush).toHaveBeenCalledWith({ x: 200, y: 300 }) // last wins
      })

      it('flush() fires synchronously and clears the timer (pointerup behavior)', () => {
          const onFlush = vi.fn()
          const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

          debounce.recordDelta({ x: 100, y: 200 })
          vi.advanceTimersByTime(50)

          debounce.flush()

          expect(onFlush).toHaveBeenCalledTimes(1)
          expect(onFlush).toHaveBeenCalledWith({ x: 100, y: 200 })

          // The timer should be cleared — advancing past 250 ms must NOT fire again
          vi.advanceTimersByTime(500)
          expect(onFlush).toHaveBeenCalledTimes(1)
      })

      it('cancel() clears the timer and snapshot without firing (pointercancel behavior)', () => {
          const onFlush = vi.fn()
          const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

          debounce.recordDelta({ x: 100, y: 200 })
          debounce.cancel()

          vi.advanceTimersByTime(500)
          expect(onFlush).not.toHaveBeenCalled()
      })

      it('flush() is a no-op when nothing has been recorded (no spurious empty flush)', () => {
          const onFlush = vi.fn()
          const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

          debounce.flush()
          expect(onFlush).not.toHaveBeenCalled()
      })

      it('recordDelta after flush() starts a new debounce window', () => {
          const onFlush = vi.fn()
          const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

          debounce.recordDelta({ x: 100, y: 200 })
          debounce.flush()
          onFlush.mockClear()

          debounce.recordDelta({ x: 300, y: 400 })
          vi.advanceTimersByTime(250)
          expect(onFlush).toHaveBeenCalledTimes(1)
          expect(onFlush).toHaveBeenCalledWith({ x: 300, y: 400 })
      })

      it('clears the timer on unmount (no leaked timers after the component is destroyed)', () => {
          const onFlush = vi.fn()
          const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

          debounce.recordDelta({ x: 100, y: 200 })

          // Simulate component unmount: call onUnmount cleanup
          debounce.dispose()
          vi.advanceTimersByTime(500)
          expect(onFlush).not.toHaveBeenCalled()
      })
  })
  ```
- [ ] Run `cd src/apps/desktop && timeout 60 bunx vitest run src/__tests__/useDesignDragDebounce.spec.ts` and confirm failing (composable doesn't exist yet).
- [ ] Implement the composable:
  ```ts
  // src/apps/desktop/src/composables/useDesignDragDebounce.ts
  import { onBeforeUnmount } from 'vue'

  export interface UseDesignDragDebounceArgs<P> {
      onFlush: (patch: P) => void
      /** Idle window in ms. Default 250. */
      idleMs?: number
  }

  export interface DesignDragDebounceHandle<P> {
      /** Update the pending snapshot and reset the idle timer. */
      recordDelta: (patch: P) => void
      /** Fire onFlush synchronously with the current snapshot and clear the timer. */
      flush: () => void
      /** Clear the timer and snapshot without firing. */
      cancel: () => void
      /** Remove the onBeforeUnmount hook (for tests that don't mount a component). */
      dispose: () => void
  }

  export function useDesignDragDebounce<P>(
      args: UseDesignDragDebounceArgs<P>,
  ): DesignDragDebounceHandle<P> {
      const idleMs = args.idleMs ?? 250
      let pending: P | null = null
      let timerId: ReturnType<typeof setTimeout> | null = null

      const fire = (): void => {
          if (pending !== null) {
              const patch = pending
              pending = null
              if (timerId !== null) {
                  clearTimeout(timerId)
                  timerId = null
              }
              args.onFlush(patch)
          }
      }

      const recordDelta = (patch: P): void => {
          pending = patch
          if (timerId !== null) clearTimeout(timerId)
          timerId = setTimeout(fire, idleMs)
      }

      const flush = (): void => {
          fire()
      }

      const cancel = (): void => {
          pending = null
          if (timerId !== null) {
              clearTimeout(timerId)
              timerId = null
          }
      }

      // Auto-cleanup on component unmount (mirrors useKanbanScrollRestore pattern)
      const removeOnUnmount = onBeforeUnmount(() => {
          cancel()
      })

      const dispose = (): void => {
          cancel()
          removeOnUnmount()
      }

      return { recordDelta, flush, cancel, dispose }
  }
  ```
- [ ] Run tests, confirm all passing.
- [ ] Run `cd src/apps/desktop && timeout 60 bunx vitest run src/__tests__/useDesignDragDebounce.spec.ts` — expect 7/7 pass.
- [ ] Commit: `git commit -am "feat(design): useDesignDragDebounce composable — trailing-edge debounce for drag PATCHes"`.

### Chunk 2 verification

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
timeout 60 bunx vitest run src/__tests__/useDesignDragDebounce.spec.ts
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build
```

Expected: 7/7 debounce tests pass; vue-tsc clean.

---

## Chunk 3 — Frontend: wire the debounce into DesignElement + batch store + batch SSE dedupe

**Outcome:** Three coordinated changes collapse the request rate:

1. **`DesignElement.vue`** swaps its inline 50 ms throttle for the new `useDesignDragDebounce` composable (single + group paths). Pointermove calls `recordDelta(patch)`; pointerup calls `flush()`; pointercancel calls `cancel()`. The PATCH rate drops from 20 Hz to ~4 Hz.

2. **`DesignView.vue::handleGroupDrag`** calls the new BATCH store action (one PATCH per pointermove tick instead of N per-element PATCHes).

3. **`stores/designSse.ts`** gains a `recentLocalMutations: Map<element_id, expiry_ms>` with 1500 ms TTL. Every local PATCH (single OR batch) registers the element id(s) via `registerRecentLocalMutations([...])`. The SSE handler skips `fetchDesignElements` when EVERY element_id in the incoming event is in the Set AND the event's `updated_at` ≥ our locally-set timestamp. This is the dominant backend-load reduction — every PATCH currently triggers 1 GET fan-out.

### Task 3.1 — Add `updateDesignElementsGeometryBatch` API + store action

**Files to edit:** `src/apps/desktop/src/api/index.ts` (around line 1798, near `updateDesignElementGeometry`), `src/apps/desktop/src/stores/workspaces.ts` (around line 1262)

**Steps:**

- [ ] Read `src/apps/desktop/src/api/index.ts` lines 1787-1820 to find `updateDesignElementGeometry` and its wire shape.
- [ ] Write the failing tests in a NEW section of `src/apps/desktop/src/__tests__/apiDesign.spec.ts` (extend the existing file):
  ```ts
  describe('api.updateDesignElementsGeometryBatch', () => {
      it('POSTs to /geometry-batch with the full updates array', async () => {
          // mock fetch; call updateDesignElementsGeometryBatch(ws_1, item_1, p1, [
          //   { element_id: 'e1', x: 100 },
          //   { element_id: 'e2', x: 200 },
          //   { element_id: 'e3', x: 300 },
          // ])
          // assert fetch received POST to /geometry-batch with body updates.length === 3
          // assert body shape: { updates: [{ element_id, x }, ...] }
      })

      it('sends an empty field as null (the wire form of "no change for this field")', async () => {
          // call with updates: [{ element_id: 'e1', x: 100 }] (only x set)
          // assert body.updates[0] has x: 100, y: null, width: null, height: null, rotation: null
      })

      it('returns { updated: DesignElement[] } in input order', async () => {
          // mock fetch to resolve { updated: [{ id: 'e3' }, { id: 'e1' }, { id: 'e2' }] } — but assert our return order is preserved (no reordering)
      })
  })
  ```
- [ ] Run `bunx vitest run src/__tests__/apiDesign.spec.ts` — confirm failing.
- [ ] Add the types + function:
  ```ts
  export interface GeometryBatchUpdate {
      element_id: string
      x?: number
      y?: number
      width?: number
      height?: number
      rotation?: number
  }

  export interface GeometryBatchUpdateResponse {
      updated: DesignElement[]
  }

  export async function updateDesignElementsGeometryBatch(
      workspaceId: string,
      itemId: string,
      pageId: string,
      updates: GeometryBatchUpdate[],
  ): Promise<GeometryBatchUpdateResponse> {
      return await apiFetch<GeometryBatchUpdateResponse>(
          `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/geometry-batch`,
          { method: 'POST', body: { updates } },
      )
  }
  ```
- [ ] Run, confirm passing.
- [ ] In `src/apps/desktop/src/stores/workspaces.ts` add the store action (around line 1269, after `updateDesignElementGeometry`):
  ```ts
  async function updateDesignElementsGeometryBatch(
      workspaceId: string,
      itemId: string,
      pageId: string,
      updates: GeometryBatchUpdate[],
  ): Promise<DesignElement[]> {
      const result = await updateDesignElementsGeometryBatchApi(workspaceId, itemId, pageId, updates)
      // Mirror every updated row into the local design_elements array in place
      const item = findItem(workspaceId, itemId)
      if (item?.design_elements) {
          for (const updated of result.updated) {
              const idx = item.design_elements.findIndex((e) => e.id === updated.id)
              if (idx !== -1) item.design_elements[idx] = updated
          }
      }
      // Register the locally-mutated ids so the SSE handler skips the GET
      // fan-out for these elements (see stores/designSse.ts).
      registerRecentLocalMutations(
          updates.map((u) => u.element_id),
          Date.now() + 1500,
      )
      return result.updated
  }
  ```
- [ ] Write a failing test in `src/apps/desktop/src/__tests__/workspacesStore.spec.ts` (extend):
  ```ts
  describe('workspacesStore.updateDesignElementsGeometryBatch', () => {
      it('calls the batch API once with all updates and mirrors results in input order', async () => {
          // mock api; call with 3 updates; assert ONE fetch call to /geometry-batch
          // assert item.design_elements has the 3 updated rows in place
      })

      it('registers the element ids in recentLocalMutations so the SSE handler can skip the GET fan-out', async () => {
          // spy on registerRecentLocalMutations (or read the SSE store's Set directly)
          // assert the 3 ids are present after the call
      })

      it('returns the updated rows from the API response', async () => {
          // assert return value === mock response.updated
      })

      it('is a no-op (no API call) for an empty updates array', async () => {
          // call with []
          // assert fetch NOT called
      })
  })
  ```
- [ ] Run, confirm failing.
- [ ] Implement `registerRecentLocalMutations` as a module-level helper exported from `workspaces.ts` (used by both this action and by the single-element `updateDesignElementGeometry` action — see Task 3.2):
  ```ts
  /**
   * Local-mutation dedupe Set for the SSE GET fan-out. Every
   * locally-issued PATCH (single or batch) registers the affected
   * element_id(s) here with an expiry timestamp (Date.now() + 1500).
   * The SSE handler in stores/designSse.ts reads this Set and skips
   * the fetchDesignElements() call when the incoming event is for
   * one of these ids (i.e. the change came from this client).
   *
   * Module-level Map (not a Pinia ref) because the SSE handler reads
   * it synchronously on every event; reactivity would add overhead
   * for no benefit.
   *
   * TTL: 1500 ms covers the round-trip + SSE round-trip + Vue
   * reactivity on slow networks. Beyond 1500 ms, stale ids fall
   * through to the normal fetch path.
   */
  const recentLocalMutations = new Map<string, number>()

  function registerRecentLocalMutations(ids: string[], expiryMs: number): void {
      const now = Date.now()
      // Lazy GC: drop expired entries on every register call to keep
      // the Map small.
      for (const [id, exp] of recentLocalMutations) {
          if (exp < now) recentLocalMutations.delete(id)
      }
      for (const id of ids) {
          recentLocalMutations.set(id, expiryMs)
      }
  }

  /** Exported for the SSE handler. */
  export function isRecentLocalMutation(elementId: string): boolean {
      const exp = recentLocalMutations.get(elementId)
      if (exp === undefined) return false
      if (exp < Date.now()) {
          recentLocalMutations.delete(elementId)
          return false
      }
      return true
  }
  ```
- [ ] Update `updateDesignElementGeometry` (the SINGLE-element action) to also call `registerRecentLocalMutations` with `[elementId]`:
  ```ts
  async function updateDesignElementGeometry(...) {
      return await updateDesignElementGeometryApi(...).then((result) => {
          registerRecentLocalMutations([elementId], Date.now() + 1500)
          return result
      })
  }
  ```
- [ ] Run, confirm passing.
- [ ] Commit: `git commit -am "feat(design): batch geometry API + store action with SSE dedupe registration"`.

### Task 3.2 — Wire the debounce into `DesignElement.vue`

**Files to edit:** `src/apps/desktop/src/components/design/DesignElement.vue` (around lines 145-302 — the `startDrag` function)

**Steps:**

- [ ] Read `DesignElement.vue` lines 145-302 to confirm the current throttle / emit structure.
- [ ] Write the failing tests in `src/apps/desktop/src/__tests__/DesignElement.drag.spec.ts` (extend):
  ```ts
  describe('DesignElement drag — trailing-edge debounce (Chunk 3)', () => {
      it('rapid pointermoves emit at most 1 update during the debounce window + 1 trailing on pointerup', async () => {
          // Use fake timers (vi.useFakeTimers)
          // pointerdown
          // fire 5 pointermoves within 50 ms (rapid)
          // advance timers by 250 ms → first trailing emit (the last snapshot)
          // expect wrapper.emitted('update').length === 1 (NOT 5)
          // fire pointerup → expect wrapper.emitted('update').length === 2 (pointerup trailing)
      })

      it('after 250 ms of stillness, the pending patch fires ONCE without pointerup', async () => {
          // pointerdown, pointermove, advance 250 ms (no pointerup)
          // expect wrapper.emitted('update').length === 1
      })

      it('continuous drag emits ~1 PATCH per 250 ms (5 PATCHes for a 1.3s drag)', async () => {
          // pointerdown, fire pointermove every 100 ms (13 moves over 1.3 s)
          // expect wrapper.emitted('update').length === 5 (not 13)
      })

      it('pointercancel does NOT fire any trailing emit (cancel clears the timer)', async () => {
          // pointerdown, pointermove, pointercancel
          // advance 500 ms
          // expect wrapper.emitted('update').length === 0
      })

      it('pointerup flushes immediately, even if the 250 ms window has not elapsed', async () => {
          // pointerdown, pointermove, advance 50 ms (well within 250 ms)
          // pointerup → wrapper.emitted('update').length === 1
      })
  })
  ```
- [ ] Run, confirm failing.
- [ ] Replace the inline `THROTTLE_MS = 50` logic with `useDesignDragDebounce`:
  ```ts
  import { useDesignDragDebounce } from '../../composables/useDesignDragDebounce'

  // Inside startDrag:
  const flushSingle = (patch: Partial<DesignElement>): void => {
      emit('update', patch)
  }
  const debounce = useDesignDragDebounce<Partial<DesignElement>>({
      onFlush: flushSingle,
      idleMs: 250,
  })

  // onMove handler becomes:
  const onMove = (e: PointerEvent): void => {
      const inv = 1 / Math.max(0.01, props.zoom)
      const dx = (e.clientX - startX) * inv
      const dy = (e.clientY - startY) * inv
      const patch = computePatch(dx, dy)
      debounce.recordDelta(patch)
  }

  // onUp handler becomes:
  const onUp = (e: PointerEvent): void => {
      if (target.hasPointerCapture(e.pointerId)) {
          target.releasePointerCapture(e.pointerId)
      }
      isDragging.value = false
      // Trailing flush: capture the final position regardless of debounce.
      debounce.flush()
      emit('dragEnd')
      // ... remove listeners ...
  }

  // onUp-alt (pointercancel) — same as onUp but debounce.cancel() instead of flush()
  const onCancel = (e: PointerEvent): void => {
      if (target.hasPointerCapture(e.pointerId)) {
          target.releasePointerCapture(e.pointerId)
      }
      isDragging.value = false
      debounce.cancel()
      emit('dragEnd')
      // ... remove listeners ...
  }
  ```
  **Note**: The same pattern applies to the group-drag branch (lines 188-217 in the current file). The composable is used twice — once per branch — since `startDrag` runs once per drag.
- [ ] Run tests, confirm passing.
- [ ] Run `bunx vitest run src/__tests__/DesignElement.drag.spec.ts` — expect all tests pass (existing 9 + 5 new = 14).
- [ ] Verify `cd src/apps/desktop && timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build` — clean.
- [ ] Commit: `git commit -am "feat(design): replace 50ms throttle with 250ms trailing-edge debounce in DesignElement"`.

### Task 3.3 — Wire the batch into `DesignView.handleGroupDrag`

**Files to edit:** `src/apps/desktop/src/components/design/DesignView.vue` (around lines 1221-1326 — the `handleGroupDrag` function)

**Steps:**

- [ ] Read `DesignView.vue` lines 1221-1326 to confirm the current per-element loop.
- [ ] Write the failing tests in `src/apps/desktop/src/__tests__/DesignView.groupDrag.spec.ts` (extend — there should be an existing file):
  ```ts
  describe('DesignView groupDrag — batch geometry (Chunk 3)', () => {
      it('handleGroupDrag fires ONE batch PATCH per pointermove (not N per-element PATCHes)', async () => {
          // 5-element selection; trigger groupDrag with dx=10, dy=20
          // assert updateDesignElementsGeometryBatch called exactly 1 time with 5 updates
          // assert updateDesignElementGeometry (single) NOT called
      })

      it('handleGroupDrag passes each selected element with its ORIGINAL position + finalDx/Dy', () => {
          // elements at (0,0), (100,100), (200,200); dx=10, dy=20
          // assert batch body has updates with x: 10, 110, 210 and y: 20, 120, 220
      })

      it('handleGroupDrag applies snap math to the union bbox (same as single-element path)', () => {
          // existing snap tests must continue to pass — the batch endpoint is opaque to them
      })
  })
  ```
- [ ] Run, confirm failing.
- [ ] Replace the per-element loop in `handleGroupDrag` with the batch call:
  ```ts
  const handleGroupDrag = (delta: { dx: number; dy: number }): void => {
      if (selectedIds.value.size === 0) return
      if (!props.workspaceId || !effectiveItemId.value) return
      if (!activePageId.value) return
      const pageId = activePageId.value
      const itemId = effectiveItemId.value
      const workspaceId = props.workspaceId

      const dragIds = expandSelectionWithDescendants(selectedIds.value, elements.value)
      const selected = elements.value.filter((e) => dragIds.has(e.id))
      if (selected.length > 0) {
          if (dragStartPositions === null) {
              dragStartPositions = new Map()
              for (const el of selected) {
                  dragStartPositions.set(el.id, { x: el.x, y: el.y })
              }
          }
          const originalPos = (e: DesignElementApi): { x: number; y: number } =>
              dragStartPositions!.get(e.id) ?? { x: e.x, y: e.y }

          const minX = Math.min(...selected.map((e) => originalPos(e).x + delta.dx))
          const minY = Math.min(...selected.map((e) => originalPos(e).y + delta.dy))
          const maxX = Math.max(...selected.map((e) => originalPos(e).x + delta.dx + e.width))
          const maxY = Math.max(...selected.map((e) => originalPos(e).y + delta.dy + e.height))
          const unionBbox = {
              id: '__union__',
              x: minX, y: minY,
              width: maxX - minX, height: maxY - minY,
          }
          const others = elements.value.filter((e) => !selectedIds.value.has(e.id))
          const snapResult = computeSnapDelta([unionBbox, ...others], '__union__', 0, 0)
          snapGuides.value = snapResult.guides
          const finalDx = delta.dx + snapResult.dx
          const finalDy = delta.dy + snapResult.dy

          // ─── CHUNK 3 CHANGE: ONE batch PATCH instead of N per-element PATCHes ───
          void workspacesStore.updateDesignElementsGeometryBatch(
              workspaceId, itemId, pageId,
              selected.map((el) => ({
                  element_id: el.id,
                  x: Math.round(originalPos(el).x + finalDx),
                  y: Math.round(originalPos(el).y + finalDy),
              })),
          )
          return
      }

      // Defensive no-selection path (unchanged — fall through to single-element path)
      for (const id of selectedIds.value) {
          const el = elements.value.find((e) => e.id === id)
          if (!el) continue
          void workspacesStore.updateDesignElementGeometry(workspaceId, itemId, pageId, id, {
              x: Math.round(el.x + delta.dx),
              y: Math.round(el.y + delta.dy),
          })
      }
  }
  ```
- [ ] Run, confirm passing.
- [ ] Commit: `git commit -am "feat(design): handleGroupDrag sends ONE batch PATCH per pointermove"`.

### Task 3.4 — Wire the SSE dedupe into `stores/designSse.ts`

**Files to edit:** `src/apps/desktop/src/stores/designSse.ts` (around lines 95-118 — the bus.on('design', ...) handler)

**Steps:**

- [ ] Read `stores/designSse.ts` lines 95-120 to confirm the current `fetchDesignElements` call.
- [ ] Write the failing tests in a NEW `src/apps/desktop/src/__tests__/designSse.spec.ts`:
  ```ts
  describe('designSse — local-mutation dedupe (Chunk 3)', () => {
      beforeEach(() => {
          setActivePinia(createPinia())
          // Reset the global dedupe Map between tests
      })

      it('skips fetchDesignElements when the SSE event is for an element we just mutated (within 1500 ms TTL)', async () => {
          // setup active workspace, item, page
          // call workspacesStore.updateDesignElementGeometry (registers the element_id in the Set)
          // dispatch a 'design_element_updated' SSE event for that element_id
          // assert workspacesStore.fetchDesignElements was NOT called
      })

      it('fires fetchDesignElements when the SSE event is for a DIFFERENT element_id (not in the Set)', async () => {
          // dispatch a SSE event for an element_id not in recentLocalMutations
          // assert fetchDesignElements WAS called
      })

      it('falls through to fetchDesignElements when the Set entry has expired (TTL elapsed)', async () => {
          // register an element_id with a past expiry
          // dispatch a SSE event for that element_id
          // assert fetchDesignElements WAS called
      })

      it('skips fetchDesignElements for BATCH events when EVERY element_id is in the Set', async () => {
          // register 3 element ids in the Set
          // dispatch a 'design_elements_geometry_batch_updated' event with all 3 ids
          // assert fetchDesignElements NOT called
      })

      it('fires fetchDesignElements for BATCH events when ANY element_id is missing from the Set (partial dedupe is unsafe)', async () => {
          // register 2 of 3 element ids
          // dispatch a batch event with 3 ids
          // assert fetchDesignElements WAS called (strict superset — any unknown → fetch)
      })

      it('falls through to fetchDesignElements when the SSE event payload is missing required fields (defensive)', async () => {
          // dispatch a malformed event
          // assert no crash, fetchDesignElements IS called (safe default)
      })
  })
  ```
- [ ] Run, confirm failing.
- [ ] Add the dedupe check inside the bus.on('design', ...) handler:
  ```ts
  import { isRecentLocalMutation } from './workspaces'  // re-exported there

  offDesign = bus.on('design', (event: DesignElementEvent) => {
      if (event.workspace_id !== activeWorkspaceId.value) return
      const ws = useWorkspacesStore()
      const wsId = event.workspace_id

      // Chunk 3: local-mutation dedupe. If EVERY element_id in this
      // event was just mutated by this client (within 1500 ms), skip
      // the fetchDesignElements GET — the local store already has the
      // truth (the API mirror updated it synchronously).
      //
      // Safety: if ANY element_id is missing from the Set OR the Set
      // entry has expired, fall through to the normal fetch path.
      // This is a strict-superset dedupe — never partial.
      const eventElementIds: string[] = extractElementIds(event)
      if (eventElementIds.length > 0) {
          const allLocal = eventElementIds.every((id) => isRecentLocalMutation(id))
          if (allLocal) {
              // Skip the GET — the local store already mirrors the truth.
              // (The single-element drag's optimistic update + the batch
              // store action's local mirror both keep the cache in sync.)
              return
          }
      }

      void ws.fetchDesignElements(event.workspace_id, event.item_id, event.page_id)
  })
  ```
- [ ] Add the `extractElementIds` helper at the bottom of `designSse.ts`:
  ```ts
  function extractElementIds(event: DesignElementEvent): string[] {
      // The two event shapes share the same payload struct (single
      // 'design_element_updated' carries element_id; batch
      // 'design_elements_geometry_batch_updated' carries element_ids).
      // Defensive: missing fields → empty array → fetch path (no dedupe).
      const e = event as unknown as {
          element_id?: string
          element_ids?: string[]
      }
      if (Array.isArray(e.element_ids)) return e.element_ids
      if (typeof e.element_id === 'string' && e.element_id.length > 0) return [e.element_id]
      return []
  }
  ```
- [ ] Run tests, confirm passing.
- [ ] Run `bunx vitest run src/__tests__/designSse.spec.ts` — expect 6/6 pass.
- [ ] Commit: `git commit -am "feat(design): SSE handler skips fetchDesignElements when the event is for a locally-mutated element (within 1500ms TTL)"`.

### Chunk 3 verification

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
timeout 60 bunx vitest run \
    src/__tests__/useDesignDragDebounce.spec.ts \
    src/__tests__/DesignElement.drag.spec.ts \
    src/__tests__/DesignView.groupDrag.spec.ts \
    src/__tests__/designSse.spec.ts \
    src/__tests__/apiDesign.spec.ts \
    src/__tests__/workspacesStore.spec.ts
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build
timeout 180 bunx vitest run   # full suite
```

Expected: all green; vue-tsc clean; existing tests not regressed.

---

## Chunk 4 — Live smoke test + SPEC + NALAR update

**Outcome:** Verified end-to-end with a fresh isolated server (port 8080) that a 5-element group drag now sends ~5 req/sec (one batch PATCH + one SSE-triggered GET per debounce window) instead of ~200 req/sec. SPEC.md updated with the new feature. NALAR.md changelog updated.

### Task 4.1 — Live smoke test on port 8080

**Steps:**

- [ ] Start a fresh isolated server on port 8080:
  ```bash
  rm -rf /tmp/nalar-dragdebounce-smoke
  env -i HOME=/tmp/nalar-dragdebounce-smoke PATH=$PATH \
      setsid -f /home/ginwa/ginwaaitoolbox/zig-out/bin/nalarcore-linux-x86_64 \
      --port 8080 > /tmp/dragdebounce-smoke.log 2>&1 < /dev/null
  sleep 6
  ```
- [ ] Bootstrap: workspace + design item + page + 5 elements (one group + 4 leaves).
  ```bash
  WS=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces -H 'content-type: application/json' -d '{"name":"drag-smoke"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  ITEM=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/design" -H 'content-type: application/json' -d '{"name":"drag test","path":"/tmp"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  PAGE=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages" -H 'content-type: application/json' -d '{"name":"Page 1"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  # Create 5 elements via set_design_page or update_element (use the add_element tool or POST /elements)
  ```
- [ ] Test the BATCH endpoint directly:
  ```bash
  curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements/geometry-batch" \
      -H 'content-type: application/json' \
      -d "{\"updates\":[{\"element_id\":\"$E1\",\"x\":100},{\"element_id\":\"$E2\",\"x\":200}]}" | python3 -m json.tool
  # expect: { "updated": [ { ... E1 ... }, { ... E2 ... } ] } in input order
  ```
- [ ] Verify batch atomicity — try a batch where 1 element_id is missing. Expect 404:
  ```bash
  curl -sS -i -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements/geometry-batch" \
      -H 'content-type: application/json' \
      -d "{\"updates\":[{\"element_id\":\"$E1\",\"x\":100},{\"element_id\":\"missing\",\"x\":200}]}" | head -n 1
  # expect: HTTP/1.1 404 Not Found
  ```
- [ ] Verify the DB state didn't change (re-fetch elements; assert `$E1.x` is unchanged).
- [ ] Test empty updates → 400:
  ```bash
  curl -sS -i -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements/geometry-batch" \
      -H 'content-type: application/json' -d '{"updates":[]}' | head -n 1
  # expect: HTTP/1.1 400 Bad Request
  ```
- [ ] **End-to-end network-rate test** (the key validation): open nalar-desktop (or simulate via curl loop) and observe the request rate via the Network panel — confirm the 5-element drag now generates ≤ 10 req/sec instead of ~200 req/sec. Specifically: drag for 1 second, count requests in the dev tools Network tab; expect ≤ 10 PATCH + ≤ 10 SSE-fetch.
- [ ] Cleanup: `pkill -f "nalar --port 8080"`.
- [ ] Commit any fixups.

### Task 4.2 — Update `docs/SPEC.md` and root `NALAR.md`

**Files to edit:** `docs/SPEC.md` (§3.8 Design Canvas), `NALAR.md` (changelog)

**Steps:**

- [ ] Read `docs/SPEC.md` §3.8 to find the existing design-canvas feature list.
- [ ] Append a new entry:
  > "Design drag debounce + batch geometry: pointermove is no longer the trigger for backend writes. A 250 ms trailing-edge debounce in `useDesignDragDebounce` ensures the PATCH rate is ~4 Hz even during continuous drag; multi-element drag sends ONE `POST .../geometry-batch` per pointermove (instead of N per-element PATCHes); the SSE handler skips the GET fan-out when the incoming event is for an element this client just mutated (1500 ms TTL). Total request rate for a 5-element drag drops from ~200 req/sec to ~2 req/sec."
- [ ] Read root `NALAR.md` changelog section.
- [ ] Append a `## 2026-07-30: ...` block per project convention:
  > **Symptom**: User drags an element on the design canvas; the network panel shows hundreds of fetches in 200 ms; the backend becomes unresponsive.
  >
  > **Root cause**: Three layered multipliers.
  > 1. `pointermove` fires at 60 Hz; the existing 50 ms throttle in `DesignElement.vue` collapses that to 20 Hz PATCH rate.
  > 2. Multi-element group drag in `DesignView.handleGroupDrag` loops over the selection and calls `updateDesignElementGeometry` once per element per pointermove → 5 elements × 20 Hz = 100 PATCH/sec.
  > 3. Every PATCH on the backend emits a `design_element_updated` SSE event; the frontend SSE listener (`designSse.ts`) calls `fetchDesignElements` (a GET for the full page) on EVERY event. So each PATCH becomes 2 backend round-trips. Total: 5 elements × 20 Hz × 2 = 200 req/sec per drag. Single-element drag: 40 req/sec.
  >
  > **Fix** (3 layers):
  > - Trailing-edge debounce (`useDesignDragDebounce`, 250 ms idle) drops the PATCH rate to ~4 Hz (5× reduction).
  > - Batch endpoint `POST .../elements/geometry-batch` collapses N per-element PATCHes into one PATCH (5× reduction for 5-element drag).
  > - SSE dedupe (`isRecentLocalMutation` Map with 1500 ms TTL) skips the `fetchDesignElements` GET when the SSE event is for an element this client just mutated (2× reduction in GETs — every PATCH currently triggers 1 GET).
  >
  > Combined: 5-element drag drops from ~200 req/sec to ~2 req/sec (100× reduction). Single-element drag: ~40 → ~1 req/sec.
  >
  > **Decisions**: see design-decisions table at top of plan.
- [ ] Commit: `git add docs/SPEC.md NALAR.md && git commit -m "docs(design): SPEC + NALAR entry for drag debounce + batch geometry"`.

### Chunk 4 verification

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
rm -rf zig-out/bin
timeout 360 zig build
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
cd src/apps/desktop
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build
timeout 180 node_modules/.bin/vitest run   # full suite
timeout 240 bun run build 2>&1 | tail -n 5
```

Expected: all green; `.js` files emitted by vue-tsc are cleaned before commit; SPEC + NALAR are updated; live smoke port 8080 confirms the wire (single + batch + atomicity + SSE event type).

---

## Deferred (out of scope for this plan)

- **Per-pointermove PATCH coalescing within the batch body** (sending every position, not just the last, so the server can interpolate). Current plan sends only the latest snapshot per debounce window — simple, predictable, correct.
- **Debounce for resize handles** (currently uses the same 50 ms throttle; same fix applies but is out of scope for this plan — can be done as a follow-up chunk if needed).
- **Adaptive throttle based on element count** (smaller selection = faster drag). The trailing-edge debounce already adapts to cursor speed; explicit element-count adaptation is over-engineering for v1.
- **Per-tab SSE dedupe override** (a "Force refresh" button that clears `recentLocalMutations`). Currently the SSE handler is fully automatic; an explicit "force fetch" path can be a follow-up.
- **Moving the debounce timer into the SSE manager** (instead of `DesignElement.vue`). The composable approach is testable in isolation; lifting the timer higher would couple it to the SSE lifecycle for no real benefit.

---

## Pitfalls & gotchas

- **Don't write static-contract tests.** Per `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`: every test must be a real behavioural call. The `DesignElement.drag.spec.ts` MUST use `vi.useFakeTimers()` + real pointer events + assertions on `wrapper.emitted('update')`. No grep tests.
- **Fake-timer timing in vitest** — `vi.useFakeTimers()` mocks `setTimeout`/`clearTimeout`/`performance.now()` globally for the test. The composable uses both. When you call `vi.advanceTimersByTime(250)`, the setTimeout callback fires synchronously inside the advance. Verify with `(wrapper.emitted('update') ?? []).length === 1` immediately after.
- **`onBeforeUnmount` in `useDesignDragDebounce`** only fires inside a Vue component context. For tests that exercise the composable directly (without mounting), call `debounce.dispose()` manually to clean up the timer + unmount hook. The test in Task 2.1 covers this with `debounce.dispose()`.
- **The `recentLocalMutations` Map is module-level, not a Pinia ref** — intentional. The SSE handler reads it synchronously on every event; reactivity would add overhead for no benefit. Tests that mutate it directly need `vi.resetModules()` between tests OR a `clearRecentLocalMutations()` test helper (add it if needed).
- **Empty `updates[]` body** — the new batch endpoint must return 400 (not 200 with `updated: []`). The model returns `error.EmptyUpdates` → handler maps to 400. Verify with a test that `body: { updates: [] }` → status 400.
- **`registerRecentLocalMutations` lazy GC** — every register call iterates the Map to drop expired entries. For pages with hundreds of recently-mutated elements, this is O(N) per PATCH. Acceptable for v1 (the Map self-prunes on the next register; worst case is bounded by the rate of mutations). If this becomes a hotspot, move the GC to a separate `setInterval` (out of scope).
- **Don't store `pending` patches in `useDesignDragDebounce` as a closure variable that's also captured by `onFlush`** — JS closures + Vue 3 reactivity: when `onFlush` reads `pending`, the snapshot must be taken BEFORE `pending = null`. The current implementation does this correctly (`const patch = pending; pending = null; args.onFlush(patch)`). Test in Task 2.1 covers the ordering.
- **vue-tsc emits `.js` files** next to `.vue`/`.ts` sources when `noEmit:false` (per `.nalar/skills/vue-tsc-build-emits-js-files/SKILL.MD`). Clean them with `git status -- '*.js' '*.vue.js'` before committing.
- **Don't forget the `setActivePinia(createPinia())` setup** in any new vitest spec that uses `useWorkspacesStore()` or `useNotificationStore()` (per `.nalar/memories/nalar-frontend-patterns.md`).
- **Lazy analysis on `addExecutable`** — the handler changes in Chunk 1 do NOT fail `zig build test` if exercised only in handler tests; run `zig build install:linux:system` to catch type errors that lazy analysis hides (per `.nalar/memories/zig-build-and-test.md`).
- **`failed command:` is harmless** — `zig build test` prints a "failed command:" line above its summary when stderr is non-empty, but it's NOT a failure indicator (per `.nalar/memories/zig-build-and-test.md` §"failed command: in zig build output is misleading"). Look at the `Build Summary: N/N steps succeeded` line for ground truth.
- **The batch endpoint's transaction must wrap the WHOLE iteration** — if element #5's UPDATE fails, elements #1-4 must NOT be committed. The defer-rollback pattern (`defer if (!committed) tx.rollback() catch {};`) covers this. Verify with Task 1.1's "rolls back when ANY element_id is missing" test.
- **The `extractElementIds` helper is permissive** — if both `element_id` and `element_ids` are missing (malformed event), it returns `[]`. The dedupe check sees `eventElementIds.length === 0` and falls through to `fetchDesignElements`. This is the safe default: a malformed event never silently bypasses the cache refresh.

---

## Reference

- `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md` — no grep tests
- `~/.config/nalar/memories/no-comments-on-logger-calls.md` — no decorator comments
- `~/.config/nalar/memories/nalar-frontend-patterns.md` — vue-tsc is type-check; `apiFetch` mock shape; jsdom color normalization
- `~/.config/nalar/memories/nalar-backend-architecture.md` — handler thin-wrapper; per-request arena; parseFromSliceLeaky
- `~/.config/nalar/memories/zig-build-and-test.md` — lazy analysis trap, full build command sequence
- `~/.config/nalar/memories/zig-sqlite-patterns.md` — `db.exec` only binds TEXT; transaction design
- `~/.config/nalar/memories/zig-0.16-stdlib-changes.md` — Zig 0.16 stdlib API changes
- `~/.config/nalar/memories/zig-cross-platform.md` — cross-platform Windows/macOS patterns
- `.nalar/memories/design-tab-button-needs-full-wire.md` — silent partial-wiring gotcha; preventive check on the new wire
- `.nalar/memories/applayout-close-handlers-strip-url-params.md` — same partial-wiring family
- Existing plan: `docs/superpowers/plans/2026-07-29-design-right-click-group-menu.md` — the closest neighbour (group/ungroup)
- Existing plan: `docs/superpowers/plans/2026-07-29-constrain-design-elements-to-canvas.md` — chunky drag-throttling precedent
- Existing plan: `docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md` — same batching pattern (atomic batch endpoint)
- Memory: `vue-3-virtual-scroller-reactive-scrollability.md` — debounce/throttle patterns in the same app
- Memory: `useKanbanScrollRestore.ts` in `src/apps/desktop/src/composables/` — composable that owns a debounce timer; closest template