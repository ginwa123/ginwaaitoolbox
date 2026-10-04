# Fix UI Model Context Window — Profile Override Not Reflected in Chat Footer

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the chat footer's context-window readout (`43,988 / 500,000`) reflect the session's selected profile's `max_capacity_tokens` override (e.g. 950,000) instead of always showing the built-in per-model default.

**Architecture:** The backend's `GET /api/llm/session/:id/messages` handler computes `max_capacity_total_tokens` via `LlmConfig.maxCapacityForModel(null, null, cfg, cfg.model)` — it passes `null` for the profile, so the session's `selected_profile_model` override never reaches the UI. The fix re-reads `sessions.selected_profile_model` (the same query the workflow loop already uses), resolves the profile via `config.getProfile()`, and passes it into the cascade. The same bug exists in the compaction threshold decision (`shouldCompactDefault`), which also passes `null` profile — fixed in the same pass so the UI number and the actual compaction behavior agree.

**Tech Stack:** Zig 0.16 backend (`src/ai_workflow/tui/agentic_loop/llm_history.zig`, `workflow_commpact_message.zig`, `workflow.zig`), Vue 3 frontend (no changes needed — it already renders whatever the backend sends).

## Global Constraints

- Zig 0.16: `const` over `var` for single-init vars; SQLite argv is string-typed only.
- Per-request arena allocator: do NOT `defer allocator.free()` anything allocated via `ctx.allocator` (arena wipes it). Keep `defer rows.deinit()` for SQLite statement handles.
- `zig build test --summary all` must pass with 0 failures before commit.
- Do NOT kill the port 8081 server; use 8080 for any manual testing.
- Match the existing `re_read_selected_profile_model` pattern in `workflow.zig:267` for DB re-reads (dupe into caller's allocator, fall back gracefully on error).

## Root Cause (verified)

**Symptom:** Chat footer shows `43,988 / 500,000` while the active profile "alpha model" has `max_capacity_tokens = 950000` (screenshot: Edit profile dialog shows "Override the context window" checked, Max capacity 950000).

**Data flow today:**

```
Frontend ChatView.vue:1347  ←  GET /api/llm/session/:id/messages
  ← session_messages_get.zig:101  ←  llm_history.getSessionMessagesSorted()
       llm_history.zig:739-755:
         .max_capacity_total_tokens = blk: {
             const di_opt = pabrikcore.getSingleton() catch null;
             if (di_opt) |di| {
                 const cfg = pabrikcore.getLlmConfig(di);
                 // ← passes null for profile AND sub_agent
                 break :blk cfg.maxCapacityForModel(null, null, cfg, cfg.model);
             }
             break :blk llm_models.getModelTokenCount("");
         };
```

`maxCapacityForModel` cascade (`Config.zig:1297-1309`):
1. `sub_agent.max_capacity_tokens` — skipped (null)
2. `profile.max_capacity_tokens` — **skipped (null) ← THE BUG**
3. `defaults.max_capacity_token_model` (Defaults tab top-level override)
4. `LLMModels.getModelTokenCount(model)` — built-in table → **500,000** for the configured model

The session row HAS `selected_profile_model = "alpha model"` (the profile chip in the footer proves the frontend knows it), and `alpha model.max_capacity_tokens = 950000`. But step 2 is never reached because the call site hardcodes `null`.

**Secondary instance of the same bug** — the compaction *decision* itself, `shouldCompactDefault` (`workflow_commpact_message.zig:187-194`):

```zig
return agent.LLMModels.shouldCompact(
    ctx.total_tokens,
    ctx.llm_config.maxCapacityForModel(null, null, ctx.llm_config, ctx.model),  // ← null profile
    ctx.llm_config.compactionThresholdPercent(null, null, ctx.llm_config),      // ← null profile
);
```

So even the backend's own compaction trigger ignores the profile override — a session with a 950k override would compact at 80% of 500k = 400k instead of 80% of 950k = 760k. The UI number and the actual behavior must agree, so both call sites get fixed.

**Not broken:** the frontend (`ChatView.vue:1347-1349`, `api/index.ts:1148/1204`) — it faithfully renders `data.max_capacity_total_tokens`. No frontend change needed.

## File Map

| File | Change |
|---|---|
| `src/ai_workflow/tui/agentic_loop/llm_history.zig` | `getSessionMessagesSorted` gains a `profile_name: []const u8` param; resolve profile + pass to `maxCapacityForModel` |
| `src/ai_workflow/tui/http_handlers/session_messages_get.zig` | Read `sessions.selected_profile_model` and pass it through |
| `src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig` | `ThresholdCtx` gains `profile: ?*const LlmProfile`; `shouldCompactDefault` uses it |
| `src/ai_workflow/tui/agentic_loop/workflow.zig` | Resolve profile once per iteration; pass into `maybeCompactMessagesNew` deps context |
| `src/ai_workflow/tui/http_handlers/session_compact.zig` | Same resolution for the manual compact endpoint |
| Tests: `session_messages_get_test.zig`, `workflow_compact_message.zig` (test block), `config_test.zig` (already covers cascade) | New cases pinning the profile-aware behavior |

## Task 1 — Backend: profile-aware `max_capacity_total_tokens` in the messages endpoint

**Files:** `llm_history.zig`, `session_messages_get.zig`, `session_messages_get_test.zig`

- [ ] **1.1 Write failing test** — in `session_messages_get_test.zig`, add a test next to the existing wire-shape test (line 204): seed a session with `selected_profile_model = '900ribu'`, seed a profile named `900ribu` with `max_capacity_tokens = 950000` in the LlmConfig used by the singleton (or construct the config directly if the test harness allows), call `getSessionMessagesSorted`, assert `resp.max_capacity_total_tokens == 950000`. Run it — must FAIL with 500000 (or the built-in default).
  - Note: `getSessionMessagesSorted` currently pulls the config from `pabrikcore.getSingleton()`. For testability, prefer adding an optional `profile: ?*const LlmProfile = null` parameter (defaults null) that, when non-null, is passed straight to `maxCapacityForModel(profile, null, cfg, cfg.model)`. The handler resolves the profile by name and passes it; tests pass it directly without needing the singleton.
- [ ] **1.2 Implement** — in `llm_history.zig`:
  - Add param `profile: ?*const config_mod.LlmProfile` to `getSessionMessagesSorted` (after the existing sort param; update all call sites — grep `getSessionMessagesSorted(` — there are few: the HTTP handler + tests).
  - In the `.max_capacity_total_tokens = blk:` block (lines 739-755), replace `cfg.maxCapacityForModel(null, null, cfg, cfg.model)` with `cfg.maxCapacityForModel(profile, null, cfg, cfg.model)`.
  - In `session_messages_get.zig` (the handler), before calling `getSessionMessagesSorted`: read the session's profile name. The response already carries `selected_profile_model` (llm_history.zig:261/289 does the COALESCE query internally) — reuse that returned value: `const profile = if (resp_snapshot.selected_profile_model) |name| (if (name.len > 0) cfg.getProfile(name) else null) else null;` — resolve BEFORE building the response struct, pass into the call. If the handler currently calls `getSessionMessagesSorted` once and uses the result for both, order the calls so the profile name is available before the capacity is computed (may require splitting the single call into: fetch messages → resolve profile → compute capacity, or adding a tiny `getSessionProfileName(allocator, db, session_id) []const u8` helper mirroring `re_read_selected_profile_model`'s query).
  - Graceful degradation: profile name empty / not found → pass `null` → existing cascade (Defaults tab → built-in) applies. No error path.
- [ ] **1.3 Run tests** — `zig build test --summary all`. New test passes; all existing tests pass (update the 2-3 existing call sites in tests to pass `null`).
- [ ] **1.4 Commit** — `fix(ui): messages endpoint returns profile-aware max_capacity_total_tokens`

## Task 2 — Backend: profile-aware compaction threshold decision

**Files:** `workflow_commpact_message.zig`, `workflow.zig`, `session_compact.zig`

- [ ] **2.1 Write failing test** — in `workflow_commpact_message.zig`'s test block (near line 1676 where `maxCapacityForModel` cascade tests live): construct `ThresholdCtx` with a profile whose `max_capacity_tokens = 400_000` and `compaction_threshold_percent = 50`, `total_tokens = 210_000`. Assert `shouldCompactDefault(ctx) == true` (210k > 50% of 400k = 200k). With the current null-profile code the effective cap is the built-in (500k) → 80% = 400k → false. Must FAIL first.
- [ ] **2.2 Implement** —
  - `ThresholdCtx` (workflow_commpact_message.zig:146): add field `profile: ?*const LlmProfile = null`.
  - `shouldCompactDefault` (line 187): use `ctx.profile` in both cascade calls:
    ```zig
    ctx.llm_config.maxCapacityForModel(ctx.profile, null, ctx.llm_config, ctx.model),
    ctx.llm_config.compactionThresholdPercent(ctx.profile, null, ctx.llm_config),
    ```
  - `maybeCompactMessagesNew` (line 247 where `deps.shouldCompact(.{...})` is built): it needs the profile. Add a `profile: ?*const LlmProfile` parameter (update all ~11 test call sites in the same file to pass `null` — mechanical), thread it into the `ThresholdCtx` literal.
  - `workflow.zig:974` call site: resolve the profile once per loop iteration, right where `live_selected_profile_model` is already re-read (the `re_read_selected_profile_model` helper at line 267 already returns the name; add `const iter_profile: ?LlmProfile = if (live_selected_profile_model.len > 0) config.getProfile(live_selected_profile_model) else null;` — note `getProfile` returns an owned-or-borrowed `LlmProfile` by value; check its signature at Config.zig:1093 and keep the value alive in the per-iteration arena). Pass `iter_profile` into `maybeCompactMessagesNew`.
  - `session_compact.zig:82` (manual compact endpoint): same resolution — it already has `di`/config in scope; read the session's `selected_profile_model` (one COALESCE query, mirror `re_read_selected_profile_model`), resolve via `getProfile`, pass through.
- [ ] **2.3 Run tests** — `zig build test --summary all`. New test passes; the ~11 mechanical call-site updates compile; full suite green.
- [ ] **2.4 Commit** — `fix(compaction): honor session profile override in threshold decision`

## Task 3 — Verify end-to-end + wire check

- [ ] **3.1 Full suite** — `zig build test --summary all` → 0 fail, 0 leak.
- [ ] **3.2 Manual verification** (optional, if a dev server is available on port **8080** — never 8081): open a chat with the "alpha model" profile selected, footer must show `/ 950,000`; switch profile to Default → falls back to built-in/Defaults-tab value.
- [ ] **3.3 Frontend sanity** — no frontend change required; confirm `ChatView.vue` renders the new number without code changes (it already does `maxCapacityTotalTokens.value = data.max_capacity_total_tokens`).
- [ ] **3.4 Commit any remaining bits + move kanban card** to `in_review_task` with a summary for human review.

## Pitfalls

- **`getProfile` returns `?LlmProfile` by value** (Config.zig:1093) — the returned struct borrows strings from the config; keep the config alive (it's the process-lifetime singleton) and don't free anything.
- **Don't resolve the profile inside `getSessionMessagesSorted` from the singleton** — tests can't control the singleton. Pass it in (dependency injection), resolve at the HTTP handler layer where the singleton is legitimately reachable.
- **Arena discipline:** the handler runs under the per-request arena — no `defer free` on arena allocations; keep `defer rows.deinit()` on SQLite handles.
- **Existing tests call `getSessionMessagesSorted` and `maybeCompactMessagesNew` directly** — every new parameter needs `null`/default at those call sites or the suite won't compile. Grep before finalizing signatures.
- **Do not "fix" the frontend** — it's already correct; changing it would mask the backend bug.

## Verification

- [ ] New test: session with profile override → `max_capacity_total_tokens == 950000` (fails before, passes after)
- [ ] New test: `shouldCompactDefault` honors profile cap/threshold (fails before, passes after)
- [ ] `zig build test --summary all` → 0 failures
- [ ] Manual: footer shows 950,000 with alpha model selected
