# Design — Leave group menu item

**Branch:** `worktree/design-ungroup`
**Date:** 2026-08-06
**Owner:** session `task_1785595978987`
**PR:** #166 → https://github.com/ginwa123/ginwaaitoolbox/pull/166

---

## Symptom

User reported: *"i try to leave the element, but cannot, i want leave chat-area, to non group"*.

Their workflow: right-click on a child row (`chat-area`) inside a parent
group (`Group 5`) in the design LayersPanel → click **Ungroup** → got an
HTTP 400: *"group has no children — nothing to ungroup"*.

The error was technically correct: their target was a `frame` with no
children of its own in the DB. The UX problem was that **Ungroup** was
the only right-click affordance that touched nesting, and "Ungroup"
reads as "leave the group" to anyone who hasn't memorised Figma's
distinction. The user wanted to **pull `chat-area` OUT of `Group 5`**,
which is a different action.

## Root cause

Two separate concerns were conflated under one menu item:

| Action | What it does | Mental model |
|---|---|---|
| Leave group | Pull ONE element OUT of its parent group → top-level | "I want this leaf to escape the group" |
| Ungroup | DISSOLVE the selected group → its children move up | "I'm done with this group, kill it" |

The codebase already had Ungroup wired (PR #150, commit `0cc752c4`,
1019 lines added) but no menu item for the inverse: Leave group.

The drag-out affordance from PR #151 implements Leave group semantically
(when you drop a row onto a top-level drop-zone, `new_parent_id: null`
flows through `POST .../reparent-batch`). But:

1. Drag-out is a less discoverable gesture than a menu item.
2. The user didn't know about it.
3. No keyboard shortcut, no visual cue — it's pure drag-target discovery.

## What landed

Frontend-only. No backend, no DB, no migrations, no API endpoint
added. Surgical additions to four source files + two test files +
two doc files.

### Source files (4 edits)

- **`src/apps/desktop/src/components/design/DesignContextMenu.vue`**
  - New `<button>` menu item "Leave group" between "Group selection"
    and "Ungroup", with `data-testid="design-context-menu-leave-group"`.
  - New `canLeaveGroup` computed — enabled when
    `targetIds.length === 1` AND `props.elements.find(e => e.id === targetId).parent_id` is non-empty (accepts the wire's
    `''` (empty-string from `COALESCE(parent_id, '')`) or missing/`null`
    as "top-level" — disabled).
  - New `leaveGroup: [targetId: string]` emit added to `defineEmits`.
  - Prop type for `elements` widened from omitted `parent_id` to
    `parent_id?: string | null` to match the `DesignElement` API
    surface.
  - `MENU_ROWS` updated `10` → `11` for edge-clamping math.

- **`src/apps/desktop/src/components/design/LayersPanel.vue`**
  - New `leaveGroup: [elementId: string]` added to `defineEmits`.
  - New `@leave-group="(id) => emit('leaveGroup', id)"` on the
    DesignContextMenu mount. LayersPanel does NOT change the wire —
    it just bubbles.

- **`src/apps/desktop/src/components/design/DesignView.vue`**
  - New handler `handleDesignLeaveGroupFromContextMenu(elementId)`
    routing to `designHandlers.leaveGroup(elementId)`.
  - Wired at BOTH the canvas's `DesignContextMenu` mount AND the
    `LayersPanel` mount.

- **`src/apps/desktop/src/composables/useDesignHandlers.ts`**
  - New `leaveGroup(elementId: string)` composable function.
    Mirrors `ungroupSelection`'s shape: args-driven ids, silent
    no-op on missing args, try/catch around the store call, success
    toast via `notificationStore.notifyError`, error toast on
    failure, clears `selectedIds.value` on success.
  - Internally calls
    `workspacesStore.reparentDesignElementsBatch(workspaceId, itemId, pageId, { element_ids: [id], new_parent_id: null })` —
    the EXACT same endpoint the drag-out affordance calls. No new
    backend touch.
  - Exported in the composable's return object alongside
    `ungroupSelection`.

### Tests (8 new behavioural, 1 updated)

Per user rule (2026-07-29): behavioural only — no static-contract.

- **`DesignContextMenu.spec.ts`** — 7 new tests in a new describe
  block "Leave group":
  1. Enabled when single selected element has `parent_id`.
  2. Enabled when single selected element is a nested group/frame
     (parent_id set) — and Ungroup is ALSO enabled (orthogonal).
  3. Disabled when single selected element is top-level
     (`parent_id === ''`).
  4. Disabled when more than one element is selected.
  5. Enabled when single selection is a group/frame that's
     nested inside another group (Leave group pulls IT out).
  6. Clicking Leave group emits `leaveGroup` with the right id.
  7. Clicking Leave group when disabled does NOT emit
     `leaveGroup` (defensive).
  - Updated existing test "renders all 8 menu items" → "renders all
    9 menu items" — added `design-context-menu-leave-group` to the
    expected testid list.

- **`LayersPanel.contextMenu.spec.ts`** — 1 new test:
  - `forwards the menu leaveGroup click as a top-level @leaveGroup
    emit with the single id` — mounts a LayersPanel with a child
    row whose `parent_id` is set, opens the menu, clicks Leave
    group, asserts the panel emitted `leaveGroup` with `['elem_b']`.

### Docs (2 changes)

- **`AGENTS.md`** — append-only changelog entry under
  `## 📜 Recent changes (changelog)`.
- **`docs/SPEC.md`** — PR index entry `#152 feat(design): leave-group menu item (Figma "Pull out of group")` inserted
  between #151 and #153.

## Verification

| Check | Result |
|---|---|
| `bun run build` (vue-tsc type-check) | clean |
| `bunx vitest run src/__tests__/DesignContextMenu.spec.ts` | 18/18 pass (was 11/11, +7 Leave-group) |
| `bunx vitest run src/__tests__/LayersPanel.contextMenu.spec.ts` | 9/9 pass (was 8/8, +1 forwarding) |
| `bunx vitest run src/composables/__tests__/useDesignHandlers.spec.ts` | 9/9 pass (no regression) |
| `bunx vitest run src/__tests__/useDesignHandlers.reparent.spec.ts` | 4/4 pass (no regression) |
| Full `bunx vitest run` | 1901/1909 pass — **same 8 pre-existing failures as `main`** (verified by `git stash` + re-run) |
| Zig `build test --summary all` | 2160/2166 pass (same on `main` — no regressions) |

The 8 pre-existing failures (verified pre-existing on `main`):
- `DesignView.undoHidden.spec.ts` — 5 tests locking in
  "undo/redo feature is HIDDEN" invariant. Unrelated.
- `DesignElement.spec.ts` — 1 static-contract test that uses
  `expect(source).toMatch(...)`. Project has a no-static-contract
  rule (2026-07-29) but this file predates it. Unrelated.
- `DesignView.nudge.spec.ts` — 1 test, the well-documented
  "arrow nudge clamps element to canvas bounds" flake that's
  known on `main`.
- `AppLayout.translateResize.spec.ts` — 1 "POST /translate"
  flake also known on `main`.

## Out of scope

### Data desync — separate investigation

The user's screenshot shows `chat-area` (a `frame`) at indent level 1
inside `Group 5`, with `input-area` and `state-transition` indented
under `chat-area`. But Ungroup's backend error
(`group has no children`) says `chat-area` has no children in the
DB. Two possibilities:

1. **Bug A (more likely):** `chat-area`'s `parent_id` is the GROUP'S
   id, but `input-area` and `state-transition` have `parent_id === ''`
   (top-level) — the LayersPanel tree builder puts them under
   `chat-area` only because their position in the UI list sorts them
   that way, not because of the FK. The visual nesting is misleading.
2. **Bug B:** `chat-area` is itself top-level (no parent), and the
   user's perception of it being inside `Group 5` is wrong.

In either case, the user's "leave chat-area from Group 5" request is
**not satisfiable as stated** — they need to first understand the
actual layout. After Leave group lands, the right follow-up is a
diagnostic feature (e.g. "Inspect" panel showing each row's real
`parent_id`) so users can see when the visual tree disagrees with
the DB.

Tracked separately.

### Keyboard shortcut

Figma doesn't have a default keyboard shortcut for "Pull out of
group". `Cmd+Shift+G` is taken by Ungroup (since PR #150, 2026-07-29).
No shortcut is added. Drag-out (existing affordance, PR #151) still
works for keyboard-shy users.

### LLM tool

A matching `leave_group` tool for the LLM could be added — it would
be a thin wrapper around `move_design_element` with `apply_to_children=false`
or a direct `reparentElements` call with `new_parent_id=null`. Not
added — the LLM can already compose the operation via
`reparent_design_elements({ new_parent_id: null })` once it exists
(it's the same backend endpoint the menu uses).

## Roll-back plan

Pure additive change. Revert the four source files + two test
files + two doc files. No state to migrate (no DB schema change, no
config change). The only user-visible change on rollback is that the
"Leave group" menu item disappears.

## File touch map (final)

| File | Change |
|---|---|
| `src/apps/desktop/src/components/design/DesignContextMenu.vue` | +Leave group item, +canLeaveGroup, +leaveGroup emit, parent_id prop type, MENU_ROWS 10→11 |
| `src/apps/desktop/src/components/design/LayersPanel.vue` | +leaveGroup emit, @leave-group forward |
| `src/apps/desktop/src/components/design/DesignView.vue` | +handleDesignLeaveGroupFromContextMenu, 2 mounts get @leave-group |
| `src/apps/desktop/src/composables/useDesignHandlers.ts` | +leaveGroup function, +leaveGroup export |
| `src/apps/desktop/src/__tests__/DesignContextMenu.spec.ts` | +7 Leave-group tests, +1 menu-list update |
| `src/apps/desktop/src/__tests__/LayersPanel.contextMenu.spec.ts` | +1 forwarding test |
| `AGENTS.md` | +changelog entry |
| `docs/SPEC.md` | +#152 PR index entry |
| `docs/superpowers/plans/2026-08-06-design-leave-group-menu.md` | +this plan |

Total: 8 modified files + 1 new plan doc. No new test files (additions
go into existing fixtures). No backend touch. No DB migration.
