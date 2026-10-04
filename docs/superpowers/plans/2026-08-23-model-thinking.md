# Model Thinking (Claude Extended Thinking + OpenAI Reasoning) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Claude extended thinking (Anthropic) and OpenAI reasoning (o1 / o3 / GPT-5 / DeepSeek-R1) end-to-end through config → request body → SSE parse → DB → ChatView, and surface per-profile `thinking_budget_tokens` and `reasoning_effort` knobs plus a Thinking mode selector (Auto / On / Off) in PabrikSettings.

**Architecture:** Additive, NOT a rewrite. The Anthropic parser already emits `thinking_delta → reasoning_content` (Agent.zig:1605-1608) and writes the Anthropic `thinking: {type: "enabled", budget_tokens}` block in `buildJsonAnthropicRequest` (Agent.zig:1177-1238). The OpenAI parser already reads `delta.reasoning_content` (Agent.zig:1440-1444). `llm_history.reasoning_content` is wired through `insertLLMHistories` (llm_history.zig:130) and surfaced in ChatView (ChatView.vue:1207-1447). What's MISSING is the runtime wire from the profile's `thinking` string to the main-agent's `is_thinking` flag, the OpenAI `reasoning_effort` field on the request body, the `on/off` UI value parsing, the Anthropic `type: "adaptive"` mode, and a per-profile `thinking_budget_tokens` / `reasoning_effort` knob.

**Tech Stack:** Zig 0.16 (backend), TypeScript + Vue 3 Composition API (frontend), SQLite (no migration — adds nullable columns to llm_history), JSON-string wire format (`||` for arrays, JSON-encoded for tags).

## Global Constraints

- **No migration** — store the new knobs as nullable columns on `llm_history` (when session-bound) AND as nullable strings/numbers on `LlmProfile` / `SubAgentConfig`. Backend round-trips NULL gracefully (`COALESCE(...)`).
- **No new HTTP routes** — `PUT /api/config/pabrik` already accepts arbitrary profile fields (zig-tested as such); sub-agent configs already accept `thinking` strings. The new fields extend the existing wire shapes.
- **Backend-first** — every new profile field round-trips through the existing `LlmConfig` parser at `src/modules/config/Config.zig:480-740` and existing `pabrik_config_put_parse_test.zig` cases. New parse-fn lives in `src/modules/config/parse_thinking.zig` (separate file for testability, mirroring `parse_compaction_settings.zig` precedent).
- **Frontend wiring per `desktop-frontend-build` skill** — extend `LlmConfigForm.vue` (NOT `PabrikSettings.vue`) because the profile form already lives there. `PabrikSettings.vue` only hydrates the form's values.
- **Anthropic adaptive vs enabled** — Anthropic docs now recommend `type: "adaptive"` (model picks its own budget) over `type: "enabled" + budget_tokens` for Sonnet 4.5+. We support BOTH and let `thinking_budget_tokens` fall through to `null` (adaptive mode).
- **OpenAI reasoning_effort** — only valid for o-series and GPT-5. We pass the field unconditionally for OpenAI-style URLs and let the server reject if unsupported (mirrors how `temperature` is passed unconditionally).
- **Avoid cross-module struct-member lookup asymmetry** — use fully-qualified nested types (`pabrikcore.config.LlmConfig.LlmProfile`), NOT shortcuts like `pabrikcore.config.LlmProfile` (lesson from PR #288).
- **Reuse existing SSE event types** — `reasoning_content` already flows through `llm_chunk` SSE events. No new event types needed. No `additionalEventTypes` registration needed.
- **Test discipline** — every new wire shape gets a `*_test.zig` static-contract test INLINE in the impl file (per the Agent Mode convention post-2026-08-17). NO `_test.zig` files for HTTP handlers (per user preference). Add `bunt` (Vitest) cases for any new frontend form fields.

---

## Background — What Already Exists

These are FACT, not work to do. Verify before coding.

| Layer | File | Line | State |
|-------|------|------|-------|
| Anthropic request writes `thinking: {type:"enabled", budget_tokens}` | `src/modules/agent/Agent.zig` | 1177-1238 | ✅ exists |
| Anthropic request forces thinking off when `max_tokens < 1025` | `src/modules/agent/Agent.zig` | 1191-1198 | ✅ exists |
| Anthropic parser maps `thinking_delta` → `reasoning_content` | `src/modules/agent/Agent.zig` | 1605-1608 | ✅ exists |
| OpenAI parser reads `delta.reasoning_content` | `src/modules/agent/Agent.zig` | 1440-1444 | ✅ exists |
| `Agent.thinkingEnabled` boolean | `src/modules/agent/Agent.zig` | 872 | ✅ exists |
| `dynamic_agent.thinkingEnabled = isThinking` | `src/ai_workflow/tui/agentic_loop/workflow.zig` | 1472 | ✅ exists |
| `llm_history.reasoning_content` column | `src/models/llm_history.zig` | 39, 83, 130, 200 | ✅ exists |
| `llm_history.is_thinking` column | `src/migrations/migration.zig` | 187 | ✅ exists (migration 011) |
| ChatView renders `reasoning_content` (kept-but-collapsed) | `src/apps/desktop/src/components/views/ChatView.vue` | 1207-1447 | ✅ exists |
| UI Thinking selector (Auto / On / Off) | `src/apps/desktop/src/components/pabrik/LlmConfigForm.vue` | 124-138 | ✅ exists |
| Profile `thinking: []const u8 = "auto"` | `src/modules/config/Config.zig` | 97, 204, 273 | ✅ exists |
| Sub-agent `thinking` parsed to `?bool` ("auto"→null, "true"→true, "false"→false) | `src/modules/config/Config.zig` | 1247-1253 | ⚠️ partial (no "on"/"off") |
| `resolveProfileField("thinking", ...)` into main-agent runtime | `src/ai_workflow/tui/agentic_loop/workflow.zig` | 217-245 | ❌ MISSING — only resolves model/base_url/api_key/url_style |
| `buildJsonOpenAIRequest` writes `reasoning_effort` | `src/modules/agent/Agent.zig` | 1346-1362 | ❌ MISSING |
| `LlmProfile.thinking_budget_tokens` | `src/modules/config/Config.zig` | 94-113 | ❌ MISSING |
| `LlmProfile.reasoning_effort` | `src/modules/config/Config.zig` | 94-113 | ❌ MISSING |
| Anthropic `type: "adaptive"` branch | `src/modules/agent/Agent.zig` | 1191-1238 | ❌ MISSING |

---

## File Map

### NEW (4 files)
- `src/modules/config/parse_thinking.zig` — pure helpers `parseThinkingString(allocator, []const u8) !ThinkingParseResult` + `parseReasoningEffort([]const u8) !ReasoningEffort`. Testable in isolation.
- `src/modules/config/parse_thinking_test.zig` — inline unit tests (per Agent Mode convention).
- `src/modules/agent/openai_reasoning_test.zig` — inline tests for `buildJsonOpenAIRequest` reasoning fields.
- `src/modules/agent/anthropic_adaptive_test.zig` — inline tests for the new adaptive mode branch.

### EDIT (10 files)

**Backend runtime wire (the main-agent `is_thinking` path is the critical fix):**
- `src/ai_workflow/tui/agentic_loop/workflow.zig` — resolve `effective_is_thinking` and `effective_thinking_budget_tokens` from profile, pass into `callDynamicAgentNew`. Persist `is_thinking` and `thinking_budget_tokens` onto the session's initial agent state. (≈30 LOC across lines 429-433 and 745-748 and 1011.)
- `src/ai_workflow/tui/agentic_loop/workflow.zig` — extend `callDynamicAgentNew` signature to accept `thinking_budget_tokens: ?u32` (≈5 LOC at line 1377, 1442, 1472).

**OpenAI reasoning fields:**
- `src/modules/agent/Agent.zig` — add `reasoning_effort: ?[]const u8 = null` + `thinking_budget_tokens: ?u32 = null` to `Agent` struct (≈2 LOC at 863). Use them in `buildJsonOpenAIRequest` (≈10 LOC at 1346-1362).
- `src/modules/agent/Agent.zig` — add `reasoning_effort` field to `JsonRequest` (≈5 LOC at 219-271), default `null` (omitted).

**Anthropic adaptive mode + budget override:**
- `src/modules/agent/Agent.zig` — extend `buildJsonAnthropicRequest` to honor `self.thinking_budget_tokens: ?u32`. When set, use it directly (still clamped to >=1024 and <max_tokens). When `null`, fall through to the existing 50%-of-max heuristic. Add the `type: "adaptive"` branch when budget_tokens is explicitly null AND profile has `thinking == "auto"` (i.e., user opted into adaptive). (≈25 LOC at 1191-1238.)

**Config:**
- `src/modules/config/Config.zig` — add `thinking_budget_tokens: ?u32 = null` and `reasoning_effort: ?[]const u8 = null` to `LlmProfile` (lines 94-113). Reuse the same fields on `SubAgentConfig` (lines 120-136).
- `src/modules/config/Config.zig` — extend `ResolvedSubAgent` (lines 162-184) with `thinking_budget_tokens: ?u32` + `reasoning_effort: ?[]const u8`. Update `buildResolvedFromConfig` (lines 1240-1275) to parse them.
- `src/modules/config/Config.zig` — add `thinking_budget_tokens` + `reasoning_effort` to the JSON parse chain (lines 562, 642, 725 — keep them in lex order).
- `src/modules/config/config_test.zig` — add cases for "thinking=on" + budget_tokens + reasoning_effort round-trip (1 new test).

**HTTP config PUT validation:**
- `src/ai_workflow/tui/http_handlers/pabrik_config_put.zig` — validate `thinking_budget_tokens` (u32, >0, <=2_000_000) and `reasoning_effort` (one of "low"/"medium"/"high"/"auto"/""). Reject others with structured error matching the existing `InvalidThresholdPercent` pattern.

**Sub-agent overrides (extend the spawn path):**
- `src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent.zig` — thread `thinking_budget_tokens` + `reasoning_effort` from `ResolvedSubAgent` into `SubAgentOverrides` (lines 471-471).
- `src/ai_workflow/tui/agentic_loop/workflow.zig` — extend `SubAgentOverrides` struct to carry the two new fields (find the struct def).
- `src/ai_workflow/tui/agentic_loop/workflow.zig` — apply them in the `ov.is_thinking` override block at lines 800-808 (≈5 LOC).

**Frontend:**
- `src/apps/desktop/src/components/pabrik/LlmConfigForm.vue` — add two new fields to the `LlmConfig` interface (lines 4-19). Add a second row under the Thinking selector with: `Thinking budget tokens` (number input, visible only when thinking != "off") and `Reasoning effort` (select: low/medium/high/auto). Emit them through `update()`. (≈35 LOC at 124-138 + 280.)
- `src/apps/desktop/src/components/PabrikSettings.vue` — extend the `LlmConfig` defaults block (line 264, 314, 341) to include `thinking_budget_tokens: null` and `reasoning_effort: null`. Extend the `profilesToRecord` mapper (lines 125-140) to surface them.
- `src/apps/desktop/src/components/pabrik/SubAgentModal.vue` — same field additions (search for the 4 instances of the `LlmConfig` literal in PabrikSettings.vue and mirror them).
- `src/apps/desktop/src/components/pabrik/ProfilesSection.vue` — surface the budget/effort in the profile-row tooltip / inline summary (search for the `description=` prop usage at line 119).

**Tests:**
- `src/modules/agent/anthropic_request_test.zig` — add cases for "budget_tokens override honored" + "adaptive mode emitted when budget is null and thinking==auto".
- `src/modules/agent/openai_reasoning_test.zig` (NEW) — inline tests for `buildJsonOpenAIRequest` with reasoning_effort set + null + with tools + without.
- `src/modules/config/parse_thinking_test.zig` (NEW) — inline tests for `parseThinkingString` (auto/on/off/true/false/empty/garbage) + `parseReasoningEffort` (low/medium/high/auto/empty/garbage).
- `src/apps/desktop/src/__tests__/pabrikConfigFormThinking.spec.ts` (NEW) — Vitest test that renders `LlmConfigForm` with `thinking="on"` and asserts the budget tokens field is visible; with `thinking="off"` asserts it's hidden.

---

# Task Breakdown

## Task 1: Add `parseThinkingString` + `parseReasoningEffort` helpers (with tests)

**Files:**
- CREATE: `src/modules/config/parse_thinking.zig`
- CREATE: `src/modules/config/parse_thinking_test.zig`
- EDIT: `src/modules/config/Config.zig` — replace the inline parser at lines 1247-1253 to call `parseThinkingString` (so sub-agent path also benefits from "on"/"off" support).

### Step 1.1 — Write failing tests for `parseThinkingString`

Write `parse_thinking_test.zig`:

```zig
const std = @import("std");
const pt = @import("parse_thinking.zig");
const testing = std.testing;

test "parseThinkingString auto -> null" {
    try testing.expectEqual(@as(?bool, null), try pt.parseThinkingString(testing.allocator, "auto"));
}
test "parseThinkingString on -> true" {
    try testing.expectEqual(@as(?bool, true), try pt.parseThinkingString(testing.allocator, "on"));
}
test "parseThinkingString off -> false" {
    try testing.expectEqual(@as(?bool, false), try pt.parseThinkingString(testing.allocator, "off"));
}
test "parseThinkingString true -> true (legacy)" {
    try testing.expectEqual(@as(?bool, true), try pt.parseThinkingString(testing.allocator, "true"));
}
test "parseThinkingString false -> false (legacy)" {
    try testing.expectEqual(@as(?bool, false), try pt.parseThinkingString(testing.allocator, "false"));
}
test "parseThinkingString garbage -> error" {
    try testing.expectError(error.InvalidThinkingMode, pt.parseThinkingString(testing.allocator, "maybe"));
}
test "parseThinkingString empty -> null (auto)" {
    try testing.expectEqual(@as(?bool, null), try pt.parseThinkingString(testing.allocator, ""));
}
test "parseReasoningEffort low|medium|high|auto accepted" {
    try testing.expectEqualStrings("low", try pt.parseReasoningEffort("low"));
    try testing.expectEqualStrings("medium", try pt.parseReasoningEffort("medium"));
    try testing.expectEqualStrings("high", try pt.parseReasoningEffort("high"));
    try testing.expectEqualStrings("auto", try pt.parseReasoningEffort("auto"));
}
test "parseReasoningEffort empty -> auto" {
    try testing.expectEqualStrings("auto", try pt.parseReasoningEffort(""));
}
test "parseReasoningEffort garbage -> error" {
    try testing.expectError(error.InvalidReasoningEffort, pt.parseReasoningEffort("super"));
}
```

### Step 1.2 — Run tests, watch them fail (compile error — module doesn't exist)

```bash
cd /home/ginwa/ginwaaitoolbox && timeout 60 zig build test --summary all 2>&1 | tail -n 20
```

Expect: "error: file 'parse_thinking.zig' not found".

### Step 1.3 — Implement `parse_thinking.zig`

```zig
const std = @import("std");
const testing = std.testing;

pub const ThinkingModeError = error{ InvalidThinkingMode };

/// Parses the per-profile / sub-agent `thinking` string field:
///   "auto"  → null  (inherit)
///   "on"    → true  (enabled; let the model pick its own budget when adaptive)
///   "off"   → false
///   "true"  → true  (legacy — pre-2026-08-23 UI wrote boolean strings)
///   "false" → false (legacy)
///   ""      → null  (same as "auto")
///   anything else → error.InvalidThinkingMode
pub fn parseThinkingString(allocator: std.mem.Allocator, raw: []const u8) ThinkingModeError!?bool {
    _ = allocator;
    if (raw.len == 0) return null;
    if (std.mem.eql(u8, raw, "auto")) return null;
    if (std.mem.eql(u8, raw, "on")) return true;
    if (std.mem.eql(u8, raw, "off")) return false;
    if (std.mem.eql(u8, raw, "true")) return true;
    if (std.mem.eql(u8, raw, "false")) return false;
    return error.InvalidThinkingMode;
}

pub const ReasoningEffortError = error{ InvalidReasoningEffort };

/// Parses the per-profile / sub-agent `reasoning_effort` string field:
///   "low" | "medium" | "high" | "auto" → returned as-is
///   "" → "auto"  (treated as auto)
///   anything else → error.InvalidReasoningEffort
///
/// The returned slice BORROWS from `raw` — callers that need to
/// store it long-term must `dupe` it. The wire format round-trips
/// through JSON unchanged.
pub fn parseReasoningEffort(raw: []const u8) ReasoningEffortError![]const u8 {
    if (raw.len == 0) return "auto";
    if (std.mem.eql(u8, raw, "low")) return "low";
    if (std.mem.eql(u8, raw, "medium")) return "medium";
    if (std.mem.eql(u8, raw, "high")) return "high";
    if (std.mem.eql(u8, raw, "auto")) return "auto";
    return error.InvalidReasoningEffort;
}
```

### Step 1.4 — Wire into `Config.zig`'s `buildResolvedFromConfig`

Replace lines 1246-1253:

```zig
const parse_thinking = @import("parse_thinking.zig");
const thinking_mod = pabrikcore.parse_thinking_mod;  // re-export pattern; or import directly

// at the top of the function, replace the inline blk:
const resolved_thinking: ?bool = try parse_thinking.parseThinkingString(
    self.allocator,
    sa.thinking,
);
```

(And add `parse_thinking` to `src/root.zig` re-exports if needed for the `pabrikcore.parse_thinking_mod` shortcut — match whatever convention the existing `parse_compaction_settings.zig` uses. Search for `parse_compaction` first.)

### Step 1.5 — Run tests, watch them pass

```bash
cd /home/ginwa/ginwaaitoolbox && timeout 60 zig build test --summary all 2>&1 | tail -n 30
```

Expect: 8+ new passes for `parse_thinking_test.zig`, 0 failures.

### Step 1.6 — Commit

```bash
git add src/modules/config/parse_thinking.zig src/modules/config/parse_thinking_test.zig src/modules/config/Config.zig
git commit -m "feat(config): parseThinkingString + parseReasoningEffort helpers (on/off/auto + low/medium/high/auto)"
```

---

## Task 2: Add `thinking_budget_tokens` and `reasoning_effort` to `LlmProfile` + `SubAgentConfig`

**Files:**
- EDIT: `src/modules/config/Config.zig` — `LlmProfile` (lines 94-113), `SubAgentConfig` (lines 120-136), `ResolvedSubAgent` (lines 162-184), and the three JSON parse blocks (lines 480-740).

### Step 2.1 — Extend the three structs

In `LlmProfile` (after `compaction_threshold_percent: ?u8 = null`, line 112):

```zig
/// Optional override for the thinking budget. Anthropic only:
/// when set, used directly as `thinking.budget_tokens` (clamped
/// to >=1024 and <max_tokens). When null AND `thinking == "on"`,
/// the agent falls back to the 50%-of-max heuristic; when
/// `thinking == "auto"` the agent emits `type: "adaptive"` and
/// lets Anthropic pick its own budget. OpenAI-style URLs ignore
/// this field — they use `reasoning_effort` instead.
thinking_budget_tokens: ?u32 = null,
/// OpenAI-style reasoning effort knob (o1 / o3 / GPT-5 /
/// DeepSeek-R1). One of "low" | "medium" | "high" | "auto".
/// Validated by `parse_thinking.parseReasoningEffort`. Null on
/// Anthropic-style URLs (the field is silently omitted from the
/// request body).
reasoning_effort: ?[]const u8 = null,
```

Mirror the same two fields on `SubAgentConfig` (line 120) and on `ResolvedSubAgent` (line 162).

### Step 2.2 — Extend the JSON parse chain

There are 3 blocks that need to surface the new fields:
- Profile block (around line 562, 642, 725)
- Sub-agent top-level block (around line 642)
- Sub-agent per-profile block (around line 725)

For each, after `.temperature = ...` (or before), add:

```zig
.thinking_budget_tokens = j.thinking_budget_tokens,
.reasoning_effort = if (j.reasoning_effort) |re| try allocator.dupe(u8, re) else null,
```

(Use the same `dupe` pattern as the other string fields. Verify each block uses `self.allocator` or a local — match surrounding code.)

### Step 2.3 — Update `buildResolvedFromConfig` to parse them

In `src/modules/config/Config.zig` around line 1247, after the new `parseThinkingString` call from Task 1, add:

```zig
const resolved_budget: ?u32 = blk: {
    if (sa.thinking_budget_tokens) |t| {
        if (t > 0 and t <= 2_000_000) break :blk t;
    }
    break :blk null;
};
const resolved_effort: ?[]const u8 = blk: {
    if (sa.reasoning_effort) |re| {
        if (re.len == 0) break :blk null;
        break :blk re;
    }
    break :blk null;
};
```

And add to the returned `ResolvedSubAgent` literal:

```zig
.thinking_budget_tokens = resolved_budget,
.reasoning_effort = resolved_effort,
```

### Step 2.4 — Add a test in `config_test.zig`

Mirror the existing test at `src/modules/config/config_test.zig:572-591` (the "profile thinking=on" case). Add one with `thinking_budget_tokens: 8192` and `reasoning_effort: "high"`, assert both round-trip.

### Step 2.5 — Run tests

```bash
cd /home/ginwa/ginwaaitoolbox && timeout 60 zig build test --summary all 2>&1 | tail -n 30
```

Expect: 1+ new pass, 0 failures.

### Step 2.6 — Commit

```bash
git add src/modules/config/Config.zig src/modules/config/config_test.zig
git commit -m "feat(config): add thinking_budget_tokens + reasoning_effort to LlmProfile/SubAgentConfig"
```

---

## Task 3: Wire `effective_is_thinking` into the main-agent runtime

**Files:**
- EDIT: `src/ai_workflow/tui/agentic_loop/workflow.zig` — resolve the field at lines 429-433, persist on the initial agent-state INSERT at lines 745-748, pass into `callDynamicAgentNew` at lines 1011, 1442, 1472.

**Why this is the MOST IMPORTANT task:** without it, the per-profile "Thinking" selector UI is purely cosmetic — every main-agent session still defaults to `is_thinking = true` via the `COALESCE(is_thinking, 1)` at `llm_history.zig:2455`. Only sub-agents that explicitly set `is_thinking` in their config actually toggle it today.

### Step 3.1 — Extend `resolveProfileField` callers in workflow.zig

At lines 430-433, add two new effective-* vars right after `effective_url_style`:

```zig
var effective_thinking_budget_tokens: ?u32 = blk: {
    // 1. Session/profile override.
    if (params.selected_profile_model.len > 0) {
        if (config.getProfile(params.selected_profile_model)) |profile| {
            if (profile.thinking_budget_tokens) |t| break :blk t;
        }
    }
    // 2. Active profile fallback.
    if (config.active_profile) |ap| {
        if (ap.len > 0) {
            if (config.getProfile(ap)) |profile| {
                if (profile.thinking_budget_tokens) |t| break :blk t;
            }
        }
    }
    // 3. No top-level default — null means "let the agent use
    // the 50%-of-max heuristic" (Anthropic) or "adaptive mode"
    // when profile.thinking == "auto".
    break :blk null;
};
var effective_is_thinking_str: []const u8 = blk: {
    if (params.selected_profile_model.len > 0) {
        if (config.getProfile(params.selected_profile_model)) |profile| {
            if (profile.thinking.len > 0) break :blk profile.thinking;
        }
    }
    if (config.active_profile) |ap| {
        if (ap.len > 0) {
            if (config.getProfile(ap)) |profile| {
                if (profile.thinking.len > 0) break :blk profile.thinking;
            }
        }
    }
    break :blk "auto";
};
// Parse the resolved string into a typed bool.
// ParseThinkingString errors fall through to `null` (= auto).
const effective_is_thinking: ?bool = parse_thinking.parseThinkingString(
    parent_allocator,
    effective_is_thinking_str,
) catch null;
```

(Make sure `parse_thinking` is importable at this module scope — check the existing `@import` lines near line 71 for `pabrikcore.X` re-exports and add one for `parse_thinking` if needed.)

### Step 3.2 — Persist on the initial agent-state INSERT

At line 748 (the first `insertLLMHistories` of the main loop):

```zig
.is_thinking = effective_is_thinking orelse initial_agent_state.is_thinking,
```

(Use `orelse` so sub-agent overrides + the session's own history still win when the profile says "auto".)

### Step 3.3 — Pass into `callDynamicAgentNew`

At line 1011, extend the call:

```zig
const res_dynamic_agent = callDynamicAgentNew(
    allocator, io, messagesLists, agent_temperature,
    current_max_tokens,
    effective_is_thinking orelse isThinking,
    effective_thinking_budget_tokens,
    effective_api_key, effective_model, effective_base_url, effective_url_style,
    copy_session_id, merged_tools, &last_dynamic_agent_error_message,
) catch |err| { ... };
```

### Step 3.4 — Extend `callDynamicAgentNew` signature

At line 1377 (the `callDynamicAgentNew` declaration), add a parameter:

```zig
pub fn callDynamicAgentNew(
    ...
    isThinking: bool,
    thinking_budget_tokens: ?u32,  // NEW
    ...
) !... {
```

At line 1442 (the inner dynamic agent construction), pass it through:

```zig
var dynamic_agent = agent.Agent.init_with_options(allocator, io, .{
    .model = effective_model,
    .apiKey = effective_api_key,
    .baseUrl = effective_base_url,
    .UrlStyle = effective_url_style,
    .userIdentifier = "AnakMagang",
});
dynamic_agent.thinkingEnabled = isThinking;
dynamic_agent.thinkingBudgetTokens = thinking_budget_tokens;  // NEW
```

### Step 3.5 — Add `thinkingBudgetTokens` to the `Agent` struct

In `src/modules/agent/Agent.zig` at line 872, add:

```zig
/// Anthropic-only: override for the `thinking.budget_tokens` value.
/// When set, used directly (clamped to >=1024 and <max_tokens by
/// buildJsonAnthropicRequest). When null AND thinkingEnabled is
/// true, falls back to the 50%-of-max heuristic. When null AND
/// profile.thinking == "auto", emits Anthropic's `type:
/// "adaptive"` mode and lets the model pick its own budget.
/// OpenAI-style URLs ignore this field — they use
/// `reasoningEffort` instead.
thinkingBudgetTokens: ?u32 = null,
```

### Step 3.6 — Update helper extensions

The two helper extensions in workflow.zig — `runAgenticMultiStepnew` (line 412) and the per-iteration re-read at line 632-661 — must also resolve `effective_thinking_budget_tokens` and `effective_is_thinking` on each iteration. Mirror the pattern: copy the resolution block into both call sites, or extract a helper `resolveThinkingSettings(allocator, config, selected_profile_model) struct { is_thinking: ?bool, budget_tokens: ?u32 }` and call from both.

### Step 3.7 — Add a test

Write `src/ai_workflow/tui/agentic_loop/workflow_thinking_test.zig` (inline with the impl per Agent Mode convention). Two cases:
1. Profile with `thinking="off"` → `is_thinking` INSERTED as 0 even on session 1.
2. Profile with `thinking="on"` + `thinking_budget_tokens=4096` → INSERT carries `is_thinking=1`, and the dynamic agent's `thinkingBudgetTokens` is 4096.

(Verify by checking that the `dynamic_agent` struct is constructed correctly — easier to test the Agent.zig path directly via the helper. Real integration is covered by the manual wire test in Task 10.)

### Step 3.8 — Run tests

```bash
cd /home/ginwa/ginwaaitoolbox && timeout 60 zig build test --summary all 2>&1 | tail -n 30
cd /home/ginwa/ginwaaitoolbox && timeout 600 zig build pabrik-desktop --summary all 2>&1 | tail -n 30
```

Expect: 2+ new passes, 0 failures. pabrik-desktop build is the critical CI gate (lesson from PR #288: `zig build test` is more permissive than `zig build pabrik-desktop` for cross-module struct lookup).

### Step 3.9 — Commit

```bash
git add src/ai_workflow/tui/agentic_loop/workflow.zig src/ai_workflow/tui/agentic_loop/workflow_thinking_test.zig src/modules/agent/Agent.zig
git commit -m "feat(workflow): wire effective_is_thinking + thinking_budget_tokens from profile into main-agent runtime"
```

---

## Task 4: Apply budget_tokens + adaptive mode in `buildJsonAnthropicRequest`

**Files:**
- EDIT: `src/modules/agent/Agent.zig` — replace the inline `thinking_on` / `thinking_budget` blocks (lines 1191-1238) with the new logic that honors `self.thinkingBudgetTokens` + adds adaptive mode.
- CREATE: `src/modules/agent/anthropic_adaptive_test.zig` — inline tests.

### Step 4.1 — Write failing tests

Write `anthropic_adaptive_test.zig` (mirror the style of `anthropic_request_test.zig` lines 1-60):

```zig
test "buildJsonAnthropicRequest: thinkingBudgetTokens set emits that exact budget" {
    // max_tokens=8192, thinkingEnabled=true, thinkingBudgetTokens=2048
    // assert budget_tokens == 2048 (NOT the 50% heuristic of 4096)
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens=1025 (floor+1) honored" {
    // assert budget_tokens == 1025 (the floor is 1024, value is >= floor)
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens=0 falls back to heuristic" {
    // (we treat 0 as "unset" — same as null)
}

test "buildJsonAnthropicRequest: thinkingEnabled=true with no budget emits type:adaptive" {
    // thinkingEnabled=true, thinkingBudgetTokens=null, profile.thinking == "auto"
    // assert thinking.type == "adaptive" AND no budget_tokens field
}

test "buildJsonAnthropicRequest: thinkingEnabled=true with budget keeps type:enabled" {
    // thinkingEnabled=true, thinkingBudgetTokens=4096
    // assert thinking.type == "enabled" AND budget_tokens == 4096
}

test "buildJsonAnthropicRequest: thinkingEnabled=false omits thinking entirely" {
    // unchanged from existing test
}
```

### Step 4.2 — Run, watch compile fail

```bash
cd /home/ginwa/ginwaaitoolbox && timeout 60 zig build test --summary all 2>&1 | tail -n 20
```

Expect: "error: unknown field 'thinkingBudgetTokens'" (because Agent.zig doesn't have it yet — but Task 3.5 added it, so it should compile; the tests will FAIL functionally because the heuristic still wins. Verify they fail functionally before moving on.)

### Step 4.3 — Replace the inline thinking_on/thinking_budget blocks

In `Agent.zig:1191-1238`, replace with:

```zig
const thinking_on: bool = blk: {
    if (!self.thinkingEnabled) break :blk false;
    if (resolved_max_tokens < 1025) {
        self.log_fmt(.warn, "buildJsonAnthropicRequest: thinkingEnabled=true but max_tokens={d} (<1025) — Anthropic requires budget_tokens >= 1024 AND < max_tokens, so thinking is forced off for this request. Raise max_tokens to >=1025 to re-enable.", .{resolved_max_tokens});
        break :blk false;
    }
    break :blk true;
};

// budget_tokens comes from one of three sources, in priority order:
//   1. Explicit override (Agent.thinkingBudgetTokens) — wins always.
//   2. 50%-of-max_tokens heuristic (the existing default).
//   3. null = "adaptive mode" — Anthropic picks its own budget.
//
// Source 3 only triggers when budget_tokens is null AND thinking_on
// is true AND the profile explicitly opted into adaptive via
// thinking="auto". The flag is carried on the Agent as
// `thinkingAdaptive: bool` (added below).
const thinking_budget: ?usize = blk: {
    if (!thinking_on) break :blk null;
    if (self.thinkingBudgetTokens) |explicit| {
        // Honor explicit override, but still clamp to >=1024 and <max_tokens.
        const floor_constrained: usize = if (explicit < 1024) 1024 else explicit;
        const ceiling: usize = resolved_max_tokens -| 1;
        break :blk if (floor_constrained < ceiling) floor_constrained else ceiling;
    }
    if (self.thinkingAdaptive) {
        // Adaptive mode — let Anthropic pick.
        break :blk null;
    }
    // Fallback heuristic (unchanged from existing implementation).
    const half = resolved_max_tokens / 2;
    const floor_constrained: usize = if (half < 1024) 1024 else half;
    const ceiling: usize = resolved_max_tokens -| 1;
    break :blk if (floor_constrained < ceiling) floor_constrained else ceiling;
};
```

And extend `AnthropicThinking` to make `budget_tokens` optional + add `type: "adaptive"` support. Replace the struct (lines 390-409) with:

```zig
const AnthropicThinking = struct {
    type: []const u8,           // "enabled" | "adaptive" | "disabled"
    /// Required only when type == "enabled". Omitted for adaptive.
    budget_tokens: ?usize = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.type);
        if (self.budget_tokens) |bt| {
            try stringify.objectField("budget_tokens");
            try stringify.write(bt);
        }
        try stringify.endObject();
    }
};
```

And update the AnthropicRequest construction (lines 1229-1245) to:

```zig
const thinking_value: ?AnthropicThinking = blk: {
    if (!thinking_on) break :blk null;
    if (thinking_budget) |bt| break :blk .{ .type = "enabled", .budget_tokens = bt };
    break :blk .{ .type = "adaptive" };  // budget_tokens=null → emit adaptive
};

const json_request = AnthropicRequest{
    ...
    .thinking = thinking_value,
    ...
};
```

### Step 4.4 — Add `thinkingAdaptive: bool = false` to `Agent` struct

In `Agent.zig:872-886`, after `thinkingEnabled`:

```zig
/// Anthropic-only: when true AND `thinkingBudgetTokens` is null,
/// `buildJsonAnthropicRequest` emits `thinking: {type: "adaptive"}`
/// (Anthropic picks its own budget — recommended for Sonnet 4.5+).
/// When false, the request falls back to the 50%-of-max_tokens
/// heuristic. The workflow sets this from the profile's
/// `thinking == "auto"` resolution (see Task 3).
thinkingAdaptive: bool = false,
```

The workflow at Task 3 step 3.1 must set `dynamic_agent.thinkingAdaptive = (effective_is_thinking_str == "auto")` — wire that in too.

### Step 4.5 — Run tests, watch pass

```bash
cd /home/ginwa/ginwaaitoolbox && timeout 60 zig build test --summary all 2>&1 | tail -n 20
cd /home/ginwa/ginwaaitoolbox && timeout 600 zig build pabrik-desktop --summary all 2>&1 | tail -n 30
```

Expect: all 6 new tests pass, 0 regressions.

### Step 4.6 — Commit

```bash
git add src/modules/agent/Agent.zig src/modules/agent/anthropic_adaptive_test.zig
git commit -m "feat(agent): anthropic thinking_budget_tokens override + adaptive mode"
```

---

## Task 5: Apply `reasoning_effort` in `buildJsonOpenAIRequest`

**Files:**
- EDIT: `src/modules/agent/Agent.zig` — add `reasoningEffort` field to `Agent` (line 872), add `reasoning_effort` to `JsonRequest` (line 219), emit it in `buildJsonOpenAIRequest` (line 1346).
- CREATE: `src/modules/agent/openai_reasoning_test.zig` — inline tests.

### Step 5.1 — Add `reasoningEffort` to `Agent` struct

In `Agent.zig` after `thinkingEnabled`:

```zig
/// OpenAI-style reasoning effort knob (o1 / o3 / GPT-5 /
/// DeepSeek-R1). One of "low" | "medium" | "high" | "auto" —
/// emitted verbatim into the request body's
/// `reasoning_effort` field. When null, the field is omitted
/// (model-default reasoning). Anthropic-style URLs ignore this
/// field entirely.
reasoningEffort: ?[]const u8 = null,
```

### Step 5.2 — Extend `JsonRequest`

After `enable_thinking` (lines 243-244), add:

```zig
reasoning_effort: ?[]const u8 = null,
```

And in `jsonStringify` (after the `enable_thinking` block):

```zig
if (self.reasoning_effort) |re| {
    if (re.len > 0) {
        try stringify.objectField("reasoning_effort");
        try stringify.write(re);
    }
}
```

### Step 5.3 — Update `buildJsonOpenAIRequest`

At line 1346, populate the new field:

```zig
const json_request = JsonRequest{
    .model = self.model,
    .enable_thinking = self.thinkingEnabled,
    .thinking = if (!self.thinkingEnabled) .{} else null,
    .reasoning_effort = self.reasoningEffort,
    .messages = json_messages[0..json_message_count],
    .temperature = params.temperature orelse self.temperature,
    .max_tokens = params.max_tokens orelse self.maxTokens,
    .stream = stream,
    .tools = json_tools,
    .tool_choice = if (json_tools != null) "auto" else null,
    .user = if (self.userIdentifier.len > 0) self.userIdentifier else null,
};
```

### Step 5.4 — Wire from workflow

In `workflow.zig` step 3.3 / 3.4 — alongside `dynamic_agent.thinkingBudgetTokens = ...` — add:

```zig
dynamic_agent.reasoningEffort = if (effective_url_style_is_anthropic) null else effective_reasoning_effort;
```

Where `effective_reasoning_effort` is resolved like `effective_thinking_budget_tokens` (Task 3.1) but reads from `profile.reasoning_effort`.

### Step 5.5 — Write failing tests

```zig
test "buildJsonOpenAIRequest: reasoningEffort set emits reasoning_effort field" {
    // reasoningEffort = "high" → wire body contains "reasoning_effort":"high"
}
test "buildJsonOpenAIRequest: reasoningEffort null omits field" {
    // reasoningEffort = null → wire body does NOT contain "reasoning_effort"
}
test "buildJsonOpenAIRequest: reasoningEffort empty string omits field" {
    // reasoningEffort = "" → wire body does NOT contain "reasoning_effort"
}
test "buildJsonOpenAIRequest: reasoning_effort coexists with tools" {
    // reasoningEffort = "medium" + 2 tools → both emitted
}
```

### Step 5.6 — Run, watch pass

```bash
cd /home/ginwa/ginwaaitoolbox && timeout 60 zig build test --summary all 2>&1 | tail -n 20
cd /home/ginwa/ginwaaitoolbox && timeout 600 zig build pabrik-desktop --summary all 2>&1 | tail -n 30
```

### Step 5.7 — Commit

```bash
git add src/modules/agent/Agent.zig src/modules/agent/openai_reasoning_test.zig
git commit -m "feat(agent): openai reasoning_effort field on request body"
```

---

## Task 6: Extend sub-agent overrides to carry budget + effort

**Files:**
- EDIT: `src/ai_workflow/tui/agentic_loop/workflow.zig` — find `SubAgentOverrides` struct definition (search for `SubAgentOverrides = struct`), add the two new fields.
- EDIT: `src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent.zig` — extend the overrides literal at line 471-498.

### Step 6.1 — Find and extend `SubAgentOverrides`

In `workflow.zig`, search for `SubAgentOverrides = struct` and add:

```zig
thinking_budget_tokens: ?u32,
reasoning_effort: ?[]const u8,
```

### Step 6.2 — Extend the spawn path

In `tools_exec_spawn_sub_agent.zig:471-498`, mirror the `ResolvedSubAgent` fields:

```zig
break :blk ai_workflow.SubAgentOverrides{
    .resolved_name = resolved.name,
    .model = resolved.model,
    .base_url = resolved.base_url,
    .api_key = resolved.api_key,
    .url_style = resolved.url_style,
    .system_prompt = resolved.system_prompt,
    .is_thinking = resolved.is_thinking,
    .temperature = resolved.temperature,
    .thinking_budget_tokens = resolved.thinking_budget_tokens,  // NEW
    .reasoning_effort = resolved.reasoning_effort,              // NEW
};
```

### Step 6.3 — Apply them in workflow.zig

At lines 800-808, after the existing `if (ov.is_thinking) |t| isThinking = t;` block, add:

```zig
const effective_thinking_budget_tokens = ov.thinking_budget_tokens orelse effective_thinking_budget_tokens;
const effective_reasoning_effort = ov.reasoning_effort orelse effective_reasoning_effort;
```

(These mirror the existing `if (ov.is_thinking) |t|` cascade pattern. Pass them into `callDynamicAgentNew` per Task 3.3.)

### Step 6.4 — Commit

```bash
git add src/ai_workflow/tui/agentic_loop/workflow.zig src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent.zig
git commit -m "feat(spawn_sub_agent): thread thinking_budget_tokens + reasoning_effort into overrides"
```

---

## Task 7: HTTP PUT validation for the new fields

**Files:**
- EDIT: `src/ai_workflow/tui/http_handlers/pabrik_config_put.zig` — add the validation calls in the profile loop and the sub-agent loop. Mirror the existing `compaction_threshold_percent` validation (search for `InvalidThresholdPercent`).

### Step 7.1 — Find the validation site

Open `pabrik_config_put.zig` and find:
- The profile-parse block where `compaction_threshold_percent` is range-checked.
- The sub-agent-parse block where `compaction_threshold_percent` is range-checked.
- The error enum (likely `LoadError` re-used or a per-handler error set) — confirm the error name pattern.

### Step 7.2 — Add the validation

For each profile / sub-agent parsed block, after the existing threshold check, add:

```zig
// Validate thinking_budget_tokens (must be 0 < n <= 2_000_000).
if (parsed.thinking_budget_tokens) |t| {
    if (t == 0 or t > 2_000_000) {
        return error.InvalidThinkingBudgetTokens;
    }
}
// Validate reasoning_effort (parse_thinking.parseReasoningEffort).
if (parsed.reasoning_effort) |re| {
    _ = try parse_thinking.parseReasoningEffort(re);
}
```

Add `InvalidThinkingBudgetTokens` to the error set if it's local to the handler, or to `LoadError` if shared (mirror the existing `InvalidThresholdPercent` pattern).

### Step 7.3 — Add a static-contract test

Create `src/ai_workflow/tui/http_handlers/pabrik_config_put_thinking_test.zig` (inline). Three cases:
1. `thinking_budget_tokens: 0` → `error.InvalidThinkingBudgetTokens`
2. `thinking_budget_tokens: 9_999_999` → same
3. `reasoning_effort: "super"` → `error.InvalidReasoningEffort`

### Step 7.4 — Commit

```bash
git add src/ai_workflow/tui/http_handlers/pabrik_config_put.zig src/ai_workflow/tui/http_handlers/pabrik_config_put_thinking_test.zig
git commit -m "feat(http): validate thinking_budget_tokens + reasoning_effort in config PUT"
```

---

## Task 8: Frontend — extend `LlmConfigForm.vue` with the two new fields

**Files:**
- EDIT: `src/apps/desktop/src/components/pabrik/LlmConfigForm.vue` — add `thinking_budget_tokens: number | null` + `reasoning_effort: string | null` to the `LlmConfig` interface (lines 4-19), add the second-row UI.

### Step 8.1 — Extend the TypeScript interface

At lines 4-19:

```ts
export interface LlmConfig {
  ...
  max_capacity_tokens: number | null
  compaction_threshold_percent: number | null
  /** Anthropic-only. When null, falls back to 50%-of-max_tokens
   * heuristic (or "adaptive" mode when thinking == "auto"). */
  thinking_budget_tokens: number | null
  /** OpenAI-only. "low" | "medium" | "high" | "auto". Null = omit. */
  reasoning_effort: 'low' | 'medium' | 'high' | 'auto' | null
}
```

### Step 8.2 — Add the UI

Below the Thinking/Temperature/URL style row (after line 165), add a second row that's visible only when `thinking !== 'off'`:

```vue
<!-- Thinking budget / Reasoning effort — Anthropic + OpenAI knobs -->
<div v-if="modelValue.thinking !== 'off'" class="grid grid-cols-2 gap-3">
  <div>
    <label :class="labelBase" :style="labelStyle">
      Thinking budget tokens
      <span class="block text-xs mt-0.5" :style="helperStyle">
        Anthropic only. Min 1024. Null = adaptive mode.
      </span>
    </label>
    <input
      :value="modelValue.thinking_budget_tokens ?? ''"
      @input="(e) => update('thinking_budget_tokens',
        e.target.value === '' ? null : Math.max(1024, parseInt(e.target.value || '0', 10)))"
      type="number"
      min="1024"
      step="512"
      placeholder="auto"
      :class="inputBase"
      :style="inputStyle()"
      data-testid="thinking-budget-input"
    />
  </div>
  <div>
    <label :class="labelBase" :style="labelStyle">
      Reasoning effort
      <span class="block text-xs mt-0.5" :style="helperStyle">
        OpenAI only (o1/o3/GPT-5/DeepSeek-R1).
      </span>
    </label>
    <select
      :value="modelValue.reasoning_effort ?? ''"
      @change="(e) => update('reasoning_effort',
        e.target.value === '' ? null : e.target.value)"
      :class="inputBase"
      :style="inputStyle()"
      data-testid="reasoning-effort-select"
    >
      <option value="">Auto</option>
      <option value="low">Low</option>
      <option value="medium">Medium</option>
      <option value="high">High</option>
    </select>
  </div>
</div>
```

### Step 8.3 — Write Vitest tests

`src/apps/desktop/src/__tests__/pabrikConfigFormThinking.spec.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import LlmConfigForm from '../components/pabrik/LlmConfigForm.vue'

describe('LlmConfigForm Thinking fields', () => {
  it('hides budget + effort fields when thinking=off', () => {
    const wrapper = mount(LlmConfigForm, {
      props: {
        modelValue: {
          model: 'm', base_url: '', thinking: 'off',
          temperature: 'auto', url_style: 'openai', api_key: '',
          max_capacity_tokens: null, compaction_threshold_percent: null,
          thinking_budget_tokens: null, reasoning_effort: null,
        },
      },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
  })

  it('shows both fields when thinking=on', () => {
    const wrapper = mount(LlmConfigForm, {
      props: {
        modelValue: {
          model: 'm', base_url: '', thinking: 'on',
          temperature: 'auto', url_style: 'openai', api_key: '',
          max_capacity_tokens: null, compaction_threshold_percent: null,
          thinking_budget_tokens: null, reasoning_effort: null,
        },
      },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
  })
})
```

### Step 8.4 — Run

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop && bun run test:unit -- pabrikConfigFormThinking 2>&1 | tail -n 30
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop && bun run build 2>&1 | tail -n 30
```

Expect: 2 passes, 0 failures, vue-tsc clean.

### Step 8.5 — Commit

```bash
git add src/apps/desktop/src/components/pabrik/LlmConfigForm.vue src/apps/desktop/src/__tests__/pabrikConfigFormThinking.spec.ts
git commit -m "feat(ui): Thinking budget + reasoning effort knobs in LlmConfigForm"
```

---

## Task 9: Frontend — extend PabrikSettings + SubAgentModal defaults

**Files:**
- EDIT: `src/apps/desktop/src/components/PabrikSettings.vue` — 4 sites at lines 264, 273, 314, 325, 341, 352 need the two new fields defaulted.
- EDIT: `src/apps/desktop/src/components/pabrik/SubAgentModal.vue` — mirror.
- EDIT: `src/apps/desktop/src/components/PabrikSettings.vue` — extend `profilesToRecord` (lines 125-140) to map the fields from API to form.
- EDIT: `src/apps/desktop/src/components/PabrikSettings.vue` — extend the `profileModal.value.value` literal (line 264) and the `startEditProfile` mapper (line 273).

### Step 9.1 — Update the 4 `LlmConfig` literal sites

In each of the 4 spots at lines 264, 314, 341 (add-modal defaults), add:

```ts
thinking_budget_tokens: null,
reasoning_effort: null,
```

### Step 9.2 — Update the 3 mapper sites

In `startEditProfile` (line 267), `startEditSubAgentInProfile` (line 344), and the inline edit at line 352, mirror the existing `temperature: p.temperature ?? 'auto'` style:

```ts
thinking_budget_tokens: p.thinking_budget_tokens ?? null,
reasoning_effort: p.reasoning_effort ?? null,
```

### Step 9.3 — Update `profilesToRecord`

At line 125-140, the mapper returns `ProfileRow`. Extend the row object to carry the two new fields, then forward them in the new-profile literal at line 273 and edit literal at line 352.

### Step 9.4 — Update `SubAgentModal.vue`

Search for the `LlmConfig` literal in SubAgentModal.vue (likely 1 spot — the local state shape) and add the two defaults. Mirror the same pattern.

### Step 9.5 — Run frontend build + tests

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop && bun run build 2>&1 | tail -n 30
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop && bun run test:unit 2>&1 | tail -n 30
```

Expect: vue-tsc clean, all tests pass.

### Step 9.6 — Commit

```bash
git add src/apps/desktop/src/components/PabrikSettings.vue src/apps/desktop/src/components/pabrik/SubAgentModal.vue
git commit -m "feat(ui): wire thinking_budget_tokens + reasoning_effort through profile/sub-agent forms"
```

---

## Task 10: Functional test — replay frontend wire payload (per harness rule)

**Files:**
- CREATE: `tests/functional/model_thinking_test.py`

**Why:** Per the `replay-frontend-wire-payload-in-functional-tests` rule and the `verification-before-completion` skill, every HTTP-layer change needs a functional harness test — unit tests don't exercise route order, JSON binding edge cases, or validator semantics.

### Step 10.1 — Use the existing harness

The harness at `tests/functional/harness.py` boots `zig-out/bin/pabrikcore-linux-x86_64` against an isolated tmpdir HOME on a free port in 8080-8199 (NEVER 8081). Reuse it.

### Step 10.2 — Write 4 test cases

```python
def test_profile_thinking_off_persists(harness):
    """Profile with thinking='off' round-trips through PUT then GET."""
    # 1. Create profile via PUT /api/config/pabrik with thinking='off'
    # 2. GET /api/config/pabrik → assert profile.thinking == 'off'
    # 3. PUT a 2nd profile with thinking='on' + thinking_budget_tokens=4096
    # 4. GET → assert both profiles persist with correct values

def test_profile_thinking_budget_invalid_rejected(harness):
    """thinking_budget_tokens: 0 → 400 with structured error."""
    # Assert the response body's error message contains 'InvalidThinkingBudgetTokens'

def test_profile_reasoning_effort_invalid_rejected(harness):
    """reasoning_effort: 'super' → 400 with structured error."""

def test_profile_reasoning_effort_roundtrip(harness):
    """reasoning_effort='high' round-trips; null stays null."""
```

### Step 10.3 — Run

```bash
cd /home/ginwa/ginwaaitoolbox && PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/model_thinking_test.py -v 2>&1 | tail -n 30
```

Expect: 4 passed.

### Step 10.4 — Commit

```bash
git add tests/functional/model_thinking_test.py
git commit -m "test(functional): model thinking profile roundtrip + validation"
```

---

## Task 11: Documentation update — note thinking mode in agent prompt

**Files:**
- EDIT: `src/ai_workflow/tui/agentic_loop/prompts_make_agent_prompt.zig` (or whichever file generates the system prompt's "## Active Workers" or settings section) — add a short line so the agent knows thinking is enabled and what mode.

**Why:** When `thinking=on`, the agent should know that extra latency is expected (Sonnet thinking pauses 10-60s, o1/GPT-5 pause 20-120s). When `thinking=off`, the agent should NOT spend time on chain-of-thought inside `<thinking>` tags.

### Step 11.1 — Find the system-prompt builder

Search for `BuildDynamicAgentContent` or the equivalent in `prompts_*.zig` files. Find the section that mentions temperature and add a parallel "Thinking mode" line.

### Step 11.2 — Add the line

Mirror the existing "Temperature: 0.4" line. Add:

```zig
try out_writer.print("Thinking mode: {s}\n", .{
    if (effective_is_thinking_str == "on") "on (extended reasoning enabled)"
    else if (effective_is_thinking_str == "off") "off (no extended reasoning)"
    else "auto (model decides per request)"
});
```

### Step 11.3 — Commit

```bash
git add src/ai_workflow/tui/agentic_loop/prompts_make_agent_prompt.zig
git commit -m "feat(prompt): surface thinking mode in system prompt so the agent knows whether extended reasoning is active"
```

---

## Task 12: Final verification + cleanup

### Step 12.1 — Run full Zig test suite

```bash
cd /home/ginwa/ginwaaitoolbox && timeout 120 zig build test --summary all 2>&1 | tail -n 40
```

Expect: zero failures, zero leaks.

### Step 12.2 — Run full desktop build

```bash
cd /home/ginwa/ginwaaitoolbox && timeout 600 zig build pabrik-desktop --summary all 2>&1 | tail -n 30
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop && bun run build 2>&1 | tail -n 20
```

Expect: 0 errors. The zig build pabrik-desktop step is the critical CI gate (lesson from PR #288).

### Step 12.3 — Run all Vitest

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop && bun run test:unit 2>&1 | tail -n 10
```

Expect: 0 failures.

### Step 12.4 — Run all functional tests

```bash
cd /home/ginwa/ginwaaitoolbox && PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/ -v 2>&1 | tail -n 30
```

Expect: ALL pre-existing tests + 4 new passes, 0 regressions.

### Step 12.5 — Create a follow-up kanban card for the API cost telemetry

The new thinking fields will burn MORE tokens (Anthropic `budget_tokens` + OpenAI `reasoning_tokens`). The `Usage` struct already tracks `total_tokens` but doesn't yet have a `thinking_tokens` field. Create a follow-up task:

```bash
# Use the kanban_create_kanban_task tool with:
# name: "Track thinking_tokens in cost telemetry"
# description: "After this PR lands, Anthropic budget_tokens and OpenAI reasoning_tokens are still conflated into completion_tokens. Add a thinking_tokens column to llm_history + Usage struct so cost logs can bill reasoning at the actual rate (Anthropic: budget_tokens count toward input; OpenAI: reasoning_tokens are billed at o1's premium rate)."
```

### Step 12.6 — Open a PR

```bash
cd /home/ginwa/ginwaaitoolbox && git push origin HEAD
gh pr create --title "feat: model thinking (Claude extended + OpenAI reasoning) end-to-end" --body-file <(cat <<'EOF'
## Summary
Wires Claude extended thinking (Anthropic) and OpenAI reasoning (o1/o3/GPT-5/DeepSeek-R1) end-to-end through config → request body → SSE parse → DB → ChatView. Adds per-profile `thinking_budget_tokens` (Anthropic) and `reasoning_effort` (OpenAI) knobs, the new `type: "adaptive"` Anthropic mode, and the UI "Thinking budget tokens" + "Reasoning effort" inputs in PabrikSettings.

## What changed
- Backend: 7 files edited, 4 created. New `parse_thinking.zig` module, extended `LlmProfile` + `SubAgentConfig` + `ResolvedSubAgent`, wired `effective_is_thinking` + `thinking_budget_tokens` into `workflow.zig`, added `reasoning_effort` + `thinkingBudgetTokens` + `thinkingAdaptive` fields to `Agent.zig`, added Anthropic adaptive mode + budget override, added OpenAI `reasoning_effort` to request body, added HTTP PUT validation.
- Frontend: 3 files edited, 1 created. Extended `LlmConfigForm.vue` with the two new fields (visible only when thinking != "off"), updated PabrikSettings + SubAgentModal defaults + mappers.
- Tests: 6 inline `*_test.zig` cases + 1 Vitest spec + 1 functional harness test.
- No migration (uses existing llm_history columns + nullable new fields).
- No new HTTP routes.

## Why
The UI "Thinking" selector (Auto / On / Off) was already wired in `LlmConfigForm.vue` but only the sub-agent `thinking` field was parsed by `Config.zig`. Main-agent sessions hardcoded `is_thinking = true` via `COALESCE(is_thinking, 1)` at `llm_history.zig:2455`. The OpenAI request body never carried `reasoning_effort`, and Anthropic had no `type: "adaptive"` branch.

## Test plan
- `zig build test --summary all` — baseline 2595+ pass, +13 new
- `zig build pabrik-desktop --summary all` — must pass (PR #288 lesson)
- `bun run test:unit` — 2454+ tests pass, +2 new
- `python3 -m pytest tests/functional/model_thinking_test.py -v` — 4 passed
- Manual: create a profile with `thinking=on + thinking_budget_tokens=4096` against an Anthropic-style URL; observe thinking tokens; create an OpenAI o1 profile with `reasoning_effort=high`; observe longer latency.

## Follow-up
- Add `thinking_tokens` column to llm_history + `Usage` struct so cost telemetry can bill reasoning separately (separate PR).
EOF
)
```

---

## Verification Checklist

Before marking the task complete, ALL of these must be true:

- [ ] `zig build test --summary all` → 0 failures, 0 leaks (Task 12.1)
- [ ] `zig build pabrik-desktop --summary all` → 0 errors (Task 12.2) — **CRITICAL**, this is the CI gate
- [ ] `bun run build` (frontend vue-tsc) → 0 errors (Task 12.2)
- [ ] `bun run test:unit` → 0 failures (Task 12.3)
- [ ] `python3 -m pytest tests/functional/` → all pre-existing + 4 new pass (Task 12.4)
- [ ] All 12 tasks have a corresponding git commit (Tasks 1-12 each end with `git commit`)
- [ ] No `defer allocator.free()` for `ctx.allocator`-allocated slices in any new code (per AGENTS.md "Per-Request Arena Cleanup" rule)
- [ ] No new SSE event types introduced (per "SSE Wire-Format Contract" rule — reuse existing `reasoning_content` flow)
- [ ] Follow-up kanban card created for `thinking_tokens` cost telemetry (Task 12.5)
- [ ] PR opened with the body template (Task 12.6)

## Pitfalls (worth flagging upfront)

1. **`zig build test` ≠ `zig build pabrik-desktop`** — the test build is more permissive about cross-module struct lookup. Always run BOTH. (Lesson from PR #288.)
2. **`COALESCE(is_thinking, 1)` in `llm_history.zig:2455`** — this is the silent default that's been making main-agent sessions always-think. Task 3 is the only place that breaks this. If the resolve chain there is wrong, no other task will catch it.
3. **Arena lifetime** — `effective_is_thinking_str` is a borrowed slice from the config; do NOT `defer allocator.free()` on it. Pass it straight into `parseThinkingString` which itself just returns a `?bool` (no allocation).
4. **The Anthropic `type: "adaptive"` branch is silently ignored by older Claude models** — Sonnet 4.5+ accepts it; Sonnet 3.7 / Opus 4 do not. We accept that risk because the request body also carries the regular `thinking` shape on older models (the `thinkingAdaptive` flag only flips when `profile.thinking == "auto"`).
5. **OpenAI o1-pro vs o1-mini vs o3-mini** all have different reasoning_effort semantics. We do NOT validate model compatibility — we let the server reject with a 400, which surfaces in `last_error_message` (already wired in `Agent.zig:886`).
6. **Empty-string vs null handling** — the UI uses `null` for "auto" but a user-typed empty string is treated as `null` (not as an invalid value). `parse_thinking.parseThinkingString` returns `null` for empty input. Both paths converge.
7. **Profile naming on the `PabrikSettings` mapper** — when extending `profilesToRecord`, the field name on the API DTO (`reasoning_effort`) must match the field name on the form DTO (`reasoning_effort`). Both `ApiPabrikProfile` and `LlmConfig` use snake_case so this is fine, but verify by grep before wiring.
8. **Skip the chatview render work** — ChatView already renders `reasoning_content` (line 1207-1447). Do NOT add a new "thinking drawer" — out of scope. The user just asked to wire the feature end-to-end, not redesign the UI.
