# nalar — Vue 3 async onMounted + click race (the "empty chat on toggle" bug)

A common pattern in the nalar codebase is to kick off an async
"resolve existing row" lookup in `onMounted` (so the UI can show
the persisted state after a page reload), then have a click
handler that *creates* a new row if the resolve hasn't finished.
**This is a race condition that silently corrupts the DB and
produces confusing UX.**

## Symptom

1. User opens a page where the component does an async lookup
   in `onMounted` (e.g. `resolveExistingChatTask` in
   `DesignView.vue`).
2. User clicks a toggle button BEFORE the lookup finishes (race
   window: ~50-200ms on a local network; the lookup involves a
   network round-trip + a DB query).
3. The click handler sees `existingRowId.value === null` (because
   the lookup hasn't completed) → falls into the "create new"
   branch.
4. A SECOND row is created with the same discriminator (e.g.
   `name='Chat'` for a `workspace_item_tasks` row).
5. The new row has no associated data (no `llm_history` rows, no
   design pages, no routine, etc.).
6. The new row is what gets mounted into the detail view
   (because `existingRowId.value` was just set by the create).
7. User sees: "the sidebar shows the original (populated) row,
   but the detail view is empty."

## Why this bites

Three reasons it goes unnoticed for a long time:

1. **No UNIQUE constraint protects the discriminator column.** In
   the case I hit, `workspace_item_tasks(workspace_item_id, name)`
   had no UNIQUE index, so the DB silently accepted the duplicate.
   The `tasks` table is the only place where this matters; for
   tasks that have a `position` column (kanban) it's a bit less
   harmful because the position differs, but for `name` columns
   it's a direct duplicate.

2. **The first click seems to work.** The user clicks "Chat", a
   panel appears, they type "hello", and the response comes back.
   But they're chatting with the EMPTY new task, not the
   original. On reload, the original task is still in the
   sidebar but the user's message history is gone.

3. **The bug looks like a network/DB issue from the user's POV.**
   They report "the chat is empty when I open it" — not "two Chat
   tasks are being created". The duplicate-row symptom is hidden
   in the sidebar (both rows look identical to the user).

## How to detect

If you see a component that:

- Has a `const xxxLoading = ref(false)` and `const xxxReady = ref(false)` flag
- Calls `void resolveExistingXxx()` in `onMounted` (fire-and-forget)
- Has a click handler that does `if (!xxxId.value) { create... }`

That's the pattern. Run the component in dev, click the toggle
within ~100ms of mount, and check the DB for duplicates:

```bash
sqlite3 ~/.config/nalar/agent.db \
  "SELECT workspace_item_id, name, COUNT(*) FROM workspace_item_tasks " \
  "WHERE name = 'Chat' GROUP BY workspace_item_id, name HAVING COUNT(*) > 1"
```

If you see any rows, the bug is live.

## The fix pattern

The fix is to **make the click handler wait for the eager resolve
to finish** before deciding whether to create. The pattern is:

```ts
async function handleClick() {
  // ... OFF path ...

  // ON path: wait for the eager resolve if it's still in flight.
  if (!xxxReady.value) {
    xxxLoading.value = true
    try {
      await resolveExistingXxx()  // idempotent — no-op if already done
    } finally {
      xxxLoading.value = false
    }
  }

  // Now we know for sure: chatReady is true, chatTaskId reflects
  // the current DB state. Safe to create if still null.
  if (!xxxId.value) {
    const created = await api.createXxx(...)
    xxxId.value = created.id
  }

  // Flip the UI state atomically (AFTER the createTask), not
  // before. Avoids the "Chat On" state flashing with no panel
  // mounted.
  showXxx.value = true
}
```

Two key changes vs the broken pattern:

1. **Await the resolve** when `xxxReady === false`. This is the
   fix. Without it, the click races the resolve and the create
   branch always wins.

2. **Move the `showXxx = true` flip to the END** of the ON path
   (not the start). The original code did it first to make the
   panel appear immediately, but then the template's
   `v-if="showXxx && xxxId"` would hide the panel when xxxId
   was null — that worked, but it briefly showed the toggle in
   the "On" state with no panel mounted, which was confusing.
   Atomic flip is cleaner.

## Source-level regression test (the project's convention)

nalar's frontend doesn't have a behavioral test infra for
components like DesignView (the team uses static-contract tests
instead). The contract for the fix is:

```ts
test('DesignView toggle awaits the eager resolve before creating', () => {
  const fnMatch = source.match(/async function handleToggleChat\(\) \{([\s\S]*?)\n\}/)
  if (!fnMatch || !fnMatch[1]) throw new Error('handleToggleChat missing')
  const body: string = fnMatch[1]

  // 1. The await must be in the ON path.
  if (!body.includes('await resolveExistingChatTask')) throw new Error(...)

  // 2. showChat.value = true must come AFTER the await.
  const flipPos = body.indexOf('showChat.value = true')
  const awaitPos = body.indexOf('await resolveExistingChatTask')
  if (awaitPos < 0 || awaitPos > flipPos) throw new Error(...)
})
```

This locks in the structural fix so a future refactor can't
re-introduce the race by moving the `showChat = true` line back
to the top of the function.

## When this bites

Any Vue 3 component that has:

- `onMounted` with a fire-and-forget async lookup (`void resolveXxx()`)
- A click handler that creates a new row when the lookup hasn't
  found one yet
- No UNIQUE constraint on the discriminator column (most "tag"
  columns like `name='Chat'`, `name='Routine'`, etc. fall in this
  bucket because they're meant to be human-editable)
- A UI that shows the resolved-or-created row in a panel/sidebar

Common offenders to grep for:
```bash
rg -l "void resolveExisting|void loadExisting" src/apps/desktop/src/components/
rg -l "if \(!xxxId.value\)\s*\{?\s*const created" src/apps/desktop/src/components/
```

If you find a component that matches both, it has the bug (or
should add the await + atomic-flip fix as defense in depth even
if it happens to not manifest today).

## Concrete precedent in this repo

`src/apps/desktop/src/components/DesignView.vue` (commit
`96ce8e17` on branch `feature/design-mode`, 2026-07-06):

- Before: toggle click → optimistic `showChat = true` → create Chat
  task if `chatTaskId === null` → race against the eager
  `resolveExistingChatTask` in `onMounted` → silent duplicate
  Chat task created on every fast click → user sees empty chat.
- After: toggle click → await `resolveExistingChatTask` if not
  done → create only if `chatTaskId === null` after the await →
  atomic `showChat = true` at the end.

Reproduction (curl against `./zig-out/bin/nalar --port 8080`):

```bash
# Set up workspace + design item + one Chat task
WSID=ws_xxx; ITEMID=item_xxx
# (Create via /api/workspaces, /api/workspaces/$WSID/items, /api/workspaces/$WSID/items/$ITEMID/tasks)

# Simulate the race: 2 quick POSTs to /api/workspaces/$WSID/items/$ITEMID/tasks
# with name='Chat' (no UNIQUE constraint on (workspace_item_id, name))
# Result: 2 Chat rows in workspace_item_tasks for the same design item.

# Verify in DB:
sqlite3 ~/.config/nalar/agent.db \
  "SELECT id, name, created_at FROM workspace_item_tasks WHERE workspace_item_id = '$ITEMID' ORDER BY created_at"
```

After the fix, the second click in the same scenario reuses the
first task (no duplicate row).
