# PabrikSettings Reset button for active profile — design

**Date:** 2026-08-06
**Branch:** `worktree/investigate-profile-bug`
**Plan:** `docs/superpowers/plans/2026-08-06-reset-active-profile.md`
**User request:** "in settings app i think we need to have button to reset select profile to goback on the default"

## Problem

After PR #205 (chatview profile cascade display), the chatview chip
correctly reflects the active profile cascade. But the PabrikSettings
→ Profiles tab only had a "Set active" button on each profile row.
Once a profile was marked active, the user had no UI path to UNSET
the active profile (back to "no active profile" — cascade falls
through to top-level config).

The only ways to clear the active profile before this PR:
- Set a different profile active (which the user might not want).
- Hand-edit `~/.config/pabrik/config.json` to remove the `active_profile`
  key.

The user wanted a one-click reset from the UI.

## Behavioural matrix

| State                                         | Reset button visible? | Click behaviour |
|-----------------------------------------------|----------------------|-----------------|
| No active profile (`activeProfile = null`)    | NO                  | n/a              |
| Active = "work"                               | YES                 | Optimistic `activeProfile = null`, save `active_profile: undefined` to config. Backend cascade falls through to top-level. |
| Save fails                                    | (mid-action)        | Restore `activeProfile` to previous value, fire error notification. |
| Save succeeds                                 | (mid-action)        | Fire success notification. UI shows the `(none — pick one below)` italic. |

## Visual design

Before (active = "300 ribu"):

```
┌──────────────────────────────────────────────────────┐
│ Active [300 ribu]                       [+ Add profile]│
├──────────────────────────────────────────────────────┤
│ ▶ 900ribu                                            │
│   MiniMax-M3 · https://api.minimax.io/v1              │
│   · inherits top-level sub-agents                    │
│   Compaction: 96% @ 500k tokens        [Set active]  │
├──────────────────────────────────────────────────────┤
│ ▶ • 300 ribu  active                                │
│   MiniMax-M3 · https://api.minimax.io/v1              │
│   · inherits top-level sub-agents                    │
│   Compaction: 95% @ 500k tokens                [Edit]  │
└──────────────────────────────────────────────────────┘
```

After (with Reset button):

```
┌──────────────────────────────────────────────────────┐
│ Active [300 ribu]  [Reset]             [+ Add profile]│
├──────────────────────────────────────────────────────┤
│ ▶ 900ribu                                            │
│   MiniMax-M3 · https://api.minimax.io/v1              │
│   · inherits top-level sub-agents                    │
│   Compaction: 96% @ 500k tokens        [Set active]  │
├──────────────────────────────────────────────────────┤
│ ▶ • 300 ribu  active                                │
│   MiniMax-M3 · https://api.minimax.io/v1              │
│   · inherits top-level sub-agents                    │
│   Compaction: 95% @ 500k tokens                [Edit]  │
└──────────────────────────────────────────────────────┘
```

After clicking Reset:

```
┌──────────────────────────────────────────────────────┐
│ Active (none — pick one below)         [+ Add profile]│
├──────────────────────────────────────────────────────┤
│ ▶ 900ribu                                            │
│   MiniMax-M3 · https://api.minimax.io/v1              │
│   · inherits top-level sub-agents        [Set active]  │
├──────────────────────────────────────────────────────┤
│ ▶ • 300 ribu                                        │
│   MiniMax-M3 · https://api.minimax.io/v1              │
│   · inherits top-level sub-agents        [Set active]  │
│   Compaction: 95% @ 500k tokens                [Edit]  │
└──────────────────────────────────────────────────────┘
```

A green toast (existing notification system) appears: "Active profile
cleared — using top-level config".

## Button design

```html
<button
  v-if="activeProfile"
  type="button"
  data-testid="reset-active-btn"
  title="Clear active profile — every chat will use the top-level config"
  @click="emit('clearActive')"
  class="px-2 h-6 rounded-md text-[10px] font-mono border transition-colors duration-150 hover:opacity-80"
  style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
>Reset</button>
```

- 6px tall (matches the active pill height — same row)
- 10px font, italic-by-default mono (matches the active pill style)
- Subtle border + muted text colour (de-emphasised vs the
  violet-themed `Set active` and `+ Add profile` actions)
- `hover:opacity-80` to confirm hover state
- `v-if="activeProfile"` so the button is invisible when no active
  is set (no clutter for users who never set one)

## Wire flow

```
User clicks Reset
  → ProfilesSection.vue emits 'clearActive' (no payload)
  → PabrikSettings.vue's @clear-active handler: clearActiveProfile()
    1. optimistic: activeProfile.value = null (UI updates)
    2. savePabrikConfig({ ..., active_profile: undefined })
       → PUT /api/config/pabrik
         → pabrik_config_put.zig: writes config.json with
           active_profile: null (or omits the key, same result)
         → live-reloads LlmConfigHolder
    3. on success: emit 'notification' (success message)
       on error: activeProfile.value = previous (rollback)
                  emit 'notification' (error message)
```

The chatview's `effectiveProfile` computed (from PR #205) sees
`activeProfile = null` on the next `getPabrikConfig()` refresh and
falls back to the per-session `selectedProfile` (or top-level if
that's also empty).

## Why `undefined` not `null` for the wire payload

The `PabrikConfig` TypeScript type declares:

```ts
interface PabrikConfig {
  // ...
  active_profile?: string;  // not nullable
  // ...
}
```

`savePabrikConfig({ ..., active_profile: null })` triggers a TS2352
type error: "Type 'null' is not comparable to type 'string | undefined'".

Using `undefined` omits the key on JSON serialization, which the
backend's `pabrik_config_put.zig:246-252` handler treats identically
to `null` (both paths write `config_json.active_profile = null`).
Verified by the test:

```ts
expect('active_profile' in savedConfig ? savedConfig.active_profile : undefined).toBeUndefined()
```

## Out of scope (deferred)

- **Confirmation dialog before Reset.** v1: instant reset (matches
  the existing instant-save pattern of `setActiveProfile`). The
  user can re-pick the profile with one extra click. Adding a
  confirmation modal for a single-button action is over-engineering.
- **Reset on the chatview chip itself.** The chatview's profile
  picker could also expose a "Use default" option. Not in this
  PR — would be a separate plan if requested.
- **Bulk reset (clear active + all per-session selections).** Not
  requested. Each per-session selection is independent and the
  user can clear them via the chatview picker.

## Verification

- `bun run build` (vue-tsc): clean
- `bunx vitest run src/__tests__/ProfilesSection.spec.ts`: 20/20
  pass (+4 new Reset tests)
- `bunx vitest run src/__tests__/PabrikSettings.spec.ts`: 10/10
  pass (+3 new wiring tests)
- `bunx vitest run` (full suite): 2017 pass / 14 fail. The 14
  are the pre-existing baseline on `main` (AppLayout.urlPersist ×7,
  AppLayout.memoriesGate ×4, sidebarKanbanSortUrl ×2, DesignView.nudge
  ×1) — unrelated to this change.

## Files

- Modified: `src/apps/desktop/src/components/pabrik/ProfilesSection.vue`
  (+15)
- Modified: `src/apps/desktop/src/components/PabrikSettings.vue` (+24)
- Modified: `src/apps/desktop/src/__tests__/ProfilesSection.spec.ts` (+50)
- Modified: `src/apps/desktop/src/__tests__/PabrikSettings.spec.ts` (+77)
- New: `docs/superpowers/plans/2026-08-06-reset-active-profile.md`
- New: `docs/superpowers/specs/2026-08-06-reset-active-profile-design.md`

## Branch

- Worktree: `worktree/investigate-profile-bug`
- Branch: `worktree/investigate-profile-bug` (pushed to origin)
- Commits: `5b474f73` (fix) + docs (this PR)
