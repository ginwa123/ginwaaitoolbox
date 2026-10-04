# Consistent Profile Resolution Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 6 hand-rolled profile-cascade blocks in `workflow.zig` (and the near-duplicate in `Config.resolveSubAgent`) with one typed, unit-tested `LlmConfig.resolveEffectiveProfile()` helper, so every consumer resolves profile fields through the identical cascade.

**Architecture:** Add a single `EffectiveProfile` struct + `resolveEffectiveProfile()` method on `LlmConfig` (in `src/modules/config/Config.zig`, where the config types live). It walks the canonical cascade **selected_profile → active_profile → top-level** once, returning all 9 fields as a typed value. `workflow.zig` then calls it exactly twice per run (entry + per-iteration re-read) instead of maintaining ~120 lines of copy-pasted cascade code. The existing string-only `resolveProfileField()` and the existing `llm_history.resolveSessionProfile()` are consolidated onto the same primitive.

**Tech Stack:** Zig 0.16, no new dependencies, no schema/migration changes, no frontend changes.

## Global Constraints

- **No behavior change.** Every resolved value must be byte-identical before/after. The refactor is verified by: (a) porting the existing inline tests' expectations onto the new helper, (b) `zig build test --summary all` staying at baseline (2401 pass / 6 skip / 0 fail modulo known pre-existing failures), (c) grep-proofs that no hand-rolled cascade remains.
- **Cascade precedence is frozen:** `selected_profile_model` (non-empty AND profile exists AND field non-empty/non-null) → `config.active_profile` (non-null AND non-empty AND profile exists AND field set) → top-level fallback (`config.model` / `"auto"` / `null`). This matches `resolveProfileField` today (workflow.zig:218-246).
- **Borrowed memory only.** All returned strings borrow from the `LlmConfig` singleton (process-lifetime; kept alive across swaps by `LlmConfigHolder.previous`). No allocation, no free, no arena coupling. Callers must not free or retain beyond the current iteration's use of `config`.
- **Surgical patching:** do not refactor unrelated parts of workflow.zig. The `sub_agent_overrides` block (lines ~964-994) stays as-is — it is override logic, not cascade logic.
- Do NOT touch port 8081. Verification via `zig build test --summary all` only (no live server needed for this pure-refactor task).
- Plan doc lives at `docs/superpowers/plans/2026-08-23-refactor-profile-resolution.md`.

## Background — the duplication being removed

All of these walk the same cascade by hand:

| # | Site | What it resolves | Lines |
|---|------|------------------|-------|
| 1 | `workflow.zig:431-434` (entry) | api_key/model/base_url/url_style | 4 |
| 2 | `workflow.zig:453-516` (entry) | thinking_str + budget_tokens + reasoning_effort | ~64 |
| 3 | `workflow.zig:743-746` (per-iter) | api_key/model/base_url/url_style | 4 |
| 4 | `workflow.zig:754-804` (per-iter) | thinking_str + budget_tokens + reasoning_effort | ~51 |
| 5 | `workflow.zig:823-833` (per-iter) | whole `?LlmProfile` for compaction | ~11 |
| 6 | `Config.zig:1358-1366+` (`buildResolvedFromConfig`) | model/base_url/api_key/url_style overlay | ~10 |

Plus two existing helpers that ARE the cascade but aren't reused:
- `workflow.zig:218` `resolveProfileField(field)` — string fields only, comptime field name
- `llm_history.zig:857` `resolveSessionProfile(cfg, selected)` — whole-profile, but lives in llm_history (wrong layer), so Config can't call it and workflow doesn't

After this refactor there is exactly ONE implementation of the cascade:
`LlmConfig.resolveEffectiveProfile(selected_profile_model)` in Config.zig.

### Field-by-field resolution table (the contract)

| Field | Type | Step 1 (selected) | Step 2 (active) | Step 3 (top-level) |
|---|---|---|---|---|
| `model` | []const u8 | profile.model if len>0 | profile.model if len>0 | `config.model` |
| `base_url` | []const u8 | profile.base_url if len>0 | profile.base_url if len>0 | `config.base_url` |
| `api_key` | []const u8 | profile.api_key if len>0 | profile.api_key if len>0 | `config.api_key` |
| `url_style` | []const u8 | profile.url_style if len>0 | profile.url_style if len>0 | `config.url_style` |
| `thinking_str` | []const u8 | profile.thinking if len>0 | profile.thinking if len>0 | `"auto"` |
| `is_thinking` | ?bool | parseThinkingString(thinking_str) catch null | — (derived once from final str) | — |
| `thinking_adaptive` | bool | `eql(str,"auto")` | — (derived once) | — |
| `thinking_budget_tokens` | ?u32 | profile.thinking_budget_tokens | profile.thinking_budget_tokens | `null` |
| `reasoning_effort` | ?[]const u8 | profile.reasoning_effort if len>0 | profile.reasoning_effort if len>0 | `null` |

Note: `is_thinking` / `thinking_adaptive` are DERIVED from the final `thinking_str` (not cascaded independently) — this preserves today's semantics exactly (workflow.zig:471, 477).

---

## Task 1 — Add `EffectiveProfile` + `resolveEffectiveProfile()` to Config.zig (TDD)

**Files:** `src/modules/config/Config.zig` (edit), `src/modules/config/config_test.zig` (edit)

- [ ] 1.1 Write failing tests first in `src/modules/config/config_test.zig`. Build an `LlmConfig` fixture in-memory (mirror the pattern used by "model-thinking knobs" tests at config_test.zig:598-653 — construct profiles map directly, no disk JSON needed). Tests to write:
      - selected profile wins over active_profile for every field (string + optional)
      - active_profile wins over top-level when selected empty
      - missing selected profile name falls through to active_profile
      - empty-string active_profile falls through to top-level
      - profile field EMPTY falls through for THAT field only (partial profile)
      - no selection + null active → pure top-level defaults (`model`=cfg.model, `thinking_str`="auto", `budget`=null, `effort`=null)
      - derived fields: thinking="on" → is_thinking=true, adaptive=false; "off" → false/false; "auto" → null/true; garbage → null/is_thinking + adaptive=false (garbage ≠ "auto")
      - `resolveSessionProfileCompat`: returns same ?LlmProfile as old resolveSessionProfile for selected-hit / active-hit / miss cases
- [ ] 1.2 Run `zig build test --summary all` — confirm the new tests FAIL to compile (helper doesn't exist yet). That's the red step.
- [ ] 1.3 Implement in `src/modules/config/Config.zig` inside `pub const LlmConfig = struct { ... }` (place after `getProfile` at line ~1164):

```zig
/// Fully-resolved effective settings for one LLM call, produced by
/// walking the canonical profile cascade. All strings BORROW from
/// the LlmConfig singleton — never free, never outlive the config.
pub const EffectiveProfile = struct {
    model: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    url_style: []const u8,
    /// Raw resolved `thinking` string ("auto" default).
    thinking_str: []const u8,
    /// Derived: parseThinkingString(thinking_str) catch null.
    is_thinking: ?bool,
    /// Derived: std.mem.eql(u8, thinking_str, "auto").
    thinking_adaptive: bool,
    thinking_budget_tokens: ?u32,
    reasoning_effort: ?[]const u8,
};

/// THE canonical profile cascade. Walks:
///   1. `selected_profile_model` (non-empty, profile exists, field set)
///   2. `active_profile`          (non-empty, profile exists, field set)
///   3. top-level defaults
/// One implementation; every consumer must go through here.
pub fn resolveEffectiveProfile(
    self: *const LlmConfig,
    selected_profile_model: []const u8,
) EffectiveProfile {
    const sel = self.getProfileIfSet(selected_profile_model);
    const act = if (sel == null) self.getProfileIfSet(self.active_profile orelse "") else null;
    const p = sel orelse act;
    const fb = EffectiveProfile{ // top-level fallbacks
        .model = self.model,
        .base_url = self.base_url,
        .api_key = self.api_key,
        .url_style = self.url_style,
        .thinking_str = "auto",
        .is_thinding_placeholder_do_not_use = undefined, // (removed in real impl)
        ...
    };
    ... // per-field: take from p when set, else fb
}
```

(Real implementation: pick each field from the winning profile when non-empty/non-null, else the top-level fallback; derive `is_thinking`/`thinking_adaptive` ONCE from the final `thinking_str` via `parse_thinking.parseThinkingString(...) catch null` and `std.mem.eql(u8, str, "auto")`. Also add tiny private helper `fn getProfileIfSet(self, name: []const u8) ?LlmProfile` returning null for empty names.)

- [ ] 1.4 Add thin compat wrapper (same file):
```zig
/// Backward-compat shim for llm_history.resolveSessionProfile callers.
pub fn resolveSessionProfileCompat(
    self: *const LlmConfig,
    selected_profile_model: []const u8,
) ?LlmProfile {
    const e = self.resolveEffectiveProfile(selected_profile_model);
    return self.getProfile(effective_source_name); // see note
}
```
NOTE: simpler + exact — implement it directly as the existing 3-step lookup (selected → active → null), i.e. move the body of `llm_history.resolveSessionProfile` here verbatim. Do NOT reconstruct from EffectiveProfile (the winning profile NAME is lost in the struct). Keep both lookups in one place with a shared private `getProfileIfSet`.
- [ ] 1.5 Run `zig build test --summary all` — new tests PASS, zero regressions elsewhere.
- [ ] 1.6 Commit: `refactor(config): add resolveEffectiveProfile — single typed profile cascade`

## Task 2 — Rewire `llm_history.resolveSessionProfile` onto the new helper

**Files:** `src/ai_workflow/tui/agentic_loop/llm_history.zig` (edit)

- [ ] 2.1 Keep the public signature `pub fn resolveSessionProfile(cfg, selected_profile_model) ?LlmProfile` (3 external callers depend on it: session_compact.zig:72, session_messages_get.zig:72, plus tests). Replace the body with a delegation: `return cfg.resolveSessionProfileCompat(selected_profile_model);` Update the doc comment to point at Config.resolveEffectiveProfile as the source of truth.
- [ ] 2.2 Run `zig build test --summary all` — pass.
- [ ] 2.3 Commit: `refactor(llm_history): delegate resolveSessionProfile to Config cascade`

## Task 3 — Rewire `resolveProfileField` + delete entry-block duplication in workflow.zig

**Files:** `src/ai_workflow/tui/agentic_loop/workflow.zig` (edit)

- [ ] 3.1 At workflow entry (~line 430), replace lines 431-516 with:

```zig
var config = pabrikcore.getLlmConfig(di.di);
var eff = config.resolveEffectiveProfile(params.selected_profile_model);

logger.infoFmt(
    "[CHECKPOINT] profile selected_profile_model='{s}' effective_model={s} effective_base_url={s} effective_url_style={s} effective_thinking_str={s} effective_thinking_budget_tokens={?d} effective_reasoning_effort={?s}",
    .{ params.selected_profile_model, eff.model, eff.base_url, eff.url_style, eff.thinking_str, eff.thinking_budget_tokens, eff.reasoning_effort },
);
```

- [ ] 3.2 Delete `resolveProfileField` (workflow.zig:203-246) and its inline test block (workflow.zig:1913-2057). The cascade now has ONE home with its own tests in config_test.zig.
- [ ] 3.3 Mechanical rename across the remaining function body (all within runAgenticMultiStepnew): `effective_api_key`→`eff.api_key`, `effective_model`→`eff.model`, `effective_base_url`→`eff.base_url`, `effective_url_style`→`eff.url_style`, `effective_thinking_str`→`eff.thinking_str`, `effective_is_thinking`→`eff.is_thinking`, `effective_thinking_adaptive`→`eff.thinking_adaptive`, `effective_thinking_budget_tokens`→`eff.thinking_budget_tokens`, `effective_reasoning_effort`→`eff.reasoning_effort`. Known touch points: log at 518-521 (done above), user-message INSERT `.is_thinking = eff.is_thinking orelse initial_agent_state.is_thinking` (~912), sub-agent override block (~979-991), compaction call (~1179 uses iter_profile — handled in Task 4), callDynamicAgentNew (~1197).
- [ ] 3.4 Run `zig build test --summary all` — compile clean, tests pass.
- [ ] 3.5 Commit: `refactor(workflow): entry block resolves via resolveEffectiveProfile`

## Task 4 — Collapse the per-iteration re-resolution block

**Files:** `src/ai_workflow/tui/agentic_loop/workflow.zig` (edit)

- [ ] 4.1 In the loop body, keep the live re-reads (`config = pabrikcore.getLlmConfig(di.di)` at 715, `live_selected_profile_model` at 728-733, the missing-profile warning at 738-742) — those are NOT duplication. Replace ONLY the duplicated cascade: lines 743-746 (4× resolveProfileField), 754-804 (thinking/budget/effort hand-rolled), and 823-833 (iter_profile) become:

```zig
eff = config.resolveEffectiveProfile(live_selected_profile_model);
const iter_profile: ?config_mod.LlmConfig.LlmProfile =
    config.resolveSessionProfileCompat(live_selected_profile_model);
```

Delete the promote-back block (808-812) — `eff` IS the live variable now.
- [ ] 4.2 Verify downstream consumers still compile: `maybeCompactMessagesNew(..., if (iter_profile) |*p| p else null)` at 1179 — NOTE: check whether it needs `|*p|` capture against a const local; adjust to `if (iter_profile) |p| &tmp_profile else null` pattern if the compiler requires a pointer (keep semantics identical). `callDynamicAgentNew(..., eff.is_thinking-derived isThinking, eff.thinking_budget_tokens, eff.thinking_adaptive, eff.reasoning_effort, eff.api_key, eff.model, eff.base_url, eff.url_style, ...)` at 1197.
- [ ] 4.3 Sub-agent override block (~964-994): mechanical rename only (`ov.is_thinking` writes `isThinking` AND `eff.is_thinking`; `ov.thinking_budget_tokens` → `eff.thinking_budget_tokens`; etc.). NO logic change.
- [ ] 4.4 Run `zig build test --summary all` — pass.
- [ ] 4.5 Commit: `refactor(workflow): per-iteration re-resolution via resolveEffectiveProfile (-115 lines)`

## Task 5 — Consolidate `buildResolvedFromConfig` overlay onto the cascade

**Files:** `src/modules/config/Config.zig` (edit)

- [ ] 5.1 In `buildResolvedFromConfig` (Config.zig:1313-1370), replace the four manual overlay lines for model/base_url/api_key/url_style with reads from `self.resolveEffectiveProfile("")`... **STOP — semantic check first.** The overlay base is the ORCHESTRATOR's top-level values (`self.model` etc.), NOT the active-profile cascade. Using resolveEffectiveProfile("") would change behavior when active_profile is set (sub-agent would inherit active profile's model instead of top-level). DECISION: leave the 4 overlay lines as-is; they are already trivially short and semantically distinct ("empty sub-agent field → orchestrator top-level", not the full cascade). Document this divergence in a comment referencing resolveEffectiveProfile. Only consolidate what is truly the same cascade — YAGNI.
- [ ] 5.2 Run `zig build test --summary all` — pass (no-op task except comment).
- [ ] 5.3 Commit: `docs(config): clarify buildResolvedFromConfig overlay vs resolveEffectiveProfile cascade`

## Task 6 — Grep-proof + full verification

**Files:** none (verification only)

- [ ] 6.1 Grep-proofs that the duplication is gone:
      - `search("getProfile\\(", path=workflow.zig)` → expect ≤ 2 hits (none in cascade context; only any remaining legitimate direct lookups — target: ZERO getProfile calls in workflow.zig outside comments)
      - `search("active_profile", path=workflow.zig)` → expect only the warning-log site + comments
      - `search("parseThinkingString", path=workflow.zig)` → expect 0 hits (derivation moved into Config)
- [ ] 6.2 Full suite: `zig build test --summary all` — compare against baseline (2401 pass / 6 skip / 0 fail + known pre-existing failures listed in memory mem_a1eabbc7daa573fa). No NEW failures allowed.
- [ ] 6.3 Read back the final workflow.zig entry + loop blocks to confirm the pasted-in duplication from the user's message is fully replaced.
- [ ] 6.4 Commit (if any stragglers): `chore(workflow): final cleanup for profile-resolution consolidation`

---

## Out of scope (explicitly)

- No frontend changes (ChatView cascade comments reference workflow.zig::resolveProfileField by name — update those 3 comment references opportunistically in Task 3 IF trivial, otherwise leave; they're comments only).
- No change to `session_create.zig` snapshot behavior (it snapshots the NAME, correct layer).
- No change to sub-agent override semantics.
- No schema/migration.
- No live-server testing (pure Zig refactor; unit tests + static greps suffice).

## Risks & mitigations

- **Risk:** `var eff` vs `const eff` mutation across iterations — mitigated by keeping `var` and assigning wholesale per iteration (struct assignment, no partial mutation except the documented sub-agent override block which mutates fields pre-call).
- **Risk:** `callDynamicAgentNew` takes `isThinking` from `currentAgentState.is_thinking` (session state), NOT from eff — preserve that exact wiring (only the INSERT at 912 and the ov-override path touch eff.is_thinking).
- **Risk:** losing the "missing selected profile" warning — it's independent of the cascade (checks existence, not fields); kept verbatim at 738-742.
