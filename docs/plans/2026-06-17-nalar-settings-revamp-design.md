# Nalar Settings UI Revamp

**Status:** Approved (brainstorming complete 2026-06-17)
**Owner:** Desktop frontend
**Scope:** `src/apps/desktop/src/components/NalarSettings.vue` (and adjacent files only)

## Goal

Replace the 1306-line monolithic `NalarSettings.vue` with a **4-sub-tab** layout
inside the Nalar pane (`Defaults` / `Profiles` / `Sub-agents` / `MCP Servers`),
backed by a small set of focused sub-components and a single composable that
owns the config state. Commit to a **Kanagawa Dragon, refined-industrial**
aesthetic — paper-like cards, hairline borders, monospace metadata, no
gradients, no drop shadows.

This is a **pure frontend** revamp. The `NalarConfig` shape, the
`getNalarConfig()` / `saveNalarConfig()` / `deleteProfile()` API surface, and
the `useProfileDelete` composable are unchanged.

## Decisions locked during brainstorming

1. **Active profile on Defaults tab is silent** — the Profiles tab is where
   active is managed; Defaults is just the fallback config. No hint banner.
2. **System prompt token count is approximate** — footer line, computed as
   `Math.ceil(words * 1.3)`. No tokenizer dependency.
3. **API key Show toggle** — eye-icon button inside the field (not a checkbox
   above). One per password field, in `LlmConfigForm` and the top-level API
   key field.
4. **Save semantics** — single global Save with a dirty pill in a sticky
   bottom bar. One PUT to `/api/config/nalar` for the whole config. No
   per-tab auto-save.
5. **MCP header value preview** — always-mask with first 3 + last 3 chars
   visible (`abc************xyz`). No click-to-reveal. Reduces accidental
   disclosure in screen-sharing.

## Aesthetic tokens (commit)

| Token | Hex | Use |
|---|---|---|
| `--semantic-content-bg` | `#181616` | Page surface |
| `--semantic-card-bg` | `#1D1C19` | Card / modal surface |
| `--color-border` | `#282727` | Hairline borders, dividers |
| `--color-border-light` | `#393836` | Softer dividers (between rows in a list) |
| `--semantic-text` | `#c5c9c5` | Primary text |
| `--semantic-text-muted` | `#a6a69c` | Labels, helper text |
| `--semantic-text-dim` | `#7a8382` | Section headers (caps), metadata |
| `--color-violet` | `#8992a7` | Active tab underline, primary accent border |
| `--color-red` | `#c4746e` | Destructive actions (border on hover, icon glyph) |

**Do NOT use:** drop shadows, rounded-xl on cards (use `rounded-md` at most),
purple-blue gradients (the current button style), pill-shaped tab nav, large
icons, illustrations.

**Section header style:** monospace caps, e.g. `── DEFAULT LLM ─────────`,
rendered as `<span class="font-mono text-xs uppercase tracking-wider text-[--semantic-text-dim]">…</span>` with a hairline rule below.

**Buttons:**
- Primary: 1 px border in `--color-violet`, transparent fill, text in
  `--color-violet` → on hover: fill `--color-violet`, text `#181616`.
- Secondary (Cancel): 1 px border in `--color-border`, text in
  `--semantic-text-muted` → on hover: fill `--color-border`.
- Destructive: text in `--color-red`, no border by default → on hover: 1 px
  border in `--color-red`.

**Inputs:** height 32 px, 1 px `--color-border` border, transparent fill.
On focus: 1 px `--color-violet` border, no fill change, no glow.

**Motion:** 120 ms ease-out for hover/focus; 180 ms for tab-switch underline
slide. No spring animations.

## IA — 4 sub-tabs inside the Nalar pane

The parent `SettingsView.vue` keeps its 240 px sidebar (Nalar / Skills).
The Nalar pane becomes a vertical stack:

1. **Tab strip** (sticky top): horizontal `Defaults | Profiles | Sub-agents | MCP Servers`, underline-style active indicator.
2. **Scrollable tab content.**
3. **Sticky save bar** (only visible when dirty): `● N unsaved changes  [Reset]  [Save changes]`.

Tab order is by edit frequency: Defaults first, MCP last. Persisted in
`localStorage` key `nalar-settings-active-tab` so the user lands back where
they were.

## File/component breakdown

```
src/apps/desktop/src/components/
├── NalarSettings.vue                    (orchestrator: tab strip + save bar + section switch — ~200 lines)
└── nalar/
    ├── NalarTabStrip.vue                (horizontal tab nav with underline indicator)
    ├── NalarSaveBar.vue                 (sticky bottom bar with dirty count + Reset/Save)
    ├── useNalarConfig.ts                (composable: load / dirty / save / reset; single source of truth)
    ├── useNalarDirty.ts                 (small composable: tracks which fields are dirty across tabs)
    ├── DefaultsSection.vue              (Default LLM + Model Params + System Prompt)
    ├── ProfilesSection.vue              (list + active pill in header)
    ├── SubAgentsSection.vue             (list + 2-line prompt preview with expand)
    ├── McpServersSection.vue            (list + masked header preview)
    ├── EmptyState.vue                   (shared empty state with icon + 1-line + CTA)
    ├── LlmConfigForm.vue                (shared: model / base_url / api_key / thinking / temp / url_style)
    ├── LlmConfigModal.vue               (wraps LlmConfigForm + name field + Cancel/Save + title)
    ├── McpHeadersEditor.vue             (key/value pair editor for MCP)
    ├── ProfileModal.vue                 (wraps LlmConfigModal with profile-specific labels)
    ├── SubAgentModal.vue                (wraps LlmConfigModal + system_prompt field)
    └── McpServerModal.vue               (wraps LlmConfigModal + McpHeadersEditor)
```

The `useProfileDelete` composable (in `composables/useProfileDelete.ts`) is
**unchanged**. The Profiles section consumes it the same way the current
`NalarSettings.vue` does.

`NalarSettings.vue` exposes the same `notification` event and the same
`saveSettings` / `resetSettings` `defineExpose` surface as today, so the
parent `SettingsView.vue` does not need to change.

## Data flow

```
NalarSettings.vue
  ├── useNalarConfig()            // single source of truth: NalarConfig
  │     ├── load()                // getNalarConfig() on mount
  │     ├── dirty (computed)      // true if any field differs from loaded snapshot
  │     ├── unsavedCount (computed)
  │     ├── save()                // saveNalarConfig() + emit('notification', ...)
  │     └── reset()               // restore from snapshot
  │
  ├── NalarTabStrip                // controls which section is shown
  │
  ├── <DefaultsSection v-if=...>   // bound to useNalarConfig().config.* fields
  ├── <ProfilesSection v-if=...>   // bound to useNalarConfig().config.profiles + active_profile
  ├── <SubAgentsSection v-if=...>  // bound to useNalarConfig().config.sub_agents
  ├── <McpServersSection v-if=...> // bound to useNalarConfig().config.mcp_servers
  │
  └── NalarSaveBar                 // shown when dirty
```

Each section receives a `v-model` (or `v-model:field`) for the slice of
config it owns. The composable tracks the original snapshot and computes
`dirty` reactively.

## Save flow

1. User edits any field anywhere in any tab.
2. `useNalarConfig` updates the in-memory `config` and bumps `dirty = true`.
3. `NalarSaveBar` slides in from the bottom (180 ms) showing `● N unsaved changes`.
4. User clicks **Save**:
   - `useNalarConfig.save()` calls `saveNalarConfig(config)`.
   - On success: update the snapshot, set `dirty = false`, emit `notification` with `Settings saved` (success), slide save bar out.
   - On failure: emit `notification` with the error message (error), keep `dirty = true`.
5. User clicks **Reset**:
   - `useNalarConfig.reset()` restores from snapshot, sets `dirty = false`, slides save bar out. No notification.

`Set active` on a profile row is an **instant** action (no save) — it writes
to `config.json` via the same `saveNalarConfig` call directly and shows a
brief toast. This is the only exception to "edit → dirty → save".

## Modal pattern (shared)

All three add/edit flows (profile, sub-agent, MCP) share `LlmConfigModal`
which wraps `LlmConfigForm`. The form has the LLM fields; each wrapper
adds its specific extras:

- **ProfileModal**: adds a `name` field at the top, no extras at the bottom.
- **SubAgentModal**: adds a `name` field at the top, a `system_prompt`
  textarea at the bottom.
- **McpServerModal**: adds a `name` field at the top, an `McpHeadersEditor`
  block at the bottom.

Validation is field-level, surfaced as red helper text under the field
(text in `--color-red`). No top-of-modal alerts.

Required fields: `name`, `model`. Optional but validated for format:
`base_url` (URL syntax), `api_key` (non-empty for active config), `url`
(URL syntax, MCP only).

## Empty states

All three list sections share a single `EmptyState.vue`:

```
┌──────────────────────────────────────────────┐
│  ⌗  No profiles yet                          │
│                                              │
│  Profiles are saved LLM configurations you   │
│  can switch between with one click.          │
│                                              │
│  [ + Add profile ]                           │
└──────────────────────────────────────────────┘
```

The icon glyph (`⌗` / `◌` / `◇`) is a monospace character, not an SVG — keeps
the file size down and matches the refined-industrial feel.

## Behaviors that are unchanged

- The `useProfileDelete` composable (optimistic update + rollback + toast).
- The `ConfirmDialog` flow for delete.
- The `notification` event signature.
- The `defineExpose({ saveSettings, resetSettings })` API.
- The `localStorage` keys (the fallback path is preserved for users who
  can't reach the API).
- The `saveNalarConfig` payload shape (snake_case, full-object PUT).
- The semantic CSS variables (no new tokens introduced).

## Test plan

Add vitest specs under `src/apps/desktop/src/__tests__/`:

- `useNalarConfig.spec.ts` — load / dirty / save / reset / unsavedCount
  (parallels `useProfileDelete.spec.ts`).
- `NalarTabStrip.spec.ts` — tab switch, persistence, active underline.
- `NalarSaveBar.spec.ts` — renders when dirty, hidden when clean, Reset / Save
  buttons call the right methods.
- `LlmConfigForm.spec.ts` — Show / hide toggle on API key, thinking /
  temperature / url_style selects, validation messages.
- `DefaultsSection.spec.ts` — temperature slider range, token count updates
  on system prompt change.
- `ProfilesSection.spec.ts` — Set active calls save and emits toast;
  delete wires through `useProfileDelete`.
- `McpServersSection.spec.ts` — masked header preview format (`abc***xyz`).

## Out of scope

- Backend changes (the `NalarConfig` schema is unchanged).
- Migrating to Pinia (the composable approach is enough; the orchestrator
  already needs to be in a single component to read from the snapshot).
- A search/command palette (would be nice, separate plan).
- Light theme (Kanagawa is dark-only; the project has no light theme).
- A11y beyond what comes for free with semantic HTML + focus-visible
  outlines. No full WCAG audit.
- Per-tab save or auto-save (explicit single Save is the chosen model).
- Bulk import/export of `config.json` (separate plan).
- Profile "duplicate" action (separate plan).
- Per-profile sub-agents inline editor (they still live in
  LlmConfigForm's `sub_agents` field; the section's UI does not change).
