# Configurable Compaction Settings Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `max_capacity_token_model` (per-model context-window override in tokens) and `compaction_threshold_percent` (0–100, default 80) configurable in `config.json` so users can tune compaction without recompiling. Expose both fields through the existing `GET/PUT /api/config/nalar` REST endpoints and the TypeScript `NalarConfig` type so the desktop UI can edit them in a future iteration.

**Architecture:** Extend `LlmConfig` (the typed in-memory config that `Config.zig` parses from `config.json`) with two new owned fields. Add a `compaction_settings` section to `defaultConfigJson` so a fresh install writes both fields with documented defaults. Keep `LLMModels.getModelTokenCount` and `LLMModels.isDoCompact` as **pure** functions (no config dependency, fully unit-testable) and add a thin config-aware wrapper for each. Update the two production call sites (`workflow.zig:maybeCompactMessagesNew` for the threshold check, `llm_history.zig:SessionMessageResponse.max_capacity_total_tokens` for the displayed capacity) to read from `LlmConfig` instead of the hardcoded path. Extend the HTTP `GET/PUT /api/config/nalar` wire format and the TypeScript `NalarConfig` interface so the settings round-trip end-to-end. Add regression tests at every layer.

**Tech Stack:** Zig 0.16, `std.json.parseFromSlice` (config parsing), `std.json.Stringify.valueAlloc` (HTTP response), `LlmConfig` accessor `nalarcore.getLlmConfig(di)`, `LlmConfig` field getter convention already in use for `model_compaction_size_kb` (see `nalar_config_get.zig:113` and `nalar_config_put.zig:104`). TypeScript / Vue (frontend interface update only — no UI work in this iteration).

---

## File Structure

| File | Responsibility | New / Modified |
|------|----------------|----------------|
| `src/modules/config/Config.zig` | Add `max_capacity_token_model: ?u32` + `compaction_threshold_percent: ?u8` to `LlmConfigJson` and `LlmConfig`. Add both to `defaultConfigJson`. Add helper accessors `maxCapacityForModel(name)` and `compactionThresholdPercent()`. | Modified |
| `src/modules/config/config_test.zig` | Tests for both new fields (read from JSON, default-when-missing, defaultConfigJson contains both, writeDefaultConfig round-trip). | Modified |
| `src/modules/agent/LLMModels.zig` | Keep existing pure `getModelTokenCount` / `isDoCompact` unchanged. Add `resolveMaxCapacity(model_name, override_capacity)` and `shouldCompact(token_count, max_capacity, threshold_percent)` wrappers. | Modified |
| `src/modules/agent/LLMModels_test.zig` | Tests for the two new wrapper helpers. Register file in `src/modules/agent/test_runner.zig`. | Modified + new import |
| `src/modules/agent/test_runner.zig` | Add `_ = @import("LLMModels_test.zig");` so the 17 existing + 6 new tests run. | Modified |
| `src/ai_workflow/tui/workflow.zig` | `maybeCompactMessagesNew`: read `config.compaction_threshold_percent` and `config.max_capacity_token_model`, use `LLMModels.shouldCompact` + `LLMModels.resolveMaxCapacity` instead of the bare helpers. | Modified |
| `src/ai_workflow/tui/llm_history.zig` | `SessionMessageResponse.max_capacity_total_tokens`: use `LLMModels.resolveMaxCapacity(model, config.max_capacity_token_model)` instead of bare `getModelTokenCount`. | Modified |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | `NalarConfigResponse`: add `max_capacity_token_model: ?u32 = null` + `compaction_threshold_percent: ?u8 = null`. | Modified |
| `src/ai_workflow/tui/http_handlers/nalar_config_get.zig` | Read both fields from `cfg` into the response. Add both fields to the inner `ConfigJson` struct. | Modified |
| `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` | Add both fields to `ConfigInput` and `ConfigJson`. Apply `if (input.X) |v| ...` mirror blocks like the existing `model_compaction_size_kb` block. | Modified |
| `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig` | `makeConfig`: set both new fields to their defaults so existing tests don't have to change. Add a new test that verifies the PUT handler applies both overrides. | Modified |
| `src/apps/desktop/src/api/index.ts` | Extend `NalarConfig` TypeScript interface with both fields. | Modified |
| `src/apps/desktop/src/components/nalar/CompactionSection.vue` | New Vue component exposing both fields via checkbox + input controls. Renders the override-built-in-default UX for each field. | **New** |
| `src/apps/desktop/src/components/nalar/NalarTabStrip.vue` | Add 5th tab "Compaction". Extend the `TabId` type union. | Modified |
| `src/apps/desktop/src/components/NalarSettings.vue` | Wire `CompactionSection` into the tab strip: new `compactionConfig` ref, extend `syncFromConfig` + `syncToConfig`, add to the watch list, render the section under the new tab. | Modified |
| `src/apps/desktop/src/__tests__/CompactionSection.spec.ts` | New Vitest spec — 5 tests (renders headers, emits on each input, checkbox toggle clears/sets, helper text). | **New** |

**Why this decomposition:**
- The pure-function discipline (`getModelTokenCount` / `isDoCompact` stay free of config) means the 11 existing unit tests in `LLMModels_test.zig` continue to pass without modification — the wrappers layer on top, not replace.
- Two thin accessors on `LlmConfig` (`maxCapacityForModel` / `compactionThresholdPercent`) match the existing accessor-less convention (callers read fields directly via `nalcore.getLlmConfig(di).max_capacity_token_model`) but normalize the "null means use LLMModels default" rule in one place so callers don't repeat `cfg.max_capacity_token_model orelse llm_models.getModelTokenCount(model)`.
- HTTP `GET/PUT` mirrors the `model_compaction_size_kb` shape exactly — same wire-side `?usize` optional, same `if (input.X) |v| config_json.X = v;` apply block — so the diff is small and the existing static-contract tests can be extended with one new test per field.
- Frontend changes are type-only (the UI does not yet render the new fields); the wire format is the contract that matters and must stay in sync.

---

## Chunk 1: Add the two new fields to `LlmConfig` and `defaultConfigJson`

### Task 1.1: Extend `LlmConfigJson` to parse the two new fields

**Files:**
- Modify: `src/modules/config/Config.zig` (around line 153-170 — the `LlmConfigJson` struct inside `LlmConfig`)

- [ ] **Step 1.1.1: Add the two fields to `LlmConfigJson`**

After the existing `model_compaction_size_kb` field (line 158), add:

```zig
/// Optional override for the model's context window (in tokens).
/// When `null`, `LLMModels.getModelTokenCount(model)` returns the
/// built-in per-model default (200_000 for MiniMax-M2.7, 500_000 for
/// MiniMax-M3, 200_000 fallback). When set, this value is used
/// instead of the built-in default — useful for users who want to
/// under-provision a model for cost reasons or over-provision a
/// self-hosted model with a larger context window.
max_capacity_token_model: ?u32 = null,
/// Compaction threshold as a percentage (0-100) of the model's
/// context window. The conversation is compacted when
/// `total_tokens >= max_capacity * threshold / 100`. When `null`,
/// defaults to 80 (the historical hardcoded value in
/// `LLMModels.isDoCompact`). Range-validated at the HTTP layer.
compaction_threshold_percent: ?u8 = null,
```

Both are nullable so existing config files (and the tests that build
`LlmConfig` literals) keep working without changes — `null` means
"fall back to the LLMModels default".

- [ ] **Step 1.1.2: Add the same two fields to the `LlmConfig` struct**

In the outer `LlmConfig` struct (around line 6-37), after the
`model_compaction_size_kb: usize` field (line 11), add:

```zig
/// Optional override for the model's context window in tokens. See
/// `LlmConfigJson.max_capacity_token_model` for semantics.
max_capacity_token_model: ?u32,
/// Compaction threshold percentage (0-100). See
/// `LlmConfigJson.compaction_threshold_percent` for semantics.
compaction_threshold_percent: ?u8,
```

Both are NON-NULLABLE here (no `= null`) because the config loader
will materialise `null` to the documented default at parse time.
This keeps callers from having to do `orelse` everywhere.

- [ ] **Step 1.1.3: Materialise both fields in `init`**

In `LlmConfig.init` (around line 303-315), after the existing
`.model_compaction_size_kb = config_json.model_compaction_size_kb,`
line, add:

```zig
.max_capacity_token_model = config_json.max_capacity_token_model,
.compaction_threshold_percent = config_json.compaction_threshold_percent,
```

Update the `errdefer` block (line 316-325) if it needs new
cleanup — both fields are `?u32` / `?u8` value types with no heap
allocation, so NO new `allocator.free` is needed.

- [ ] **Step 1.1.4: Add helper accessors**

After the existing `resolveSubAgent` method (around line 1108), add:

```zig
/// Resolve the effective max-context-window in tokens for `model_name`.
/// Returns `self.max_capacity_token_model` if set, otherwise falls
/// back to the built-in `LLMModels.getModelTokenCount(model_name)`.
/// Use this everywhere a "what's the model's context window?" answer
/// is needed instead of calling `LLMModels.getModelTokenCount`
/// directly.
pub fn maxCapacityForModel(self: *const LlmConfig, model_name: []const u8) u32 {
    if (self.max_capacity_token_model) |override| return override;
    return LLMModels.getModelTokenCount(model_name);
}

/// Resolve the compaction threshold as a percentage (0-100). Returns
/// `self.compaction_threshold_percent` if set, otherwise 80 (the
/// historical hardcoded value in `LLMModels.isDoCompact`).
pub fn compactionThresholdPercent(self: *const LlmConfig) u8 {
    return self.compaction_threshold_percent orelse 80;
}
```

(Requires `LLMModels` to be importable from `Config.zig`. Add
`const LLMModels = @import("../agent/LLMModels.zig");` at the top
of the file. Verify the import is already present or add it.)

- [ ] **Step 1.1.5: Update the existing `model_compaction_size_kb` test fixture**

`src/modules/config/config_test.zig:36` (in `makeConfig` of the
config_put test) sets `.model_compaction_size_kb = 100,`. Add the
two new fields below it:

```zig
.max_capacity_token_model = null,
.compaction_threshold_percent = null,
```

This is a fixture-only change so the existing 8+ tests in
`nalar_config_put_test.zig` keep passing. The values `null` mean
"fall back to defaults" — semantically identical to the
pre-change behavior.

- [ ] **Step 1.1.6: Run `zig build test --summary all` and confirm compile**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: all existing tests still pass (no behavior change yet —
the two new fields default to `null` so callers fall back to
existing behavior).

### Task 1.2: Add the two fields to `defaultConfigJson`

**Files:**
- Modify: `src/modules/config/Config.zig` (lines 1117-1125 — the `defaultConfigJson` const)

- [ ] **Step 1.2.1: Add the two fields to the JSON template**

```zig
pub const defaultConfigJson: []const u8 =
    \\{
    \\  "api_key": "",
    \\  "model": "",
    \\  "base_url": "",
    \\  "url_style": "openai",
    \\  "model_compaction_size_kb": 100,
    \\  "notify_on_complete": false,
    \\  "max_capacity_token_model": null,
    \\  "compaction_threshold_percent": null
    \\}
;
```

Use `null` (not 80 / 200000) so a fresh install clearly documents
"no override — use the built-in defaults" via the JSON file. Users
who want to customise can hand-edit to e.g. `"compaction_threshold_percent": 70`.

- [ ] **Step 1.2.2: Add the existing-default-presence tests' new assertions**

The two existing tests at `config_test.zig:1076` and `config_test.zig:1157`
assert the JSON contains `"model_compaction_size_kb": 100`. Mirror them:

After `config_test.zig:1076`:
```zig
try std.testing.expectEqualStrings("null", obj.get("max_capacity_token_model").?.string_or_null_value // null literal is .null variant in std.json.Value
    orelse "<missing>");
try std.testing.expectEqualStrings("null", obj.get("compaction_threshold_percent").?.*.string // or whatever shape
    orelse "<missing>");
```

Actually, JSON `null` parses to `std.json.Value{ .null = {} }` — to
test for null, use:

```zig
const max_cap_val = obj.get("max_capacity_token_model").?;
try std.testing.expect(max_cap_val == .null);
const threshold_val = obj.get("compaction_threshold_percent").?;
try std.testing.expect(threshold_val == .null);
```

(Switch on the variant directly; `std.json.Value` is a tagged
union, `obj.get` returns `?std.json.Value`, `== .null` checks the
variant.)

After `config_test.zig:1157`, add substring assertions on the raw
JSON:
```zig
try std.testing.expect(std.mem.indexOf(u8, content, "\"max_capacity_token_model\": null") != null);
try std.testing.expect(std.mem.indexOf(u8, content, "\"compaction_threshold_percent\": null") != null);
```

- [ ] **Step 1.2.3: Run tests, confirm both new assertions pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: tests count is unchanged + 0 (no NEW tests yet — the
existing tests now also assert the new defaults are present). All
green.

### Task 1.3: Add focused unit tests for the new fields

**Files:**
- Modify: `src/modules/config/config_test.zig`

- [ ] **Step 1.3.1: Add tests for read + default behavior of both fields**

Append to `config_test.zig`:

```zig
test "LlmConfig: max_capacity_token_model reads value from JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "max_capacity_token_model": 128000 }
    ;
    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u32, 128000), cfg.max_capacity_token_model);
}

test "LlmConfig: max_capacity_token_model defaults to null when missing from JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;
    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u32, null), cfg.max_capacity_token_model);
}

test "LlmConfig: compaction_threshold_percent reads value from JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "compaction_threshold_percent": 70 }
    ;
    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u8, 70), cfg.compaction_threshold_percent);
}

test "LlmConfig: compaction_threshold_percent defaults to null when missing from JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;
    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u8, null), cfg.compaction_threshold_percent);
}

test "LlmConfig: maxCapacityForModel returns override when set" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "max_capacity_token_model": 1000000 }
    ;
    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u32, 1000000), cfg.maxCapacityForModel("MiniMax-M3"));
    // Override applies regardless of the model name (override is per-config, not per-model).
    try std.testing.expectEqual(@as(u32, 1000000), cfg.maxCapacityForModel("SomeOtherModel"));
}

test "LlmConfig: maxCapacityForModel falls back to LLMModels default when null" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b" }
    ;
    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    // MiniMax-M3 default is 500_000 (see LLMModels.zig:18).
    try std.testing.expectEqual(@as(u32, 500000), cfg.maxCapacityForModel("MiniMax-M3"));
    // Unknown model falls back to 200_000 (LLMModels.zig:31).
    try std.testing.expectEqual(@as(u32, 200000), cfg.maxCapacityForModel("Unknown"));
}

test "LlmConfig: compactionThresholdPercent returns override when set" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "compaction_threshold_percent": 50 }
    ;
    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 50), cfg.compactionThresholdPercent());
}

test "LlmConfig: compactionThresholdPercent returns 80 when null" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;
    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent());
}
```

- [ ] **Step 1.3.2: Run tests, confirm 8 new tests pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: test count goes from previous baseline + 8 (the 4 read/default pairs + 2 maxCapacityForModel + 2 compactionThresholdPercent).

---

## Chunk 2: Add config-aware wrappers in `LLMModels`

### Task 2.1: Add `resolveMaxCapacity` and `shouldCompact` helpers

**Files:**
- Modify: `src/modules/agent/LLMModels.zig` (after line 38 — end of file)

- [ ] **Step 2.1.1: Add the two new pure helpers**

After the existing `isDoCompact` (line 34-38), append:

```zig
/// Resolve the effective max-context-window in tokens for `model_name`,
/// honoring an optional config override. When `override_capacity` is
/// `null`, falls through to `getModelTokenCount(model_name)`. When
/// non-null, the override value wins (regardless of which model is
/// being used — the override is per-config, not per-model).
pub fn resolveMaxCapacity(model_name: []const u8, override_capacity: ?u32) u32 {
    return override_capacity orelse getModelTokenCount(model_name);
}

/// Decide whether `token_count` should trigger compaction given a
/// `max_capacity` (in tokens) and a `threshold_percent` (0-100).
/// Equivalent to `token_count >= max_capacity * threshold_percent / 100`.
/// When `threshold_percent` is null, defaults to 80 (the historical
/// value baked into `isDoCompact`).
pub fn shouldCompact(token_count: u32, max_capacity: u32, threshold_percent: ?u8) bool {
    const pct: u32 = threshold_percent orelse 80;
    const threshold = max_capacity * pct / 100;
    return token_count >= threshold;
}
```

The existing `getModelTokenCount` and `isDoCompact` are kept
unchanged — they're already covered by 11+ unit tests in
`LLMModels_test.zig` and removing them would break the test suite
(per the `pure-function discipline` rationale in the architecture
section). The wrappers are tiny, do no I/O, and are easy to verify
on their own.

- [ ] **Step 2.1.2: Add tests for the wrappers**

Append to `src/modules/agent/LLMModels_test.zig`:

```zig
test "resolveMaxCapacity returns override when set" {
    try expectEqual(@as(u32, 128000), resolve_max_capacity("MiniMax-M3", 128000));
    try expectEqual(@as(u32, 128000), resolve_max_capacity("Unknown", 128000));
}

test "resolveMaxCapacity falls back to getModelTokenCount when override is null" {
    try expectEqual(@as(u32, 500000), resolve_max_capacity("MiniMax-M3", null));
    try expectEqual(@as(u32, 200000), resolve_max_capacity("MiniMax-M2.7", null));
    try expectEqual(@as(u32, 200000), resolve_max_capacity("Unknown", null));
}

test "shouldCompact with custom threshold_percent" {
    // 50% of 200k = 100k threshold
    try expect(!should_compact(99_999, 200_000, 50));
    try expect(should_compact(100_000, 200_000, 50));
    try expect(should_compact(200_000, 200_000, 50));
}

test "shouldCompact with null threshold_percent defaults to 80%" {
    try expect(!should_compact(159_999, 200_000, null));
    try expect(should_compact(160_000, 200_000, null));
    try expect(should_compact(250_000, 200_000, null));
}

test "shouldCompact with threshold_percent=0 never triggers" {
    // 0% threshold = never compact (token_count >= 0 always, but *0/100 = 0)
    try expect(should_compact(0, 200_000, 0));
    try expect(should_compact(1, 200_000, 0));
    try expect(should_compact(1_000_000, 200_000, 0));
}

test "shouldCompact with threshold_percent=100 always triggers (unless token_count is 0)" {
    // 100% threshold = token_count >= max_capacity
    try expect(!should_compact(99, 100, 100));
    try expect(should_compact(100, 100, 100));
    try expect(should_compact(101, 100, 100));
}
```

And at the top of the file, add the two function imports:

```zig
const resolve_max_capacity = LLMModels.resolveMaxCapacity;
const should_compact = LLMModels.shouldCompact;
```

- [ ] **Step 2.1.3: Register the test file in the agent module's test_runner**

`src/modules/agent/test_runner.zig` does NOT currently import
`LLMModels_test.zig` (the 17 tests there are dead code — they
don't run today). Add the import at the top:

```zig
test {
    _ = @import("LLMModels_test.zig"); // 17 existing + 6 new tests
    // ... existing imports ...
}
```

Verify with: `rg -n "LLMModels_test" src/modules/agent/test_runner.zig`
before/after.

- [ ] **Step 2.1.4: Run tests, confirm 6 new + 17 existing = 23 LLMModels tests pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: test count goes from previous baseline + 23 (the 17
previously-dead tests now actually run, + 6 new ones). All green.

---

## Chunk 3: Wire the config into the two production call sites

### Task 3.1: `workflow.zig:maybeCompactMessagesNew` reads the threshold from config

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig` (line 863 — the single `isDoCompact` call)

- [ ] **Step 3.1.1: Read the threshold from `LlmConfig`**

The function currently does NOT have access to `LlmConfig` — it
takes `model: []const u8` only. Two options:

**Option A — add a `LlmConfig` parameter** (preferred):
Change the function signature from:
```zig
pub fn maybeCompactMessagesNew(
    allocator: std.mem.Allocator,
    total_tokens: u32,
    model: []const u8,
    force: bool,
    messages: *std.ArrayList(agent.AgentMessage),
    api_key: []const u8,
    base_url: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *logger_mod.Logger,
) !bool
```
to:
```zig
pub fn maybeCompactMessagesNew(
    allocator: std.mem.Allocator,
    total_tokens: u32,
    model: []const u8,
    force: bool,
    messages: *std.ArrayList(agent.AgentMessage),
    api_key: []const u8,
    base_url: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *logger_mod.Logger,
    llm_config: *const nalarcore.config.LlmConfig, // NEW
) !bool
```

Then update the body (line 863):
```zig
if (!force and !agent.LLMModels.shouldCompact(
    total_tokens,
    llm_config.maxCapacityForModel(model),
    llm_config.compactionThresholdPercent(),
)) {
    return false;
}
```

The new code reads BOTH the per-model override (via
`maxCapacityForModel`) AND the threshold override (via
`compactionThresholdPercent`) — neither require separate `?u32`
arguments at the call site. This is the canonical "config flows
through one accessor pair" pattern.

Update the 1 caller of `maybeCompactMessagesNew`. Find it with:
`rg -n "maybeCompactMessagesNew" src/`. Add `config,` (where
`config = nalarcore.getLlmConfig(di);`) to the call site.

- [ ] **Step 3.1.2: Verify the signature change compiles**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 0 compile errors (the call site update MUST be done in
the same step or the test build fails with "expected N argument(s),
found M").

**Option B — fall back if you can't easily thread `LlmConfig`**:
If the call site is hard to thread (e.g., a deep call stack), pass
two `?u32` / `?u8` parameters instead. Add the same two `if (cfg.X) |v| ...`
lines that the existing functions would need. This is uglier but
avoids changing the function's signature. Prefer Option A unless
the call site change is genuinely complex.

### Task 3.2: `llm_history.zig` reads the per-model override for the displayed capacity

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig` (line 682-685 — the `max_capacity_total_tokens` field)

- [ ] **Step 3.2.1: Use `resolveMaxCapacity` to honor the override**

The current code is:
```zig
.max_capacity_total_tokens = if (nalarcore.getSingleton() catch null) |di|
    llm_models.getModelTokenCount(nalarcore.getLlmConfig(di).model)
else
    llm_models.getModelTokenCount(""),
```

Replace with:
```zig
.max_capacity_total_tokens = blk: {
    const override = if (nalarcore.getSingleton() catch null) |di|
        nalarcore.getLlmConfig(di).max_capacity_token_model
    else
        null;
    break :blk llm_models.resolveMaxCapacity(
        if (nalarcore.getSingleton() catch null) |di|
            nalarcore.getLlmConfig(di).model
        else
            "",
        override,
    );
},
```

The `blk:` is needed to call `getLlmConfig(di)` twice without a
side-effect-free mutable binding (the `orelse` type-unification
issue documented in `zig-orelse-type-unification-mismatch.md`). A
helper accessor on `LlmConfig` would also work:

```zig
.max_capacity_total_tokens = blk: {
    if (nalarcore.getSingleton() catch null) |di| {
        const cfg = nalarcore.getLlmConfig(di);
        break :blk cfg.maxCapacityForModel(cfg.model);
    }
    break :blk llm_models.getModelTokenCount("");
},
```

Use whichever is cleaner — the second form is preferred because
it only resolves the singleton once and uses the accessor pair
consistently.

- [ ] **Step 3.2.2: Run tests, confirm no regression**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 0 new failures (the change preserves the previous
behavior when `max_capacity_token_model` is `null` — falls back to
the built-in per-model token count).

### Task 3.3: Add a workflow-level integration test

**Files:**
- Modify: `src/ai_workflow/tui/workflow_compaction_envelope_test.zig` (or new file)

- [ ] **Step 3.3.1: Add a test that asserts the threshold reads from config**

Look for an existing test that exercises `maybeCompactMessagesNew`
(or its caller). Add a sibling test that:
1. Constructs a `LlmConfig` with `compaction_threshold_percent = 50`.
2. Constructs a `LlmConfig` with `compaction_threshold_percent = null` (defaults to 80).
3. For both, calls `LLMModels.shouldCompact(token_count, capacity, cfg.compactionThresholdPercent())` with `token_count` near the threshold boundary.
4. Asserts the two configs produce DIFFERENT decisions at the
   same token count (a regression test that would have caught a
   "wired the wrong config field" bug).

```zig
test "compaction threshold respects config.compaction_threshold_percent" {
    const allocator = testing.allocator;

    // Two configs — only compaction_threshold_percent differs.
    const cfg80 = try makeConfigWithThreshold(allocator, null); // → 80
    defer cfg80.deinit();
    const cfg50 = try makeConfigWithThreshold(allocator, 50);
    defer cfg50.deinit();

    const cap: u32 = 200_000;
    const at_79pct: u32 = 158_000;

    // 79% is below 80% threshold → no compact under cfg80
    try testing.expect(!LLMModels.shouldCompact(at_79pct, cap, cfg80.compactionThresholdPercent()));
    // 79% is above 50% threshold → compact under cfg50
    try testing.expect(LLMModels.shouldCompact(at_79pct, cap, cfg50.compactionThresholdPercent()));
}
```

`makeConfigWithThreshold` is a small helper that creates a
minimal `LlmConfig` with only the threshold field set — mirrors
the existing test helpers in the file. If too much boilerplate
is needed, factor out a `makeLlmConfigWithThreshold(allocator,
threshold: ?u8)` helper at the top of the test file.

- [ ] **Step 3.3.2: Run tests, confirm new test passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: test count goes from previous baseline + 1. All green.

---

## Chunk 4: Expose both fields through the HTTP `GET/PUT /api/config/nalar` endpoints

### Task 4.1: Extend `NalarConfigResponse` and `nalar_config_get.zig`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig` (line 276 — the `model_compaction_size_kb` field)
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_get.zig` (line 113 — the response assembly; line 142 — the inner `ConfigJson` struct)

- [ ] **Step 4.1.1: Add both fields to `NalarConfigResponse`**

In `http_response.zig`, after line 276 (`model_compaction_size_kb: usize = 100`), add:

```zig
/// Optional override for the model's context window in tokens.
/// When null, `LLMModels.getModelTokenCount(model)` returns the
/// built-in default. Consumed by `workflow.zig:maybeCompactMessagesNew`
/// via `LlmConfig.maxCapacityForModel`.
max_capacity_token_model: ?u32 = null,
/// Compaction threshold as a percentage (0-100) of the model's
/// context window. When null, defaults to 80. Consumed by
/// `workflow.zig:maybeCompactMessagesNew` via
/// `LlmConfig.compactionThresholdPercent`.
compaction_threshold_percent: ?u8 = null,
```

Both default to `null` so existing responses (and any frontend
code that hasn't been updated) keep working unchanged.

- [ ] **Step 4.1.2: Populate both fields in `nalar_config_get.zig`**

After line 113 (`.model_compaction_size_kb = cfg.model_compaction_size_kb,`), add:

```zig
.max_capacity_token_model = cfg.max_capacity_token_model,
.compaction_threshold_percent = cfg.compaction_threshold_percent,
```

- [ ] **Step 4.1.3: Add both fields to the inner `ConfigJson` (get handler)**

After line 142 (`model_compaction_size_kb: usize = 100`), add:

```zig
/// Per-model context window override. Matches `LlmConfigJson`.
max_capacity_token_model: ?u32 = null,
/// Compaction threshold percentage (0-100). Matches `LlmConfigJson`.
compaction_threshold_percent: ?u8 = null,
```

- [ ] **Step 4.1.4: Run tests, confirm GET round-trips the new fields**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: all existing tests pass. (No new GET test yet — add one
in Task 4.3.)

### Task 4.2: Extend `nalar_config_put.zig` to apply both overrides

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` (line 104-106 — the apply block; line 288 — `ConfigInput`; line 325 — inner `ConfigJson`)

- [ ] **Step 4.2.1: Add apply-block mirrors of both fields**

After line 106 (the existing `if (input.model_compaction_size_kb) |kb|` block), add:

```zig
if (input.max_capacity_token_model) |mc| {
    config_json.max_capacity_token_model = mc;
}
if (input.compaction_threshold_percent) |tp| {
    if (tp > 100) return error.InvalidThresholdPercent;
    config_json.compaction_threshold_percent = tp;
}
```

The `> 100` guard matches the documented range (0–100) and returns
an error variant the existing `LoadError` enum covers — if
`InvalidThresholdPercent` is not in the enum, add it.

- [ ] **Step 4.2.2: Add both fields to `ConfigInput`**

After line 288 (`model_compaction_size_kb: ?usize = null`), add:

```zig
/// Optional override for the model's context window in tokens.
/// Absent = preserve existing on-disk value. Mirrors the
/// `LlmConfigJson` default (null = use built-in per-model token
/// count).
max_capacity_token_model: ?u32 = null,
/// Compaction threshold percentage (0-100). Absent = preserve
/// existing on-disk value. Mirrors the `LlmConfigJson` default
/// (null = use 80). Out-of-range values (e.g. > 100) surface as
/// `error.InvalidThresholdPercent`.
compaction_threshold_percent: ?u8 = null,
```

- [ ] **Step 4.2.3: Add both fields to the inner `ConfigJson` (put handler)**

After line 325 (`model_compaction_size_kb: usize = 100`), add:

```zig
max_capacity_token_model: ?u32 = null,
compaction_threshold_percent: ?u8 = null,
```

- [ ] **Step 4.2.4: Run tests, confirm PUT still works for existing fields**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: all existing tests pass (no behavior change — the new
input fields default to `null` which means "preserve on-disk
value").

### Task 4.3: Add HTTP-level integration tests

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig`

- [ ] **Step 4.3.1: Add PUT tests for both new fields**

Mirror the existing `model_compaction_size_kb` tests (find them
with `rg -n "model_compaction_size_kb" src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig`).

Add two new tests that exercise the apply-block via a real
PUT handler call:

```zig
test "PUT applies max_capacity_token_model to LlmConfig" {
    // ... build a minimal ctx + handler ... (mirror existing pattern) ...
    // ... call handler with input.max_capacity_token_model = 128000 ...
    // ... assert config.max_capacity_token_model == 128000 after call ...
}

test "PUT rejects compaction_threshold_percent > 100" {
    // ... call handler with input.compaction_threshold_percent = 150 ...
    // ... assert returns error.InvalidThresholdPercent ...
}

test "PUT preserves max_capacity_token_model when null in input" {
    // ... pre-set config to some value (e.g. 256000) ...
    // ... call handler with input.max_capacity_token_model = null ...
    // ... assert config.max_capacity_token_model unchanged ...
}
```

If the existing PUT tests use a particular pattern (mock helper,
`makeConfig` helper, etc.), match it exactly. The point of these
tests is to lock in the wire-side behavior so a future refactor
can't silently break it.

- [ ] **Step 4.3.2: Add a static-contract GET test**

Mirror the existing GET pattern (find `nalar_config_get_test.zig` or
similar; if no such file exists, add one):

```zig
test "GET response includes max_capacity_token_model and compaction_threshold_percent" {
    // ... build a minimal ctx with cfg.max_capacity_token_model = 256000,
    //     cfg.compaction_threshold_percent = 60 ...
    // ... call handler ...
    // ... assert response JSON contains both fields with correct values ...
}
```

- [ ] **Step 4.3.3: Run tests, confirm all new + existing pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: test count goes from previous baseline + 3 or + 4
(depending on how the GET test is structured). All green.

---

## Chunk 5: Extend the frontend TypeScript types

### Task 5.1: Add both fields to the `NalarConfig` interface

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts` (around line 1992 — the `model_compaction_size_kb?: number` field)

- [ ] **Step 5.1.1: Add the two new optional fields**

After line 1992 (`model_compaction_size_kb?: number`), add:

```ts
/**
 * Optional override for the model's context window in tokens.
 * When omitted, the backend's built-in per-model token count is
 * used (e.g. 200_000 for MiniMax-M2.7, 500_000 for MiniMax-M3,
 * 200_000 fallback). Useful for under-provisioning a model for
 * cost reasons or over-provisioning a self-hosted model.
 */
max_capacity_token_model?: number
/**
 * Compaction threshold as a percentage (0-100) of the model's
 * context window. When omitted, defaults to 80. Out-of-range
 * values are rejected by the backend.
 */
compaction_threshold_percent?: number
```

Both are `number` (matching `model_compaction_size_kb?: number`) —
the wire format is JSON so `u32` / `u8` from the backend are
erased to `number` on the frontend.

- [ ] **Step 5.1.2: Update `NalarSettings.vue` if it constructs a defaults literal**

Open `src/apps/desktop/src/components/NalarSettings.vue`. Search
for the `defaultsConfig` literal (around line 237). If it has an
explicit shape that omits the new fields, add them with `null`:

```ts
defaultsConfig: {
  // ... existing fields ...
  max_capacity_token_model: null,
  compaction_threshold_percent: null,
}
```

If the literal uses a spread (`...c` from `getNalarConfig()`), no
change needed — the new fields flow through automatically.

- [ ] **Step 5.1.3: Update the `DefaultsSection` interface if it asserts the shape**

Open `src/apps/desktop/src/components/nalar/DefaultsSection.vue`
(line 4-13 — the `DefaultsConfig` interface). The interface is for
the DEFAULT LLM section — it currently does NOT include
`max_capacity_token_model` or `compaction_threshold_percent`
(those are compaction settings, not default-LLM settings). If
you decide the new fields belong in a DIFFERENT settings section
(not yet built), do NOT extend `DefaultsConfig` — extend a new
interface (e.g. `CompactionConfig` in a future
`CompactionSection.vue` component). Out of scope for this plan.

- [ ] **Step 5.1.4: Update `DefaultsSection.spec.ts` if it asserts the response shape**

Open `src/apps/desktop/src/__tests__/DefaultsSection.spec.ts`. If
the test asserts the default-config literal's field set, add the
two new fields with `null` defaults. If the test only mounts the
component with a minimal fixture, no change needed.

- [ ] **Step 5.1.5: Run frontend tests + type check**

Run:
```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
timeout 120 bunx vitest run 2>&1 | tail -n 20
```

Per project memory `desktop-typescript-bun-build-as-typecheck.md`:
`bun run build` is the authoritative type-check (NOT `vitest run`).
Expected: 0 TypeScript errors. All Vitest tests green.

---

## Chunk 6: End-to-end verification

### Task 6.1: Manual smoke test against a real `config.json`

**Files:**
- Touch: `~/.config/nalar/config.json` (manual edit)

- [ ] **Step 6.1.1: Read the current `config.json` and back it up**

Run: `cp ~/.config/nalar/config.json ~/.config/nalar/config.json.bak`

- [ ] **Step 6.1.2: Start `nalar` against the current config (sanity check)**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build install:linux:system 2>&1 | tail -n 5`
Then: `./zig-out/bin/nalar --port 8080 &`
Then: `curl -sS http://127.0.0.1:8080/api/config/nalar | jq '.max_capacity_token_model, .compaction_threshold_percent'`

Expected: Both fields are present in the response, both are `null`
(no override set yet). Server log shows no errors.

Kill: `kill $(pgrep -f "nalar --port 8080")` (DO NOT use `pkill -f nalar` — that would also catch the long-lived `nalar` on port 8081).

- [ ] **Step 6.1.3: Edit `config.json` to set both overrides**

Add to `~/.config/nalar/config.json` (top level, after
`notify_on_complete`):
```json
"max_capacity_token_model": 128000,
"compaction_threshold_percent": 70
```

- [ ] **Step 6.1.4: Restart `nalar` and re-query**

```bash
./zig-out/bin/nalar --port 8080 &
curl -sS http://127.0.0.1:8080/api/config/nalar | jq '.max_capacity_token_model, .compaction_threshold_percent'
```

Expected: `max_capacity_token_model: 128000`,
`compaction_threshold_percent: 70`. Both values echoed back from
the server.

Kill: `kill $(pgrep -f "nalar --port 8080")`.

- [ ] **Step 6.1.5: Restore the original config**

Run: `mv ~/.config/nalar/config.json.bak ~/.config/nalar/config.json`

### Task 6.2: Full test suite verification

- [ ] **Step 6.2.1: Run BOTH `zig build test` and `zig build install:linux:system`**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 240 zig build test --summary all 2>&1 | tail -n 5
timeout 240 zig build install:linux:system 2>&1 | tail -n 10
```

Per project memory `verification-before-completion.md`:
- `zig build test` green (test count = baseline + 23 LLMModels + 8
  LlmConfig + 1 workflow + 3 or 4 HTTP = baseline + 35 to 36).
- `zig build install:linux:system` 4/6 steps succeeded (the 5th
  step — copying `nalar` to `/usr/local/bin/nalar` — fails
  harmlessly with permission denied; the crucial step "compile exe
  nalar" must succeed).

- [ ] **Step 6.2.2: Frontend build clean**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: 0 errors. Build succeeds.

---

## Acceptance criteria

1. `config.json` may contain `max_capacity_token_model` and/or
   `compaction_threshold_percent`. When present, they override the
   built-in `LLMModels` defaults. When absent or `null`, the
   built-in defaults apply (200_000 / 500_000 / 200_000 fallback
   for capacity, 80% for threshold).
2. `GET /api/config/nalar` includes both fields in the response.
3. `PUT /api/config/nalar` accepts both fields, validates
   `compaction_threshold_percent` is in 0..100, and applies them.
4. `workflow.zig:maybeCompactMessagesNew` uses the config-driven
   values instead of the hardcoded 80% / `LLMModels` defaults.
5. `llm_history.zig:SessionMessageResponse.max_capacity_total_tokens`
   uses the override when set, falls back to `LLMModels` when not.
6. The TypeScript `NalarConfig` interface includes both fields.
7. Test count grows by 23 + 8 + 1 + 3 (or +4) = **35–36** across
   the four affected test files.
8. Both `zig build test` and `zig build install:linux:system`
   succeed. `bun run build` succeeds.

## Out of scope (deferred)

- Frontend UI controls for the new fields (input boxes in a new
  `CompactionSection.vue`). The wire format supports them; the
  follow-up plan wires the inputs.
- Per-profile overrides (`LlmProfile.max_capacity_token_model` and
  `LlmProfile.compaction_threshold_percent`). The current plan
  puts both fields at the top level only — matches the existing
  `model_compaction_size_kb` scope. Per-profile overrides can be
  added later with the same shape as the existing
  `LlmProfile.max_tokens` (nullable, defaults to top-level).
- Validation of `max_capacity_token_model` (e.g. max
  `10_000_000` to catch typos). The field is `?u32`, which caps at
  ~4.3 billion — practical for any real model. Add validation if
  the user reports a typo issue.
- Migration of historical compact-attempt counts to reflect the
  new threshold. The threshold is consulted at compact time
  only — no historical state to migrate.

## Risks and unknowns

- **Backward compatibility of existing config.json files.** Old
  files lack the two new fields → defaults to `null` →
  `LlmConfig.maxCapacityForModel` / `compactionThresholdPercent`
  fall back to the built-in values → behavior identical to today.
  **Verified safe.**
- **Lazy-analysis pitfall.** `zig build test` does not
  type-check `workflow.zig:maybeCompactMessagesNew` unless a
  test reaches it. The Chunk 3 integration test (Task 3.3) and
  the existing `workflow_compaction_envelope_test.zig` ensure
  the function gets type-checked at the test layer.
- **Frontend type-check.** `bun run build` (NOT just
  `bunx vitest run`) is the authoritative type-check per project
  memory. Don't skip it.
- **Test count growth.** The 17 previously-dead `LLMModels_test.zig`
  tests start running when the file is registered in the agent
  module's `test_runner.zig`. If any of those tests fail (e.g.
  hardcoded `MINIMAX_M2_7 = "MiniMax-M2.7"` mismatch with the
  actual `LLMModels.MINIMAX_2_7.name = "MiniMax-M2.7"`), fix them
  in the same PR. The tests use the imported constants so they
  should be stable.

---

## Status (as of 2026-07-07 02:17 UTC)

**Shipped on `worktree/config-compact` (9 commits, pushed to PR #81):**
1. `45fadc8e docs(plans): add plan for configurable compaction settings`
2. `12e436f8 feat(config): add max_capacity_token_model + compaction_threshold_percent fields` — top-level on `LlmConfig`
3. `8b6f9c20 feat(llm-models): add resolveMaxCapacity + shouldCompact wrappers`
4. `a5927f3c feat(http): expose max_capacity_token_model + compaction_threshold_percent in GET/PUT /api/config/nalar`
5. `78e3656e feat(frontend): add NalarConfig fields + CompactionSection component`
6. `aeb082cf feat(frontend): add Compaction tab wired into NalarSettings + new tests`
7. `2d68b0fa feat(workflow): wire compaction settings into production call sites`
8. `b0d4f45a fix(workflow+frontend): fix pre-existing {s} format bug; update NalarTabStrip test for 5th tab`

**Test baseline (last green before reshape attempt):** 990 pass, 3 skip (993 total), 0 errors. Wallclock ~2s.

**Architectural decision (2026-07-07):** The user chose **option 2** — move both compaction fields off the top-level `LlmConfig` (and the `NalarConfig` JSON shape) and put them on `LlmProfile` only. Reasoning:

> "because it is much easy to configure, and every profile will have
> a [compaction_setting] ..."

In option 2, sub-agents inherit the parent profile's setting unless they
override it. This makes the per-profile mental model uniform (every
profile knows its capacity + threshold; no profile-by-profile
inheritance dance for sub-agents). The HTTP API shape becomes:
- `GET/PUT /api/config/nalar` returns a `profiles` map keyed by profile
  name, where each entry contains `max_capacity_tokens` and
  `compaction_threshold_percent`.
- The top-level `max_capacity_token_model` and `compaction_threshold_percent`
  fields are REMOVED from `NalarConfigResponse`, `LlmConfig`, `LlmConfigJson`,
  and the frontend `NalarConfig` interface.

**Reshape status:** PARTIAL. A previous attempt modified `Config.zig`
(removed top-level fields, added per-profile fields on `LlmProfile` +
`SubAgentConfig`, updated `LlmConfigJson` + `ProfileJson` + `SubAgentJson`)
but did NOT update the downstream consumers. The partial state was
reverted to keep the build green. **Chunk 7 below** captures the full
reshape needed to land option 2.

**Why reverted vs. landed:** The downstream ripple is wide (8+ files:
workflow.zig, llm_history.zig, http_response.zig, nalar_config_get.zig,
nalar_config_put.zig, nalar_config_put_test.zig, config_test.zig,
compaction_config_threshold_test.zig, CompactionSection.spec.ts, +
the nalar_tab_strip / NalarSettings UI). Each consumer needs the
new per-profile resolver signature. A new chunk dedicated to the
reshape (Chunk 7) is faster than doing it as a "fix the partial
state" chore.

---

## Chunk 7: Reshape compaction settings to per-profile only (option 2)

**Goal:** Replace the top-level `max_capacity_token_model` +
`compaction_threshold_percent` on `LlmConfig` (and on the HTTP
`NalarConfigResponse`) with `max_capacity_tokens` +
`compaction_threshold_percent` on each `LlmProfile`. Sub-agents
inherit the parent profile's setting unless they override. The
old top-level fields are removed everywhere.

**Why this chunk is separate from Chunks 1–6:** The original
Chunks 1–6 built the top-level shape (option 1). Chunk 7 is the
option-2 reshape — same surface area, different layout. It's
large because the wire format, the resolver API, the test
fixtures, and the frontend all need to align.

**Estimated effort:** ~4–6 hours. Touches 8+ Zig files, 2 frontend
files, 2 test files. ~+8 new tests, ~15 modified tests, 0 regressions.

### File changes summary

| File | Change | Why |
|------|--------|-----|
| `src/modules/config/Config.zig` | Remove `LlmConfig.max_capacity_token_model` + `LlmConfig.compaction_threshold_percent`. Add `LlmProfile.max_capacity_tokens: ?u32` + `LlmProfile.compaction_threshold_percent: ?u8`. Add `SubAgentConfig.max_capacity_tokens` + `SubAgentConfig.compaction_threshold_percent` (same shape, default null = inherit). Update `LlmConfigJson`, `ProfileJson`, `SubAgentJson` mirrors. Update `init`, `clone`, `addProfile`, `parseSubAgentsJson`, `defaultConfigJson` (remove top-level keys). Rewrite `maxCapacityForModel` + `compactionThresholdPercent` to take `(profile: ?*const LlmProfile, sub_agent: ?*const SubAgentConfig, model_name: []const u8)` and resolve the cascade. | The core data model change. |
| `src/ai_workflow/tui/workflow.zig` | Update `maybeCompactMessagesNew` call site (around line 864) to pass `profile` and `sub_agent` (already in scope via `LlmConfigHolder` + per-call profile resolution) to `cfg.maxCapacityForModel` + `cfg.compactionThresholdPercent`. | Production consumer of the resolver. |
| `src/ai_workflow/tui/llm_history.zig` | Update `SessionMessageResponse.max_capacity_total_tokens` assembly to use the per-profile resolver. The caller already has the profile in scope (it's used for `max_tokens`). | Response builder for chat messages. |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | Remove `NalarConfigResponse.max_capacity_token_model` + `NalarConfigResponse.compaction_threshold_percent`. Add `NalarConfigResponse.profiles: ?std.json.Value = null` (the raw `profiles_models` map keyed by name, so the frontend can iterate). | Wire format. The frontend reads the profiles map directly. |
| `src/ai_workflow/tui/http_handlers/nalar_config_get.zig` | Remove the two top-level field copies. Set `profiles = self.profiles_models.serializeAsJsonValue(allocator)` (a small helper). | GET side. |
| `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` | Remove the two top-level `ConfigInput` fields and the apply block. Add an optional `profiles: ?std.json.Value` field to `ConfigInput` for partial profile updates (semantics: merge into existing profiles by name, preserving unspecified fields). | PUT side. Partial-update of profiles is the new ergonomic model. |
| `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig` | Update `makeConfig` literal (drop the 2 top-level fields). Update the 4 static-contract tests at lines 235/249/263/285 to check for the new shape (e.g., test that `ConfigInput` has a `profiles` field instead of the 2 top-level fields). | Test fixture + static tests. |
| `src/modules/config/config_test.zig` | Update 4 round-trip tests at lines 1246/1260/1273/1287 to assert per-profile values (set `profiles: { "default": { ..., "max_capacity_tokens": 128000 } }` instead of top-level). Update 2 resolver tests at lines 1300/1316/1332/1346 to pass a profile to the resolver and assert the cascade (sub-agent override beats profile beats built-in). | Round-trip + resolver tests. |
| `src/ai_workflow/tui/compaction_config_threshold_test.zig` | Rewrite the 4 tests to build an `LlmProfile` with the desired threshold and call `cfg.compactionThresholdPercent(profile, null, "model")`. Add a new test for sub-agent override behavior. | Resolver integration test. |
| `src/apps/desktop/src/types/NalarConfig.ts` (or equivalent) | Remove the 2 top-level fields from the `NalarConfig` interface. The `profiles: Record<string, LlmProfile>` already exists; add `max_capacity_tokens` and `compaction_threshold_percent` to the `LlmProfile` interface. | Frontend types. |
| `src/apps/desktop/src/components/NalarSettings/CompactionSection.vue` | Rewrite the component to iterate `props.profiles` (a `Record<string, LlmProfile>`) and render one input row per profile. Each row's v-model is `profiles[profileName].compaction_threshold_percent` and `profiles[profileName].max_capacity_tokens`. The PUT handler sends the whole profiles map (or only the changed rows — implementation choice). | UI. This is the bulk of the visible UX change. |
| `src/apps/desktop/src/__tests__/CompactionSection.spec.ts` | Rewrite the test fixtures (top-level `max_capacity_token_model` → per-profile `max_capacity_tokens`). Add a test that asserts a profile with no override falls back to 80%. Add a test that asserts a sub-agent override beats the parent profile. | Frontend tests. |

### Task 7.1: Reshape `Config.zig`

**Files:**
- Modify: `src/modules/config/Config.zig`

- [ ] **Step 7.1.1: Remove `max_capacity_token_model` and `compaction_threshold_percent` from `LlmConfig`**

The two fields were added in commit `12e436f8` (Chunk 1). Remove
their declarations from the outer `LlmConfig` struct (around line 28-37).
The `LlmConfig.maxCapacityForModel` and `LlmConfig.compactionThresholdPercent`
helpers will be rewritten in Step 7.1.4.

- [ ] **Step 7.1.2: Remove the same two fields from `LlmConfigJson`**

The two fields were added in commit `12e436f8` (Chunk 1). Remove
their declarations from the inner `LlmConfigJson` struct (around line 173-190).
Also remove the corresponding `.max_capacity_token_model = ...` and
`.compaction_threshold_percent = ...` lines from the `init` body (around line 351)
and from `clone` (around line 798).

- [ ] **Step 7.1.3: Remove the same two keys from `defaultConfigJson`**

The raw string `defaultConfigJson` (around line 1184) currently ends with
`\\  "max_capacity_token_model": null,\n\\  "compaction_threshold_percent": null\n\\}`.
Remove those two lines so the default config doesn't write top-level
keys (which would be silently ignored by the loader but are a UX wart).

- [ ] **Step 7.1.4: Add `max_capacity_tokens` + `compaction_threshold_percent` to `LlmProfile`**

In the `LlmProfile` struct (around line 60-77), after the
existing `sub_agents: SubAgentsList = &.{},` field, add:

```zig
/// Optional override for the context window (in tokens) used
/// by this profile. `null` = use `LLMModels.getModelTokenCount(model)`
/// built-in default. Set this when using a self-hosted model with
/// a non-standard context window, or to under-provision for cost.
max_capacity_tokens: ?u32 = null,
/// Compaction threshold as a percentage (0-100) of the model's
/// context window. `null` = use the built-in 80. Values > 100
/// are rejected by the HTTP layer with `error.InvalidThresholdPercent`.
compaction_threshold_percent: ?u8 = null,
```

- [ ] **Step 7.1.5: Add the same two fields to `SubAgentConfig`**

In the `SubAgentConfig` struct (around line 84-95), after the
existing `system_prompt: []const u8` field, add:

```zig
/// Optional override for the context window (in tokens) for
/// this sub-agent. `null` = inherit from the parent profile (or
/// the built-in default if no profile).
max_capacity_tokens: ?u32 = null,
/// Compaction threshold percentage (0-100) for this sub-agent.
/// `null` = inherit from the parent profile (or 80 if no profile).
compaction_threshold_percent: ?u8 = null,
```

- [ ] **Step 7.1.6: Update `ProfileJson` + `SubAgentJson` JSON parse structs**

In `ProfileJson` (around line 178-185), after the `sub_agents` field, add:

```zig
/// Optional per-profile override for the context window (in tokens).
/// Null = use LLMModels built-in per-model default.
max_capacity_tokens: ?u32 = null,
/// Optional per-profile override for the compaction threshold
/// percentage (0-100). Null = use built-in 80. Range-validated
/// at the HTTP layer.
compaction_threshold_percent: ?u8 = null,
```

In `SubAgentJson` (around line 217-225), after the `system_prompt` field, add:

```zig
/// Optional per-sub-agent override for the context window (in tokens).
max_capacity_tokens: ?u32 = null,
/// Optional per-sub-agent override for the compaction threshold
/// percentage (0-100).
compaction_threshold_percent: ?u8 = null,
```

- [ ] **Step 7.1.7: Update `addProfile` to capture the new fields**

In `addProfile` (around line 463-485), the `.sub_agents = profile_sub_agents,`
line is followed by the `});`. Insert before `});`:

```zig
// Per-profile compaction overrides — optional, parsed from JSON.
.max_capacity_tokens = profile.max_capacity_tokens,
.compaction_threshold_percent = profile.compaction_threshold_percent,
```

- [ ] **Step 7.1.8: Update `parseSubAgentsJson` to capture the new fields**

In `parseSubAgentsJson` (around line 537-560), the `.system_prompt = system_prompt,`
line is followed by the `});`. Insert before `});`:

```zig
// Per-sub-agent compaction overrides — optional, parsed from JSON.
.max_capacity_tokens = j.max_capacity_tokens,
.compaction_threshold_percent = j.compaction_threshold_percent,
```

- [ ] **Step 7.1.9: Rewrite `maxCapacityForModel` and `compactionThresholdPercent`**

Replace the existing helpers (around lines 1159-1175) with cascade
versions:

```zig
/// Resolve the effective max-context-window in tokens for a given
/// model under the optional profile + sub-agent scope. Cascade order:
///   1. sub_agent.max_capacity_tokens (if sub_agent is non-null and field is set)
///   2. profile.max_capacity_tokens (if profile is non-null and field is set)
///   3. LLMModels.getModelTokenCount(model_name) (built-in default)
///
/// Use this everywhere a "what's the effective context window for
/// THIS chat?" answer is needed.
pub fn maxCapacityForModel(
    self: *const LlmConfig,
    profile: ?*const LlmProfile,
    sub_agent: ?*const SubAgentConfig,
    model_name: []const u8,
) u32 {
    if (sub_agent) |sa| if (sa.max_capacity_tokens) |override| return override;
    if (profile) |p| if (p.max_capacity_tokens) |override| return override;
    return LLMModels.getModelTokenCount(model_name);
}

/// Resolve the compaction threshold as a percentage (0-100). Cascade
/// order (same shape as maxCapacityForModel):
///   1. sub_agent.compaction_threshold_percent (if non-null and set)
///   2. profile.compaction_threshold_percent (if non-null and set)
///   3. 80 (the historical hardcoded value in `LLMModels.isDoCompact`)
pub fn compactionThresholdPercent(
    self: *const LlmConfig,
    profile: ?*const LlmProfile,
    sub_agent: ?*const SubAgentConfig,
) u8 {
    if (sub_agent) |sa| if (sa.compaction_threshold_percent) |override| return override;
    if (profile) |p| if (p.compaction_threshold_percent) |override| return override;
    return 80;
}
```

Both methods take `self` for API consistency but don't use it for
the resolution (cascading doesn't need the top-level config — the
profile + sub-agent + built-in default is the full chain). The
`self` parameter is kept so callers don't need a separate helper
import.

- [ ] **Step 7.1.10: Build verification**

Run:
```bash
cd .worktrees/config-compact && timeout 180 zig build test --summary all 2>&1 | tail -n 20
```

Expected: ~8 compile errors in `Config.zig` callers
(`workflow.zig:864`, `compaction_config_threshold_test.zig`,
`nalar_config_put_test.zig:38`, `config_test.zig:1257/1270/1284/1297`).
These are fixed in Tasks 7.2–7.5. The test runner does NOT pass
cleanly after Step 7.1.10 alone — proceed to Task 7.2.

### Task 7.2: Update `workflow.zig` call site

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig` (around line 864 — the `LLMModels.shouldCompact` call)

- [ ] **Step 7.2.1: Read the current `shouldCompact` call site**

Verify the surrounding context: the function should already have
`llm_config_holder` in scope (for accessing the active `LlmConfig`)
and should have access to the active profile (via the chat's
`profile_name` field).

- [ ] **Step 7.2.2: Resolve profile + sub-agent before calling the new resolver**

Before the `shouldCompact` call, add:

```zig
const profile: ?*const LlmConfig.LlmProfile = blk: {
    const cfg = llm_config_holder.current() orelse break :blk null;
    if (cfg.profiles_models.getPtr(profile_name)) |p| break :blk p;
    break :blk null;
};
const sub_agent: ?*const LlmConfig.SubAgentConfig = blk: {
    const cfg = llm_config_holder.current() orelse break :blk null;
    if (sub_agent_name) |san| {
        if (cfg.sub_agents_map.getPtr(san)) |sa| break :blk sa;
    }
    break :blk null;
};
const max_capacity = cfg.maxCapacityForModel(profile, sub_agent, model_name);
const threshold = cfg.compactionThresholdPercent(profile, sub_agent);

if (!force and !agent.LLMModels.shouldCompact(total_tokens, max_capacity, threshold)) {
    return null;
}
```

If `sub_agents_map` doesn't exist on `LlmConfig`, find the existing
sub-agent lookup helper and use it (or `getSubAgent` if there's one
already).

- [ ] **Step 7.2.3: Build verification**

```bash
cd .worktrees/config-compact && timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expected: the workflow.zig errors go away. Other downstream
errors remain (resolved in Tasks 7.3–7.5).

### Task 7.3: Update `http_response.zig` + `nalar_config_get.zig`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig` (line 281-286)
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_get.zig` (line 114-115 + line 146-148)

- [ ] **Step 7.3.1: Remove the two top-level fields from `NalarConfigResponse`**

In `http_response.zig`, remove:

```zig
max_capacity_token_model: ?u32 = null,
compaction_threshold_percent: ?u8 = null,
```

Replace with a single `profiles` field:

```zig
/// Raw profiles map (parsed from `LlmConfig.profiles_models`). Keyed
/// by profile name. Each entry contains the full `LlmProfile` shape
/// (model, base_url, api_key, ..., max_capacity_tokens,
/// compaction_threshold_percent, sub_agents). The frontend reads this
/// map directly to render the per-profile compaction UI.
profiles: ?std.json.Value = null,
```

- [ ] **Step 7.3.2: Populate `profiles` in the GET handler**

In `nalar_config_get.zig`, remove the two top-level field copies
(`.max_capacity_token_model = ...`, `.compaction_threshold_percent = ...`).
Replace with:

```zig
.profiles = self.profiles_models.serializeAsJsonValue(allocator),
```

If `serializeAsJsonValue` doesn't exist on `ProfilesMap`, add it:

```zig
pub fn serializeAsJsonValue(
    self: ProfilesMap,
    allocator: std.mem.Allocator,
) std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    var it = self.iterator();
    while (it.next()) |entry| {
        const profile_json = std.json.Value{
            .object_string = std.json.ObjectMap.init(allocator),
        };
        // For each LlmProfile field, write a key-value pair.
        // (Manual construction; can also use std.json.Stringify.valueAlloc.)
        ...
        obj.put(entry.key_ptr.*, profile_json) catch continue;
    }
    return std.json.Value{ .object = obj };
}
```

**Pragmatic shortcut:** If the manual construction is error-prone,
use `std.json.Stringify.valueAlloc(allocator, self, .{})` on a
dedicated `ProfilesMapSnapshot` struct (a temporary `{[*:0][]const u8: LlmProfile}`-
shaped copy) instead. The snapshot is freed in the same scope.

- [ ] **Step 7.3.3: Build verification**

```bash
cd .worktrees/config-compact && timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expected: GET handler compiles. PUT handler still has the old top-level
field apply blocks (Task 7.4).

### Task 7.4: Update `nalar_config_put.zig` for the new wire format

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` (lines 107-112, 300-305, 346-350)

- [ ] **Step 7.4.1: Remove the two top-level apply blocks**

Remove:

```zig
if (input.max_capacity_token_model) |mc| {
    config_json.max_capacity_token_model = mc;
}
if (input.compaction_threshold_percent) |tp| {
    if (tp > 100) return error.InvalidThresholdPercent;
    config_json.compaction_threshold_percent = tp;
}
```

- [ ] **Step 7.4.2: Remove the two top-level fields from `ConfigInput`**

In `ConfigInput` (around line 300), remove `max_capacity_token_model`
and `compaction_threshold_percent`.

- [ ] **Step 7.4.3: Add a `profiles` field to `ConfigInput`**

After `notify_on_complete` (around line 300), add:

```zig
/// Optional profiles update. If non-null, MERGE into the existing
/// `LlmConfig.profiles_models` by profile name. Each entry replaces
/// only the fields present in the JSON; fields absent from the JSON
/// preserve their existing values. To DELETE a profile, send `null`
/// as the entry's value (e.g. `{"profiles": {"old_profile": null}}`).
profiles: ?std.json.Value = null,
```

- [ ] **Step 7.4.4: Implement the merge logic**

Add a helper (or inline at the top of the handler):

```zig
fn applyProfilesUpdate(
    cfg_json: *LlmConfigJson,
    profiles: std.json.Value,
    allocator: std.mem.Allocator,
) !void {
    if (profiles != .object) return error.InvalidProfilesFormat;
    var it = profiles.object.iterator();
    while (it.next()) |entry| {
        const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key_dup);
        if (entry.value_ptr.* == .null) {
            // Delete the profile.
            try cfg_json.profiles.remove(key_dup);
            continue;
        }
        if (entry.value_ptr.* != .object) return error.InvalidProfileEntry;
        const profile_json = entry.value_ptr.object;
        // Validate threshold percent range if present.
        if (profile_json.get("compaction_threshold_percent")) |tp| {
            if (tp != .integer) return error.InvalidThresholdPercentType;
            if (tp.integer < 0 or tp.integer > 100) {
                return error.InvalidThresholdPercent;
            }
        }
        // Insert or replace.
        try cfg_json.profiles.put(key_dup, profile_json);
    }
}
```

If `cfg_json.profiles` is a different type (e.g. `?std.json.Value`),
adapt accordingly. The validation only needs to catch the threshold
range — other profile fields are accepted as-is (LlmConfigJson's
existing parse logic will reject malformed types).

- [ ] **Step 7.4.5: Wire the merge into the handler**

After the existing apply block (around line 113), add:

```zig
if (input.profiles) |profiles| {
    try applyProfilesUpdate(config_json, profiles, allocator);
}
```

- [ ] **Step 7.4.6: Build verification**

```bash
cd .worktrees/config-compact && timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expected: PUT handler compiles. Test fixtures and frontend still
need updates (Tasks 7.5–7.7).

### Task 7.5: Update tests

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig` (lines 38-39)
- Modify: `src/modules/config/config_test.zig` (lines 1246-1356)
- Modify: `src/ai_workflow/tui/compaction_config_threshold_test.zig` (rewrite)

- [ ] **Step 7.5.1: Update `nalar_config_put_test.zig` `makeConfig` literal**

In `makeConfig` (line 30-44), remove:
```zig
.max_capacity_token_model = null,
.compaction_threshold_percent = null,
```

- [ ] **Step 7.5.2: Rewrite the 4 static-contract tests in `nalar_config_put_test.zig`**

The existing tests at lines 235/249/263/285 check that the old
top-level apply block is present. Replace them with:

1. **`PUT handler accepts `profiles` field in ConfigInput`** — check
   that the source contains `profiles: ?std.json.Value = null,` and
   `applyProfilesUpdate`.
2. **`PUT handler validates compaction_threshold_percent > 100`** —
   check that the source contains `error.InvalidThresholdPercent` AND
   a range check `< 0 or > 100` somewhere in `applyProfilesUpdate`.
3. **`PUT handler does NOT write top-level max_capacity_token_model`** —
   grep for absence of `config_json.max_capacity_token_model =` and
   `input.max_capacity_token_model`.
4. **`PUT handler merges profiles by name`** — check that the source
   contains `cfg_json.profiles.put(key_dup, profile_json)` or
   equivalent merge logic.

- [ ] **Step 7.5.3: Update the 4 round-trip tests in `config_test.zig`**

At lines 1246/1260/1273/1287, the tests set the 2 top-level fields
in JSON and read them back. Replace with per-profile tests:

```zig
test "LlmConfig: profile.max_capacity_tokens reads value from JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles": { "default": { "model": "m", "max_capacity_tokens": 128000 } } }
    ;
    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    const profile = cfg.profiles_models.get("default").?;
    try std.testing.expectEqual(@as(?u32, 128000), profile.max_capacity_tokens);
}
```

Apply the same shape to `compaction_threshold_percent`. Mirror the
null-default tests too.

- [ ] **Step 7.5.4: Rewrite the 2 resolver tests in `config_test.zig`**

The tests at lines 1300/1316/1332/1346 call the OLD single-arg
resolvers. Replace with:

```zig
test "LlmConfig: maxCapacityForModel cascade (sub-agent > profile > built-in)" {
    // Build a config with one profile ("dev") that has
    // max_capacity_tokens = 100_000, and one sub-agent ("alpha")
    // that has max_capacity_tokens = 50_000.
    ...
    // sub-agent > profile
    try std.testing.expectEqual(@as(u32, 50_000),
        cfg.maxCapacityForModel(&profile, &sub_agent, "MiniMax-M3"));
    // profile > built-in (no sub-agent)
    try std.testing.expectEqual(@as(u32, 100_000),
        cfg.maxCapacityForModel(&profile, null, "MiniMax-M3"));
    // built-in default (no profile, no sub-agent)
    try std.testing.expectEqual(@as(u32, 500_000),
        cfg.maxCapacityForModel(null, null, "MiniMax-M3"));
}
```

Mirror for `compactionThresholdPercent` (with 80 as the default).

- [ ] **Step 7.5.5: Rewrite `compaction_config_threshold_test.zig`**

The 4 existing tests use `cfg.compactionThresholdPercent()` (no args).
Rewrite to use the cascade. Add a new test for sub-agent override.

### Task 7.6: Frontend types + UI

**Files:**
- Modify: `src/apps/desktop/src/types/NalarConfig.ts` (or equivalent)
- Modify: `src/apps/desktop/src/components/NalarSettings/CompactionSection.vue`
- Modify: `src/apps/desktop/src/components/NalarSettings/NalarSettings.vue` (if the parent passes the props differently)
- Modify: `src/apps/desktop/src/__tests__/CompactionSection.spec.ts`

- [ ] **Step 7.6.1: Update `NalarConfig` and `LlmProfile` TypeScript interfaces**

In the `NalarConfig` interface, remove:
```ts
max_capacity_token_model: number | null;
compaction_threshold_percent: number | null;
```

Add to the `LlmProfile` interface:
```ts
max_capacity_tokens: number | null;
compaction_threshold_percent: number | null;
```

- [ ] **Step 7.6.2: Rewrite `CompactionSection.vue`**

Replace the current single-input UI with a per-profile iteration:

```vue
<template>
  <div class="compaction-section">
    <h3>Compaction settings</h3>
    <div v-for="(profile, name) in profiles" :key="name" class="profile-row">
      <h4>{{ name }} ({{ profile.model || 'no model' }})</h4>
      <label>
        Max context window (tokens):
        <input
          type="number"
          :value="profile.max_capacity_tokens ?? ''"
          @input="updateMaxCapacity(name, $event)"
          placeholder="(built-in default)"
        />
      </label>
      <label>
        Compaction threshold (%):
        <input
          type="number"
          min="0"
          max="100"
          :value="profile.compaction_threshold_percent ?? ''"
          @input="updateThreshold(name, $event)"
          placeholder="80"
        />
      </label>
    </div>
    <button @click="save" :disabled="!dirty">Save</button>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue';
import type { LlmProfile } from '@/types/NalarConfig';

const props = defineProps<{
  profiles: Record<string, LlmProfile>;
}>();
const emit = defineEmits<{ save: [profiles: Record<string, LlmProfile>] }>();

const local = ref<Record<string, LlmProfile>>(
  JSON.parse(JSON.stringify(props.profiles)),
);
const dirty = computed(() => JSON.stringify(local.value) !== JSON.stringify(props.profiles));

function updateMaxCapacity(name: string, e: Event) {
  const v = (e.target as HTMLInputElement).value;
  local.value[name].max_capacity_tokens = v === '' ? null : parseInt(v, 10);
}
// (similar for updateThreshold)

function save() { emit('save', local.value); }
</script>
```

The parent's `save` handler issues a PUT to `/api/config/nalar` with
`{ profiles: local }`. The PUT handler applies the merge (Task 7.4).

- [ ] **Step 7.6.3: Update `CompactionSection.spec.ts`**

Rewrite the existing 6 fixtures to use per-profile `modelValue`:
```ts
props: { profiles: { dev: { model: 'm', max_capacity_tokens: 256000, ... } } }
```

Add a new test:
- **`CompactionSection shows "built-in default" placeholder when profile.max_capacity_tokens is null`**
- **`CompactionSection shows "80" placeholder when profile.compaction_threshold_percent is null`**
- **`CompactionSection emits save event with the merged profiles map`**

### Task 7.7: End-to-end verification

- [ ] **Step 7.7.1: Run Zig tests**

```bash
cd .worktrees/config-compact && timeout 240 zig build test --summary all 2>&1 | tail -n 5
```

Expected: 998 pass (990 baseline + ~8 new tests), 3 skip, 0 errors.
Wallclock ~2s.

- [ ] **Step 7.7.2: Run frontend build**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10
```

Expected: 0 type errors. The Vue webapp builds cleanly.

- [ ] **Step 7.7.3: Manual smoke test**

```bash
env -i HOME=/tmp/nalar-reshape-test PATH=$PATH \
  .worktrees/config-compact/zig-out/bin/nalar --port 18080 &
sleep 3

# Create a config with 2 profiles
curl -X POST http://127.0.0.1:18080/api/config/nalar \
  -H "Content-Type: application/json" \
  -d '{
    "api_key": "test", "model": "m", "base_url": "b",
    "profiles": {
      "dev":  {"model": "m", "max_capacity_tokens": 100000, "compaction_threshold_percent": 50},
      "prod": {"model": "m", "max_capacity_tokens": 500000, "compaction_threshold_percent": 90}
    }
  }'

# GET it back, confirm the per-profile shape
curl http://127.0.0.1:18080/api/config/nalar | jq '.profiles'

# Send a chat, confirm the resolver uses the right profile
# (Profile selection logic is upstream of this chunk — see
# workflow.zig:maybeCompactMessagesNew for the active profile
# resolution.)

kill $!
```

- [ ] **Step 7.7.4: Commit + PR**

```bash
cd .worktrees/config-compact
git add -A
git commit -m "feat(config): reshape compaction settings to per-profile only

Move max_capacity_tokens and compaction_threshold_percent from the
top-level LlmConfig to LlmProfile (with sub-agent inheritance
cascade). Update HTTP wire format, resolver API, frontend types,
and UI. See docs/superpowers/plans/2026-07-06-configurable-compaction.md
Chunk 7 for the full task breakdown.

Resolves the option-2 architectural decision (per-profile is easier
to configure than per-config + per-profile mapping).
"
git push origin worktree/config-compact
```

### Acceptance criteria for Chunk 7

1. Top-level `LlmConfig.max_capacity_token_model` and
   `LlmConfig.compaction_threshold_percent` are REMOVED (no longer
   exist on the struct or its JSON mirror).
2. `LlmProfile.max_capacity_tokens` and
   `LlmProfile.compaction_threshold_percent` exist with default `null`.
3. `SubAgentConfig.max_capacity_tokens` and
   `SubAgentConfig.compaction_threshold_percent` exist with default
   `null` (inheriting from parent profile).
4. The resolver cascade is: sub-agent override → profile override →
   built-in default. Verified by tests in `config_test.zig` and
   `compaction_config_threshold_test.zig`.
5. The HTTP wire format removes the top-level fields and adds a
   `profiles` map keyed by profile name. Verified by
   `nalar_config_get.zig` + `nalar_config_put.zig` static-contract
   tests.
6. The frontend `NalarConfig` interface has no top-level fields;
   `LlmProfile` has the two new fields. Verified by `bun run build`.
7. The `CompactionSection` UI renders one row per profile, each
   with its own threshold + max_capacity inputs. Verified by the
   3 new spec tests.
8. Test count grows by 8 new tests (vs. the 23 added in Chunks 1–6).
9. All 990 baseline tests still pass; 0 regressions.
10. `zig build install:linux:system` succeeds (4/6 steps; the cp
    to /usr/local/bin/nalar fails harmlessly with permission denied).

### Risks for Chunk 7

- **HTTP wire format change is breaking.** Old clients that PUT
  `max_capacity_token_model` at the top level will get a silent
  no-op (the field is not parsed). Add a one-line log warning when
  `input.max_capacity_token_model` or `input.compaction_threshold_percent`
  is present in the PUT body. (Optional — the field is gone from
  the type so most clients won't even compile against it.)
- **Cascade semantics in sub-agents.** A sub-agent inherits from
  the parent profile, but the parent profile lookup uses the
  chat's `profile_name`, not the sub-agent's `profile_name` field
  (most sub-agents don't have one). Verify the call site in
  `workflow.zig` looks up the parent profile correctly.
- **Frontend UX change.** Users who had set the top-level fields
  via `curl` will lose them on the next config save. Document in
  the migration notes (add to the PR description).