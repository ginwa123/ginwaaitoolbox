# Sidebar dead code surfaced by Task 8 audit (2026-08-06)

## Context

Task 8 of the sidebar single-active-state plan was an audit-and-cleanup
task. Goal: identify sidebar components that still read the
store-flags (`activeWorkspaceItemId`, `activeTaskId`,
`activeDesignPageId`, `navigationStore.sessionId`) to drive visuals,
and remove those reads.

**Result: no code changes were made.** All sidebar store-flag reads
either (a) coordinate side-effects (KEEP) or (b) drive still-relevant
visuals (KEEP). But the audit surfaced SEVEN pieces of dead code that
the plan explicitly excluded from Task 8's scope ("NOTE in commit
message but don't fix here"). This memory records them for the next
cleanup task.

## The dead code (out of scope for Task 8)

### 1. `Sidebar.vue:158` — `activeChatName` ref is unused

```ts
const activeChatName = computed(() => navigationStore.activeChatName)
```

Declared but never read in the template. The Sidebar's template uses
`<ChatsList>` (separate component), which maintains its own internal
`activeChatName`. Removal: 1 line.

### 2. `Sidebar.vue:271-298` — `loadChats()` is dead

Sidebar.vue defines its own `loadChats` function (also `loadMoreChats`
at line 300-319) that mirrors `navItems` state — but the function is
never called from outside Sidebar.vue and is not exposed via
`defineExpose`. The actual `<ChatsList>` component has its own
`loadChats`. Sidebar's `navItems` is itself dead.

The `savedSessionId = navigationStore.sessionId` + `active:
savedSessionId === session.session_id` read inside this dead function
(line 276, 281) IS the kind of stale-flag read the audit was looking
for — but it's in dead code, so removing it is just removing dead
code, not a "sidebar cleanup" change.

Removal: ~50 lines (the entire `loadChats` + `loadMoreChats` +
`navItems` ref + `updateChatId` helper).

### 3. `Sidebar.vue:1442` — `:active-workspace-item-id` drives a redundant visual

```vue
<WorkspaceList
  :active-workspace-item-id="workspacesStore.activeWorkspaceItemId"
  ...
/>
```

This reads `workspacesStore.activeWorkspaceItemId` and threads it
through WorkspaceList → WorkspaceItem as the `isActive` prop. After
Task 3, WorkspaceItem's URL-driven accent bar provides the visual
signal; the prop only drives a small aqua 1.5×1.5 dot at
`WorkspaceItem.vue:568-573`. That dot is redundant given the bg +
accent bar.

Removal: ~4 lines (Sidebar binding + WorkspaceList prop + WorkspaceItem
template dot). Tests would need updates (they still pass `isActive`).

### 4. `DesignPageRow.vue:30, 44, 54` — `isActivePage` prop is dead

```ts
isActivePage: boolean   // line 44 — defineProps
```

Declared in JSDoc and `defineProps` but NEVER used in the template
(only references are line 30 in JSDoc and line 54 in a comment
explaining why it's still passed). The visual uses
`isCurrentMainView` (URL-driven, lines 92-97).

The binding at `WorkspaceItem.vue:756`
(`:is-active-page="workspacesStore.activeDesignPageId === page.id"`)
IS a stale-flag read — but it goes to a dead prop. Cleanest removal
would be a single follow-up that removes both the binding AND the
prop declaration (and 4 test files that pass `isActivePage`).

Removal: ~15 lines across 4-5 files (binding + prop + JSDoc +
comment + test helper).

### 5. `Sidebar.vue:75` + `updateChatId()` — local navItems is dead

Sidebar's local `navItems` ref + `updateChatId(oldId, newId)` function
(line 82) are only used internally by Sidebar's own dead `loadChats`.
`AppLayout.vue:344` calls `sidebarRef.value?.updateChatId(oldId, newId)`
but Sidebar's `updateChatId` only modifies Sidebar's dead `navItems`
(the unrelated `ChatsList.updateChatId` does the actual work in
ChatsList.vue:359).

Removal: ~15 lines (the ref + updateChatId function + updateChatId in
defineExpose).

### 6. `WorkspaceItemTaskCard.vue:276-277` — kanban card visual uses store flag

```ts
:style="{
  color: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text)',
  backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--semantic-active-bg)' : 'var(--semantic-card-bg)',
  boxShadow: cardBoxShadow,
}"
```

This is the kanban card's active styling (in the main content area,
NOT the sidebar). The plan's spec covers only the sidebar — but for
consistency, this should also be URL-driven (?view=task&task=X match).

Removal: ~3 lines. Would need a `useCurrentMainView` integration or a
local computed.

### 7. `ChatsList.vue` template reads `item.active` directly

The TEMPLATE at `ChatsList.vue:443-448` uses
`item.active` (the stored local flag) to render the active style,
NOT `currentMainView`. So:

- `item.active` is set correctly by `loadChats()` (URL-driven).
- `item.active` is updated by `setActive()` on user clicks.
- `item.active` is cleared by `resetActiveChat()` on navigation away.

This means `resetActiveChat()` (Sidebar.vue:392, 883 → ChatsList.vue:355)
is still needed for visual sync. To remove `resetActiveChat()`, the
template would need to read `currentMainView` directly:

```vue
:style="currentMainView.kind === 'chat' && currentMainView.sessionId === item.id
  ? 'background: var(--semantic-active-bg); ...'
  : '...'"
```

That's a bigger refactor — out of scope for Task 8 (template-rendering
change, not just "remove store-flag read"). Future cleanup.

Removal: ~20 lines (template binding refactor + remove `resetActiveChat`
+ remove callers).

## Why no changes were made for Task 8

The plan's "Step 3 — Apply changes" says "surgical removals per step
1-2. Each change should be minimal — typically removing one or two
lines per call site." The 7 findings above are NOT 1-2 line removals
each — they're multi-file refactors or dead-code cleanups that the
plan explicitly excluded:

> "If you find any other dead code (e.g., unused imports, unused
> parameters) in the touched files, NOTE it in the commit message but
> don't fix here — out of scope for Task 8."

Plus, the plan's spec said:

> "Out of scope (deferred): The store's `activeTaskId` /
> `activeWorkspaceItemId` / `activeDesignPageId` flags are kept — they
> still drive AppLayout routing decisions. They just don't drive
> sidebar highlighting anymore. (Removing them would be a much larger
> refactor across AppLayout + SSE handlers + workspace store
> actions.)"

So the task is "do a focused audit + small surgical removals". The
dead code discovered here is for a future cleanup.

## What was verified

- `bun run build` clean (vue-tsc + vite, 2.72s)
- `bunx vitest run`: 2100 pass / 19 fail (same as documented
  `main` baseline in AGENTS.md — `DesignView.undoHidden ×5`,
  `AppLayout.urlPersist ×7`, `AppLayout.memoriesGate ×4`,
  `DesignElement static ×1`, `AppLayout.translateResize ×1`,
  `DesignView.nudge ×1`)

## Related files

- Plan: `docs/superpowers/plans/2026-08-06-sidebar-single-active-state.md`
  § Task 8
- Spec: `docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md`
- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/sidebar-single-active`
- Branch: `worktree/sidebar-single-active`
- Committed Tasks 1-7: `f35ebfd0` (composable), `506376f9`
  (ChatsList), `698e7eff` (task row), `2920222a` (item row),
  `fbfbdd0e` (page row), `a2914760` (no active-bg on expanded),
  `b98d191b` (E2E), `471db238` (fixture fix)

## Future cleanup task names (suggested)

A "Sidebar dead-code cleanup" task could:
1. Remove Sidebar's dead `navItems` ref + `loadChats` + `loadMoreChats`
   + `updateChatId` + `activeChatName` (~50 lines, 1 file)
2. Make WorkspaceItem's `isActive` prop optional and remove the binding
   chain through WorkspaceList (~5 lines, 3 files + tests)
3. Remove DesignPageRow's dead `isActivePage` prop (~5 lines, 3 files
   + tests)
4. Refactor ChatsList template to use `currentMainView` directly,
   dropping `resetActiveChat` (~20 lines, 3 files + tests)
5. Make kanban card's active state URL-driven (~5 lines, 1 file +
   tests)

Total: ~80 lines across ~12 files. Probably 1-2 commits with full TDD
coverage.

## Pitfall

When investigating "is this stale-flag read driving a visual or a
coordination?", always check whether the visual reads the flag
DIRECTLY or reads a CHAIN (prop, then template). The plan's audit
focused on direct reads in templates. Indirect reads (flag → prop →
ignored) are technically stale but are also dead code — different
cleanup than removing the staleness.
