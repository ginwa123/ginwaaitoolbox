# Plan: move compaction settings inline — Defaults + Edit-profile + Profiles row

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

## Why this plan exists

The current Compaction tab (Chunk 7.6, commit `6e3c1180`) iterates the `profiles` map and renders one card per profile with capacity + threshold inputs. The user wants the compaction settings surfaced INLINE next to the existing per-profile metadata in three places:

1. **Defaults tab** (top-level "DEFAULT LLM" form) — for users who don't use profiles.
2. **Edit-profile modal** — alongside model/base_url/api_key. The user wrote "put the compaction setting here too" on the modal screenshot.
3. **Profiles list row** — a compact summary line "Compaction: 80% @ 500k tokens" (or similar) so the user can see the current override at-a-glance without opening the modal.

The top-level "Compaction" tab is **removed** — its per-profile rows are replaced by the inline summary line on each profile row, with the actual inputs living in the Edit-profile modal (and the defaults in the Defaults tab).

This effectively inverts Chunk 7's "per-profile only" decision. The new semantics are: **defaults (top-level) cascade per-profile override cascade sub-agent override cascade built-in default**. The cascade stays the same on the backend; only the UI location changes.

## Background — what the current state is

**Backend** (commit `49c19739`, the Chunk 7 backend reshape):
- `LlmConfig.max_capacity_token_model` / `LlmConfig.compaction_threshold_percent` were **removed** from the top-level.
- `LlmProfile.max_capacity_tokens` / `LlmProfile.compaction_threshold_percent` were added.
- The resolver signature became `maxCapacityForModel(profile, sub_agent, model)` — cascade goes sub-agent → profile → built-in default.
- HTTP wire format: removed the two top-level fields; the `profiles` map carries them through.

**Frontend** (commit `6e3c1180`, Chunk 7.6):
- `api/index.ts`: `NalarConfig.max_capacity_token_model` / `compaction_threshold_percent` removed; `NalarProfile.max_capacity_tokens` / `compaction_threshold_percent` added.
- `CompactionSection.vue`: rewritten to iterate `props.profiles` and render one card per profile. Wired via `:profiles="profilesToRecord(profilesList)"` + `@update:profiles="onCompactionProfilesUpdate"` in `NalarSettings.vue`.
- `NalarSettings.vue`: dropped the standalone `compactionConfig` ref. Wired the Compaction tab via the per-profile path.

The current per-profile-only UX is functional but feels off — the user has to flip tabs to find compaction, and the defaults tab has no compaction inputs at all.

## Goal

1. **Add the two fields back to the top-level** `NalarConfig` AND `LlmConfig` (frontend + backend). Cascade: defaults (top-level) wins first; falls through to per-profile → built-in.
2. **Move the per-row inputs from the Compaction tab** into:
   - The Defaults tab (top-level capacity + threshold inputs).
   - The Edit-profile modal (the same inputs, scoped to that one profile).
3. **Show a compact summary line** on each Profiles-list row so the user can see the current override at-a-glance.
4. **Remove the Compaction tab entirely** from `NalarTabStrip.vue`.

## Architecture

### Cascade order (backend + frontend)

```
sub_agent.compaction_threshold_percent (if non-null)
  → profile.compaction_threshold_percent (if non-null)
  → NalarConfig.compaction_threshold_percent (if non-null)  ← NEW (top-level defaults)
  → 80 (built-in default)
```

Same shape for `max_capacity_tokens`:
```
sub_agent.max_capacity_tokens
  → profile.max_capacity_tokens
  → NalarConfig.max_capacity_token_model  ← NEW (top-level defaults)
  → LLMModels.getModelTokenCount(model)
```

The resolver gains one more optional argument: `defaults: ?*const LlmConfig` (or just `defaults_config: ?DefaultsConfig`, since `DefaultsConfig` is the frontend-side interface — the backend already has full `LlmConfig` access).

### Why this shape works

- **No new HTTP fields required on the PUT side** — the existing `ProfileChange` action path already carries `max_capacity_tokens` and `compaction_threshold_percent` per-profile. The defaults tab restores the top-level fields and the PUT handler can use them.
- **Backward-compatible** — existing `config.json` files that lack the two top-level defaults keys continue to work (the loader drops unknown fields, and `null` is the cascade wildcard).
- **The 4-level cascade** (sub-agent → profile → defaults → built-in) is a natural extension of the existing 3-level cascade. No semantic surprise for users who already read the docs/memory.

## File changes summary

| File | Change | Why |
|------|--------|-----|
| **`src/modules/config/Config.zig`** | Add `max_capacity_token_model` + `compaction_threshold_percent` back to `LlmConfig` + `LlmConfigJson`. Update `init`, `clone`, `defaultConfigJson`. **Update `maxCapacityForModel` and `compactionThresholdPercent` to cascade through a new `defaults: *const LlmConfig` parameter** (or take the resolved value directly). | Restore the top-level defaults. |
| **`src/ai_workflow/tui/workflow.zig`** | Update the call site at line 864 to pass the active chat's profile / sub-agent / defaults lookup. Currently passes `null, null` — needs the real profile lookup. | Per-chat cascade needs the 3-level shape. |
| **`src/ai_workflow/tui/llm_history.zig`** | Same: pass `null, null` is acceptable here (no chat-level resolution needed for the response envelope). | Cascade in the response envelope. |
| **`src/ai_workflow/tui/http_handlers/http_response.zig`** | Add `max_capacity_token_model` + `compaction_threshold_percent` back to `NalarConfigResponse`. | Wire format needs the top-level fields for the Defaults tab to show them. |
| **`src/ai_workflow/tui/http_handlers/nalar_config_get.zig`** | Re-add `.max_capacity_token_model = ...` / `.compaction_threshold_percent = ...` copies from `cfg` → `response`. | GET side populates the new fields. |
| **`src/ai_workflow/tui/http_handlers/nalar_config_put.zig`** | Re-add the `if (input.max_capacity_token_model) |mc| { ... }` / `if (input.compaction_threshold_percent) |tp| { ... tp > 100 ... }` apply blocks. Re-add the two fields to `ConfigInput` and the inner `ConfigJson`. | PUT side accepts top-level defaults again. |
| **`src/modules/config/config_test.zig`** | Re-add the 4 round-trip tests for top-level defaults. Add a cascade test: defaults+profile override, profile wins. | Cascading test coverage. |
| **`src/ai_workflow/tui/compaction_config_threshold_test.zig`** | Update the existing 5 tests to include top-level defaults in the cascade. Add a cascade test: defaults(50%) + profile(90%) → resolver returns 90. | Cascading test coverage. |
| **`src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig`** | Re-add the 4 static-contract tests for the top-level apply blocks. | PUT handler still has the top-level path. |
| **`src/apps/desktop/src/api/index.ts`** | Re-add `max_capacity_token_model` + `compaction_threshold_percent` to `NalarConfig` (top-level). Keep them on `NalarProfile` (per-profile). | Wire format matches backend. |
| **`src/apps/desktop/src/components/nalar/DefaultsSection.vue`** | Add the 2 fields to the DefaultsConfig interface (re-introduce the v-model split). Add the 2 inputs to the template as a new "Compaction defaults" subsection (between Model parameters and System prompt). | User requirement: compaction inputs in Defaults tab. |
| **`src/apps/desktop/src/components/nalar/LlmConfigForm.vue`** | Add the 2 fields to `LlmConfig` (extend the existing v-model shape). Add the 2 inputs as a new "Compaction overrides" subsection at the bottom of the form. | User requirement: compaction in Edit profile modal. |
| **`src/apps/desktop/src/components/nalar/ProfilesSection.vue`** | Add a compact summary line under each profile row showing the resolved compaction (e.g. "Compaction: 80% @ 500k tokens" or "Compaction: default (80% @ 500k)" when no override). The actual editing happens via the existing Edit button → modal. | User requirement: compaction visible in the row. |
| **`src/apps/desktop/src/components/NalarSettings.vue`** | Drop the dedicated `compactionConfig` ref + `onCompactionProfilesUpdate` handler + the `<CompactionSection>` mount. The compaction fields now live in the `defaultsConfig` ref (for top-level) and in the `profilesList.value[].max_capacity_tokens` + `.compaction_threshold_percent` fields (for per-profile). Wire those directly. | Remove the Compaction tab from the orchestrator. |
| **`src/apps/desktop/src/components/nalar/NalarTabStrip.vue`** | Remove the `'compaction'` tab from the `tabs` array. Keep `'defaults' \| 'profiles' \| 'sub-agents' \| 'mcp'`. | Remove the tab from the strip. |
| **`src/apps/desktop/src/components/nalar/CompactionSection.vue`** | **Delete the file**. | The component is no longer needed. |
| **`src/apps/desktop/src/__tests__/CompactionSection.spec.ts`** | **Delete the file**. | No more CompactionSection. |
| **`src/apps/desktop/src/__tests__/DefaultsSection.spec.ts`** | Add tests for the compaction fields in the Defaults tab. | Regression coverage. |
| **`src/apps/desktop/src/__tests__/LlmConfigForm.spec.ts`** | Add tests for the compaction fields in the profile form. | Regression coverage. |
| **`src/apps/desktop/src/__tests__/NalarSettings.spec.ts`** | Update the test that counted 5 tabs → it should now be 4. | Match the new tab count. |
| **`src/apps/desktop/src/__tests__/NalarTabStrip.spec.ts`** | Update the test that expected 5 tabs → it should now be 4. Add a sanity test that the `compaction` tab id is gone. | Match the new tab count. |

## Task 8.1 — Backend: restore top-level defaults + 4-level cascade

**Files:**
- Modify: `src/modules/config/Config.zig`
- Modify: `src/ai_workflow/tui/workflow.zig`
- Modify: `src/ai_workflow/tui/llm_history.zig`
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig`
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_get.zig`
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put.zig`
- Modify: `src/modules/config/config_test.zig`
- Modify: `src/ai_workflow/tui/compaction_config_threshold_test.zig`
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig`

- [ ] **Step 8.1.1: Add the two fields back to `LlmConfig` + `LlmConfigJson`**

In `Config.zig`, after the existing `notify_on_complete` field on `LlmConfig` (line 30), re-add:

```zig
/// Optional top-level override for the context window (in tokens).
/// `null` = use the built-in `LLMModels.getModelTokenCount(model)`
/// default. Profiles can override this (see `LlmProfile.max_capacity_tokens`).
max_capacity_token_model: ?u32,
/// Optional top-level compaction threshold as a percentage (0-100).
/// `null` = use the historical default of 80. Profiles can override
/// this (see `LlmProfile.compaction_threshold_percent`).
compaction_threshold_percent: ?u8,
```

Also re-add the corresponding fields to `LlmConfigJson` (around line 175 in the original), and to `defaultConfigJson` (around line 1184). Update `init` + `clone` + `LlmConfig.maxCapacityForModel` + `compactionThresholdPercent` to materialize them.

- [ ] **Step 8.1.2: Update the resolvers to cascade through the new defaults**

Change the resolver signatures from `(profile, sub_agent)` to `(profile, sub_agent, defaults)` where `defaults: *const LlmConfig`:

```zig
pub fn maxCapacityForModel(
    self: *const LlmConfig,
    profile: ?*const LlmProfile,
    sub_agent: ?*const SubAgentConfig,
    model_name: []const u8,
) u32 {
    _ = self;
    if (sub_agent) |sa| if (sa.max_capacity_tokens) |override| return override;
    if (profile) |p| if (p.max_capacity_tokens) |override| return override;
    if (self.max_capacity_token_model) |override| return override;
    return LLMModels.getModelTokenCount(model_name);
}

pub fn compactionThresholdPercent(
    self: *const LlmConfig,
    profile: ?*const LlmProfile,
    sub_agent: ?*const SubAgentConfig,
) u8 {
    _ = self;
    if (sub_agent) |sa| if (sa.compaction_threshold_percent) |override| return override;
    if (profile) |p| if (p.compaction_threshold_percent) |override| return override;
    if (self.compaction_threshold_percent) |override| return override;
    return 80;
}
```

Note: `self` is now used (cascade through the top-level defaults), so the `_ = self` cast disappears.

- [ ] **Step 8.1.3: Update the resolver call sites**

In `workflow.zig:864`, the call site is currently:

```zig
llm_config.maxCapacityForModel(null, null, model),
llm_config.compactionThresholdPercent(null, null),
```

Change to pass the active profile + sub-agent lookups (already in scope inside `maybeCompactMessagesNew`). If they're not in scope, defer to plan-aware threading (out of scope for this chunk; pass `cfg` itself as the 3rd arg and resolve inside the call):

```zig
// Pass *const LlmConfig as the defaults arg; profile / sub_agent
// threading requires plan-aware resolution (deferred).
const max_capacity = llm_config.maxCapacityForModel(null, null, llm_config, model);
const threshold = llm_config.compactionThresholdPercent(null, null, llm_config);
```

In `llm_history.zig:691`, the same call-site update. (Per-chat resolution is a separate follow-up — for now, just pass the cfg as defaults so the cascade reaches the new field.)

- [ ] **Step 8.1.4: Update `http_response.zig`**

Re-add the two top-level fields to `NalarConfigResponse` (after `model_compaction_size_kb`):

```zig
/// Optional override for the model's context window in tokens.
/// `null` = fall through to per-profile override, then built-in.
max_capacity_token_model: ?u32 = null,
/// Compaction threshold percentage (0-100).
/// `null` = fall through to per-profile override, then built-in 80.
compaction_threshold_percent: ?u8 = null,
```

- [ ] **Step 8.1.5: Update `nalar_config_get.zig`**

Re-add the two `.max_capacity_token_model = cfg.max_capacity_token_model` copies (after the existing `model_compaction_size_kb` line). Re-add the two fields to the inner `ConfigJson` struct.

- [ ] **Step 8.1.6: Update `nalar_config_put.zig`**

Re-add the `if (input.max_capacity_token_model) |mc| { ... }` and `if (input.compaction_threshold_percent) |tp| { if (tp > 100) return error.InvalidThresholdPercent; ... }` apply blocks. Re-add the two fields to `ConfigInput`. **Keep** the existing per-profile `max_capacity_tokens` + `compaction_threshold_percent` fields on `ProfileChange` (those are independent — both layers coexist).

- [ ] **Step 8.1.7: Re-add the 4 round-trip tests in `config_test.zig`**

Restore the 2 round-trip tests for top-level defaults (`config_test.zig` lines 1246/1260/1273/1287). Add a new "cascade" test that sets BOTH defaults + profile override and verifies the profile wins:

```zig
test "LlmConfig: top-level defaults cascade — profile override wins" {
    const json =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "max_capacity_token_model": 200000,
        \\  "compaction_threshold_percent": 70,
        \\  "profiles_models": { "default": { "model": "MiniMax-M3", "max_capacity_tokens": 600000, "compaction_threshold_percent": 90 } } }
    ;
    var cfg = try writeAndRead(...);
    defer cfg.deinit();
    // Profile override (600_000) wins over top-level defaults (200_000).
    try std.testing.expectEqual(@as(u32, 600000),
        cfg.maxCapacityForModel(profile, null, &cfg, "MiniMax-M3"));
    // Without profile, top-level defaults (200_000) apply.
    try std.testing.expectEqual(@as(u32, 200000),
        cfg.maxCapacityForModel(null, null, &cfg, "MiniMax-M3"));
}
```

- [ ] **Step 8.1.8: Update `compaction_config_threshold_test.zig`**

Add cascade test for top-level defaults. The existing tests continue to work after `makeLlmConfig` is updated to populate `max_capacity_token_model` + `compaction_threshold_percent` on the `LlmConfig` literal.

- [ ] **Step 8.1.9: Re-add the 4 static-contract tests in `nalar_config_put_test.zig`**

Restore the 2-3 tests for the top-level PUT apply blocks (lines 237/251/263/285 in the original). Add a test that the top-level `max_capacity_token_model` field is NOT written to per-profile JSON.

- [ ] **Step 8.1.10: Backend verification**

```bash
cd .worktrees/config-compact && timeout 240 zig build test --summary all 2>&1 | tail -n 10
# Expected: ~1000+ pass (was 991; +9 from new cascade tests).

cd .worktrees/config-compact && timeout 240 zig build install:linux:system 2>&1 | tail -n 5
# Expected: 4/6 steps succeeded (cp step fails harmlessly).
```

If `install:linux:system` compile fails, also fix any other call sites I missed with `rg "maxCapacityForModel\|compactionThresholdPercent"`.

## Task 8.2 — Frontend types: re-add top-level fields

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 8.2.1: Re-add the two top-level fields to `NalarConfig`**

In `api/index.ts`, after `model_compaction_size_kb`, re-add:

```typescript
/**
 * Optional top-level override for the model's context window in tokens.
 * When null, the per-profile override (or built-in default) applies.
 */
max_capacity_token_model?: number | null
/**
 * Top-level compaction threshold as a percentage (0-100).
 * When null, the per-profile override (or built-in 80) applies.
 */
compaction_threshold_percent?: number | null
```

Keep the per-profile fields on `NalarProfile` (already there from Chunk 7.6).

- [ ] **Step 8.2.2: Type-check verification**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10
# Expected: 0 errors (frontend types still align, but unused top-level
# fields won't error).
```

## Task 8.3 — Frontend: add compaction inputs to Defaults tab

**Files:**
- Modify: `src/apps/desktop/src/components/nalar/DefaultsSection.vue`
- Modify: `src/apps/desktop/src/components/NalarSettings.vue` (defaultsConfig ref)

- [ ] **Step 8.3.1: Add the 2 fields to the `DefaultsConfig` interface**

In `DefaultsSection.vue`, add to the `DefaultsConfig` interface:

```typescript
max_capacity_token_model: number | null
compaction_threshold_percent: number | null
```

- [ ] **Step 8.3.2: Add a "Compaction defaults" subsection to the template**

Insert after the "Model parameters" section, before "System prompt":

```vue
<section>
  <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Compaction defaults ──</h3>
  <div class="space-y-4">
    <div>
      <label class="flex items-start gap-2 cursor-pointer text-sm">
        <input
          type="checkbox"
          :checked="modelValue.max_capacity_token_model !== null"
          @change="setCapacityOverride(($event.target as HTMLInputElement).checked)"
          class="w-4 h-4 mt-0.5"
          style="accent-color: var(--color-violet);"
          data-testid="defaults-capacity-override-checkbox"
        />
        <span>
          <span :style="labelStyle">Override the model's context window for all profiles</span>
          <span class="block text-xs mt-0.5" :style="helperStyle">
            Sets <code class="font-mono">max_capacity_token_model</code> in config.json.
            Profiles can override this in their own compaction settings.
          </span>
        </span>
      </label>
    </div>

    <div :class="{ 'opacity-50 pointer-events-none': modelValue.max_capacity_token_model === null }">
      <label :class="labelBase" :style="labelStyle">Max capacity (tokens)</label>
      <input
        :value="defaultsCapacityDisplay"
        @input="setDefaultsCapacity(($event.target as HTMLInputElement).value)"
        type="number"
        min="0"
        step="1000"
        placeholder="500000"
        :class="inputBase"
        :style="inputStyle"
        :disabled="modelValue.max_capacity_token_model === null"
        data-testid="defaults-capacity-input"
      />
    </div>

    <div>
      <label class="flex items-start gap-2 cursor-pointer text-sm">
        <input
          type="checkbox"
          :checked="modelValue.compaction_threshold_percent !== null"
          @change="setThresholdOverride(($event.target as HTMLInputElement).checked)"
          class="w-4 h-4 mt-0.5"
          style="accent-color: var(--color-violet);"
          data-testid="defaults-threshold-override-checkbox"
        />
        <span>
          <span :style="labelStyle">Override the compaction threshold for all profiles</span>
          <span class="block text-xs mt-0.5" :style="helperStyle">
            Sets <code class="font-mono">compaction_threshold_percent</code> in config.json.
            Profiles can override this in their own compaction settings.
          </span>
        </span>
      </label>
    </div>

    <div :class="{ 'opacity-50 pointer-events-none': modelValue.compaction_threshold_percent === null }">
      <div class="flex items-center justify-between mb-1.5">
        <label :class="labelBase" :style="labelStyle" class="!mb-0">Threshold (%)</label>
        <span class="font-mono text-xs" :style="labelStyle">{{ defaultsThresholdDisplay }}</span>
      </div>
      <input
        :value="defaultsThresholdDisplay"
        @input="setDefaultsThreshold(parseFloat(($event.target as HTMLInputElement).value))"
        type="range"
        min="0"
        max="100"
        step="1"
        class="w-full"
        :disabled="modelValue.compaction_threshold_percent === null"
        data-testid="defaults-threshold-slider"
      />
      <div class="flex justify-between text-xs mt-1 font-mono" :style="helperStyle">
        <span>Never</span>
        <span>80% (default)</span>
        <span>Always</span>
      </div>
    </div>
  </div>
</section>
```

- [ ] **Step 8.3.3: Add the 4 setter functions in `<script setup>`**

After the existing `systemPromptTokens` computed, add:

```typescript
const defaultsCapacityDisplay = computed<string>({
  get: () => props.modelValue.max_capacity_token_model === null
    ? ''
    : String(props.modelValue.max_capacity_token_model),
  set: (raw) => {
    const trimmed = raw.trim()
    if (trimmed === '') return  // ignore transient empty
    const parsed = Number(trimmed)
    if (!Number.isFinite(parsed) || parsed < 0) return
    update('max_capacity_token_model', Math.floor(parsed))
  },
})

const defaultsThresholdDisplay = computed<number>({
  get: () => props.modelValue.compaction_threshold_percent ?? 80,
  set: (v) => {
    if (!Number.isFinite(v)) return
    update('compaction_threshold_percent', Math.max(0, Math.min(100, Math.floor(v))))
  },
})

function setCapacityOverride(on: boolean) {
  update('max_capacity_token_model', on ? (props.modelValue.max_capacity_token_model ?? 500000) : null)
}
function setThresholdOverride(on: boolean) {
  update('compaction_threshold_percent', on ? (props.modelValue.compaction_threshold_percent ?? 80) : null)
}
function setDefaultsCapacity(raw: string) {
  defaultsCapacityDisplay.value = raw  // bound to setter via computed
}
function setDefaultsThreshold(v: number) {
  defaultsThresholdDisplay.value = v
}
```

- [ ] **Step 8.3.4: Update `NalarSettings.vue` to populate the new fields**

In `syncFromConfig()`, after `notify_on_complete: c.notify_on_complete ?? false,`, add:

```typescript
max_capacity_token_model: c.max_capacity_token_model ?? null,
compaction_threshold_percent: c.compaction_threshold_percent ?? null,
```

- [ ] **Step 8.3.5: Update `syncToConfig()` to emit the new fields**

Replace the `(compactionConfig.value ? {...} : {})` block (already removed in Chunk 7.6) with:

```typescript
// Compaction defaults — written back to the top-level LlmConfig fields.
// (Per-profile compaction overrides are emitted via profilesList below.)
...{
  max_capacity_token_model: d.max_capacity_token_model,
  compaction_threshold_percent: d.compaction_threshold_percent,
},
```

The spread is unconditional — `null` is a valid value that the backend stores verbatim.

- [ ] **Step 8.3.6: Delete `CompactionSection.vue` (no longer needed)**

```bash
cd .worktrees/config-compact && timeout 5 git rm src/apps/desktop/src/components/nalar/CompactionSection.vue
```

- [ ] **Step 8.3.7: Delete `CompactionSection.spec.ts` (no longer needed)**

```bash
cd .worktrees/config-compact && timeout 5 git rm src/apps/desktop/src/__tests__/CompactionSection.spec.ts
```

- [ ] **Step 8.3.8: Remove the Compaction tab from `NalarTabStrip.vue`**

In `NalarTabStrip.vue`:

```typescript
// Replace:
type TabId = 'defaults' | 'profiles' | 'sub-agents' | 'mcp' | 'compaction'
const tabs = [{ id: 'defaults', ... }, ..., { id: 'compaction', label: 'Compaction' }]

// With:
type TabId = 'defaults' | 'profiles' | 'sub-agents' | 'mcp'
const tabs = [
  { id: 'defaults', label: 'Defaults' },
  { id: 'profiles', label: 'Profiles' },
  { id: 'sub-agents', label: 'Sub-agents' },
  { id: 'mcp', label: 'MCP Servers' },
]
```

- [ ] **Step 8.3.9: Remove the `<CompactionSection>` mount from `NalarSettings.vue`**

In the template (line 509), delete:

```vue
<CompactionSection
  v-else-if="activeTab === 'compaction'"
  :profiles="profilesToRecord(profilesList)"
  @update:profiles="onCompactionProfilesUpdate"
/>
```

Also remove the import (line 21), the `onCompactionProfilesUpdate` function (lines 188-203), and the unused `CompactionConfig` type import.

- [ ] **Step 8.3.10: Frontend verification**

```bash
cd src/apps/desktop && timeout 240 bun run build 2>&1 | tail -n 5
# Expected: 0 errors.

cd src/apps/desktop && timeout 120 bunx vitest run DefaultsSection NalarSettings NalarTabStrip LlmConfigForm ProfilesSection 2>&1 | tail -n 5
# Expected: 4 component test files, all green (modulo the 8
# pre-existing failures noted in project memory).
```

## Task 8.4 — Frontend: add compaction inputs to Edit-profile modal

**Files:**
- Modify: `src/apps/desktop/src/components/nalar/LlmConfigForm.vue`
- Modify: `src/apps/desktop/src/components/nalar/LlmConfigModal.vue` (errors type)
- Modify: `src/apps/desktop/src/components/nalar/ProfileModal.vue` (passthrough)

- [ ] **Step 8.4.1: Add the 2 fields to the `LlmConfig` interface in `LlmConfigForm.vue`**

In `LlmConfigForm.vue`, after the `api_key` field:

```typescript
export interface LlmConfig {
  // ... existing
  /// Optional override for THIS PROFILE's context window (in tokens).
  /// null = fall through to top-level defaults → built-in.
  max_capacity_tokens: number | null
  /// Optional override for THIS PROFILE's compaction threshold (0-100).
  /// null = fall through to top-level defaults → built-in 80.
  compaction_threshold_percent: number | null
}
```

- [ ] **Step 8.4.2: Add a "Compaction overrides" subsection to the form template**

After the API-key section:

```vue
<section>
  <h3 :class="labelBase" :style="labelStyle">── Compaction overrides ──</h3>
  <div class="space-y-3 mt-2">
    <div>
      <label class="flex items-start gap-2 cursor-pointer text-sm">
        <input
          type="checkbox"
          :checked="modelValue.max_capacity_tokens !== null"
          @change="setCapacityOverride(($event.target as HTMLInputElement).checked)"
          class="w-4 h-4 mt-0.5"
          style="accent-color: var(--color-violet);"
          data-testid="profile-capacity-override-checkbox"
        />
        <span>
          <span :style="labelStyle">Override the context window</span>
          <span class="block text-xs mt-0.5" :style="helperStyle">
            Falls back to top-level defaults → built-in.
          </span>
        </span>
      </label>
    </div>
    <div :class="{ 'opacity-50 pointer-events-none': modelValue.max_capacity_tokens === null }">
      <label :class="labelBase" :style="labelStyle">Max capacity (tokens)</label>
      <input
        :value="capacityDisplay"
        @input="setCapacity(($event.target as HTMLInputElement).value)"
        type="number"
        min="0"
        step="1000"
        placeholder="500000"
        :class="inputBase"
        :style="inputStyle(!!errors?.max_capacity_tokens)"
        :disabled="modelValue.max_capacity_tokens === null"
        data-testid="profile-capacity-input"
      />
    </div>
    <div>
      <label class="flex items-start gap-2 cursor-pointer text-sm">
        <input
          type="checkbox"
          :checked="modelValue.compaction_threshold_percent !== null"
          @change="setThresholdOverride(($event.target as HTMLInputElement).checked)"
          class="w-4 h-4 mt-0.5"
          style="accent-color: var(--color-violet);"
          data-testid="profile-threshold-override-checkbox"
        />
        <span>
          <span :style="labelStyle">Override the compaction threshold</span>
          <span class="block text-xs mt-0.5" :style="helperStyle">
            Falls back to top-level defaults → built-in 80.
          </span>
        </span>
      </label>
    </div>
    <div :class="{ 'opacity-50 pointer-events-none': modelValue.compaction_threshold_percent === null }">
      <div class="flex items-center justify-between mb-1.5">
        <label :class="labelBase" :style="labelStyle" class="!mb-0">Threshold (%)</label>
        <span class="font-mono text-xs" :style="labelStyle">{{ thresholdDisplay }}</span>
      </div>
      <input
        :value="thresholdDisplay"
        @input="setThreshold(parseFloat(($event.target as HTMLInputElement).value))"
        type="range"
        min="0"
        max="100"
        step="1"
        class="w-full"
        :disabled="modelValue.compaction_threshold_percent === null"
        data-testid="profile-threshold-slider"
      />
    </div>
  </div>
</section>
```

- [ ] **Step 8.4.3: Add the setter / display computeds in `<script setup>`**

```typescript
const capacityDisplay = computed<string>({
  get: () => props.modelValue.max_capacity_tokens === null ? '' : String(props.modelValue.max_capacity_tokens),
  set: (raw) => {
    const trimmed = raw.trim()
    if (trimmed === '') return
    const parsed = Number(trimmed)
    if (!Number.isFinite(parsed) || parsed < 0) return
    update('max_capacity_tokens', Math.floor(parsed))
  },
})
const thresholdDisplay = computed<number>({
  get: () => props.modelValue.compaction_threshold_percent ?? 80,
  set: (v) => {
    if (!Number.isFinite(v)) return
    update('compaction_threshold_percent', Math.max(0, Math.min(100, Math.floor(v))))
  },
})
function setCapacityOverride(on: boolean) {
  update('max_capacity_tokens', on ? (props.modelValue.max_capacity_tokens ?? 500000) : null)
}
function setThresholdOverride(on: boolean) {
  update('compaction_threshold_percent', on ? (props.modelValue.compaction_threshold_percent ?? 80) : null)
}
function setCapacity(raw: string) { capacityDisplay.value = raw }
function setThreshold(v: number) { thresholdDisplay.value = v }
```

- [ ] **Step 8.4.4: Update `LlmConfigModal.vue` to pass through the new fields**

The errors type needs `max_capacity_tokens` and `compaction_threshold_percent` as optional string fields:

```typescript
errors?: { name?: string; model?: string; base_url?: string; api_key?: string; max_capacity_tokens?: string; compaction_threshold_percent?: string }
```

The template's `LlmConfigForm` already binds via `update:modelValue="updateConfig"` which spreads the whole object — no other change needed in the modal.

- [ ] **Step 8.4.5: Verify profile-modal data flow**

In `NalarSettings.vue`, when a profile is edited, the modal value includes the 2 new fields. Add them to the ProfileRow literal at line 118:

```typescript
profilesList.value = Object.entries(c.profiles ?? {}).map(([name, p]) => ({
  name,
  model: p.model ?? '',
  base_url: p.base_url ?? '',
  thinking: p.thinking ?? 'auto',
  temperature: p.temperature ?? 'auto',
  url_style: p.url_style ?? 'openai',
  api_key: p.api_key ?? '',
  sub_agents: p.sub_agents ?? [],
  max_capacity_tokens: p.max_capacity_tokens ?? null,
  compaction_threshold_percent: p.compaction_threshold_percent ?? null,
}))
```

(If Chunk 7.6's commit `6e3c1180` already added these two fields — check the current state before re-adding.)

## Task 8.5 — Frontend: compaction summary on Profiles list rows

**Files:**
- Modify: `src/apps/desktop/src/components/nalar/ProfilesSection.vue`

- [ ] **Step 8.5.1: Add a "Compaction" line under the existing sub-agents summary**

In `ProfilesSection.vue`, after the existing `<div class="text-xs font-mono mt-1">` that shows the sub-agents summary, add:

```vue
<div class="text-xs font-mono mt-0.5 truncate" style="color: var(--semantic-text-dim);">
  Compaction: {{ compactionSummary(profile) }}
</div>
```

- [ ] **Step 8.5.2: Add the `compactionSummary` helper in `<script setup>`**

```typescript
function compactionSummary(profile: ProfileRow): string {
  const cap = profile.max_capacity_tokens
  const thr = profile.compaction_threshold_percent
  const capStr = cap === null || cap === undefined ? 'default' : `${(cap / 1000).toFixed(0)}k tokens`
  const thrStr = thr === null || thr === undefined ? '80%' : `${thr}%`
  return `${thrStr} @ ${capStr}`
}
```

(The exact wording is a UX choice — pick a string that fits the user's screenshot style. The user might prefer "Capacity: 500k · Threshold: 80%" or similar.)

## Task 8.6 — Frontend: update tests for the new shape

- [ ] **Step 8.6.1: Update `DefaultsSection.spec.ts`**

Add tests for the 4 new inputs (override-checkbox + value-input for each of capacity + threshold). Use the pattern from `CompactionSection.spec.ts` (override on/off, value clamping).

- [ ] **Step 8.6.2: Update `LlmConfigForm.spec.ts`**

Add tests for the 2 new fields in the profile form. Mirror the DefaultsSection tests.

- [ ] **Step 8.6.3: Update `NalarSettings.spec.ts`**

Update the test that expected 5 tabs / 5 test ids → it should now expect 4.

- [ ] **Step 8.6.4: Update `NalarTabStrip.spec.ts`**

Update similarly. Add a regression assertion: `expect(tabs.some(t => t.id === 'compaction')).toBe(false)`.

- [ ] **Step 8.6.5: Run the full frontend test suite**

```bash
cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 10
# Expected: 1086+ tests, 8 pre-existing failures (KanbanView, etc.).
```

## Task 8.7 — End-to-end verification

- [ ] **Step 8.7.1: Backend tests**

```bash
cd .worktrees/config-compact && timeout 240 zig build test --summary all 2>&1 | tail -n 5
```

Expected: ~1000+ tests pass, 3 skipped, 0 failures (or up to 5 pre-existing migration-test skips). Wallclock ~2-3s.

- [ ] **Step 8.7.2: Backend production compile**

```bash
cd .worktrees/config-compact && timeout 240 zig build install:linux:system 2>&1 | tail -n 5
```

Expected: `4/6 steps succeeded` (cp step fails harmlessly with `permission denied` writing to `/usr/local/bin/nalar`).

- [ ] **Step 8.7.3: Frontend type-check + build**

```bash
cd src/apps/desktop && timeout 240 bun run build 2>&1 | tail -n 5
```

Expected: 0 type errors. Vite build emits `dist/`.

- [ ] **Step 8.7.4: Manual smoke test**

```bash
env -i HOME=/tmp/nalar-fresh-test PATH=$PATH \
  .worktrees/config-compact/zig-out/bin/nalar --port 18080 &
sleep 3

# Create with BOTH defaults + per-profile override.
curl -X PUT http://127.0.0.1:18080/api/config/nalar \
  -H "Content-Type: application/json" \
  -d '{
    "api_key": "test", "model": "m", "base_url": "b",
    "max_capacity_token_model": 200000,
    "compaction_threshold_percent": 70,
    "profiles": {
      "dev":  {"model": "m", "max_capacity_tokens": 500000, "compaction_threshold_percent": 50},
      "prod": {"model": "m", "max_capacity_tokens": null,     "compaction_threshold_percent": null}
    }
  }'

# GET and confirm the shape.
curl http://127.0.0.1:18080/api/config/nalar

# Confirm cascade: dev profile (500k @ 50%) wins over defaults (200k @ 70%).
# prod profile uses defaults (200k @ 70%) because its override is null.
# Expect in the GET:
#   max_capacity_token_model: 200000     ← defaults present
#   compaction_threshold_percent: 70     ← defaults present
#   profiles.dev.max_capacity_tokens: 500000   ← per-profile
#   profiles.dev.compaction_threshold_percent: 50   ← per-profile
#   profiles.prod.max_capacity_tokens: null  ← falls back to defaults

kill $!
```

## Task 8.8 — Commit + PR

- [ ] **Step 8.8.1: Atomic commit**

```bash
cd .worktrees/config-compact
git add -A
git commit -m "feat: inline compaction settings into Defaults + Edit-profile (rescues top-level cascade)

User feedback: the per-profile Compaction tab (Chunk 7.6, commit
6e3c1180) forced users to flip tabs to find compaction, and left
the Defaults tab without any capacity/threshold inputs. Move the
settings back to where they belong:
- Defaults tab (top-level 'DEFAULT LLM' form): NEW subsection
  'Compaction defaults' with capacity + threshold override inputs.
- Edit-profile modal: NEW subsection 'Compaction overrides' with
  the same inputs (overrides per-profile).
- Profiles list row: NEW compact summary line showing the
  effective compaction (e.g. '80% @ 500k tokens' or 'default').

The Compaction top-level tab is REMOVED from NalarTabStrip; the
CompactionSection.vue + its spec are DELETED.

Backend change: restore LlmConfig.max_capacity_token_model +
LlmConfig.compaction_threshold_percent (top-level cascade level
between per-profile and built-in). The resolver cascade becomes:
sub-agent > profile > top-level defaults > built-in.

Tests:
- Backend: 991 → ~1005 pass (9 new: 4 round-trip + 4 cascade +
  1 static-contract).
- Frontend: 1086 → ~1100 pass (12 moved tests + 8 new).

See docs/superpowers/plans/2026-07-07-compaction-inline.md for
the full task breakdown."
git push origin worktree/config-compact
```

## Acceptance criteria

1. The Defaults tab has a "Compaction defaults" subsection with override-checkbox + capacity-input + threshold-slider per the same pattern as the Model parameters section.
2. The Edit-profile modal has a "Compaction overrides" subsection below the API key input.
3. The Profiles list row shows a compact summary line for compaction (e.g. `80% @ 500k tokens`).
4. The top-level `Compaction` tab is gone (4 tabs total: Defaults, Profiles, Sub-agents, MCP Servers).
5. The backend cascade is: sub-agent → profile → top-level defaults → built-in. Verified by unit tests.
6. `bun run build` → 0 type errors.
7. `zig build test` → ~1005 tests pass, 0 regressions.
8. Manual smoke test (Step 8.7.4) confirms the wire format round-trips both top-level defaults AND per-profile overrides correctly.

## Risks and unknowns

- **The `self.max_capacity_token_model` cascade depends on `*const LlmConfig`** — the resolver signature changes from 2-arg to 3-arg (`profile, sub_agent, defaults`). Every call site needs updating. There are 2 call sites (`workflow.zig`, `llm_history.zig`); `llm_history.zig` only passes nulls for both, so the 3rd arg is added without behavior change. `workflow.zig` is the critical one — it currently passes `null, null` and needs the active profile threaded in (deferred per the comment in Step 8.1.3).
- **Per-chat profile resolution** is required for the cascade to actually flow from top-level defaults down through the active profile. This plan defers per-chat threading (out of scope). The wire format already supports it; the resolver just doesn't reach into the chat-level profile yet.
- **The `compactionSummary` UX string in Step 8.5.2** is a guess. The user may prefer a different presentation (separate capacity + threshold lines, icon, etc.). Implement and adjust per their feedback.
- **The `defaultsConfig.value.max_capacity_token_model` write happens unconditionally**, which means clients that previously omitted this field will now write it back as `null`. This is **not** a breaking change (the field was always there semantically — null is the cascade wildcard). But old `config.json` files with `max_capacity_token_model` missing will now round-trip through the PUT with the explicit `null`. Verified acceptable in Step 8.7.4.

## Out of scope (deferred)

- Per-chat profile resolution in `workflow.zig` (currently passes `null, null`; needs the active profile lookup).
- Sub-agent compaction overrides UI (the backend cascade already handles them; the UI just doesn't expose them). Out of scope for this chunk — users can edit `config.json` for sub-agent overrides.
- Migration test for fresh-DB users (`max_capacity_token_model` defaulted to null in `defaultConfigJson` — backward-compatible).

## Notes for next-agent

- The `CompactionSection.vue` and `__tests__/CompactionSection.spec.ts` files are **deleted** at the end of this plan (Step 8.3.6-7). Do not recreate them.
- The plan-vs-test mismatch you may notice: `LlmConfigForm.spec.ts` is referenced but it might not exist today. If it doesn't exist, skip that test update (it's a new test file to create, not an update).
- The plan-vs-test `defaultsCapacityDisplay` / `defaultsThresholdDisplay` computed properties bind the input's `@change` handler to the computed setter via the `setCapacity(raw: string)` wrapper functions. This pattern is borrowed from the old CompactionSection.vue (Step 8.3.3's commented `setCapacity` wrapper).