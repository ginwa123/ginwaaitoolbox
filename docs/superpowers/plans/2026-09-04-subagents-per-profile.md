# Subagents Per-Profile Only Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the top-level global `sub_agents` list so subagents live only inside each profile (`profiles_models.<name>.sub_agents`) in `config.json`.

**Architecture:** Single source of truth becomes `LlmProfile.sub_agents`. `resolveSubAgent` looks only in the session's profile (no top-level fallback). A one-time load migration copies any existing top-level entries into profiles that have an empty list, then the top-level key is no longer written. Frontend drops the global Sub-Agents tab and edits subagents only inside each profile row.

**Tech Stack:** Zig 0.16 (`src/modules/config/Config.zig`, `src/ai_workflow/tui/http_handlers/pabrik_config_{put,get}.zig`), Vue 3 + TypeScript (`PabrikSettings.vue`, `ProfilesSection.vue`, `SubAgentsSection.vue`, `api/index.ts`), SQLite untouched (no migration).

## Global Constraints

- No `rm -rf`, no live-server `curl` verification — use `tests/functional/harness.py` + `zig build test` per repo rules.
- `config.json` stays backward-readable: old files with top-level `sub_agents` must still load (migrated in memory, not rejected).
- No new DB migration, no new HTTP route, no new SSE event.
- Keep `SubAgentConfig` / `SubAgentJson` field shape identical (only the *location* changes).
- DONT KILL port 8081; functional tests use harness-picked ports.

## Current State (verified 2026-09-04)

- `LlmConfig.sub_agents` (global, `Config.zig:25`) + `LlmProfile.sub_agents` (per-profile, `Config.zig:124`) both exist; `resolveSubAgent` (`Config.zig:2007`) searches profile-first, falls back to top-level.
- `clone()` (`Config.zig:1242-1266`) explicitly drops per-profile `sub_agents` (passes `.sub_agents = null`) — must be fixed regardless.
- `PUT /api/config/pabrik` granular profile add/update (`pabrik_config_put.zig:180-234`) rebuilds the profile object field-by-field with NO `sub_agents` key → clobbers per-profile subagents on any granular profile edit. Object-map shape (`:243+`) deep-copies so it preserves them.
- Frontend already edits both scopes (`PabrikSettings.vue` top-level `subAgentsList` + per-profile `profilesList[].sub_agents`, shared `SubAgentModal`, `SubAgentsSection.vue` global tab + `ProfilesSection.vue` nested lists). Resolution copy says non-empty per-profile REPLACES top-level.
- User intent: kill the dual model — per-profile only, no inheritance, no global tab.

## Open Decision (needs user confirm before execution)

- **Migration target:** when top-level `sub_agents` is non-empty on load, copy it into (a) every profile with an empty list, or (b) only the `active_profile`? Recommended: (a) — preserves behavior for all profiles, matches today's "inherits top-level" semantics.

---

## Task 1 — Backend: load-migration + profile-only resolution

- [ ] Write failing test in `src/modules/config/config_test.zig`: config with top-level `sub_agents=[X]` + profile `p1` with empty list → after `LlmConfig.init`, `p1.sub_agents` contains `X` (migration ran).
- [ ] Run it, confirm it fails.
- [ ] Implement in `Config.zig` (`LlmConfig.init`, after `addProfile` loop): if top-level list non-empty, for each profile with empty `sub_agents`, dupe top-level entries into it (reuse `parseSubAgentsJson`-style dupe; keep top-level list in memory for now for backward compat).
- [ ] Write failing test: `resolveSubAgent("p1", "name-only-in-top-level")` still resolves during transition (fallback kept until Task 3 removes it) — documents transition behavior.
- [ ] Run `zig build test --summary all`, confirm green.
- [ ] Commit.

## Task 2 — Backend: fix `clone()` to preserve per-profile subagents

- [ ] Write failing test in `config_test.zig`: profile with 1 subagent → `clone()` → cloned profile still has 1 subagent (today it has 0).
- [ ] Run it, confirm it fails.
- [ ] Implement in `Config.zig:1250-1266`: replace `.sub_agents = null` with a deep-copy of `entry.value_ptr.sub_agents` (dupe all 8 strings + 2 knobs per entry, same pattern as top-level clone at `:1283-1294`).
- [ ] Run `zig build test --summary all`, confirm green.
- [ ] Commit.

## Task 3 — Backend: remove top-level fallback from `resolveSubAgent` + stop writing top-level

- [ ] Write failing test: `resolveSubAgent("p1", "top-level-only-name")` with `p1.sub_agents=[]` → returns `is_random_fallback=true` (no longer falls back to top-level).
- [ ] Run it, confirm it fails.
- [ ] Implement in `Config.zig:2007-2039`: delete the top-level `getSubAgent` fallback branch; miss in profile → straight to random-fallback. Keep parsing top-level key on load (for migration) but mark deprecated in comment.
- [ ] Update `BuildSubAgentsListing` (`prompts_build_messages_for_agent_prompt.zig:1139-1144`): render only the session profile's list (remove `else top-level` branch).
- [ ] Run `zig build test --summary all`, update the 3 precedence tests at `config_test.zig:1216-1344` (profile-preferred stays, fallback-to-top-level becomes random-fallback, unknown-profile becomes random-fallback).
- [ ] Commit.

## Task 4 — Backend: PUT handler — per-profile subagents in granular shape, drop top-level write

- [ ] Write failing static-contract test in `pabrik_config_put.zig` (or its `_test.zig`): granular `{"action":"update","name":"p1",...,"sub_agents":[...]}` preserves subagents; granular update WITHOUT `sub_agents` preserves existing on-disk per-profile subagents (no clobber).
- [ ] Run it, confirm it fails (today granular rebuild at `:181-234` drops the key).
- [ ] Implement: add `sub_agents: ?[]SubAgentJson` to `ProfileChange` struct; in add/update branch, when present validate (reuse thinking-knob validation at `:331-354`) + serialize into `profile_obj`; when absent, copy existing on-disk profile's `sub_agents` value through (same "omit doesn't clobber" pattern as `max_capacity_tokens` at `:192-194`).
- [ ] Deprecate top-level `input.sub_agents` handling (`:324-374`): keep parsing (old frontend may still send) but log warn; do NOT write `config_json.sub_agents` for new saves. Add `sub_agents: null` omission so fresh writes drop the key.
- [ ] Add functional test in `tests/functional/` (harness, isolated HOME, non-8081 port): PUT granular profile update without `sub_agents` → GET still returns per-profile subagents; PUT with `sub_agents` → GET returns new list.
- [ ] Run `PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/<new>_test.py -v` + `zig build test --summary all`.
- [ ] Commit.

## Task 5 — Backend: GET handler — return per-profile only

- [ ] Update `pabrik_config_get.zig` + `http_response.zig` (`PabrikConfigResponse`): keep `profiles[].sub_agents`, remove top-level `sub_agents` from response (or return `[]` with deprecation comment if frontend transition needs it — decide in Task 6 order: land backend GET change TOGETHER with frontend change to avoid wire break).
- [ ] Update GET static-contract tests.
- [ ] Run `zig build test --summary all`.
- [ ] Commit (squash with Task 6 if wire-break risk dictates).

## Task 6 — Frontend: delete global tab, edit subagents only in profiles

- [ ] Delete `SubAgentsSection.vue` usage from `PabrikSettings.vue` `sub-agents` tab (remove tab or repurpose as "Sub-agents live inside each profile" pointer); remove `subAgentsList` ref + `startAddSubAgent/startEditSubAgent/deleteSubAgent` top-level branch; keep only `scope:{kind:'profile'}` path in `saveSubAgent`.
- [ ] Keep `ProfilesSection.vue` nested lists as the ONLY editor; update header copy (remove "overrides top-level / inherits top-level", replace with count-only summary).
- [ ] Update `api/index.ts`: remove `PabrikConfig.sub_agents` (or mark `@deprecated`), keep `PabrikProfile.sub_agents`.
- [ ] Update `usePabrikConfig.ts` save path: `syncToConfig` writes profiles only.
- [ ] Update/extend specs: `ProfilesSection` nested add/edit/delete still pass; add regression spec asserting no global `SubAgentsSection` mount in `PabrikSettings`.
- [ ] Run `pnpm test:unit` + `vue-tsc --noEmit`.
- [ ] Commit.

## Task 7 — Cleanup + docs

- [ ] Remove top-level `sub_agents` parse/write entirely (after 1 release of deprecated-read): `LlmConfigJson.sub_agents`, `parseSubAgentsList` top-level call, `LlmConfig.sub_agents` field, `getSubAgent/hasSubAgent/subAgentCount` top-level helpers (or keep helpers retargeted at a profile param).
- [ ] Update `docs/SPEC.md:127` + `PABRIK.md` changelog (dual-model → per-profile-only, migration note).
- [ ] Full verification: `zig build test --summary all` + `pnpm test:unit` + relevant `pytest tests/functional/` suites green.
- [ ] Commit.

## Verification (before claiming done)

- [ ] `zig build test --summary all` green.
- [ ] `pnpm test:unit` green, `vue-tsc` clean.
- [ ] New functional test: old `config.json` with ONLY top-level `sub_agents` loads, profile inherits them once, GET shows them under the profile, and a granular profile update without `sub_agents` doesn't wipe them.
- [ ] Grep `sub_agents` shows no remaining top-level write path (`pabrik_config_put.zig` top-level branch removed, `PabrikSettings.vue` no `subAgentsList`).
