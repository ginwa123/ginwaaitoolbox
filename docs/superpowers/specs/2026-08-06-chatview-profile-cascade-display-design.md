# ChatView profile chip — cascade display

**Date:** 2026-08-06
**Branch:** `worktree/investigate-profile-bug`
**Bug report:** task_1786029998152 (kanban: "profile actvie bugs")

## Problem

The chatview's status bar chip displays the chat's currently selected LLM
profile. Pre-fix behaviour: when the user had not picked a per-session profile
via the chip's dropdown, the chip showed the literal string `Default` with
tooltip `Using default (top-level config)`.

This label was misleading: the backend's `resolveProfileField` cascade
(`workflow.zig:209-237`) actually applies a three-level fallback:

1. `params.selected_profile_model` (per-session, when non-empty AND profile
   exists)
2. `config.active_profile` (NalarSettings "Set active" default, when
   non-null AND non-empty AND profile exists)
3. `config.model` / `api_key` / `base_url` / `url_style` (top-level fallback)

The chip only showed step 1. When the user had set "300 ribu" as the active
profile in NalarSettings but never picked one per-session, the chatview said
"Default" — making the user believe the top-level config was in use, when
"300 ribu" was actually being applied. This was a UX failure, not a backend
failure.

## Why the user couldn't observe the cascade working

In the user's specific config, both profiles (`300 ribu`, `900ribu`) and
the top-level config used the same `model` (`MiniMax-M3`) and the same
`base_url` (`https://api.minimax.io/v1`). The only field that differed
across layers was `api_key` (300 ribu + top-level shared one key;
900ribu used a different one). So:

- New session with empty `selected_profile_model` → backend logs:
  `effective_model=MiniMax-M3 effective_base_url=...` (looks like top-level
  output, because the values are the same)
- User sees "Default" in the chip → "but I set 300 ribu as active!" → bug
  report

If the user had given `300 ribu` a *different* `model` (e.g. `M3-mini`),
the chat would have visibly used `M3-mini` — but the chip would still
show "Default". The label was the bug.

## Design

### Behavioural matrix (chip text + tooltip)

| `selectedProfile` | `activeProfile` | Chip text  | Tooltip                              | Picker ✓    |
|-------------------|-----------------|------------|--------------------------------------|-------------|
| `'300 ribu'`      | `'900ribu'`     | `300 ribu` | `Using profile: 300 ribu`           | on `300 ribu` row |
| `''` (empty)      | `'300 ribu'`    | `300 ribu` | `Using active profile: 300 ribu`    | on `300 ribu` row (no per-session) |
| `null`            | `'300 ribu'`    | `300 ribu` | `Using active profile: 300 ribu`    | on `300 ribu` row |
| `null`            | `null`          | `Default`  | `Using default (top-level config)`  | on `Default (top-level config)` row |
| (no profiles configured) | `null`   | `Default`  | `Using default (top-level config)`  | n/a — no rows |

The `(active)` violet badge appears next to whichever row is
`activeProfile`. It's independent of the ✓ (which is keyed to
`effectiveProfile`).

### User's stated rule (verbatim, message 2026-08-06):

> "if chat session is not created, default is active, if chat session
> is already created that mean it will be select the profile base on
> chat session created before"

Translation: no per-session row → show the active profile; a row exists
with `selected_profile_model` set → use it (overrides active).

### Why `||` and not `??` for the fallback

The session wire shape carries `selected_profile_model` as a *string*,
not nullable. An unset value arrives as `''` (empty string) via
`api.getSession.selectedProfile`. `??` only catches `null` / `undefined`,
so a fresh session that has never been touched would slip past it and
show empty chip text. `||` catches both `null`/`undefined` AND empty
string, matching the backend's `selected_profile_model.len > 0` guard
in `resolveProfileField:217`.

## Implementation

### `ChatView.vue::loadProfiles`

Now also reads `config.active_profile` (was: profiles only). The active
profile is stored in a new `activeProfile` ref. Empty string from the
wire is coerced to `null` (matches the backend's PUT coercion in
`nalar_config_put.zig:246-252`).

### `ChatView.vue::effectiveProfile` (new computed)

```ts
const effectiveProfile = computed<string | null>(() => {
  const sel = selectedProfile.value
  if (sel && sel.length > 0) return sel
  return activeProfile.value
})
```

### `ChatView.vue::profileChipTooltip` (new computed)

```ts
const profileChipTooltip = computed(() => {
  const sel = selectedProfile.value
  if (sel && sel.length > 0) return `Using profile: ${sel}`
  if (activeProfile.value) return `Using active profile: ${activeProfile.value}`
  return 'Using default (top-level config)'
})
```

### Template changes

- Chip text: `{{ selectedProfile ?? 'Default' }}` →
  `{{ effectiveProfile ?? 'Default' }}`
- Chip title: inline ternary → `:title="profileChipTooltip"`
- Picker default row: `v-if="!selectedProfile"` →
  `v-if="!selectedProfile && !activeProfile"` (so ✓ is on the
  Default row only when no active profile is set)
- Picker profile rows: add `(active)` badge when
  `activeProfile === p.name`; ✓ when `effectiveProfile === p.name`
  (was: `selectedProfile === p.name`)
- Add `data-testid="profile-picker-${p.name}"` to each row for
  testability
- Add `data-testid="profile-picker-default"` to the Default row
- Add `data-testid="profile-picker-active-badge"` to the (active)
  span

## Out of scope

- **Per-call mixing of profiles** — the user can't currently set the
  active profile to differ per call. The chip just shows the cascade.
- **Backend change to `sessions.selected_profile_model`** — no
  schema or wire change. The per-session field is already persisted
  (commit `27e48e97` "fix(profile): chatview profile persists across
  page refresh"). We're only fixing the chip's display.
- **The two related backend bugs flagged in the investigation**:
  - `workflow.zig:1076` passes `config.api_key, config.base_url`
    instead of `effective_api_key, effective_base_url` to
    `handle_tool`. Most tools don't use these directly, but
    `spawn_sub_agent` does. (No observable impact for this user —
    their profiles' api_key and the top-level api_key are
    effectively the same.)
  - `spawn_sub_agent.zig:334` only checks the per-session
    `selected_profile_model` for sub-agent lookup, not the active
    profile. (User's profiles have 0 sub_agents, so no impact.)
  - Both deferred to follow-up plans per the user's "out of scope"
    discussion in the investigation.

## Verification

- `bun run build` (vue-tsc --build): clean
- `bunx vitest run src/__tests__/ChatView.profileCascade.spec.ts`:
  7/7 pass
- `bunx vitest run src/__tests__/ChatView.stopSession.spec.ts` (existing
  ChatView test): 5/5 pass — no regression
- `bunx vitest run` (full suite): 2010 pass / 14 fail. The 14 are
  the documented pre-existing baseline on `main`
  (AppLayout.urlPersist ×7, AppLayout.memoriesGate ×4,
  sidebarKanbanSortUrl ×2, DesignView.nudge ×1) — unrelated.

## Files

- Modified: `src/apps/desktop/src/components/views/ChatView.vue`
  (+62/-13)
- New: `src/apps/desktop/src/__tests__/ChatView.profileCascade.spec.ts`
  (+336)

## Tests

7 new behavioural tests in `ChatView.profileCascade.spec.ts`:

1. Shows the active profile when no chat session has been opened yet
   (active = default).
2. Shows the active profile when session has empty
   `selected_profile_model` (cascade falls through).
3. Shows the per-session `selected_profile_model` when it is set
   (overrides active).
4. Shows "Default" only when neither per-session nor active is set.
5. Shows "Default" when no profiles are configured at all.
6. Renders `(active)` badge next to the active profile in the picker.
7. Puts ✓ on the effective profile row (selected > active > none).

All 7 pass.
