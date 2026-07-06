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