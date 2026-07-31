# Design Layer Drag-to-Join-or-Leave-Group Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to drag one OR MORE selected layers in `LayersPanel` onto a `group`/`frame` to make them children (join), drag them out of any group onto a top-level area (leave), or drag them between groups via the top-level drop zone (move-between-groups) — with visual drop targets, cycle prevention, and atomic batched backend updates.

**Architecture:** Native HTML5 drag-and-drop on `<LayerRow>` (Vue 3). The selection state already lives in `selectedIds: Set<string>` (introduced in Chunk 2 of the right-click group menu plan, 2026-07-29); the drag handler reads from it. A new `POST .../elements/reparent-batch` endpoint handles N elements atomically (single transaction, single SSE event). The single-element `PUT .../elements/:id` path also gains an OPTIONAL `reposition: 'last_in_parent'` field for use from keyboard / programmatic reparent. Cycle prevention is enforced server-side (no group-into-self, no group-into-descendant) and visualised client-side as a grey-out during drag. The whole batch is rejected if ANY element would create a cycle (atomicity). All tests are behavioural (no static-contract / source-grep).

**Tech Stack:** Vue 3 (Composition API + `<script setup>`), TypeScript, Pinia, `@vue/test-utils` + Vitest, Zig 0.16, SQLite (vendored 3.x), native HTML5 DnD (`draggable`, `dragstart`, `dragover`, `drop`, `dragend`), `node vue-tsc --build` for type-check.

**Spec:** `docs/superpowers/specs/2026-07-30-design-layer-drag-join-or-leave-group-design.md`

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/design-layer-drag-group` on branch `worktree/design-layer-drag-group`

## Design Decisions (for the user to review before execution begins)

| ID  | Decision | Why                                                                                                        | Alternative rejected                                                  |
|-----|----------|------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------|
| D1  | Drop ON a `group`/`frame` row → join (as last children, preserving the multi-selection's order)              | Matches Figma's "drag into folder" affordance; preserves relative order when dropping N elements | Drop with top/middle/bottom of group row (more precise, deferred)     |
| D2  | Drop ABOVE/BELOW a top-level row OR onto the empty area between groups → leave group / move to top-level      | Simple mental model: groups are "containers"; the area outside them is "loose"              | Only support drop-on-empty-area (forces user to drag to a specific edge) |
| D3  | Whole row is draggable (no separate drag handle)                                                               | Figma parity — the entire row is the drag handle                                             | Separate ⋮⋮ handle (extra click cost; Figma doesn't use one)          |
| D4  | **Multi-element drag IS in scope for v1.** Drag ONE selected row → ALL selected rows are dragged together (same target parent, last-children order = selection order) | Matches Figma's "drag a multi-selection" affordance; user explicitly requested it            | Single-element drag only with toast (less powerful UX)                |
| D5  | Cycle prevention is enforced server-side for BOTH the single PUT and the batch endpoint (group-into-self OR group-into-descendant → 400 BadReparent; the BATCH is all-or-nothing) | Single source of truth; matches the existing `groupElements` pattern                         | Frontend-only check (server could be bypassed via curl)                |
| D6  | Action buttons (▲▼×) on the row are NOT draggable (their `draggable=false` stops dragstart)                     | Prevents conflict: clicking × to delete doesn't start a drag                                  | Whole-row drag with implicit abort (clicks register mid-drag)         |
| D7  | Use native HTML5 DnD (no Sortable.js / vuedraggable)                                                             | Zero bundle weight, sufficient for one-at-a-time OR multi-at-a-time semantics, no version coupling | Sortable.js (40KB+, lots of config, MIT license OK but unnecessary)    |
| D8a | Single-element path: extend existing `PUT .../elements/:id` with optional `reposition: 'last_in_parent'`        | Atomic parent + position in one round-trip for the programmatic path (keyboard, undo)        | New endpoint `POST /reparent` (more surface for no extra capability)  |
| D8b | Multi-element path: NEW endpoint `POST .../elements/reparent-batch` with body `{ element_ids, new_parent_id, reposition }` — single transaction, all-or-nothing | 1 round-trip for N elements (instead of N parallel PUTs); atomic cycle rejection; one SSE event per batch | N parallel PUTs (race conditions, partial failure, N SSE events, harder to roll back) |
| D9  | Visual feedback: 50% opacity + grabbing cursor on EVERY selected row (during multi-drag), 1px violet ring + violet fill on valid drop target, 2px violet line above/below for top-level drops | Matches the existing design's violet-on-dark theme; the user sees WHICH elements will move | Subtle gray feedback (insufficient signal — user can't tell which rows or where they'll land) |
| D10 | Multi-drag dragstart reads `selectedIds` from the store (not the local row's id). If `selectedIds.size === 0`, the dragged row is the only one.                                                       | Reuses the existing multi-select state from Chunk 2 of the right-click group menu plan (2026-07-29) | Maintain a separate "drag set" ref (duplicates the existing selection state) |

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
- **Multi-drag atomicity**: when ANY element in the batch would create a cycle, the WHOLE batch is rejected (400 BadReparent). The frontend shows an error toast and the local store is unchanged.
- **Cycle prevention**: a `group`/`frame` may NOT be dropped into itself OR any of its transitive descendants. This applies to BOTH the single PUT path and the batch endpoint.

---

## File Structure

```
NEW  src/ai_workflow/tui/http_handlers/design_elements_reparent.zig
NEW  src/ai_workflow/tui/http_handlers/design_elements_reparent_test.zig
NEW  src/ai_workflow/tui/design_model_reparent_batch_test.zig
EDIT src/ai_workflow/tui/design_model.zig                           (+ `reposition` field on UpdateElementInput + cycle check + position normalization + `reparentElements` model function)
EDIT src/ai_workflow/tui/http_handlers/design_elements_update.zig  (+ `reposition` body field handling)
EDIT src/ai_workflow/tui/http_handlers/mod.zig                      (+ re-export reparentBatchHandler)
EDIT src/ai_workflow/tui/test_runner.zig                           (+ _ = @import("...reparent_test.zig"); + _ = @import("...reparent_batch_test.zig");)
EDIT src/main.zig                                                  (+ POST .../elements/reparent-batch route registration)

EDIT src/apps/desktop/src/api/index.ts                             (+ RepositionMode type, ReparentDesignElementsBatchRequest, reparentDesignElementsBatch API wrapper, reposition on UpdateDesignElementRequest)
EDIT src/apps/desktop/src/stores/workspaces.ts                     (+ reparentDesignElement (single) + reparentDesignElementsBatch (batch) store actions)
EDIT src/apps/desktop/src/composables/useDesignHandlers.ts         (+ reparentLayers(payload) — N elements, one target)
EDIT src/apps/desktop/src/components/design/LayerRow.vue           (+ draggable + dragstart/dragend/dragover/drop handlers + visual state classes)
EDIT src/apps/desktop/src/components/design/LayersPanel.vue        (+ top-level drop zone area + @reparent emit with element_ids array)
EDIT src/apps/desktop/src/components/design/DesignView.vue         (+ handleDesignReparent (N-element variant) + @reparent on <LayersPanel>)

NEW  src/apps/desktop/src/composables/useLayerDragDrop.ts          (composable: owns multi-drag state + drag/drop handlers + cycle preflight per-element)
NEW  src/apps/desktop/src/__tests__/LayerRow.dragDrop.spec.ts       (behavioural mount tests)
EDIT src/apps/desktop/src/__tests__/LayersPanel.spec.ts            (+ drop-zone rendering tests + multi-drag emit tests)
NEW  src/apps/desktop/src/__tests__/DesignView.reparent.spec.ts    (end-to-end: drag in panel → store action → api call, single + batch)
NEW  src/apps/desktop/src/__tests__/workspacesStoreReparent.spec.ts (+ single + batch store action tests)
NEW  src/apps/desktop/src/__tests__/useDesignHandlers.reparent.spec.ts (+ single + batch composable tests)
NEW  src/apps/desktop/src/__tests__/useLayerDragDrop.spec.ts        (+ multi-drag coverage)

EDIT docs/SPEC.md                                                  (+ feature entry under §3.8 Design Canvas)
EDIT NALAR.md                                                      (+ Recent changes entry once shipped)
```

---

## Chunk 1 — Backend: `updateElement` accepts `reposition` + cycle prevention (single-element path)

**Outcome:** `design_model.zig::updateElement` accepts a new optional `reposition: ?RepositionMode` field. When set to `.last_in_parent`, after the parent_id update succeeds, the element's `position` is recomputed to `MAX(sibling.position) + 1` where siblings share the new parent. When `parent_id` would create a cycle (drop a group into itself or its descendant), the model returns `error.CycleDetected` (400-mapped in the handler). The PUT handler routes the new field. Tests cover: (a) cycle rejection on parent_id = self, (b) cycle rejection on parent_id = descendant id, (c) successful reparent with `last_in_parent` recompute, (d) backward compat (no `reposition` field → behaves as today). This chunk establishes the foundation for the multi-element batch endpoint (Chunk 1b) which calls this same `updateElement` in a loop.

### Task 1.1 — Add `RepositionMode` enum + `reposition` field to `UpdateElementInput`

**Files to edit:**
- `src/ai_workflow/tui/design_model.zig` (around line 671 — `UpdateElementInput` struct + around line 605 where `ElementType` lives)

**Steps:**

- [ ] Read `src/ai_workflow/tui/design_model.zig` lines 660–710 to confirm the exact `UpdateElementInput` struct location.
- [ ] Write the failing test in a NEW file `src/ai_workflow/tui/design_model_reparent_test.zig` (mirrors `design_model_parent_id_test.zig`'s `setupDbAndItem` helper):
  ```zig
  test "updateElement accepts reposition: .last_in_parent and recomputes position" {
      // 1. setupDb with one page + 3 sibling elements (a, b, c) all parented to NULL (top-level)
      // 2. INSERT a group_id via raw SQL with parent_id = NULL
      // 3. Call updateElement(input{ .element_id = "a", .parent_id = "group_id", .reposition = .last_in_parent })
      // 4. SELECT a.position FROM design_page_elements WHERE id = 'a' — assert = 3 (max+1 of 0 siblings)
      // 5. Call updateElement again on element "b" with the same group_id
      // 6. SELECT b.position — assert = 4
  }
  ```
- [ ] Run the test: `timeout 120 zig build test --summary all 2>&1 | grep reparent` and confirm it fails (the field doesn't exist yet, expected compile error).
- [ ] Add to `UpdateElementInput`:
  ```zig
  pub const RepositionMode = enum { last_in_parent };

  pub const UpdateElementInput = struct {
      // ... existing fields ...
      parent_id: ?[]const u8 = null,
      /// Optional post-update position normalization (Chunk 1 of
      /// drag-to-reparent plan). When set, the position is recomputed
      /// after the SET list runs — useful for "drop into group" UX
      /// where the moved element should appear at the bottom of its
      /// new siblings. See design_model_reparent_test.zig.
      reposition: ?RepositionMode = null,
  };
  ```
- [ ] In the SET-list build section (after the `try args.append(allocator, v);` for `parent_id`), add the `reposition` handling logic:
  ```zig
  if (input.reposition) |mode| {
      // Compute the position AFTER the parent_id SET took effect.
      // We do this by re-querying siblings of the new parent_id.
      defer _ = mode; // currently only one variant; future variants branch here.
      const new_parent_id_sql: []const u8 = if (input.parent_id) |p| p else "";
      var max_pos_q = try db.query(allocator,
          \\SELECT COALESCE(MAX(position), -1) FROM design_page_elements
          \\WHERE (COALESCE(parent_id, '') = ? OR parent_id IS NULL) AND id != ?
      , &.{ new_parent_id_sql, input.element_id });
      defer max_pos_q.deinit();
      const max_pos_row = (try max_pos_q.next()) orelse unreachable;
      defer max_pos_row.deinit(allocator);
      const new_position_str = try std.fmt.allocPrint(allocator, "{d}", .{
          std.fmt.parseInt(i64, max_pos_row.values[0], 10) catch 0 + 1
      });
      try owned.append(allocator, new_position_str);
      try sets.append(allocator, "position = ?");
      try args.append(allocator, owned.items[owned.items.len - 1]);
  }
  ```
  Note: the SQL `WHERE COALESCE(parent_id, '') = ?` mirrors how the SQL serializer normalises NULL → '' so the comparison works for both top-level (`parent_id` NULL) and nested (parent_id = group_id) cases.
- [ ] Run the test: `timeout 120 zig build test --summary all 2>&1 | grep reparent` and confirm it now passes.
- [ ] Run `timeout 120 zig build install:linux:system 2>&1 | tail -n 5` to catch lazy-analysis errors in the executable (per `.nalar/memories/zig-build-and-test.md`).
- [ ] Commit: `git add src/ai_workflow/tui/design_model.zig src/ai_workflow/tui/design_model_reparent_test.zig && git commit -m "feat(design): updateElement accepts reposition: last_in_parent"`.

### Task 1.2 — Add cycle prevention to `updateElement`

**Files to edit:** `src/ai_workflow/tui/design_model.zig` (around the parent_id handling site in `updateElement`)

**Steps:**

- [ ] Write the failing tests in `src/ai_workflow/tui/design_model_reparent_test.zig`:
  ```zig
  test "updateElement returns CycleDetected when parent_id is the element's own id" {
      // setupDb with one page + one group at top-level
      // call updateElement on that group with parent_id = group.id
      // expect error.CycleDetected
  }

  test "updateElement returns CycleDetected when parent_id is a transitive descendant" {
      // setupDb: group_a top-level, group_b parented to group_a, leaf parented to group_b
      // call updateElement on group_a with parent_id = group_b.id (a descendant)
      // expect error.CycleDetected
  }

  test "updateElement accepts a non-cycle reparent (group_a into group_b, where group_b is unrelated)" {
      // setupDb: two top-level groups, no relation
      // call updateElement on group_a with parent_id = group_b.id
      // expect success — group_b is not under group_a
  }
  ```
- [ ] Run, confirm failing.
- [ ] Add `CycleDetected` to `UpdateElementError` (or `anyerror![]u8` if we keep it permissive):
  ```zig
  pub const UpdateElementError = error{
      ElementNotFound,
      CycleDetected,
      DbError,
      FileWriteFailed,
      OutOfMemory,
  };
  ```
- [ ] Add the cycle check helper and call it BEFORE the SQL UPDATE (mirror `groupElements`'s pre-flight pattern at line 1051-1056):
  ```zig
  pub fn hasAncestorCycle(
      db: *sqlite.SqliteBackend,
      allocator: std.mem.Allocator,
      candidate_ancestor_id: []const u8,
      candidate_descendant_id: []const u8,
  ) !bool {
      // Walks up from candidate_descendant_id following parent_id until
      // it either hits candidate_ancestor_id (cycle) or NULL (safe).
      // Use a fresh row per hop; max depth bounded by the ON DELETE CASCADE
      // rule (no infinite loops in normal DBs).
      var current: []const u8 = candidate_descendant_id;
      var depth: u32 = 0;
      while (depth < 1024) : (depth += 1) {
          var q = try db.query(allocator,
              "SELECT COALESCE(parent_id, '') FROM design_page_elements WHERE id = ?",
              &.{current});
          defer q.deinit();
          const row_opt = try q.next();
          if (row_opt == null) return false;
          var row = row_opt.?;
          defer row.deinit(allocator);
          const parent = row.values[0];
          if (parent.len == 0) return false; // walked to the root, no cycle
          if (std.mem.eql(u8, parent, candidate_ancestor_id)) return true;
          current = parent;
      }
      return false;
  }
  ```
- [ ] In `updateElement`, after the parent_id is gathered from the SET list but BEFORE the SQL UPDATE, call:
  ```zig
  if (input.parent_id) |new_pid| {
      // Self-cycle (dropping the element into itself)
      if (std.mem.eql(u8, new_pid, input.element_id)) return error.CycleDetected;
      // Descendant cycle (dropping an ancestor into one of its descendants)
      if (try hasAncestorCycle(db, allocator, input.element_id, new_pid)) {
          return error.CycleDetected;
      }
  }
  ```
- [ ] Run, confirm passing.
- [ ] Run `zig build install:linux:system` to catch lazy-analysis errors.
- [ ] Commit.

### Task 1.3 — Extend `design_elements_update.zig` handler to pass through `reposition` and map `CycleDetected` to 400

**Files to edit:** `src/ai_workflow/tui/http_handlers/design_elements_update.zig`

**Steps:**

- [ ] Read `design_elements_update.zig` to find the body parse + handler signature.
- [ ] Write the failing tests in `src/ai_workflow/tui/http_handlers/design_elements_update_test.zig` (extend the existing test file or create a new one if no test file exists):
  ```zig
  test "updateElement handler passes reposition field through to the model" {
      // call handler with body containing parent_id + reposition:"last_in_parent"
      // assert the SQL UPDATE passed to the model includes "position = ?"
  }

  test "updateElement handler maps CycleDetected to 400 BadReparent" {
      // setupDb with one group at top-level
      // call handler with body { parent_id: group.id, ... }
      // assert res.status_code == 400 and error_message contains "cycle" or "reparent"
  }
  ```
- [ ] Run, confirm failing.
- [ ] Add `reposition: ?[]const u8 = null` to the handler's body struct.
- [ ] Parse `reposition` into `?design_model.RepositionMode`:
  ```zig
  fn repositionFromString(s: []const u8) ?design_model.RepositionMode {
      if (std.mem.eql(u8, s, "last_in_parent")) return .last_in_parent;
      return null;
  }
  ```
- [ ] Pass `reposition` through to `updateElement`.
- [ ] Add a `CycleDetected` arm to the handler's error-to-status switch: 400 with `BadReparent` body.
- [ ] Run, confirm passing.
- [ ] `zig build test --summary all` — confirm full pass.
- [ ] `zig build install:linux:system 2>&1 | tail -n 5` — clean.
- [ ] Commit: `git commit -m "feat(design): handler passes reposition + maps CycleDetected to 400 BadReparent"`.

### Chunk 1 verification

```bash
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
```

Expected: all green. No new existing-test regressions.

---

## Chunk 1b — Backend: New `POST .../elements/reparent-batch` endpoint

**Outcome:** A new endpoint handles N-element reparenting in a single transaction. Body `{ element_ids: string[], new_parent_id: ?string, reposition: 'last_in_parent' }`. Returns `{ updated: DesignElement[] }` in input order. Atomic: ALL elements get reparented, or NONE (single SQL transaction). Cycle detection runs for each element pre-flight; if ANY element would cycle, the batch is rejected (400). SSE emits ONE `design_element_updated` event per affected element. The model function `reparentElements` is the canonical implementation; the handler is a thin wrapper.

### Task 1b.1 — Add `reparentElements` model function

**Files to edit:** `src/ai_workflow/tui/design_model.zig` (new function below `updateElement`, around line 905)

**Steps:**

- [ ] Read the `groupElements` function (around line 954) to mirror its transaction pattern.
- [ ] Write the failing tests in `src/ai_workflow/tui/design_model_reparent_batch_test.zig`:
  ```zig
  test "reparentElements moves 3 top-level leaves into a group in one transaction" {
      // setupDb: page + group (top-level) + 3 leaves (top-level)
      // call reparentElements(input{ element_ids = [a, b, c], new_parent_id = group.id, reposition = .last_in_parent })
      // assert all 3 leaves now have parent_id = group.id
      // assert positions are [max+1, max+2, max+3] (preserving input order)
  }

  test "reparentElements leaves parent_id NULL when new_parent_id is null" {
      // setupDb: page + 2 leaves nested in a group
      // call reparentElements(input{ element_ids = [a, b], new_parent_id = null, reposition = .last_in_parent })
      // assert both leaves now have parent_id IS NULL
  }

  test "reparentElements returns CycleDetected if ANY element would cycle, rejecting the whole batch" {
      // setupDb: group_a top-level + group_b parented to group_a + leaf parented to group_b
      // call reparentElements(input{ element_ids = [leaf, group_a], new_parent_id = group_b.id, ... })
      // expect error.CycleDetected
      // assert the DB has NOT changed (no leaves reparented; group_a still top-level)
  }

  test "reparentElements returns CrossPageIds when any element is on a different page" {
      // setupDb: page_1 + page_2; elements span both
      // expect error.CrossPageIds
  }

  test "reparentElements rejects an empty input list" {
      // expect error.EmptyElementIds
  }

  test "reparentElements rejects when an element_id does not exist" {
      // expect error.BadElementId
  }
  ```
- [ ] Run, confirm failing.
- [ ] Add `ReparentElementsInput` struct:
  ```zig
  pub const ReparentElementsInput = struct {
      page_id: []const u8,
      element_ids: []const []const u8,
      /// null = top-level (no parent). "" is also accepted as top-level
      /// (matches the COALESCE convention).
      new_parent_id: ?[]const u8,
      reposition: RepositionMode,
  };

  pub const ReparentElementsError = error{
      PageNotFound,
      EmptyElementIds,
      BadElementId,
      CrossPageIds,
      CycleDetected,
      BadNewParentId,
      DbError,
      OutOfMemory,
  };
  ```
- [ ] Implement `reparentElements`:
  ```zig
  pub fn reparentElements(
      allocator: std.mem.Allocator,
      db: *sqlite.SqliteBackend,
      input: ReparentElementsInput,
  ) ReparentElementsError![]DesignElement {
      if (input.element_ids.len == 0) return error.EmptyElementIds;

      // 1. Pre-flight: build the dynamic IN-list SELECT for the requested
      //    elements + validate page + parent_id + cycle for each.
      //    (Mirror groupElements' IN-list pattern at line 996-1006.)
      // ...

      // 2. Look up the page JOIN: workspace_id, item_id (needed for SSE).
      // ...

      // 3. Validate the new parent (if non-null):
      //    - SELECT id, type, page_id FROM design_page_elements WHERE id = ?
      //    - If not found → error.BadNewParentId (200 OK with explanatory
      //      message? — actually 400, matches update_element handler)
      //    - If page_id differs from input.page_id → error.CrossPageIds
      //    - If type is NOT 'group' or 'frame' → error.BadNewParentId
      //      (the parent must be a container — like D5).
      //    - For each element_id in the batch: check
      //      `hasAncestorCycle(input.element_id, new_parent_id)`. If ANY
      //      element would cycle → error.CycleDetected, NO writes happen.

      // 4. Start a transaction (mutex-held for the whole batch — per the
      //    SQLite transaction safety pattern in `.nalar/memories/zig-sqlite-patterns.md`).
      var tx = try db.begin();
      var committed = false;
      defer if (!committed) tx.rollback() catch {};

      // 5. For each element_id in input.element_ids (in order):
      //    - SELECT COALESCE(MAX(position), -1) FROM design_page_elements
      //      WHERE (COALESCE(parent_id, '') = ? OR parent_id IS NULL) AND id != ?
      //    - UPDATE design_page_elements SET parent_id = ?, position = ?, updated_at = datetime('now')
      //      WHERE id = ?
      //    - Use a fresh owned position string per iteration so each
      //      element lands at MAX + (its index + 1) — preserving input order.

      // 6. Re-SELECT the updated rows (to return the full DesignElement shape).
      // ...

      // 7. Emit `design_element_updated` SSE events (one per element).
      //    Use a fresh event per element so the SSE handler on the frontend
      //    gets a separate event per reparented element.

      // 8. Commit the transaction.
      committed = true;
      tx.commit() catch return error.DbError;
      return updated_rows;
  }
  ```
  **Pitfall:** Don't share one `position` value across iterations. Each element must be at `max_position + (i+1)` where `max_position` is computed from the CURRENT DB state (which is the post-update state of all previous elements in this batch). Use the same SELECT MAX pattern per element.
- [ ] Run tests, confirm passing.
- [ ] Run `zig build install:linux:system 2>&1 | tail -n 5` — clean.
- [ ] Commit: `git commit -m "feat(design): reparentElements model function — atomic N-element reparent with cycle rejection"`.

### Task 1b.2 — Add `design_elements_reparent.zig` HTTP handler

**Files to create:** `src/ai_workflow/tui/http_handlers/design_elements_reparent.zig`

**Steps:**

- [ ] Read the existing `design_elements_update.zig` handler to mirror its body-parse + error-mapping shape (per `.nalar/memories/nalar-backend-architecture.md` §"HTTP handler thin-wrapper pattern").
- [ ] Write the failing tests in `src/ai_workflow/tui/http_handlers/design_elements_reparent_test.zig`:
  ```zig
  test "reparent-batch handler calls design_model.reparentElements with parsed inputs" {
      // Build body JSON: { element_ids: ["a","b"], new_parent_id: "group_1", reposition: "last_in_parent" }
      // Call handler with req.params.get("page_id") = "page_1"
      // Assert response.status_code == 200, body has { updated: [DesignElement, DesignElement] }
  }

  test "reparent-batch handler maps CycleDetected to 400 BadReparent with the offending element id" {
      // body where one element would cycle
      // expect status 400 + error message includes "cycle"
  }

  test "reparent-batch handler maps EmptyElementIds to 400" {
      // body { element_ids: [], new_parent_id: null }
      // expect status 400 + "element_ids must be non-empty"
  }

  test "reparent-batch handler maps CrossPageIds to 409" {
      // body where an element is on a different page
      // expect status 409
  }

  test "reparent-batch handler maps BadNewParentId (parent is not a group/frame) to 400" {
      // body where new_parent_id is a leaf rectangle
      // expect status 400 + error message says "parent must be a group or frame"
  }

  test "reparent-batch handler maps PageNotFound to 404" {
      // body with bad page_id path param
      // expect status 404
  }
  ```
- [ ] Run, confirm failing.
- [ ] Implement the handler:
  ```zig
  const RepartBatchBody = struct {
      element_ids: []const []const u8 = &.{},
      new_parent_id: ?[]const u8 = null,
      reposition: []const u8 = "",
  };

  pub fn designElementsReparentBatchHandler(ctx, req, res) !res {
      // 1. Validate page_id path param (400 if missing)
      // 2. Validate body presence (400)
      // 3. Parse JSON (400 on parse failure)
      // 4. Validate element_ids non-empty (400 EmptyElementIds)
      // 5. Translate reposition string to enum (400 if invalid)
      // 6. Translate new_parent_id: null vs "" vs string (both null and "" mean top-level)
      // 7. Delegate to design_model.reparentElements
      // 8. Map errors to status codes (see test list above)
      // 9. Build { updated: DesignElementResponse[] } response (in input order)
  }
  ```
  Per `.nalar/memories/nalar-backend-architecture.md` §"HTTP handler thin-wrapper pattern": use `parseFromSliceLeaky`, per-request arena, `std.json.Stringify.valueAlloc` for the response.
- [ ] Run, confirm passing.
- [ ] Register the test in `src/ai_workflow/tui/test_runner.zig` (one line: `_ = @import("http_handlers/design_elements_reparent_test.zig");`).
- [ ] `zig build test --summary all` — confirm full pass.
- [ ] Commit.

### Task 1b.3 — Register the route in `main.zig` + re-export handler

**Files to edit:** `src/main.zig`, `src/ai_workflow/tui/http_handlers/mod.zig`

**Steps:**

- [ ] Read `src/main.zig` to find the existing `try gs.router.post(.../elements/reorder, ...)` line (or the existing route registrations for `elements/:element_id` PUT and `elements/group` POST).
- [ ] Add the route registration:
  ```zig
  try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reparent-batch", designElementsReparentBatchHandler);
  ```
- [ ] Add the handler re-export in `mod.zig` (one line: `pub const designElementsReparentBatchHandler = @import("design_elements_reparent.zig").designElementsReparentBatchHandler;`).
- [ ] Run `zig build install:linux:system 2>&1 | tail -n 5` — must succeed. This catches the lazy-analysis error if the route is wired incorrectly (per `.nalar/memories/zig-build-and-test.md`).
- [ ] Commit: `git commit -m "feat(design): wire POST .../elements/reparent-batch route"`.

### Chunk 1b verification

```bash
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
```

Expected: all green. Live test with `curl -X POST .../elements/reparent-batch` confirms the wire (deferred to Chunk 5).

---

## Chunk 2 — API + store + composable wiring (single + batch paths)

**Outcome:** Frontend has both:
- Single-element reparent via `PUT .../elements/:id` with `{ parent_id, reposition }` — used by keyboard shortcuts (D8a).
- N-element batch reparent via `POST .../elements/reparent-batch` with `{ element_ids, new_parent_id, reposition }` — used by drag-and-drop (D8b).

The composable `useDesignHandlers.reparentLayers(payload)` ALWAYS calls the batch endpoint (uniform behaviour regardless of selection size; the backend handles N=1 efficiently).

### Task 2.1 — Extend `UpdateDesignElementRequest` in API + add `reparentDesignElementsBatch`

**Files to edit:** `src/apps/desktop/src/api/index.ts` (around line 1581, in `updateDesignElement` + new section after)

**Steps:**

- [ ] Read lines 1580-1600 of `src/apps/desktop/src/api/index.ts`.
- [ ] Write the failing tests in a NEW `src/apps/desktop/src/__tests__/apiReparent.spec.ts`:
  ```ts
  describe('api.updateDesignElement — reposition field', () => {
      it('forwards the optional reposition field to the wire body', async () => {
          // mock fetch; call updateDesignElement(..., { parent_id: 'g', reposition: 'last_in_parent' })
          // assert body has `reposition: 'last_in_parent'`
      })
  })

  describe('api.reparentDesignElementsBatch', () => {
      it('POSTs to /elements/reparent-batch with the parsed body', async () => {
          // mock fetch; call reparentDesignElementsBatch(ws, item, page, { element_ids: ['a','b'], new_parent_id: 'g', reposition: 'last_in_parent' })
          // assert fetch received POST to the right URL with the right body
      })

      it('sends new_parent_id as null when leaving a group', async () => {
          // call with { element_ids: ['a'], new_parent_id: null, ... }
          // assert body has `new_parent_id: null`
      })
  })
  ```
- [ ] Run `bunx vitest run src/__tests__/apiReparent.spec.ts` — confirm failing.
- [ ] Add the types + functions:
  ```ts
  export type RepositionMode = 'last_in_parent'

  export interface UpdateDesignElementRequest extends Partial<DesignElement> {
      parent_id?: string
      reposition?: RepositionMode  // NEW
  }

  export interface ReparentDesignElementsBatchRequest {
      element_ids: string[]
      /** null = leave any current group, become top-level. */
      new_parent_id: string | null
      reposition: RepositionMode
  }

  export interface ReparentDesignElementsBatchResponse {
      updated: DesignElement[]
  }

  export async function reparentDesignElementsBatch(
      workspaceId: string,
      itemId: string,
      pageId: string,
      body: ReparentDesignElementsBatchRequest,
  ): Promise<ReparentDesignElementsBatchResponse> {
      return await apiFetch<ReparentDesignElementsBatchResponse>(
          `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/reparent-batch`,
          { method: 'POST', body },
      )
  }
  ```
- [ ] Run, confirm passing.
- [ ] Commit.

### Task 2.2 — Add `reparentDesignElementsBatch` store action

**Files to edit:** `src/apps/desktop/src/stores/workspaces.ts` (around line 1214, near `updateDesignElement`)

**Steps:**

- [ ] Read lines 1210-1270 to understand the existing `updateDesignElement` pattern.
- [ ] Write the failing tests in a NEW `src/apps/desktop/src/__tests__/workspacesStoreReparent.spec.ts`:
  ```ts
  describe('workspacesStore.reparentDesignElementsBatch', () => {
      it('POSTs the batch and mirrors every server response into item.design_elements in input order', async () => {
          // setup: a workspace + item with 3 elements
          // mock api.reparentDesignElementsBatch to resolve with { updated: [DesignElement, DesignElement, DesignElement] }
          // call store.reparentDesignElementsBatch(ws, item, page, { element_ids: ['a','b','c'], new_parent_id: 'group_x' })
          // assert item.design_elements contains the 3 updated rows with parent_id set
      })

      it('sends new_parent_id = null to leave a group (top-level)', async () => {
          // assert body.new_parent_id === null
      })
  })
  ```
- [ ] Run, confirm failing.
- [ ] Implement:
  ```ts
  async function reparentDesignElementsBatch(
      workspaceId: string,
      itemId: string,
      pageId: string,
      body: Omit<ReparentDesignElementsBatchRequest, 'reposition'> & { reposition?: RepositionMode },
  ): Promise<DesignElement[]> {
      const result = await reparentDesignElementsBatchApi(workspaceId, itemId, pageId, {
          ...body,
          reposition: body.reposition ?? 'last_in_parent',
      })
      // Mirror every updated row into the local design_elements array
      // in place (preserves input order; the array length is stable).
      const item = findItem(workspaceId, itemId)
      if (item?.design_elements) {
          for (const updated of result.updated) {
              const idx = item.design_elements.findIndex((e) => e.id === updated.id)
              if (idx !== -1) item.design_elements[idx] = updated
          }
      }
      return result.updated
  }
  ```
- [ ] Re-export in the store's returned API object.
- [ ] Run, confirm passing.
- [ ] Commit.

### Task 2.3 — Add `reparentLayers` to `useDesignHandlers`

**Files to edit:** `src/apps/desktop/src/composables/useDesignHandlers.ts`

**Steps:**

- [ ] Read the existing `updateElement` and `groupSelection` patterns in the composable.
- [ ] Write the failing tests in a NEW `src/apps/desktop/src/__tests__/useDesignHandlers.reparent.spec.ts`:
  ```ts
  describe('useDesignHandlers.reparentLayers', () => {
      it('calls the BATCH endpoint regardless of selection size (1 or N elements)', async () => {
          // single-element: call reparentLayers({ elementIds: ['a'], newParentId: 'g' })
          // assert api.reparentDesignElementsBatch was called with { element_ids: ['a'], new_parent_id: 'g', reposition: 'last_in_parent' }
          // N-element: same with ['a','b','c']
      })

      it('sends newParentId=null through as null in the batch body (leave group)', async () => {
          // call reparentLayers({ elementIds: ['a','b'], newParentId: null })
          // assert body.new_parent_id === null
      })

      it('shows an error notification when the API rejects with CycleDetected', async () => {
          // mock api to throw 'cycle detected'
          // call reparentLayers(...)
          // assert notifications.notifyError was called with the cycle message
      })

      it('is a quiet no-op when any of wsId/itemId/pageId is empty OR elementIds is empty', async () => {
          // skip the store call; assert no api call happened
      })
  })
  ```
- [ ] Run, confirm failing.
- [ ] Implement:
  ```ts
  async function reparentLayers(payload: {
      workspaceId: string
      itemId: string
      pageId: string
      elementIds: string[]
      /** null = drop into the top-level (leave any current group). */
      newParentId: string | null
  }): Promise<void> {
      const { workspaceId, itemId, pageId, elementIds, newParentId } = payload
      if (!workspaceId || !itemId || !pageId) return
      if (elementIds.length === 0) return
      try {
          await workspacesStore.reparentDesignElementsBatch(
              workspaceId, itemId, pageId, {
                  element_ids: elementIds,
                  new_parent_id: newParentId,
                  reposition: 'last_in_parent',
              },
          )
      } catch (err) {
          const message = err instanceof Error ? err.message : String(err)
          notificationStore.notifyError(message, 'Failed to reparent layers.')
      }
  }
  ```
- [ ] Add to the composable's `return { ... }`.
- [ ] Run, confirm passing.
- [ ] Commit.

### Chunk 2 verification

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build
timeout 180 node_modules/.bin/vitest run \
    src/__tests__/apiReparent.spec.ts \
    src/__tests__/workspacesStoreReparent.spec.ts \
    src/__tests__/useDesignHandlers.reparent.spec.ts
timeout 60 bun run build 2>&1 | tail -n 5
```

Expected: all green.

---

## Chunk 3 — Drag-and-drop composable (`useLayerDragDrop`, multi-aware)

**Outcome:** A pure-logic composable that owns drag state for the WHOLE selected set (not just one row), computes the visual state class for each row ("is being dragged" / "is a valid drop target" / "would cycle"), and exposes `onDragStart`, `onDragOver`, `onDragLeave`, `onDrop`, `onDragEnd` handlers. Behavioural tests cover:
- 1-element selection: dragstart records the dragged set
- N-element selection: dragstart on any selected row records the FULL set
- Drop on a group resolves to `{ elementIds: [...full set], newParentId: group.id }`
- Drop on top-level zone resolves to `{ elementIds: [...full set], newParentId: null }`
- Cycle detection: if ANY element in the set would cycle (target is in the descendant chain of any selected element), the target is marked invalid for the entire drag
- Multi-select (where selection includes the target itself): target is marked invalid
- dragend clears state

### Task 3.1 — Implement `useLayerDragDrop` composable

**Files to create:** `src/apps/desktop/src/composables/useLayerDragDrop.ts`

**Steps:**

- [ ] Write the failing tests in a NEW `src/apps/desktop/src/__tests__/useLayerDragDrop.spec.ts`:
  ```ts
  describe('useLayerDragDrop (composable, multi-aware)', () => {
      const makeElements = () => [
          { id: 'leaf_top_1', parent_id: '', type: 'rectangle' },
          { id: 'leaf_top_2', parent_id: '', type: 'rectangle' },
          { id: 'group_a', parent_id: '', type: 'group' },
          { id: 'leaf_in_a', parent_id: 'group_a', type: 'rectangle' },
          { id: 'group_b', parent_id: 'group_a', type: 'group' }, // grandchild
      ]

      describe('single-element drag', () => {
          it('onDragStart with empty selection records the dragged element id', () => {
              const { handlers, state } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(),
              })
              handlers.onDragStart('leaf_top_1', new DragEvent('dragstart'))
              expect(state.draggedIds.value).toEqual(new Set(['leaf_top_1']))
          })
      })

      describe('multi-element drag', () => {
          it('onDragStart on a selected row records ALL selected ids, not just the dragged one', () => {
              const { handlers, state } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(['leaf_top_1', 'leaf_top_2', 'group_a']),
              })
              handlers.onDragStart('leaf_top_1', new DragEvent('dragstart'))
              expect(state.draggedIds.value).toEqual(new Set(['leaf_top_1', 'leaf_top_2', 'group_a']))
          })

          it('onDragStart on an unselected row records ONLY that row (single-element shortcut)', () => {
              // user clicked-then-dragged without Shift — only one row is selected
              const { handlers, state } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(['leaf_top_1']),
              })
              handlers.onDragStart('leaf_top_2', new DragEvent('dragstart')) // dragged a non-selected row
              expect(state.draggedIds.value).toEqual(new Set(['leaf_top_2']))
          })
      })

      describe('drop resolution', () => {
          it('onDrop on a group resolves to { elementIds: [...], newParentId: group.id }', () => {
              const { handlers } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(['leaf_top_1', 'leaf_top_2']),
              })
              handlers.onDragStart('leaf_top_1', new DragEvent('dragstart'))
              const dropResult = handlers.onDrop('group_a', new DragEvent('drop'))!
              expect(dropResult.elementIds).toEqual(['leaf_top_1', 'leaf_top_2'])
              expect(dropResult.newParentId).toBe('group_a')
          })

          it('onDrop on a top-level zone resolves to newParentId: null (leave any group)', () => {
              // drag 2 nested elements + 1 group that contains them
              const { handlers } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(['group_a', 'leaf_in_a']),
              })
              handlers.onDragStart('group_a', new DragEvent('dragstart'))
              const dropResult = handlers.onDrop(TOP_LEVEL_SENTINEL, new DragEvent('drop'))!
              expect(dropResult.newParentId).toBe(null)
          })

          it('drop result is null when no drag is in flight', () => {
              const { handlers } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(),
              })
              expect(handlers.onDrop('group_a', new DragEvent('drop'))).toBe(null)
          })
      })

      describe('cycle prevention', () => {
          it('marks target invalid when target is in the descendant chain of ANY dragged element', () => {
              // Drag group_a (which contains group_b) — group_b is its descendant
              const { handlers, state } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(['group_a']),
              })
              handlers.onDragStart('group_a', new DragEvent('dragstart'))
              handlers.onDragOver('group_b', new DragEvent('dragover'))
              expect(state.isDropTarget('group_b')).toBe(false)
          })

          it('blocks dropping a group onto itself', () => {
              const { handlers, state } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(['group_a']),
              })
              handlers.onDragStart('group_a', new DragEvent('dragstart'))
              handlers.onDragOver('group_a', new DragEvent('dragover'))
              expect(state.isDropTarget('group_a')).toBe(false)
          })

          it('blocks dropping a mixed selection onto itself (any selected is target)', () => {
              const { handlers, state } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(['group_a', 'leaf_in_a']),
              })
              handlers.onDragStart('group_a', new DragEvent('dragstart'))
              // dropping on leaf_in_a (which is a child of group_a) — cycle because group_a is an ancestor
              handlers.onDragOver('leaf_in_a', new DragEvent('dragover'))
              expect(state.isDropTarget('leaf_in_a')).toBe(false)
          })

          it('allows dropping a nested element onto its own parent (no cycle)', () => {
              const { handlers, state } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(['leaf_in_a']),
              })
              handlers.onDragStart('leaf_in_a', new DragEvent('dragstart'))
              handlers.onDragOver('group_a', new DragEvent('dragover'))
              expect(state.isDropTarget('group_a')).toBe(true)
          })
      })

      describe('visual state', () => {
          it('every selected row gets the dragging class during a multi-drag', () => {
              const { handlers, state } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(['leaf_top_1', 'leaf_top_2', 'group_a']),
              })
              handlers.onDragStart('leaf_top_1', new DragEvent('dragstart'))
              expect(state.isBeingDragged('leaf_top_1')).toBe(true)
              expect(state.isBeingDragged('leaf_top_2')).toBe(true)
              expect(state.isBeingDragged('group_a')).toBe(true)
              expect(state.isBeingDragged('leaf_in_a')).toBe(false)
          })

          it('onDragEnd clears the drag state', () => {
              const { handlers, state } = useLayerDragDrop({
                  elements: makeElements(),
                  selectedIds: () => new Set(['leaf_top_1', 'leaf_top_2']),
              })
              handlers.onDragStart('leaf_top_1', new DragEvent('dragstart'))
              handlers.onDragEnd(new DragEvent('dragend'))
              expect(state.draggedIds.value).toEqual(new Set())
              expect(state.hoveredDropId.value).toBe(null)
          })
      })
  })
  ```
- [ ] Run, confirm failing (composable doesn't exist yet).
- [ ] Implement (the file is a TS composable that owns refs and returns `handlers` + `state`):
  ```ts
  // src/apps/desktop/src/composables/useLayerDragDrop.ts
  import { ref, computed, type Ref } from 'vue'
  import type { DesignElement } from '../api'

  export interface LayerDragDropArgs {
      elements: () => DesignElement[] | Ref<DesignElement[]>
      /** Optional reactive selectedIds getter. When the dragged row is
       *  in this set, the WHOLE set is dragged (multi-drag). */
      selectedIds?: () => Set<string> | null
  }

  export interface DropResult {
      elementIds: string[]
      newParentId: string | null
  }

  /** Sentinel id for "drop here means: leave any current group, become top-level". */
  export const TOP_LEVEL_SENTINEL = '__design_top_level__'

  export function useLayerDragDrop(args: LayerDragDropArgs) {
      const draggedIds = ref<Set<string>>(new Set())
      const hoveredDropId = ref<string | null>(null)

      const elements = computed<DesignElement[]>(() => {
          const v = args.elements()
          return Array.isArray(v) ? v : (v as Ref<DesignElement[]>).value
      })

      // Walk the parent_id chain upward. Returns true iff `targetAncestor`
      // is itself or any ancestor of `descendantId`.
      function isAncestor(targetAncestor: string, descendantId: string): boolean {
          let current: string | null = descendantId
          for (let depth = 0; depth < 1024; depth++) {
              const e = elements.value.find((x) => x.id === current)
              if (!e) return false
              if (e.parent_id && e.parent_id === targetAncestor) return true
              current = (e.parent_id && e.parent_id.length > 0) ? e.parent_id : null
              if (current === null) return false
          }
          return false
      }

      // A target is a valid drop zone if:
      //   - For the top-level sentinel: always valid.
      //   - For a real row id: that row is `group` or `frame`, AND
      //     NONE of the dragged elements is the target OR a descendant
      //     of the target.
      function isValidDropTarget(targetId: string, sourceIds: Set<string>): boolean {
          if (targetId === TOP_LEVEL_SENTINEL) return true
          const t = elements.value.find((e) => e.id === targetId)
          if (!t) return false
          if (t.type !== 'group' && t.type !== 'frame') return false
          // Block ANY dragged element being the target or a descendant
          // of the target — covers both single and multi-drag cycles.
          for (const src of sourceIds) {
              if (targetId === src) return false
              if (isAncestor(targetId, src)) return false
          }
          return true
      }

      function isDropTarget(targetId: string): boolean {
          if (draggedIds.value.size === 0) return false
          return isValidDropTarget(targetId, draggedIds.value)
      }

      function isBeingDragged(id: string): boolean {
          return draggedIds.value.has(id)
      }

      function onDragStart(rowId: string, _event: DragEvent): void {
          // Multi-drag: if the dragged row is in selectedIds, drag the
          // WHOLE selection. Otherwise, drag just this row.
          const sel = args.selectedIds?.()
          if (sel && sel.has(rowId) && sel.size > 1) {
              draggedIds.value = new Set(sel)
          } else {
              draggedIds.value = new Set([rowId])
          }
      }

      function onDragOver(targetId: string, _event: DragEvent): void {
          if (draggedIds.value.size === 0) return
          if (isValidDropTarget(targetId, draggedIds.value)) {
              hoveredDropId.value = targetId
          } else {
              hoveredDropId.value = null
          }
      }

      function onDragLeave(_targetId: string, _event: DragEvent): void {
          hoveredDropId.value = null
      }

      function onDragEnd(_event: DragEvent): void {
          draggedIds.value = new Set()
          hoveredDropId.value = null
      }

      function onDrop(targetId: string, _event: DragEvent): DropResult | null {
          const source = new Set(draggedIds.value)
          draggedIds.value = new Set()
          hoveredDropId.value = null
          if (source.size === 0) return null
          if (!isValidDropTarget(targetId, source)) return null
          return {
              elementIds: Array.from(source),
              newParentId: targetId === TOP_LEVEL_SENTINEL ? null : targetId,
          }
      }

      return {
          state: { draggedIds, hoveredDropId, isDropTarget, isBeingDragged },
          handlers: { onDragStart, onDragOver, onDragLeave, onDrop, onDragEnd },
      }
  }
  ```
- [ ] Run tests, confirm passing.
- [ ] Commit: `git commit -m "feat(design): useLayerDragDrop composable — multi-drag with cycle prevention"`.

### Chunk 3 verification

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
timeout 60 node_modules/.bin/vitest run src/__tests__/useLayerDragDrop.spec.ts
```

Expected: all ~14 tests pass.

---

## Chunk 4 — Wire drag-and-drop into `<LayerRow>` + `<LayersPanel>`

**Outcome:** Dragging one or more selected rows engages the visual state machine (50% opacity on EVERY dragged row, violet ring on valid drop targets, grey-out on invalid drop targets). Dropping resolves to a `reparent` emit on `<LayersPanel>` (with an array of element ids + new parent id) which `DesignView` translates into the `useDesignHandlers.reparentLayers(...)` call. The LayersPanel also renders a "top-level drop zone" area between top-level rows so dragging a child group/element to a top-level row leaves it as top-level.

### Task 4.1 — Add drag handlers + visual state classes to `<LayerRow>`

**Files to edit:** `src/apps/desktop/src/components/design/LayerRow.vue`

**Steps:**

- [ ] Read the full file (already have it from earlier exploration).
- [ ] Write the failing behavioural tests in a NEW `src/apps/desktop/src/__tests__/LayerRow.dragDrop.spec.ts`:
  ```ts
  import LayerRow from '../components/design/LayerRow.vue'
  import { mount } from '@vue/test-utils'
  import { setActivePinia, createPinia } from 'pinia'

  describe('<LayerRow> drag-and-drop', () => {
      beforeEach(() => setActivePinia(createPinia()))

      const makeNode = (id: string, type: 'rectangle' | 'group' = 'rectangle', children: any[] = []) => ({
          element: { id, type, parent_id: '', name: id },
          children,
      })

      it('the row DOM has draggable=true when not readonly', () => {
          const wrapper = mount(LayerRow, {
              props: {
                  node: makeNode('a'), depth: 0,
                  selectedIds: ['a'], readonly: false, collapsedIds: new Set(),
              },
          })
          expect(wrapper.attributes('draggable')).toBe('true')
      })

      it('readonly rows are not draggable', () => {
          const wrapper = mount(LayerRow, {
              props: { node: makeNode('a'), depth: 0, selectedIds: [], readonly: true, collapsedIds: new Set() },
          })
          expect(wrapper.attributes('draggable')).toBe('false')
      })

      it('action buttons (▲▼×) are NOT draggable (prevent dragstart from clicks)', () => {
          const wrapper = mount(LayerRow, {
              props: { node: makeNode('a'), depth: 0, selectedIds: [], readonly: false, collapsedIds: new Set() },
          })
          expect(wrapper.find('[data-testid="design-layer-reorder-up-a"]').attributes('draggable')).toBe('false')
          expect(wrapper.find('[data-testid="design-layer-delete-a"]').attributes('draggable')).toBe('false')
      })

      it('calls the onLayerDragStart prop with the row element id when dragstart fires', async () => {
          const onLayerDragStart = vi.fn()
          const wrapper = mount(LayerRow, {
              props: {
                  node: makeNode('a'), depth: 0, selectedIds: [], readonly: false, collapsedIds: new Set(),
                  onLayerDragStart,
              },
          })
          await wrapper.trigger('dragstart', { dataTransfer: {} })
          expect(onLayerDragStart).toHaveBeenCalledWith('a', expect.any(DragEvent))
      })

      it('calls the onLayerDragEnd prop on dragend', async () => {
          const onLayerDragEnd = vi.fn()
          const wrapper = mount(LayerRow, {
              props: {
                  node: makeNode('a'), depth: 0, selectedIds: [], readonly: false, collapsedIds: new Set(),
                  onLayerDragEnd,
              },
          })
          await wrapper.trigger('dragend')
          expect(onLayerDragEnd).toHaveBeenCalled()
      })

      it('calls the onLayerDrop prop on drop with the row element id', async () => {
          const onLayerDrop = vi.fn()
          const wrapper = mount(LayerRow, {
              props: {
                  node: makeNode('a'), depth: 0, selectedIds: [], readonly: false, collapsedIds: new Set(),
                  onLayerDrop,
              },
          })
          await wrapper.trigger('drop', { dataTransfer: {} })
          expect(onLayerDrop).toHaveBeenCalledWith('a', expect.any(DragEvent))
      })

      it('applies the drop-target visual class when isDropTarget prop is true', async () => {
          const wrapper = mount(LayerRow, {
              props: {
                  node: makeNode('group_x', 'group'),
                  depth: 0,
                  selectedIds: [], readonly: false, collapsedIds: new Set(),
                  isDropTarget: true,
              },
          })
          expect(wrapper.classes()).toContain('layer-row-drop-target')
      })

      it('applies the drop-target-blocked visual class when isDropTargetBlocked is true', () => {
          const wrapper = mount(LayerRow, {
              props: {
                  node: makeNode('group_x', 'group'),
                  depth: 0,
                  selectedIds: [], readonly: false, collapsedIds: new Set(),
                  isDropTarget: false,
                  isDropTargetBlocked: true,
              },
          })
          expect(wrapper.classes()).toContain('layer-row-drop-target-blocked')
      })

      it('applies the dragging class when isBeingDragged prop is true', () => {
          const wrapper = mount(LayerRow, {
              props: {
                  node: makeNode('a'), depth: 0, selectedIds: [], readonly: false, collapsedIds: new Set(),
                  isBeingDragged: true,
              },
          })
          expect(wrapper.classes()).toContain('layer-row-dragging')
      })
  })
  ```
- [ ] Run, confirm failing.
- [ ] Implement in `LayerRow.vue`:
  - Add props: `onLayerDragStart?: (id: string, ev: DragEvent) => void`, `onLayerDragOver?: (id: string, ev: DragEvent) => void`, `onLayerDrop?: (id: string, ev: DragEvent) => void`, `onLayerDragLeave?: (id: string, ev: DragEvent) => void`, `onLayerDragEnd?: (ev: DragEvent) => void`, `isDropTarget?: boolean`, `isDropTargetBlocked?: boolean`, `isBeingDragged?: boolean`, `kind?: 'row' | 'drop-zone' = 'row'`.
  - Add the listeners:
    ```vue
    <div
        :draggable="!readonly && kind === 'row'"
        :class="[
            'flex items-center gap-2 px-2 py-1.5 text-sm cursor-pointer transition-colors',
            isBeingDragged && 'layer-row-dragging',
            isDropTarget && 'layer-row-drop-target',
            isDropTargetBlocked && 'layer-row-drop-target-blocked',
        ]"
        @dragstart="handleDragStart"
        @dragover.prevent="handleDragOver"
        @drop="handleDrop"
        @dragleave="handleDragLeave"
        @dragend="handleDragEnd"
    >
    ```
  - Add the handlers that delegate to the callbacks (so `LayersPanel` owns the drag state centrally):
    ```ts
    const handleDragStart = (e: DragEvent) => {
        if (kind === 'drop-zone') { e.preventDefault(); return }
        if (readonly) { e.preventDefault(); return }
        props.onLayerDragStart?.(props.node.element.id, e)
    }
    const handleDragOver = (e: DragEvent) => {
        props.onLayerDragOver?.(effectiveId.value, e)
    }
    const handleDragLeave = (e: DragEvent) => {
        props.onLayerDragLeave?.(effectiveId.value, e)
    }
    const handleDrop = (e: DragEvent) => {
        e.preventDefault()
        props.onLayerDrop?.(effectiveId.value, e)
    }
    const handleDragEnd = (e: DragEvent) => {
        props.onLayerDragEnd?.(e)
    }
    ```
  - Add `draggable="false"` to the action buttons (▲▼×) so clicks don't start a drag.
  - Add CSS classes (in `<style scoped>`):
    ```css
    .layer-row-dragging { opacity: 0.5; cursor: grabbing !important; }
    .layer-row-drop-target { outline: 1px solid var(--color-violet); outline-offset: -1px; background-color: rgba(127, 0, 255, 0.08); }
    .layer-row-drop-target-blocked { cursor: not-allowed; opacity: 0.6; }
    ```
- [ ] Run, confirm passing.
- [ ] Commit.

### Task 4.2 — Wire `<LayersPanel>` to render top-level drop zones + handle multi-reparent

**Files to edit:** `src/apps/desktop/src/components/design/LayersPanel.vue`

**Steps:**

- [ ] Read `LayersPanel.vue` (have it from earlier).
- [ ] Write the failing tests in `src/apps/desktop/src/__tests__/LayersPanel.spec.ts` (extend):
  ```ts
  describe('LayersPanel.vue — drop zone rendering + multi-reparent', () => {
      const elements = [
          { id: 'a', parent_id: '', type: 'rectangle' },
          { id: 'b', parent_id: '', type: 'rectangle' },
          { id: 'group', parent_id: '', type: 'group' },
      ]

      it('renders top-level drop zones: one above, one between, one below the top-level rows', () => {
          const wrapper = mount(LayersPanel, { props: { elements, selectedIds: [], readonly: false } })
          expect(wrapper.findAll('[data-testid="design-layer-drop-zone-top-level"]').length).toBeGreaterThanOrEqual(2)
      })

      it('emits reparent with elementIds=[selected...] and newParentId=null on a top-level drop', async () => {
          const wrapper = mount(LayersPanel, { props: { elements, selectedIds: ['a','b'], readonly: false } })
          const topZone = wrapper.findAll('[data-testid="design-layer-drop-zone-top-level"]')[0]
          await topZone.trigger('drop', { dataTransfer: {} })
          expect(wrapper.emitted('reparent')).toBeTruthy()
          expect(wrapper.emitted('reparent')![0]).toEqual([{ elementIds: ['a','b'], newParentId: null }])
      })

      it('emits reparent with newParentId=group.id when dropped ON a group row', async () => {
          // single-element selection for the simplest test
          const wrapper = mount(LayersPanel, { props: { elements, selectedIds: ['a'], readonly: false } })
          const groupRow = wrapper.find('[data-testid="design-layer-group"]')
          await groupRow.trigger('drop', { dataTransfer: {} })
          expect(wrapper.emitted('reparent')![0]).toEqual([{ elementIds: ['a'], newParentId: 'group' }])
      })

      it('passes multi-drag elementIds through when multiple rows are selected', async () => {
          // simulate multi-drag: user selects [a, group] then drags `a` onto the top-level drop zone
          const wrapper = mount(LayersPanel, { props: { elements, selectedIds: ['a','group'], readonly: false } })
          const topZone = wrapper.findAll('[data-testid="design-layer-drop-zone-top-level"]')[0]
          await topZone.trigger('drop', { dataTransfer: {} })
          // The drop resolved to the full selected set
          expect(wrapper.emitted('reparent')![0]).toEqual([{ elementIds: ['a','group'], newParentId: null }])
      })
  })
  ```
- [ ] Run, confirm failing.
- [ ] Implement:
  - Add a `reparent` emit to `<LayersPanel>`: `reparent: [payload: { elementIds: string[]; newParentId: string | null }]`.
  - Construct `useLayerDragDrop({ elements: () => props.elements, selectedIds: () => new Set(props.selectedIds) })` once per panel.
  - Render `<LayerRow kind="drop-zone" data-testid="design-layer-drop-zone-top-level" :is-drop-target="..." :on-layer-drop="...">` at the top of the list AND between every pair of top-level siblings AND after the last top-level sibling.
  - For each `<LayerRow kind="row" />`, pass:
    - `:is-being-dragged="state.isBeingDragged(row.element.id)"`
    - `:is-drop-target="state.isDropTarget(row.element.id) && hoveredDropId === row.element.id"`
    - `:on-layer-drag-start="handlers.onDragStart"`, `:on-layer-drag-over="handlers.onDragOver"`, etc.
  - The composable's `onDrop` resolves to a `reparent` emit; clear the drop result after emit.
  - **No multi-drag toast** (we changed D4 — multi-drag IS in scope).
- [ ] Run, confirm passing.
- [ ] Commit.

### Task 4.3 — Wire `<DesignView>` to receive `reparent` + call `useDesignHandlers.reparentLayers`

**Files to edit:** `src/apps/desktop/src/components/design/DesignView.vue`

**Steps:**

- [ ] Read lines 1965-1990 to confirm the `<LayersPanel>` template + handler binding.
- [ ] Write the failing tests in a NEW `src/apps/desktop/src/__tests__/DesignView.reparent.spec.ts`:
  ```ts
  describe('DesignView reparent wiring (single + multi)', () => {
      it('forwards <LayersPanel @reparent> with 1 elementId to useDesignHandlers.reparentLayers', async () => {
          // mount DesignView with one page + 3 elements
          // findComponent({ name: 'LayersPanel' })
          // mock api
          // emit reparent { elementIds: ['a'], newParentId: 'group' }
          // assert api was called with body { element_ids: ['a'], new_parent_id: 'group', reposition: 'last_in_parent' }
      })

      it('forwards N elementIds for multi-reparent', async () => {
          // emit reparent { elementIds: ['a','b','c'], newParentId: null }
          // assert body element_ids === ['a','b','c'] and new_parent_id === null
      })
  })
  ```
- [ ] Run, confirm failing.
- [ ] Implement:
  ```ts
  const handleDesignReparent = (payload: { elementIds: string[]; newParentId: string | null }): void => {
      const pageId = activePageId.value
      if (!pageId) return
      if (!payload.elementIds || payload.elementIds.length === 0) return
      void designHandlers.reparentLayers({
          workspaceId: props.workspaceId,
          itemId: props.itemId,
          pageId,
          elementIds: payload.elementIds,
          newParentId: payload.newParentId,
      })
  }
  ```
- [ ] Add `@reparent="handleDesignReparent"` to the `<LayersPanel>` tag at line 1968.
- [ ] Run, confirm passing.
- [ ] Verify `node node_modules/vue-tsc/bin/vue-tsc.js --build` is clean.
- [ ] Commit.

### Chunk 4 verification

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
timeout 60 node_modules/.bin/vitest run \
    src/__tests__/LayerRow.dragDrop.spec.ts \
    src/__tests__/LayersPanel.spec.ts \
    src/__tests__/DesignView.reparent.spec.ts
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build
timeout 240 bun run build 2>&1 | tail -n 5
```

Expected: all green; `vue-tsc` is the gate.

---

## Chunk 5 — Live smoke + SPEC + NALAR update

**Outcome:** Verified end-to-end with a fresh isolated server (port 8080), the SPEC.md updated with the new feature, NALAR.md changelog updated. Live smoke covers both single-element and N-element batch reparent + cycle rejection.

### Task 5.1 — Live smoke on port 8080

**Steps:**

- [ ] Start a fresh isolated server on port 8080:
  ```bash
  rm -rf /tmp/nalar-dragdrop-smoke
  env -i HOME=/tmp/nalar-dragdrop-smoke PATH=$PATH \
      ./zig-out/bin/nalarcore-linux-x86_64 --port 8080 > /tmp/dragdrop-smoke.log 2>&1 &
  disown
  sleep 6
  ```
- [ ] Bootstrap: workspace + design item + page + 3 elements (one group + 2 top-level leaves + 1 child-of-group).
- [ ] Test single-element reparent (via PUT .../elements/:id with `reposition`):
  ```bash
  curl -sS -X PUT "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements/$LEAF_TOP" \
      -H 'content-type: application/json' \
      -d "{\"parent_id\":\"$GROUP\",\"reposition\":\"last_in_parent\"}" | python3 -m json.tool
  ```
- [ ] Test N-element batch reparent (via POST .../elements/reparent-batch):
  ```bash
  curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements/reparent-batch" \
      -H 'content-type: application/json' \
      -d "{\"element_ids\":[\"$LEAF_TOP\",\"$LEAF_NESTED\"],\"new_parent_id\":\"$GROUP\",\"reposition\":\"last_in_parent\"}" | python3 -m json.tool
  ```
  Assert response is `{ updated: [DesignElement, DesignElement] }` in input order.
- [ ] Verify batch atomicity — try a batch where 1 element would cycle. Expect 400:
  ```bash
  curl -sS -i -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements/reparent-batch" \
      -H 'content-type: application/json' \
      -d "{\"element_ids\":[\"$LEAF_TOP\",\"$GROUP\"],\"new_parent_id\":\"$LEAF_NESTED\",\"reposition\":\"last_in_parent\"}" | head -n 1
  # expect: HTTP/1.1 400 Bad Request
  ```
- [ ] Verify the DB state didn't change (re-fetch elements; assert `$GROUP` is still top-level and `$LEAF_TOP` still in its previous state).
- [ ] Test leave-group (batch, new_parent_id = null):
  ```bash
  curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages/$PAGE/elements/reparent-batch" \
      -H 'content-type: application/json' \
      -d "{\"element_ids\":[\"$LEAF_TOP\"],\"new_parent_id\":null,\"reposition\":\"last_in_parent\"}" | python3 -m json.tool
  ```
- [ ] Cleanup: `pkill -f "nalar --port 8080"`.
- [ ] Commit any fixups.

### Task 5.2 — Update `docs/SPEC.md` and root `NALAR.md`

**Files to edit:** `docs/SPEC.md` (§3.8 Design Canvas), `NALAR.md` (changelog)

**Steps:**

- [ ] Read `docs/SPEC.md` §3.8 to find the existing design-canvas feature list.
- [ ] Append a new entry: "Layer drag-to-join-or-leave-group (single + multi)" with the wire/binding description.
- [ ] Read root `NALAR.md` changelog section.
- [ ] Append a `## 2026-07-30: ...` block per project convention with:
  - Symptom: user wanted Figma-style drag-to-reparent in LayersPanel (multi-select support included)
  - Root cause: no drag/drop UI existed (only keyboard shortcuts + right-click group/ungroup)
  - Fix: native HTML5 DnD on `<LayerRow>` + `useLayerDragDrop` composable (multi-aware) + new `POST .../elements/reparent-batch` endpoint (atomic, single transaction)
  - Decisions: see design-decisions table at top of this plan
  - Verification: backend tests + frontend tests + live smoke port 8080
- [ ] Commit: `git add docs/SPEC.md NALAR.md && git commit -m "docs(design): SPEC + NALAR entry for layer drag-to-reparent (single + multi)"`.

### Chunk 5 verification

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
rm -rf zig-out/bin
timeout 360 zig build
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
cd src/apps/desktop
timeout 180 node_modules/.bin/vitest run   # full suite
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build
timeout 240 bun run build 2>&1 | tail -n 5
```

Expected: all green; `.js` files emitted by vue-tsc are cleaned before commit; SPEC + NALAR are updated; live smoke port 8080 confirms the wire (single + batch + cycle rejection + leave-group).

---

## Deferred (out of scope for this plan)

- **Drop position within group** (drop top/middle/bottom of group row to land at the precise position). Requires a 3-zone drop target UI + an `insertion_index` parameter in the wire. Plan as `2026-07-30-design-reparent-with-position` once the basic reparent is comfortable.
- **Drag-and-drop on the canvas** (in addition to the panel) — i.e. dragging a rectangle INTO the bounds of a visible group on the canvas to reparent it. Different coordinate space, different drop detection. Plan as a separate feature.
- **Snap-to-group-edges on canvas drag** — when dragging an element over a group on the canvas, show a violet ring around the group + auto-reparent on pointerup. Different UX model (auto-reparent vs explicit drop).
- **Marquee drag-select + drag-reparent in one motion** — combines multi-select with drag.
- **Drag-to-reorder-by-z-index via the LayersPanel ▲▼ buttons** — currently the existing ▲▼ emit a `reorder` event that the parent does not translate to a backend call. Out of scope here; if needed, plan as `2026-07-30-design-fixes-broken-layer-reorder` (this is a latent bug).

---

## Pitfalls & gotchas

- **Don't write static-contract tests.** Per `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`: every test must be a real behavioural call. The `LayerRow.dragDrop.spec.ts` MUST trigger real DOM events via `wrapper.trigger('dragstart', ...)` and assert classes.
- **HTML5 `dragover.prevent`** — Vue's `@dragover` does NOT call `preventDefault` by default; you need the explicit `.prevent` modifier to allow the drop target to actually receive a `drop` event. Without this, the drop target receives `dragenter`/`dragleave` only and the drop never fires.
- **`draggable` propagates to children** — setting `draggable=true` on the row makes EVERY descendant draggable too. The action buttons (▲▼×) need `draggable="false"` explicitly, otherwise clicking × initiates a drag of the row and the click never fires the delete.
- **`useLayerDragDrop`'s reactivity** — `elements` is a getter so the composable sees fresh data on each call, but `isAncestor` walks a JS array (`find`). For a page with thousands of elements this is O(N²) per drop. Acceptable for v1 (design pages rarely exceed 100 elements).
- **Cycle detection for multi-drag** — a target is INVALID if ANY dragged element is the target itself OR a descendant of the target. The composable iterates `sourceIds` and runs `isAncestor(targetId, src)` for each. This correctly handles the case "user selects a parent group + its child + drags them onto the child" (would cycle).
- **Empty string vs null parent_id** — the backend's `updateElement` treats `""` as "no parent" (top-level) because `COALESCE(parent_id, '')` is the SQL convention. The frontend MUST send `parent_id: ''` for leave-group, not `parent_id: null`. In the BATCH endpoint, `new_parent_id` IS allowed to be `null` (handler translates to SQL NULL); in the single PUT, the field is `string` (matches the existing `updateDesignElement` partial-of-DesignElement shape).
- **vue-tsc emits `.js` files** next to `.vue`/`.ts` sources when `noEmit:false` (per `.nalar/skills/vue-tsc-build-emits-js-files/SKILL.MD`). Clean them with `git status -- '*.js' '*.vue.js'` before committing.
- **Don't forget the `setActivePinia(createPinia())` setup** in any new vitest spec that uses `useWorkspacesStore()` or `useNotificationStore()` (per `.nalar/memories/nalar-frontend-patterns.md`).
- **The existing `reorder` emit chain is broken** — LayerRow ▲ → LayersPanel `reorder` emit → DesignView `reorderElements` emit → ... → no parent handler. This is a separate bug; do NOT try to fix it as part of this plan (the `reparent` emit + handler is a different wire).
- **Lazy analysis on `addExecutable`** — the handler changes in Chunk 1 + 1b do NOT fail `zig build test` if exercised only in handler tests; run `zig build install:linux:system` to catch type errors that lazy analysis hides (per `.nalar/memories/zig-build-and-test.md`).
- **`failed command:` is harmless** — `zig build test` prints a "failed command:" line above its summary when stderr is non-empty, but it's NOT a failure indicator (per `.nalar/memories/zig-build-and-test.md` §"failed command: in zig build output is misleading"). Look at the `Build Summary: N/N steps succeeded` line for ground truth.
- **Multi-drag `position` ordering** — when a batch of N elements is dropped into a group, each element gets a position at `MAX(siblings.position) + (its_index_in_input + 1)`. Re-querying `MAX(position)` between each UPDATE ensures the second element lands at the FIRST+1 (not the FIRST again). Use a SEPARATE SELECT MAX per element in the batch (don't share one value).
- **Batch cycle check is per-element + all-or-nothing** — the model runs `hasAncestorCycle` for EACH element BEFORE writing any. If ANY element fails, the whole batch returns 400 with the offending element id in the error message; no DB writes happen. The frontend toast should display the error verbatim (so the user knows WHICH element caused the rejection).
- **Backend HTTP status for CycleDetected** — return 400 (Bad Request) with the message `BadReparent: <element_id> would create a cycle`. NOT 409 (Conflict) — 409 is reserved for `CrossPageIds` in this codebase's design handlers. Keep the convention consistent.

---

## Reference

- `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md` — no grep tests
- `~/.config/nalar/memories/no-comments-on-logger-calls.md` — no decorator comments
- `~/.config/nalar/memories/nalar-frontend-patterns.md` — vue-tsc is type-check; `apiFetch` mock shape; jsdom color normalization
- `~/.config/nalar/memories/nalar-backend-architecture.md` — handler thin-wrapper; per-request arena; parseFromSliceLeaky
- `~/.config/nalar/memories/zig-build-and-test.md` — lazy analysis trap, full build command sequence
- `~/.config/nalar/memories/zig-sqlite-patterns.md` — `db.exec` only binds TEXT; transaction design
- `~/.config/nalar/memories/zig-0.16-stdlib-changes.md` — Zig 0.16 stdlib changes
- `~/.config/nalar/memories/zig-cross-platform.md` — `std.c.*` patterns for cross-platform Windows/macOS
- `.nalar/memories/design-tab-button-needs-full-wire.md` — silent partial-wiring gotcha; preventive check on the new wire
- `.nalar/memories/applayout-close-handlers-strip-url-params.md` — same partial-wiring family
- `.nalar/memories/kanban-create-shape-mismatch-untitled-project.md` — wire-shape mismatch debugging pattern
- Existing plan: `docs/superpowers/plans/2026-07-29-design-right-click-group-menu.md` — the closest neighbour (group/ungroup + reorder); siblings in same family
- Existing plan: `docs/superpowers/plans/2026-07-28-grouped-layers.md` — the original `parent_id` schema migration + tree rendering