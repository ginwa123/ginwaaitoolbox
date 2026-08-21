# Agent Mode Tools list UI/UX + Wire Add Knowledge

**Date:** 2026-08-20
**Branch:** `worktree/agent-tools-ui-ux`
**Tasks:** task_1787254463604_3 ("agent mode knowledge")

## Goal

Fix two related UX problems on the `item_type='agent'` workspace
item (Agent Mode):

1. The "+ Add" button in the Knowledge panel logs a warning and does
   nothing — the AgentKnowledgeDialog exists but is not mounted
   anywhere in AppLayout, so clicking it goes nowhere.
2. The Tools panel renders all 44 registered tools as a cramped
   checkbox list with truncated descriptions — no search, no
   category grouping, no visual hierarchy between enabled and
   disabled tools.

This plan ships surgical fixes for both: wire the existing dialog
into AppLayout (the bug fix), and rework the Tools list into a
searchable, bulk-operable panel with a clear enabled/disabled visual
treatment.

## Changes

### 1. Wire Add Knowledge (bug fix)

`src/apps/desktop/src/components/AppLayout.vue`:

- Imported `AgentKnowledgeDialog` next to `AgentChatDialog`.
- Mounted `<AgentKnowledgeDialog>` below `<AgentChatDialog>`, gated
  on `item_type === 'agent'`. Uses `v-model:show` like every other
  dialog in the file.
- Replaced the `console.warn('not yet wired (v1.1)')` stubs in
  `handleAgentAddKnowledge` and `handleAgentRemoveKnowledge` with
  real implementations:
  - `openAgentKnowledgeDialog()` opens the dialog.
  - `handleAgentKnowledgeCreate(filePath, label)` calls
    `api.addAgentKnowledge(itemId, filePath, label)` and optimistically
    appends the new row to `agentKnowledge.value`. On error, stores
    the error message and keeps the dialog open so the user can see
    it + retry.
  - `handleAgentRemoveKnowledge(id)` optimistically removes the row
    from `agentKnowledge.value`, then calls
    `api.deleteAgentKnowledge(itemId, id)`. On failure, restores the
    previous value so the user can retry.
- New refs: `agentKnowledgeDialogOpen`, `agentKnowledgeBusy`,
  `agentKnowledgeError`. The dialog receives `:busy` + `:error` so
  the user sees submit progress and server errors without the
  dialog unmounting on failure.

### 2. AgentKnowledgeDialog — busy/error + Browse

`src/apps/desktop/src/components/dialogs/AgentKnowledgeDialog.vue`:

- New props: `busy?: boolean`, `error?: string | null` (defaults to
  `false` / `null` via `withDefaults`).
- The submit button label flips to "Adding…" while `busy=true`;
  Cancel + Browse are disabled while `busy=true` so the user can't
  close mid-submit.
- The error banner renders below the form when `error` is set
  (`data-testid="agent-knowledge-error"`).
- The dialog no longer closes itself on submit — the parent decides
  based on the server response. This avoids the "modal closes, then
  error appears with nowhere to retry" failure mode.
- New "📂 Browse…" button next to the File Path label. Opens a
  `FilePickerDialog` in `mode='file'` so the user can navigate to
  a markdown file instead of typing absolute paths by hand. The
  picker emits `select` → `handleFileSelected` fills `filePath` AND
  auto-fills the empty `label` from the basename (so a
  `/home/me/docs/spec.md` selection pre-populates the label
  "spec").

### 3. AgentView — Tools list UI/UX

`src/apps/desktop/src/components/views/AgentView.vue`:

- **Search/filter input** (top of Tools panel): filters the
  registry by name OR description (case-insensitive). Includes a ✕
  clear button visible only when the query is non-empty.
- **Filter-status line**: shows "Showing N / total matching" so
  the user always knows how the count relates to the unfiltered
  total.
- **Bulk ops**: "Select all" (enables every currently-filtered
  tool) + "Clear" (disables every currently-filtered tool).
  Both buttons disable themselves appropriately (Select all
  disables when every visible tool is already enabled; Clear
  disables when no visible tool is enabled).
- **Enabled-count chip** in the panel header: `5 / 44` format.
  Same chip style on the Knowledge panel for symmetry.
- **Per-tool ON chip**: small purple "ON" badge next to the
  tool name when the tool is enabled. Sits above the description.
- **Bordered card layout**: enabled tools get a violet border +
  `--semantic-active-bg` background. Disabled tools get a neutral
  border + `--semantic-sidebar-bg`. The 4px padding + 6px gap
  replaces the cramped 4px-gutter checkbox-row layout.
- **Full description on hover**: every tool's description is the
  full text (no `truncate`), with a `title="..."` tooltip for
  copy-paste.
- **Empty-search state**: when the filter matches zero tools,
  renders a polite "No tools match 'foo'. Clear search" hint
  instead of an empty list.

### 4. AgentView — Knowledge panel UI/UX

- **Count chip** next to "Knowledge" header: shows the entry count,
  styled with the violet chip when > 0, a neutral bordered chip
  when 0.
- **Hover-reveal remove button**: opacity 40% by default, 100% on
  `group-hover`. Adds a red-tinted hover background so the action
  is discoverable but doesn't clutter the card.
- **Bordered card style**: each entry gets a 1px border (matching
  the Tools card style for visual consistency).
- **Helpful empty-state copy**: explains the + Add button
  verb is "attach a markdown file the agent will read on every
  chat start".

### 5. AppLayout — bulk toggle handler

`src/apps/desktop/src/components/AppLayout.vue`:

- New `handleAgentToggleToolsBulk(toolNames, enabled)` runs all
  tools through `api.enableAgentTool` / `api.disableAgentTool` in
  parallel (`Promise.all`), then re-fetches the canonical list so
  partial successes + races collapse into one coherent view.
- Per-tool failures are caught and logged (don't abort the batch);
  the user gets the best-effort outcome and the refetch corrects
  any drift.
- New emit on `<AgentView>`: `toggleToolsBulk`. The mount in
  AppLayout forwards it to the new handler.

## Tests

- `src/apps/desktop/src/components/dialogs/AgentKnowledgeDialog.spec.ts`
  went from 4 → 8 tests:
  - Stubs `FilePickerDialog` with `vi.mock` (same pattern as
    `AddAgentDialog.spec.ts` — the real picker uses
    `useRecentFoldersStore` which requires active Pinia).
  - New: `shows the "Adding…" label and disables submit when busy=true`
  - New: `renders the error banner when error prop is set`
  - New: `renders a Browse button that opens the file picker`
  - New: `disables Cancel + Browse when busy=true (avoid closing mid-submit)`
- `src/apps/desktop/src/__tests__/AgentView.spec.ts` went from 7 → 18:
  - New: `renders knowledge count chip with the entry count`
  - New: `shows the enabled tools count chip as N / total`
  - New: `renders an ON chip for enabled tools`
  - New search-filter describe: by name, by description,
    empty-search state, filter-status text
  - New bulk-ops describe: Select all enabled, Select all
    disabled when all visible enabled, Clear with enabled tools,
    Clear disabled when none enabled, Select all only includes
    filtered (visible) tools

## Verification

```bash
cd src/apps/desktop
./node_modules/.bin/vitest run \
  src/__tests__/AgentView.spec.ts \
  src/__tests__/AppLayout.agentToolsToggle.spec.ts \
  src/__tests__/AppLayout.agentToolsFetchOnView.spec.ts \
  src/__tests__/agentToolsStore.spec.ts \
  src/components/dialogs/AgentKnowledgeDialog.spec.ts \
  src/components/dialogs/AddAgentDialog.spec.ts
# → 45 / 45 pass

./node_modules/.bin/vitest run
# → 2406 / 2406 pass (the 6 unhandled-rejection errors are
#   pre-existing on main from AppLayout.chatSuffixRoundTrip.spec.ts;
#   confirmed by running the same file against the unchanged
#   main checkout).

cd ../..
zig build test --summary all
# → 2537 / 2543 pass, 6 skip, 0 fail

cd src/apps/desktop
bun run build
# → clean (vue-tsc --noEmit passes)
```

## Notes for reviewers

- The "category grouping" idea (collapse/expand headers per
  group) was considered and dropped: the registry only exposes
  `name` + `description`, no category metadata. Hardcoding a
  name→category map in the frontend is brittle (every new tool
  needs a frontend update). Search filter gives the same
  navigation win (jump to "kanban" or "lsp") without the
  maintenance burden.
- `handleAgentToggleToolsBulk` re-fetches the canonical list at
  the end rather than computing the canonical state from the
  partial-success set — this matches the single-tool `buildToggle`
  helper's "canonical state from server" pattern, so success
  races (e.g. user clicks Select all while a server-side
  re-classification is happening) collapse cleanly.
- The Browse button uses `mode='file'` (NOT `'both'`) — we want
  the user to end on a file, not a folder. The picker still
  navigates INTO folders to find them.
- `AgentKnowledgeDialog.handleClose` now early-returns when
  `busy=true` (matching the Cancel disabled state), so the
  user can't accidentally dismiss the modal mid-submit.
- The new `agentKnowledgeBusy` + `agentKnowledgeError` refs are
  cleared by `closeAgentKnowledgeDialog` so the dialog opens
  fresh next time.
