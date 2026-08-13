# Folder Picker — Select Button Enabled When Current Folder Is Open

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **⛔ DO ALL WORK IN A GIT WORKTREE — never on `main`.** See **Task 0 — Worktree setup** below. Project convention: every feature/refactor ships via a PR from `worktree/<topic>`. The "fix the select button folder picker" kanban card moves to `merged` only after the user merges the PR.

**Goal:** Enable the **Select** button in `FilePickerDialog` (folder mode) whenever the user has navigated to a folder — even if they haven't clicked a folder in the content pane. The currently-open folder (the one shown on the right pane / breadcrumb) is a valid selection; the user shouldn't have to click the same folder twice just to confirm it.

**Architecture:** Localized edit to `src/apps/desktop/src/components/FilePickerDialog.vue`. Introduce a computed `effectiveSelection` that prefers `selectedPath` (explicit click) and falls back to `currentPath` (currently-open folder). Wire `canSelect` to `effectiveSelection` and `handleSelect` to emit `effectiveSelection`. Update the footer "Selected:" readout + add a tiny "← current folder" hint when the fallback is in use. Add behavioural tests to `src/apps/desktop/src/__tests__/FilePickerDialog.spec.ts` covering the three browser-side affordances (button enables/disabled, click emits, footer reflects, tree navigation past `/` doesn't enable, root path '/' doesn't enable). No backend changes, no wire-format changes.

**Tech Stack:** Vue 3.5 + TypeScript, Vitest, Vite, the shared `FilePickerDialog` component (no other files touched).

---

## Background — why we're doing this

The shared `FilePickerDialog` is the modal used by every "pick a folder" flow in the desktop app (Add Kanban, Add Project, Add Memory, Add Design, Per-Task Cwd, Create Worktree parent dir, the "Set project root" banner on `KanbanView`, and the cwd picker in `KanbanTaskDetailDialog`). Today, the **Select** button in the footer is disabled whenever the user hasn't clicked a folder in the content pane — even if they've already navigated to that folder via the tree (left), the breadcrumb, the address bar, the **Up** button, or `Backspace`.

**User-visible bug:** the user opens the picker, clicks `home` in the tree (left), the children of `/home` load in the content pane (right). They press **Select**. Nothing happens — the button is greyed out. They're forced to click `home` again in the content pane to "select" the very folder they already opened. On touch / a11y / keyboard-only flows this is even worse — there's no way to confirm the current folder without either clicking the same row twice or restoring the content pane to a folder they didn't want.

**Root cause** (in `FilePickerDialog.vue`):
- `canSelect` only flips true when `selectedPath.value` is set (line 335: `const canSelect = computed(() => !!selectedPath.value)`).
- `selectedPath` is only set by `handleItemClick` (line 291), which is wired to clicks on the *content pane* rows.
- `navigateTo()` (line 262) explicitly resets `selectedPath.value = ''` on every navigation — so the tree, the breadcrumb, the **Up** button, `Backspace`, and the address bar all immediately disable the button.

**Why currentPath is the right fallback:** the right pane is literally the contents of `currentPath`; making that folder a "valid selection" makes the picker's mental model match the OS one (Finder / Explorer / GNOME Files / `zenity --file-selection --directory` all confirm the *currently shown* directory when the user presses OK without clicking a child). The user has already committed to "this folder" by navigating to it — the explicit click is redundant.

---

## Design Decisions (review before execution)

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| D1 | **Scope = `folder` mode only.** `file` and `both` modes keep the existing `selectedPath` semantics. | In file mode, the user is selecting a **file** — `currentPath` is the parent of the file, not a valid selection. In `both` mode, the user must click an item to indicate which kind they want. | Auto-selecting `currentPath` in `file` mode would always emit a directory — broken. |
| D2 | **Fallback hierarchy: `selectedPath` (explicit click) → `currentPath` (open folder).** Explicit click wins. | A user who clicks a child folder is being more specific; respect that. The fallback only kicks in when nothing was clicked yet. | Always prefer `currentPath` — overwrites the user's explicit click. Always prefer `selectedPath` — leaves the bug. |
| D3 | **`currentPath === '/'` does NOT enable Select.** Root is the "I haven't picked anything" state. | Emitting `/` on confirm would be meaningless — every picker caller validates the selected path against a meaningful project root. | Allowing `/` — breaks the parent dialogs (e.g. `AddItemDialog` already filters empty paths before `handleCreate`). |
| D4 | **Footer "Selected:" always shows `effectiveSelection`**, not `selectedPath`. | The footer is the ground-truth display of what will be emitted — keeping it in sync with `canSelect` avoids confused users. | Two separate displays — diverges during the fallback → "why does the button say Select when the footer says (none)?" |
| D5 | **Add a tiny `← current folder` hint** in the footer when the fallback is in use (i.e. `selectedPath === ''` but `currentPath` is valid). | Tells the user "the button is enabled because you're sitting on this folder, not because you clicked it". This is the missing explainer that prevents the next "is the button broken?" report. | No hint — users will be slightly confused for the first click. |
| D6 | **`currentPath` starts at `initialPath` (line 79)**, so the fallback is meaningful on dialog open only when the caller passes a non-root `initialPath`. This is already the case for `CreateWorktreeDialog` (passes `parentDir`), `KanbanTaskDetailDialog` (passes `cwdSession || props.cwd || '/'`), and most others. | Caller intent is preserved: if the caller gave us a starting path, that path is a valid initial selection. | Always start at `/` — makes the fallback useless on open. |
| D7 | **No new props.** The fix is purely internal to `FilePickerDialog.vue`. | The component is already shared across 6 callers; adding a prop would force every caller to think about it. | New `useCurrentFolderAsDefault?: boolean` prop — over-engineered for a behaviour that should always be true. |
| D8 | **No footer slot changes.** Existing `<slot name="footer" />` between the **Selected:** and the buttons is preserved verbatim. | Some callers (none today, but the slot is there) might use it; don't break the contract. | Move the slot — wasted refactor. |
| D9 | **No `props.selectedPath` init change.** The component still reads `props.selectedPath` on open via `selectedPath.value = props.selectedPath || ''` (line 104 / `openDialog` line 575). | Existing `selectedPath` prop contract (set by caller to "this is the current value, pre-select it") is preserved. | Drop the prop — that's a separate refactor. |
| D10 | **Behavioural tests only.** No static `expect(component).toContain(...)` patterns. Mirror the existing `FilePickerDialog.spec.ts` style. | Project memory `static-contract-test-when-to-prefer-behavioural` applies. | Static assertions — false-positive on rename. |
| D11 | **Bun-only verification.** `bun run build` for the type-check + `bunx vitest run -- FilePickerDialog` for the tests. The project uses Bun and Vitest. | The desktop-frontend-build skill calls out `bun run build` as the type-check. | `npm run build` — works but slower; project uses Bun. |
| D12 | **One PR, two commits.** Commit 1: tests + impl + footer hint. No commit boundary inside the file — it's a single localized change. Optionally commit 2: docs/superpowers reference. | ATOMIC-WRITING principle: keep the change small, one commit covers it. | Splitting tests from impl — adds a commit that ships with a failing test, which is fine for TDD but unnecessary for a tiny fix. |

---

## Global Constraints

- **Cross-platform**: every change MUST work on Linux, macOS, AND Windows. The frontend is a Vite + Vue 3 SPA; no platform-specific code.
- **No static-contract tests**: ALL tests are behavioural. See `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`.
- **TDD discipline**: every implementation step starts with a failing test, then minimal code to make it pass, then a commit.
- **`bun run build` IS the type-check**: every frontend commit must pass `bun run build`; `bunx vitest run` alone does NOT catch type errors.
- **No `dist/` or `.js` cruft**: `vue-tsc --build` emits `.js` files alongside `src/**/*.ts` (see `vue-tsc-build-emits-js-files` skill). Delete them before `git status`.
- **No port 8081**: smoke tests use port 8080.
- **Teleport + Transition test pattern**: `FilePickerDialog` uses `<Teleport to="body">` AND `<Transition>`. `@vue/test-utils` stubs `<Transition>`, so `wrapper.find()` does NOT traverse into the dialog. Use `document.querySelector('[data-testid="..."]')` for data-testid assertions — see the existing `findInDom` / `findAllInDom` / `clickInDom` / `keydownInDom` helpers at the top of `FilePickerDialog.spec.ts`.
- **Vue 3.5 anonymous-struct-literal gotcha**: do NOT initialize only one field of a multi-field object — anon struct literals only initialize named fields. (`@zig-constcast-slice-helper-mismatch` is a Zig-only memory of the same shape; the Vue-side analogue is this Vue 3.5 / TS quirk.)

---

## File Structure

```
src/apps/desktop/src/
├── components/
│   └── FilePickerDialog.vue                                     # MINIMAL EDIT — add effectiveSelection + footer hint
└── __tests__/
    └── FilePickerDialog.spec.ts                                 # ADD ~5 behavioural tests in a new describe block

# UNCHANGED (verify by reading, not editing):
├── components/dialogs/AddItemDialog.vue                         # uses FilePickerDialog, no change
├── components/dialogs/AddKanbanDialog.vue                       # uses FilePickerDialog, no change
├── components/dialogs/AddMemoryDialog.vue                       # uses FilePickerDialog, no change
├── components/dialogs/CreateWorktreeDialog.vue                 # uses FilePickerDialog, no change
├── components/design/AddDesignDialog.vue                        # uses FilePickerDialog, no change
├── components/kanban/KanbanTaskDetailDialog.vue                 # uses FilePickerDialog, no change
└── components/kanban/KanbanView.vue                             # uses FilePickerDialog, no change
```

**Why no caller changes:** the patch is purely internal to `FilePickerDialog.vue`. The `closeOnSelect` prop already governs auto-close; every caller passes `closeOnSelect: true` (AddItemDialog, AddKanbanDialog, AddMemoryDialog, AddDesignDialog, KanbanTaskDetailDialog's cwd picker) or `closeOnSelect: false` (CreateWorktreeDialog — closes manually from the parent). Both flows work with the new fallback because `handleSelect` always emits a valid path.

---

## Risks & breaking changes analysis

| # | Risk | Mitigation |
|---|------|-----------|
| R1 | **A caller that relied on Select being disabled at `/` now sees it enabled.** | D3: `currentPath === '/'` is excluded — `/` is treated as "no selection". The fallback only kicks in when `currentPath` is a real folder. |
| R2 | **The user presses Select without clicking anything, gets a folder they didn't intend.** | This is what the user is asking for. The footer hint (`← current folder`) + the "Selected:" readout make the consequence visible. |
| R3 | **Existing test `Select button is disabled when nothing is selected` (line 259-265) breaks.** | That test mounts with `initialPath: '/home/user'` — a non-root path. Per D2/D3, the fallback IS enabled at `/home/user`, so the test must be updated to either (a) mount at `/` (root) to assert the disabled-at-root invariant, or (b) bake in the new contract. The plan renames the test to `Select button is disabled at root when nothing is selected` and changes the `initialPath` from `/home/user` to `/`. |
| R4 | **Existing test `Enter on a highlighted folder (folder mode, closeOnSelect: true) selects and closes` (line 468-478) breaks.** | That test currently presses `Enter` after `ArrowDown`; the keydown handler at line 491-501 calls `handleItemClick` then `handleSelect`. Since `handleItemClick` sets `selectedPath`, the explicit-click branch of `effectiveSelection` is exercised. Test stays green. |
| R5 | **Tree click clears `selectedPath` (line 266) but the user expects the tree click to also "select" the folder.** | The user clearly distinguishes between "navigate" (left tree click) and "select" (right content click). The fallback path `currentPath → effectiveSelection` covers the case where the user just navigated and wants to confirm — they don't need to click the same folder again. |
| R6 | **The "Selected:" footer shows `currentPath` even when the user clicked a CHILD folder (so `selectedPath` is set).** | D2 + D4: `effectiveSelection` prefers `selectedPath` (child) over `currentPath` (parent). The footer shows the child. The fallback is **only** when `selectedPath === ''`. |
| R7 | **The new footer hint `← current folder` shows even when `selectedPath` is set (clicks).** | D5: only show when `selectedPath === ''` AND `currentPath` is a valid (non-root) folder. The hint is computed-off when an explicit click is in play. |
| R8 | **The `Enter` key on the dialog (line 491-501) emits `effectiveSelection` via `handleSelect` — but the user pressed Enter on a HIGHLIGHTED item, so `selectedPath` is set right before.** | Verified: `handleItemClick(entry.item)` runs first (line 494), which sets `selectedPath.value`. Then `handleSelect()` runs (line 495), which now reads `effectiveSelection` — which is `selectedPath` (the just-clicked item). Behaviour unchanged. |
| R9 | **The `Enter` key inside the search input (line 472-482) submits the first match → `handleItemClick` → `handleSelect`. Same path as R8 — first match is the just-set `selectedPath`.** | Same as R8. No regression. |
| R10 | **Keyboard `Enter` from outside the content pane (no highlight, no search) hits the `else if (canSelect.value)` branch (line 496-498), which calls `handleSelect()`. With the fix, `canSelect` is `true` when `currentPath` is valid → emits `currentPath`.** | This is the desired new behaviour. Document explicitly in the new test. |
| R11 | **A caller that does NOT pass `initialPath` defaults to `/` (line 79). With the fix, the button stays disabled at root.** | D3. The user has to click into a folder on the right to enable Select. Already the existing behaviour — no change. |
| R12 | **The fix adds a 4th `<span>` (the hint) inside the footer — make sure existing data-testids for the existing footer children are preserved.** | Plan: add the hint AFTER the existing `data-testid="file-picker-selected-path"` span, with a NEW `data-testid="file-picker-selected-hint"` so it's easy to assert on. No existing data-testid is modified. |
| R13 | **CSS restyling of the hint** — must use existing CSS variables (`var(--semantic-text-dim)`). | Plan uses the same dim-text style as the existing "Selected:" label. |
| R14 | **The hint shows on the parent of the searched-into folder (e.g. user searches "docs" → Select is still based on `currentPath`, not the search match).** | Documented behaviour: search filters the content pane but does NOT auto-select. The hint + footer make this clear. No code change needed. |

---

## Task 0 — Git worktree setup (do this FIRST)

**CRITICAL: do NOT implement directly on `main`.** Every commit in this plan lands on the worktree branch; the user is the only one who moves them to `main`. The kanban task "fix the select button folder picker" moves to `merged` only after the PR is merged.

### Step 0.1 — Create the worktree
Project convention (every existing refactor follows this):
- Path: `/home/ginwa/ginwaaitoolbox/.worktrees/<topic-slug>`
- Branch: `worktree/<topic-slug>` (auto-derived from the path basename)

Use the `set_git_worktree` tool:
```
path: /home/ginwa/ginwaaitoolbox/.worktrees/folder-picker-select-current-folder
```

Or equivalently:
```bash
cd /home/ginwa/ginwaaitoolbox
git worktree add .worktrees/folder-picker-select-current-folder \
    -b worktree/folder-picker-select-current-folder main
```

**If the path already exists** (someone else's worktree):
- `git worktree list` to see what's there
- Either pick a different slug OR pass `branch=<existing-branch>` to bind to the existing branch

**If a different worktree already has the same branch checked out:**
- Pass `branch=''` to fall back to the auto-derived name (or pick a different slug)

### Step 0.2 — Verify the worktree
```bash
cd .worktrees/folder-picker-select-current-folder
git status            # should be on worktree/folder-picker-select-current-folder, clean
git log -1 --oneline  # should match main HEAD
```

### Step 0.3 — Run every subsequent command from inside the worktree
All `git add` / `git commit` / `bunx vitest` / `bun run build` commands in Tasks 1–3 run from `.worktrees/folder-picker-select-current-folder/`. Path-relative in this plan (e.g. `src/apps/desktop/src/components/FilePickerDialog.vue`) resolves from this worktree root.

### Step 0.4 — Open the PR at the end (Task 3.4)
After Task 3 verification:
```bash
cd .worktrees/folder-picker-select-current-folder
gh pr create \
    --title "fix(folder-picker): Select button enabled when current folder is open" \
    --body-file <(git log main..HEAD --pretty=format:"- %s%n%b%n")
```
Then the user reviews and merges.

### Step 0.5 — Kanban tracking
- **before starting Task 1**: move the kanban card "fix the select button folder picker" from `todo` to `in progress` (mandatory per the project's Kanban Status Tracking rules)
- **after Step 3.4**: move the card to `in_review_task` (waiting on user merge)
- **user merges the PR**: user moves the card to `merged`

---

## Task 1 — Failing tests (TDD, no impl yet)

**Goal:** Add the new behavioural tests to `FilePickerDialog.spec.ts` that codify the desired contract. They MUST fail against the current `FilePickerDialog.vue` (which only enables Select on explicit click). Then we wire the fix in Task 2.

### Step 1.1 — Add the new `describe` block

**File:** `src/apps/desktop/src/__tests__/FilePickerDialog.spec.ts`

Append a new `describe` block at the end of the file (after the `// ─── Address-bar (path input) ───` block, before the file's final `})`). The new block covers the four scenarios from D2/D3/D5/R3/R7:

```typescript
// ─── Select button — current folder fallback (folder mode) ─────────────────
//
// Plan: docs/superpowers/plans/2026-08-13-folder-picker-select-button-current-folder.md
//
// The Select button is enabled whenever the user has a meaningful folder
// in scope — either because they clicked a folder in the content pane
// (explicit selectedPath) OR because they navigated to a folder via the
// tree / breadcrumb / Up / Backspace / address bar (currentPath). The
// root path '/' is treated as "no selection" and does NOT enable the
// button. The footer "Selected:" shows what will be emitted, and a tiny
// "← current folder" hint appears when the fallback path is in use.
describe('FilePickerDialog — Select when current folder is open (folder mode)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('Select button is DISABLED at root when nothing is clicked', async () => {
    wrapper = mountDialog({ initialPath: '/', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(true)
  })

  it('Select button is ENABLED when the user navigates into a non-root folder (no click)', async () => {
    // The fix: navigateTo() resets selectedPath but the new effectiveSelection
    // falls back to currentPath. The button is enabled because /home/user is
    // a real folder, even though the user never clicked a row in the content pane.
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(false)
    // The footer reflects the fallback (currentPath).
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('/home/user')
    // The hint is visible because the fallback is in use (no explicit click).
    expect(findInDom('[data-testid="file-picker-selected-hint"]')).not.toBeNull()
  })

  it('Select button STAYS enabled after navigating Up via the Up button', async () => {
    // Mirrors the bug report: user opens picker at /home/user, clicks Up,
    // lands at /home. The button should still be enabled — /home is a real
    // folder they just navigated to.
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-up"]')
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(false)
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('/home')
  })

  it('Select button is DISABLED after navigating to root via Up', async () => {
    // D3: '/' is treated as "no selection". The fallback is gated on
    // currentPath !== '/'.
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home', mode: 'folder', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-up"]')
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(true)
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('(none)')
  })

  it('clicking Select with the fallback emits currentPath (no explicit click)', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder', closeOnSelect: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-select"]')
    await flushPromises()
    expect(wrapper.emitted('select')?.[0]).toEqual(['/home/user'])
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })

  it('explicit click on a folder OVERRIDES the fallback in the footer', async () => {
    // D2: selectedPath (explicit) wins over currentPath (fallback). User
    // navigates to /home/user, then clicks /home/user/docs in the content
    // pane. The footer should show /home/user/docs, NOT /home/user.
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/docs"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('/home/user/docs')
    // The hint is HIDDEN because the explicit click is in play.
    expect(findInDom('[data-testid="file-picker-selected-hint"]')).toBeNull()
  })

  it('file-mode: Select is still disabled at a non-root folder (no fallback in file mode)', async () => {
    // D1: only folder mode gets the fallback. In file mode, currentPath is a
    // directory, not a selectable file — Select must wait for an explicit
    // file click.
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'file' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(true)
  })

  it('Enter key on the dialog (no highlight) emits currentPath via the fallback', async () => {
    // R10: pressing Enter without first pressing ArrowDown calls
    // handleSelect() in the `else if (canSelect.value)` branch. With the
    // fix, canSelect is true at /home/user, and Enter emits /home/user.
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder', closeOnSelect: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    keydownInDom('Enter')
    await flushPromises()
    expect(wrapper.emitted('select')?.[0]).toEqual(['/home/user'])
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })
})
```

### Step 1.2 — Update the existing root-pinned test

**File:** `src/apps/desktop/src/__tests__/FilePickerDialog.spec.ts`

The existing test `'Select button is disabled when nothing is selected'` (line 259-265) currently uses `initialPath: '/home/user'`. With the fix, this test would now fail because the fallback IS enabled at `/home/user`. Rename it to clarify intent and pin it to the root path:

```typescript
// RENAMED + initialPath changed from '/home/user' to '/' to assert the
// "disabled at root" invariant. Previously: "Select button is disabled
// when nothing is selected". Plan:
// docs/superpowers/plans/2026-08-13-folder-picker-select-button-current-folder.md
it('Select button is disabled at root when nothing is selected', async () => {
  wrapper = mountDialog({ initialPath: '/', mode: 'folder' })
  await wrapper.setProps({ modelValue: true })
  await flushPromises()
  const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
  expect(btn?.disabled).toBe(true)
})
```

(Only the `it(...)` title and the `initialPath` change; the rest of the test body is identical.)

### Step 1.3 — Run tests and confirm they fail

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/FilePickerDialog.spec.ts 2>&1 | tail -n 60
```

**Expected output:** the 8 new tests in the new `describe` block FAIL (the implementation does not yet enable Select at non-root folders). The renamed root-pinned test PASSES (root is still disabled). The pre-existing tests for content rendering, breadcrumb, search, address bar, etc. all PASS (untouched).

If any pre-existing test fails, read the failure carefully — it might be a test that depends on the old "disabled at /home/user" contract and needs the same `initialPath` change. Search for `initialPath: '/home/user'` in the spec and confirm each test's intent.

**Done when:** the new describe block reports 8 failures, the rest of the file is green.

### Step 1.4 — Commit (do NOT commit yet — tests are red)

```bash
# Do NOT run `git commit` — red tests must not ship. Task 2 fixes them.
```

---

## Task 2 — Implementation in `FilePickerDialog.vue`

**Goal:** Apply the surgical change to `FilePickerDialog.vue`. After this task, the tests from Task 1 turn green.

### Step 2.1 — Add `effectiveSelection` computed

**File:** `src/apps/desktop/src/components/FilePickerDialog.vue`

Find the existing `canSelect` computed (currently at line 335):

```typescript
const canSelect = computed(() => !!selectedPath.value)
```

Replace it with a new computed that captures D2 (hierarchy) and D3 (root exclusion), and update `canSelect` to use it:

```typescript
// Effective selection for the Select button. Order of preference:
//   1. selectedPath — the user explicitly clicked a folder in the content pane.
//   2. currentPath — the user navigated to a folder via the tree, breadcrumb,
//      Up button, Backspace, or address bar. The currently-open folder is a
//      valid selection (mirrors Finder / Explorer / zenity --directory).
// The root path '/' is treated as "no selection" — falling back to it would
// emit a meaningless path that every caller rejects. Plan:
// docs/superpowers/plans/2026-08-13-folder-picker-select-button-current-folder.md
const effectiveSelection = computed<string>(() => {
  if (mode.value !== 'folder') return selectedPath.value
  if (selectedPath.value) return selectedPath.value
  if (currentPath.value && currentPath.value !== '/') return currentPath.value
  return ''
})

const canSelect = computed(() => !!effectiveSelection.value)
```

**Why `effectiveSelection` is computed off `mode`:** R1 — file mode must not fall back to `currentPath` (which is a directory). The conditional `if (mode.value !== 'folder') return selectedPath.value` short-circuits to the old behaviour for `file` and `both` modes.

### Step 2.2 — Update `handleSelect` to emit `effectiveSelection`

Find `handleSelect` (currently at line 319):

```typescript
function handleSelect() {
  if (!selectedPath.value) return
  emit('select', selectedPath.value)
  // Note: Vue 3.5 auto-defaults `boolean?` to `false`, so the only way to opt
  // INTO close-on-select is to explicitly pass `closeOnSelect={true}`. If the
  // prop is omitted, the dialog stays open after selection.
  if (props.closeOnSelect) {
    emit('update:modelValue', false)
  }
}
```

Replace the guard and the emit source:

```typescript
function handleSelect() {
  const path = effectiveSelection.value
  if (!path) return
  emit('select', path)
  // Note: Vue 3.5 auto-defaults `boolean?` to `false`, so the only way to opt
  // INTO close-on-select is to explicitly pass `closeOnSelect={true}`. If the
  // prop is omitted, the dialog stays open after selection.
  if (props.closeOnSelect) {
    emit('update:modelValue', false)
  }
}
```

(`effectiveSelection` is only non-empty when `canSelect` is true, so the guard is the same shape — the path source is just `effectiveSelection` instead of `selectedPath`.)

### Step 2.3 — Update the footer "Selected:" readout + add the hint

Find the footer block (currently at lines 1118-1143, the `<div class="px-5 py-3 ...">` containing the "Selected:" span and the right-side buttons):

```html
<div class="flex-1 min-w-0 flex items-center gap-2">
  <span
    class="text-xs shrink-0"
    style="color: var(--semantic-text-dim)"
    >Selected:</span
  >
  <span
    class="text-xs font-mono truncate"
    style="
      color: var(--semantic-text);
      direction: rtl;
      text-align: left;
    "
    :title="selectedPath || '(none)'"
    data-testid="file-picker-selected-path"
    >{{ selectedPath || '(none)' }}</span
  >
</div>
```

Replace the right-hand `<span>` so the readout + the hint both bind to `effectiveSelection`:

```html
<div class="flex-1 min-w-0 flex items-center gap-2">
  <span
    class="text-xs shrink-0"
    style="color: var(--semantic-text-dim)"
    >Selected:</span
  >
  <span
    class="text-xs font-mono truncate"
    style="
      color: var(--semantic-text);
      direction: rtl;
      text-align: left;
    "
    :title="effectiveSelection || '(none)'"
    data-testid="file-picker-selected-path"
    >{{ effectiveSelection || '(none)' }}</span
  >
  <!--
    NEW (plan: 2026-08-13-folder-picker-select-button-current-folder.md).
    Hint shown when the Select button is enabled via the fallback path
    (currentPath, not selectedPath). Tells the user "the button is on
    because you're sitting on this folder, not because you clicked it".
    Hidden when selectedPath is set (explicit click is more specific).
  -->
  <span
    v-if="mode === 'folder' && !selectedPath && effectiveSelection"
    class="text-[10px] shrink-0"
    style="color: var(--semantic-text-dim)"
    data-testid="file-picker-selected-hint"
    >← current folder</span
  >
</div>
```

(R12: the new `<span>` uses a fresh `data-testid="file-picker-selected-hint"`. No existing data-testid is modified. R13: hint uses the same `var(--semantic-text-dim)` colour as the "Selected:" label.)

### Step 2.4 — Run the tests

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/FilePickerDialog.spec.ts 2>&1 | tail -n 30
```

**Expected output:** all tests pass — the 8 new tests turn green, the renamed root-pinned test stays green, all pre-existing tests stay green.

If a test fails, read the assertion message. The most likely culprit is a test that expected Select to be disabled at a non-root folder — apply the same `initialPath: '/'` rename pattern from Step 1.2 to that test (and add a comment explaining why; the intent is "disabled at root", not "disabled everywhere").

### Step 2.5 — Run the full frontend test suite (no other component should break)

```bash
cd src/apps/desktop && bunx vitest run 2>&1 | tail -n 40
```

**Expected output:** the entire suite stays green. The change is internal to `FilePickerDialog`; no caller's emit contract changed (all callers listen for `select(path)` and the path source is now `effectiveSelection` — which is the same path callers would have received when the user clicked the same folder explicitly).

### Step 2.6 — Run the type-check + build

```bash
cd src/apps/desktop && bun run build 2>&1 | tail -n 30
```

**Expected output:** clean build. No `vue-tsc --build` errors. **Then** delete the `.js` files `vue-tsc` emits alongside the `src/**/*.ts` (per the `vue-tsc-build-emits-js-files` skill):

```bash
cd src/apps/desktop && find src -name '*.js' -not -path 'src/__tests__/*' -not -path 'src/**/*.spec.ts' -delete 2>&1 | head -n 20
```

Verify with `git status` that the only diff is the two intended files.

### Step 2.7 — Commit

```bash
git status                                                    # confirm only FilePickerDialog.vue + FilePickerDialog.spec.ts
git add src/apps/desktop/src/components/FilePickerDialog.vue \
        src/apps/desktop/src/__tests__/FilePickerDialog.spec.ts
git commit -m "fix(folder-picker): enable Select when current folder is open

The FilePickerDialog Select button was disabled whenever the user hadn't
clicked a folder in the content pane — even though they had already
navigated to a folder via the tree, breadcrumb, Up button, Backspace, or
address bar. The button now enables whenever a non-root folder is in
scope (explicit click takes precedence; currentPath is the fallback).

The footer 'Selected:' reflects the effective selection, and a tiny
'← current folder' hint appears when the fallback is in use. File
mode is unchanged — currentPath is a directory, not a selectable file.

Plan: docs/superpowers/plans/2026-08-13-folder-picker-select-button-current-folder.md"
```

**Done when:** the commit is atomic and `git log -1 --stat` shows exactly the two files modified.

---

## Task 3 — Final integration verification

### Step 3.1 — Build + full test suite pass

```bash
cd src/apps/desktop && bun run build 2>&1 | tail -n 10
cd src/apps/desktop && bunx vitest run 2>&1 | tail -n 10
```

Both must be green. No `vue-tsc` errors, no failing tests.

### Step 3.2 — Manual smoke (port 8080)

1. Start the backend: `./zig-out/bin/nalar --port 8080` (the project rule says **never use port 8081**).
2. Start the frontend: `cd src/apps/desktop && bun run dev` (Vite picks its own port).
3. Open the app. Trigger each folder picker one by one and verify the new behaviour:
   - **Add Project** (`AddItemDialog` → "Choose folder" → `FilePickerDialog`):
     - Open the picker — it lands at `/`. Click `home` in the tree (left). The children of `/home` load (right). **Select** is now enabled. Press **Select** → the project is created with `/home` as the path.
     - Open the picker again. Click `home`, then click `user` in the content pane (right). The "Selected:" footer shows `/home/user`. Press **Select** → the project is created with `/home/user`.
   - **Add Kanban** (`AddKanbanDialog` → "Choose folder" → `FilePickerDialog`): same flow.
   - **Add Memory** (`AddMemoryDialog` → folder picker): same flow.
   - **Create Worktree** (`CreateWorktreeDialog` → folder picker for parent dir): navigate via **Up** button — confirm Select stays enabled at the parent folder. Note: this caller uses `closeOnSelect: false` (closes manually from the parent), so the dialog stays open after Select — verify the handler emits the path and the parent updates `parentDir`.
   - **Kanban task detail → Per-Task Cwd picker** (`KanbanTaskDetailDialog`): same flow. The parent has `closeOnSelect: true`.
4. Verify the file mode is untouched: open the file picker (if any caller uses `mode='file'`) and confirm Select is still disabled until a file is clicked.
   - **Note:** no current caller uses `mode='file'` in the desktop app today. The change is exercised by the test suite (R1 / file-mode test), not by manual smoke. Mention this in the PR description.

### Step 3.3 — Check the kanban for follow-ups

While verifying, look for any ad-hoc folder picker that does NOT use `FilePickerDialog` (i.e. a re-rolled picker). If found, flag it as a follow-up kanban task (use `create_kanban_task` with a one-line description pointing at the file). Don't fix it in this PR — out of scope.

```bash
cd src/apps/desktop/src && rg -l "TreePane|tree-flat|treeFlat" --type vue 2>&1 | head -n 10
```

Any hit that's not `FilePickerDialog.vue` is a candidate for the follow-up.

### Step 3.4 — Open the PR

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/folder-picker-select-current-folder
git log main..HEAD --oneline
gh pr create \
    --title "fix(folder-picker): Select button enabled when current folder is open" \
    --body-file <(git log main..HEAD --pretty=format:"- %s%n%b%n")
```

Move the kanban card from `in progress` to `in_review_task` (waiting on user merge):

```
task: "fix the select button folder picker" (task_1786627373004)
column: "in_review_task" (col_1826ecca367f0000)
```

---

## Out of scope (deferred — do NOT do in this plan)

- **Auto-selecting `currentPath` in file mode** — `currentPath` is a directory, not a file. Needs separate UX (e.g. require the user to navigate to a folder and the click a file). Defer.
- **Auto-selecting `currentPath` in `both` mode** — same concern: the user must click to disambiguate file vs folder. Defer.
- **Refactoring the 6+ callers to use a shared `selectedPath`/`initialPath` adapter** — possible cleanup, but orthogonal to this fix. Defer.
- **Replacing the FilePickerDialog with a third-party picker (e.g. `vuefinder`)** — much bigger change, separate brainstorm.
- **Mobile / touch affordances** — the hint + footer already work on touch. Deeper touch refactor is a separate task.
- **Any backend / wire-format changes** — none required.

---

## Verification checklist (copy this for the final response)

- [ ] Worktree created on `worktree/folder-picker-select-current-folder` (Task 0)
- [ ] 8 new behavioural tests added to `FilePickerDialog.spec.ts` (Task 1.1)
- [ ] Existing root-pinned test renamed + `initialPath` changed to `/` (Task 1.2)
- [ ] `effectiveSelection` computed added, `canSelect` rewired (Task 2.1)
- [ ] `handleSelect` emits `effectiveSelection` (Task 2.2)
- [ ] Footer "Selected:" + hint bound to `effectiveSelection` (Task 2.3)
- [ ] `FilePickerDialog.spec.ts` is fully green (Tasks 1.3, 2.4)
- [ ] Full frontend test suite green (Task 2.5)
- [ ] `bun run build` clean + `.js` files cleaned up (Task 2.6)
- [ ] Single atomic commit (Task 2.7)
- [ ] Manual smoke on Linux + all 5 callers verified (Task 3.2)
- [ ] No ad-hoc folder pickers found in the codebase (Task 3.3)
- [ ] PR opened, kanban card moved to `in_review_task` (Task 3.4)
