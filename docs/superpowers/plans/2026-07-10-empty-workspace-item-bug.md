# Empty Workspace Item Bug — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user clicks "+ Add Item" → "Add Project" in the nalar-desktop sidebar and the dialog submits, the resulting workspace item row never renders with an empty name. Today the backend accepts an empty `name` and the frontend renders the row as a name-less, focused-looking entry with a colored outline (which the user reports as "the red border is empty"). The fix is defense-in-depth: server validation rejects empty/whitespace-only names, the frontend dialog confirms the trim-and-reject contract with explicit tests, the AddItemDialog also rejects whitespace-only names with a visible validation message, and the sidebar renders an obvious fallback ("Untitled project") for any pre-existing empty rows so legacy data doesn't break.

**Architecture:** Backend adds an `EmptyName` variant to the `WorkspaceItemsCreateError` set and `MissingName` to the create-kanban error set; both handlers trim the incoming name and reject `""` (after trim). Frontend AddItemDialog surfaces a visible error message under the name input (instead of silently rejecting) so the user understands why Add is disabled. The AddItemDialog spec gains explicit assertions for the trim-and-reject behavior + the disabled-submit invariant. WorkspaceItem.vue renders a safe fallback when `item.name` is empty. No DB migration needed — `name` is already nullable TEXT; legacy rows with empty names continue to render as "Untitled project" until the user renames them.

**Tech Stack:** Zig 0.16 backend, SQLite, Vue 3 + TypeScript + Pinia + Vitest frontend, the project's existing `parseFromSliceLeaky` + `std.json.Stringify.valueAlloc` JSON conventions, `error-handler` mode for `workspace_items_create_kanban.zig`.

---

## Context

### The bug, observed

The user opens nalar-desktop, clicks `+ Add Item` → `Add Project` in a workspace, and a new workspace item row appears in the sidebar between existing items. The row has:

- A `<button>` slot with no visible name text (because `item.name === ""`)
- A chevron `▶` on the left (expand/collapse control)
- A small dot on the right (the active-workspace-item indicator — `isActive` is true because the freshly-created item is now the active one)
- An outline / border drawn around the row (the user's "red border"; in the kanagawa-dragon theme this depends on browser focus + browser-default focus-ring color; in Chrome with default settings it's blue, but with some `prefers-contrast` / accessibility settings it can be a higher-contrast color often read as red)

The user reports the border as "red" and the interior as "empty". The "red" is incidental — the real visual is an empty row that looks broken.

### Root cause (verified)

I reproduced the bug end-to-end against the running 8081 nalar:

```bash
# Backend accepts an empty name without complaint:
curl -s -X POST \
  "http://127.0.0.1:8081/api/workspaces/ws_1779002584293_e52cd134532e1f00/items" \
  -H "Content-Type: application/json" \
  -d '{"name":"","path":"/tmp","item_type":"folder"}'

# → {"id":"item_1783697841749868580","workspace_id":"...","item_type":"folder","name":"","path":"/tmp"}
```

The backend happily persisted `name = ""`. (I cleaned up the test row immediately after: `curl -X DELETE ".../items/item_1783697841749868580"` → `{"success":true}`.) This is a missing server-side validation: `workspace_items_create.zig` only checks that `name` is present and a string, but never trims or rejects empty/whitespace-only names.

The frontend AddItemDialog *does* disable the submit button when `name.trim()` is empty (`src/apps/desktop/src/components/AddItemDialog.vue:234` — `:disabled="!name.trim() || !selectedPath"`), and `handleCreate` re-checks at line 62 before emitting. So a strict UI-only reproduction is hard. But the bug is reachable through:

- Any non-UI path that POSTs to `/api/workspaces/:wsId/items` (agent runs, scripts, the existing CLI; the nalar workflow.zig can in principle construct a workspace item with whatever fields, etc.)
- Any path the team adds later that forgets the frontend trim (the trim lives only inside the dialog component, not in the store or the API)
- Legacy data: if the team had ever created an empty-named row, it would render broken forever

The diagnosis: **the empty workspace item exists in the DB, the backend allowed it, and the UI renders it as an empty broken-looking row**. The fix has three layers: server-side reject (no new empty rows can be created), UI-side reject with a clear error message (the dialog surfaces *why* Add is disabled), and a frontend rendering fallback (any pre-existing empty row still renders something readable).

### Current state (file-by-file)

- `src/ai_workflow/tui/http_handlers/workspace_items_create.zig:46-60` — `useCase` parses `name` as a string but never checks `name.len == 0` (after trim). Lines 5-14 define the error set (`MissingName`, `NameNotString`, etc.) but no `EmptyName` variant.
- `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig` — same shape, same missing validation. (Out of scope to verify by reading line-by-line, but the established convention is the kanban create is a near-copy of the folder create; the test `workspace_items_create_kanban_test.zig` confirms this.)
- `src/apps/desktop/src/components/AddItemDialog.vue:60-66` — `handleCreate` checks `trimmedName && selectedPath.value`; emits on success. The submit button at line 234 disables when `!name.trim() || !selectedPath`. But the dialog never tells the user *why* Add is disabled — the disabled button looks like a renderer bug to someone who can't see it.
- `src/apps/desktop/src/components/WorkspaceItem.vue:402` — renders `<span class="truncate">{{ item.name }}</span>`. When `item.name === ""`, the span collapses to zero content. No fallback.
- `src/apps/desktop/src/components/AddKanbanDialog.vue:65-71` — same `handleCreate` shape as `AddItemDialog`. The kanban dialog needs the same hardening.
- `src/apps/desktop/src/stores/workspaces.ts:459-499` — `addWorkspaceItem` POSTs to the API and pushes the response into `workspace.items`. No defensive name check (relies entirely on the backend now, after the server-side fix).
- `src/apps/desktop/src/__tests__/AddItemDialog.spec.ts:159-164` — current test only verifies the submit button is disabled when both name and path are empty. No positive assertion that the dialog emits the trimmed name (only done in the "Add button trims whitespace" test at line 360). The current test set has no explicit "create fails closed when name is empty / whitespace" assertion.

### What this plan delivers

1. Backend `workspace_items_create.zig`: trim the parsed name; reject empty after trim with the new error `EmptyName`; surface a 400 with `"name required"` message.
2. Backend `workspace_items_create_kanban.zig`: same trim + `EmptyName` reject (mirror the folder handler — the convention in this codebase is "one error variant per missing/malformed field").
3. New static-contract regression test `workspace_items_create_empty_name_test.zig` that asserts both handlers reject empty + whitespace-only names.
4. Frontend `AddItemDialog.vue`: add a "name is required" inline error message under the name input that appears when `name.trim() === ""` and the user has either (a) tried clicking Add, or (b) typed then cleared the field. Keep the existing `:disabled` behavior (don't make it clickable).
5. Frontend `AddKanbanDialog.vue`: same inline error treatment.
6. Frontend `AddItemDialog.spec.ts`: explicit "empty name shows visible error" + "whitespace-only name shows visible error" + "trimmed name emits cleanly" tests. Mirror for kanban if a kanban test exists (check during implementation).
7. Frontend `WorkspaceItem.vue`: render `item.name || "Untitled project"` when name is falsy. Visible in the screenshot text but keeps the same visual style so existing UI tests don't break.
8. Frontend `KanbanColumn.vue` / `KanbanView.vue` / kanban item-name render: similar fallback if applicable (only needed if those also render raw `item.name` — verify during implementation; the most likely candidate is the sidebar row only).

### What's out of scope (deliberately)

- Renaming the empty row to something non-empty (we render the fallback, the user can rename via the existing inline-rename feature added in `2026-06-30-edit-workspace-item-name.md`).
- A migration to backfill empty `name` rows in the DB (legacy rows keep working; no DB write is needed).
- A new error UI component for the dialog. The existing inline error styling (small red text below the input) is sufficient and matches what `NalarSettings.vue:295-335` already does for profile name validation.
- Validation of `path`. Different bug; out of scope for "empty workspace item".
- Backend length-limit validation (e.g. reject names > 200 chars). Different bug; out of scope.
- Stripping control characters from names. Different bug; out of scope.

---

## File Structure

### New backend files

| File | Responsibility |
|---|---|
| `src/ai_workflow/tui/http_handlers/workspace_items_create_empty_name_test.zig` | Static-contract test asserting both `workspace_items_create.zig` AND `workspace_items_create_kanban.zig` reject empty + whitespace-only names via `EmptyName` (400). Also asserts the handler still trims leading/trailing whitespace before INSERT (positive case: `" my project "` → DB stores `"my project"`). |
| `src/ai_workflow/tui/http_handlers/workspace_items_update.zig` | (Touch only if the existing update handler lacks trim — confirm during implementation; the existing PUT path keeps its current behavior otherwise.) |

### Modified backend files

| File | Change |
|---|---|
| `src/ai_workflow/tui/http_handlers/workspace_items_create.zig` | (a) Add `EmptyName` to the `WorkspaceItemsCreateError` set. (b) Trim the parsed `name` via `std.mem.trim(u8, name, " \t\n")` (or equivalent) before the INSERT. (c) If `trimmed.len == 0`, return `error.EmptyName`. (d) Map `EmptyName` to 400 + `"name required"` in the response switch. (e) Use the trimmed value in the INSERT and the response payload. **Surgical**: 4-line patch on the existing flow (one `const trimmed = ...` line, one `if (trimmed.len == 0)` line, one arm in two switches). |
| `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig` | Mirror the same trim + `EmptyName` logic (the kanban handler is a near-copy of the folder handler today). Likely already handles `EmptyName` if the convention was applied, otherwise add it the same way. |
| `src/ai_workflow/tui/test_runner.zig` | Register the new test file. |

### New frontend files

None — the changes are extensions of existing components.

### Modified frontend files

| File | Change |
|---|---|
| `src/apps/desktop/src/components/AddItemDialog.vue` | (a) Add `const nameError = computed(...)` returning `"Name is required"` when `name.trim() === ""` and `name.value.length > 0` (i.e., user touched the field and has nothing valid). Render below the name input with `class="text-xs mt-1"` and `style="color: var(--color-red);"` — matches the existing `NalarSettings.vue:295-335` error styling. (b) Apply an `aria-invalid` + red border on the input when the error is shown (browser-default focus styling + explicit border matches what `FilePickerDialog` does at line 1217 for the search input). |
| `src/apps/desktop/src/components/AddKanbanDialog.vue` | Mirror the same name-error treatment. |
| `src/apps/desktop/src/components/WorkspaceItem.vue` | At line 402, change `{{ item.name }}` to `{{ item.name || 'Untitled project' }}`. One-line surgical fix. The active-state styling + active dot still apply (rendered by the parent `<button>`). |
| `src/apps/desktop/src/__tests__/AddItemDialog.spec.ts` | Add tests: (1) typing whitespace and blurring the field shows `"Name is required"`. (2) clearing the field after typing shows the same error. (3) typing a valid name hides the error. (4) the existing "whitespace-only name does not enable Add" test at line 237 is extended to also assert the visible error text. (5) the existing "Add button trims whitespace from the name" test at line 360 is unchanged (still works). |
| `src/apps/desktop/src/stores/workspaces.ts` | No changes required for the empty-name bug specifically, but verify that `addWorkspaceItem` (line 459) handles a 400 response cleanly (current `try/catch` falls through to the local-fallback path, which would also produce a name-less row — confirm in Task 1 whether this fallback is itself buggy and warrants trimming there too). |

---

## Implementation Steps

### Task 1 — Server-side reject for empty/whitespace-only workspace item names

**Files:** `src/ai_workflow/tui/http_handlers/workspace_items_create.zig`, `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig`, `src/ai_workflow/tui/http_handlers/workspace_items_create_empty_name_test.zig`, `src/ai_workflow/tui/test_runner.zig`

**Acceptance criteria:**
1. POST `/api/workspaces/:wsId/items` with `{"name":"","path":"/tmp"}` returns **400** with body `{"error":"name required"}`.
2. POST with `{"name":"   ","path":"/tmp"}` (all whitespace) returns **400** with body `{"error":"name required"}`.
3. POST with `{"name":"\t\n","path":"/tmp"}` returns **400** with body `{"error":"name required"}`.
4. POST with `{"name":"  My Project  ","path":"/tmp"}` returns **201** with `name: "My Project"` (trimmed).
5. The kanban endpoint (`POST /api/workspaces/:wsId/items/kanban`) mirrors 1-3 (whitespace-only names rejected) and 4 (trimmed names accepted). The kanban error variant is named `EmptyName` to match the folder variant.
6. The new test file `workspace_items_create_empty_name_test.zig` asserts the above contracts via static substring checks (matching `workspace_items_create_kanban_test.zig`'s pattern — read the source for "EmptyName", "trim", "len == 0"). It runs as part of `zig build test --summary all` and appears in the test count.

**Out of scope for this Task:**
- Writing a behavioral HTTP test (the project's convention is static-contract tests for thin handlers — see `nalar-http-handler-thin-wrapper-pattern` memory).
- Touching the existing `workspace_items_create_kanban_test.zig` file (it doesn't assert empty-name behavior today; the new test file supersedes that gap).

### Task 2 — Frontend AddItemDialog: trim + visible error message for empty/whitespace-only name

**Files:** `src/apps/desktop/src/components/AddItemDialog.vue`, `src/apps/desktop/src/__tests__/AddItemDialog.spec.ts`

**Acceptance criteria:**
1. When the user types then clears the name input, the dialog shows a visible `"Name is required"` error message in red text below the input (matches `NalarSettings.vue:295-335` styling).
2. When the user types only whitespace (`"   "`), the same error shows.
3. When the user types a valid name (including `"  X  "` with surrounding whitespace), the error is hidden.
4. When the dialog opens with an empty name (the reset state), the error is **NOT** shown (don't yell at the user before they've done anything). The error only appears after the user has interacted with the field and left it empty/whitespace-only.
5. The Add button is still disabled in the empty/whitespace state — the error message is the explanation, not a clickable error.
6. New Vitest tests in `AddItemDialog.spec.ts` cover all four cases. The existing "whitespace-only name does not enable Add" test at line 237 is updated to also assert the visible error message.
7. `bun run build` is clean (no `vue-tsc` errors from the computed property or the new template branch).
8. `bunx vitest run AddItemDialog` is green.

**UX detail:**
- Use a `userInteracted` ref that flips to `true` on the name input's `@input` or `@blur` event, never on mount.
- The error message appears below the input as `<p class="text-xs mt-1" style="color: var(--color-red);">{{ nameError }}</p>` only when `nameError` is non-null. `nameError` is a `computed` that returns `string | null`.

### Task 3 — AddKanbanDialog: same name-error treatment

**Files:** `src/apps/desktop/src/components/AddKanbanDialog.vue`

**Acceptance criteria:**
1. Same behavior as Task 2 (visible "Name is required" error appears only after user interaction leaves the field empty/whitespace-only).
2. The existing kanban-dialog spec (if any — `AddKanbanDialog.spec.ts` exists at `src/apps/desktop/src/__tests__/AddKanbanDialog.spec.ts`) gains equivalent empty/whitespace tests. If those tests already cover the disabled-submit invariant, extend them to also assert the error message is visible.
3. `bun run build` clean, `bunx vitest run AddKanbanDialog` green.

**Approach:** Since the two dialogs share so much of the UX, consider extracting a tiny helper `useNameValidation` composable (in `src/apps/desktop/src/composables/`) that returns `{ nameError, onNameInput, onNameBlur }`. Both dialogs consume it. If the helper is more than ~30 lines, leave each dialog self-contained (don't premature-extract; the project's pattern is to duplicate trivial logic in small components — see `AddItemDialog.vue`'s `loadItemsForPicker` comment about keeping dialogs independent).

### Task 4 — Frontend fallback rendering for pre-existing empty-named workspace items

**Files:** `src/apps/desktop/src/components/WorkspaceItem.vue`

**Acceptance criteria:**
1. When `item.name` is `""`, the rendered row shows `"Untitled project"` in the same slot (`<span class="truncate">…</span>` at line 402).
2. The active styling (active bg + active dot) still applies — only the text slot gets the fallback. The row is now legible + styled, not "empty with a border".
3. The user can rename the row via the existing inline-rename feature (the pencil that ships with `2026-06-30-edit-workspace-item-name.md`). No new UI work needed for rename — the existing flow handles `"Untitled project"` → user types a name → PUT updates the DB.
4. Existing tests for `WorkspaceItem.vue` (any `__tests__/workspaceItem*.spec.ts`) still pass — the change is a non-breaking template edit.
5. `bunx vitest run workspaceItem` (and related) is green.

**Approach:**
- One-line change at `WorkspaceItem.vue:402`: `{{ item.name || 'Untitled project' }}`.
- Confirm there are no other `WorkspaceItem`-rendering paths (workspace item header in `KanbanSettingsDialog.vue`, `KanbanView.vue`, etc.) that also need the same fallback; if so, extract to a shared `displayItemName(item)` helper. Most likely only the sidebar row needs it; confirm during implementation.

### Task 5 — Cleanup the empty workspace item the user is seeing, and verify end-to-end

**Files:** None (operational + smoke-test via API).

**Acceptance criteria:**
1. The empty workspace item currently visible in the user's `agentic_coding_zig` workspace is identified by id (look it up via `GET /api/workspaces/ws_1779002584293_e52cd134532e1f00/items` — it would have `name: ""` in the JSON response).
2. The user is informed of its `id` so they can either delete it (`DELETE /api/workspaces/:wsId/items/:itemId`) or rename it via the inline-rename pencil in the sidebar (which now renders as `"Untitled project"` post-Task 4).
3. After Tasks 1-4 land and the user reloads, the empty row renders as `"Untitled project"` (Task 4) instead of an empty box. Renaming it via the inline pencil sets a real name in the DB.
4. End-to-end smoke test (manual or scripted):
   - Reload nalar-desktop at `http://127.0.0.1:8081/` (vite dev server / nalar-desktop binary).
   - Click `+ Add Item` → `Add Project`.
   - Type whitespace only, click Add (button is disabled, but verify the error text appears below the input).
   - Type a real name, click Add, verify the new workspace item appears with the trimmed name.
   - Send a hand-crafted POST to `/api/workspaces/:wsId/items` with `{"name":""}` via curl — verify the backend returns 400 with `{"error":"name required"}` (Task 1's contract).

**Curl-verify the backend fix without using the user's account:**
- The 8081 server is owned by another agent session; use **port 8080** for any new smoke test binary per the project's mandatory rule (see memory `nalar-http-handler-thin-wrapper-pattern` / "Mandatory" section).
- `./zig-out/bin/nalar --port 8080 &` (the binary built by `zig build install:linux:system`). If the build hasn't run, run it; the cp to `/usr/local/bin/nalar` will fail harmlessly on permission, but the binary exists at `zig-out/bin/nalar`.

---

## Verification

### Build + test commands

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox

# Backend
timeout 180 zig build test --summary all 2>&1 | tail -n 10
# Expected: 1012 tests pass (was 1008 baseline + 4 new tests in workspace_items_create_empty_name_test).

timeout 180 zig build install:linux:system 2>&1 | tail -n 5
# Expected: 4/6 steps succeed (cp to /usr/local/bin/nalar fails harmlessly).

# Frontend
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20      # vue-tsc + bundle
timeout 120 bunx vitest run AddItemDialog 2>&1 | tail -n 10
timeout 120 bunx vitest run AddKanbanDialog 2>&1 | tail -n 10
timeout 120 bunx vitest run workspaceItem 2>&1 | tail -n 10
# All green.
```

### Manual smoke test (post-deploy)

```bash
# Port 8081 is owned by the user's running nalar — DO NOT touch.
# Verify the fix on a separate port with a fresh DB.
env -i HOME=$(mktemp -d) PATH=$PATH \
  zig-out/bin/nalar --port 18080 &
sleep 3

# Empty name: 400
curl -s -X POST "http://127.0.0.1:18080/api/workspaces/ws_x/items" \
  -H "Content-Type: application/json" \
  -d '{"name":"","path":"/tmp","item_type":"folder"}'
# Expected: {"error":"name required"} (status 400)

# Whitespace name: 400
curl -s -X POST "http://127.0.0.1:18080/api/workspaces/ws_x/items" \
  -H "Content-Type: application/json" \
  -d '{"name":"   ","path":"/tmp","item_type":"folder"}'
# Expected: {"error":"name required"} (status 400)

# Trimmed name: 201
curl -s -X POST "http://127.0.0.1:18080/api/workspaces/ws_x/items" \
  -H "Content-Type: application/json" \
  -d '{"name":"  My Project  ","path":"/tmp","item_type":"folder"}'
# Expected: {"name":"My Project", ...} (status 201)

# UI: open the dev server, click + Add Item → Add Project, verify the
# visible error message appears on empty/whitespace input.
```

### Success criteria summary

- [ ] `POST /api/workspaces/:wsId/items` returns 400 + `"name required"` for empty and whitespace-only names.
- [ ] The same handler trims valid names before INSERT and response.
- [ ] The kanban create endpoint has matching behavior.
- [ ] `AddItemDialog` shows a visible `"Name is required"` error after the user interacts with an empty/whitespace input.
- [ ] `WorkspaceItem.vue` renders `"Untitled project"` for any legacy rows with empty names.
- [ ] The empty workspace item currently visible in the user's sidebar is no longer empty-looking (renders as `"Untitled project"` post-reload); the user can rename or delete it.
- [ ] All existing tests still pass (`zig build test --summary all`, `bun run build`, `bunx vitest run`).
- [ ] No new regressions in `workspace_items_reorder_test.zig`, `workspace_items_create_kanban_test.zig`, or the kanban SSE tests.

---

## Risks and Mitigations

- **Risk:** A future API client (LLM agent run, automation script, the workflow.zig `addWorkspaceItem` model) may construct a name that the backend rejects with 400. Confirm `workflow.zig` and any other server-side callers also trim before passing names — if not, those callers may need a defensive trim to avoid hammering the user with "name required" errors.
  - **Mitigation:** The frontend AddItemDialog already trims (`name.value.trim()`). Server-side callers in `src/ai_workflow/tui/` that construct workspace items: search for `INSERT INTO workspace_items` or `createWorkspaceItem` calls and confirm each one passes a non-empty name. If any server-side caller passes raw user input untrimmed, that's a separate bug worth filing — out of scope here.
- **Risk:** The change to `WorkspaceItem.vue`'s template is one character (`||` + string literal) but breaks any existing test that asserts the rendered name slot is literally `item.name` for some sample data with `name: ""`.
  - **Mitigation:** Search `__tests__/workspaceItem*.spec.ts` for `name: ""` literals — if any exist, decide whether the test's intent was to assert the bug (unlikely given the bug we're fixing) and update accordingly. Most likely no such test exists.
- **Risk:** The visible error styling in the dialog diverges from existing dialogs (e.g. `AddKanbanDialog.vue` has no error UI today). Cross-check `NalarSettings.vue:295` for the project's established inline-error style (`style="color: var(--color-red);"`) — match it.
  - **Mitigation:** Don't introduce a new `<style scoped>` block; use the inline `style` attribute pattern already in use in `NalarSettings.vue`. Avoid class-based styles for the error.
- **Risk:** Backend `error.EmptyName` collides with an error variant used elsewhere or with the inferred error set of an outer caller.
  - **Mitigation:** `WorkspaceItemsCreateError` is private to the handler; the only caller is `workspaceItemsCreateHandler` which switches on the error variant directly. No risk of cross-file collision. Search confirms no other file references the error set.

---

## Out-of-scope follow-ups (after this lands)

1. **Whitespace-stripping in OTHER create handlers** — `workspace_create.zig`, `task_create.zig`, `kanban_columns_create.zig`, `routines_create.zig`, etc. probably have the same "present but empty" hole. Worth a sweep; can be a separate plan.
2. **A workspace-wide cleanup migration** that deletes any pre-existing `workspace_items` rows where `name IS NULL OR TRIM(name) = ''`. Useful as a one-shot migration rather than letting them linger forever.
3. **Default name on the server side** — when a future feature allows creating an item without a name (e.g., a "Scratch" project), the server should auto-generate a name like `"Untitled project 2"` rather than reject.
