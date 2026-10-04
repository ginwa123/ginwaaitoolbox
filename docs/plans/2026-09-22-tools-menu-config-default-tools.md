# Plan: Tools menu — config.json default tool checklist

Date: 2026-09-22
Task: `new menu name tools` (task_1790096028573_1)
Worktree: `/home/ginwa/.config/pabrik/.worktrees/new-menu-name-tools-1790096026633`
Status: planning — for human review before any implementation

Wireframe: [`docs/plans/2026-09-22-tools-menu-wireframe.html`](./2026-09-22-tools-menu-wireframe.html)

## 1. Goal

Add a **Tools** tab in Pabrik Settings, beside **MCP Servers**
(`General | Profiles | MCP Servers | Tools`). `config.json` gains a
top-level array `"tools": ["read_file", …]` — the **default tool
checklist** the agent uses:

- **agent mode** and **kanban mode** — seeds the per-item tool rows at creation time,
- **design mode** and **non-all (plain chat) mode** — the runtime default when no per-mode source applies.

The frontend renders the array as a checkbox list built from the real
tool registry (name + description), riding the existing Settings
save bar / `PUT /api/config/pabrik`.

Scope: planning + wireframe only in this task. No implementation until
the human approves.

## 2. Current state (verified against source)

### 2.1 Settings tabs (frontend)

- Tab strip: `src/apps/desktop/src/components/pabrik/PabrikTabStrip.vue:6,25-30`
  — `type TabId = 'general'|'profiles'|'mcp'` + literal `tabs` array.
- Orchestrator: `src/apps/desktop/src/components/PabrikSettings.vue:53`
  (`type Tab`), `:593` (`<PabrikTabStrip v-model="activeTab" />`),
  MCP list state `:100`, hydrate `:144`, serialize via `syncToConfig()`
  `:175-203`, deep watch `:230-240`, section mount `:658-666`.
- Save flow: `composables/usePabrikConfig.ts` (snapshot-diff `dirty`) →
  sticky `PabrikSaveBar` (mounted `PabrikSettings.vue:690-697`) →
  `PUT /api/config/pabrik` with the **whole config object**
  (`api/index.ts:4238-4244`). Load: `GET /api/config/pabrik` (`:4230`).
- ⚠️ Active tab is **not URL-synced** today — it lives in
  `localStorage['pabrik-settings-active-tab']`
  (`PabrikTabStrip.vue:8,34-43`), violating the repo's
  "every view switch must update the browser URL" rule.
  Canonical pattern to copy: `KanbanSettingsView.vue:68-105`
  (`?section=` computed + `router.replace`). Query key **must be
  `section`, never `tab`** — `?tab=` is owned by browser tab-mode
  (`helpers/tabTarget.ts:281-293`, `stores/tabs.ts:437`).
- Reusable primitives (no Toggle/Checkbox component exists — copy the
  inline patterns): checkbox row `PabrikGeneralSection.vue:118-133`,
  pill toggle `McpServersSection.vue:84-97`, `+ Add`-style button
  `McpServersSection.vue:36-41`, `EmptyState.vue`, `ConfirmDialog.vue`,
  section header `PabrikGeneralSection.vue:100-106`. Palette/tokens in
  `style.css:4-77`; Tailwind utilities + inline `var(…)` colors; no i18n.
- Tool catalog endpoint **already exists**: `GET /api/agent-tools/registry`
  → `[{name, description}]` (`src/http_handlers/agent_tools_registry.zig:60`,
  route `main.zig:698`, store `stores/agentTools.ts`).

### 2.2 config.json (backend)

- Path: `$HOME/.config/pabrik/config.json` (Linux; `Config.zig:2445-2482`).
- Parse struct `LlmConfigJson` (`Config.zig:291-341`) — every field has
  a default, `ignore_unknown_fields = true`.
- Endpoints (merge semantics — read file, apply only fields present in body):
  | Route | Handler | Structs to touch |
  |---|---|---|
  | `GET /api/config/pabrik` | `pabrik_config_get.zig:12` | read `ConfigJson` `:114`, response `PabrikConfigResponse` (`http_response.zig:356`) |
  | `PUT /api/config/pabrik` | `pabrik_config_put.zig:27` | `ConfigInput` `:494`, write-struct `ConfigJson` `:610` |
- ⚠️ **PUT strips undeclared keys**: it re-serializes from its own
  write-struct, so any field missing there is erased from disk on the
  next Settings save. Adding `tools` must touch **all four** structs
  (`LlmConfigJson`, GET read+response, PUT input+write) or the feature
  silently self-destructs. (Precedent: `user_identifier` is already
  parsed but never round-tripped.)
- No config versioning — new keys behave via struct defaulting.
  Absent key → default, tolerated everywhere.

### 2.3 Tool registry & per-mode defaults (backend)

- Registry: `src/agentic_loop/tools_equipped.zig` — `equips()` (`:75-143`,
  the LLM offer list) and `UNIFIED_TOOL_REGISTRY()` (`:149-276`,
  dispatch + validation source). Full inventory (~40 tools): file/shell
  (`command, read_file, write_file, text_replace, remove_file,
  list_directory, glob, search`), planning (`update_plan, get_plan`),
  memory (`save_memory, load_memory, read_workspace_session`), skills
  (`list_skills, use_skill, add_skill, edit_skill, remove_skill`),
  sub-agents (`spawn_sub_agent, list_sub_agent`), interactive
  (`ask_user`), progressive search (`search_tool, view_tool, use_tool`),
  git (`set_git_worktree, set_pull_request`), kanban
  (`kanban_list, kanban_move_task, create_kanban_task`), design
  (`set_design_page, add_element, update_element, group_elements,
  set_element_parent, move_design_element, move_element_to_page,
  get_design_context, preview_design_page`), presentation
  (`present_files, generate_image`), MCP mgmt (`add_mcp_server`).
- Creation defaults: `DEFAULT_AGENT_TOOLS` (25 names, `:291-337`),
  `DEFAULT_KANBAN_TOOLS` (`kanban_list, kanban_move_task`, `:339-342`);
  seeded only by `workspace_items_create_agent.zig:148` and
  `workspace_items_create_kanban.zig:174`.
- Runtime decision chain, `workflow.zig:600-634` (per run, sub-agents
  excluded): `allowed_tools` from request body →
  `maybeOverrideAllowedToolsForAgent` (`:2394`, reads `agent_tools` rows)
  → `…ForKanban` (`:2474`, reads `agent_kanban_tools`, zero-enabled =
  "not configured" → falls through, D5) → `…ForRoutine` (`:2547`)
  → **nothing — design & plain chat fall through to the request body**.
- Plain chat request body hardcodes `DEFAULT_CHAT_TOOLS`
  (`api/index.ts:1485-1500`, sent `:1525`); design mode rides the same
  path (its design tools are **not** on the wire today — known gap).
- Sentinel wart: `""` = *no filtering → all tools*
  (`tool_eligibility.zig:76-83`, `workflow.zig:2089`) although the
  agent-mode spec says zero enabled rows ⇒ *zero* tools
  (`docs/superpowers/specs/2026-08-15-agent-mode-design.md:22`).
- Hard invariants (not configurable): sub-agent strip of
  `MAIN_AGENT_ONLY_NAMES` (`spawn_sub_agent`, `ask_user`),
  progressive `search/view/use_tool` injection regardless of allowlist
  (`workflow.zig:2152-2166`), MCP tools gated by server `enabled` +
  per-session equip.
- `config.json` has **no** tools field today — this is net-new surface.

## 3. Design decisions (need human sign-off)

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Schema shape | (a) flat `"tools": [name…]` — one default list for all four modes; (b) per-mode `"tools": {agent:[], kanban:[], design:[], chat:[]}` | **(a) flat** — matches the task wording ("array_list name tools"); one checklist in the UI; per-mode divergence already comes from mode floors + item-type rules. Per-mode can be added later additively as `tools_by_mode` without breaking (a). |
| D2 | Key absent vs empty | (a) absent → built-in defaults, `[]` → zero defaults; (b) absent and `[]` both → built-in defaults | **(a)** — an all-unchecked checklist must not silently snap back to 25 defaults; the UI would lie. Requires D3. |
| D3 | Zero-tools representation | (a) add explicit `"none"` sentinel handled in `allowlistFilter` + make agent zero-enabled-rows emit it (aligns runtime with the 2026-08-15 spec, changes behavior when a user disables every row); (b) leave the `"" = all` wart and document empty config as "falls through" | **(a)** — currently an agent with *all* rows disabled silently gets *every* tool; that is a security-flavored contradiction of the spec. Flagged because it changes runtime behavior. |
| D4 | Retroactivity | (a) config seeds **new** items only; existing per-item checklists win; (b) live-override everything | **(a)** — per-item panels (`agent_tools` / `agent_kanban_tools` rows, KanbanToolsPanel) stay meaningful; no surprise rewrites on Save. |
| D5 | Tab URL sync | (a) implement `?section=` for all four tabs now (fixes the pre-existing gap); (b) ship Tools with localStorage only | **(a)** — repo rule; pattern proven in `KanbanSettingsView.vue:68-105`. |

## 4. Data model & semantics (assuming D1/D2/D3/D4)

```jsonc
// config.json
{
  "tools": ["command", "read_file", "write_file", "ask_user", …]  // omitted key = built-in defaults
}
```

| State | agent / kanban (seed) | design / plain chat (runtime) |
|---|---|---|
| key absent | today's `DEFAULT_AGENT_TOOLS` / `+ DEFAULT_KANBAN_TOOLS` | today's behavior (request body `DEFAULT_CHAT_TOOLS`) |
| non-empty array | seed = validated(config) (kanban: `∪ DEFAULT_KANBAN_TOOLS` as mode floor) | `maybeOverrideAllowedToolsForConfigDefault` supplies CSV |
| `[]` | seed zero rows → D3 `none` sentinel → zero tools | override supplies `none` → zero tools |

Validation: each name must exist in `UNIFIED_TOOL_REGISTRY()` —
`PUT` rejects unknown names (400 `InvalidToolName`, precedent
`agent_tools_create.zig:81`); the load path stays tolerant (unknown
names are already ignored by `allowlistFilter`). Built-ins only — MCP
tools keep their own `mcp_<server>_<tool>` + equip mechanism.

Application order (extends the chain at `workflow.zig:600-634`):

```
request-body allowed_tools
  → agent rows → kanban rows → routine rows   (existing, unchanged)
  → config.tools default     (NEW — catches design + plain chat + zero-configured fallthroughs)
  → hard rules: sub-agent main-only strip, progressive injection, item-type prompt strip (unchanged)
```

## 5. Backend changes

1. **Structs** (all four, or PUT erases the key):
   - `Config.zig:291` `LlmConfigJson`: `tools: ?[]const []const u8 = null`
     (typed — consistent with existing typed fields; `?std.json.Value`
     is the tolerant alternative but pushes re-parsing into every consumer).
   - `pabrik_config_get.zig:114` read struct + `http_response.zig:356`
     `PabrikConfigResponse`: `tools: ?[]const []const u8 = null`.
   - `pabrik_config_put.zig:494` `ConfigInput` + `:610` write struct:
     optional = "no change", present = whole-list replace (mirrors
     `mcp_servers` semantics `:342-363`); validate names → 400
     `InvalidToolName`.
2. **Seeds** (`tools_equipped.zig:347,369` + call sites
   `workspace_items_create_agent.zig:148`,
   `workspace_items_create_kanban.zig:174`): accept an optional
   config-derived list; kanban keeps `∪ DEFAULT_KANBAN_TOOLS` floor;
   empty config seeds zero rows (D2/D3).
3. **Runtime fallback**: new `maybeOverrideAllowedToolsForConfigDefault`
   appended after routine in the `workflow.zig:600-634` chain, inside
   the existing `!params.is_sub_agent` guard; reads `tools` from the
   already-threaded config singleton; absent → no-op (falls through as
   today).
4. **D3 sentinel** (if approved): `tool_eligibility.zig:76-83`
   `allowlistFilter` treats exact `"none"` as empty set; agent override
   emits `"none"` for zero enabled rows; wire the `[]` config paths to it.
5. No DB migration (config-only), no new route (reuses GET/PUT
   `/api/config/pabrik` + existing `GET /api/agent-tools/registry`).

## 6. Frontend changes

1. `PabrikTabStrip.vue` — `TabId += 'tools'`; append
   `{ id: 'tools', label: 'Tools' }` after `mcp`.
2. `PabrikSettings.vue` — `Tab += 'tools'`; `toolsList = ref<string[]>()`;
   hydrate in `syncFromConfig()` from `c.tools`; serialize in
   `syncToConfig()`; add to the deep watch array so `PabrikSaveBar` /
   `PUT` dirty-tracking works; mount new `ToolsSection`.
3. **NEW** `components/pabrik/ToolsSection.vue` — description paragraph +
   `All / None` actions + grouped checklist rows
   (checkbox-row pattern from `PabrikGeneralSection.vue:118-133`):
   catalog from `GET /api/agent-tools/registry`; client-side grouping by
   a static `name → category` map (frontend-only, fallback bucket
   `Other`); special pills: `main-agent only` on
   `spawn_sub_agent`/`ask_user`, `mode floor` on
   `kanban_list`/`kanban_move_task`; `EmptyState` if registry 500s is
   unnecessary (registry is static) but keep loading row.
4. **URL sync (D5)** — replace the `activeTab` ref with a
   `route.query.section` computed (`general|profiles|mcp|tools`,
   validated; URL wins when present, else localStorage, else `general`;
   `router.replace` on click). Copy `KanbanSettingsView.vue:68-105`.
   Never `?tab=`.
5. No new api module functions except (already present) config
   get/put; no i18n (none exists).

## 7. Verification

- **Zig unit** (in-file tests, in-memory where DB touched): parse
  `tools` absent/present/empty/malformed; PUT round-trip preserves the
  key when body omits it and replaces when present; unknown name →
  400; seed derivation (config list, kanban floor, empty → zero rows);
  `allowlistFilter("none")` → empty (if D3).
- **Functional (python harness)** — any HTTP/wire claim graduates here
  (`tests/functional/harness.py`, free port 8080-8199, **never 8081**,
  isolated tmpdir HOME, no live-server `curl`):
  - `GET /api/config/pabrik` → `tools` key present after PUT;
  - Settings-save cycle (the exact whole-config PUT body the frontend
    sends) does **not** erase `tools`;
  - plain-chat session created with config `tools` set → wire
    `tools[]` equals the checklist (design/chat fallback fires);
  - config `[]` → empty wire set (D3) vs absent → legacy defaults.
- **Vitest**: `PabrikTabStrip.spec.ts` + `PabrikSettings.spec.ts` currently
  assert the exact 3-tab set — update to 4; new `ToolsSection.spec.ts`
  (render from registry, toggle → emits, hydration from config); URL
  round-trip spec (click → `?section=tools`; mount-with-query → active),
  pattern `KanbanSettingsView.spec.ts:346,449`.
- `pnpm -C src/apps/desktop run build` + `zig build test`.

## 8. Risks / notes

- **PUT-strip footgun** (§2.2) — forgetting any of the four structs
  erases the feature on first Save; covered by the round-trip
  functional test.
- Typed `?[]const []const u8` means a hand-edited `"tools": "bash"`
  fails whole-config parse (boot abort / GET 500) — same failure mode
  as existing typed fields; tolerated names stay safe because
  `allowlistFilter` ignores unknown names.
- D3 changes behavior for "agent with every row disabled" (all tools →
  zero tools) — intentional spec alignment, needs explicit approval.
- `move_element_to_page` is registry-only (missing from `equips()`) —
  it would appear in the checklist but never reach the model; fix or
  exclude as a tiny follow-up, not part of this plan's core.
- Design-mode tool reachability is currently broken on the ChatView
  path; the config fallback incidentally fixes it when design tools are
  checked — note in the PR so it isn't mistaken for a regression.
- Dark-only palette: use semantic vars, never hardcode light colors.

## 9. Acceptance

- [ ] `General | Profiles | MCP Servers | Tools` tabs; Tools active via
      click **and** deep-link `…/app/settings?section=tools`
- [ ] Checklist = every `UNIFIED_TOOL_REGISTRY()` name with description,
      grouped, `All / None`, special pills, saved via the existing bar
- [ ] `config.json` round-trips `tools` through GET → edit → PUT without
      loss; unknown names rejected with a clear 400
- [ ] New agent/kanban items seed from `tools` (kanban floor intact);
      design + plain chat use it as runtime default; absent key =
      byte-identical legacy behavior
- [ ] `[]` semantics per D2/D3 approved and covered by tests
- [ ] vitest + `zig build test` + functional harness green; **no
      human-approved behavior change hidden in the diff** (D3 called out)
