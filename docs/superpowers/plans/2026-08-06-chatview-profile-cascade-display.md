# Plan — chatview profile chip shows effective cascade

**Date:** 2026-08-06
**Branch:** `worktree/investigate-profile-bug`
**Spec:** `docs/superpowers/specs/2026-08-06-chatview-profile-cascade-display-design.md`
**Bug report:** task_1786029998152 (kanban: "profile actvie bugs")

## TL;DR

The chatview profile chip only showed the per-session
`selected_profile_model`, never the `active_profile` fallback. Backend
cascade works correctly (already verified live with curl + logs). Fix
is a frontend-only change in `ChatView.vue` + a new test spec.

## Investigation findings (Phase 1)

**User's symptoms (user message 2026-08-06):** "i select profile active
300ribu, but when create a task or start a session why the init select
model not using from actice which is the selected profiel"

**Live evidence the cascade IS working** (logs from
`/tmp/agentic_coding.log`):
- New session with `selected_profile_model=""` →
  `[CHECKPOINT] profile selected_profile_model='' effective_model=MiniMax-M3`
- Session with `selected_profile_model='300 ribu'` →
  `[CHECKPOINT] profile selected_profile_model='300 ribu' effective_model=MiniMax-M3`

**Live evidence the chip is misleading** (frontend source):
- `ChatView.vue:773` — `selectedProfile = ref<string | null>(null)`
- `ChatView.vue:2043` — watch on `sessionId` resets to `null`
- `ChatView.vue:2048` — `selectedProfile.value = session?.selectedProfile ?? null`
- `ChatView.vue:2777` — chip: `{{ selectedProfile ?? 'Default' }}`
- `ChatView.vue:2770-2774` — tooltip:
  `'Using default (top-level config)'` (misleading — actually uses
  active profile)

**Why the user thought it was broken:** Their profiles and top-level
config happen to use the same `model` (`MiniMax-M3`) and the same
`base_url`, so the visible LLM output looked identical regardless of
which layer was selected. The only field that differs across layers
is `api_key` (300 ribu + top-level share one key; 900ribu uses a
different one). When the chip said "Default" but actually used
"300 ribu", the LLM's response was identical → user inferred the chip
label was telling the truth → concluded "active profile doesn't work".

**The chip is the bug, not the cascade.** The user can't observe the
bug directly because their model is the same across layers.

## Phase 2 — Hypothesis (confirmed)

**Hypothesis:** ChatView's profile chip ignores `config.active_profile`
and only renders the per-session `selected_profile_model`. The
backend cascade in `workflow.zig::resolveProfileField` is correct; the
UI is misleading.

**Verification:** Code reading + live logs confirm both halves.

**Out of scope** (user did not ask to fix):
- `workflow.zig:1076` passing `config.api_key, config.base_url` to
  `handle_tool` instead of effective values (no observable impact
  for this user's config)
- `spawn_sub_agent.zig:334` only checking per-session
  `selected_profile_model` for sub-agent lookup, not active profile
  (user's profiles have 0 sub_agents)

## Phase 3 — Fix (TDD)

### Step 1: Write tests first (RED)

**File:** `src/apps/desktop/src/__tests__/ChatView.profileCascade.spec.ts`
(336 lines, 7 tests).

Setup mirrors `ChatView.stopSession.spec.ts`:
- `setActivePinia(createPinia())` in `beforeEach`
- `installSseBus(vueApp)` + `__setSseBusGlobalClient(stub)`
- `Object.defineProperty(globalThis, 'localStorage', { value: makeLocalStorageStub() })`
  (jsdom 29 dropped localStorage; the `workspacesStore.init()` path
  calls `localStorage.getItem` and crashes without this stub)
- `getNalarConfig` / `getSession` are `vi.spyOn` mocked per test

Tests cover the 5-row behavioural matrix from the spec + 2 picker
checks (active badge + ✓ on effective row).

### Step 2: Run tests, confirm RED

```
Test Files  1 failed (1)
Tests       7 failed (7)
```

All 7 failed because the chip's text is just `Default` (when
`selectedProfile=null`) or `''` (when `selectedProfile=''`), never
the active profile. Confirmed bug.

### Step 3: Apply the fix

**File:** `src/apps/desktop/src/components/views/ChatView.vue`
(+62/-13).

Three changes in `<script setup>`:
1. New `activeProfile = ref<string | null>(null)` alongside
   `selectedProfile`.
2. `loadProfiles` reads `(config as { active_profile?: string | null }).active_profile`
   and coerces empty string → `null`.
3. Two new computeds: `effectiveProfile` (per-session || active) and
   `profileChipTooltip` (3-state tooltip).

Template changes in the status bar:
1. Chip text: `selectedProfile ?? 'Default'` → `effectiveProfile ?? 'Default'`.
2. Chip title: inline ternary → `:title="profileChipTooltip"`.
3. Picker default row: `v-if="!selectedProfile"` →
   `v-if="!selectedProfile && !activeProfile"`.
4. Picker profile rows: `(active)` badge when
   `activeProfile === p.name`; ✓ when `effectiveProfile === p.name`
   (was: `selectedProfile === p.name`).
5. Add `data-testid` attrs for testability (no production-test
   coupling — purely for the new spec).

### Step 4: Run tests, confirm GREEN

```
Test Files  1 passed (1)
Tests       7 passed (7)
```

### Step 5: Full suite, confirm no regressions

```
Test Files  4 failed | 218 passed (222)
Tests       14 failed | 2010 passed (2024)
```

The 14 failures are the pre-existing baseline on `main`
(AppLayout.urlPersist ×7, AppLayout.memoriesGate ×4,
sidebarKanbanSortUrl ×2, DesignView.nudge ×1). Confirmed by
re-running the suite on `main` (without my changes) — same 14.

### Step 6: Build

```
bun run build (vue-tsc + vite): ✓ built in 2.98s
```

vue-tsc clean. The `INEFFECTIVE_DYNAMIC_IMPORT` warnings are
pre-existing (monaco-editor and src/api/index.ts) and unrelated to
this change.

## Phase 4 — Pitfalls to record

- **Empty string vs null on the wire.** The session's
  `selected_profile_model` arrives as `''` when unset, not `null`.
  The chip must use `||` (not `??`) to fall through correctly. This
  bit the first test attempt — `?? 'Default'` returned `''` for an
  empty-string selectedProfile, so the chip rendered just the emoji
  and chevron. Test "shows the active profile when session has
  empty selected_profile_model (cascade falls through)" exists
  specifically to lock this in.
- **localStorage stub.** `workspacesStore.init()` reads
  `localStorage.getItem('...')` on mount. jsdom 29 dropped
  `localStorage` from its default globals, so the test crashes
  with `Cannot read properties of undefined (reading 'getItem')`
  unless `Object.defineProperty(globalThis, 'localStorage', { value:
  makeLocalStorageStub() })` is set in `beforeEach`. This is a
  project-wide pattern; see `src/apps/desktop/src/__tests__/helpers.ts::makeLocalStorageStub`.
- **SseState enum.** `SseState` is `'connecting' | 'open' |
  'reconnecting' | 'closed' | 'failed'` — NOT `'connected'`. The
  first draft of the test stub used `'connected'` and failed the
  type-check. Use `'open'` (or one of the four other valid values).
- **DOMWrapper type.** `wrapper.findAll('button')` returns
  `DOMWrapper<HTMLButtonElement>[]`, not a generic. The first
  readChip helper used `ReturnType<typeof buttons[0]>` which is
  a complex generic and didn't satisfy the `(fn) => any` constraint
  in `.find()`. Use `DOMWrapper<HTMLButtonElement> | undefined`
  directly.
- **Testid scope for the ✓ check.** The chip text contains
  the profile name too (when active is "300 ribu" and chip says
  "300 ribu"). The test's first version grep'd the raw HTML for
  "300 ribu" then looked for "✓" within 200 chars — but the chip's
  own "300 ribu" matched first and the chip has no ✓. Fix: use
  `wrapper.find('[data-testid="profile-picker-300 ribu"]')` and
  check that scope.

## Files

- Modified: `src/apps/desktop/src/components/views/ChatView.vue`
  (+62/-13)
- New: `src/apps/desktop/src/__tests__/ChatView.profileCascade.spec.ts`
  (+336)
- New: `docs/superpowers/specs/2026-08-06-chatview-profile-cascade-display-design.md`
- New: `docs/superpowers/plans/2026-08-06-chatview-profile-cascade-display.md` (this file)
- AGENTS.md changelog entry: pending (will be added in the merge commit)

## Branch

- Worktree: `worktree/investigate-profile-bug`
- Branch: `worktree/investigate-profile-bug` (pushed to origin)
- Commit: `798096fd fix(chatview): profile chip shows effective cascade (active + per-session)`
- PR: pending — see "Open PR" step in follow-up

## Follow-ups (out of scope, deferred)

- `workflow.zig:1076` — pass `effective_api_key` / `effective_base_url`
  to `handle_tool` instead of `config.api_key` / `config.base_url`.
- `spawn_sub_agent.zig:334` — cascade through `active_profile` for
  sub-agent lookup (currently only checks per-session
  `selected_profile_model`).
- Live smoke test: restart nalar, observe chatview chip shows
  "300 ribu" instead of "Default" when active profile is set.
