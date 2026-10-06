# TASK 6 BRIEF — Frontend: API client, store, section, route

WORK DIRECTLY IN THIS EXISTING WORKTREE — do NOT call `set_git_worktree`, do NOT create a
new worktree, do NOT touch `/home/ginwa/ginwaaitoolbox`:

    /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930

`cd` there for every command. All paths below are relative to that directory.

Frontend root is `src/apps/desktop/`. Another agent is concurrently doing the Zig HTTP
handlers (Task 5) — do NOT edit anything under `src/` (the Zig tree) except nothing. Your
changes are confined to `src/apps/desktop/`.

Plan: `docs/superpowers/plans/2026-10-02-workspace-secrets.md` (rev 2) — `### Task 6`,
Design Decision 9.

---

## The contract you are building against

The backend surface (Task 5, landing in parallel) is:

| Method | Path | Body |
|---|---|---|
| GET | `/api/workspaces/:workspace_id/secrets` | `{ secrets: [{id, name, created_at, updated_at}], count }` |
| POST | `/api/workspaces/:workspace_id/secrets` | `{ secret: {...} }` — body `{ name, value }` |
| PATCH | `/api/workspaces/:workspace_id/secrets/:secret_id` | `{ secret: {...} }` — body `{ name?, value? }` |
| DELETE | `/api/workspaces/:workspace_id/secrets/:secret_id` | `{ id, success }` |

**No response ever contains the value.** There is no `key_hint` (dropped by reviewer
decision). The UI renders each row as `NAME` + "configured" + `updated_at`.

---

## STEP 1 — API client

Add to `src/apps/desktop/src/api/index.ts`, beside the existing documents block (~line 5910+),
mirroring `listDocuments` / `createDocument` / `updateDocument` / `deleteDocument` exactly:

```ts
export interface Secret {
  id: string
  name: string
  created_at: string
  updated_at: string
}
```
plus `listSecrets`, `getSecret`(optional — skip if unused), `createSecret`, `updateSecret`,
`deleteSecret`.

Conventions to copy from the documents functions: relative path with **no `/api` prefix**
(`apiFetch` adds it), `encodeURIComponent` on every path segment.

Copy the `api/index.ts:5915-5919` comment's principle into your block: the backend scopes
every read AND write by the `workspace_id` in the path, so **do not add a client-side
workspace filter** — that would be a second, weaker copy of a rule already in SQL.

---

## STEP 2 — Pinia store

Create `src/apps/desktop/src/stores/secrets.ts`.

**`src/apps/desktop/src/stores/documents.ts` is the template — read its 1–30 line header
comment first; it states exactly what this store must and must not do.** Honour it:

- No client-side workspace filtering.
- State: `secrets`, `loading`, `saving`, `error: string | null`, `loaded: boolean`.
  `loaded` distinguishes "not fetched yet" from "fetched and there are none", so a fresh view
  does not flash a misleading empty state.
- `error` MUST be rendered by the view — never write-only. A swallowed failure that returns
  an empty list is precisely the bug class this repo forbids.
- Follow the repo's **Effect-TS** rule: fallible operations express failure in the type
  (`Effect<A, E>`), not `try`/`catch` returning a fake empty. `src/apps/desktop/src/sync/`
  is the reference implementation; `runSyncEffect` / `runSyncEffectOr` / `runSyncVoid` in
  `sync/runtime.ts` are the Vue-`<script setup>` bridge.
- Naming: camelCase `.ts`, one store per file, `defineStore('secrets', () => {...})`.

If the `sync/` Effect seam turns out not to fit a simple CRUD store, say so in your report
and explain what you did instead — do not silently reintroduce `try`/`catch`-and-empty.

---

## STEP 3 — the section component

Create `src/apps/desktop/src/components/workspace/SecretsSection.vue`.

Conventions (all verified in this repo): PascalCase, `*Section.vue` for a settings-tab body,
Tailwind v4 utilities plus CSS custom properties (`var(--semantic-text-muted)`) — **never hex
literals**, `data-testid` on every interactive element, typography classes
(`text-dense`, `text-title-sm`, …), `<Teleport>` for any modal.

Content per row: the name, a "configured" state, and `updated_at`. An edit/rotate action and a
delete action. An empty state with `data-testid="empty-state"`.

**The value input is write-only and has NO reveal toggle.** There is no stored value to
reveal — the server never sends one. A reveal button would be a lie.

### Do not copy the existing masking bug

`src/apps/desktop/src/components/nalar/McpServersSection.vue` renders `maskValue(h.value)` at
line ~138 while putting the **raw value** into a `:title=` tooltip at line ~135. That is a
live secret-leak shape in this repo. Your component must have no path by which a value
becomes visible, hoverable, or copyable after save. Clear the value input on save.

---

## STEP 4 — the route

Create `src/apps/desktop/src/components/views/WorkspaceSettingsView.vue` and register the
route.

- Add `'/app/:workspaceId/settings'` to `src/apps/desktop/src/router/index.ts`.
- **It MUST be registered ABOVE `path: '/app/:workspaceId'` (around line 86).** Vue Router
  matches in registration order and that route is a catch-all that would otherwise swallow
  `/app/ws_1/settings`. The repo documents this exact trap twice already — for
  `/app/chat/:sessionId` and for `/app/:workspaceId/doc/:documentId`. Follow the comment
  style of those two entries.
- Add the matching branch to the `currentView` computed in
  `src/apps/desktop/src/components/AppLayout.vue` (around line 1133), and mount the component
  alongside `<SettingsView v-if="currentView === 'settings'" />`.

### URL sync is mandatory

The repo rule: **every view switch must update the browser URL** so refresh, Back/Forward
and shared links all restore the same view.

- Use the query key **`?section=`** inside the settings shell. **`?tab=` is owned by browser
  tab-mode** (`helpers/tabTarget.ts`, `stores/tabs.ts`) — do not reuse it.
- `src/apps/desktop/src/components/NalarSettings.vue` is the reference implementation of the
  URL-backed tab (its `activeTab` writable computed, its localStorage fallback, its
  `router.replace`). Copy that pattern; do not invent a second one.
- The existing `readTabParam`/`syncTabParam` helpers in `SidebarDiffPanel.vue` are **local to
  that file, not shared** — do not import them.

---

## STEP 5 — tests

Vitest. `cd src/apps/desktop && npx vitest --run <file>`. Specs live in
`src/apps/desktop/src/__tests__/`, named `ComponentName.spec.ts`.
`McpServersSection.spec.ts` and `LlmConfigForm.spec.ts` are the templates — read them.

Create `src/apps/desktop/src/__tests__/SecretsSection.spec.ts`:

1. One row per secret, showing the name and a "configured" state.
2. **`expect(wrapper.html()).not.toContain(<the value>)`** — the direct analogue of the
   existing masking/absence assertions. Seed a prop or mock with a recognisable value and
   assert it never reaches the DOM.
3. The value input is `type="password"` and there is **no** reveal toggle.
4. Empty state renders `data-testid="empty-state"`.
5. Clicking add emits `add`; clicking delete emits `delete` with the name.
6. `WorkspaceSettingsView` mount with `?section=secrets` restores that section, and a tab
   click calls `router.replace` (mock the router; `NalarSettings.spec.ts` already does this —
   it imports `createMemoryHistory`/`createRouter` for exactly this reason).

**TDD: failing test first, watch it fail, then implement.**

---

## GATE

```bash
cd /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930/src/apps/desktop
npx vue-tsc --noEmit
npx vitest --run src/__tests__/SecretsSection.spec.ts
```

Both must pass. Do NOT run `zig build test` — the other agent owns that and concurrent builds
contend on `.zig-cache`.

Note: `npx oxlint` reports many pre-existing findings repo-wide and CI's `lint` still passes;
do not chase lint output. Compare against the base file if you must, but it is not your gate.

Commit when green:

```
feat(secrets): workspace settings UI (write-only values)
```

---

## HARD CONSTRAINTS

- **No `// NEW (plan: ...)` comments.**
- **Never render a stored secret value**, not masked, not hinted, not in a tooltip or a
  `title=` attribute. The server never sends one, and neither should any local state survive
  a save.
- No hex colour literals; use the existing CSS custom properties.
- Do not edit anything in the Zig tree.
- If you conclude a file outside `api/index.ts`, `stores/`, `components/`, `router/index.ts`,
  `AppLayout.vue` must change, STOP and report.

## REPORT BACK

Files changed, exact commit sha, the `vue-tsc` and vitest output, how the URL sync is wired,
how you handled the Effect/try-catch rule in the store, and any deviation with its reason.