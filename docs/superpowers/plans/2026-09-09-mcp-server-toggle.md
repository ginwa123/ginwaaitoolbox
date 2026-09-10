# MCP Server Enable/Disable Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `enabled` toggle per MCP server so users can disable a server without deleting it; disabled servers are hidden from the agent (no tools listed, no calls dispatched) but stay in `config.json` and the settings UI.

**Architecture:** Add optional `enabled?: boolean` (default `true` = missing means enabled) to the backend `McpServerConfig` + JSON parsers + mirror rebuild, skip `enabled == false` in runtime enumeration (`buildMCPToolsRun`) and reject at call dispatch (`handle_mcp_tool`), and add a row-level toggle + modal checkbox in the frontend that round-trips through the existing bulk `PUT /api/config/nalar`.

**Tech Stack:** Zig 0.16 backend (`src/modules/config/Config.zig`, `src/ai_workflow/tui/agentic_loop/`), Vue 3 + TypeScript frontend (`src/apps/desktop/src/`), Python functional harness (`tests/functional/harness.py`).

## Global Constraints

- Backward compat: missing `enabled` MUST mean enabled. Never require a migration; never rewrite old `config.json` entries on load.
- Omit-when-true on write: serialize `enabled: false` only; omit when true to keep `config.json` clean and diffs small.
- No per-server endpoint: all frontend mutations stay local-array + one bulk `PUT /api/config/nalar` (existing pattern). No new routes.
- Disabled = invisible to agent: no `tools/list` enumeration, no `tools/call` dispatch, no stdio spawn, no HTTP connect. Disabled servers must not cost a child process or socket.
- Disable must teardown: toggling to disabled evicts cached stdio child / HTTP client (reuse existing `markStale`/`evict` + `clearMcpToolsCache` path in `nalar_config_put.zig:501-509`).
- Strict TDD: failing test first for every behavior change (Zig inline tests + vitest + python functional).
- Do NOT touch port 8081. Functional tests use harness-picked ports (8080..8199 excl. 8081).
- Per-request arena: no `defer allocator.free` on `ctx.allocator` memory in handlers (arena frees it). Keep `rows.deinit()` for SQLite stmts.

## File Map (read before touching)

| File | Role | What changes |
|---|---|---|
| `src/modules/config/Config.zig:380-410` | `McpServerConfig` struct | Add `enabled: bool = true` field |
| `src/modules/config/Config.zig:1044-1136` | `parseMcpServerConfig` | Parse `enabled` (bool only; non-bool → ignore = true) |
| `src/modules/config/Config.zig:1557-1635` | `rebuildMcpServersParsed` | Re-emit `enabled:false` (omit when true) — fixes today's unknown-field strip |
| `src/modules/config/Config.zig:1442-1556` | `AddMcpServerStdioInput` + `addMcpServerStdio` | New servers default enabled (no input change needed; ensure rebuild keeps it) |
| `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig:413-511` | `buildMCPToolsRun` enumeration | Skip `enabled == false` before spawn/connect |
| `src/ai_workflow/tui/agentic_loop/handle_mcp_tool.zig:48-53` | call dispatch | Reject call to disabled server with clear XML error |
| `src/ai_workflow/tui/http_handlers/nalar_config_put.zig:346-369,501-509` | PUT persistence + cache clear | Verify `enabled` survives deep-copy (it will, generic `json.Value`); verify stale-evict covers toggled server |
| `src/apps/desktop/src/api/index.ts:3707-3730,3755-3759` | `McpServer` + raw wire union | Add `enabled?: boolean` to both |
| `src/apps/desktop/src/components/nalar/McpServersSection.vue:6-10,60-99` | list row | Add toggle button/switch left of Edit, new `toggle` emit, dimmed style when disabled |
| `src/apps/desktop/src/components/NalarSettings.vue:192-258,449-493` | parse/serialize/CRUD | Hydrate `enabled ?? true`, round-trip omit-when-true, carry on save; add `toggleMcpServer(name)` handler |
| `src/apps/desktop/src/components/nalar/McpServerModal.vue` | add/edit modal | Add `Enabled` checkbox (companion to row toggle) into `McpServerModalValue` + `onSave` |
| `src/modules/agent/tools/add_mcp_server.zig:70-95` | agent tool input | Optional: accept `enabled?` (default true). Only if cheap; otherwise skip — agent-added servers are enabled by definition |

## Wire Shape

`config.json` (omit-when-true — enabled servers look exactly like today):

```json
"mcp_servers": {
  "graphify": { "command": "/home/ginwa/.local/share/uv/tools/graphifyy/bin/python", "args": ["-m", "graphify.serve", "graphify-out/graph.json"] },
  "flaky-srv": { "command": "/bin/foo", "enabled": false }
}
```

- Enabled: field absent OR `"enabled": true` → identical behavior to today.
- Disabled: `"enabled": false` → persisted, shown greyed in UI, invisible to agent.
- Frontend `McpServer`: `enabled?: boolean` (undefined = true). Serializer omits when `true`/undefined, emits `false` explicitly.
- Agent-visible error on stale call (defense in depth, e.g. tool list cached mid-run): `<mcp_tool><error>server 'X' is disabled</error></mcp_tool>` (match existing error envelope style in `handle_mcp_tool.zig`).

## UI Shape (matches screenshot row)

Row today: `graphify [STDIO]  $ <command...>  [Edit] [⌫]`. After:

```
graphify [STDIO] [Disabled badge if off]  $ <command...>  [toggle] [Edit] [⌫]
```

- Toggle: small switch/checkbox button with `data-testid="toggle-btn"`, `title="Enable/Disable server"`, `aria-pressed`. Position: left of Edit in the `div.flex.items-center.gap-1.5.shrink-0` cluster (`McpServersSection.vue:84`).
- Disabled row style: `opacity-60` on name/subtitle + amber/grey `Disabled` pill next to transport badge. No layout shift.
- Modal: `Enabled (agent can call this server)` checkbox at top of both HTTP + stdio branches (next to transport toggle). Checked by default for new servers.
- Delete stays as-is (instant filter, no confirm). Toggle is orthogonal.

---

## Task 1 — Backend: `enabled` field on `McpServerConfig` + parser

- [ ] Read `src/modules/config/Config.zig:380-410` (`McpServerConfig`) and `:1044-1136` (`parseMcpServerConfig`).
- [ ] Write failing Zig test in `Config.zig` (or `config_test.zig` if that is the established location — check first): parse `{ "command": "x", "enabled": false }` → `enabled == false`; parse `{ "command": "x" }` → `enabled == true`; parse `{ "command": "x", "enabled": "yes" }` (non-bool) → `enabled == true` (ignore, not fatal).
- [ ] Run it, confirm it fails (`enabled` field unknown).
- [ ] Implement: add `enabled: bool = true` to `McpServerConfig`; in `parseMcpServerConfig` read `obj.get("enabled")`, accept only `.bool`, else leave default.
- [ ] Run test, confirm passes. Run `zig build test --summary all`, confirm no regressions.
- [ ] Commit: `mcp toggle: parse enabled flag on McpServerConfig (default true)`.

## Task 2 — Backend: preserve `enabled` in mirror rebuild

- [ ] Read `src/modules/config/Config.zig:1549-1635` (`rebuildMcpServersParsed`).
- [ ] Write failing test: build map with one disabled server → `rebuildMcpServersParsed` → JSON contains `"enabled": false`; enabled server → JSON omits `enabled` key.
- [ ] Run it, confirm it fails (today rebuild emits only url/headers/command/args/cwd).
- [ ] Implement: emit `enabled:false` when `!server.enabled`, omit otherwise.
- [ ] Run test + full `zig build test`. Verify existing `agent_add_mcp_server` tests still pass (new servers enabled by default).
- [ ] Commit: `mcp toggle: rebuildMcpServersParsed round-trips enabled:false`.

## Task 3 — Runtime: skip disabled servers in `buildMCPToolsRun`

- [ ] Read `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig:413-511`.
- [ ] Write failing test (follow existing `buildMCPToolsRun` test pattern in same file): `mcpServers` JSON with one enabled + one disabled server → returned `[]AgentTool` contains only enabled server's tools (or disabled server's `tools/list` never attempted — assert via tool name prefix `mcp_<server>_`).
- [ ] Run it, confirm it fails (disabled server's tools appear).
- [ ] Implement: after `server_obj` extraction (`:433-436`), check `server_obj.get("enabled")`; if `.bool == false`, `continue` before any spawn/connect. Note: runtime reads the JSON mirror (`mcpServers()`), not the typed map — so check the JSON value, not `McpServerConfig`.
- [ ] Run test + `zig build test`.
- [ ] Commit: `mcp toggle: buildMCPToolsRun skips disabled servers`.

## Task 4 — Runtime: reject calls to disabled servers at dispatch

- [ ] Read `src/ai_workflow/tui/agentic_loop/handle_mcp_tool.zig` (config lookup ~`:48-53`, dispatch to stdio/http).
- [ ] Write failing test: config with disabled server → `callViaStdio`/`callViaHttp` path (or the wrapper that resolves server by name) returns `<error>...disabled...</error>` and never spawns/connects.
- [ ] Run it, confirm it fails.
- [ ] Implement: after resolving server config by name, if `enabled == false` return the disabled-error envelope (same shape as existing unknown-server error in that file).
- [ ] Run test + `zig build test`.
- [ ] Commit: `mcp toggle: dispatch rejects disabled servers`.

## Task 5 — Backend verification: PUT round-trip + cache evict (no code expected)

- [ ] Read `src/ai_workflow/tui/http_handlers/nalar_config_put.zig:346-369` (deep-copy) and `:501-509` (clearMcpToolsCache + markStale/evict).
- [ ] Static-contract check: `enabled` is a generic `json.Value` boolean so deep-copy preserves it — add a static test asserting a PUT body with `"enabled": false` survives to disk (follow `nalar_config_put` test pattern) OR document why no test is needed.
- [ ] Confirm toggle-to-disabled triggers the same stale-evict as any other PUT edit (it should — wholesale replace + per-server evict). If evict is keyed on removed servers only, extend to changed servers.
- [ ] Write functional test `tests/functional/mcp_server_toggle_test.py` (harness boots fresh binary, isolated tmp HOME, never port 8081): (a) PUT config with disabled server → GET returns `enabled:false`; (b) agent tool list excludes disabled server's tools; (c) PUT flip to enabled → tools reappear. Replay the EXACT JSON body the frontend sends (see Task 7 serializer).
- [ ] Run: `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/mcp_server_toggle_test.py -v`. Confirm green.
- [ ] Commit: `mcp toggle: functional toggle round-trip + enumeration`.

## Task 6 — Frontend: type + parse/serialize plumbing

- [ ] Read `src/apps/desktop/src/api/index.ts:3707-3759` and `NalarSettings.vue:192-258`.
- [ ] Write failing vitest (extend `McpServersSection.spec.ts` or NalarSettings spec — check existing): `parseMcpServers({a: {command:'x', enabled:false}})` → `[{name:'a', enabled:false}]`; missing `enabled` → `enabled: undefined` (treated as true); `serializeMcpServers` omits `enabled` when true/undefined, emits `false` explicitly.
- [ ] Run it, confirm it fails.
- [ ] Implement: add `enabled?: boolean` to `McpServer` + raw wire union; hydrate `enabled: raw.enabled ?? true` (or leave undefined — pick one and keep parse/serialize symmetric); serializer omit-when-true.
- [ ] Run `pnpm test:unit` for touched specs. Run `npx vue-tsc --noEmit -p tsconfig.app.json`.
- [ ] Commit: `mcp toggle: frontend type + parse/serialize enabled`.

## Task 7 — Frontend: row toggle button + dimmed state

- [ ] Read `src/apps/desktop/src/components/nalar/McpServersSection.vue:53-114`.
- [ ] Write failing vitest in `McpServersSection.spec.ts`: row with `enabled:false` shows `toggle-btn` in off state + dimmed class + `Disabled` pill; clicking `toggle-btn` emits `toggle` with server; row with missing `enabled` renders as enabled.
- [ ] Run it, confirm it fails.
- [ ] Implement: add `toggle` to `defineEmits`; add `<button data-testid="toggle-btn">` left of `edit-btn` in `:84` cluster (switch styling, `aria-pressed`, `title`); add `Disabled` pill + `opacity-60` when `server.enabled === false`.
- [ ] Run `pnpm test:unit`, `vue-tsc` clean.
- [ ] Commit: `mcp toggle: row toggle button + disabled style`.

## Task 8 — Frontend: orchestrator handler + modal checkbox

- [ ] Read `NalarSettings.vue:415-493` (CRUD) and `McpServerModal.vue` transport toggle + `onSave`.
- [ ] Write failing vitest: `toggleMcpServer(name)` flips `enabled` in `mcpServersList` and marks dirty (via `syncToConfig` watch); modal `Enabled` checkbox binds into `McpServerModalValue` and survives `onSave` → parent `saveMcpServer` carries it.
- [ ] Run it, confirm it fails.
- [ ] Implement: `toggleMcpServer(name)` in `NalarSettings.vue` (map + flip, default true→false); wire `@toggle` on `<McpServersSection>` mount (`:610-616`); add `Enabled (agent can call this server)` checkbox to both modal branches + `enabled` in `McpServerModalValue` + `onSave` passthrough; `saveMcpServer` validation unchanged (name/command/url rules as-is).
- [ ] Run `pnpm test:unit` (full), `vue-tsc` clean.
- [ ] Commit: `mcp toggle: orchestrator handler + modal checkbox`.

## Task 9 — Full verification + docs

- [ ] `zig build test --summary all` — all pass, 0 fail.
- [ ] `pnpm test:unit` — all pass.
- [ ] `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/mcp_server_toggle_test.py tests/functional/mcp_stdio_test.py tests/functional/mcp_http_test.py tests/functional/nalar_config_test.py -v` — all green (no regressions in sibling suites).
- [ ] `zig build nalar-desktop --summary all` — builds clean (frontend changes embedded).
- [ ] Update `NALAR.md` changelog (one entry, same style as prior MCP entries) + `docs/SPEC.md` if it documents `mcp_servers` shape.
- [ ] Commit: `mcp toggle: verification + changelog`.

## Out of Scope (explicitly NOT in this plan)

- Per-server Test button for disabled servers (Test stays as-is; testing a disabled server is allowed but does not enable it).
- `env` support for stdio (frontend already has `env` UI-only/forward-compat; backend ignores it — separate feature).
- Agent `add_mcp_server` `enabled` input (agent-added servers are always enabled; add later if needed without changing this plan's wire).
- Auto-disable on repeated failures / health checks (no behavior change on fetch failure — existing warn+continue stays).
- Migration of old configs (not needed — missing field = enabled).

## Risks

- **Rebuild strip (known):** `rebuildMcpServersParsed` today drops unknown keys, so any `enabled` written by PUT is lost on the next `add_mcp_server` call. Task 2 fixes this at the source. If Task 2 is skipped, the toggle silently resets — must not ship Tasks 6-8 without Task 2.
- **JSON-mirror vs typed-map drift:** runtime reads `mcpServers()` (JSON mirror), not `mcp_servers` (typed map). Both Task 3 and Task 4 must check the JSON value. Checking only the typed struct leaves runtime unfiltered.
- **Stale cache on toggle:** PUT already evicts per-server (`markStale`/`evict`); if evict only fires on server removal (not value change), a just-disabled stdio child stays alive until restart. Task 5 verifies and fixes.
- **Omit-when-true asymmetry:** if parse defaults to `true` but serialize emits `true` explicitly, every save dirties `config.json` with noise. Keep both sides symmetric (absent = true, omit on write).
