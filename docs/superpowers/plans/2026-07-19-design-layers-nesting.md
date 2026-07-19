# Design Mode — Layers Panel Nesting (parent_id) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `parent_id` end-to-end so designers / LLMs can nest elements inside `frame`/`group` containers and the Layers panel renders a real tree.

**Architecture:** Backend first (DB column already exists, just make it live), then LLM tool params, then frontend interface, then LayersPanel tree rendering, then prompt rewrite. No canvas changes.

**Tech Stack:** Zig 0.16 (backend), Vue 3 + TypeScript (frontend), SQLite (DB).

**Baseline:** `zig build test --summary all` → 1806/1813 pass, 4 pre-existing failures in `search_test.zig` (unrelated). Frontend `bun run build` clean, `bunx vitest run` green. Don't regress these numbers; don't try to fix the 4 unrelated failures.

---

## File Structure

| File | Responsibility for this PR |
|---|---|
| `src/ai_workflow/tui/design_model.zig` | Core: `DesignElement.parent_id`, query it, write it, cycle-detect, cascade on delete |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | Expose `parent_id` in `DesignElementResponse` JSON |
| `src/ai_workflow/tui/http_handlers/design_elements_create.zig` | HTTP body parses `parent_id`, passes through |
| `src/ai_workflow/tui/http_handlers/design_elements_update.zig` | HTTP body parses `parent_id` (empty = detach), passes through |
| `src/modules/agent/tools/add_design_element.zig` | LLM tool: `parent_id` schema param + XML response attribute |
| `src/modules/agent/tools/update_design_element.zig` | LLM tool: `parent_id` schema param (empty = detach) + XML attribute |
| `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` | Rewrite misleading nesting text |
| `src/apps/desktop/src/api/index.ts` | Frontend `DesignElement.parent_id` |
| `src/apps/desktop/src/components/design/LayersPanel.vue` | Tree rendering: depth, chevrons, expand/collapse |
| `src/apps/desktop/src/__tests__/LayersPanel.spec.ts` | Static-contract tests for tree shape |
| `src/ai_workflow/tui/design_model_test.zig` | Unit tests for parent_id flows |
| `src/modules/agent/tools/add_design_element_test.zig` | Schema param test |
| `src/modules/agent/tools/update_design_element_test.zig` | Schema param test |

---

## Chunk 1 — Backend data model + validation

### Task 1: Add `parent_id` to `DesignElement` struct + free functions

**Files:**
- Modify: `src/ai_workflow/tui/design_model.zig:368-392` (struct) and `:395-411` (`freeElements`) and `:954-967` (`freeElement`)

- [ ] **Step 1: Add field to struct**

In `design_model.zig`, in the `DesignElement` struct (line 368-392), add after `image_url`:

```zig
/// Optional parent element id. `null` = top-level. When set, refers
/// to a sibling element with `type IN ('frame', 'group')` on the
/// same page. Read in `getElement` / `listElements` (column 22 of
/// the SELECT — `de.parent_id`); the DB column was added by
/// Migration 057 but was unused until this PR.
parent_id: ?[]u8 = null,
```

- [ ] **Step 2: Update `freeElement`**

In `design_model.zig:954-967`, add inside the function body (before the closing `}`):

```zig
if (e.parent_id) |p| allocator.free(p);
```

- [ ] **Step 3: Update `freeElements`**

In `design_model.zig:395-411`, add inside the `for` body:

```zig
if (e.parent_id) |p| allocator.free(p);
```

- [ ] **Step 4: Run baseline build to confirm no breakage**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/design-layers-nesting && timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same `1806 pass, 3 skip, 4 fail` as baseline (the 4 pre-existing `search_test` failures). The struct change is purely additive (`parent_id: ?[]u8 = null` defaults to null), so existing tests that don't construct `parent_id` continue to compile.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/design_model.zig
git commit -m "feat(design): add parent_id field to DesignElement struct"
```

---

### Task 2: `getElement` SELECT reads `parent_id`

**Files:**
- Modify: `src/ai_workflow/tui/design_model.zig:914-923` (SELECT) and `:927-950` (mapping)

- [ ] **Step 1: Extend the SELECT**

In `getElement` (line 914-923), add one column to the SELECT list — `de.parent_id` — as the LAST column (after the existing `COALESCE(de.updated_at, '')`). The new SELECT becomes:

```zig
\\SELECT de.id, de.page_id, de.name, de.file_path,
\\       de.x, de.y, de.width, de.height, de.z_index, de.position,
\\       de.type, de.rotation, de.fill, de.stroke, de.stroke_width,
\\       de.corner_radius, de.opacity,
\\       de.text_content, de.text_style, de.image_url,
\\       COALESCE(de.created_at, ''), COALESCE(de.updated_at, ''),
\\       de.parent_id
\\FROM design_page_elements de
\\WHERE de.id = ?
```

- [ ] **Step 2: Extend the struct mapping**

In the `return .{ ... }` block (line 927-950), add as the LAST field (after `.updated_at`):

```zig
.parent_id = if (row.values[22].len == 0) null else try allocator.dupe(u8, row.values[22]),
```

- [ ] **Step 3: Run build**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same baseline counts.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/design_model.zig
git commit -m "feat(design): getElement reads parent_id column"
```

---

### Task 3: `listElements` SELECT reads `parent_id`

**Files:**
- Modify: `src/ai_workflow/tui/design_model.zig:841-...` (the SELECT in `listElements`)

- [ ] **Step 1: Find the `listElements` SQL**

Search for `fn listElements(` in `src/ai_workflow/tui/design_model.zig`. Read the body. Extend the SELECT to include `de.parent_id` and extend the row mapping (same pattern as Task 2).

(The exact row indices depend on the existing SELECT — read the file, mirror the change.)

- [ ] **Step 2: Run build**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same baseline counts.

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/design_model.zig
git commit -m "feat(design): listElements reads parent_id column"
```

---

### Task 4: `addElement` writes `parent_id` (with validation)

**Files:**
- Modify: `src/ai_workflow/tui/design_model.zig:425-441` (`AddElementInput`)
- Modify: `src/ai_workflow/tui/design_model.zig:475-559` (the INSERT)
- Modify: error set / docs

- [ ] **Step 1: Extend `AddElementInput`**

In `design_model.zig:425-441`, add at the end of the struct:

```zig
/// Optional parent element id. When set, the referenced element must:
///   1. exist,
///   2. belong to the same page_id,
///   3. have type `frame` or `group` (containers).
/// Pass `null` (or omit) for top-level elements. Validation runs
/// before INSERT; mismatches return `InvalidParent`.
parent_id: ?[]const u8 = null,
```

- [ ] **Step 2: Add error variant**

Find `pub const AddElementError` (around line 443). Add variant:

```zig
/// `parent_id` was set but the referenced element is missing,
/// on a different page, or not a frame/group.
InvalidParent,
```

- [ ] **Step 3: Add `validateParent` helper**

Add a new private function near `addElement`:

```zig
/// When `input.parent_id` is set, verify the parent:
///   1. exists in `design_page_elements`,
///   2. has the same `page_id`,
///   3. has `type IN ('frame', 'group')`.
/// Returns `InvalidParent` on any mismatch.
fn validateParent(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    parent_id: []const u8,
) !void {
    var q = try db.query(allocator,
        \\SELECT de.page_id, de.type
        \\FROM design_page_elements de
        \\WHERE de.id = ?
    , &.{parent_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.InvalidParent;
    defer row.deinit(allocator);
    if (!std.mem.eql(u8, row.values[0], page_id)) return error.InvalidParent;
    const etype = row.values[1];
    if (!std.mem.eql(u8, etype, "frame") and
        !std.mem.eql(u8, etype, "group")) return error.InvalidParent;
}
```

- [ ] **Step 4: Call `validateParent` in `addElement`**

In `addElement`, after the existing page_id check (around line 475), add:

```zig
if (input.parent_id) |pid| {
    try validateParent(allocator, db, input.page_id, pid);
}
```

- [ ] **Step 5: Update the INSERT to write `parent_id`**

In `addElement`'s INSERT (line 542-559), change the column list:

```zig
\\INSERT INTO design_page_elements (
\\    id, page_id, name, file_path, x, y, width, height, z_index, position,
\\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
\\    text_content, text_style, image_url, parent_id,
\\    created_at, updated_at
\\) VALUES (
\\    ?, ?, ?, ?, ?, ?, ?, ?, 0,
\\    COALESCE((SELECT MAX(de.position) FROM design_page_elements de
\\        WHERE de.page_id = ?), -1) + 1,
\\    ?, ?, ?, '', 0, ?, ?, '', '', ?, NULL,
\\    datetime('now'), datetime('now')
\\)
```

(Only change: the literal `NULL` at the end of the parent_id column position was the previous hard-code; now it's `?` so we can pass either `NULL` or the parent_id.)

- [ ] **Step 6: Add the new arg to the `&.{...}` argv**

Find the `&.{...}` argv in the `db.exec(...,  .{ ... })` call. After `image_url` (or wherever the existing args end), append:

```zig
parent_id_str,
```

Where `parent_id_str` is a new variable created just before the `db.exec`:

```zig
const parent_id_str: ?[]const u8 = if (input.parent_id) |p| p else null;
```

(The `exec` binding treats `null` and `&.{...}` indices uniformly — see project memory `db.exec only binds TEXT`. For a NULL binding, pass an empty slice or use the simpler `if (input.parent_id) |p| p else ""` pattern.)

- [ ] **Step 7: Run build + run model tests**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same baseline counts. No existing test calls `addElement` with `parent_id`, so the new parameter is dormant.

- [ ] **Step 8: Commit**

```bash
git add src/ai_workflow/tui/design_model.zig
git commit -m "feat(design): addElement accepts parent_id with validation"
```

---

### Task 5: `updateElement` writes `parent_id` (with cycle detection)

**Files:**
- Modify: `src/ai_workflow/tui/design_model.zig:603-621` (`UpdateElementInput`)
- Modify: `src/ai_workflow/tui/design_model.zig:677-720` (the SET builder)

- [ ] **Step 1: Extend `UpdateElementInput`**

In `design_model.zig:603-621`, add:

```zig
/// Re-parent this element. Behavior:
///   - `null` (omitted) — leave parent unchanged.
///   - non-empty string — set parent_id to that value (must reference
///     a frame/group on the same page; cycle to self-or-descendant
///     is rejected with `InvalidParent`).
///   - empty string `""` — DETACH: clear parent_id (set DB column NULL).
parent_id: ?[]const u8 = null,
```

- [ ] **Step 2: Add helper to walk the ancestor chain**

The cycle detector: "would setting this element's parent to `parent_id` create a cycle?" — i.e., is `element_id` reachable from `parent_id` via parent_of?

```zig
/// Returns true if `target` is reachable from `start` (inclusive) via
/// the parent_id chain. Used to reject re-parenting that would form
/// a cycle: passing `target = element_id`, `start = candidate_parent_id`.
fn ancestorReaches(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    start: []const u8,
    target: []const u8,
) !bool {
    // Iterative: walk up from `start` looking for `target`. Bound
    // iterations by element count to defend against accidental loops
    // (the DB shouldn't have cycles, but let's not hang if it does).
    var current: ?[]u8 = try allocator.dupe(u8, start);
    defer if (current) |c| allocator.free(c);
    var iter: usize = 0;
    while (current) |cur| : (iter += 1) {
        if (iter > 4096) return error.TooManyAncestors;
        if (std.mem.eql(u8, cur, target)) return true;
        var q = try db.query(allocator,
            \\SELECT parent_id FROM design_page_elements WHERE id = ?
        , &.{cur});
        defer q.deinit();
        const row = try q.next();
        if (row) |r| {
            defer r.deinit(allocator);
            const next = r.values[0];
            if (next.len == 0) return false;
            if (current) |c| allocator.free(c);
            current = try allocator.dupe(u8, next);
        } else {
            return false;
        }
    }
    return false;
}
```

Add `TooManyAncestors` to the error set of `updateElement` (or use `anyerror!` if it's already `anyerror`).

- [ ] **Step 3: Add the `parent_id` branch to the SET builder**

In `updateElement` (around line 707-720, where the SET/args build runs), add:

```zig
if (input.parent_id) |v| {
    // Empty string = detach (set NULL). Otherwise check cycle.
    if (v.len == 0) {
        try sets.append(allocator, "parent_id = NULL");
        // No argv entry — NULL literal in the SQL.
    } else {
        // Reject re-parenting to self.
        if (std.mem.eql(u8, v, input.element_id)) return error.InvalidParent;
        // Reject creating a cycle.
        if (try ancestorReaches(allocator, db, v, input.element_id)) {
            return error.InvalidParent;
        }
        // Validate target is frame/group on same page.
        // (Reuse validateParent — but it requires page_id; lookup
        // page_id from element_id first, then call validateParent.)
        // For simplicity, inline the check:
        var q = try db.query(allocator,
            \\SELECT de.page_id, de.type
            \\FROM design_page_elements de
            \\WHERE de.id = ?
        , &.{v});
        defer q.deinit();
        const row = (try q.next()) orelse return error.InvalidParent;
        defer row.deinit(allocator);
        const ctx_q = try db.query(allocator,
            \\SELECT page_id FROM design_page_elements WHERE id = ?
        , &.{input.element_id});
        defer ctx_q.deinit();
        const ctx_row = (try ctx_q.next()) orelse return error.ElementNotFound;
        defer ctx_row.deinit(allocator);
        if (!std.mem.eql(u8, row.values[0], ctx_row.values[0])) return error.InvalidParent;
        const etype = row.values[1];
        if (!std.mem.eql(u8, etype, "frame") and
            !std.mem.eql(u8, etype, "group")) return error.InvalidParent;
        try sets.append(allocator, "parent_id = ?");
        try args.append(allocator, v);
    }
}
```

- [ ] **Step 4: Add `InvalidParent` to the error set**

If `updateElement` returns `anyerror`, you can just call `return error.InvalidParent` from inside. Otherwise, add `InvalidParent` to the named error set.

- [ ] **Step 5: Run build**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same baseline counts. (No existing test passes `parent_id` to updateElement.)

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/design_model.zig
git commit -m "feat(design): updateElement accepts parent_id with cycle detection"
```

---

### Task 6: `deleteElement` cascades children to NULL

**Files:**
- Modify: `src/ai_workflow/tui/design_model.zig` — find the `deleteElement` function

- [ ] **Step 1: Find `deleteElement`**

Search for `fn deleteElement(` in `design_model.zig`. Read the body.

- [ ] **Step 2: Add a cascading UPDATE before/after the DELETE**

Before the existing `DELETE FROM design_page_elements WHERE id = ?`, run:

```zig
try db.exec(allocator,
    \\UPDATE design_page_elements SET parent_id = NULL WHERE parent_id = ?
, &.{element_id});
```

(So children become top-level when the parent is deleted.)

- [ ] **Step 3: Run build**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same baseline counts.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/design_model.zig
git commit -m "feat(design): deleteElement re-parents children to top-level"
```

---

### Task 7: Tests for parent_id flows in `design_model_test.zig`

**Files:**
- Modify: `src/ai_workflow/tui/design_model_test.zig`

- [ ] **Step 1: Read the test file's setup pattern**

Read the first ~100 lines to understand how it builds an in-memory DB, applies migrations, and constructs `DesignElement`-shaped test rows. This file should already have a helper for "create a frame, create a child" scenarios — find the existing addElement test cases to mirror the pattern.

- [ ] **Step 2: Write `addElement with parent_id sets the column`**

```zig
test "addElement accepts parent_id pointing at a frame on the same page" {
    // Setup: create page, create a frame element, then add a child.
    // Call addElement with parent_id pointing at the frame.
    // Assert: getElement(parent_id).parent_id == frame.id
}

test "addElement rejects parent_id pointing at a rectangle" {
    // Create page + rectangle + try to add child with parent_id = rect.id
    // Assert: returns error.InvalidParent
}

test "addElement rejects parent_id pointing at a frame on a different page" {
    // Create page A, page B, frame on A, try add child on B with parent_id = A-frame.id
    // Assert: returns error.InvalidParent
}
```

- [ ] **Step 3: Write cycle-detection tests**

```zig
test "updateElement rejects self-parent (element_id == parent_id)" {
    // Create element, try updateElement(parent_id = element_id)
    // Assert: returns error.InvalidParent
}

test "updateElement rejects cycle via grandchild" {
    // Create A (frame), B (child of A), C (would-be-child of A)
    // Try to update A with parent_id = C — would form cycle if C is a desc of A.
    // Actually that's the trivial case. The real test is:
    // Create A (frame), B (frame, child of A), C (rect, child of B).
    // Try to update B with parent_id = C — C is a descendant, would create cycle.
    // Assert: returns error.InvalidParent
}
```

- [ ] **Step 4: Write cascade-on-delete test**

```zig
test "deleteElement re-parents children to top-level" {
    // Create A (frame), B (child of A). Delete A. Assert: getElement(B).parent_id == null
}
```

- [ ] **Step 5: Write detach-via-empty-string test**

```zig
test "updateElement with parent_id='' detaches the element" {
    // Create A (frame), B (child of A).
    // Call updateElement(B, parent_id = "").
    // Assert: getElement(B).parent_id == null
}
```

- [ ] **Step 6: Run new tests**

Run: `timeout 240 zig build test --summary all 2>&1 | rg -A 2 'addElement accepts parent_id|updateElement rejects|deleteElement re-parents'`

Expected: each new test passes.

- [ ] **Step 7: Full build**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: `1811 pass, 3 skip, 4 fail` (5 new tests added, all pass; the 4 search_test failures remain).

- [ ] **Step 8: Commit**

```bash
git add src/ai_workflow/tui/design_model_test.zig
git commit -m "test(design): add parent_id flow tests (cycle, cascade, detach)"
```

---

## Chunk 2 — Wire `parent_id` through the HTTP response + handlers

### Task 8: `DesignElementResponse` exposes `parent_id`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig:745-770` (`DesignElementResponse`)
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig:776-801` (`makeDesignElementResponse`)

- [ ] **Step 1: Add field to struct**

In `http_response.zig`, in `DesignElementResponse` (line 745-770), add as the LAST field (before the closing `};`):

```zig
/// `null` for top-level elements. Matches the DB column directly
/// (`de.parent_id` in the SQL SELECT). The HTTP wire format is
/// `parent_id: null | string` (NOT empty string — distinguishes
/// "no parent" from "empty attribute").
parent_id: ?[]const u8,
```

- [ ] **Step 2: Add to mapper**

In `makeDesignElementResponse` (line 776-801), add:

```zig
.parent_id = elem.parent_id,
```

before the `.created_at` / `.updated_at` fields.

- [ ] **Step 3: Run build + run an HTTP-touching test if available**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same counts as after Chunk 1.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/http_response.zig
git commit -m "feat(design): DesignElementResponse exposes parent_id"
```

---

### Task 9: `design_elements_create.zig` parses + propagates `parent_id`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/design_elements_create.zig:53-68` (body)
- Modify: `src/ai_workflow/tui/http_handlers/design_elements_create.zig:104-123` (input)
- Modify: useCase at line 151-203 (delegation)
- Modify: error→HTTP mapping at line 304-330

- [ ] **Step 1: Add to body struct**

In `CreateElementBody` (line 53-68), add:

```zig
parent_id: ?[]const u8 = null,
```

- [ ] **Step 2: Add to `CreateElementInput`**

In `CreateElementInput` (line 104-123), add at the end:

```zig
parent_id: ?[]const u8 = null,
```

- [ ] **Step 3: Add `InvalidParent` to the error set**

In `DesignElementCreateError` (line 77-101), add variant `InvalidParent`.

- [ ] **Step 4: Plumb through useCase**

In the `useCase` function (line 151-203), pass `parent_id` through to `design_model.addElement(allocator, db, io, .{ ... .parent_id = input.parent_id, ... })`. Add the `error.InvalidParent` arm to the catch at line 178-184.

- [ ] **Step 5: Add to handler body parsing + status/message switch**

In the handler (line 248-303), after parsing the body, copy `parsed.parent_id` into the input (with default `null`). Add `error.InvalidParent => 400` to the status switch and `"parent_id must reference a frame or group on the same page"` to the message switch.

- [ ] **Step 6: Run build**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same counts.

- [ ] **Step 7: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/design_elements_create.zig
git commit -m "feat(design): POST element accepts parent_id in body"
```

---

### Task 10: `design_elements_update.zig` parses + propagates `parent_id` (empty = detach)

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/design_elements_update.zig`

- [ ] **Step 1: Mirror the create-handler changes**

Do the same edits as Task 9, but for the update handler:
- Add `parent_id: ?[]const u8 = null` to body + input
- Add `InvalidParent` to error set
- Plumb through to `design_model.updateElement(allocator, db, .{ ..., .parent_id = input.parent_id, ... })`
- Add status/message for `InvalidParent` (400, same message)

- [ ] **Step 2: Document the empty-string = detach convention**

In the body struct doc, add:

```zig
/// Empty string "" means DETACH (set parent_id to NULL). Omit or
/// pass null to leave parent unchanged.
parent_id: ?[]const u8 = null,
```

- [ ] **Step 3: Run build**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same counts.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/design_elements_update.zig
git commit -m "feat(design): PATCH element accepts parent_id (empty = detach)"
```

---

## Chunk 3 — Wire `parent_id` through the LLM tool surface

### Task 11: `add_design_element.zig` adds `parent_id` schema + XML

**Files:**
- Modify: `src/modules/agent/tools/add_design_element.zig:24-70` (`AddElementInput`)
- Modify: `src/modules/agent/tools/add_design_element.zig:94-173` (JSON schema)
- Modify: `src/modules/agent/tools/add_design_element.zig:434-507` (executor)
- Modify: `src/modules/agent/tools/add_design_element.zig:253-344` (`elementToXml`)

- [ ] **Step 1: Add `parent_id` to `AddElementInput`**

In `AddElementInput` (line 24-70), add after `image_url`:

```zig
/// Optional parent element id. When set, the referenced element must
/// exist on the same page and be of type `frame` or `group`. Omit
/// (or pass empty string) for top-level elements.
parent_id: []const u8 = "",
```

- [ ] **Step 2: Add to JSON schema properties**

In the schema properties (line 96-172), after the `image_url` property block, add a new property:

```zig
.{
    .name = "parent_id",
    .type = "string",
    .description = "Optional parent element id. Must reference a 'frame' or 'group' element on the same page. Omit (or pass '') for top-level elements. The element must already exist (create the parent first via a separate add_element call).",
},
```

- [ ] **Step 3: Add validation in executor**

In `executeAddElementToString` (line 434-507), after the existing `validateHtmlShape` call, call a new `validateParentIdShape` function (create it next to the others). The validation just checks shape (non-numeric format is fine since IDs are strings); the DB validation in `addElement` will reject mismatches.

For simplicity, just check that `input.parent_id` is `""` or starts with `elem_` — same pattern as the page_id validator:

```zig
if (input.parent_id.len > 0 and !std.mem.startsWith(u8, input.parent_id, "elem_")) {
    return try errorXml(allocator,
        "parent_id must start with 'elem_' (find it in the id=\"...\" attribute of a set_design_page response) or be omitted for top-level elements");
}
```

- [ ] **Step 4: Pass through to addElement**

In the executor, after the `fill_for_db` shim, add:

```zig
const parent_id_opt: ?[]const u8 = if (input.parent_id.len == 0) null else input.parent_id;
```

And pass `.parent_id = parent_id_opt` to the `addElement` call. Add the `error.InvalidParent` arm to the catch.

- [ ] **Step 5: Update XML response**

In `elementToXml` (line 253-344), after the `image_url` attribute block, add:

```zig
if (elem.parent_id) |pid| {
    if (pid.len > 0) {
        const v = try xmlEscape(allocator, pid);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " parent_id=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    }
}
```

- [ ] **Step 6: Run build**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same counts.

- [ ] **Step 7: Commit**

```bash
git add src/modules/agent/tools/add_design_element.zig
git commit -m "feat(design): add_element tool accepts parent_id"
```

---

### Task 12: `update_design_element.zig` adds `parent_id` schema + XML

**Files:**
- Modify: `src/modules/agent/tools/update_design_element.zig`

- [ ] **Step 1: Mirror Task 11 changes for update**

Add `parent_id: []const u8 = ""` to `UpdateElementInput` (default empty). Add the property to the JSON schema. Add the validator + pass-through (empty → detach).

- [ ] **Step 2: Add `parent_id=""` semantics to description**

In the schema property description, document:

```
"Empty string '' DETACHES the element (clears its parent_id). Omit (or pass null) to leave parent unchanged. To re-parent, pass the new parent's element id."
```

- [ ] **Step 3: Run build**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same counts.

- [ ] **Step 4: Commit**

```bash
git add src/modules/agent/tools/update_design_element.zig
git commit -m "feat(design): update_element tool accepts parent_id (empty = detach)"
```

---

### Task 13: Static-contract tests for the `parent_id` schema param

**Files:**
- Modify: `src/modules/agent/tools/add_design_element_test.zig`
- Modify: `src/modules/agent/tools/update_design_element_test.zig`

- [ ] **Step 1: Read the existing test patterns**

Look at how `add_design_element_test.zig` checks other params (e.g., `page_id`, `name`). Should be simple `expect(source).toContain(...)` assertions.

- [ ] **Step 2: Add the param presence assertions**

For `add_design_element_test.zig`:

```zig
test "add_element tool has parent_id parameter" {
    expect(source).toContain('.name = "parent_id"');
    expect(source).toContain("frame");  // mentioned in description
    expect(source).toContain("group");  // mentioned in description
}
```

For `update_design_element_test.zig`:

```zig
test "update_element tool has parent_id parameter" {
    expect(source).toContain('.name = "parent_id"');
    expect(source).toContain("DETACH");
    expect(source).toContain("parent_id");
}
```

(Adjust phrasing to match the exact strings in the source.)

- [ ] **Step 3: Run tests**

Run: `timeout 240 zig build test --summary all 2>&1 | rg 'add_element tool has parent_id|update_element tool has parent_id' | head -n 5`

Expected: each new test passes.

- [ ] **Step 4: Full build**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: `1813 pass, 3 skip, 4 fail` (2 more new tests).

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/add_design_element_test.zig src/modules/agent/tools/update_design_element_test.zig
git commit -m "test(design): add parent_id schema contract tests"
```

---

## Chunk 4 — System-prompt rewrite + frontend interface + LayersPanel tree

### Task 14: Rewrite the misleading nesting text in `BuildDesignCanvasPrompt`

**Files:**
- Modify: `src/ai_workflow/tui/build_messages_for_agent_prompt.zig:819-837` (the static system-prompt text)

- [ ] **Step 1: Replace the misleading `frame`/`group` paragraphs**

Find the existing text:
```
\- `frame` — a reusable frame (template) — same properties as
\  rectangle, but flagged as a frame for the layers panel.
\- `group` — a logical group of child elements. The element's
\  own `html` is the container; children are added by calling
\  `add_element` with subsequent `position` numbers in the
\  same group.
```

Replace with:
```
\- `frame` — a container that CAN hold children. Create the frame first
\  (via `add_element` with `type='frame'`), then create children with
\  `add_element(..., parent_id=<frame_id>)` to nest them inside. Frames
\  and groups appear as parents in the Layers panel; their children
\  render indented underneath.
\- `group` — same as `frame` but does not visually clip its children in
\  the canvas (children may overflow the group's bounds). Use `frame`
\  for visual containment (e.g. an app window containing panels); use
\  `group` for logical grouping (e.g. a set of icon buttons that you
\  want to operate as one unit).
\
\**Nesting rules:** the parent must exist BEFORE the child (two
\`add_element` calls — first the parent, then the child with
\`parent_id`). The parent must have `type='frame'` or `type='group'`.
\The parent and child must be on the SAME page. To re-parent an
\existing element, call `update_element(element_id, parent_id='<new>')`;
\to detach, pass `parent_id=''`.
```

- [ ] **Step 2: Run build**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: same counts.

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/build_messages_for_agent_prompt.zig
git commit -m "fix(design): correct the misleading nesting instructions in the system prompt"
```

---

### Task 15: Frontend `DesignElement` interface gets `parent_id`

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:190-213` (`DesignElement` interface)

- [ ] **Step 1: Add field to interface**

In `src/apps/desktop/src/api/index.ts`, after `position` and before `created_at`, add:

```ts
// Optional parent element id. Null/undefined = top-level. Points to
// an element with type='frame' or 'group' on the same page. Set via
// add_element / update_element's `parent_id` field; populated by the
// backend's parent_id column (Migration 057).
parent_id?: string | null
```

- [ ] **Step 2: Run TypeScript check**

Run: `cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 20`

Expected: type-check clean. The new field is optional + nullable, so no existing call site needs changes.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(design): DesignElement interface gets parent_id"
```

---

### Task 16: Rewrite `LayersPanel.vue` to render a tree

**Files:**
- Modify: `src/apps/desktop/src/components/design/LayersPanel.vue`

This is the heart of the UX. Read the current 210-line file fully before rewriting.

- [ ] **Step 1: Keep props + emits the same**

The public API (`elements`, `selectedElementId`, `readonly`, `select`, `reorder`, `delete`) MUST stay identical — `DesignView.vue` wires them. Don't change the prop names or event names.

- [ ] **Step 2: Replace the flat `layers` computed with a `tree` computed**

Build an adjacency map (`parentId -> children[]`) from the elements, then a depth-first traversal that produces a flat list of `{ element, depth, childCount }` rows in the order they'll render top-to-bottom.

```ts
interface LayerRow {
  element: DesignElement
  depth: number
  // number of immediate children (used to decide whether to show the chevron)
  childCount: number
  // whether this row's children are expanded (UI state, not derived from props)
  hasChildren: boolean
}

// Module-level Map<parentId, expanded> — survives across re-renders
const expandedParents = reactive(new Map<string, boolean>())

// Top-level = no parent_id. Children = lookup in adjacency map.
const tree = computed<LayerRow[]>(() => {
  const childMap = new Map<string, DesignElement[]>()
  for (const e of props.elements) {
    const key = e.parent_id ?? '__root__'
    if (!childMap.has(key)) childMap.set(key, [])
    childMap.get(key)!.push(e)
  }
  // Sort each level by z_index DESC, then position ASC (same as before).
  for (const arr of childMap.values()) {
    arr.sort((a, b) => {
      if (b.z_index !== a.z_index) return b.z_index - a.z_index
      return a.position - b.position
    })
  }
  const result: LayerRow[] = []
  const walk = (parentKey: string, depth: number): void => {
    const kids = childMap.get(parentKey) ?? []
    for (const k of kids) {
      const myKey = k.id
      const grandkids = childMap.get(myKey) ?? []
      const isExpanded = expandedParents.get(myKey) !== false
      result.push({
        element: k,
        depth,
        childCount: grandkids.length,
        hasChildren: grandkids.length > 0,
      })
      if (isExpanded) walk(myKey, depth + 1)
    }
  }
  walk('__root__', 0)
  return result
})
```

Default `expandedParents.get(myKey) === undefined → true` (expanded by default; only explicit `false` collapses).

- [ ] **Step 3: Add a chevron button before each row that has children**

```vue
<button
  v-if="row.hasChildren"
  type="button"
  class="shrink-0 w-3 text-xs"
  :aria-label="row.element.name + ' has ' + row.childCount + ' children, click to ' + (isExpanded ? 'collapse' : 'expand')"
  :data-testid="`design-layer-toggle-${row.element.id}`"
  @click.stop="toggleExpanded(row.element.id)"
>{{ isExpanded ? '▼' : '▶' }}</button>
<div v-else class="shrink-0 w-3" />
```

(Where `isExpanded` reads from `expandedParents.get(row.element.id) !== false`.)

- [ ] **Step 4: Add depth-based indentation**

On the row `<div>`, set `paddingLeft` from `row.depth`:

```vue
<div
  :key="row.element.id"
  :style="{ paddingLeft: `${8 + row.depth * 16}px` }"
  ...
>
```

- [ ] **Step 5: Preserve reorder + delete behavior on tree rows**

The up/down buttons swap the element with its SIBLING (the previous/next row in the flattened tree). Update `handleMoveUp`/`Down` to look up via the `tree` array, not the flat `layers` array.

The `reorder` event still emits the full ordered list of element ids in NEW top-to-bottom order. The diff vs. the old emit: only top-level siblings are reordered (can't move a child above a non-sibling parent). Document this in the function comment.

- [ ] **Step 6: Run TypeScript check + Vue tests**

Run:
```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run 2>&1 | tail -n 20
```

Expected: type-check clean; existing LayersPanel static-contract tests still pass (they assert source-grep, not behavior).

- [ ] **Step 7: Commit**

```bash
git add src/apps/desktop/src/components/design/LayersPanel.vue
git commit -m "feat(design): LayersPanel renders tree with depth + expand/collapse"
```

---

### Task 17: Static-contract tests for tree rendering

**Files:**
- Modify: `src/apps/desktop/src/__tests__/LayersPanel.spec.ts`

- [ ] **Step 1: Add tree-rendering assertions**

```ts
it('renders a tree using parent_id adjacency', () => {
  // The component should read parent_id to build the indentation hierarchy.
  expect(source).toContain('parent_id')
  expect(source).toContain('depth')  // computed property used for indentation
})

it('renders depth-based indentation', () => {
  // paddingLeft = base + depth * step
  expect(source).toMatch(/paddingLeft.*depth.*16|depth.*\*.*16/)
})

it('has expand/collapse chevron for parents', () => {
  expect(source).toContain('expandedParents')  // or 'isExpanded' — match what's actually in the file
  expect(source).toMatch(/chevron|toggle|expand/i)
})

it('renders design-layer-toggle-{id} testid for expand/collapse button', () => {
  expect(source).toContain('design-layer-toggle-')
})
```

(Adjust to match the actual code in Task 16 — these are starting points; verify the source uses these exact identifiers.)

- [ ] **Step 2: Run frontend tests**

Run:
```bash
cd src/apps/desktop
timeout 180 bunx vitest run __tests__/LayersPanel.spec.ts 2>&1 | tail -n 30
```

Expected: all tests in this file pass.

- [ ] **Step 3: Full frontend check**

Run:
```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
timeout 180 bunx vitest run 2>&1 | tail -n 10
```

Expected: build clean, all vitests pass (count should go UP from baseline).

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/__tests__/LayersPanel.spec.ts
git commit -m "test(design): add tree-rendering contract tests for LayersPanel"
```

---

## Chunk 5 — End-to-end verification

### Task 18: Full project verification

**Files:**
- No code changes. This task exists to catch regressions introduced by the previous tasks.

- [ ] **Step 1: Backend build**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/design-layers-nesting && timeout 240 zig build test --summary all 2>&1 | tail -n 5`

Expected: `1813+ pass, 3 skip, 4 fail` (the 4 search_test pre-existing failures remain; everything else passes including all new tests added in Tasks 1-13).

- [ ] **Step 2: Backend executable build (catches lazy-analysis bugs)**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/design-layers-nesting
rm -rf zig-out/bin
timeout 360 zig build 2>&1 | tail -n 10
```

Expected: clean build (no `unable to find dynamic system library`, no `undefined symbol`, no `error:` lines).

- [ ] **Step 3: Frontend type-check + build**

Run:
```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 10
```

Expected: clean type-check + bundle.

- [ ] **Step 4: Frontend tests**

Run:
```bash
cd src/apps/desktop
timeout 180 bunx vitest run 2>&1 | tail -n 10
```

Expected: all tests pass (count higher than baseline).

- [ ] **Step 5: Summarize + commit a single squashed merge if everything passes**

If all four checks pass, run:
```bash
git log --oneline -15
```

Verify the commit chain makes sense. If you want a single squash commit (cleaner for PR), do:
```bash
git log main..HEAD --oneline  # find the commits
git rebase -i main
# mark all but the first as "squash"
```

Then report to the user:
- baseline → now: pass counts (e.g. `1806/1813 → 1820/1827`)
- commit list
- worktree path

---

## Pitfalls

1. **The 4 pre-existing search_test failures** are NOT your bug. Don't try to fix them. Don't claim victory by including them. The "no regressions" check is `pass_count >= baseline_pass_count && failing_tests == {the same 4}`.

2. **`db.exec` only binds TEXT.** Integer columns need `std.fmt.allocPrint("{d}", ...)` before binding. The existing `addElement` already does this for `x`, `y`, etc. For `parent_id`, an empty slice binds as NULL — that's actually what we want for the "null parent" case, but watch for the `NOT NULL` constraint on the column. If the column is nullable (check the migration), you're fine.

3. **Heap-allocated strings via `xmlEscape` + `defer allocator.free`.** When emitting `parent_id="..."` in `elementToXml`, the new `xmlEscape` call creates a heap slice that MUST be freed at end of scope (mirror the existing pattern around line 262-264).

4. **Zig 0.16 error sets.** `addElement` / `updateElement` declared `anyerror!` for some functions. Adding a new error variant to a NAMED error set triggers compile errors at every `catch` site that doesn't handle it. If the function returns `anyerror!`, no problem. If named, update all catches.

5. **Lazy analysis hides `addExecutable`-only errors.** Always run `rm -rf zig-out/bin && zig build` (Step 18.2) to catch things `zig build test` misses. This is per the project's mandatory verification rule.

6. **Module-level state in Vue.** The `expandedParents` reactive Map lives at module scope. It survives re-renders but NOT component unmounts. That's intentional — when the user navigates away from DesignView and back, the expand state resets. If we wanted persistence, we'd lift to localStorage. Out of scope for this PR.

7. **Tree reorder semantics.** When the user clicks the up arrow on a child element, what should happen? Two options: (a) move within the parent's children list (sensible), (b) move out of the parent to the parent's previous sibling. Option (a) is what the current code does for top-level siblings; mirror it. If the child is already the first child of its parent, the up button is disabled. Don't try to bubble out of a parent — that's a separate UX (drag-to-reparent, deferred).

8. **The misleading prompt text change.** Task 14 edits a publicly-visible string (the system prompt). The new text is more accurate but also longer. If the LLM is paying attention, it should now nest correctly. Watch the first 2-3 production conversations after this lands to see if prompts get better; no automated test can verify this.

9. **Don't touch the canvas.** Task 16 explicitly does NOT change `DesignElement.vue` or `DesignView.vue`. Children still render at absolute page coords. The tree is a *layers-panel* feature only.

10. **`page_id` reset on re-parent.** The current `updateElement` SET builder doesn't change `page_id`. Re-parenting keeps the child on the same page as the parent (the validation in Task 5 enforces this with `validateParent`'s `page_id` check).

---

## Verification

After completing all 18 tasks:

1. `timeout 240 zig build test --summary all` shows ≥ 1813 passes (was 1806 baseline), 4 search_test failures unchanged.
2. `rm -rf zig-out/bin && timeout 360 zig build` succeeds.
3. `cd src/apps/desktop && timeout 180 bun run build` succeeds.
4. `cd src/apps/desktop && timeout 180 bunx vitest run` passes all tests.
5. Manual smoke: open the design view on the user's mockup page (`/design/...`). Create a frame element, then a rectangle with `parent_id=<frame_id>`. Confirm: (a) it renders inside the frame, (b) the Layers panel shows the rectangle indented under the frame with a chevron, (c) clicking the chevron collapses the children, (d) `update_element(rectangle_id, parent_id='')` detaches it and the layers panel unflattens.
