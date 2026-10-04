# list_sub_agent Implementation Plan (rev 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new read-only agent tool `list_sub_agent` that shows the LLM the subagents already configured on its current session profile — with full detail so it can pick the right one.

**Architecture:** Pure read-only view over the per-profile `LlmConfig.LlmProfile.sub_agents` slice (same source as the system-prompt `BuildSubAgentsListing`), exposed as a `get_plan`-style tool with no input, returning a `<list_sub_agent>` XML envelope carrying each subagent's full `SubAgentConfig`: `name`, `model`, `url_style`, `thinking`, `temperature`, full `system_prompt` (NOT truncated — the LLM needs the whole persona to choose correctly), plus the numeric tuning overrides (`max_capacity_tokens`, `compaction_threshold_percent`, `thinking_budget_tokens`, `reasoning_effort`). Only `api_key` and `base_url` stay hidden (credentials/connection — never on the LLM wire). Wired through the standard 3-site registry (`equips` + `UNIFIED_TOOL_REGISTRY` + `tools.zig` re-export) plus a small Vue output card.

**Tech Stack:** Zig 0.16 (AgentTool + ToolExecContext + wrapToolOutput), SQLite (no new table — config only), Vue 3 + vitest (ListSubAgent.vue card), python functional harness (wire replay).

## Global Constraints

- Per-profile only (plan 2026-09-04-subagents-per-profile): read `ctx.config.getProfile(ctx.selected_profile_model).sub_agents`. NEVER fall back to top-level `config.sub_agents` (deprecated). Empty/unknown profile → `<empty/>`, not an error.
- Secrets rule: emit every `SubAgentConfig` field EXCEPT `api_key` and `base_url`. Tuning fields (`thinking`, `temperature`, `url_style`, `max_capacity_tokens`, `compaction_threshold_percent`, `thinking_budget_tokens`, `reasoning_effort`) are shown verbatim; `null` optionals are OMITTED (null = "inherits parent profile default" — document this in the tool description so the LLM reads absence correctly).
- `system_prompt` is FULL text (rev 2 — user explicitly rejected the 80-char truncation; a truncated persona defeats the "pick the right subagent" purpose). Wrapped in CDATA with the `]]>` → `]]><![CDATA[>` split (same as `enrichCompactionXml`). Trade-off accepted: output grows with persona size; subagent counts per profile are small (single digits) so this stays within normal tool-output budgets.
- No migration, no schema change, no new SSE event, no new HTTP route. No edit to `handle_tool.zig` (registry auto-discovered).
- Per-request arena: `ctx.allocator` is arena-backed — do NOT `defer free` arena slices inside the exec adapter.
- Frontend: new `ListSubAgent.vue` in `src/apps/desktop/src/components/tool_outputs/`, wired into BOTH `ChatView.vue` and `SubAgentPeekPanel.vue` dispatchers (same as `GetPlan`/`UpdatePlan`).
- Verification: `zig build test --summary all` green + `pnpm test:unit` green + 1 new python functional test replaying the tool via the agent wire (or direct exec-adapter roundtrip if agent-wire is too heavy — see Task 5).

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/modules/agent/tools/list_sub_agent.zig` | NEW | `ListSubAgentInput = struct {}` + `list_sub_agent_tool: AgentTool` + `list_sub_agent_tool_system_prompt` + `executeListSubAgent(allocator, config, profile_name)` pure fn returning `<list_sub_agent>…` envelope |
| `src/ai_workflow/tui/agentic_loop/tools_exec_list_sub_agent.zig` | NEW | `execListSubAgent(ctx, tc)` adapter: parse `{}` → call pure fn with `ctx.config` + `ctx.selected_profile_model` → `wrapToolOutput` |
| `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` | EDIT | +1 import, +1 line in `equips()`, +1 line in `UNIFIED_TOOL_REGISTRY()` |
| `src/ai_workflow/tui/agentic_loop/tools.zig` | EDIT | +1 re-export `execListSubAgent` |
| `src/root.zig` | EDIT | +1 re-export (`pub const list_sub_agent = …`) so `pabrikcore.list_sub_agent` resolves like `pabrikcore.get_plan` |
| `src/apps/desktop/src/components/tool_outputs/ListSubAgent.vue` | NEW | Collapsible card: profile name + count chip + per-row full detail (tuning grid + full persona) |
| `src/apps/desktop/src/components/tool_outputs/ListSubAgent.spec.ts` | NEW | 7-9 vitest cases (populated, empty, missing profile, null-omission, secrets absent) |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT | `v-else-if="msg.tool_name === 'list_sub_agent'"` branch (both dispatch sites if two exist) |
| `src/apps/desktop/src/components/.../SubAgentPeekPanel.vue` | EDIT | Same branch (check exact filename from research — dispatcher mirrors ChatView) |
| `tests/functional/list_sub_agent_test.py` | NEW | 3 e2e tests: populated profile lists full detail, empty profile returns `<empty/>`, secrets never appear |
| `docs/superpowers/plans/2026-09-11-list-sub-agent.md` | THIS FILE | Plan under review (rev 2) |

## Wire Contract

No input (mirrors `get_plan`):
```json
{}
```

Success (populated — all fields except `api_key`/`base_url`; null optionals omitted):
```xml
<list_sub_agent><profile>my-profile</profile><count>2</count><sub_agents><sub_agent><name>coder</name><model>model-x</model><url_style>anthropic</url_style><thinking>true</thinking><temperature>0.7</temperature><max_capacity_tokens>200000</max_capacity_tokens><thinking_budget_tokens>10000</thinking_budget_tokens><system_prompt><![CDATA[You are a senior Zig engineer. Follow TDD… (FULL text, never truncated)]]></system_prompt></sub_agent><sub_agent><name>reviewer</name><model></model><url_style></url_style><thinking></thinking><temperature>auto</temperature><system_prompt><![CDATA[]]></system_prompt></sub_agent></sub_agents></list_sub_agent>
```

Empty (no profile / unknown profile / zero subagents):
```xml
<list_sub_agent><profile>my-profile</profile><empty/></list_sub_agent>
```

Outer wrapper (via `wrapToolOutput`, same as get_plan):
```xml
<tool><name>list_sub_agent</name><parameters>{}</parameters><success>true</success><data><list_sub_agent>…</list_sub_agent></data></tool>
```

Rules:
- `<profile>` echoes `ctx.selected_profile_model` verbatim (empty string allowed).
- Skip entries with empty `sa.name` (same as `BuildSubAgentsListing`).
- String fields (`model`, `url_style`, `thinking`, `temperature`) emitted verbatim, even when empty (empty = "inherits orchestrator default" per `buildResolvedFromConfig` overlay semantics — same meaning the spawn path uses).
- Numeric/optional fields (`max_capacity_tokens`, `compaction_threshold_percent`, `thinking_budget_tokens`, `reasoning_effort`) emitted ONLY when non-null; absent tag = "inherits parent profile default".
- `<system_prompt>` FULL text in CDATA with `]]>` → `]]><![CDATA[>` split. NEVER truncated (rev 2).
- NEVER emit `<api_key>` or `<base_url>` tags at all (not even empty).
- Tool description (LLM-facing): "List the subagents configured on your current profile with their full specs (model, tuning, system prompt). Call this before spawn_sub_agent when you are unsure which agent_name values exist or which one fits the job. Absent optional tags mean 'inherits the profile default'. Read-only, no side effects."

## Tasks

### Task 1 — Pure tool module + failing-first unit tests

- [ ] Create `src/modules/agent/tools/list_sub_agent.zig` with `ListSubAgentInput`, `list_sub_agent_tool` (function name `list_sub_agent`, `required: &.{}`, `properties: &.{}`, description per Wire Contract), `list_sub_agent_tool_system_prompt`, and `executeListSubAgent(allocator, config, profile_name) ![]const u8`.
- [ ] `executeListSubAgent` logic: `if (profile_name.len == 0) → empty envelope`; `getProfile(profile_name)` miss → empty envelope; else iterate `profile.sub_agents`, skip empty names, emit per-row full-detail tags per Wire Contract (null optionals omitted, `api_key`/`base_url` never emitted).
- [ ] Inline `test` blocks at bottom of the same file (repo convention — tests live in impl file): populated profile (2 rows; assert FULL system_prompt present verbatim — construct a >80-char prompt and assert no `...` truncation), tuning fields present verbatim (`temperature`, `thinking`, `max_capacity_tokens`, `thinking_budget_tokens`, `reasoning_effort`, `compaction_threshold_percent`, `url_style`), null-optional omission (row with all-null optionals carries none of those tags), empty-name skip, unknown profile → `<empty/>`, empty profile name → `<empty/>`, secrets check (SubAgentConfig with `api_key`+`base_url` set → output contains neither string nor tag names).
- [ ] Run the new tests to confirm they FAIL before the impl body exists (TDD: write test stubs first, run `zig test src/modules/agent/tools/list_sub_agent.zig`, see failures), then implement minimal body to green.
- [ ] Run `zig build test --summary all` — new tests pass, zero regressions.
- [ ] Commit: `feat(agent): list_sub_agent pure tool module + unit tests`.

### Task 2 — Exec adapter + registry wiring

- [ ] Create `src/ai_workflow/tui/agentic_loop/tools_exec_list_sub_agent.zig` with `pub fn execListSubAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult` mirroring `tools_exec_get_plan.zig`: expect `{}` args (tolerate missing/empty), call `executeListSubAgent(ctx.allocator, ctx.config, ctx.selected_profile_model)`, wrap via `wrapToolOutput(ctx.allocator, "list_sub_agent", args, true, null, inner)`. Include `makeTestCtx` scaffold (copy from `tools_exec_update_plan.zig:108-127`).
- [ ] Static-contract tests in the same file: adapter returns `success=true` outer envelope, echoes profile name, empty-profile path returns `<empty/>` (grep-based, same style as `tools_exec_get_plan` tests).
- [ ] Edit `tools_equipped.zig`: +1 import (`pabrikcore.list_sub_agent`), +1 `list_sub_agent_tool` in `equips()`, +1 `{ .name = "list_sub_agent", .exec = tools.execListSubAgent, .tool_def = … }` in `UNIFIED_TOOL_REGISTRY()`.
- [ ] Edit `tools.zig`: +1 re-export. Edit `src/root.zig`: +1 re-export (verify `pabrikcore.get_plan` alias lines ~849-851 and mirror them).
- [ ] Run `zig build test --summary all` green.
- [ ] Commit: `feat(agent): list_sub_agent exec adapter + registry wiring`.

### Task 3 — Prompt rule pointer (LLM discoverability)

- [ ] Find the `spawn_sub_agent` system-prompt rule text (near `appendSubAgentsListing` header in `prompts_build_messages_for_agent_prompt.zig:1818-1825` or the spawn tool description in `src/modules/agent/tools/spawn_sub_agent.zig:98-102`).
- [ ] Add one pointer sentence: "If you are unsure which agent_name values exist or which fits the job, call list_sub_agent first — it shows full specs (model, tuning, system prompt); absent optional tags mean 'inherits the profile default'." Keep it to 1-2 lines — do NOT duplicate the full listing.
- [ ] Fix the stale "then top-level" phrase in `spawn_sub_agent.zig:98-102` description if touched (per-profile-only since 2026-09-04) — 1-line correction, same commit.
- [ ] `zig build test --summary all` green (prompt snapshot tests may need updating — update expected strings, do not delete tests).
- [ ] Commit: `feat(agent): list_sub_agent prompt pointer + stale spawn desc fix`.

### Task 4 — Frontend output card + dispatchers + vitest

- [ ] Create `ListSubAgent.vue` in `src/apps/desktop/src/components/tool_outputs/` mirroring `GetPlan.vue` prop idiom (`:message="msg"` self-contained): header chip `N subagents · profile <name>` (or `No subagents on profile <name>` empty state); per-row `name` (bold) + `model`/`url_style` (muted meta line) + tuning grid (`thinking`, `temperature`, numeric overrides — render only tags present in the envelope) + full `system_prompt` in an expandable `<details>`/collapsible block (full text, scrollable, NOT truncated).
- [ ] Create `ListSubAgent.spec.ts`: populated (2 rows render with tuning values), empty state, missing-profile string, null-omitted tuning hidden (no empty grid cells for absent tags), full persona rendered (no truncation — assert a long prompt string appears in full), `api_key`/`base_url` never rendered even if present in payload (defense in depth).
- [ ] Edit `ChatView.vue`: add `v-else-if="msg.tool_name === 'list_sub_agent'"` branch next to the `get_plan` branch (import the component; follow the `:message` idiom, not `:content`).
- [ ] Edit `SubAgentPeekPanel.vue` (verify exact path — mirrors ChatView dispatcher): same branch.
- [ ] Run `pnpm test:unit` green + `vue-tsc --noEmit -p tsconfig.app.json` clean.
- [ ] Commit: `feat(ui): ListSubAgent output card + dispatchers`.

### Task 5 — Functional wire test + full verification

- [ ] Create `tests/functional/list_sub_agent_test.py` using the harness (`tests/functional/harness.py` — isolated tmpdir HOME, free port excluding 8081, `$PABRIK_BIN`): seed a config with 2 subagents on profile P (via `PUT /api/config/pabrik` granular `ProfileChange` or direct config.json seed — check `subagents_per_profile_test.py` for the established seed pattern; give one subagent distinctive tuning values + a long system_prompt, the other all-null optionals), then invoke the tool through the real agent wire (preferred) or assert the envelope via the session tool-call path; assert: names listed, count=2, full system_prompt present verbatim, tuning values present, null-optional tags absent, `api_key`/`base_url` strings absent from the full response body.
- [ ] Second test: empty profile (no subagents) → `<empty/>` envelope, no error.
- [ ] Third test (rev 2): long system_prompt (>80 chars, incl. a `]]>` sequence if practical) round-trips whole with correct CDATA split and no `...` marker.
- [ ] Run: `PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/list_sub_agent_test.py -v` (rebuild via `install:linux` first if the binary is stale — `pabrik-desktop` step does NOT rebuild it).
- [ ] Final gates: `zig build test --summary all` + `pnpm test:unit` both green.
- [ ] Commit: `test(functional): list_sub_agent wire tests`.
- [ ] Open PR from the worktree so the human reviews in `in_review_task` (per board flow).

## Out of Scope (explicit non-goals)

- No filtering/search input (`{}` only in v1 — a `query` param is a follow-up if the user asks).
- No cross-profile listing (current session profile only; no `profile` param — prevents the LLM from enumerating other profiles' setups).
- No `api_key`/`base_url` exposure (ever — credentials/connection stay off the LLM wire).
- No add/edit/delete of subagents (that is a separate tool proposal; this one is read-only).
- No `resolveSubAgent` behavior change, no random-fallback change, no `Config.zig` storage change.
- No migration, no new table, no SSE event, no HTTP route.

## Risks

- **Output size (accepted, rev 2):** full personas make the envelope larger than the truncated v1. Mitigation: none needed beyond awareness — profiles hold single-digit subagent counts; if a profile ever carries dozens of huge personas and context pressure appears, the follow-up is a `query`/name-only mode, NOT silent re-truncation.
- **Prompt snapshot churn (low):** Task 3 touches prompt strings; existing `prompts_build_messages…` snapshot tests may fail on exact-match. Mitigation: update expected strings in place, run the single test file first.
- **Binary staleness in functional tests (known gotcha):** `zig build pabrik-desktop` does NOT rebuild `pabrikcore-linux-x86_64`. Mitigation: rebuild via `install:linux` before `pytest`, per the 2026-09-04 memory.
- **Secret leak by future field addition (low but real):** a future `SubAgentConfig` field (e.g. `auth_token`) could be copied into the envelope by a careless follow-up. Mitigation: Task 1's secrets test asserts `api_key`/`base_url` absence today; code comment in `executeListSubAgent` — "denylist: api_key + base_url are NEVER emitted — any new credential/connection field must join this denylist, with a test".
