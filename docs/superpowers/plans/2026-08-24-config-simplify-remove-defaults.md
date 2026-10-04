# Config Simplify — Remove Top-Level Defaults Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the top-level "defaults" block (`api_key`, `model`, `base_url`, `url_style`, `max_tokens`, `system_prompt`) from `~/.config/pabrik/config.json` so the file only carries profiles + operational settings, while keeping every existing consumer working unchanged.

**Architecture:** The in-memory `LlmConfig` struct KEEPS its top-level fields (they are the cascade's final fallback and ~40 call sites read them). Only the ON-DISK JSON shape changes: `LlmConfig.init` backfills the four LLM fields from the resolved profile (`active_profile`, falling through to the first profile with a non-empty model) when the keys are absent/empty, and `writeDefaultConfig` stops emitting them. The PUT handler stops persisting them. Zero changes to workflow.zig / handle_tool.zig / session_compact.zig / llm_history.zig — they all keep reading `cfg.model` etc., which now hold profile-derived values.

**Tech Stack:** Zig 0.16 backend (`src/modules/config/Config.zig`, HTTP handlers), Vue 3 + TypeScript frontend (`PabrikSettings.vue` + `DefaultsSection.vue`).

## Global Constraints

- **Do NOT delete the struct fields.** `LlmConfig.api_key/model/base_url/url_style` stay — deleting them would touch ~40 call sites across workflow.zig, handle_tool.zig, session_compact.zig, llm_history.zig, pabrik_config_get.zig, and Config.zig's own cascade (`resolveEffectiveProfile` step 3 falls back to `self.model`). This plan only removes them from the FILE.
- **Never kill the port 8081 server.** Functional tests use ports 8080–8199 via the harness.
- **Verification:** `zig build test --summary all` for unit/static tests; python functional harness for wire behavior; `npm run build` (or `vue-tsc --build`) for frontend type-check.
- **Backward compat:** an OLD config.json that still has top-level keys must keep loading identically (backfill is a no-op when keys are present).
- **Migration-on-load, not migration script:** no separate migration tooling; the rewrite happens naturally the next time the user saves settings (PUT rewrites the file without those keys) — or immediately via Task 6's one-time cleanup of the live config.

### Current on-disk shape (before)

```json
{
  "api_key": "sk-...",
  "model": "MiniMax-M3",
  "base_url": "https://api.minimax.io/v1",
  "url_style": "openai",
  "max_tokens": null,
  "system_prompt": "",
  "profiles_models": { ... },
  "active_profile": "alpha model",
  "mcp_servers": null,
  "notify_on_complete": true,
  "model_compaction_size_kb": 100,
  "max_capacity_token_model": 500000,
  "compaction_threshold_percent": 95,
  "retry_delay_ms": 10000,
  "sub_agents": null
}
```

### Target on-disk shape (after)

```json
{
  "profiles_models": { ... },
  "active_profile": "alpha model",
  "mcp_servers": null,
  "notify_on_complete": true,
  "model_compaction_size_kb": 100,
  "max_capacity_token_model": 500000,
  "compaction_threshold_percent": 95,
  "retry_delay_ms": 10000,
  "sub_agents": null
}
```

(`max_tokens` / `system_prompt` are dropped entirely — nothing reads them at runtime; see Task 5.)

---

## Background: who reads what today

| Site | What it reads | Why it survives unchanged |
|---|---|---|
| `Config.zig` `resolveEffectiveProfile` (~1242–1261) | `self.model/base_url/api_key/url_style` as cascade step 3 | Backfill makes these hold profile values |
| `Config.zig` `buildResolvedFromConfig` (~1515–1518) | `self.*` as sub-agent overlay base | Same |
| `Config.zig` `resolveSubAgent` random fallback (~1441–1444) | `self.*` | Same |
| `Config.zig` `validate` (~1111–1123) | requires non-empty api_key/model/base_url | Backfill satisfies it; test updated to assert backfill |
| `workflow.zig:1226` | `config.api_key, config.base_url` → handle_tool ctx | Reads the struct fields — untouched |
| `handle_tool.zig` ToolContext (46–47) → `tools_exec_generate_image.zig` (59–60) | ctx api_key/base_url for image gen | Untouched; now gets profile creds |
| `session_compact.zig:43–54` | `live_cfg.model/api_key/base_url/url_style` | Untouched |
| `llm_history.zig:773` | `cfg.model` for max-capacity cascade | Untouched |
| `pabrik_config_get.zig:101–107` | returns top-level fields to frontend | Now returns backfilled (profile) values — correct UX |
| `pabrik_config_put.zig:104–139` | writes top-level fields from PUT body | Task 3 removes these writes |
| `PabrikSettings.vue` DefaultsSection | edits top-level defaults UI | Task 4 removes the tab |

---

## Task 1 — Load-time backfill in `LlmConfig.init`

**Files:** `src/modules/config/Config.zig` (+ tests in same file bottom / `config_test.zig`)

- [ ] Write failing test: parse a config JSON string with NO top-level `api_key/model/base_url/url_style` but WITH `profiles_models` containing one populated profile and `active_profile` naming it → after `init`, `cfg.model == profile.model`, `cfg.base_url == profile.base_url`, `cfg.api_key == profile.api_key`, `cfg.url_style == profile.url_style`.
- [ ] Write failing test: same but `active_profile` names a MISSING profile → falls back to the FIRST profile entry (iteration order caveat: use a single-profile fixture to keep the test deterministic; document multi-profile order as unspecified).
- [ ] Write failing test: old-style config WITH top-level keys present → keys win, backfill does not overwrite (backward compat).
- [ ] Implement: in `LlmConfig.init`, after building `config` and AFTER the profiles_models parsing block (~line 582), add a backfill step:

```zig
// Plan 2026-08-24-config-simplify-remove-defaults:
// Top-level LLM defaults are no longer stored in config.json.
// When absent/empty, derive them from the active profile so every
// downstream consumer of cfg.model/api_key/base_url/url_style keeps
// working unchanged. Present keys always win (backward compat).
fn backfillTopLevelFromProfiles(config: *LlmConfig) !void {
    if (config.model.len > 0 and config.base_url.len > 0 and config.api_key.len > 0) return;
    // resolveSessionProfileCompat walks selected→active; here selection
    // is just active_profile (no session context at load time).
    const p = config.resolveSessionProfileCompat("") orelse {
        // No usable profile: leave empty strings (validate() will warn
        // exactly as it does today for a blank first-run config).
        return;
    };
    if (config.model.len == 0) config.model = try config.allocator.dupe(u8, p.model);
    if (config.base_url.len == 0) config.base_url = try config.allocator.dupe(u8, p.base_url);
    if (config.api_key.len == 0) config.api_key = try config.allocator.dupe(u8, p.api_key);
    if (config.url_style.len == 0 or std.mem.eql(u8, config.url_style, "openai") == false) {
        // url_style has a non-empty default ("openai") so absence can't be
        // detected by len==0. Rule: if the key was ABSENT in JSON we still
        // get "openai" from LlmConfigJson's default — accept that, but if a
        // profile explicitly sets another style AND the file had no explicit
        // top-level key, prefer the profile's. Track absence via the raw
        // parsed value instead (see implementation note below).
    }
}
```

  **Implementation note (url_style):** `LlmConfigJson.url_style` defaults to `"openai"`, so "absent" and "explicitly openai" are indistinguishable post-parse. Simplest correct rule: when backfilling ANY field from the profile, also copy `p.url_style` over the default IF the profile's url_style is non-empty. This matches user intent (the profile defines the wire format). Add a dedicated test for this.
- [ ] Call `try backfillTopLevelFromProfiles(&config);` right before `return config;` in `init` (after sub_agents parse). Ensure errdefer ordering stays correct (backfilled dupes are covered by the existing errdefer frees).
- [ ] Run `zig build test --summary all` → new tests pass, suite green.
- [ ] Commit: `feat(config): backfill top-level LLM defaults from active profile on load`

## Task 2 — `writeDefaultConfig` emits the new minimal shape

**Files:** `src/modules/config/Config.zig` (`defaultConfigJson` ~1589), `config_test.zig` (~1158, ~1201)

- [ ] Update `defaultConfigJson` to:

```
{
  "profiles_models": {},
  "active_profile": null,
  "model_compaction_size_kb": 100,
  "notify_on_complete": false,
  "retry_delay_ms": 0,
  "max_capacity_token_model": null,
  "compaction_threshold_percent": null
}
```
- [ ] Update the two `writeDefaultConfig` tests' assertions (they currently check the file parses and contains placeholders — adjust expected content; also assert `"api_key"` is NOT in the output).
- [ ] Verify the auto-init flow still works: `LlmConfig.init` on the freshly written default must not crash (empty profiles → backfill no-op → validate warns, same as today's blank config).
- [ ] Run `zig build test --summary all`.
- [ ] Commit: `feat(config): writeDefaultConfig emits minimal profile-only shape`

## Task 3 — PUT handler stops persisting top-level defaults

**Files:** `src/ai_workflow/tui/http_handlers/pabrik_config_put.zig`, static-contract tests `pabrik_config_put_test.zig` / `pabrik_config_put_parse_test.zig`

- [ ] In `pabrikConfigPutHandler`, DELETE the apply blocks for `input.api_endpoint / api_key / model / url_style / max_tokens / system_prompt` (lines ~104–139). Keep `ConfigInput` accepting these fields (ignore-and-drop) so old frontends / curl scripts don't 400 — `ignore_unknown_fields` already tolerates extra keys, but the named fields remain in the struct harmlessly; alternatively remove them from `ConfigInput` too since unknown fields are ignored either way. **Choose removal from `ConfigInput`** for cleanliness; the parser ignores them.
- [ ] Remove the corresponding fields from the handler-local `ConfigJson` write struct ONLY where safe: `api_key/model/base_url/url_style/max_tokens/system_prompt` must go so `Stringify.valueAlloc` doesn't re-emit them on save. (This struct is the on-disk serializer — removing the fields removes the keys from the saved file.)
- [ ] Update static-contract tests that grep for these apply blocks; add one asserting the strings `"api_endpoint"` / `"system_prompt"` no longer appear in the handler source (source-grep pattern used by sibling tests).
- [ ] Add/adjust functional test later (Task 7) — here just keep unit/static green.
- [ ] Run `zig build test --summary all`.
- [ ] Commit: `refactor(config-put): stop persisting top-level LLM defaults`

## Task 4 — Frontend: remove the Defaults tab

**Files:** `src/apps/desktop/src/components/PabrikSettings.vue`, `src/apps/desktop/src/components/pabrik/PabrikTabStrip.vue`, `DefaultsSection.vue` (delete or retire), `usePabrikConfig.ts`, `api/index.ts` types

- [ ] `PabrikTabStrip.vue`: remove the `'defaults'` tab entry (keep `profiles` as the landing tab; change `PabrikSettings.vue` `activeTab` initial value `'defaults'` → `'profiles'`).
- [ ] `PabrikSettings.vue`: drop `DefaultsSection` import + render branch; drop `defaultsConfig` ref and its syncFrom/syncTo wiring; drop `LEGACY_LS_KEYS` localStorage fallback block (it exists solely to seed the removed defaults form).
- [ ] `syncToConfig`: stop sending `api_endpoint/api_key/model/url_style/temperature/max_tokens/system_prompt` in the PUT body (backend now ignores them anyway, but stop sending per YAGNI).
- [ ] Types: trim `PabrikConfig` in `api/index.ts` (remove `api_endpoint?`, `temperature?`, `max_tokens?`, `system_prompt?`; keep `api_key/model/url_style` ONLY if GET still returns them — it does, as backfilled display values; mark optional and unused).
- [ ] Delete `DefaultsSection.vue` if nothing else imports it (check with search first); otherwise retire.
- [ ] Run `cd src/apps/desktop && npm run build` (vue-tsc clean) and `npm run test:unit` (update any PabrikSettings.spec.ts coverage of the defaults tab).
- [ ] Commit: `refactor(frontend): remove Defaults tab — profiles are the only LLM config surface`

## Task 5 — Drop dead `max_tokens` / `system_prompt` handling

**Files:** `pabrik_config_get.zig` (ConfigJson + response), `http_response.zig` (`makePabrikConfigResponse` shape)

- [ ] Confirm nothing consumes the GET response's `max_tokens`/`system_prompt` besides the removed DefaultsSection (search frontend for `max_tokens` / `system_prompt` usages under `src/apps/desktop/src` — agent-level system prompts are a DIFFERENT feature served by `/api/agents/:id/system_prompt`, untouched).
- [ ] Remove `max_tokens`/`system_prompt` from `pabrik_config_get.zig`'s `ConfigJson` and response payload; adjust `makePabrikConfigResponse` accordingly.
- [ ] Note: `LlmConfigJson` (Config.zig) never had these fields — no backend runtime change needed.
- [ ] Run `zig build test --summary all` + frontend build/tests.
- [ ] Commit: `chore(config): drop unused max_tokens/system_prompt from config wire`

## Task 6 — One-time cleanup of the live config file

**Files:** none (user's `~/.config/pabrik/config.json`)

- [ ] After Tasks 1–5 land and the binary is rebuilt/restarted, hand-edit `~/.config/pabrik/config.json` to delete the six keys (`api_key`, `model`, `base_url`, `url_style`, `max_tokens`, `system_prompt`). Keep everything else byte-identical.
- [ ] Restart the desktop app; verify a chat on each profile still calls the right endpoint (check `[CHECKPOINT] eff.model=` log line).
- [ ] No commit (user config, not repo).

## Task 7 — Functional verification (wire round-trip)

**Files:** `tests/functional/config_simplify_test.py` (new)

- [ ] Using the harness (`tests/functional/harness.py`, isolated tmpdir HOME, free port 8080–8199):
  1. Seed a config.json WITHOUT top-level defaults but WITH one profile + active_profile.
  2. Boot binary; `GET /api/config/pabrik` → assert `api_key/model/base_url/url_style` equal the PROFILE's values (backfill visible on the wire).
  3. `PUT /api/config/pabrik` with a body that omits the defaults entirely (exactly what new frontend sends) → assert 200, re-read the on-disk file, assert the six keys are ABSENT and `profiles_models` intact.
  4. Old-format compat: seed WITH top-level keys → boot → assert GET returns the top-level values (not overwritten by backfill).
- [ ] Run: `PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/config_simplify_test.py -v`
- [ ] Full suites: `zig build test --summary all` + `npm run test:unit`.
- [ ] Commit: `test(functional): config-simplify wire round-trip coverage`

---

## Risks / Notes

- **Profile iteration order:** HashMap iteration is unordered; the "first profile" fallback for a missing `active_profile` is nondeterministic with multiple profiles. Mitigation: docs say active_profile should always name a real profile; the deterministic-path tests use one profile. If the user wants determinism later, sort keys at backfill time (follow-up card).
- **generate_image tool:** uses `ctx.base_url/api_key` which come from `config.api_key/base_url` at workflow.zig:1226 — after backfill these are the ACTIVE PROFILE's creds, which is arguably more correct than today's stale top-level key. Behavior change is intentional and desirable.
- **Sub-agent overlay base:** `buildResolvedFromConfig` overlays onto `self.*` (top-level). After backfill, sub-agents inherit the active profile's creds instead of the removed Defaults-tab values — consistent with the cascade philosophy documented at Config.zig:1505–1514. The comment there should be updated to mention backfill (small doc edit in Task 1).
- **Rollback:** trivially reversible — re-adding the six keys to config.json restores old behavior (present keys win over backfill).
