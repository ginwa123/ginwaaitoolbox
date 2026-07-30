# Design Element parent_id Tool Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the LLM see and mutate the parent/group hierarchy of design elements, so it can correctly nest new elements inside existing frames/groups instead of dropping them at the top level.

**Architecture:** Three coordinated changes to the design tool surface. (1) `set_design_page`'s `<element>` response gains a `parent_id="elem_xxx"` attribute (or empty for top-level) so the LLM can discover the existing hierarchy in a single query. (2) `add_element` gains an optional `parent_id` parameter that flows through `design_model.addElement` into the SQL INSERT. (3) A new `set_element_parent` tool lets the LLM re-parent existing top-level elements into an existing group/frame, with cycle detection and container-type validation.

**Tech Stack:** Zig 0.16 (backend), existing `nalarcore.ai_mod.design_model` helpers, SQLite (migration-057 schema is already in place — no new migrations).

## Global Constraints

- TDD: every change ships with a behavioural test that fails before the change and passes after.
- **Never write static-contract tests** in this codebase (per project memory `static-contract-test-when-to-prefer-behavioural.md`). Wire-shape and tool-registration are validated by reading the source AND by calling the function.
- Cross-platform: every change must compile cleanly for `x86_64-linux-gnu` (the default test target), `x86_64-windows-gnu`, and `aarch64-macos`.
- Use existing helpers (`helpers.sanitize.sanitizeUtf8`, `xmlEscape`, etc.); don't reinvent.
- All existing tests must continue to pass — no breaking changes to the existing `set_design_page` or `add_element` shapes (additive only).

## Files to Touch (touch map)

| File | Change |
|---|---|
| `src/ai_workflow/tui/design_model.zig` | (a) Extend `AddElementInput` with `parent_id: ?[]const u8 = null`. (b) `addElement` validates parent_id (if non-null): element exists, is on same page, is type `group` or `frame`. (c) Add new `setElementParent(allocator, db, element_id, new_parent_id)` function with cycle detection. |
| `src/modules/agent/tools/set_design_page.zig` | `toXml` emits `parent_id="elem_xxx"` (or empty) attribute per element. |
| `src/modules/agent/tools/add_design_element.zig` | `AddElementInput` gains `parent_id: ?[]const u8 = null`. Tool schema adds the parameter. `executeAddElementToString` threads it through. |
| `src/modules/agent/tools/set_element_parent.zig` | NEW tool. `SetElementParentInput { element_id, new_parent_id }`. Re-fetches the element and returns XML. |
| `src/ai_workflow/tui/agentic_loop/tools_exec_set_element_parent.zig` | NEW exec wrapper (parses JSON, calls tool, wraps output). |
| `src/ai_workflow/tui/agentic_loop/tools.zig` | Re-export `execSetElementParent`. |
| `src/ai_workflow/tui/agentic_loop/tool_registry.zig` | Add import + registry entry. |
| `src/root.zig` | Re-export `set_element_parent`. |
| `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` | Add `set_element_parent_mod.set_element_parent_tool,` to the equipped list. |
| `src/modules/agent/tools/test_runner.zig` | Register `set_element_parent_test.zig`. |
| `src/modules/agent/tools/set_element_parent_test.zig` | NEW behavioural tests. |
| `src/modules/agent/tools/add_design_element_test.zig` | Extend with parent_id behaviour tests. |
| `src/modules/agent/tools/set_design_page_test.zig` | Extend with parent_id wire-shape test. |

## Tasks

### Task 1 — `design_model.addElement` accepts `parent_id`

**Files:** `src/ai_workflow/tui/design_model.zig`

**Step 1.1** — Write the failing behavioural test.

Add a test file `src/ai_workflow/tui/design_model_add_element_parent_test.zig` with three tests:
- `addElement with parent_id sets the FK` — sets up a page + a parent frame, calls `addElement(..., .parent_id = frame_id)`, asserts the new row's parent_id matches.
- `addElement with parent_id pointing to a different page returns error.BadParentId` — sets up two pages, asserts the call fails.
- `addElement with parent_id pointing to a leaf type (rectangle) returns error.ParentNotContainer` — asserts the call fails because rectangles can't be parents.

Register the test in `src/ai_workflow/tui/test_runner.zig` (or wherever the existing design_model tests register; check `migration_*_test.zig` for the pattern).

**Step 1.2** — Run `timeout 180 zig build test --summary all` and confirm the tests fail with "no field named parent_id in struct design_model.AddElementInput".

**Step 1.3** — Modify `design_model.zig`:
- Extend `AddElementInput` (line 489) with `parent_id: ?[]const u8 = null` after `image_url`.
- Add error variant `BadParentId` and `ParentNotContainer` to `AddElementError`.
- In `addElement` (line 530), after the page lookup, if `input.parent_id != null`, validate:
  - The parent element exists (`SELECT id, page_id, type FROM design_page_elements WHERE id = ?`).
  - Same page as the new element (return `BadParentId`).
  - Type is `group` or `frame` (return `ParentNotContainer`).
- Update the SQL INSERT at line 606 to bind `parent_id`: replace the literal `NULL` in the VALUES list with `?,` and append the parent_id string to `&.{...}` args (using empty string for null since `SqliteBackend.exec` binds empty slice as NULL — the same trick `updateElement` uses; see memory `sqlite-backend-empty-slice-binds-as-null`).

**Step 1.4** — Re-run tests, confirm pass.

**Step 1.5** — Commit: `feat(design): addElement accepts parent_id (FK to existing group/frame)`.

### Task 2 — `design_model.setElementParent` (new function)

**Files:** `src/ai_workflow/tui/design_model.zig`

**Step 2.1** — Write the failing behavioural test.

Add a test in the same file as Task 1 (`design_model_add_element_parent_test.zig`) with four tests:
- `setElementParent moves an element into an existing group` — creates element A at top-level + group G on same page, calls `setElementParent(A, G)`, asserts A's parent_id is now G.
- `setElementParent to null moves the element to top-level` — creates element A parented to G, calls `setElementParent(A, null)`, asserts A's parent_id is empty.
- `setElementParent with parent_id of a leaf type returns error.ParentNotContainer`.
- `setElementParent with a cycle (G -> A -> G) returns error.CycleDetected` — sets up A parented to G, then tries to parent G to A.

**Step 2.2** — Run, confirm tests fail with "no function named setElementParent".

**Step 2.3** — Implement `setElementParent`:
```zig
pub const SetElementParentError = error{
    ElementNotFound,
    ParentNotFound,        // new_parent_id doesn't exist
    ParentNotContainer,    // new_parent_id type is not group/frame
    DifferentPages,        // element and parent are on different pages
    CycleDetected,         // new_parent is a descendant of element
    DbError,
    OutOfMemory,
};

pub fn setElementParent(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
    new_parent_id: ?[]const u8,
) anyerror!void {
    // 1. Look up element page_id + parent_id (current). Return
    //    ElementNotFound if missing.
    // 2. If new_parent_id is null → UPDATE parent_id = NULL WHERE id = element_id.
    // 3. If new_parent_id == current parent_id → no-op (success).
    // 4. Look up new_parent page_id + type. Return ParentNotFound if missing.
    // 5. Same page? Return DifferentPages if not.
    // 6. Type in {group, frame}? Return ParentNotContainer if not.
    // 7. Cycle detection: walk parent chain from new_parent upward;
    //    if element_id appears, return CycleDetected.
    // 8. UPDATE design_page_elements SET parent_id = ? WHERE id = element_id.
    // 9. Emit SSE design_element_updated.
}
```

For cycle detection, use a recursive CTE:
```sql
WITH RECURSIVE chain(id) AS (
  SELECT id FROM design_page_elements WHERE id = ?
  UNION ALL
  SELECT dpe.parent_id FROM design_page_elements dpe
    JOIN chain c ON dpe.id = c.id
    WHERE dpe.parent_id IS NOT NULL
)
SELECT 1 FROM chain WHERE id = ? LIMIT 1;
```
Bind `[new_parent_id, element_id]`. If a row returns, cycle exists.

**Step 2.4** — Re-run tests, confirm pass.

**Step 2.5** — Commit: `feat(design): setElementParent re-parents element with cycle detection`.

### Task 3 — `set_design_page` response includes `parent_id`

**Files:** `src/modules/agent/tools/set_design_page.zig`

**Step 3.1** — Write the failing behavioural test.

Extend `src/modules/agent/tools/set_design_page_test.zig` (or add a new behavioural test file `set_design_page_behavioral_test.zig`) with:
- `set_design_page response includes parent_id attribute` — set up page with parent + child elements, call `executeSetDesignPageToString`, assert the XML contains `parent_id="elem_..."` for the child and `parent_id=""` for the top-level.

**Step 3.2** — Run, confirm test fails (no `parent_id` attribute in XML).

**Step 3.3** — Modify `set_design_page.zig::toXml`:
After the existing `file_path` block (line 377), add:
```zig
if (e.parent_id.len > 0) {
    const v = try xmlEscape(allocator, e.parent_id);
    defer allocator.free(v);
    try xml.appendSlice(allocator, " parent_id=\"");
    try xml.appendSlice(allocator, v);
    try xml.appendSlice(allocator, "\"");
} else {
    try xml.appendSlice(allocator, " parent_id=\"\"");
}
```

**Step 3.4** — Re-run, confirm pass.

**Step 3.5** — Commit: `feat(design): set_design_page exposes parent_id in element XML`.

### Task 4 — `add_element` tool accepts `parent_id`

**Files:** `src/modules/agent/tools/add_design_element.zig`

**Step 4.1** — Write the failing behavioural test.

Extend `add_design_element_test.zig` with:
- `add_element tool accepts parent_id parameter` — calls `executeAddElementToString` with `parent_id = valid_frame_id`, asserts success and the returned XML contains `parent_id="elem_..."`.
- `add_element tool rejects parent_id with invalid prefix` — passes `parent_id = "not_elem"`, asserts error XML.

**Step 4.2** — Run, confirm tests fail (no `parent_id` in `AddElementInput`).

**Step 4.3** — Modify `add_design_element.zig`:
- Add `parent_id: ?[]const u8 = null` to `AddElementInput` (line 24).
- Add the parameter to the JSON schema (line 95-180).
- Add `validateParentIdShape` function (mirror of `validatePageIdShape`).
- In `executeAddElementToString`, after `validatePageIdShape`, call `validateParentIdShape` if `input.parent_id != null`.
- Pass `input.parent_id` through to `design_model.addElement`.

**Step 4.4** — Re-run, confirm pass.

**Step 4.5** — Commit: `feat(design): add_element tool accepts parent_id`.

### Task 5 — `set_element_parent` tool

**Files:** new files + registry wiring

**Step 5.1** — Write the failing behavioural test.

Create `src/modules/agent/tools/set_element_parent_test.zig` with:
- `set_element_parent moves element to new parent group` — sets up A + G, calls `executeSetElementParentToString`, asserts success XML and DB state.
- `set_element_parent rejects cycle` — asserts error.
- `set_element_parent rejects non-container parent` — asserts error.

Register in `src/modules/test_runner.zig`.

**Step 5.2** — Run, confirm test fails.

**Step 5.3** — Create `src/modules/agent/tools/set_element_parent.zig` mirroring `group_design_elements.zig` structure:
- `SetElementParentInput { element_id: []const u8, new_parent_id: ?[]const u8 = null }`.
- `set_element_parent_tool` AgentTool definition.
- `executeSetElementParentToString(allocator, db, input) ![]u8` — validates shapes, calls `design_model.setElementParent`, re-fetches the element, returns XML.

**Step 5.4** — Create `src/ai_workflow/tui/agentic_loop/tools_exec_set_element_parent.zig` (mirror of `tools_exec_group_elements.zig`).

**Step 5.5** — Wire it up:
- Add `pub const execSetElementParent = ...` to `src/ai_workflow/tui/agentic_loop/tools.zig`.
- Add the import + registry entry in `src/ai_workflow/tui/agentic_loop/tool_registry.zig`.
- Add `pub const set_element_parent = @import(...)` to `src/root.zig`.
- Add `set_element_parent_mod.set_element_parent_tool,` to `tools_equipped.zig`.

**Step 5.6** — Run tests, confirm pass.

**Step 5.7** — Commit: `feat(design): set_element_parent tool with cycle detection`.

### Task 6 — Cross-platform compile smoke + verification

**Step 6.1** — Run the canonical verification chain:
```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/design-element-parent-id
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
rm -rf zig-out/bin
timeout 360 zig build
```
All three must succeed.

**Step 6.2** — Cross-compile smoke:
```bash
cat > /tmp/cross_test.zig <<EOF
const nalarcore = @import("nalarcore");
const _ = nalarcore.set_element_parent.set_element_parent_tool;
pub fn main() void {}
EOF
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/cross_test.zig -Mnalarcore=src/root.zig
```
Both must exit 0.

**Step 6.3** — End-to-end smoke against port 8080 (never 8081):
1. `rm -rf /tmp/nalar-parent-smoke && env -i HOME=/tmp/nalar-parent-smoke PATH=$PATH ./zig-out/bin/nalar --port 8080 &`
2. Create workspace + design item + page.
3. Add a `frame` parent element via `add_element` (no parent_id → top-level).
4. Add a child `rectangle` via `add_element` WITH `parent_id = frame_id`.
5. `GET /api/workspaces/.../items/.../design/pages/.../elements` → assert child has `parent_id == frame_id`.
6. `POST /set_element_parent` with `new_parent_id = ""` → assert child is now top-level.

**Step 6.4** — Final commit: `chore(design): verification pass + cross-compile smoke`.

## Pitfalls

- **`SqliteBackend.exec` binds empty `[]const u8` as SQL NULL** (memory `sqlite-backend-empty-slice-binds-as-null`). The `parent_id` column is nullable. For `setElementParent(_, null)`, pass `""` empty string and let SQL bind as NULL — same trick used in `group_design_elements.zig`.
- **Cycle detection must use a recursive CTE**, not a naive walk — the chain can be arbitrarily deep and a `parent_id IS NOT NULL` predicate in the recursive leg is required to avoid infinite loops on NULL chains.
- **Don't break existing call sites.** `set_design_page`'s XML gains a new attribute — existing tests that don't reference `parent_id` keep passing (additive change). `add_element`'s `parent_id` is `?[]const u8 = null` (default null = top-level = existing behavior).
- **`tools_equipped.zig` list** — verify the `set_element_parent_mod.set_element_parent_tool,` entry exists with the trailing comma. The convention is `tool_name,` with the comma after each entry. A missing comma silently breaks the comptime list parse.
- **The new tool's JSON schema field for `new_parent_id`** must use `?string` not `string`. Otherwise the LLM can't pass `null` to unparent.
- **`parent_id` wire format** — empty string `""` for top-level (per SQL `COALESCE(parent_id, '')` convention), NOT `null`. The frontend already handles this in LayersPanel (`vue-3-empty-string-vs-null-mismatch.md` memory).

## Verification

- All 5 task commits present in `git log --oneline`.
- `zig build test --summary all` reports `N passed; 0 failed` (pre-existing flakes excluded).
- Cross-compile smoke (Windows + macOS) exits 0.
- Live API smoke against port 8080 confirms the new fields/endpoints work end-to-end.
- Project memory updated with the schema-37 fix.
