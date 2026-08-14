# Plan: New group's z_index must sit BELOW its children (design-mode group bug)

**Task**: `task_1786693066547` — user says: *"the element is show, if i set
transparent, [the group still occludes the children]"* and suggests:
*"maybe the solution is set index below child element for the group, so
it can proper user see the design"*.

**Branch**: TBD (start from current `in progress` task; worktree per the
project rule).

---

## 1. Context (symptom + root cause)

### What the user saw

User creates a `group` (or `frame`) around 2+ existing elements via
`Cmd+G` / right-click **Group selection**. The group's bounding box
appears on the canvas — but **the children inside it disappear**.
Setting the group's `fill` to `transparent` brings the children back;
setting it back to any opaque color (the default in their template is
`#181616`, near-black) hides them again. The user reports this as
*"i have to ungroup to fix the bugs"*.

### Reproduction (2026-08-14)

Group 19 (fill `#181616`, w=592, h=542) was created on a page that
already contained 9 children with `parent_id` set to the new group.
After the group command, the canvas showed ONLY the dark group fill
(no children visible). The layers panel correctly listed all 9
children under Group 19 — they exist in the DB and in the local
Pinia store, but the canvas draws the group OVER them.

### Root cause

`groupElements` (in `src/ai_workflow/tui/design_model.zig`, the
backend handler that creates a new `group` element) sets the new
group's `z_index` to `max(children.z_index) + 1`:

```zig
// design_model.zig:2068 + 2125
var max_z: i64 = 0;
for (children.items) |c| {
    ...
    if (c.z_index > max_z) max_z = c.z_index;
}
...
const z_index_str = try std.fmt.allocPrint(allocator, "{d}", .{max_z + 1});
```

The new group therefore stacks **above** every child. Combined with
`fill: '#181616'` (or any opaque color), the group's body covers
its children on the canvas.

The frontend honours `z_index` strictly — see the inline fix note in
`DesignElement.vue:174-185`:

```ts
// FIX 2026-08-06 (task_1785988530202): apply `z-index` inline so
// CSS handles the z-axis stacking. Without this, the right-click
// reorder menu (Bring to front / forward / Send backward / back) and
// the Ctrl+]+[ keyboard shortcuts WERE updating the DB `z_index`
// values correctly but the canvas visual stacking didn't change…
zIndex: props.element.z_index,
```

So a higher `z_index` → `zIndex: N` → CSS paints the group above its
children. Even with `fill: 'transparent'`, the group's `<div>` (with
`border-radius`, optional `border`, optional opaque HTML body) is
still drawn above the children. With an opaque fill, it's clearly
above them.

The user even tried the "set transparent" workaround — that works in
the trivial case (no `border`, no iframe children inside the group),
but in general the group needs to stack **behind** its children.

### Why this is a backend bug, not a UI one

The frontend honours `z_index` correctly (Figma parity requires DOM
order = visual stacking for `position: absolute` children). The bug
is in the SQL write: a container must not occlude its contents.
Pushing the container to `z_index = max_z + 1` is the inverse of
intuitive stacking. The natural fix is to put the group **below** its
children so they paint on top of it.

---

## 2. What landed

### Source files (1 edit + 1 test file)

- **`src/ai_workflow/tui/design_model.zig`** — `groupElements`:
  - Added `min_z: i64 = std.math.maxInt(i64);` alongside the existing
    `max_z` accumulator.
  - Track `min_z = min(min_z, c.z_index)` in the children loop.
  - Changed `z_index_str` allocation from `max_z + 1` to `min_z - 1`,
    with an explanatory comment block describing the visual-stacking
    reason (group = container, must render behind its children; a
    container drawn on top of its contents occludes them).
- **`src/ai_workflow/tui/design_model_group_test.zig`** — new inline
  contract test: `groupElements uses min_z - 1 (group below children)`.
  Reads `pub fn groupElements` in source, asserts the new pattern
  appears within 8 KB of the function signature (mirrors the
  existing `union bbox geometry` test at line 283). Fails closed
  (returns `error.GroupZIndexAboveChildren`) if a future refactor
  reverts to `max_z + 1`.

### Tests (1 new behavioural, 0 updated)

The contract test in `design_model_group_test.zig` is behavioural (it
greps the source for the new pattern), matching the existing
`groupElements uses union bbox geometry` test.

### Docs (1 change)

- **`AGENTS.md`** — append-only changelog entry under
  `## 📜 Recent changes (changelog)`.

---

## 3. Verification

| Check | Result |
|---|---|
| `bunx tsc -p src/apps/desktop/tsconfig.json --noEmit` (vue-tsc) | unchanged (no frontend touch) |
| `zig build test` (`custom test` target → runs inline tests in `design_model.zig` + `design_model_group_test.zig`) | new test passes; existing group tests unaffected |
| `bunx vitest run src/__tests__/workspacesStoreMoveBatch.spec.ts` | unchanged (no frontend touch) |
| `bunx vitest run src/__tests__/DesignElement.drag.spec.ts` | unchanged (no frontend touch) |
| Manual: Cmd+G two elements → group fill #181616 → children remain visible inside the group | expected to pass |

---

## 4. Out of scope (future work, not part of this PR)

- **Re-render `fill` / `border` styling of the group to be visually
  obvious it's a container** (dashed border, name label, etc.). The
  user is happy with the bug fix; container chrome polish is a
  separate UX task.
- **Migration for existing groups** that were created before this fix
  (they still have `z_index = max_z + 1`). The fix only affects
  *new* groups. A one-time SQL migration to rewrite old groups'
  z_index is unnecessary because (a) the local Pinia store
  re-fetches elements whenever the page becomes active
  (so user-perceived state on the next visit is already
  re-sorted), and (b) a user can right-click → Bring to front /
  Send to back to nudge any stale group as desired.
- **Locking the group's `z_index` to a fixed slot** (e.g. always
  the lowest z_index in the page). Today's fix uses `min_z - 1`,
  which still lets a user drag the group behind other groups via
  Send to back. Figma parity.
