# nalar — add-kanban shows "Untitled project" until reload (wire-shape mismatch)

## Symptom

User adds a kanban via `+ Add Item → Add Kanban`, types a name (e.g.
"My Cool Sprint"), picks a folder, clicks Add. The kanban appears
in the sidebar as **"Untitled project"** (the fallback in
`WorkspaceItem.vue:401-408` for empty `item.name`). After a page
reload, the kanban shows its real name. No console error, no toast.

Same flow for regular folder items works correctly — only kanban
shows the bug.

## Root cause

The backend (`workspace_items_create_kanban.zig`) returned a **flat**
`CreateKanbanResponse`:

```json
{"id":"item_...","workspace_id":"ws_...","item_type":"kanban",
 "name":"My Cool Sprint","path":"/tmp","position":0}
```

The frontend (`api/index.ts::createKanban`) destructured a
**wrapped** envelope:

```ts
const { item, columns } = await api.createKanban(...)
```

`item` was `undefined` → `ws.items.push({...undefined, kanban_columns: undefined, tasks: []})`
→ the new item had `name: undefined` → the sidebar's
`{{ item.name || 'Untitled project' }}` fallback fired → until
reload, when `getWorkspacesItems` repopulated from the DB with the
correct shape.

The bug was silent because:
1. TypeScript trusted `WorkspaceItem.name: string` (non-optional),
   so the type checker didn't complain about `item.name` being undefined
2. The `kanbanStore` + `kanbanApi` tests mocked the response with
   the **correct** shape (`{item, columns}`), so they passed — they
   never exercised the real backend's flat shape
3. The sidebar template's `||` fallback is a deliberately permissive
   "looks fine" UX — it shows "Untitled project" instead of a broken
   row, so the failure is invisible

## Fix (4 layers)

### Layer 1 — backend (`workspace_items_create_kanban.zig`)

Add a `CreateKanbanResponseFull` envelope struct:

```zig
pub const CreateKanbanResponseFull = struct {
    item: CreateKanbanResponse,
    columns: []const kanban_model.KanbanColumn,
};
```

Change `useCase` to return `CreateKanbanResponseFull` and serialize
via `std.json.Stringify.valueAlloc`. The `seeded_cols` from
`kanban_model.listColumns` is now included in the response — the
kanban board renders its 3 default columns without a follow-up
`GET /items/:id/kanban/columns` round-trip.

Bonus: also fixed the `position: 0` placeholder bug. The original
INSERT computed position via `COALESCE(MAX+1, 0)` so the value was
unknown until a follow-up SELECT. Added a `readInsertedPosition`
helper that does the SELECT and falls back to `0` on failure
(non-fatal — next refresh reconciles).

### Layer 2 — frontend store (`stores/workspaces.ts::addKanbanItem`)

Add the defensive merge that `addDesignItem` already has:

```ts
ws.items.push({
  ...item,
  name: item.name ?? name,             // ← form value as fallback
  item_type: item.item_type ?? 'kanban',
  path: item.path ?? path,
  kanban_columns: columns || [],       // ← never undefined
  tasks: [],
})
```

Defense-in-depth — if the backend ever regresses to the bare
`{id, success}` shape, the sidebar still renders the typed name.

### Layer 3 — backend test (`workspace_items_create_kanban_test.zig`)

Add a 4th contract: `create_kanban handler returns wrapped {item,
columns} envelope` — checks that `CreateKanbanResponseFull` appears
in the source so the regression catches anyone reverting to the
flat shape.

Update the file-level docstring (line 11-16) to describe the new
envelope shape — the old docstring was the original bug source:
"Returns 201 with `{id, workspace_id, item_type, name, position}`"
documented the WRONG shape.

### Layer 4 — frontend store test (`kanbanStore.spec.ts`)

Add a regression test that mocks the API to return an item missing
`name` / `item_type` / `path`, then asserts the local store has the
form values applied. Pins the defensive merge contract.

## Why the bug went undetected

Three layers of false confidence:

1. **TypeScript type-check**: `apiFetch<{ item: WorkspaceItem }>`
   says `item.name: string`. At runtime it's `undefined`. No type
   error.

2. **Unit tests**: `kanbanStore.spec.ts:111-127` mocks the API to
   return `{item: {id, item_type, name}, columns}`. `kanbanApi.spec.ts:60-71`
   mocks `mockFetchOnce` to return the same shape. Both pass. But
   they test what the FRONTEND EXPECTS, not what the BACKEND RETURNS.
   No test in the codebase made a real HTTP call to
   `POST /workspaces/:wsId/items/kanban` and asserted on the
   response shape.

3. **Backend tests**: `workspace_items_create_kanban_test.zig` is a
   static-substring test, not a behavioral one. It checks for
   `parseFromSliceLeaky`, `seedDefaultColumns`, `.status_code = 201`
   — but not the wire envelope shape. The "Returns 201 with
   `{id, workspace_id, item_type, name, position}`" docstring
   *documented* the wrong shape, cementing the bug as intended
   behavior.

## Verification

### Backend build + tests

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all
# 1839/1848 pass (3 pre-existing failures in workflow_retry_delay_test, unrelated)

timeout 200 zig build
# Binary builds, no errors
```

### Frontend build + tests

```bash
cd src/apps/desktop
timeout 180 bunx vitest run src/__tests__/kanbanStore.spec.ts
# 19/19 pass (includes the new defensive-fallback regression test)

timeout 180 bunx vitest run
# 1452/1452 pass

timeout 180 bun run build
# vue-tsc + vite build clean
```

### Live smoke test against port 8080 (NOT 8081)

```bash
# Start isolated server
rm -rf /tmp/nalar-smoke && mkdir -p /tmp/nalar-smoke
env -i HOME=/tmp/nalar-smoke PATH=$PATH \
  nohup /home/ginwa/.../zig-out/bin/nalarcore-linux-x86_64 --port 8080 \
  >/tmp/nalar-smoke.log 2>&1 &
disown
sleep 4

# Create a workspace
WS_ID=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces \
  -H 'content-type: application/json' \
  -d '{"name":"smoke"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

# Create a kanban — verify the response shape is {item, columns}
RESP=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/kanban" \
  -H 'content-type: application/json' \
  -d '{"name":"My Cool Sprint","path":"/tmp"}')
echo "$RESP" | python3 -m json.tool
# Expect:
# {
#   "item": {"id":"item_...","workspace_id":"ws_...","item_type":"kanban",
#            "name":"My Cool Sprint","path":"/tmp","position":0},
#   "columns": [
#     {"id":"col_...","workspace_item_id":"item_...","name":"todo",
#      "description":"","position":0,"created_at":"..."},
#     {"id":"col_...","workspace_item_id":"item_...","name":"in progress",
#      "description":"","position":1,"created_at":"..."},
#     {"id":"col_...","workspace_item_id":"item_...","name":"done",
#      "description":"","position":2,"created_at":"..."}
#   ]
# }

# Create a 2nd kanban — verify position is 1 (NOT both 0)
curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/kanban" \
  -H 'content-type: application/json' \
  -d '{"name":"Second Sprint","path":"/tmp"}' | python3 -m json.tool
# Expect: item.position = 1

# Cleanup
SMOKE_PID=$(ps aux | grep nalarcore-linux-x86_64 | grep -v grep | awk '{print $2}')
[ -n "$SMOKE_PID" ] && kill $SMOKE_PID
```

## Pitfalls

- **Don't mock what the BACKEND doesn't return.** If the frontend test
  mocks `{item, columns}` but the real backend returns the flat shape,
  the test passes while production is broken. Always make at least one
  test do a real (or mock-equivalent) call to the actual backend.
- **Don't trust the docstring.** The backend's test docstring said
  "Returns 201 with `{id, workspace_id, item_type, name, position}`"
  — documenting the bug as intended behavior. Update the docstring
  to describe the CORRECT shape, then assert on it.
- **The `|| 'Untitled project'` fallback is not a feature.** It's a
  UX hedge for legacy rows with empty names. It SILENCES bugs that
  should crash loudly. If you find yourself using the fallback
  field as a debugging signal, the data is wrong upstream — fix it
  at the API boundary, don't lean on the fallback.
- **`zig.json.Stringify.valueAlloc` + struct fields.** Adding a
  wrapper struct (`CreateKanbanResponseFull { item, columns }`) and
  serializing it as one call is the cleanest path. Avoid building
  JSON manually via string concat — Zig's serializer is
  reflection-based and handles escape sequences / null correctly.
- **Captured-row-is-const with `if (...)|row|`.** Inline
  `if (db.query(...)) |q| { defer q.deinit(); if (q.next() catch
  null) |row| { defer row.deinit(...); ... } }` runs into
  `error: expected type '*T', found '*const T'` in Zig 0.16
  because `|row|` captures as const and `Row.deinit(self: Row, ...)`
  wants Row by value. Extract into a helper function with
  `var q = db.query(...) catch return 0;` — the explicit `var`
  sidesteps the const-capture.
- **Static-contract tests are silent.** A test like
  `workspace_items_create_kanban_test.zig` that checks for
  `parseFromSliceLeaky` in the source DOES NOT verify the wire
  shape — it only verifies a parser was called. Add an explicit
  contract that asserts the response envelope.

## Related

- `nalar-frontend-patterns.md` — `bun run build` is the only check
  that catches TS type errors; `bunx vitest run` doesn't.
- `nalar-backend-architecture.md` — HTTP handler thin-wrapper pattern
  (per-request arena, parseFromSliceLeaky, etc.).
- `nalar-data-and-routines.md` — Static-contract test convention for
  HTTP handlers.
- `workspace_items_create_empty_name_test.zig` — the EmptyName
  contract test for the same handler; mirrors the static-check
  pattern.