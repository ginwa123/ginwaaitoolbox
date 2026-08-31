# Kanban Tools UI — fix broken checkbox + redesign (2026-08-28)

## What landed
The Kanban settings **🛠 Tools** tab now lets the user actually enable tools (previously the
checklist silently no-op'd when the board had no `agent_kanbans` row), and the UI got a
proper polish pass — search filter, live "X / Y enabled" summary chip, per-tool description,
gradient highlight when enabled, and a one-click "Use recommended starter set" preset that
bootstraps the config.

## The bug
`KanbanToolsPanel.vue` (pre-fix, line 90):
```ts
const handleToggleTool = async (toolName: string) => {
  if (!config.value || toolBusy.value) return   // ← blocks unconfigured boards
  ...
}
```
The board in the screenshot is **unconfigured** (no `agent_kanbans` row yet), so every click
returned early — checkbox ticked, nothing happened, no error, no row created. The backend
already auto-seeds the row on first enable
(`src/ai_workflow/tui/http_handlers/agent_kanban_tools_create.zig:120-123`,
`INSERT OR IGNORE INTO agent_kanbans (id, workspace_item_id) VALUES (?, ?)`), so the
frontend just needed to let the click through.

## The fix (KanbanToolsPanel.vue)
1. **Dropped the `!config.value` guard** — `handleToggleTool` now uses
   `effectiveKanbanId()` (returns `props.item.id`, NOT `config.value.id`) so the first
   enable from the unconfigured state still hits the backend with the workspace_item id
   the backend's `INSERT OR IGNORE` expects.
2. **Post-enable refetch** — after a successful enable from the unconfigured state, the
   panel re-fetches the bundle so `config` gets populated and the unconfigured banner
   disappears without a page reload.
3. **Optimistic UI preserved** — local `tools.value` flips first, POST happens, revert on
   failure. No change to the existing UX once the board IS configured.

## The redesign (single file — `KanbanToolsPanel.vue`)
Everything below replaces the previous flat 2-col checkbox grid.

### Header (sticky to top of panel)
- Title: 🛠 **Available tools**
- Summary chip on the right: **"X / Y enabled"** — gradient + accent border when X>0,
  muted outline when X=0. Splits `enabled` and `total` into separate `<span>`s so tests
  can read each side independently.
- Search input below: `type="search"`, full-width, `data-testid="kanban-tools-search"`.
  Filters live by case-insensitive substring match on **name OR description**.

### Body
- **Unconfigured banner** — when no `agent_kanbans` row exists, shows a 💡 callout:
  "Tick the first tool below to create one — Knowledge & System Prompts unlock once
  you've started." Visually distinct from the configured body (dashed border, dim
  background).
- **Tool cards** — each tool is a `<button>` (not a `<label>` wrapping a native input) so
  we own the visual state end-to-end:
  - **Custom checkbox square** (16×16, gradient violet→blue when checked, outlined
    light gray when unchecked) with a hand-drawn checkmark SVG.
  - **Hidden `<input type="checkbox" class="sr-only">`** carries the legacy
    `kanban-agent-tool-check-${name}` data-testid so existing tests still work — but the
    user-facing click target is the wrapping button.
  - **Tool name** (font-medium) + **2-line description** (line-clamp-2, dim text).
  - **Background tint when enabled**: linear-gradient violet/blue at 14% opacity,
    saturated border, subtle box-shadow drop. Disabled state: dim background, gray
    border.
- **Empty states** — three of them, mutually exclusive:
  - `kanban-tools-loading` — first load before registry lands.
  - `kanban-agent-tools-empty` — registry failed silently + no cache.
  - `kanban-tools-empty` — search filter matched nothing; shows the query back to the
    user.

### Footer preset
- **"✨ Use recommended starter set"** button — visible ONLY when `enabledCount === 0`
  AND the registry has loaded. Sends parallel POSTs for `bash`, `read_file`, `write_file`
  (curated, safe-by-default), per-tool revert on failure (one bad POST doesn't drop the
  rest), then refetches the bundle to populate `config`. Single-click bootstrap of an
  empty board.

## Data-testid contract (unchanged)
All existing test selectors kept working:
- `kanban-tools-panel`, `kanban-tools-unconfigured`, `kanban-tools-loading`,
  `kanban-tools-error`, `kanban-tools-mutation-error`
- `kanban-agent-tools-panel`, `kanban-agent-tools-empty`
- `kanban-agent-tool-${name}` (per-tool wrapper, now a `<button>` instead of `<label>`)
- `kanban-agent-tool-check-${name}` (hidden checkbox — still queryable for `.checked`)

**New** selectors added:
- `kanban-tools-search` — the search input
- `kanban-tools-summary` (with `kanban-tools-summary-enabled` + `kanban-tools-summary-total` spans)
- `kanban-tools-preset-row` + `kanban-tools-preset-recommended` — the preset CTA
- `kanban-tools-empty` — search zero-match hint

## Verification
| Layer                  | Result                                                  |
|------------------------|---------------------------------------------------------|
| `vue-tsc --noEmit`     | clean — no type errors                                  |
| `vitest` KanbanToolsPanel | **12/12 pass** (was 6/6) — +6 new bootstrap/search/preset tests |
| `vitest` KanbanKnowledgePanel | 9/9 pass — no regression                          |
| `vitest` KanbanSettingsView   | 20/20 pass — no regression                        |
| Full `npm run test:unit` | **2751/2751 pass** across 292 files — no regressions   |
| `npm run build`         | succeeds in 1.23 s                                     |

## Files
- **EDIT** `src/apps/desktop/src/components/views/KanbanToolsPanel.vue` — fix bug + full UI
  redesign (458 lines, was 225).
- **EDIT** `src/apps/desktop/src/__tests__/KanbanToolsPanel.spec.ts` — +6 tests for the
  bootstrap flow, search filter, and recommended-set preset.

## Not changed
- Backend — zero changes. `agent_kanbans` row auto-seeding in
  `agent_kanban_tools_create.zig` is already correct; this PR just makes the frontend
  actually call it.
- `KanbanKnowledgePanel.vue`, `KanbanSettingsView.vue` — the parent page + sibling
  panel are untouched.
- No new dependencies, no migration, no schema change, no API shape change.

## Branch / task
- Branch: `worktree/kanban-tools-ui`
- Task: `task_1787915827700_0` (kanban card `kanbang settings tools`)
- 2 commits, atomic per-file: test-first → impl.
