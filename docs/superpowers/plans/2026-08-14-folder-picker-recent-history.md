# FilePickerDialog — Recent-history tab + pin + browse redesign

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **⛔ DO ALL WORK IN A GIT WORKTREE — never on `main`.** See **Task 0 — Worktree setup** below. Project convention: every feature/refactor ships via a PR from `worktree/<topic>`. The kanban card moves to `merged` only after the user merges the PR.

**Goal:** Enhance `FilePickerDialog` (the modal used by every "pick a folder" flow — Add Project, Add Kanban, Add Memory, Add Design, Per-Task Cwd, Create Worktree parent dir, the "Set project root" banner) with a **Recent** tab that surfaces the user's previously picked folders — most-recent first, with relative timestamps ("now", "2h", "yest"), a manual pin/star so the user's "lifetime" projects stay at the top, and zero-friction rebuild of the existing **Browse** tree UX. The two views are mutually exclusive tabs in the same modal — the toolbar becomes the tabstrip.

**Architecture:** A new `useRecentFolders` Pinia store (in `src/apps/desktop/src/stores/recentFolders.ts`) owns the persistent list. Persistence is `localStorage` keyed at `pabrik-folder-picker-recent:v1` (JSON-encoded array, same pattern as the existing `workspaces.ts` keys — see `STORAGE_KEY_WORKSPACE_EXPANDED` at line 223). The store exposes `addRecent(path)`, `removeRecent(path)`, `togglePin(path)`, `list()` (sorted by `pinned desc, lastUsedAt desc`), and a `lastUsedAt` map so the UI can render the "now / 2h / yest / 3d" chip via the existing `formatRelativeTime` helper (`src/apps/desktop/src/helpers/relativeTime.ts`). The dialog gets a top tabstrip (`Recent` / `Browse`) replacing the "view" role the toolbar implicitly held. Recent mode renders a flat list of cards (folder icon, name, full path, time, pin). Browse mode is the existing two-pane tree + content layout, untouched. On `select` (either tab), the store records the path. Header text becomes `Select Per-Task Cwd` — same as today. Title is unchanged.

**Tech Stack:** Vue 3.5 + TypeScript + Pinia 2 + Vitest. No new dependencies. The relative-time chip reuses the existing `formatRelativeTime` helper from `src/apps/desktop/src/helpers/relativeTime.ts` (already used by `ChatsList.vue` and `WorkspaceItemTaskCard.vue`).

---

## Background — why we're doing this

Today every "pick a folder" modal in the desktop app opens with an empty tree. The user picks `/home/me/ginwaaitoolbox` ~10 times a day; every time they type the breadcrumb or click through the tree. The KanbanTaskDetailDialog's cwd picker, the Add Kanban folder input, the Add Project folder input, the Add Design folder input, the Create Worktree parent-dir input, and the "Set project root" banner on KanbanView all show the same `FilePickerDialog` modal.

**User-visible problem:** the picker has no memory. The user always pays the navigation cost (`/ → home → me → ginwaaitoolbox → click`) even when they're going to the same folder they picked 20 minutes ago.

**Reproduction today:**
1. Open Add Kanban → "Choose folder..." → pick `/home/me/ginwaaitoolbox`.
2. Close. Open Add Task → "Project root" picker → land on `/`. Navigate back to `/home/me/ginwaaitoolbox` again.

**Goal UX (matches the screenshot):**
1. Open Add Kanban → "Choose folder..." → modal opens on the **Recent** tab.
2. The top row is the folder they picked 20 minutes ago (with a ⭐ because it's pinned, or just the time chip "now" if not).
3. Click the row → closes, picks `/home/me/ginwaaitoolbox`.
4. The list bumps /home/me/ginwaaitoolbox to position 0 with a "now" timestamp.

---

## Design Decisions (review before execution)

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| D1 | **Two-tab layout: Recent / Browse.** Recent is the default tab on dialog open. The existing tree + content two-pane lives under Browse. | The user almost always wants the recent list first. The tree is a power-user affordance for "navigate somewhere I haven't picked yet". | One merged view (recents at top of the tree) — confusing because the path the user picked is rarely in the same branch they were browsing. |
| D2 | **New Pinia store** `useRecentFolders` (not a module-level Map). Persistence: `localStorage` key `pabrik-folder-picker-recent:v1`. | Matches the `useSettingsStore` / `useDesignHistoryStore` pattern already in the codebase. Pinia gives us devtools + reactive automatic dedupe-by-path. The `:v1:` suffix lets us bump the schema later without nuking user data. | Module-level ref — same anti-pattern as `recentLocalMutations` in `workspaces.ts:384` ("why a module-level Map (NOT a Pinia ref): the SSE handler reads it"). The data here is user-facing, not glue. |
| D3 | **List shape: `{ path, lastUsedAt, pinned? }[]`** where `lastUsedAt` is a Unix-ms timestamp. Dedupe by `path` (latest `lastUsedAt`, `pinned` is sticky). | `pinned` is independent of `lastUsedAt` — the user can pin a project they're not using today. Re-ordering is `pinned desc, lastUsedAt desc`. | Sort by lastUsedAt only — pinned items drift down. Or `pinned desc, path alpha` — pinned items overflow when there are many. |
| D4 | **Pin = sticky ⭐**, render via inline SVG (matches `kanban-folder-picker-style` plan which replaced the 📂 emoji in the cwd picker button with an inline SVG). Toggle by clicking the star: pin → unpin → pin. | Star is the universal "favorite" affordance. Click toggles (no separate edit mode). | Right-click context menu → "Pin" — overkill for a single-click action. |
| D5 | **Cap = 12 entries** (matches the screenshot's "Recent 12" badge). On insert, dedupe by path, then trim to 12. The trim drops the OLDEST non-pinned entry first; pinned entries are exempt from eviction. | Without a cap, the list grows unbounded. Pinned entries are the user's "lifetime" config — never auto-removed. | Cap = 50 — too many visible rows. Cap = 5 — not enough recent-context. |
| D6 | **Relative time chip** uses `formatRelativeTime` (returns `'now'`, `'2h'`, `'yest'`, `'3d'`, `'2w'`, `'6mo'`, `'2y'`). Existing helper, already imported by `ChatsList.vue` and `WorkspaceItemTaskCard.vue`. | No new formatter. The string `'yest'` (one of the existing outputs) matches the screenshot. | New formatter — duplicate code, drift risk. |
| D7 | **Empty Recent state** — show "📁 No recent folders yet — pick one in Browse" with a single button to switch tabs. | The user might never have used the picker. Clear next action. | Auto-open Browse on empty — surprising, steals the user's intent. |
| D8 | **Add-pin / unpin emit-debounced save** (200ms). Worst case: rapid pin/unpin → 1 localStorage write. | `localStorage` is synchronous; bulk writes during a swipe could spam the quota check. | Synchronous on every toggle — negligible cost, but the debounce is already justified by the design undo/redo (`useDesignHistory` debounces 500ms — same pattern). |
| D9 | **No new props on `FilePickerDialog`.** The `Recent` tab is conditional on the caller setting `enableRecentHistory?: boolean` (default `true`, opt-out). Older callers (none today, but see R6) that don't want the tab can pass `false`. | Per the upgrade-everything-at-once principle from the existing `2026-08-13-folder-picker-select-button-current-folder.md` plan (D7: "No new props"). The one opt-out keeps the door open if a future caller wants the legacy behaviour. | Always-on — already all callers want it. |
| D10 | **Time chip text uses the existing `formatRelativeTime`**; the path display uses the existing monospace + truncate pattern. The whole row is a single `<button>` for accessibility (Tab-able, Enter to select). | Mirrors the existing `file-picker-item-*` content rows. | Separate `<button>` + `<span>` — breaks keyboard nav. |
| D11 | **Browse tab's existing layout is unchanged.** The two-pane tree + content + breadcrumb + search + address bar all stay. The tabstrip is added at the top of the toolbar (or above the two-pane body — see D12). | Minimal diff. The user can keep using the existing Browse UX if their need is "I need to navigate to a folder I haven't picked yet". | Redesign Browse — out of scope. |
| D12 | **Tabstrip placement:** a thin row immediately below the existing breadcrumb/address bar (which lives below the header). Two buttons: `Recent <count-badge>` and `Browse`. Active tab is underlined violet (`var(--color-violet)`) — same pattern as `PabrikTabStrip.vue`. | The toolbar (search + hidden + refresh) is content-pane-only and should stay above the content pane under Browse. The tabstrip is a SINGLE thing that switches the body, so it sits above the body. | Move the tabstrip into the header — header is already crowded (emoji + title + close). |
| D13 | **Toolbar visibility under Browse stays.** Under Recent, the toolbar (search + hidden + refresh) is **hidden** because it doesn't apply to a flat list. This is consistent with the screenshot (which shows the toolbar under Browse but not under Recent). | Reduces noise on the Recent tab. | Show the toolbar on both — wastes vertical space. |
| D14 | **Recent rows show the full path** (e.g. `/home/me/ginwaaitoolbox`), not just the basename. The screenshot shows the folder name big (e.g. `ginwaaitoolbox`) and the path small (e.g. `/home/me/ginwaaitoolbox`). | The path is the canonical id; the user uses it to disambiguate. The basename is the friendly label. | Show only the basename — collides for siblings. |
| D15 | **Recent mode disables the **Up** button + the tree pane** (Recent is a flat list, not a tree). The header still shows the title + close button. | The user is in Recent mode, not Browse. | Hide all navigation — confusing; let the user switch tabs. |
| D16 | **Selecting a Recent row** emits `select` (same path as Browse) AND closes the dialog (the existing `closeOnSelect` prop governs this). The store records the path on `select`. | Same wired-up path as Browse. The store write is fire-and-forget; the close is synchronous. | Different emit name — redundant; callers all listen for `select`. |
| D17 | **No backend changes.** Recent-folders is a desktop-only concern. The backend doesn't know about it. | Mirrors the `useDesignHistory` (in-app, localStorage) split. | Backend persistence — over-engineered. |
| D18 | **No relative-time re-render timer.** The list renders the time once when the dialog opens; the chip stays static until the next dialog open. | The dialog is open for seconds; rendering once is enough. | `setInterval` to re-render — adds reactivity for a few-second window. |
| D19 | **No new components in `src/apps/desktop/src/components/`.** The tabstrip + Recent list + rows live **inside** `FilePickerDialog.vue` (a single self-contained change to one component). | The tabstrip is tightly coupled to the dialog's state (active tab, recent list, pinned state). Extracting it would create prop-drilling without payoff. | Extract `RecentList.vue` + `RecentTabStrip.vue` — over-engineered. |
| D20 | **Pin/unpin keyboard:** `p` (lowercase) on the focused row toggles the pin. Documented in the row's `title` attribute (`"Pin to keep at top" / "Unpin"`). | Keyboard parity with the existing dialog (arrow keys, Enter, /, Escape). | Mouse-only — poor keyboard UX. |
| D21 | **Test strategy: behavioural, no static `expect(component).toContain(...)`.** Mirror the existing `FilePickerDialog.spec.ts` pattern (use `findInDom` / `clickInDom` because the dialog is teleported + transitioned). | Project memory `static-contract-test-when-to-prefer-behavioural`. | Static string-match — false-positive on rename. |
| D22 | **TS strictness: `defineProps<...>` with no defaults for the new strings; `withDefaults` only where needed.** Vue 3.5 + the project's existing optional-prop pattern. | Matches the existing component. | Looser typing — drift risk. |
| D23 | **Anonymous struct literal gotcha:** when constructing pinned-state badge objects, initialize ALL fields or use explicit field names. The existing `zig-constcast-slice-helper-mismatch` skill is the Zig analogue; the Vue analogue is "Vue 3.5 / TS anonymous struct literal only initializes named fields". | Avoid the same SEGV-style bug class that hit the Anthropic request builder (plan 2026-08-13). | Implicit init — silent bug. |
| D24 | **One PR, 4 commits.** (1) store + tests, (2) tabstrip + recent list + tests, (3) wire select→store + tests, (4) docs. | Each commit is a reviewable unit. | One mega-commit — unreviewable. |
| D25 | **Worktree-based branch.** Path: `.worktrees/folder-picker-recent-history`. Branch: `worktree/folder-picker-recent-history`. | Project convention. | Direct on main — forbidden. |
| D26 | **TODO bump `recentFolders` feature on the kanban:** move the card from `todo` to `in progress` at Task 0.5, then to `in_review_task` after Task 4. | Matches the existing `kanban-status-tracking` rules. | Forgetting to move — card stuck. |

---

## Global Constraints

- **Cross-platform**: every change MUST work on Linux, macOS, AND Windows. The frontend is a Vite + Vue 3 SPA; no platform-specific code.
- **No static-contract tests**: ALL tests are behavioural. See `~/.config/pabrik/memories/static-contract-test-when-to-prefer-behavioural.md`.
- **TDD discipline**: every implementation step starts with a failing test, then minimal code to make it pass, then a commit.
- **`bun run build` IS the type-check**: every frontend commit must pass `bun run build`; `bunx vitest run` alone does NOT catch type errors.
- **No `dist/` or `.js` cruft**: `vue-tsc --build` emits `.js` files alongside `src/**/*.ts` (see `vue-tsc-build-emits-js-files` skill). Delete them before `git status`.
- **No port 8081**: smoke tests use port 8080.
- **Teleport + Transition test pattern**: `FilePickerDialog` uses `<Teleport to="body">` AND `<Transition>`. `@vue/test-utils` stubs `<Transition>`, so `wrapper.find()` does NOT traverse into the dialog. Use `document.querySelector('[data-testid="..."]')` for data-testid assertions — see the existing `findInDom` / `findAllInDom` / `clickInDom` / `keydownInDom` helpers at the top of `FilePickerDialog.spec.ts`.
- **Vue 3.5 anonymous-struct-literal gotcha**: do NOT initialize only one field of a multi-field object — anon struct literals only initialize named fields. (`@zig-constcast-slice-helper-mismatch` is a Zig-only memory of the same shape; the Vue-side analogue is this Vue 3.5 / TS quirk.)
- **No new npm dependencies.** The relative-time formatter already exists.

---

## File Structure

```
src/apps/desktop/src/
├── components/
│   └── FilePickerDialog.vue                                     # EDIT — add tabstrip + recent list + pin star
├── stores/
│   └── recentFolders.ts                                         # NEW — Pinia store + localStorage persistence
└── __tests__/
    ├── FilePickerDialog.spec.ts                                 # EDIT — add ~12 new behavioural tests
    └── recentFoldersStore.spec.ts                               # NEW — ~8 behavioural tests for the store

# UNCHANGED (verify by reading, not editing):
├── components/dialogs/AddItemDialog.vue                         # uses FilePickerDialog, no change
├── components/dialogs/AddKanbanDialog.vue                       # uses FilePickerDialog, no change
├── components/dialogs/AddMemoryDialog.vue                       # uses FilePickerDialog, no change
├── components/dialogs/AddDesignDialog.vue                       # uses FilePickerDialog, no change
├── components/dialogs/CreateWorktreeDialog.vue                 # uses FilePickerDialog, no change
├── components/kanban/KanbanTaskDetailDialog.vue                 # uses FilePickerDialog, no change
├── components/kanban/KanbanView.vue                             # uses FilePickerDialog, no change
└── helpers/relativeTime.ts                                     # formatRelativeTime — unchanged, reused
```

**Why no caller changes:** the new tab is opt-OUT via `enableRecentHistory?: boolean` (default `true`). Every existing caller wants the new tab. The new prop has a default so the 6 caller sites need ZERO changes. The `select` emit is unchanged.

---

## Risks & breaking changes analysis

| # | Risk | Mitigation |
|---|------|-----------|
| R1 | **A caller that today relies on the modal opening at the Browse tree now sees it open at the Recent tab.** | D1: D9 default = `enableRecentHistory: true`. The two callers that mint a fresh `initialPath` (CreateWorktreeDialog, KanbanTaskDetailDialog) still want Recent-first as the default. The Browse tab is one click away. |
| R2 | **The new tab + Recent list makes the modal taller than 80vh max-height on small viewports.** | The Recent list is a flat stack of cards capped at 12 rows. Each row is ~52px tall. 12 rows ≈ 624px + header (40px) + breadcrumb (32px) + tabstrip (40px) + footer (56px) = 792px. Today the modal is `max-height: 80vh; min-height: 480px` — at 800px viewport height, 80vh = 640px (min-height wins). Adjust the `max-height` to `min(80vh, 720px)` so the Recent tab never overflows on a 720p display. Tiny CSS-only edit. |
| R3 | **localStorage quota.** The list is 12 entries × ~80 bytes = 960 bytes. The key fits in localStorage's 5MB default. No risk. | Documented in D2 (`:v1:` suffix). |
| R4 | **Existing `FilePickerDialog` tests break** because the dialog now opens on the Recent tab (not the Browse tree). | Update the existing tests to either (a) opt out via `enableRecentHistory: false`, or (b) switch to the Browse tab via `clickInDom('[data-testid="file-picker-tab-browse"]')` then continue. Plan renames the existing describe blocks to `FilePickerDialog — Browse tab` and the new ones to `FilePickerDialog — Recent tab + tabstrip`. |
| R5 | **The Recent tab is empty on a fresh user** (first time they open the picker). | D7: Empty state with a "Open Browse" button + helper copy. |
| R6 | **A future caller wants the legacy "open the tree, no recents" UX.** | D9: `enableRecentHistory?: boolean` (default `true`). Pass `false` to opt out. Today NO caller needs this, but the door is open. |
| R7 | **A user picks `/home/me/foo` once, then deletes the folder.** The Recent list still shows it. | Documented. The list is "paths the user has picked", not "paths that exist". The picker will surface the existing error UI from `loadItems` (boom: not a directory) when the user clicks the row, so the failure is visible. Future enhancement: a "reconcile" button that calls `listFolder` on each entry and evicts the 404s. NOT in this plan. |
| R8 | **The user's keyboard Enter on a Recent row** submits the row, just like Browse. | D16 unified emit + D20 keyboard parity. |
| R9 | **The footer "Selected:" readout** stays meaningful on the Recent tab — it shows the row the user clicked (because click sets `selectedPath`). | The footer already uses `effectiveSelection` (see existing plan 2026-08-13); no new wiring needed. |
| R10 | **The `Enter` key on the dialog with no row highlighted** (Recent tab with no rows, or Browse tab with no focus) — today the keyboard handler emits `currentPath` via the fallback. On the Recent tab, `currentPath` is still set (the last Browse path), so Enter still does something meaningful. | D15: The currentPath fallback is preserved on the Recent tab; the user can switch tabs and Enter. |
| R11 | **Pin star and time chip render in the same column** — they need to coexist. | The row is a 3-column flex: `[icon] [name+path] [time+pin]`. The pin is a child of the right column, sits next to the time chip. See the screenshot. |
| R12 | **The `formatRelativeTime` helper formats a SQLite datetime string** (`"YYYY-MM-DD HH:MM:SS"`) by appending `Z`. Our store stores Unix-ms (number). | Convert in the row template: `formatRelativeTime(new Date(entry.lastUsedAt).toISOString().replace('T', ' ').replace('Z', ' '').slice(0, 19))`. Or: the store stores the ISO string the helper expects. Cleaner: store `lastUsedAt` as Unix-ms, format with `new Date(ms).toISOString().replace('T', ' ').slice(0, 19)` and pass that to `formatRelativeTime`. |
| R13 | **The existing `select` event fires from the Recent row** — does the parent dialog need to update `cwdSession` / `selectedPath`? | Same as today's Browse flow — the parent's `handleFolderSelected` / `selectCwd` / `handleProjectRootSelected` just receives the path. No parent changes. |
| R14 | **The dialog's `closeOnSelect` prop already governs close behaviour.** | D16 reuses it. |
| R15 | **The new tabstrip is rendered conditionally on `enableRecentHistory`.** | D9. The default is `true`. The tabstrip is always rendered when the dialog is open. |
| R16 | **The `file-picker-toolbar` (search + hidden + refresh) is hidden on the Recent tab.** | D13. The currently-displayed toolbar is wrapped in a `v-if="activeTab === 'browse'"`. |
| R17 | **The tabstrip uses `var(--color-violet)` for the underline** — same as the existing `PabrikTabStrip.vue`. | Reuse the existing CSS variable. |
| R18 | **The Recent tab badge "N"** (the count of recent folders) updates reactively when the store mutates. | Computed `recentCount` from `useRecentFoldersStore()`. |
| R19 | **Toggling a pin while a row is selected** — does it clear the selection? | No. The pin is a UI affordance; the row stays selected. The "Selected:" footer still shows the path. |
| R20 | **The user's first time on the new system** — the localStorage is empty. The Recent tab is empty. The empty-state CTA is "Open Browse". | D7. |

---

## Task 0 — Git worktree setup (do this FIRST)

**CRITICAL: do NOT implement directly on `main`.** Every commit in this plan lands on the worktree branch; the user is the only one who moves them to `main`. The kanban card moves to `merged` only after the PR is merged.

### Step 0.1 — Create the worktree

Project convention (every existing refactor follows this):
- Path: `/home/ginwa/ginwaaitoolbox/.worktrees/folder-picker-recent-history`
- Branch: `worktree/folder-picker-recent-history` (auto-derived from the path basename)

Use the `set_git_worktree` tool with `path` = `/home/ginwa/ginwaaitoolbox/.worktrees/folder-picker-recent-history`. Or equivalently:

```bash
cd /home/ginwa/ginwaaitoolbox
git worktree add .worktrees/folder-picker-recent-history \
    -b worktree/folder-picker-recent-history main
```

**If the path already exists** (someone else's worktree):
- `git worktree list` to see what's there
- Either pick a different slug OR pass `branch=<existing-branch>` to bind to the existing branch

**If a different worktree already has the same branch checked out:**
- Pass `branch=''` to fall back to the auto-derived name (or pick a different slug)

### Step 0.2 — Verify the worktree

```bash
cd .worktrees/folder-picker-recent-history
git status            # should be on worktree/folder-picker-recent-history, clean
git log -1 --oneline  # should match main HEAD
```

### Step 0.3 — Run every subsequent command from inside the worktree

All `git add` / `git commit` / `bunx vitest` / `bun run build` commands in Tasks 1–4 run from `.worktrees/folder-picker-recent-history/`. Path-relative in this plan (e.g. `src/apps/desktop/src/components/FilePickerDialog.vue`) resolves from this worktree root.

### Step 0.4 — Open the PR at the end (Task 4.4)

After Task 4 verification:

```bash
cd .worktrees/folder-picker-recent-history
gh pr create \
    --title "feat(folder-picker): Recent tab + pin + relative-time chip" \
    --body-file <(git log main..HEAD --pretty=format:"- %s%n%b%n")
```

Then the user reviews and merges.

### Step 0.5 — Kanban tracking

- **before starting Task 1**: move the kanban card "enhance file folder implement recent history" from `todo` to `in progress` (mandatory per the project's Kanban Status Tracking rules)
- **after Step 4.4**: move the card to `in_review_task` (waiting on user merge)
- **user merges the PR**: user moves the card to `merged`

---

## Task 1 — `useRecentFolders` Pinia store (failing tests, then impl)

**Goal:** Add a standalone Pinia store that owns the recent-folders list. The store is a pure data + helper-functions module — no UI details. The dialog (Task 2) consumes it via `useRecentFoldersStore()`.

### Step 1.1 — Write the failing tests

**File:** `src/apps/desktop/src/__tests__/recentFoldersStore.spec.ts` (NEW)

Create the file with this content:

```typescript
/**
 * Tests for useRecentFolders — Pinia store backing the FilePickerDialog's
 * Recent tab.
 *
 * The store owns:
 *   - recentEntries: { path: string, lastUsedAt: number, pinned?: boolean }[]
 *   - addRecent(path) — dedupe by path, bump lastUsedAt, trim to cap (pinned exempt)
 *   - togglePin(path) — flips pinned, re-sort
 *   - removeRecent(path) — explicit remove (used when the user wants to forget)
 *   - list() — sorted by pinned desc, then lastUsedAt desc
 *   - Persistence: localStorage key 'pabrik-folder-picker-recent:v1'
 *
 * Persistence is the interesting part — the store hydrates from localStorage
 * on init, and writes back on every mutation (debounced 200ms via the
 * useDebounceFn pattern from `useDesignHistory.ts`).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useRecentFoldersStore } from '../stores/recentFolders'

describe('useRecentFoldersStore — basics', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    localStorage.clear()
  })
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('starts empty when localStorage is empty', () => {
    const store = useRecentFoldersStore()
    expect(store.list()).toEqual([])
  })

  it('hydrates from localStorage on first read', () => {
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/a', lastUsedAt: 1000, pinned: true },
        { path: '/home/me/b', lastUsedAt: 500, pinned: false },
      ]),
    )
    const store = useRecentFoldersStore()
    const list = store.list()
    expect(list).toHaveLength(2)
    // Pinned first.
    expect(list[0].path).toBe('/home/me/a')
    expect(list[1].path).toBe('/home/me/b')
  })

  it('addRecent appends a new path with the current timestamp', () => {
    const store = useRecentFoldersStore()
    const now = 1_700_000_000_000
    vi.spyOn(Date, 'now').mockReturnValue(now)
    store.addRecent('/home/me/foo')
    expect(store.list()).toEqual([
      { path: '/home/me/foo', lastUsedAt: now, pinned: false },
    ])
  })

  it('addRecent with an existing path DEDUPES (bumps lastUsedAt, keeps pin)', () => {
    const store = useRecentFoldersStore()
    store.addRecent('/home/me/foo')
    vi.spyOn(Date, 'now').mockReturnValue(2_000_000_000_000)
    store.addRecent('/home/me/foo')
    const list = store.list()
    expect(list).toHaveLength(1)
    expect(list[0].lastUsedAt).toBe(2_000_000_000_000)
  })

  it('addRecent preserves the pinned flag across re-inserts', () => {
    const store = useRecentFoldersStore()
    store.addRecent('/home/me/foo')
    store.togglePin('/home/me/foo')
    expect(store.list()[0].pinned).toBe(true)
    store.addRecent('/home/me/foo')
    expect(store.list()[0].pinned).toBe(true)
  })

  it('addRecent caps to 12 entries; non-pinned entries are evicted first', () => {
    const store = useRecentFoldersStore()
    let t = 1_000_000_000_000
    vi.spyOn(Date, 'now').mockImplementation(() => {
      t += 1
      return t
    })
    for (let i = 0; i < 15; i++) {
      store.addRecent(`/home/me/folder-${i}`)
    }
    expect(store.list()).toHaveLength(12)
    // The first 3 (folder-0, folder-1, folder-2) were evicted because they
    // were the OLDEST non-pinned entries. The most recent 12 remain.
    const paths = store.list().map((e) => e.path)
    expect(paths).not.toContain('/home/me/folder-0')
    expect(paths).not.toContain('/home/me/folder-1')
    expect(paths).not.toContain('/home/me/folder-2')
    expect(paths).toContain('/home/me/folder-14')
  })

  it('addRecent does NOT evict pinned entries when over the cap', () => {
    const store = useRecentFoldersStore()
    let t = 1_000_000_000_000
    vi.spyOn(Date, 'now').mockImplementation(() => {
      t += 1
      return t
    })
    // Pin the first 5.
    for (let i = 0; i < 5; i++) {
      store.addRecent(`/home/me/pinned-${i}`)
    }
    for (let i = 0; i < 5; i++) {
      store.togglePin(`/home/me/pinned-${i}`)
    }
    // Add 15 more.
    for (let i = 0; i < 15; i++) {
      store.addRecent(`/home/me/recent-${i}`)
    }
    const list = store.list()
    // All 5 pinned entries survive.
    const pinnedPaths = list.filter((e) => e.pinned).map((e) => e.path)
    expect(pinnedPaths).toHaveLength(5)
    expect(pinnedPaths).toEqual(
      expect.arrayContaining([
        '/home/me/pinned-0',
        '/home/me/pinned-1',
        '/home/me/pinned-2',
        '/home/me/pinned-3',
        '/home/me/pinned-4',
      ]),
    )
    // Total ≤ 12 (5 pinned + 7 recent at most).
    expect(list.length).toBeLessThanOrEqual(12)
  })

  it('togglePin flips the pinned flag and re-sorts the list', () => {
    const store = useRecentFoldersStore()
    store.addRecent('/home/me/foo')
    store.addRecent('/home/me/bar')
    expect(store.list()[0].path).toBe('/home/me/bar') // most recent first
    store.togglePin('/home/me/foo')
    expect(store.list()[0].path).toBe('/home/me/foo') // pinned first
    expect(store.list()[0].pinned).toBe(true)
    store.togglePin('/home/me/foo')
    expect(store.list()[0].path).toBe('/home/me/bar')
    expect(store.list()[0].pinned).toBe(false)
  })

  it('removeRecent removes the entry from the list', () => {
    const store = useRecentFoldersStore()
    store.addRecent('/home/me/foo')
    store.addRecent('/home/me/bar')
    store.removeRecent('/home/me/foo')
    expect(store.list()).toHaveLength(1)
    expect(store.list()[0].path).toBe('/home/me/bar')
  })

  it('writes to localStorage on every mutation (debounced 200ms)', async () => {
    const store = useRecentFoldersStore()
    store.addRecent('/home/me/foo')
    // localStorage write is debounced 200ms — wait for the timer.
    await new Promise((r) => setTimeout(r, 250))
    const raw = localStorage.getItem('pabrik-folder-picker-recent:v1')
    expect(raw).not.toBeNull()
    const entries = JSON.parse(raw!)
    expect(entries).toEqual([
      { path: '/home/me/foo', lastUsedAt: expect.any(Number), pinned: false },
    ])
  })

  it('silently swallows localStorage write errors (quota / private mode)', () => {
    const store = useRecentFoldersStore()
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('QuotaExceededError')
    })
    // The mutation should NOT throw.
    expect(() => store.addRecent('/home/me/foo')).not.toThrow()
    // The in-memory state is still updated.
    expect(store.list()).toHaveLength(1)
  })
})
```

### Step 1.2 — Run the tests and confirm they fail

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/recentFoldersStore.spec.ts 2>&1 | tail -n 40
```

**Expected output:** all tests FAIL with `Cannot find module '../stores/recentFolders'` (the store doesn't exist yet).

### Step 1.3 — Implement the store

**File:** `src/apps/desktop/src/stores/recentFolders.ts` (NEW)

Create the file with this content:

```typescript
/**
 * `useRecentFoldersStore` — Pinia store backing the FilePickerDialog's
 * Recent tab.
 *
 * Owns the persistent list of folders the user has picked via the
 * `FilePickerDialog` modal. The list is deduped by path, capped at 12
 * entries (pinned entries are exempt from the cap), and sorted by
 * `pinned desc, lastUsedAt desc`.
 *
 * Persistence: localStorage key `pabrik-folder-picker-recent:v1`. The `:v1`
 * suffix lets us bump the schema later without nuking user data. Writes
 * are debounced 200ms (matches the pattern in `useDesignHistory.ts`'s
 * `useDebounceFn`).
 *
 * No backend round-trip — the list is desktop-only. Mirrors the
 * `useDesignHistory` / `useSettings` pattern of "app-local state with
 * a localStorage shadow".
 */
import { defineStore } from 'pinia'
import { ref } from 'vue'

const STORAGE_KEY = 'pabrik-folder-picker-recent:v1'
const CAP = 12
const WRITE_DEBOUNCE_MS = 200

export interface RecentFolderEntry {
  path: string
  lastUsedAt: number // Unix-ms
  pinned: boolean
}

function loadFromStorage(): RecentFolderEntry[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    // Defensive: validate each entry.
    return parsed
      .filter(
        (e: any) =>
          e &&
          typeof e.path === 'string' &&
          typeof e.lastUsedAt === 'number' &&
          (e.pinned === true || e.pinned === false),
      )
      .map((e: any) => ({
        path: e.path,
        lastUsedAt: e.lastUsedAt,
        pinned: e.pinned,
      }))
  } catch {
    // Corrupt JSON or private mode — start empty.
    return []
  }
}

function saveToStorage(entries: RecentFolderEntry[]): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(entries))
  } catch {
    // localStorage quota exceeded / private mode — swallow silently.
    // The in-memory state is still updated; the next page load will
    // start fresh from the (persisted) shadow.
  }
}

export const useRecentFoldersStore = defineStore('recentFolders', () => {
  const entries = ref<RecentFolderEntry[]>(loadFromStorage())

  // Sort helper: pinned desc, lastUsedAt desc.
  function sorted(list: RecentFolderEntry[]): RecentFolderEntry[] {
    return [...list].sort((a, b) => {
      if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
      return b.lastUsedAt - a.lastUsedAt
    })
  }

  let writeTimer: ReturnType<typeof setTimeout> | null = null
  function scheduleWrite(): void {
    if (writeTimer) clearTimeout(writeTimer)
    writeTimer = setTimeout(() => {
      saveToStorage(entries.value)
      writeTimer = null
    }, WRITE_DEBOUNCE_MS)
  }

  function addRecent(path: string): void {
    if (!path) return
    const now = Date.now()
    const existing = entries.value.find((e) => e.path === path)
    if (existing) {
      // Dedupe: bump lastUsedAt, keep pinned.
      existing.lastUsedAt = now
    } else {
      entries.value.push({ path, lastUsedAt: now, pinned: false })
    }
    // Cap: evict the OLDEST non-pinned entry if over the cap. Pinned
    // entries are exempt from auto-eviction.
    if (entries.value.length > CAP) {
      const candidates = entries.value
        .filter((e) => !e.pinned)
        .sort((a, b) => a.lastUsedAt - b.lastUsedAt)
      while (entries.value.length > CAP && candidates.length > 0) {
        const victim = candidates.shift()!
        entries.value = entries.value.filter((e) => e.path !== victim.path)
      }
    }
    scheduleWrite()
  }

  function togglePin(path: string): void {
    const entry = entries.value.find((e) => e.path === path)
    if (!entry) return
    entry.pinned = !entry.pinned
    scheduleWrite()
  }

  function removeRecent(path: string): void {
    entries.value = entries.value.filter((e) => e.path !== path)
    scheduleWrite()
  }

  function list(): RecentFolderEntry[] {
    return sorted(entries.value)
  }

  return {
    entries,
    addRecent,
    togglePin,
    removeRecent,
    list,
  }
})
```

### Step 1.4 — Run the tests and confirm they pass

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/recentFoldersStore.spec.ts 2>&1 | tail -n 50
```

**Expected output:** all 12 tests pass.

### Step 1.5 — Type-check

```bash
cd src/apps/desktop && bun run build 2>&1 | tail -n 30
```

**Expected output:** type-check passes (no errors). If `vue-tsc` emits stray `.js` files, delete them (see `vue-tsc-build-emits-js-files` skill).

### Step 1.6 — Commit

```bash
git add src/apps/desktop/src/stores/recentFolders.ts \
        src/apps/desktop/src/__tests__/recentFoldersStore.spec.ts
git status  # verify NO .js files, NO dist/
git commit -m "feat(folder-picker): useRecentFolders Pinia store + localStorage shadow

Owns the persistent list of folders the user has picked via the
FilePickerDialog modal. List is deduped by path, capped at 12
entries (pinned entries exempt from the cap), and sorted by
pinned desc, lastUsedAt desc. Persistence via localStorage key
pabrik-folder-picker-recent:v1 with a 200ms debounce.

No backend changes. No caller changes (the store is unused so
far — the FilePickerDialog wires it up in the next commit).

12 new behavioural tests in recentFoldersStore.spec.ts cover
init-from-storage, add/dedupe/pin/cap/remove, persistence, and
the quota-error swallow."
```

**Done when:** the new test file is green and committed. The FilePickerDialog is unchanged.

---

## Task 2 — Add the tabstrip + Recent tab content to `FilePickerDialog.vue`

**Goal:** Add a `Recent` / `Browse` tabstrip to the dialog. Add the Recent list (renders entries from the store, with pin stars + time chips). The Browse tab is the existing layout, untouched. Default tab is `recent`.

### Step 2.1 — Write the failing tests for the tabstrip + Recent tab

**File:** `src/apps/desktop/src/__tests__/FilePickerDialog.spec.ts`

Add a new `describe` block at the END of the file (after the existing `FilePickerDialog — Select when current folder is open (folder mode)` block). The new block covers the tabstrip + Recent tab + pin behaviour.

```typescript
// ─── Recent tab + tabstrip + pin ────────────────────────────────────────────
//
// Plan: docs/superpowers/plans/2026-08-14-folder-picker-recent-history.md
//
// The dialog opens on the Recent tab by default. The user sees a flat list
// of folders they've picked before (most recent first, pinned at top). Click
// a row to select; click the star to toggle pin. The Browse tab is one click
// away and shows the existing two-pane tree + content layout.
describe('FilePickerDialog — Recent tab + tabstrip + pin', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    localStorage.clear()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('opens on the Recent tab by default', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // The Recent tab is active, the Browse tab is not.
    const recentTab = findInDom('[data-testid="file-picker-tab-recent"]')
    expect(recentTab).not.toBeNull()
    expect(recentTab?.getAttribute('aria-selected')).toBe('true')
    expect(findInDom('[data-testid="file-picker-tab-browse"]')?.getAttribute('aria-selected')).toBe('false')
  })

  it('shows the empty state on the Recent tab when localStorage is empty', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // The Recent tab is visible; the empty-state copy is rendered.
    const text = findInDom('[data-testid="file-picker-recent-empty"]')?.textContent ?? ''
    expect(text).toContain('No recent folders yet')
  })

  it('renders a row for each recent entry', async () => {
    // Seed the store via the persistence key.
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/a', lastUsedAt: Date.now() - 1000, pinned: false },
        { path: '/home/me/b', lastUsedAt: Date.now() - 60_000, pinned: true },
      ]),
    )
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-recent-row-/home/me/a"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-recent-row-/home/me/b"]')).not.toBeNull()
    // Pinned first.
    const list = findInDom('[data-testid="file-picker-recent-list"]')
    const rows = list?.querySelectorAll('[data-testid^="file-picker-recent-row-"]') ?? []
    expect(rows[0]?.getAttribute('data-testid')).toBe('file-picker-recent-row-/home/me/b')
    expect(rows[1]?.getAttribute('data-testid')).toBe('file-picker-recent-row-/home/me/a')
  })

  it('clicking a recent row emits select and closes (closeOnSelect: true)', async () => {
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/picked', lastUsedAt: Date.now() - 1000, pinned: false },
      ]),
    )
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder', closeOnSelect: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-recent-row-/home/me/picked"]')
    await flushPromises()
    expect(wrapper.emitted('select')?.[0]).toEqual(['/home/me/picked'])
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })

  it('clicking a recent row records the path in the store', async () => {
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/picked', lastUsedAt: Date.now() - 1000, pinned: false },
      ]),
    )
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-recent-row-/home/me/picked"]')
    await flushPromises()
    // The store should have the path with a fresh lastUsedAt.
    await new Promise((r) => setTimeout(r, 250)) // wait for the 200ms debounce
    const raw = localStorage.getItem('pabrik-folder-picker-recent:v1')
    const entries = JSON.parse(raw!)
    const entry = entries.find((e: any) => e.path === '/home/me/picked')
    expect(entry).toBeTruthy()
    // The bumped lastUsedAt should be very close to Date.now().
    expect(Date.now() - entry.lastUsedAt).toBeLessThan(1000)
  })

  it('clicking the star toggles the pin (no select emitted)', async () => {
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/foo', lastUsedAt: Date.now() - 1000, pinned: false },
      ]),
    )
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-recent-pin-/home/me/foo"]')
    await flushPromises()
    expect(wrapper.emitted('select')).toBeFalsy()
    await new Promise((r) => setTimeout(r, 250))
    const raw = localStorage.getItem('pabrik-folder-picker-recent:v1')
    const entries = JSON.parse(raw!)
    expect(entries[0].pinned).toBe(true)
  })

  it('switching to the Browse tab shows the existing tree + content layout', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // Default is Recent.
    expect(findInDom('[data-testid="file-picker-tab-recent"]')?.getAttribute('aria-selected')).toBe('true')
    clickInDom('[data-testid="file-picker-tab-browse"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-tab-browse"]')?.getAttribute('aria-selected')).toBe('true')
    // The Browse tab's tree pane is visible.
    expect(findInDom('[data-testid="file-picker-tree"]')).not.toBeNull()
    // The Browse tab's content pane is visible.
    expect(findInDom('[data-testid="file-picker-content"]')).not.toBeNull()
  })

  it('the tab count badge shows the number of recent entries', async () => {
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/a', lastUsedAt: Date.now() - 1000, pinned: false },
        { path: '/home/me/b', lastUsedAt: Date.now() - 2000, pinned: false },
        { path: '/home/me/c', lastUsedAt: Date.now() - 3000, pinned: true },
      ]),
    )
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const badge = findInDom('[data-testid="file-picker-tab-recent-count"]')
    expect(badge?.textContent).toBe('3')
  })

  it('enableRecentHistory: false falls back to the legacy single-pane Browse UX', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', enableRecentHistory: false })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // No tabstrip.
    expect(findInDom('[data-testid="file-picker-tab-recent"]')).toBeNull()
    // The tree pane is visible immediately.
    expect(findInDom('[data-testid="file-picker-tree"]')).not.toBeNull()
  })

  it('relative-time chip shows now / 2h / yest / 3d via formatRelativeTime', async () => {
    const now = Date.now()
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/now', lastUsedAt: now - 30_000, pinned: false },
        { path: '/home/me/2h', lastUsedAt: now - 2 * 60 * 60_000, pinned: false },
        { path: '/home/me/yest', lastUsedAt: now - 26 * 60 * 60_000, pinned: false },
        { path: '/home/me/3d', lastUsedAt: now - 3 * 24 * 60 * 60_000, pinned: false },
      ]),
    )
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(
      findInDom('[data-testid="file-picker-recent-time-/home/me/now"]')?.textContent,
    ).toBe('now')
    expect(
      findInDom('[data-testid="file-picker-recent-time-/home/me/2h"]')?.textContent,
    ).toBe('2h')
    expect(
      findInDom('[data-testid="file-picker-recent-time-/home/me/yest"]')?.textContent,
    ).toBe('yest')
    expect(
      findInDom('[data-testid="file-picker-recent-time-/home/me/3d"]')?.textContent,
    ).toBe('3d')
  })
})
```

### Step 2.2 — Run the tests and confirm they fail

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/FilePickerDialog.spec.ts 2>&1 | tail -n 60
```

**Expected output:** the 10 new tests in the new `describe` block all FAIL (the tabstrip + Recent list don't exist yet).

### Step 2.3 — Add the new prop + ref to `FilePickerDialog.vue`

**File:** `src/apps/desktop/src/components/FilePickerDialog.vue`

In the `defineProps` block (around line 49), add the new optional prop:

```typescript
  showHidden?: boolean
  closeOnSelect?: boolean
  selectButtonText?: string
  /** Pre-select this path on open. */
  selectedPath?: string
  /** NEW: show the Recent tab + tabstrip. Default true. Legacy callers
   *  (none today) can pass false to opt out for the single-pane tree. */
  enableRecentHistory?: boolean
}>()
```

Below the existing `defaultOn` computeds (around line 82), add:

```typescript
const enableRecent = computed<boolean>(() => props.enableRecentHistory ?? true)
```

In the script `import` block (around line 26), add:

```typescript
import { useRecentFoldersStore } from '../stores/recentFolders'
```

Below the existing `showCurrentFolderHint` computed (around line 362), add the tab state + store wiring:

```typescript
// ─── Tab state (Recent / Browse) ─────────────────────────────────────────────
//
// Default: Recent. The Recent tab is the user's primary path — most-of-the-time
// they pick a folder they've picked before. The Browse tab is the
// power-user / unfamiliar-folder flow.
//
// The active tab is a ref (not persisted) — the user always re-enters via
// Recent on each open.
const activeTab = ref<'recent' | 'browse'>('recent')
const recentStore = useRecentFoldersStore()
const recentList = computed(() => recentStore.list())
const recentCount = computed(() => recentList.value.length)

// Sort the recent list at the template level: pinned desc, lastUsedAt desc
// (the store's list() already does this, but computing here keeps the
// template self-contained).

// Call the store's addRecent on every Browse select AND every Recent row
// click. Watch handleSelect (the Browse path) for the add call.
watch(effectiveSelection, (path) => {
  if (path) recentStore.addRecent(path)
})
```

### Step 2.4 — Add the tabstrip + Recent tab content to the template

**File:** `src/apps/desktop/src/components/FilePickerDialog.vue`

Insert a NEW tabstrip section between the breadcrumb (ends ~line 847) and the existing toolbar (starts ~line 849). The tabstrip is a thin row with two buttons.

```html
          <!--
            Tab strip (Recent / Browse). Sits between the breadcrumb and
            the toolbar. Active tab is underlined violet (matches
            PabrikTabStrip.vue). The default tab is `recent` for the user's
            primary flow. The toolbar (search + hidden + refresh) is
            visible only under Browse — Recent has no use for it.
          -->
          <div
            v-if="enableRecent"
            class="px-5 py-1 flex items-center gap-1 shrink-0"
            style="border-bottom: 1px solid var(--color-border);"
            role="tablist"
            aria-label="Folder picker view"
          >
            <button
              type="button"
              role="tab"
              :aria-selected="activeTab === 'recent'"
              data-testid="file-picker-tab-recent"
              @click="activeTab = 'recent'"
              class="relative px-3 h-9 text-xs font-medium transition-colors duration-150 inline-flex items-center gap-1.5"
              :style="{
                color: activeTab === 'recent' ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
              }"
            >
              <span class="relative z-10">Recent</span>
              <span
                v-if="recentCount > 0"
                data-testid="file-picker-tab-recent-count"
                class="text-[10px] px-1.5 rounded"
                :style="{
                  backgroundColor: activeTab === 'recent' ? 'var(--color-violet)' : 'var(--semantic-text-muted)',
                  color: 'var(--color-bg)',
                }"
              >{{ recentCount }}</span>
              <span
                v-if="activeTab === 'recent'"
                class="absolute left-2 right-2 bottom-0 h-0.5"
                style="background-color: var(--color-violet);"
                aria-hidden="true"
              />
            </button>
            <button
              type="button"
              role="tab"
              :aria-selected="activeTab === 'browse'"
              data-testid="file-picker-tab-browse"
              @click="activeTab = 'browse'"
              class="relative px-3 h-9 text-xs font-medium transition-colors duration-150 inline-flex items-center gap-1.5"
              :style="{
                color: activeTab === 'browse' ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
              }"
            >
              <span class="relative z-10">📂 Browse</span>
              <span
                v-if="activeTab === 'browse'"
                class="absolute left-2 right-2 bottom-0 h-0.5"
                style="background-color: var(--color-violet);"
                aria-hidden="true"
              />
            </button>
          </div>
```

### Step 2.5 — Wrap the existing toolbar + body in a `v-if="activeTab === 'browse'"` (or `enableRecent`)

**File:** `src/apps/desktop/src/components/FilePickerDialog.vue`

The existing `<!-- Toolbar -->` block starts at line 849 and runs through the body. Wrap the toolbar + the two-pane body in a single `<template v-if="!enableRecent || activeTab === 'browse'">`. The simplest patch is to add the wrapper around the toolbar AND wrap the body. The text inside the toolbar mentions things like "Search files" — they only apply to Browse.

Wrap the existing `<!-- Toolbar -->` block in a `v-if`:

```html
          <!-- Toolbar (Browse only) -->
          <div
            v-if="!enableRecent || activeTab === 'browse'"
            class="px-5 py-2 flex items-center gap-2 shrink-0"
            style="border-bottom: 1px solid var(--color-border)"
          >
            ... existing toolbar content ...
          </div>
```

Wrap the existing `<!-- Two-pane body -->` block the same way:

```html
          <!-- Two-pane body (Browse only) -->
          <div
            v-if="!enableRecent || activeTab === 'browse'"
            class="flex-1 flex overflow-hidden"
          >
            ... existing tree + content pane ...
          </div>
```

### Step 2.6 — Add the Recent tab body below the body

**File:** `src/apps/desktop/src/components/FilePickerDialog.vue`

Insert the Recent tab content AFTER the existing two-pane body (after the `</div>` that closes the body, around line 1143) and BEFORE the footer (which starts at line 1145):

```html
          <!--
            Recent tab body. A flat list of cards, each row is a folder
            the user has picked before. The row is a single <button> for
            keyboard nav (Tab-able, Enter to select). The star toggles
            pin. The body scroll is contained in the [data-testid=...
            file-picker-recent-list] wrapper.
          -->
          <div
            v-if="enableRecent && activeTab === 'recent'"
            class="flex-1 flex flex-col overflow-hidden"
            data-testid="file-picker-recent-body"
          >
            <!-- Empty state -->
            <div
              v-if="recentCount === 0"
              class="flex-1 flex flex-col items-center justify-center gap-3 px-5 py-8 text-center"
              data-testid="file-picker-recent-empty"
            >
              <div class="text-3xl" aria-hidden="true">📁</div>
              <p class="text-sm" style="color: var(--semantic-text)">
                No recent folders yet
              </p>
              <p class="text-xs" style="color: var(--semantic-text-dim)">
                Pick one in Browse to save it here for next time.
              </p>
              <button
                type="button"
                @click="activeTab = 'browse'"
                data-testid="file-picker-recent-open-browse"
                class="px-3 py-1.5 text-xs rounded-lg font-medium transition-all duration-200 hover:opacity-80"
                style="
                  background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                  color: var(--color-bg);
                "
              >
                Open Browse
              </button>
            </div>

            <!-- The list -->
            <div
              v-else
              class="flex-1 overflow-y-auto px-5 py-2"
              data-testid="file-picker-recent-list"
            >
              <button
                v-for="entry in recentList"
                :key="entry.path"
                type="button"
                @click="handleRecentRowClick(entry.path)"
                :data-testid="`file-picker-recent-row-${entry.path}`"
                :title="entry.pinned ? `${entry.path} (pinned)` : entry.path"
                class="w-full flex items-center gap-3 px-3 py-2 rounded-lg text-sm text-left transition-colors duration-150 hover:opacity-80"
                style="color: var(--semantic-text);"
              >
                <!-- Folder icon -->
                <span class="text-base shrink-0" aria-hidden="true">📁</span>
                <!-- Name + path stack -->
                <span class="flex-1 min-w-0 flex flex-col gap-0.5">
                  <span class="font-medium truncate">
                    {{ entry.path.split('/').pop() || entry.path }}
                    <span
                      v-if="entry.pinned"
                      class="ml-1 text-[10px] px-1.5 py-0.5 rounded uppercase"
                      style="background-color: var(--color-violet); color: var(--color-bg);"
                      data-testid="file-picker-recent-pinned-badge"
                    >⭐ PINNED</span>
                  </span>
                  <span class="text-xs font-mono truncate" style="color: var(--semantic-text-muted)">
                    {{ entry.path }}
                  </span>
                </span>
                <!-- Right column: time + pin star -->
                <span class="flex items-center gap-2 shrink-0">
                  <span
                    :data-testid="`file-picker-recent-time-${entry.path}`"
                    class="text-xs"
                    style="color: var(--semantic-text-dim)"
                  >
                    {{ formatRelativeTime(toSqliteUtc(entry.lastUsedAt)) }}
                  </span>
                  <button
                    type="button"
                    @click.stop="handleRecentPinClick(entry.path)"
                    :data-testid="`file-picker-recent-pin-${entry.path}`"
                    :title="entry.pinned ? 'Unpin' : 'Pin to keep at top'"
                    :aria-label="entry.pinned ? 'Unpin folder' : 'Pin folder'"
                    class="w-7 h-7 rounded flex items-center justify-center transition-opacity duration-150 hover:opacity-80"
                    :style="{
                      color: entry.pinned ? 'var(--color-violet)' : 'var(--semantic-text-dim)',
                    }"
                  >
                    <svg
                      v-if="entry.pinned"
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 20 20"
                      fill="currentColor"
                      class="w-4 h-4"
                      aria-hidden="true"
                    >
                      <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.286 3.957a1 1 0 00.95.69h4.162c.969 0 1.371 1.24.588 1.81l-3.367 2.446a1 1 0 00-.364 1.118l1.286 3.957c.3.921-.755 1.688-1.54 1.118l-3.366-2.446a1 1 0 00-1.176 0l-3.366 2.446c-.784.57-1.838-.197-1.539-1.118l1.286-3.957a1 1 0 00-.364-1.118L2.066 9.384c-.783-.57-.38-1.81.588-1.81h4.162a1 1 0 00.95-.69l1.286-3.957z" />
                    </svg>
                    <svg
                      v-else
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 20 20"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.5"
                      class="w-4 h-4"
                      aria-hidden="true"
                    >
                      <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.286 3.957a1 1 0 00.95.69h4.162c.969 0 1.371 1.24.588 1.81l-3.367 2.446a1 1 0 00-.364 1.118l1.286 3.957c.3.921-.755 1.688-1.54 1.118l-3.366-2.446a1 1 0 00-1.176 0l-3.366 2.446c-.784.57-1.838-.197-1.539-1.118l1.286-3.957a1 1 0 00-.364-1.118L2.066 9.384c-.783-.57-.38-1.81.588-1.81h4.162a1 1 0 00.95-.69l1.286-3.957z" />
                    </svg>
                  </button>
                </span>
              </button>
            </div>
          </div>
```

### Step 2.7 — Add the row-click + pin helper functions + the formatRelativeTime import

**File:** `src/apps/desktop/src/components/FilePickerDialog.vue`

In the existing import block (around line 26), add:

```typescript
import { formatRelativeTime } from '../helpers/relativeTime'
```

Below the existing `handleSelect` function (around line 329), add:

```typescript
// Recent tab row click. Sets selectedPath, then triggers the same emit
// path as Browse (handleSelect). The store's `watch(effectiveSelection, ...)`
// records the path on every select — Recent rows go through the same
// code path.
function handleRecentRowClick(path: string): void {
  selectedPath.value = path
  handleSelect()
}

// Recent tab pin click. Toggles the pin; does NOT select.
function handleRecentPinClick(path: string): void {
  recentStore.togglePin(path)
}

// Format a Unix-ms timestamp as the SQLite UTC string `formatRelativeTime`
// expects (`'YYYY-MM-DD HH:MM:SS'`). See R12.
function toSqliteUtc(ms: number): string {
  const d = new Date(ms)
  // toISOString → 'YYYY-MM-DDTHH:MM:SS.sssZ'. Build the SQLite shape.
  return d.toISOString().replace('T', ' ').slice(0, 19)
}
```

### Step 2.8 — Run the new tests + confirm they pass

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/FilePickerDialog.spec.ts 2>&1 | tail -n 60
```

**Expected output:** the 10 new tests in the new `describe` block all pass.

### Step 2.9 — Type-check

```bash
cd src/apps/desktop && bun run build 2>&1 | tail -n 30
```

**Expected output:** type-check passes. Delete any stray `.js` files emitted by `vue-tsc` (see `vue-tsc-build-emits-js-files` skill).

### Step 2.10 — Run the full test suite

```bash
cd src/apps/desktop && bunx vitest run 2>&1 | tail -n 50
```

**Expected output:** all tests pass (the new tests + the existing 1025-ish tests in `FilePickerDialog.spec.ts` + others). If any existing test breaks, read the failure — the most likely cause is R4 (default tab is now Recent, not Browse). Append `enableRecentHistory: false` to the existing `mountDialog({...})` calls where needed.

### Step 2.11 — Commit

```bash
git add src/apps/desktop/src/components/FilePickerDialog.vue \
        src/apps/desktop/src/__tests__/FilePickerDialog.spec.ts
git status  # verify NO .js files, NO dist/
git commit -m "feat(folder-picker): Recent tab + tabstrip + pin star

The FilePickerDialog now opens on a Recent tab showing the user's
recently-picked folders (most recent first, pinned at top). The
existing two-pane tree + content layout lives under the Browse
tab. A new tabstrip separates the two views.

Each Recent row has a folder icon, basename, full path, relative
time chip (reuses formatRelativeTime: now / 2h / yest / 3d / ...),
and a star button that toggles pin. Selecting a Recent row emits
the same 'select' event as Browse and closes the dialog (same
closeOnSelect semantics). The store records the path on every
select (Recent OR Browse).

The Recent tab is opt-out via enableRecentHistory: false (default
true). No caller changes — every existing caller gets the new tab.

Toollbar (search + hidden + refresh) is hidden under Recent — it
only applies to the Browse tree. The breadcrumb + address bar +
footer are unchanged.

10 new behavioural tests in FilePickerDialog.spec.ts cover the
tabstrip state, empty state, list rendering, row click, pin
toggle, tab switching, count badge, opt-out, and the
relative-time chip."
```

**Done when:** the new tests pass + the existing tests still pass + the commit lands.

---

## Task 3 — Bump the dialog's max-height so the Recent tab fits on 720p

**Goal:** The new tabstrip + Recent list pushes the dialog to ~792px. Today the max-height is `80vh` with `min-height: 480px`. On a 720p viewport, 80vh = 576px — the min-height wins, and the Recent list scrolls inside. Adjust the max-height to `min(80vh, 720px)` so the dialog fits without scrolling on a 720p display.

### Step 3.1 — Update the dialog's max-height

**File:** `src/apps/desktop/src/components/FilePickerDialog.vue`

Find the dialog card's `style` block (around line 681-689):

```html
        <!-- Dialog Card -->
        <div
          class="relative w-full max-w-3xl rounded-xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35),
              0 24px 64px rgba(137, 146, 167, 0.06);
            max-height: 80vh;
            min-height: 480px;
          "
          data-testid="file-picker-dialog"
        >
```

Change `max-height: 80vh;` to `max-height: min(80vh, 720px);`. Done.

### Step 3.2 — Write a regression test (optional, 1 test)

Add a small test block to `FilePickerDialog.spec.ts` that confirms the dialog is now `min(80vh, 720px)`:

```typescript
it('dialog max-height bumps to min(80vh, 720px) so the Recent tab fits on 720p', async () => {
  wrapper = mountDialog({ initialPath: '/home/user' })
  await wrapper.setProps({ modelValue: true })
  await flushPromises()
  const dialog = findInDom('[data-testid="file-picker-dialog"]')
  const style = (dialog as HTMLElement | null)?.getAttribute('style') ?? ''
  expect(style).toContain('max-height: min(80vh, 720px)')
})
```

### Step 3.3 — Run + commit

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/FilePickerDialog.spec.ts 2>&1 | tail -n 30
cd src/apps/desktop && bun run build 2>&1 | tail -n 30
git status
git add src/apps/desktop/src/components/FilePickerDialog.vue \
        src/apps/desktop/src/__tests__/FilePickerDialog.spec.ts
git commit -m "fix(folder-picker): bump dialog max-height to fit the Recent tab on 720p

The new tabstrip + Recent list (header + breadcrumb + tabstrip +
toolbar + 12 rows of cards + footer) totals ~792px. The previous
max-height: 80vh caps the dialog at 576px on a 720p viewport,
forcing the Recent list to scroll inside.

New max-height: min(80vh, 720px). On displays >= 900px tall, 80vh
still wins (e.g. 640px on 800h, 720px on 900h). On < 900px, the
720px cap kicks in — the dialog fits without scrolling on a 720p
display. Mobile / tiny windows keep the responsive 80vh behaviour.

Behavioural test in FilePickerDialog.spec.ts confirms the new
max-height inline style."
```

**Done when:** the dialog fits on 720p and the regression test passes.

---

## Task 4 — Docs, AGENTS.md changelog, kanban move, PR

**Goal:** Land the new feature in the docs. Move the kanban card. Open the PR.

### Step 4.1 — Update `docs/SPEC.md`

Find the most recent 2026-08-14 entry in `docs/SPEC.md` (or any recent entry) and append a new changelog row to the table. The format is:

```markdown
| `2026-08-14-folder-picker-recent-history.md` | ✅ | `useRecentFolders` Pinia store + Recent tab in `FilePickerDialog`... |
```

(Use the exact format of the existing rows — read 2–3 prior rows to match.)

### Step 4.2 — Update `AGENTS.md` "Recent changes" section

Find the most recent `### ` block in `AGENTS.md`. Append a new block above it:

```markdown
- **FilePickerDialog — Recent tab + tabstrip + pin** (2026-08-14): The shared folder picker now opens on a Recent tab showing the user's previously picked folders (most recent first, pinned at top). A new tabstrip separates the Recent tab from the existing Browse tree. Each Recent row has a folder icon, basename, full path, relative time chip (reuses `formatRelativeTime`: now / 2h / yest / 3d / ...), and a star button that toggles pin. Selecting a Recent row emits the same `select` event as Browse; the store records the path on every select. The Recent tab is opt-out via `enableRecentHistory: false` (default `true`). No caller changes — every existing caller gets the new tab. The toolbar (search + hidden + refresh) is hidden under Recent. New `useRecentFoldersStore` Pinia store at `src/apps/desktop/src/stores/recentFolders.ts` with localStorage persistence (`pabrik-folder-picker-recent:v1`, 12-entry cap, pinned entries exempt from eviction, 200ms debounced writes). 12 store tests + 10 dialog tests in `FilePickerDialog.spec.ts`. Branch: `worktree/folder-picker-recent-history`. Plan: `docs/superpowers/plans/2026-08-14-folder-picker-recent-history.md`.
```

### Step 4.3 — Full verification sweep

```bash
cd src/apps/desktop && bun run build 2>&1 | tail -n 30
cd src/apps/desktop && bunx vitest run 2>&1 | tail -n 30
git status   # verify NO .js files, NO dist/
git status --porcelain | head -n 30
```

**Expected output:** type-check passes, all tests pass, git status is clean (`docs/SPEC.md` and `AGENTS.md` are the only modified files since Task 3).

### Step 4.4 — Open the PR

```bash
cd .worktrees/folder-picker-recent-history
gh pr create \
    --title "feat(folder-picker): Recent tab + tabstrip + pin + relative-time chip" \
    --body-file <(git log main..HEAD --pretty=format:"- %s%n%b%n")
```

### Step 4.5 — Move the kanban card

After Step 4.4, the PR is open. Move the kanban card "enhance file folder implement recent history" from `in progress` to `in_review_task` (the user reviews the PR, then merges):
- Use `kanban_move_task` with `workspace_id` + `item_id` from the chat context, `task_id` from the active task, and `target_column_id` = `col_1826ecca367f0000` (the `in_review_task` column).

### Step 4.6 — User merges the PR

The user merges the PR. They move the kanban card to `merged`.

---

## Verification

- [ ] Worktree `worktree/folder-picker-recent-history` exists, branch created off `main`.
- [ ] `useRecentFoldersStore` round-trips through localStorage (12 store tests pass).
- [ ] `FilePickerDialog` opens on the Recent tab by default.
- [ ] The Recent tab shows the user's previously picked folders (pinned first).
- [ ] Clicking a Recent row emits `select` + closes the dialog (same wire as Browse).
- [ ] The star toggles pin (no `select` emitted).
- [ ] The Browse tab is one click away and shows the existing two-pane tree + content layout.
- [ ] The toolbar (search + hidden + refresh) is hidden under Recent.
- [ ] The dialog's max-height is `min(80vh, 720px)` so the Recent tab fits on 720p.
- [ ] `bun run build` passes (vue-tsc type-check).
- [ ] `bunx vitest run` passes (no regressions).
- [ ] `git status` is clean (no `dist/`, no stray `.js` files).
- [ ] PR is open, kanban card is in `in_review_task`.
- [ ] `docs/SPEC.md` has a new changelog row.
- [ ] `AGENTS.md` has a new "Recent changes" entry.
