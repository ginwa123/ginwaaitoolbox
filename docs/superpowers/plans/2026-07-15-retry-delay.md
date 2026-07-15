# Configurable Retry Delay for Workflow Retries Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a configurable delay (in milliseconds, 0–60 000) that the workflow's agentic-loop retry path sleeps for before the next `callDynamicAgentNew` attempt. Default is `0` (current behavior). Expose through `GET/PUT /api/config/nalar` and the desktop Defaults tab so users can rate-limit hammering the LLM when the upstream is flaky.

**Architecture:** Extend `LlmConfig` with a top-level `retry_delay_ms: u32` field (NOT per-profile — the delay is a workflow concern, not an LLM-specific setting, matching the `notify_on_complete` precedent at `src/ai_workflow/tui/workflow.zig:566`). Add a small cancellation-aware helper `retryDelayMs(...)` to `workflow.zig` that blocks for at most `delay_ms` milliseconds in `nanosleep` chunks, checking `agentic_loop_mod.isWorkerCancelled` each iteration so a user-initiated cancel exits the sleep early. The helper uses raw libc `nanosleep` — NOT `std.Io.sleep` — because the workflow is dispatched as an `Io.Group.concurrent` task from the event bus (see `src/modules/agent/tools/bash.zig:4-17` for the exact deadlock pattern). Apply the delay at BOTH retry sites in the workflow loop (the `callDynamicAgentNew` catch at line 518 and the `else` finish_reason branch at line 588). Frontend gets a new `── Workflow behavior ──` section in `DefaultsSection.vue` with a single number input (0–60 000 ms). All changes gated by TDD: write failing test → implement → green → commit.

**Tech Stack:** Zig 0.16, `std.json.parseFromSliceLeaky` (HTTP handlers), `std.json.Stringify.valueAlloc` (HTTP response), raw libc `nanosleep` (Zig 0.16 `std.Io.sleep` deadlocks the Io.Group), `agentic_loop_mod.isWorkerCancelled` (worker cancellation check), `LlmConfig` accessor pattern matching `model_compaction_size_kb` (`src/ai_workflow/tui/http_handlers/nalar_config_get.zig:113` and `nalar_config_put.zig:142-144`), TypeScript / Vue (Defaults tab UI).

---

## Open Design Decisions (reviewer-flag these before Task 1)

These are the four non-obvious choices baked into the plan. **Reviewer can change any of them by editing the plan before Task 1 starts.** They are listed first so a reviewer doesn't have to read the whole plan to find them.

| # | Decision | Choice | Rationale | Alternative if rejected |
|---|----------|--------|-----------|-------------------------|
| 1 | Fixed delay vs exponential backoff | **Fixed delay** (`retry_delay_ms` value is used as-is) | Matches "simplest first rule" and the user's phrasing ("a delay"). Exponential backoff is a v2 ask if needed. | Replace `retryDelayMs` body with `delay = base * 2^attempt` clamped to `max_delay_ms`. Add `retry_max_delay_ms` field. |
| 2 | Top-level vs per-profile config | **Top-level** (`LlmConfig.retry_delay_ms`) | Workflow behavior, not LLM-specific. Matches `notify_on_complete` precedent (`workflow.zig:566`). All profiles benefit equally. | Move to `LlmProfile.retry_delay_ms` and cascade via `resolveRetryDelayMs(profile_name, sub_agent)` (mirrors `resolveCompactionSettings`). |
| 3 | Cancellation safety | **Required** — `retryDelayMs` checks `isWorkerCancelled` every chunk and returns early if true | A user who clicks Cancel must not have to wait the full delay. Bash.zig precedent (`src/modules/agent/tools/bash.zig:442-478`). | No early-return on cancel. User waits up to `delay_ms` even after cancel — bad UX. |
| 4 | Jitter | **No jitter** for v1 | Simpler. With a fixed delay, simultaneous retries from multiple sessions can still thunder against the upstream, but the use case (a flaky single upstream) doesn't warrant v1 complexity. | Add `±10%` jitter in `retryDelayMs` body: `actual = delay_ms + (rand() % (delay_ms / 5)) - (delay_ms / 10)`. |
| 5 | Default value | **0** (preserves current behavior) | No surprise delay for existing users. Opt-in feature. | Default 5000 — risk of breaking current behavior on first save. |
| 6 | Range upper bound | **60 000 ms** (60 s) | Beyond 60 s, the user should just cancel and start a new session. Upper bound prevents lockout. | 5 000 ms (too short for some upstream rate-limit windows); 600 000 ms (10 min, too easy to lock yourself out). |

---

## File Structure

| File | Responsibility | New / Modified |
|------|----------------|----------------|
| `src/modules/config/Config.zig` | Add `retry_delay_ms: u32 = 0` to both `LlmConfig` and `LlmConfigJson`. Materialize in `init`. Add to `defaultConfigJson`. | Modified |
| `src/modules/config/config_test.zig` | New tests: `retry_delay_ms: defaults to 0 when missing from JSON`, `retry_delay_ms: reads from JSON when present`, `defaultConfigJson includes retry_delay_ms: 0`. | Modified |
| `src/ai_workflow/tui/workflow.zig` | Add `retryDelayMs` helper (cancellation-aware nanosleep). Call it before both `continue` statements in the retry paths (line 518-525 and line 588). | Modified |
| `src/ai_workflow/tui/workflow_retry_delay_test.zig` | Static + behavioral tests for the retry-delay logic. | **New** |
| `src/ai_workflow/tui/test_runner.zig` | Add `_ = @import("workflow_retry_delay_test.zig");`. | Modified |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | Add `retry_delay_ms: u32 = 0` to `NalarConfigResponse`. | Modified |
| `src/ai_workflow/tui/http_handlers/nalar_config_get.zig` | Read `retry_delay_ms` from `cfg` into the response. Add to the inner `ConfigJson` struct. | Modified |
| `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` | Add `retry_delay_ms` to `ConfigInput` and `ConfigJson`. Apply via `if (input.retry_delay_ms) |v| ...` block. Clamp to [0, 60_000]. | Modified |
| `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig` | `makeConfig`: set `retry_delay_ms = 0`. Add test for clamping + persistence. | Modified |
| `src/apps/desktop/src/api/index.ts` | Add `retry_delay_ms?: number` to `NalarConfig` TypeScript interface. | Modified |
| `src/apps/desktop/src/components/nalar/DefaultsSection.vue` | Add `retry_delay_ms` to `DefaultsConfig`. Add new "── Workflow behavior ──" section with number input (0–60 000). | Modified |
| `src/apps/desktop/src/components/NalarSettings.vue` | Wire `retry_delay_ms` through `syncFromConfig` / `syncToConfig` / `emptyDefaults`. | Modified |
| `src/apps/desktop/src/__tests__/DefaultsSection.spec.ts` | Add `baseConfig.retry_delay_ms = 0`. Add test: "renders the retry-delay input with the current value". | Modified |

**Why this decomposition:**
- The new config field follows the exact `model_compaction_size_kb` + `notify_on_complete` pattern — no new HTTP infrastructure needed, just two new fields in three existing structs (`LlmConfig`, `NalarConfigResponse`, `NalarConfig`).
- The `retryDelayMs` helper is local to `workflow.zig` because (a) it's a workflow concern, (b) the cancellation check is `agentic_loop_mod` specific, (c) no other code needs a "sleep with cancellation check" primitive today. Extracting to a shared helper is YAGNI.
- New test file (`workflow_retry_delay_test.zig`) is needed because the existing `workflow_compaction_envelope_test.zig` covers a different concern (compaction envelope, not retry delay). The two would only share the same `setupDb` helper — easier to start fresh.
- Frontend changes are mirror-of-backend: one new field in `NalarConfig`, one new section in `DefaultsSection`. No new modal, no new tab.
- Static regression tests pin the cancellation behavior and the raw-`nanosleep` invariant at the source level (matching the project's `http_handlers/*_test.zig` pattern) — behavioral tests that actually spin up a workflow and kill the LLM mid-stream are too slow for CI.

---

## Chunk 1: Backend config plumbing

### Task 1.1: Add `retry_delay_ms` to `LlmConfig` and `LlmConfigJson`

**Files:**
- Modify: `src/modules/config/Config.zig` (3 spots: `LlmConfig` struct ~line 6-37, `LlmConfigJson` struct inside, `LlmConfig.init` materializer ~line 303-315)
- Modify: `src/modules/config/config_test.zig` (3 new tests)

- [ ] **Step 1.1.1: Write the failing tests**

In `src/modules/config/config_test.zig`, after the existing `model_compaction_size_kb` tests (around line 320), add three tests:

```zig
// retry_delay_ms: workflow retry backoff in milliseconds. 0 = no
// delay (current behavior). Defaults to 0 when missing so existing
// config files load without surprises.
test "retry_delay_ms: defaults to 0 when missing from JSON" {
    const json_src =
        \\{
        \\  "api_key": "sk-test",
        \\  "model": "MiniMax-M3",
        \\  "base_url": "https://api.test/v1"
        \\}
    ;
    const cfg = try LlmConfig.init(alloc, json_src);
    defer cfg.deinit();
    try testing.expectEqual(@as(u32, 0), cfg.retry_delay_ms);
}

test "retry_delay_ms: reads from JSON when present" {
    const json_src =
        \\{
        \\  "api_key": "sk-test",
        \\  "model": "MiniMax-M3",
        \\  "base_url": "https://api.test/v1",
        \\  "retry_delay_ms": 5000
        \\}
    ;
    const cfg = try LlmConfig.init(alloc, json_src);
    defer cfg.deinit();
    try testing.expectEqual(@as(u32, 5000), cfg.retry_delay_ms);
}

test "defaultConfigJson includes retry_delay_ms: 0" {
    // This test guards against future edits to defaultConfigJson that
    // might forget to seed the new field. Pin the literal string.
    const default_json = ...;  // see existing model_compaction_size_kb test for pattern
    if (std.mem.indexOf(u8, default_json, "\"retry_delay_ms\": 0") == null) {
        std.debug.print("!! defaultConfigJson missing retry_delay_ms: 0 !!\n", .{});
        return error.RetryDelayMissingFromDefault;
    }
}
```

(The third test uses the same pattern as the existing
`defaultConfigJson` string-grep tests in `config_test.zig` — read the
file's source for `writeDefaultConfig` and grep for the literal.)

- [ ] **Step 1.1.2: Run tests to verify they fail**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg "retry_delay_ms" | head -n 10
```

Expected: the 3 tests fail with "no member named 'retry_delay_ms' in
struct 'LlmConfig'" / "no member named 'retry_delay_ms' in struct
'LlmConfigJson'".

- [ ] **Step 1.1.3: Add `retry_delay_ms` to `LlmConfig`**

In `src/modules/config/Config.zig`, in the `LlmConfig` struct (around
line 6-37), after the existing `notify_on_complete: bool = true`
field, add:

```zig
/// Delay in milliseconds that the workflow sleeps before retrying a
/// failed `callDynamicAgentNew` call. 0 = no delay (current behavior,
/// the retry fires immediately on the next loop iteration). Upper
/// bound is 60_000 ms (1 min) — beyond that, the user should cancel
/// and start a new session. Range-validated at the HTTP layer.
retry_delay_ms: u32 = 0,
```

- [ ] **Step 1.1.4: Add `retry_delay_ms` to `LlmConfigJson`**

In the inner `LlmConfigJson` struct (around line 153-170), after the
existing `model_compaction_size_kb: usize = 100` field, add:

```zig
/// Delay in milliseconds before retrying a failed workflow call.
/// See `LlmConfig.retry_delay_ms` for semantics.
retry_delay_ms: u32 = 0,
```

- [ ] **Step 1.1.5: Materialize `retry_delay_ms` in `init`**

In `LlmConfig.init` (around line 303-315), after the existing
`.model_compaction_size_kb = config_json.model_compaction_size_kb,`
line, add:

```zig
.retry_delay_ms = config_json.retry_delay_ms,
```

- [ ] **Step 1.1.6: Add `retry_delay_ms: 0` to `defaultConfigJson`**

Find `defaultConfigJson` in `Config.zig` (around line 1257 in the
existing compaction plan — the field lives next to
`"model_compaction_size_kb": 100`). After that line, add:

```zig
\\  "retry_delay_ms": 0,
```

(The leading `\\` + double-quotes is Zig's raw-multi-line-string
literal — match the surrounding style.)

- [ ] **Step 1.1.7: Run tests to verify they pass**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `test success`, the 3 new tests pass, total count +3 vs
baseline.

- [ ] **Step 1.1.8: Commit**

```bash
git add src/modules/config/Config.zig src/modules/config/config_test.zig
git commit -m "feat(config): add retry_delay_ms to LlmConfig (default 0 = no delay)"
```

---

### Task 1.2: Add `retry_delay_ms` to the HTTP GET response

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig` (add field to `NalarConfigResponse` around line 260-285)
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_get.zig` (read from cfg, add to inner `ConfigJson`)

- [ ] **Step 1.2.1: Write the failing test**

In `src/ai_workflow/tui/http_handlers/nalar_config_get_test.zig` (or
extend an existing GET test file), add a static regression test:

```zig
// Pin the retry_delay_ms field on both the GET response struct and
// the ConfigJson parser. If a future refactor removes the field, this
// test catches it before it ships.
test "GET /api/config/nalar response includes retry_delay_ms" {
    const response_src = try readSource(testing.allocator,
        "src/ai_workflow/tui/http_handlers/http_response.zig");
    defer testing.allocator.free(response_src);
    if (std.mem.indexOf(u8, response_src, "retry_delay_ms: u32 = 0") == null) {
        std.debug.print("!! NalarConfigResponse missing retry_delay_ms !!\n", .{});
        return error.RetryDelayMissingFromResponse;
    }

    const get_src = try readSource(testing.allocator,
        "src/ai_workflow/tui/http_handlers/nalar_config_get.zig");
    defer testing.allocator.free(get_src);
    if (std.mem.indexOf(u8, get_src, ".retry_delay_ms = cfg.retry_delay_ms") == null) {
        std.debug.print("!! nalar_config_get.zig does not pipe retry_delay_ms into the response !!\n", .{});
        return error.RetryDelayNotWiredIntoGet;
    }
    if (std.mem.indexOf(u8, get_src, "retry_delay_ms: u32 = 0") == null) {
        std.debug.print("!! nalar_config_get.zig ConfigJson missing retry_delay_ms field !!\n", .{});
        return error.RetryDelayMissingFromConfigJson;
    }
}
```

(If `nalar_config_get_test.zig` doesn't exist yet, create it as a
new file mirroring `nalar_config_put_test.zig`'s static-pattern
style.)

- [ ] **Step 1.2.2: Run test to verify it fails**

```bash
timeout 180 zig build test --summary all 2>&1 | rg "retry_delay_ms" | head -n 5
```

Expected: 1 new test fails with `RetryDelayMissingFromResponse` (or
the corresponding error variant).

- [ ] **Step 1.2.3: Add `retry_delay_ms` to `NalarConfigResponse`**

In `src/ai_workflow/tui/http_handlers/http_response.zig`, after the
existing `compaction_threshold_percent: ?u8 = null` field, add:

```zig
/// Delay in milliseconds before the workflow retries a failed
/// `callDynamicAgentNew` call. 0 = no delay. Consumed by
/// `workflow.zig:518` (the `callDynamicAgentNew` retry catch) and
/// `workflow.zig:588` (the `else` finish_reason branch).
retry_delay_ms: u32 = 0,
```

- [ ] **Step 1.2.4: Pipe `retry_delay_ms` through the GET handler**

In `src/ai_workflow/tui/http_handlers/nalar_config_get.zig`:

(a) In the `makeNalarConfigResponse(...)` call (around line 100-122),
after the existing `.compaction_threshold_percent = cfg.compaction_threshold_percent,`
line, add:

```zig
.retry_delay_ms = cfg.retry_delay_ms,
```

(b) In the inner `ConfigJson` struct (around line 125-156), after the
existing `compaction_threshold_percent: ?u8 = null` field, add:

```zig
/// Delay in milliseconds before retrying a failed workflow call.
/// See `LlmConfig.retry_delay_ms` for semantics.
retry_delay_ms: u32 = 0,
```

- [ ] **Step 1.2.5: Run test to verify it passes**

```bash
timeout 180 zig build test --summary all 2>&1 | rg "retry_delay_ms|test success" | head -n 5
```

Expected: the new test passes.

- [ ] **Step 1.2.6: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/
git commit -m "feat(http): include retry_delay_ms in GET /api/config/nalar"
```

---

### Task 1.3: Add `retry_delay_ms` to the HTTP PUT handler with range clamping

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` (add to `ConfigInput` ~line 390-460 and apply block ~line 140-155)
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig` (extend `makeConfig`, add clamping test)

- [ ] **Step 1.3.1: Write the failing tests**

In `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig`, add
three tests:

```zig
test "PUT retry_delay_ms: persists a valid value" {
    // Set up makeConfig with retry_delay_ms = 5000, exercise the PUT
    // path, assert the saved ConfigJson has retry_delay_ms = 5000.
    // (Match the pattern of the existing compaction-threshold tests.)
}

test "PUT retry_delay_ms: clamps values above 60_000 to 60_000" {
    // Send retry_delay_ms = 120_000; assert the saved value is 60_000.
}

test "PUT retry_delay_ms: coerces values below 0 by treating them as 0" {
    // u32 can't be negative at the JSON level, but send `null` and
    // assert the saved value is 0 (matches the "no override" semantics).
}
```

- [ ] **Step 1.3.2: Run tests to verify they fail**

```bash
timeout 180 zig build test --summary all 2>&1 | rg "retry_delay_ms" | head -n 5
```

Expected: 3 tests fail with "no field named 'retry_delay_ms'".

- [ ] **Step 1.3.3: Add `retry_delay_ms` to `ConfigInput`**

In `src/ai_workflow/tui/http_handlers/nalar_config_put.zig`, in the
`ConfigInput` struct (around line 390-460), after the existing
`compaction_threshold_percent: ?u8 = null` field, add:

```zig
/// Delay in milliseconds before retrying a failed workflow call.
/// Range-validated at apply time: 0 ≤ value ≤ 60_000.
retry_delay_ms: ?u32 = null,
```

- [ ] **Step 1.3.4: Add the apply block**

After the existing `if (input.compaction_threshold_percent) |tp| { ... }`
apply block (around line 152-155), add:

```zig
// retry_delay_ms: clamp to [0, 60_000]. Values > 60_000 would let a
// user lock themselves out of cancelable recovery (one cancellation
// attempt would have to wait the full delay). Values < 0 are impossible
// at the type level (u32). `null` means "no change" so an omit-from-PUT
// doesn't reset the existing value.
if (input.retry_delay_ms) |ms| {
    config_json.retry_delay_ms = if (ms > 60_000) 60_000 else ms;
}
```

- [ ] **Step 1.3.5: Update `makeConfig` in `nalar_config_put_test.zig`**

Find the `makeConfig` helper in `nalar_config_put_test.zig`. After the
existing `compaction_threshold_percent: ...` line, add:

```zig
.retry_delay_ms = 0,
```

- [ ] **Step 1.3.6: Run tests to verify they pass**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: all 3 new tests pass, total count +3 vs baseline.

- [ ] **Step 1.3.7: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/
git commit -m "feat(http): accept retry_delay_ms in PUT /api/config/nalar (clamped to 0..60000)"
```

---

## Chunk 2: Frontend types + UI

### Task 2.1: Add `retry_delay_ms` to the TypeScript `NalarConfig` interface

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts` (~line 1974-2029)

- [ ] **Step 2.1.1: Write the failing test**

In `src/apps/desktop/src/__tests__/apiConfigTypes.spec.ts` (create if
absent, otherwise add to existing test file):

```ts
import { describe, expect, it } from 'vitest'
import type { NalarConfig } from '../api'

describe('NalarConfig', () => {
  it('accepts retry_delay_ms as an optional number', () => {
    const cfg: NalarConfig = {
      api_key: 'sk-test',
      retry_delay_ms: 5000,
    }
    expect(cfg.retry_delay_ms).toBe(5000)
  })

  it('allows retry_delay_ms to be omitted (defaults undefined)', () => {
    const cfg: NalarConfig = { api_key: 'sk-test' }
    expect(cfg.retry_delay_ms).toBeUndefined()
  })
})
```

- [ ] **Step 2.1.2: Run test to verify it fails**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | rg "retry_delay_ms|error TS" | head -n 10
```

Expected: `Property 'retry_delay_ms' does not exist on type 'NalarConfig'`.

- [ ] **Step 2.1.3: Add `retry_delay_ms` to `NalarConfig`**

In `src/apps/desktop/src/api/index.ts`, in the `NalarConfig` interface
(around line 1974-2029), after the existing
`compaction_threshold_percent?: number | null` field, add:

```ts
/**
 * Delay in milliseconds before the workflow retries a failed
 * `callDynamicAgentNew` call. 0 = no delay (current behavior, the
 * retry fires immediately on the next loop iteration). Range: 0–60 000.
 * The backend clamps values > 60 000 to 60 000. Mirrors
 * `LlmConfig.retry_delay_ms` in `Config.zig`.
 */
retry_delay_ms?: number
```

- [ ] **Step 2.1.4: Run test to verify it passes**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10
```

Expected: `Build successful` (or the equivalent tail output the project uses).

- [ ] **Step 2.1.5: Commit**

```bash
git add src/apps/desktop/src/api/index.ts src/apps/desktop/src/__tests__/
git commit -m "feat(desktop): add retry_delay_ms to NalarConfig TypeScript interface"
```

---

### Task 2.2: Add `retry_delay_ms` UI to `DefaultsSection.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/nalar/DefaultsSection.vue` (extend `DefaultsConfig`, add new section in template)
- Modify: `src/apps/desktop/src/components/NalarSettings.vue` (extend `syncFromConfig` / `syncToConfig` / `emptyDefaults`)
- Modify: `src/apps/desktop/src/__tests__/DefaultsSection.spec.ts` (add `baseConfig.retry_delay_ms`, add a new test)

- [ ] **Step 2.2.1: Add `retry_delay_ms` to `baseConfig` in the test file**

In `src/apps/desktop/src/__tests__/DefaultsSection.spec.ts`, in the
`baseConfig` const at the top (around line 6-18), after the existing
`compaction_threshold_percent: null as number | null,` field, add:

```ts
retry_delay_ms: 0,
```

- [ ] **Step 2.2.2: Write the failing test**

In the same file, after the existing compaction tests, add:

```ts
it('renders the retry-delay input with the current value', () => {
  const wrapper = mount(DefaultsSection, {
    props: { modelValue: { ...baseConfig, retry_delay_ms: 7500 } },
  })
  const input = wrapper.find('[data-testid="retry-delay-input"]')
  expect((input.element as HTMLInputElement).value).toBe('7500')
})

it('emits update:modelValue when retry_delay_ms changes', async () => {
  const wrapper = mount(DefaultsSection, {
    props: { modelValue: { ...baseConfig } },
  })
  const input = wrapper.find('[data-testid="retry-delay-input"]')
  await input.setValue('3000')
  const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseConfig
  expect(emitted.retry_delay_ms).toBe(3000)
})

it('clamps retry_delay_ms to 0..60000 on input', async () => {
  const wrapper = mount(DefaultsSection, {
    props: { modelValue: { ...baseConfig } },
  })
  const input = wrapper.find('[data-testid="retry-delay-input"]')
  await input.setValue('120000')
  const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseConfig
  expect(emitted.retry_delay_ms).toBe(60000)
})
```

- [ ] **Step 2.2.3: Run tests to verify they fail**

```bash
cd src/apps/desktop && timeout 120 bunx vitest run DefaultsSection 2>&1 | tail -n 20
```

Expected: 3 tests fail with "did not find [data-testid=retry-delay-input]"
(or the equivalent vitest failure).

- [ ] **Step 2.2.4: Add `retry_delay_ms` to `DefaultsConfig` interface**

In `src/apps/desktop/src/components/nalar/DefaultsSection.vue`, in the
`DefaultsConfig` interface (around line 4-21), after the existing
`compaction_threshold_percent` field, add:

```ts
/**
 * Delay in milliseconds before the workflow retries a failed
 * LLM call. 0 = no delay (default). Range: 0–60 000. Added in
 * plan 2026-07-15-retry-delay.
 */
retry_delay_ms: number
```

- [ ] **Step 2.2.5: Add the new section to the template**

In the `<template>` block (after the "── Compaction defaults ──"
section, around line 307), add:

```vue
<!-- Workflow behavior — plan 2026-07-15-retry-delay -->
<section>
  <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Workflow behavior ──</h3>
  <div class="space-y-4">
    <div>
      <label :class="labelBase" :style="labelStyle">Retry delay (ms)</label>
      <input
        :value="modelValue.retry_delay_ms"
        @input="
          update(
            'retry_delay_ms',
            Math.max(0, Math.min(60000, parseInt(($event.target as HTMLInputElement).value, 10) || 0)),
          )
        "
        type="number"
        min="0"
        max="60000"
        step="100"
        placeholder="0"
        :class="inputBase"
        :style="inputStyle"
        data-testid="retry-delay-input"
      />
      <p class="text-xs mt-1" :style="helperStyle">
        Milliseconds to wait before retrying a failed LLM call. 0 = no delay (retry immediately).
        Useful when the upstream rate-limits and you want to back off instead of hammering it.
        Max 60 000 ms (1 min) — beyond that, cancel and start a new session.
      </p>
    </div>
  </div>
</section>
```

- [ ] **Step 2.2.6: Wire through NalarSettings.vue**

In `src/apps/desktop/src/components/NalarSettings.vue`:

(a) In `syncFromConfig` (around line 106-141), after the existing
`compaction_threshold_percent: c.compaction_threshold_percent ?? null,`
line, add:

```ts
retry_delay_ms: c.retry_delay_ms ?? 0,
```

(b) In `syncToConfig` (around line 143-176), after the existing
`compaction_threshold_percent: d.compaction_threshold_percent,`
line, add:

```ts
retry_delay_ms: d.retry_delay_ms,
```

(c) In `emptyDefaults` (around line 257-266), after the existing
`compaction_threshold_percent: null,` line, add:

```ts
retry_delay_ms: 0,
```

- [ ] **Step 2.2.7: Run tests to verify they pass**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 5         # TypeScript type-check
timeout 120 bunx vitest run DefaultsSection 2>&1 | tail -n 10
```

Expected: `Build successful`, all 3 new tests pass.

- [ ] **Step 2.2.8: Commit**

```bash
git add src/apps/desktop/src/
git commit -m "feat(desktop): expose retry_delay_ms input in Defaults tab (0-60000 ms)"
```

---

## Chunk 3: Workflow integration (the actual retry-delay behavior)

### Task 3.1: Add the cancellation-aware `retryDelayMs` helper to `workflow.zig`

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig` (add helper near the bottom of the file, around line 685)

- [ ] **Step 3.1.1: Write the static regression test for `retryDelayMs`**

In `src/ai_workflow/tui/workflow_retry_delay_test.zig` (new file),
add:

```zig
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// PosixTimespec for `nanosleep`. Mirrors the same shape used in
/// `src/modules/agent/tools/bash.zig:18-21` so the helper stays
/// cross-platform.
const PosixTimespec = extern struct {
    sec: c_long,
    nsec: c_long,
};
extern "c" fn nanosleep(req: *const PosixTimespec, rem: ?*PosixTimespec) c_int;

const WORKFLOW_SOURCE_PATH = "src/ai_workflow/tui/workflow.zig";

test "workflow.zig declares retryDelayMs helper" {
    const source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io, WORKFLOW_SOURCE_PATH, std.testing.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| {
        std.debug.print("!! cannot read {s}: {{}} !!\n", .{WORKFLOW_SOURCE_PATH});
        return err;
    };
    defer std.testing.allocator.free(source);

    if (std.mem.indexOf(u8, source, "fn retryDelayMs(") == null) {
        std.debug.print(
            "!! workflow.zig does not declare retryDelayMs helper !!\n", .{});
        return error.RetryDelayMsMissing;
    }
}

test "workflow.zig retryDelayMs uses raw libc nanosleep, not std.Io.sleep" {
    const source = ...; // same as above
    defer std.testing.allocator.free(source);

    // The helper MUST NOT use std.Io.sleep — that would deadlock the
    // Io.Group concurrent task the workflow runs inside (see bash.zig
    // comment lines 4-17 for the exact reasoning).
    const retryDelayMsFnMatch = std.mem.indexOf(u8, source, "fn retryDelayMs(");
    if (retryDelayMsFnMatch == null) return error.RetryDelayMsMissing;
    // Find the function body end (next top-level `fn` or `pub const`
    // at column 0). Crude heuristic — works for this codebase.
    const body_end = std.mem.indexOfPos(u8, source, retryDelayMsFnMatch.? + 1, "\nfn ")
        orelse source.len;
    const body = source[retryDelayMsFnMatch.?..body_end];

    if (std.mem.indexOf(u8, body, "std.Io.sleep") != null) {
        std.debug.print(
            "!! retryDelayMs uses std.Io.sleep — this deadlocks the Io.Group !!\n", .{});
        return error.RetryDelayMsUsesIoSleep;
    }
    if (std.mem.indexOf(u8, body, "nanosleep") == null) {
        std.debug.print(
            "!! retryDelayMs does not call raw libc nanosleep !!\n", .{});
        return error.RetryDelayMsMissingNanosleep;
    }
}
```

- [ ] **Step 3.1.2: Run tests to verify they fail**

```bash
timeout 180 zig build test --summary all 2>&1 | rg "RetryDelayMs|retryDelayMs" | head -n 5
```

Expected: 2 tests fail with `RetryDelayMsMissing` and
`RetryDelayMsUsesIoSleep`/`RetryDelayMsMissingNanosleep`.

- [ ] **Step 3.1.3: Register the test file in `test_runner.zig`**

In `src/ai_workflow/tui/test_runner.zig`, after the existing
`_ = @import("workflow_compaction_envelope_test.zig");` line, add:

```zig
_ = @import("workflow_retry_delay_test.zig");
```

- [ ] **Step 3.1.4: Add `retryDelayMs` helper to `workflow.zig`**

In `src/ai_workflow/tui/workflow.zig`, after the existing
`generateSessionNameNew` function (around line 685), add:

```zig
// POSIX `nanosleep` — declared `extern "c"` so the call doesn't go
// through Zig 0.16's Io runtime. We deliberately avoid `std.Io.sleep`
// because the workflow is dispatched as an `Io.Group.concurrent` task
// from the event bus; blocking on `std.Io.sleep` inside that context
// deadlocks the group (see `bash.zig:4-17` for the exact reasoning).
//
// Field names differ between libc implementations: glibc uses
// `tv_sec`/`tv_nsec`, Darwin and most BSDs use `sec`/`nsec`. We mirror
// the local `PosixTimespec` shape from `helpers/mod.zig` (sec/nsec)
// so this works on macOS too.
const WorkflowNanoSleepTimespec = extern struct {
    sec: c_long,
    nsec: c_long,
};
extern "c" fn workflowNanosleep(req: *const WorkflowNanoSleepTimespec, rem: ?*WorkflowNanoSleepTimespec) c_int;

/// Sleep for up to `delay_ms` milliseconds, polling `isWorkerCancelled`
/// every 50 ms so a user-initiated cancel returns early. Returns true
/// if the delay completed, false if it was interrupted by cancellation.
///
/// `delay_ms = 0` is a fast-path no-op (returns true immediately).
/// This avoids the overhead of one nanosleep call when the user has
/// configured "no delay" (the default).
///
/// Chunk size: 50 ms balances two concerns:
/// - Cancellation responsiveness: a cancel fires within 50 ms of
///   clicking (imperceptible to the user).
/// - CPU overhead: 20 polls/sec is trivial; we never spin-busy-wait.
fn retryDelayMs(
    delay_ms: u32,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    io: std.Io,
    logger: *logger_mod.Logger,
) bool {
    if (delay_ms == 0) return true;

    const deadline_ns: i96 = std.Io.Timestamp.now(io, .real).nanoseconds +
        @as(i96, @intCast(delay_ms)) * std.time.ns_per_ms;

    while (true) {
        // Cancellation check — same shape as the loop-top check at
        // `workflow.zig:276` so the cancel UX is consistent.
        if (agentic_loop_mod.isWorkerCancelled(agentic_loop_mod.IsWorkerCancelledInput{
            .allocator = std.heap.page_allocator,  // owned by LlmConfig singleton, short-lived check
            .db = db,
            .session_id = session_id,
        })) {
            logger.infoFmt(
                "Retry delay interrupted by worker cancellation: session_id={s} remaining={d}ms",
                .{ session_id, @as(u32, @intCast(@max(
                    @divFloor(deadline_ns - std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms),
                    @as(i96, 0),
                ))) },
            );
            return false;
        }
        if (std.Io.Timestamp.now(io, .real).nanoseconds >= deadline_ns) return true;

        const remaining_ms: u32 = @intCast(@divFloor(
            deadline_ns - std.Io.Timestamp.now(io, .real).nanoseconds,
            std.time.ns_per_ms,
        ));
        const chunk_ms: u32 = if (remaining_ms > 50) 50 else remaining_ms;

        const ts = WorkflowNanoSleepTimespec{
            .sec = 0,
            .nsec = chunk_ms * std.time.ns_per_ms,
        };
        _ = workflowNanosleep(&ts, null);
    }
}
```

**Important: pass real allocator to `isWorkerCancelled`.** The
`page_allocator` placeholder above is a code smell — in production
`isWorkerCancelled` reads from the DB and may allocate internally.
The actual call site (Step 3.2.2) has `allocator` in scope; pass
that instead. Adjust the helper signature to take `allocator:
std.mem.Allocator` as the first parameter, mirroring
`IsWorkerCancelledInput.allocator`. Update the static test in Step
3.1.1 to assert the signature has `allocator` as the first param
(no signature constraint; this is just a code-review note).

- [ ] **Step 3.1.5: Run tests to verify they pass**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `test success`, the 2 new tests pass.

- [ ] **Step 3.1.6: Commit**

```bash
git add src/ai_workflow/tui/workflow.zig src/ai_workflow/tui/workflow_retry_delay_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(workflow): add cancellation-aware retryDelayMs helper (raw nanosleep)"
```

---

### Task 3.2: Wire the delay into the `callDynamicAgentNew` retry path

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig` (around line 513-525, the retry catch)

- [ ] **Step 3.2.1: Write the static regression test for retry-path wiring**

Add to `src/ai_workflow/tui/workflow_retry_delay_test.zig`:

```zig
test "workflow.zig calls retryDelayMs in the callDynamicAgentNew catch" {
    const source = ...; // read workflow.zig
    defer std.testing.allocator.free(source);

    // The catch block at line 518-525 must call retryDelayMs before
    // the `continue` statement. Assert that the catch block contains
    // both the function call AND a reference to the new config field.
    const catch_block = std.mem.indexOf(u8, source, "last_retry_source = \"callDynamicAgentNew\";");
    if (catch_block == null) return error.RetryCatchBlockNotFound;
    // Find the next `continue;` after the catch block.
    const continue_pos = std.mem.indexOfPos(u8, source, catch_block.?, "continue;");
    if (continue_pos == null) return error.RetryContinueMissing;
    const between = source[catch_block.?..continue_pos.?];

    if (std.mem.indexOf(u8, between, "retryDelayMs(") == null) {
        std.debug.print(
            "!! callDynamicAgentNew catch does not call retryDelayMs before continue !!\n", .{});
        return error.RetryDelayNotCalled;
    }
    if (std.mem.indexOf(u8, between, "config.retry_delay_ms") == null) {
        std.debug.print(
            "!! callDynamicAgentNew catch does not read config.retry_delay_ms !!\n", .{});
        return error.RetryDelayConfigNotRead;
    }
}
```

- [ ] **Step 3.2.2: Run test to verify it fails**

```bash
timeout 180 zig build test --summary all 2>&1 | rg "RetryDelayNotCalled|RetryDelayConfigNotRead" | head -n 5
```

Expected: 1 test fails with `RetryDelayNotCalled`.

- [ ] **Step 3.2.3: Wire `retryDelayMs` into the catch block**

In `src/ai_workflow/tui/workflow.zig`, replace the existing catch
block (line 513-525):

```zig
const res_dynamic_agent = callDynamicAgentNew(allocator, io, messagesLists, agent_temperature, current_max_tokens, isThinking, effective_api_key, effective_model, effective_base_url, effective_url_style, copy_session_id, merged_tools) catch |err| {
    if (err == error.Cancelled) {
        logger.infoFmt("WORKFLOW CANCELLED during streaming: session_id={s}", .{copy_session_id});
        break;
    }
    retry_count += 1;
    // Capture WHY this retry fired so the AI agent can understand
    // the cause when the retry budget is eventually exhausted.
    last_retry_error = err;
    last_retry_source = "callDynamicAgentNew";
    logger.errFmt("Error calling dynamic agent: {s} now retrying", .{@errorName(err)});
    continue;
};
```

with:

```zig
const res_dynamic_agent = callDynamicAgentNew(allocator, io, messagesLists, agent_temperature, current_max_tokens, isThinking, effective_api_key, effective_model, effective_base_url, effective_url_style, copy_session_id, merged_tools) catch |err| {
    if (err == error.Cancelled) {
        logger.infoFmt("WORKFLOW CANCELLED during streaming: session_id={s}", .{copy_session_id});
        break;
    }
    retry_count += 1;
    // Capture WHY this retry fired so the AI agent can understand
    // the cause when the retry budget is eventually exhausted.
    last_retry_error = err;
    last_retry_source = "callDynamicAgentNew";
    logger.errFmt("Error calling dynamic agent: {s} now retrying after {d}ms delay", .{ @errorName(err), config.retry_delay_ms });
    // Sleep before the next attempt so the upstream can recover (or
    // rate-limit window can close). 0 ms = no delay (current
    // behavior, the default). Interrupted by worker cancellation —
    // see retryDelayMs for the polling details.
    if (!retryDelayMs(config.retry_delay_ms, allocator, db, copy_session_id, io, logger)) {
        logger.infoFmt("WORKFLOW CANCELLED during retry delay: session_id={s}", .{copy_session_id});
        break;
    }
    continue;
};
```

- [ ] **Step 3.2.4: Run test to verify it passes**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `test success`, the new test passes.

- [ ] **Step 3.2.5: Commit**

```bash
git add src/ai_workflow/tui/workflow.zig src/ai_workflow/tui/workflow_retry_delay_test.zig
git commit -m "feat(workflow): sleep before retry after callDynamicAgentNew error"
```

---

### Task 3.3: Wire the delay into the second retry path (`else` finish_reason branch)

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig` (around line 587-589, the `else` retry)

- [ ] **Step 3.3.1: Write the static regression test**

Add to `src/ai_workflow/tui/workflow_retry_delay_test.zig`:

```zig
test "workflow.zig calls retryDelayMs in the finish_reason else branch" {
    const source = ...; // read workflow.zig
    defer std.testing.allocator.free(source);

    // The else branch (line 587-589) fires for finish_reasons other
    // than .stop, .length, .tool_calls. It increments retry_count and
    // breaks; we want to delay before the break so the next loop
    // iteration doesn't hammer the upstream immediately.
    const else_marker = std.mem.indexOf(u8, source, "} else {");
    if (else_marker == null) return error.ElseBranchNotFound;
    const else_block = source[else_marker.?..@min(else_marker.? + 500, source.len)];

    if (std.mem.indexOf(u8, else_block, "retryDelayMs(") == null) {
        std.debug.print(
            "!! else finish_reason branch does not call retryDelayMs !!\n", .{});
        return error.RetryDelayNotCalledInElse;
    }
    if (std.mem.indexOf(u8, else_block, "retry_count += 1;") == null) {
        std.debug.print(
            "!! else finish_reason branch does not increment retry_count !!\n", .{});
        return error.RetryCountNotIncrementedInElse;
    }
}
```

- [ ] **Step 3.3.2: Run test to verify it fails**

```bash
timeout 180 zig build test --summary all 2>&1 | rg "RetryDelayNotCalledInElse" | head -n 5
```

Expected: 1 test fails with `RetryDelayNotCalledInElse`.

- [ ] **Step 3.3.3: Wire `retryDelayMs` into the `else` branch**

In `src/ai_workflow/tui/workflow.zig`, replace the existing else
branch (line 587-589):

```zig
} else {
    retry_count += 1;
    break;
}
```

with:

```zig
} else {
    retry_count += 1;
    // Same delay policy as the callDynamicAgentNew catch — sleep
    // before the loop restarts so we don't hammer the upstream when
    // it returns an unexpected finish_reason repeatedly. Interrupted
    // by worker cancellation.
    if (!retryDelayMs(config.retry_delay_ms, allocator, db, copy_session_id, io, logger)) {
        logger.infoFmt("WORKFLOW CANCELLED during retry delay (finish_reason else): session_id={s}", .{copy_session_id});
        break;
    }
    break;
}
```

- [ ] **Step 3.3.4: Run test to verify it passes**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `test success`, the new test passes.

- [ ] **Step 3.3.5: Commit**

```bash
git add src/ai_workflow/tui/workflow.zig src/ai_workflow/tui/workflow_retry_delay_test.zig
git commit -m "feat(workflow): sleep before retry on unexpected finish_reason"
```

---

## Chunk 4: Full verification + smoke test

### Task 4.1: Run the full verification battery

- [ ] **Step 4.1.1: Run the test target**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `Build Summary: 5/5 steps succeeded; <N>/<N> tests passed (<k> skipped)` with N = baseline + 13 (3 LlmConfig + 1 GET + 3 PUT + 3 UI + 3 workflow_retry_delay = 13 new tests).

- [ ] **Step 4.1.2: Run the install target**

```bash
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
```

Expected: `Build Summary: 4/6 steps succeeded` (the cp to `/usr/local/bin/nalar`
fails harmlessly with "Permission denied", the compile step succeeds). If you see
"compile exe nalar" → "1 errors", the production code has a type error that the
test target's lazy analysis missed — fix and re-run before continuing.

- [ ] **Step 4.1.3: Force a fresh full build**

```bash
rm -rf zig-out/bin
timeout 360 zig build 2>&1 | tail -n 10
```

Expected: `zig build success` (no `1 errors`, no warnings). If you see
errors, the test target's lazy analysis hid a real production-code
error — fix and re-run.

- [ ] **Step 4.1.4: Run the frontend type-check + tests**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 5        # vue-tsc + bundle
timeout 120 bunx vitest run 2>&1 | tail -n 10     # unit tests
```

Expected: `Build successful` and all Vitest tests pass.

- [ ] **Step 4.1.5: Commit (if any final adjustments were needed)**

```bash
git add -A
git commit -m "chore: post-verification cleanup" --allow-empty
```

(Skip this step if Step 4.1.1–4.1.4 already passed cleanly.)

---

### Task 4.2: Manual smoke test (verify the delay is honored in a real workflow run)

**This task is a manual end-to-end verification. Run by hand after the
automated verification passes.**

- [ ] **Step 4.2.1: Start `nalar` with a temporary config that enables the delay**

```bash
# Build a config with retry_delay_ms = 3000 (3 seconds).
mkdir -p /tmp/nalar-smoke
cat > /tmp/nalar-smoke/config.json <<EOF
{
  "api_key": "sk-fake-key-for-smoke",
  "model": "MiniMax-M3",
  "base_url": "http://127.0.0.1:9",
  "retry_delay_ms": 3000
}
EOF
env HOME=/tmp/nalar-smoke timeout 90 ./zig-out/bin/nalar --port 8080 2>&1 | tee /tmp/nalar-smoke.log &
SERVER_PID=$!
sleep 5
```

Expected: server starts listening on port 8080. The fake `base_url`
will cause every LLM call to fail, which triggers the retry path.

- [ ] **Step 4.2.2: Trigger a workflow that will retry**

In the desktop UI (or via curl + the relevant endpoint), create a new
chat session and send a message. The workflow will fail on the first
LLM call (because `127.0.0.1:9` is not a real LLM endpoint) and
retry.

- [ ] **Step 4.2.3: Observe the retry delay in the log**

```bash
timeout 30 rg "now retrying after" /tmp/nalar-smoke.log | head -n 5
```

Expected: log lines like
`Error calling dynamic agent: ConnectionRefused now retrying after 3000ms delay`
appearing at intervals ≥ 3 seconds. (Without the fix, they'd appear
back-to-back with sub-second gaps.)

- [ ] **Step 4.2.4: Verify cancellation interrupts the delay**

In the desktop UI, click the Cancel button on the running chat.
Immediately check the log:

```bash
rg "Retry delay interrupted by worker cancellation" /tmp/nalar-smoke.log | tail -n 3
```

Expected: at least one log line appears within ~50 ms of clicking
Cancel (matches the 50 ms poll cadence in `retryDelayMs`).

- [ ] **Step 4.2.5: Verify TooManyRetries still fires**

Let the retries continue past the budget (10 retries × 3 s = 30 s) and
confirm `TooManyRetries exhausted:` appears in the log:

```bash
rg "TooManyRetries exhausted" /tmp/nalar-smoke.log | head -n 3
```

Expected: log line like `TooManyRetries exhausted: 11 consecutive
failures for session_id=... — last_error=ConnectionRefused
source=callDynamicAgentNew`.

- [ ] **Step 4.2.6: Clean up**

```bash
kill $SERVER_PID 2>/dev/null
rm -rf /tmp/nalar-smoke /tmp/nalar-smoke.log
```

Expected: no errors. (NEVER `pkill -f "nalar --port"` — that pattern
also catches the production nalar on port 8081.)

- [ ] **Step 4.2.7: Commit (smoke-test changes, if any)**

This task is pure verification — it shouldn't produce any source
changes. If it did, that's a bug; investigate and fix before
declaring the plan done.

```bash
git status
```

Expected: clean tree (no uncommitted changes).

---

## Test Inventory (recap of new + extended tests)

| File | Test | Purpose |
|------|------|---------|
| `src/modules/config/config_test.zig` | `retry_delay_ms: defaults to 0 when missing from JSON` | Config loader handles the missing-field case |
| `src/modules/config/config_test.zig` | `retry_delay_ms: reads from JSON when present` | Config loader handles the explicit-value case |
| `src/modules/config/config_test.zig` | `defaultConfigJson includes retry_delay_ms: 0` | Fresh-install config seeds the field |
| `src/ai_workflow/tui/http_handlers/nalar_config_get_test.zig` | `GET /api/config/nalar response includes retry_delay_ms` | Wire format is complete |
| `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig` | `PUT retry_delay_ms: persists a valid value` | PUT handler applies the field |
| `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig` | `PUT retry_delay_ms: clamps values above 60_000 to 60_000` | Range clamp works |
| `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig` | `PUT retry_delay_ms: coerces null to 0` | `null` is a legitimate "no override" value |
| `src/apps/desktop/src/__tests__/apiConfigTypes.spec.ts` | `accepts retry_delay_ms as an optional number` | TS type accepts the field |
| `src/apps/desktop/src/__tests__/DefaultsSection.spec.ts` | `renders the retry-delay input with the current value` | UI displays the field |
| `src/apps/desktop/src/__tests__/DefaultsSection.spec.ts` | `emits update:modelValue when retry_delay_ms changes` | UI emits the field on edit |
| `src/apps/desktop/src/__tests__/DefaultsSection.spec.ts` | `clamps retry_delay_ms to 0..60000 on input` | UI-side range clamp works |
| `src/ai_workflow/tui/workflow_retry_delay_test.zig` | `workflow.zig declares retryDelayMs helper` | Helper exists at the source level |
| `src/ai_workflow/tui/workflow_retry_delay_test.zig` | `workflow.zig retryDelayMs uses raw libc nanosleep, not std.Io.sleep` | Helper uses the Io-re-entrancy-safe sleep |
| `src/ai_workflow/tui/workflow_retry_delay_test.zig` | `workflow.zig calls retryDelayMs in the callDynamicAgentNew catch` | First retry path is wired |
| `src/ai_workflow/tui/workflow_retry_delay_test.zig` | `workflow.zig calls retryDelayMs in the finish_reason else branch` | Second retry path is wired |

Total: 14 new tests (8 Zig, 4 TypeScript). 8 commit checkpoints across 4 chunks. Plan completes in ~5 review cycles.

---

## Related Precedents in the Codebase (consult during implementation)

- **`src/modules/agent/tools/bash.zig:4-17` + `:442-478`** — the `nanosleep` + cancel-poll pattern that `retryDelayMs` mirrors. The deadlock-with-`Io.Group` comment is the exact reasoning the plan's architecture section cites.
- **`src/modules/config/Config.zig:30` + `nalar_config_get.zig:113` + `nalar_config_put.zig:139-141`** — the `notify_on_complete` field's full lifecycle (LlmConfig struct → LlmConfigJson parse → HTTP GET → HTTP PUT). `retry_delay_ms` follows the same shape exactly.
- **`docs/superpowers/plans/2026-07-06-configurable-compaction.md`** — the most recent "add a config field end-to-end" plan. The chunk + task decomposition matches the patterns established there.
- **`src/apps/desktop/src/components/nalar/DefaultsSection.vue:220-307`** — the existing "── Compaction defaults ──" section template (section header, helper text style, input bindings). The new "── Workflow behavior ──" section is a stripped-down version of this pattern.

---

## Pitfalls to Watch For

1. **`std.Io.sleep` deadlocks the workflow.** The plan explicitly uses raw libc `nanosleep` for this reason. If a future refactor "modernizes" the call to `std.Io.sleep`, the workflow will hang on any retry. The static regression test (`RetryDelayMsUsesIoSleep`) guards against this.

2. **`page_allocator` is not a good default.** Task 3.1.4's code-review note flags that the `isWorkerCancelled` call inside `retryDelayMs` needs a real allocator. In production, the call site (`retryDelayMs` from inside `runAgenticMultiStepnew`) has `allocator` in scope (line 273), and the workflow's arena allocator is appropriate for this short-lived check.

3. **Both retry paths must be updated.** The plan covers both `callDynamicAgentNew` (line 518) AND the `else` finish_reason branch (line 588). A reviewer who only catches the first will leave the second path still hammering the upstream on weird finish_reason values.

4. **HTTP `null` ≠ "delete the field".** In `ConfigInput.retry_delay_ms: ?u32 = null`, `null` means "user omitted the field, don't change it". The apply block only fires when `input.retry_delay_ms) |ms|` matches Some. The clamp uses `if (ms > 60_000)` (not `> 60_000 orelse 60_000`) because the `|ms|` unwrap already proved ms is present.

5. **`defaultConfigJson` regression.** Task 1.1.6 adds the field to the default JSON string. The `compaction_threshold_percent: ?u8 = null` precedent in `LlmConfig` is NON-NULLABLE (defaults to `null` materialized at parse), but `retry_delay_ms: u32 = 0` is NON-NULLABLE on `LlmConfig` with a default of 0. Both work — just be consistent.

6. **Test target's lazy analysis hides production errors.** Task 4.1.3 (`rm -rf zig-out/bin && zig build`) is non-optional. `zig build test` may report green while the install/full build fails. Always run all three.

7. **Don't `pkill -f "nalar --port"` in Task 4.2.6.** The project's mandatory rule: another `nalar` process is always running on port 8081. Use the captured `$SERVER_PID` instead.

---

## Future Enhancements (out of scope for v1)

These were considered and explicitly deferred. A follow-up plan can
address them.

1. **Exponential backoff.** Replace `retryDelayMs(delay_ms, ...)` with
   `retryDelayMs(base_ms, max_ms, attempt, ...)` and
   `delay = base * 2^attempt` capped at `max`. Useful when
   fixed-delay retries still hammer the upstream under sustained
   outage.

2. **Per-error-class delay policy.** Different delays for
   `ConnectionRefused` (likely transient — short delay) vs
   `RateLimited` (use the `Retry-After` header — needs response
   inspection).

3. **Exponential-jitter.** Add ±10% randomization to avoid
   thundering-herd when multiple sessions retry simultaneously.

4. **Telemetry.** Emit an SSE event when a retry is delayed, so
   the user can see "Retrying in 3s…" in the UI. Currently the
   delay is silent (logged only).

5. **Per-profile override.** Some users may want a self-hosted
   profile with a longer delay (more tolerant of slow upstream).
   Add `LlmProfile.retry_delay_ms: ?u32` and cascade via
   `resolveRetryDelayMs(profile_name, sub_agent)`.

---

## Review Cycle Checklist (per `writing-plans` skill)

After completing each chunk, dispatch the plan-document-reviewer subagent
against the chunk's section. Apply fixes inline. Repeat until ✅ Approved.
Then execute the chunk via `superpowers:subagent-driven-development`.

- [ ] Chunk 1 reviewed and approved
- [ ] Chunk 2 reviewed and approved
- [ ] Chunk 3 reviewed and approved
- [ ] Chunk 4 reviewed and approved
- [ ] Full plan executed end-to-end, all 14 new tests passing, smoke test green