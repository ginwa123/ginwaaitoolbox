# Plan — NalarSettings Reset button for active profile

**Date:** 2026-08-06
**Branch:** `worktree/investigate-profile-bug`
**Spec:** `docs/superpowers/specs/2026-08-06-reset-active-profile-design.md`
**Bug report:** Follow-up to task_1786029998152 (PR #205 chatview profile cascade display).
**User request:** "in settings app i think we need to have button to reset select profile to goback on the default"

## Problem

After PR #205 landed, the chatview correctly reflects the active
profile cascade. But the NalarSettings → Profiles tab only had a
"Set active" button on each profile row — once a profile was marked
active, there was no UI path to UNSET it short of hand-editing
`~/.config/nalar/config.json` to remove the `active_profile` key.

The user wanted a one-click Reset button so they can fall back to
"no active profile" (cascade falls through to top-level config).

## Investigation

**Current flow when a profile is active** (`NalarSettings.vue`):

- Header (`ProfilesSection.vue:75-80`): renders an `active-pill` span
  showing the profile name (when `activeProfile` is non-null).
- Each non-active profile row: a "Set active" button.
- The active profile's row: NO "Set active" button (it's already
  active).
- No Reset button anywhere.

**`setActiveProfile(name)` in NalarSettings.vue:450-461** is the
existing "instant save" path: optimistically sets the local ref,
calls `saveNalarConfig({ ..., active_profile: name })`, fires a
success/error notification. Reuses the same composable
(`useNalarConfig.save`) under the hood? No — it calls the raw
`saveNalarConfig` API directly. Same pattern works for the Reset
case.

**Backend's `nalar_config_put.zig:246-252`** already handles
`active_profile: null` correctly (coerces to `config_json.active_profile
= null`, which the `LlmConfig.init` parser turns into a missing
key — same result as a hand-edited config without the field).
So the backend needed NO changes.

**`useNalarConfig` composable** has both `save` (saves the dirty
working copy) and direct `saveNalarConfig` (raw API call). The
existing `setActiveProfile` uses the raw API because it bypasses
the "dirty pill" UX (active profile changes are instant — no
"unsaved changes" indicator). The Reset button follows the same
instant-save path.

## Decision

**Option A (chosen): Add a `Reset` button next to the active pill.**
- Visible only when an active profile is set.
- Click → `clearActiveProfile()` → save `active_profile: undefined`
  to config.json → backend cascade falls through to top-level
  config.

**Option B (rejected): Make "Set active" toggle-able on the active row.**
- The active row's "Set active" button becomes "Deactivate" (or
  shows a toggle state).
- Pros: Reuses existing button.
- Cons: Less discoverable (the user has to scroll to the active
  row to find it). And the active row's name is already styled
  with the violet "active" pill — the affordance is unclear.

**Option C (rejected): Move the active profile controls into a
separate header section.**
- Pros: Cleaner.
- Cons: Bigger UI churn. The header already shows the active
  pill — adding a button next to it is the minimal change.

## Implementation (TDD)

### Step 1: Write tests first (RED)

**`ProfilesSection.spec.ts`** (4 new tests):
1. `Reset button is visible next to the active pill when active is set`
2. `Reset button is hidden when no active profile`
3. `Clicking Reset emits 'clearActive' event`
4. `Set-active button stays hidden on the active row` (regression guard)

**`NalarSettings.spec.ts`** (3 new tests):
1. `Clicking Reset saves active_profile: undefined to config`
2. `Success notification fires after save`
3. `Failed save rolls back the optimistic local update`

Total: 7 new tests, all RED before the fix landed.

### Step 2: Implement the fix

**`ProfilesSection.vue`** (+15 lines):
- Added `clearActive: []` to `defineEmits` (with comment explaining
  the contract).
- Added a `Reset` button (`data-testid="reset-active-btn"`) in the
  header next to the active pill, gated on `v-if="activeProfile"`.
  Tooltip: "Clear active profile — every chat will use the top-level
  config".

**`NalarSettings.vue`** (+24 lines):
- Added `@clear-active="clearActiveProfile"` on the `<ProfilesSection>`
  binding.
- Added `clearActiveProfile()` function: optimistic `activeProfile.value
  = null`, `saveNalarConfig({ ..., active_profile: undefined })`,
  fire success notification. On failure, restore the previous value
  and fire error notification (same pattern as `setActiveProfile`).

### Step 3: Tests pass (GREEN)

```
ProfilesSection.spec.ts: 20/20 pass (+4 new)
NalarSettings.spec.ts:    10/10 pass (+3 new)
```

### Step 4: Build + full suite

- `bun run build` (vue-tsc): clean
- `bunx vitest run` (full suite): 2017 pass / 14 fail. The 14 are
  the pre-existing baseline on `main` (AppLayout.urlPersist ×7,
  AppLayout.memoriesGate ×4, sidebarKanbanSortUrl ×2, DesignView.nudge
  ×1) — unchanged by this commit.

## Wire flow

```
User clicks Reset
  → ProfilesSection emits 'clearActive' (no payload)
  → NalarSettings.clearActiveProfile()
    → optimistic: activeProfile.value = null (UI updates)
    → saveNalarConfig({ ..., active_profile: undefined })
      → PUT /api/config/nalar
        → nalar_config_put.zig: writes config.json with
          active_profile: null (or omits the key)
        → live-reloads the LlmConfig (LlmConfig.active_profile
          becomes null)
    → on success: emit 'notification' (success)
    → on error: restore activeProfile.value = previous; emit
      'notification' (error)
```

The chatview's `effectiveProfile` computed (from PR #205) immediately
sees `activeProfile = null` (after the next `getNalarConfig()`
refresh) and falls back to `selectedProfile ?? 'Default'`. New
chats / tasks now use the top-level config.

## Pitfalls (record for future agents)

- **Optimistic update with rollback.** Setting `activeProfile.value
  = null` before the `saveNalarConfig` call makes the UI feel
  instant. On failure, restore from the captured `previous`
  variable. Same pattern as the existing `setActiveProfile`.

- **`active_profile: undefined` vs `active_profile: null`.** The
  frontend type is `NalarConfig.active_profile?: string` (not
  nullable). Passing `null` triggers a TS2352 type error. Use
  `undefined` and let the spread merge the rest of the config —
  the key is omitted on serialization, which the backend treats
  the same as a missing key (= "no active profile"). Verified
  by the test: `expect('active_profile' in savedConfig ? ... : undefined).toBeUndefined()`.

- **`<button>` inside `<button>` rule.** The Reset button is a
  sibling of the active pill span (both inside the header `<div>`),
  not nested. So no HTML-validity issues.

- **Tooltip on a small button.** The Reset button is 6px tall (h-6)
  with 10px font. The tooltip "Clear active profile — every chat
  will use the top-level config" makes the affordance discoverable
  on hover. Without it, the user sees a tiny "Reset" without context.

## Files

- Modified: `src/apps/desktop/src/components/nalar/ProfilesSection.vue`
  (+15/-0)
- Modified: `src/apps/desktop/src/components/NalarSettings.vue`
  (+24/-0)
- Modified: `src/apps/desktop/src/__tests__/ProfilesSection.spec.ts`
  (+50/-0)
- Modified: `src/apps/desktop/src/__tests__/NalarSettings.spec.ts`
  (+77/-0)
- New: `docs/superpowers/specs/2026-08-06-reset-active-profile-design.md`
- New: `docs/superpowers/plans/2026-08-06-reset-active-profile.md`
  (this file)

## Branch

- Worktree: `worktree/investigate-profile-bug`
- Branch: `worktree/investigate-profile-bug` (pushed to origin)
- Commit: `5b474f73 feat(nalar-settings): Reset button to clear active profile`
- Followed by: docs commits (this PR)

## Follow-ups (out of scope, deferred)

- **Confirmation dialog for Reset.** v1: instant reset (matches the
  instant-save pattern of `setActiveProfile`). A confirmation modal
  would add friction for a single-click action. If a user mis-clicks,
  the cost is one extra click to re-pick the profile.
- **Reset on the chatview chip itself.** The chatview's profile
  picker could also expose a "Use default" option that does the
  same thing. Deferred to a follow-up plan if requested.
- **Bulk reset (clear active + all per-session selections).** Not
  requested. The chatview's `selectProfile(null)` already clears
  the per-session selection; the new Reset button clears the
  global active.
