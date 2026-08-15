# 2026-08-14: Kanban task detail dialog — allow cwd change in edit mode

## What

Make the per-task cwd picker functional in **both** create **and** edit modes of the
`KanbanTaskDetailDialog`. Today the cwd picker is implemented inside the create-mode-only
`<div data-testid="kanban-task-detail-profile-and-unattended">` block (line 1122–1302 of
`src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue`), so editing an existing
task leaves the user with a read-only cwd strip (the comment block on lines 986–994
literally says "edit-mode cwd change is out of scope for this PR"). The migration is
already wired on the backend (`task_update.zig` lines 263–296 — `validated_cwd` block
re-validates the path on every PUT) and in the API helper
(`src/apps/desktop/src/api/index.ts:861` — `updateTaskSimple` accepts a `cwd` field).
Only the UI was missing the affordance.

## Why

User feedback: the kanban task detail dialog ("task detail") cannot change cwd. Today
the read-only strip on lines 995–1014 says "📂 /home/foo" and "Change at task level is
out of scope" — which forces the user to **delete + recreate** the task just to switch
its project root. That violates the principle "let users fix small things in place".
The 3-level cwd fallback chain (per-task cwd → kanban-level path → sandbox) makes the
per-task cwd a first-class editor field; the UI should reflect that.

## Files

| File | Change |
| --- | --- |
| `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | Lift the cwd picker out of the create-mode block so it renders in both modes. Initialize `cwdSession` from `props.task?.cwd ?? ''` when the dialog opens in edit mode. Add a new `update-cwd` emit (mirrors the `update-unattended` pattern). In edit mode, `selectCwd` calls `emit('update-cwd', path)`. Remove the read-only cwd strip from the metadata strip. |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | Add a `@update-cwd="handleUpdateCwd"` listener on the edit-mode `KanbanTaskDetailDialog` mount. Add a `handleUpdateCwd` async function that calls `api.updateTaskSimple(task.id, { cwd })` with the same best-effort / SSE-corrected pattern as `handleUnattendedToggle`. |
| `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts` | Add tests for the new edit-mode behavior: (a) picker button shows the current task cwd as the label, (b) picker shows "no project root" placeholder when `task.cwd` is empty, (c) `update-cwd` emits on folder pick in edit mode. |

## Plan

### Step 1 — `KanbanTaskDetailDialog.vue`: lift the cwd picker

Currently the picker lives inside the `<div v-if="isCreateMode"
data-testid="kanban-task-detail-profile-and-unattended">` block. Lift it out into its
own row that renders in **both** modes (preceded by a `border-top` separator), then
keep profile-picker + unattended-toggle inside the existing create-mode block. The
picker becomes a sibling of the metadata strip rather than its descendant, which
matches what the edit-mode UI needs: there's no profile picker in edit mode (the
profile is captured at task creation), so the layout naturally simplifies.

```html
<!-- Before (only in create mode) -->
<div v-if="isCreateMode" class="...">
  <CWD picker />
  <Profile picker />
  <Unattended toggle />
</div>
<div v-else class="...">
  <Unattended toggle />
</div>

<!-- After (cwd picker always visible) -->
<div class="mt-4 pt-4" style="border-top: 1px solid var(--color-border);">
  <CWD picker />   <!-- emits `cwd-changed` on selection; in edit mode
                          the dialog also emits `update-cwd` so the host
                          can persist -->
</div>
<div v-if="isCreateMode" class="mt-2 flex items-center gap-4" data-testid="kanban-task-detail-profile-and-unattended">
  <Profile picker />
  <Unattended toggle />
</div>
<div v-else class="mt-2 pt-2 flex items-center justify-between gap-3" data-testid="kanban-task-detail-unattended">
  <Unattended toggle />
</div>
```

### Step 2 — initialize `cwdSession` from `task.cwd` in edit mode

The existing watcher on lines 329–336 only re-populates `cwdSession` from `props.cwd`
in create mode. Extend it to also handle edit-mode initialisation:

```ts
watch(
  () => props.show,
  (show) => {
    if (!show) return
    if (isCreateMode.value) {
      cwdSession.value = props.cwd ?? ''   // parent kanban's path (existing)
    } else {
      cwdSession.value = props.task?.cwd ?? ''   // NEW: existing task's cwd
    }
  },
)
```

Also handle the case where the user opens the dialog on a task that has no cwd yet
(empty string) — the picker button label should read "Skip (no project root)" /
"no project root" via the same `cwdSession || 'Skip (no project root)'` binding that
already exists for create mode.

### Step 3 — add `update-cwd` emit (mirrors `update-unattended`)

Add to the `defineEmits<{...}>()` block:

```ts
'update-cwd': [payload: { cwd: string }]
```

In `selectCwd()`:

```ts
const selectCwd = (path: string) => {
  cwdSession.value = path
  isCwdPickerOpen.value = false
  if (!isCreateMode.value) {
    // Edit-mode cwd change: persist immediately via the host
    // (same immediate-save UX as the unattended toggle). The
    // create-mode cwd is forwarded via the `create` / `create-and-run`
    // emit's `cwdSession` field as today.
    emit('update-cwd', { cwd: path })
  }
}
```

### Step 4 — remove the read-only cwd strip from the metadata strip

Lines 995–1014 of the template (the `<span data-testid="kanban-task-detail-cwd-readonly">`
and `<span data-testid="kanban-task-detail-cwd-readonly-empty">`) become dead weight
once the picker shows the cwd. Remove them. The picker's button label already conveys
the cwd (or the empty-state placeholder), so the user has a single source of truth.

### Step 5 — `KanbanView.vue`: wire `@update-cwd`

Add a handler next to `handleUnattendedToggle` (line 719). Same pattern: best-effort
PUT, no rollback on failure (the dialog's local `cwdSession` is the source of truth
while the dialog is open, and the next SSE re-fetch paints the correct value):

```ts
const handleUpdateCwd = async (payload: { cwd: string }) => {
  const taskId = activeTaskDetailId.value
  if (!taskId) return
  try {
    await api.updateTaskSimple(taskId, { cwd: payload.cwd })
  } catch (err) {
    console.error('Failed to update task cwd:', err)
    // Best-effort: on failure the SSE re-fetch will paint the server-truth
    // value into the picker, and the dialog's local cwdSession stays put
    // (the user can re-pick if they want).
  }
}
```

Bind on the dialog mount (line 1146):

```html
<KanbanTaskDetailDialog
  v-model:show="showTaskDetail"
  :task="activeTaskDetail"
  :column="activeTaskDetailColumn"
  :cwd="item.path || ''"
  :workspace-id="workspaceId"
  @save="handleTaskDetailSave"
  @update-unattended="handleUnattendedToggle"
  @update-cwd="handleUpdateCwd"   <!-- NEW -->
/>
```

The create-mode mount (line 1163) needs no change — the `cwdSession` field on its
`create` and `create-and-run` emits already handles the create flow.

### Step 6 — Tests

Add to `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts`:

1. **"edit mode: cwd picker button reflects the current task cwd"** — mount with
   `task: { id: '...', name: 'X', description: '', task_type: 'standard', cwd: '/home/foo/bar' }`,
   assert the button label contains `/home/foo/bar`.
2. **"edit mode: cwd picker button shows the empty-state placeholder when task has no cwd"** —
   mount with `task: { ..., cwd: '' }`, assert the label is "no project root".
3. **"edit mode: opens the FilePickerDialog when the picker button is clicked"** —
   click the picker, assert the dropdown mounts.
4. **"edit mode: emits 'update-cwd' with the picked path on folder select"** —
   mount with a mocked `<FilePickerDialog>` that emits `select` with a path, assert
   `wrapper.emitted('update-cwd')` matches `[{ cwd: '/path' }]`.

## Behavioural contract

After this change:

- **Create mode**: cwd picker behavior is **unchanged** (cwd flows via the `create`
  / `create-and-run` emit's `cwdSession` field, host forwards to `api.createTask`).
- **Edit mode**: cwd picker is **new** — clicking opens the same `FilePickerDialog`,
  picking fires `update-cwd` with the new path. The host persists immediately via
  `api.updateTaskSimple(task.id, { cwd })` (no Save click required, matching the
  unattended toggle UX).
- **Read-only cwd strip in metadata**: **removed** (replaced by the picker button
  label).
- **Error message handling**: PUT failures are logged in `handleUpdateCwd`; the
  picker's local `cwdSession` keeps the user's pick, and the next SSE re-fetch
  re-paints from server truth (same pattern as `handleUnattendedToggle`).

## Pitfalls

1. **`task.cwd` is `undefined` (not just empty)** in legacy tasks that predate
   Migration 070. The picker initializer uses `props.task?.cwd ?? ''` to coerce
   both undefined and empty to the empty-state placeholder.
2. **The `cwdSession` re-population watcher** runs on `props.show` change; ensure
   the watcher fires both on dialog open (show: false → true) AND on task swap
   (same show, different task). The existing watch source `[props.show,
   props.task?.id, props.mode]` already handles the task-swap case for the other
   fields; the new edit-mode cwd initializer piggybacks on the `props.show` watcher
   which is sufficient for the open case. Task-swap is rare but does happen when
   the user clicks one task then another with the dialog already open — handled by
   the existing watcher on lines 415–478 (the `isCreateMode` check is the
   discriminator).
3. **The `cwdSession` watcher doesn't reset to `''` on Save** — the user's pick
   stays in the local ref. The picker button label after Save continues to reflect
   the picked cwd; the dialog's `props.task.cwd` updates after the host's
   optimistic update (via `workspacesStore.updateTaskDetails` patch).
   To keep the picker in sync, the picker's `cwdSession` should ALSO re-sync from
   `props.task?.cwd` whenever `props.task` changes (handle this in the watcher's
   `task?.id` branch). Actually the simpler fix: when the dialog re-opens for the
   same task, the show watcher fires from false→true again, so cwdSession re-syncs.
   For the rare "Save → picker label still shows the user's local pick" case,
   that's fine — the prop has the same value the user just picked.
4. **SSE re-fetch may overwrite `cwdSession`** — handleUnattendedToggle's pattern
   uses "best-effort + let SSE re-fetch correct on next paint". For consistency,
   we mirror the same pattern for `update-cwd`. The dialog's `task.cwd` prop
   updates from the store's optimistic update (which I should also extend to
   include cwd for full consistency with the unattended toggle's SSE story).

   Actually simpler: skip extending `workspacesStore.updateTaskDetails` (avoid
   scope creep). The optimistic update via `api.updateTaskSimple` + the next
   workspaces refetch is good enough for v1. If the user reports "toggle shows
   OLD value after cwd change", we add the store-level optimistic update as
   a follow-up. **This is the surgical fix** — match the existing handleUnattendedToggle pattern exactly.

## Verification

- [ ] `npm run test -- KanbanTaskDetailDialog` passes (existing + new tests).
- [ ] `npm run type-check` clean.
- [ ] Manual: open a task's detail dialog → click the cwd picker → pick a folder
      → confirm the task's cwd in the session list updates.
- [ ] Manual: open a new task with cwd `=` parent kanban path → confirm the picker
      still pre-populates with that path (no regression).
- [ ] Manual: cancel a folder pick → confirm the dialog's local cwdSession is
      unchanged (the FilePickerDialog's `close-on-select={false}` already handles
      cancel via backdrop dismiss; verify by reopening the dialog and confirming
      the picker label still shows the previous cwd).

## Out of scope

- Backend migration: none needed. `task_update.zig` already validates + persists
  `cwd` (Migration 070 already shipped).
- Extending `workspacesStore.updateTaskDetails` to accept `cwd` field for
  optimistic update of `task.cwd` on Save: deferred to a follow-up. The immediate
  PUT pattern matches `handleUnattendedToggle` and is sufficient for v1.
- Audit log entry for cwd changes: deferred to a follow-up if the audit table
  ever needs to track this.
