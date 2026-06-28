# Nalar Config — `url_style` + `notify_on_complete` + `model_compaction_size_kb` Round-Trip Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `url_style` (Vue-driven bug), `notify_on_complete` (data-loss bug + new UI), and `model_compaction_size_kb` (data-loss bug) round-trip correctly through the `GET /api/config/nalar` ↔ `PUT /api/config/nalar` ↔ `config.json` ↔ typed `LlmConfig` path, AND add a "Notify when response completes" toggle in `NalarSettings.vue` so the user can control `notify_on_complete` from the desktop app.

**Architecture:** (1) Extend the `PUT` parse struct (`ConfigInput`) and the on-disk round-trip struct (`ConfigJson`) in `nalar_config_put.zig` with the three fields, plus the matching handler assignments. (2) Extend the `GET` parse struct in `nalar_config_get.zig` with the two scalar fields and pass them through to the response. (3) Update the frontend `NalarConfig` interface in `api/index.ts`. (4) Add a new `notifyOnComplete` ref in `NalarSettings.vue` plus a labeled checkbox in the Model Parameters section. `model_compaction_size_kb` stays backend-only (advanced setting, no UI). (5) Add regression tests in `config_test.zig` covering the disk→typed path. (6) Smoke-test the end-to-end round trip against `nalar-dev` with an isolated `XDG_CONFIG_HOME`.

**Tech Stack:** Zig 0.15.2 (server), Vue 3 + TypeScript (frontend), `std.json.parseFromSlice` / `std.json.Stringify.valueAlloc`, `std.fs.path.join`, `std.Io.Dir.*`. Test runner: `zig build test:ai_workflow:tui` and `zig build test`. Frontend type-check: `cd src/apps/desktop && bun run build`.

---

## Background

Three related bugs share the same root cause: the PUT/GET handlers' parse structs lag behind the typed `LlmConfig` in `Config.zig`.

| # | Field | In `LlmConfig` (Config.zig) | In PUT `ConfigInput` | In PUT `ConfigJson` (disk format) | In GET `ConfigJson` | In GET response | Effect |
|---|---|---|---|---|---|---|---|
| 1 | `url_style` | ✓ line 23, 91 | ❌ missing | ✓ present (default "openai") | ✓ present | ✓ returned | UI dropdown changes don't persist |
| 2 | `notify_on_complete` | ✓ line 29, 96 | ❌ missing | ❌ missing | ❌ missing | ❌ missing | (a) silently dropped on every save; (b) no UI to control it |
| 3 | `model_compaction_size_kb` | ✓ line 92 | ❌ missing | ❌ missing | ❌ missing | ❌ missing | silently dropped on every save |

The PUT handler parses the existing `config.json` with `ignore_unknown_fields = true` (line 77), so any field whose struct doesn't declare it is silently dropped on the next save. The live-reload path (`nalar_config_put.zig:209-249`) calls `LlmConfig.init` from disk — if the disk lost the field, the new in-memory `LlmConfig` is wrong too, and the next LLM response behaves as if the user's setting was never applied.

The downstream consumer of `notify_on_complete` is `workflow.zig:483` (fires an OS notification when `finish_reason == .stop`). The downstream consumer of `model_compaction_size_kb` is `session_compact.zig:57` (compaction threshold for long sessions). Both are real effects, not dead config.

**Default-value note**: `LlmConfig.notify_on_complete: bool = true` (Config.zig:29) and `LlmConfigJson.notify_on_complete: bool = false` (Config.zig:96) have inconsistent defaults. The `= true` only matters for direct struct construction (e.g. the test helper at `nalar_config_put_test.zig:37`); the `init()` path always uses the JSON-parsed value, which defaults to `false`. The plan preserves this behavior — a brand-new config with no `notify_on_complete` key reads as `false` everywhere. Documented in Pitfalls.

---

## File Structure

| File | Change | Purpose |
|---|---|---|
| `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` | **Modify** (~3 small edits) | Add 3 fields to `ConfigInput`, 3 to `ConfigJson`, 3 if-blocks in the handler |
| `src/ai_workflow/tui/http_handlers/nalar_config_get.zig` | **Modify** (2 small edits) | Add 2 fields to `ConfigJson`; include in response |
| `src/apps/desktop/src/api/index.ts` | **Modify** (1 small edit) | Add `notify_on_complete?: boolean` and `model_compaction_size_kb?: number` to `NalarConfig` interface |
| `src/apps/desktop/src/components/NalarSettings.vue` | **Modify** (4 small edits) | Add `notifyOnComplete` ref, load from GET, send in PUT, add checkbox to template, include in `resetSettings` |
| `src/modules/config/config_test.zig` | **Modify** (2 new tests) | Regression tests for `url_style` and `model_compaction_size_kb` round-trip via `LlmConfig.init` |
| `src/modules/config/Config.zig` | No change | `LlmConfig` and `LlmConfigJson` already declare all 3 fields correctly |
| `src/ai_workflow/tui/http_handlers/nalar_config_put_test.zig` | No change | Existing tests cover `LlmConfigHolder` swap semantics, not the parse struct (per the file's own header) |

---

## Chunk 1: PUT Handler — Wire All Three Fields

### Task 1: Add 3 fields to `ConfigInput`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put.zig:257-276`

- [ ] **Step 1: Locate the `ConfigInput` struct**

Read `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` and find the `ConfigInput` struct (around line 257-276). Current shape:

```zig
const ConfigInput = struct {
    api_endpoint: []const u8 = "",
    api_key: []const u8 = "",
    model: []const u8 = "",
    temperature: f64 = 0.7,
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    profiles: ?[]const ProfileChange = null,
    active_profile: ?[]const u8 = null,
    mcp_servers: ?json.Value = null,
    sub_agents: ?[]const LlmConfig.SubAgentJson = null,
};
```

The parse call uses `ignore_unknown_fields = true` (line 54), so any incoming field whose struct entry doesn't exist is silently discarded. That's the root cause of all three bugs.

- [ ] **Step 2: Add the three new fields**

Insert the three fields. Use `?T` (optional) for `notify_on_complete` and `model_compaction_size_kb` so a missing-from-body request preserves the existing on-disk value (matches the `max_tokens: ?usize = null` pattern at line 262). Use `[]const u8` with default `"openai"` for `url_style` (matches the existing `model` pattern + the `LlmConfigJson` default in `Config.zig:91`). Final struct:

```zig
const ConfigInput = struct {
    api_endpoint: []const u8 = "",
    api_key: []const u8 = "",
    model: []const u8 = "",
    url_style: []const u8 = "openai",
    temperature: f64 = 0.7,
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    profiles: ?[]const ProfileChange = null,
    active_profile: ?[]const u8 = null,
    mcp_servers: ?json.Value = null,
    /// When true, fire an OS-level notification when an LLM response
    /// finishes with `finish_reason == "stop"`. Absent = preserve
    /// existing on-disk value. Mirrors the `LlmConfigJson` default
    /// (`false`) so a brand-new config has notifications off.
    notify_on_complete: ?bool = null,
    /// Threshold (in KB) above which the session compactor is invoked
    /// to shrink the LLM context. Absent = preserve existing on-disk
    /// value. Mirrors the `LlmConfigJson` default (`100`).
    model_compaction_size_kb: ?usize = null,
    sub_agents: ?[]const LlmConfig.SubAgentJson = null,
};
```

- [ ] **Step 3: Verify the edit landed**

Re-read lines 257-295 of `nalar_config_put.zig` and confirm:
- `url_style` sits between `model` and `temperature`
- `notify_on_complete` and `model_compaction_size_kb` sit just before `sub_agents`
- The trailing doc comment on `sub_agents` is still in place
- No other lines were touched

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/nalar_config_put.zig
git commit -m "fix(config): declare url_style, notify_on_complete, model_compaction_size_kb in ConfigInput"
```

---

### Task 2: Add 3 fields to the on-disk `ConfigJson` struct (data-loss fix)

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put.zig:289-306`

- [ ] **Step 1: Locate the on-disk `ConfigJson` struct**

Find the second struct in the file (line 289-306). This is the parse target for the existing `config.json` and the serialize target for the rewrite. Current shape:

```zig
const ConfigJson = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    url_style: []const u8 = "openai",
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,
    mcp_servers: ?json.Value = null,
    sub_agents: ?[]LlmConfig.SubAgentJson = null,
};
```

Note `url_style` is already present (it works for the *write* path, just not the *read* path on `ConfigInput`).

- [ ] **Step 2: Add the two missing fields**

Add `notify_on_complete` and `model_compaction_size_kb`. Use defaults that EXACTLY match `LlmConfigJson` in `Config.zig:92, 96` so the PUT→disk→init round-trip is identity-preserving:

```zig
const ConfigJson = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    url_style: []const u8 = "openai",
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,
    mcp_servers: ?json.Value = null,
    /// Opt-in OS notification flag. Default `false` matches
    /// `LlmConfigJson` (Config.zig:96); a brand-new config has
    /// notifications off.
    notify_on_complete: bool = false,
    /// Compaction threshold in KB. Default `100` matches
    /// `LlmConfigJson` (Config.zig:92).
    model_compaction_size_kb: usize = 100,
    sub_agents: ?[]LlmConfig.SubAgentJson = null,
};
```

- [ ] **Step 3: Verify the edit landed**

Re-read lines 289-315 of `nalar_config_put.zig` and confirm:
- Both new fields are present
- Defaults match the values documented in the comments (`false`, `100`)
- `url_style` is unchanged

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/nalar_config_put.zig
git commit -m "fix(config): preserve notify_on_complete and model_compaction_size_kb across PUT saves"
```

---

### Task 3: Add 3 handler assignments in the PUT request handler

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put.zig:82-97`

- [ ] **Step 1: Locate the "Update with new values" block**

Find the field-assignment block (around lines 82-97). The existing pattern: skip if the input is empty/null (preserve the existing on-disk value), otherwise overwrite. Do NOT free the old `config_json.X` before overwriting — the per-request arena (see the `nalar — Custom HTTP server uses per-request arena allocator` memory) reaps it on request teardown.

- [ ] **Step 2: Insert the three new assignments**

After the `model` block, add `url_style`. After the `system_prompt` block, add `notify_on_complete` and `model_compaction_size_kb`. Final block:

```zig
// Update with new values
if (input.value.api_endpoint.len > 0) {
    config_json.base_url = try allocator.dupe(u8, input.value.api_endpoint);
}
if (input.value.api_key.len > 0) {
    config_json.api_key = try allocator.dupe(u8, input.value.api_key);
}
if (input.value.model.len > 0) {
    config_json.model = try allocator.dupe(u8, input.value.model);
}
if (input.value.url_style.len > 0) {
    config_json.url_style = try allocator.dupe(u8, input.value.url_style);
}
if (input.value.max_tokens) |mt| {
    config_json.max_tokens = mt;
}
if (input.value.system_prompt.len > 0) {
    config_json.system_prompt = try allocator.dupe(u8, input.value.system_prompt);
}
if (input.value.notify_on_complete) |n| {
    config_json.notify_on_complete = n;
}
if (input.value.model_compaction_size_kb) |kb| {
    config_json.model_compaction_size_kb = kb;
}
```

- [ ] **Step 3: Verify the edit landed**

Re-read lines 82-105 of `nalar_config_put.zig` and confirm:
- The new `url_style` block is between the `model` and `max_tokens` blocks
- The new `notify_on_complete` and `model_compaction_size_kb` blocks follow `system_prompt`
- Brace style matches the surrounding code (4-space indent, opening brace on same line as `if`)
- No other lines were touched

- [ ] **Step 4: Build to confirm the handler still compiles**

Run: `timeout 180 zig build install:linux 2>&1 | tail -n 20`
Expected: build succeeds. If it fails, the most likely causes are a typo in a new field name or a missing semicolon — re-check Step 2.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/nalar_config_put.zig
git commit -m "fix(config): apply url_style, notify_on_complete, model_compaction_size_kb in PUT handler"
```

---

## Chunk 2: GET Handler — Return the Two Scalar Fields

### Task 4: Add 2 fields to the GET parse struct

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_get.zig:116-137`

- [ ] **Step 1: Locate the GET `ConfigJson` struct**

Find the file-private parse struct (around line 116-137). Current shape:

```zig
const ConfigJson = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    url_style: []const u8 = "openai",
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    temperature: json.Value = .null,
    thinking: json.Value = .null,
    mcp_servers: ?json.Value = null,
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,
    sub_agents: ?[]const LlmConfig.SubAgentJson = null,
};
```

- [ ] **Step 2: Add the two new fields**

Insert `notify_on_complete` and `model_compaction_size_kb` between `sub_agents` and the closing brace. Defaults match `LlmConfigJson`:

```zig
const ConfigJson = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    url_style: []const u8 = "openai",
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    temperature: json.Value = .null,
    thinking: json.Value = .null,
    mcp_servers: ?json.Value = null,
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,
    sub_agents: ?[]const LlmConfig.SubAgentJson = null,
    /// Opt-in OS notification flag (see LlmConfigJson in Config.zig).
    notify_on_complete: bool = false,
    /// Compaction threshold in KB (see LlmConfigJson in Config.zig).
    model_compaction_size_kb: usize = 100,
};
```

- [ ] **Step 3: Verify the edit landed**

Re-read lines 116-145 of `nalar_config_get.zig` and confirm:
- Both new fields are present
- Defaults match `LlmConfigJson` (`false` and `100`)
- `url_style` is unchanged

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/nalar_config_get.zig
git commit -m "fix(config): declare notify_on_complete and model_compaction_size_kb in GET parse struct"
```

---

### Task 5: Include the new fields in the GET response

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_get.zig:98-113` (response struct definition) and `src/ai_workflow/tui/http_handlers/http_response.zig:138-156` (response shape)

- [ ] **Step 1: Add the fields to `NalarConfigResponse`**

Read `src/ai_workflow/tui/http_handlers/http_response.zig` around line 138-156. The response struct is the wire contract — both sides need to match. Add the two fields:

```zig
pub const NalarConfigResponse = struct {
    api_endpoint: []const u8,
    api_key: []const u8,
    model: []const u8,
    url_style: []const u8,
    temperature: f64,
    max_tokens: ?usize,
    system_prompt: []const u8,
    profiles: ?std.json.Value = null,
    active_profile: ?[]const u8 = null,
    /// Map of MCP server name to its raw JSON config (`{"url": "...", "headers": {...}}`).
    /// Sent as-is so the frontend gets full fidelity (header values, etc.).
    mcp_servers: ?std.json.Value = null,
    /// Top-level sub-agents. Each entry carries the full LLM
    /// configuration (model, base_url, thinking, temperature, url_style,
    /// api_key) plus a `system_prompt`. Borrowed slices — the caller
    /// must keep the source alive until the response is serialized.
    sub_agents: ?[]const SubAgentResponse = null,
    /// Opt-in OS notification flag. When true, the backend fires
    /// `notify-send` / osascript / PowerShell when an LLM response
    /// completes with `finish_reason == "stop"`. Consumed by
    /// `workflow.zig:483`.
    notify_on_complete: bool = false,
    /// Compaction threshold in KB. Sessions whose DB-stored token
    /// estimate exceeds this value trigger context compaction.
    /// Consumed by `session_compact.zig:57`.
    model_compaction_size_kb: usize = 100,
};
```

- [ ] **Step 2: Pass the new fields in the GET handler response build**

In `nalar_config_get.zig:98-113`, extend the `makeNalarConfigResponse` call:

```zig
return res.jsonResponse(.{
    .status_code = 200,
    .data = try http_response.makeNalarConfigResponse(allocator, .{
        .api_endpoint = cfg.base_url,
        .api_key = cfg.api_key,
        .model = cfg.model,
        .url_style = cfg.url_style,
        .temperature = parseTemperatureOrAuto(cfg.temperature),
        .max_tokens = cfg.max_tokens,
        .system_prompt = cfg.system_prompt,
        .profiles = cfg.profiles_models,
        .active_profile = cfg.active_profile,
        .mcp_servers = cfg.mcp_servers,
        .sub_agents = sub_agents_response,
        .notify_on_complete = cfg.notify_on_complete,
        .model_compaction_size_kb = cfg.model_compaction_size_kb,
    }),
});
```

- [ ] **Step 3: Build to confirm**

Run: `timeout 180 zig build install:linux 2>&1 | tail -n 20`
Expected: build succeeds. The struct literals in `makeNalarConfigResponse` use field-init syntax, so missing fields would be a compile error — Zig's exhaustiveness check is the test.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/nalar_config_get.zig src/ai_workflow/tui/http_handlers/http_response.zig
git commit -m "fix(config): return notify_on_complete and model_compaction_size_kb in GET response"
```

---

## Chunk 3: Frontend Type — Update `NalarConfig` Interface

### Task 6: Add the two new fields to the frontend type

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:1253-1276`

- [ ] **Step 1: Locate the `NalarConfig` interface**

Read `src/apps/desktop/src/api/index.ts` around line 1253-1276. The current interface:

```ts
export interface NalarConfig {
  api_endpoint?: string
  api_key?: string
  model?: string
  url_style?: string
  temperature?: number
  max_tokens?: string
  system_prompt?: string
  profiles?: Record<string, NalarProfile>
  active_profile?: string
  mcp_servers?: Record<string, { url: string; headers?: Record<string, string> }>
  sub_agents?: SubAgent[]
}
```

- [ ] **Step 2: Add the two new optional fields**

Append them at the end of the interface:

```ts
export interface NalarConfig {
  api_endpoint?: string
  api_key?: string
  model?: string
  url_style?: string
  temperature?: number
  max_tokens?: string
  system_prompt?: string
  profiles?: Record<string, NalarProfile>
  active_profile?: string
  mcp_servers?: Record<string, { url: string; headers?: Record<string, string> }>
  sub_agents?: SubAgent[]
  /**
   * Opt-in OS notification flag. When true, the backend fires
   * `notify-send` / osascript / PowerShell when an LLM response
   * completes with `finish_reason === 'stop'`. Defaults to `false`
   * when absent (matches the `LlmConfigJson` default in
   * `Config.zig`).
   */
  notify_on_complete?: boolean
  /**
   * Compaction threshold in KB. Sessions whose DB-stored token
   * estimate exceeds this value trigger context compaction. Defaults
   * to `100` when absent. Not exposed in the UI — power users can
   * edit `config.json` directly.
   */
  model_compaction_size_kb?: number
}
```

- [ ] **Step 3: Type-check the frontend**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean build with no `vue-tsc` errors. The `bun run build` (NOT `bun run build-only`) is required per the project's memory rule — it runs `vue-tsc --build` for strict type checking.

If the build fails complaining about `NalarConfig` being missing `notify_on_complete`, it usually means a consumer (e.g. the `parseSubAgent` function or the new state binding) accesses the field without going through the interface. Check the consumers of `NalarConfig` (mainly `NalarSettings.vue`).

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(desktop): add notify_on_complete and model_compaction_size_kb to NalarConfig type"
```

---

## Chunk 4: Frontend UI — Notify-on-Complete Toggle

### Task 7: Add the `notifyOnComplete` ref and default

**Files:**
- Modify: `src/apps/desktop/src/components/NalarSettings.vue:11-18` (settings state block)

- [ ] **Step 1: Locate the settings state block**

Read `NalarSettings.vue` around line 11-18. The state block:

```ts
// Settings state
const apiEndpoint = ref('')
const apiKey = ref('')
const model = ref('')
const urlStyle = ref('openai')
const temperature = ref(0.7)
const maxTokens = ref('')
const systemPrompt = ref('')
```

- [ ] **Step 2: Add the new ref**

Insert `notifyOnComplete` after `systemPrompt` (the convention is to keep top-level scalar fields together, in the order the form sections present them). Use `false` as the default to match the `LlmConfigJson` default — a brand-new config has notifications off, so a brand-new UI should match:

```ts
// Settings state
const apiEndpoint = ref('')
const apiKey = ref('')
const model = ref('')
const urlStyle = ref('openai')
const temperature = ref(0.7)
const maxTokens = ref('')
const systemPrompt = ref('')
const notifyOnComplete = ref(false)
```

- [ ] **Step 3: Verify the edit landed**

Re-read lines 11-19 of `NalarSettings.vue` and confirm:
- `notifyOnComplete` is present with `false` default
- No other lines were touched

- [ ] **Step 4: Commit (defer to Task 10 — combine with other UI edits)**

No commit yet; this is part of the same logical UI change as Tasks 8-9. The commit lands at the end of Task 10.

---

### Task 8: Load the value from the GET response

**Files:**
- Modify: `src/apps/desktop/src/components/NalarSettings.vue:151-206` (the `onMounted` body that calls `getNalarConfig`)

- [ ] **Step 1: Locate the load block**

Read the `onMounted` body. Around line 162-205, after the call to `await getNalarConfig()` and inside the `if (data)` branch, the existing assignments are:

```ts
apiEndpoint.value = data.api_endpoint || ''
apiKey.value = data.api_key || ''
model.value = data.model || ''
urlStyle.value = data.url_style || 'openai'
temperature.value = data.temperature ?? 0.7
maxTokens.value = data.max_tokens?.toString() || ''
systemPrompt.value = data.system_prompt || ''
```

- [ ] **Step 2: Add the load assignment**

Add immediately after `systemPrompt.value = ...`:

```ts
notifyOnComplete.value = data.notify_on_complete ?? false
```

The `?? false` mirrors the JSON-side default in `LlmConfigJson.notify_on_complete: bool = false` (Config.zig:96) — if the field is missing, the toggle starts in the off position.

- [ ] **Step 3: Verify the edit landed**

Re-read lines 162-210 of `NalarSettings.vue` and confirm:
- The new assignment is immediately after `systemPrompt.value = ...`
- Indent matches the surrounding 6-space convention (inside `if (data)` block)
- No other lines were touched

---

### Task 9: Send the value in `saveSettings` and reset in `resetSettings`

**Files:**
- Modify: `src/apps/desktop/src/components/NalarSettings.vue:208-280` (`saveSettings`) and `:308-327` (`resetSettings`)

- [ ] **Step 1: Locate the save and reset blocks**

`saveSettings` (around line 208-280) builds a `settings: any = { ... }` object and posts it. `resetSettings` (around line 308-327) clears the refs and `localStorage`.

- [ ] **Step 2: Add `notify_on_complete` to the save object**

In `saveSettings`, find the `settings: any = { ... }` literal and add the field after `system_prompt`:

```ts
const settings: any = {
    api_endpoint: apiEndpoint.value,
    api_key: apiKey.value,
    model: model.value,
    url_style: urlStyle.value,
    temperature: temperature.value,
    max_tokens: maxTokens.value ? parseInt(maxTokens.value) : null,
    system_prompt: systemPrompt.value,
    notify_on_complete: notifyOnComplete.value,
}
```

The UI always sends the value (matching the `bool` (not `?bool`) shape on the wire). The backend's `ConfigInput.notify_on_complete: ?bool = null` accepts both the always-sent value and the never-sent case for older clients.

- [ ] **Step 3: Reset the ref in `resetSettings`**

In `resetSettings`, add a single line after `systemPrompt.value = ''` (around line 315):

```ts
const resetSettings = () => {
  apiEndpoint.value = ''
  apiKey.value = ''
  model.value = ''
  urlStyle.value = 'openai'
  temperature.value = 0.7
  maxTokens.value = ''
  systemPrompt.value = ''
  notifyOnComplete.value = false    // <-- ADD
  profiles.value = []
  activeProfile.value = null
  mcpServers.value = []
  // ... existing localStorage.removeItem lines
}
```

Note: `resetSettings` doesn't currently reset `mcpServers` (it does — line 318). For consistency with the other scalar fields, reset `notifyOnComplete` to the same default the state-block declares.

- [ ] **Step 4: Verify the edits landed**

Re-read both functions and confirm:
- `notify_on_complete: notifyOnComplete.value` is in the `settings` literal
- `notifyOnComplete.value = false` is in `resetSettings`, after `systemPrompt.value = ''`
- No other lines were touched

---

### Task 10: Add the toggle UI element to the template

**Files:**
- Modify: `src/apps/desktop/src/components/NalarSettings.vue:604-652` (Model Parameters section)

- [ ] **Step 1: Locate the Model Parameters section**

Read `NalarSettings.vue` around line 604-652. The section currently contains the Temperature range slider and the Max Tokens number input:

```html
<!-- Model Parameters Section -->
<div class="rounded-xl p-6" ...>
  <h2 ...>Model Parameters</h2>
  <div class="space-y-4">
    <!-- Temperature -->
    <div>...range slider...</div>
    <!-- Max Tokens -->
    <div>...number input...</div>
  </div>
</div>
```

- [ ] **Step 2: Add the toggle after Max Tokens**

Append a new `<div>` block after the Max Tokens `<div>`, inside the `<div class="space-y-4">` container. The project has no existing checkbox pattern (search for `type="checkbox"` returns nothing), so follow the existing `.rounded-lg` + `var(--semantic-content-bg)` style of the other inputs:

```html
        <!-- Notify on Complete -->
        <div>
          <label
            class="flex items-center gap-2 cursor-pointer text-sm"
            style="color: var(--semantic-text-muted);"
          >
            <input
              v-model="notifyOnComplete"
              type="checkbox"
              class="w-4 h-4 rounded"
              style="accent-color: var(--color-violet);"
            />
            <span>Notify when LLM response completes</span>
          </label>
          <p
            class="text-xs mt-1 ml-6"
            style="color: var(--semantic-text-dim);"
          >Fires an OS notification when an LLM response finishes with <code>finish_reason === 'stop'</code>. Requires a notification daemon (notify-send on Linux, osascript on macOS, PowerShell on Windows).</p>
        </div>
```

Key design choices:
- `accent-color: var(--color-violet)` reuses the brand color used by the gradient buttons elsewhere — keeps the toggle visually consistent without a CSS file change.
- The `<label>` wraps the input + text, so clicking either toggles the checkbox (standard a11y pattern; the existing fields don't do this but it's the right default for a checkbox).
- The helper text below mirrors the helper text used in the MCP Server section (`style="color: var(--semantic-text-dim);"`, `class="text-xs mt-1"`) so the visual rhythm is preserved.
- The `<p>` includes the technical detail about the platform daemon — this is the "why" the user needs to know before enabling.

- [ ] **Step 3: Type-check and build**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean build. The `NalarConfig` interface (updated in Task 6) makes `data.notify_on_complete` typed as `boolean | undefined`, so `data.notify_on_complete ?? false` is the correct narrow.

- [ ] **Step 4: Manually verify the toggle renders**

Start `nalar-dev` against an isolated config (use the same `XDG_CONFIG_HOME` trick from Chunk 5's smoke test) and open the settings panel. Confirm:
- The toggle is unchecked when `config.json` has no `notify_on_complete` key
- The toggle is checked when `config.json` has `"notify_on_complete": true`
- Clicking the toggle, then clicking "Save Settings", then reloading the page preserves the state

- [ ] **Step 5: Commit (UI work)**

```bash
git add src/apps/desktop/src/components/NalarSettings.vue
git commit -m "feat(desktop): add Notify on Complete toggle to Nalar settings"
```

---

## Chunk 5: Tests

### Task 11: Add round-trip regression tests in `config_test.zig`

**Files:**
- Modify: `src/modules/config/config_test.zig` (append 2 new tests after the existing `notify_on_complete` tests at line 366-379)

- [ ] **Step 1: Read the existing test file end**

Read `config_test.zig` from line 320 onward. Note the `writeAndRead` helper (line 23-42) and the existing `notify_on_complete` test pattern (lines 337-379).

- [ ] **Step 2: Add a `url_style` round-trip test**

Append a new test verifying that `url_style` survives the disk→typed-config path. (The test does NOT cover the PUT parse struct — that's a different code path, covered by the smoke test in Chunk 5's next task per the convention in `nalar_config_put_test.zig`'s file header.)

```zig
test "LlmConfig: url_style field round-trips through disk JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "url_style": "anthropic"
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try testing.expectEqualStrings("anthropic", cfg.url_style);
}

test "LlmConfig: url_style defaults to openai when missing from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try testing.expectEqualStrings("openai", cfg.url_style);
}
```

- [ ] **Step 3: Add a `model_compaction_size_kb` round-trip test**

`model_compaction_size_kb` is NOT yet covered in `config_test.zig` (only `notify_on_complete` is). Add explicit value-presence and default tests:

```zig
test "LlmConfig: model_compaction_size_kb reads value from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "model_compaction_size_kb": 250
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 250), cfg.model_compaction_size_kb);
}

test "LlmConfig: model_compaction_size_kb defaults to 100 when missing from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 100), cfg.model_compaction_size_kb);
}
```

- [ ] **Step 4: Run the tests**

Run: `timeout 180 zig build test 2>&1 | tail -n 20`
Expected: the 4 new tests pass alongside the existing ones. If a new test fails with a "file not found" or IO error, the `writeAndRead` helper or `std.testing.tmpDir` API has changed in a newer Zig — check the file for the current convention.

- [ ] **Step 5: Sanity-check the test fails when the field is dropped**

Temporarily comment out `.url_style = try allocator.dupe(u8, config_json.url_style)` at `Config.zig:196`. Re-run `zig build test`. Expected: the `url_style: anthropic` test fails with `expected "anthropic", got "openai"`. Restore the line immediately after.

- [ ] **Step 6: Commit**

```bash
git add src/modules/config/config_test.zig
git commit -m "test(config): regression tests for url_style and model_compaction_size_kb round-trip"
```

---

### Task 12: End-to-end smoke test with `nalar-dev`

The PUT-side `ConfigJson` struct (Task 2) and the handler logic (Task 3) are not unit-tested directly — the file-private struct is awkward to expose, and the existing convention (`nalar_config_put_test.zig:7-9`) is to smoke-test HTTP handlers. This task IS that smoke test for all three fields.

**Files:** No code changes. Output goes into the wrap-up commit (Task 13).

- [ ] **Step 1: Start a fresh `nalar-dev` instance pointing at an isolated config dir**

```bash
export XDG_CONFIG_HOME=$(mktemp -d)
echo "Using XDG_CONFIG_HOME=$XDG_CONFIG_HOME"
timeout 60 zig build install:dev:linux:system 2>&1 | tail -n 5
```

This builds a dev binary and installs it to your PATH (`nalar-dev`). The `XDG_CONFIG_HOME` redirect isolates the test from your real `~/.config/nalar/config.json`.

- [ ] **Step 2: Seed `config.json` with a known initial state**

```bash
mkdir -p "$XDG_CONFIG_HOME/nalar"
cat > "$XDG_CONFIG_HOME/nalar/config.json" <<'EOF'
{
  "api_key": "test-key",
  "model": "gpt-4o",
  "base_url": "https://api.example.com/v1",
  "url_style": "openai",
  "notify_on_complete": false,
  "model_compaction_size_kb": 100
}
EOF
```

- [ ] **Step 3: Start the server on port 8080 in the background**

```bash
nalar-dev --port 8080 &
SERVER_PID=$!
sleep 2
echo "Server PID: $SERVER_PID"
```

- [ ] **Step 4: PUT with all three new values**

```bash
curl -sS -X PUT http://127.0.0.1:8080/api/config/nalar \
  -H 'Content-Type: application/json' \
  -d '{
    "api_endpoint": "https://api.example.com/v1",
    "api_key": "test-key",
    "model": "gpt-4o",
    "url_style": "anthropic",
    "temperature": 0.7,
    "max_tokens": null,
    "system_prompt": "",
    "notify_on_complete": true,
    "model_compaction_size_kb": 250
  }'
```

Expected: HTTP 200 with `{"error":"Config saved successfully"}`.

- [ ] **Step 5: GET and verify all three values**

```bash
curl -sS http://127.0.0.1:8080/api/config/nalar | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("url_style:", d["url_style"])
print("notify_on_complete:", d["notify_on_complete"])
print("model_compaction_size_kb:", d["model_compaction_size_kb"])
'
```

Expected output:
```
url_style: anthropic
notify_on_complete: True
model_compaction_size_kb: 250
```

- [ ] **Step 6: Verify the on-disk file**

```bash
grep -E '(url_style|notify_on_complete|model_compaction_size_kb)' "$XDG_CONFIG_HOME/nalar/config.json"
```

Expected: three lines, one per field, with the values from Step 4. If any field shows its old value, the corresponding handler assignment (Task 3) didn't land — re-check that file.

- [ ] **Step 7: Test the data-preservation guarantee**

Send a PUT body that omits `notify_on_complete` and `model_compaction_size_kb` (simulates an older client):

```bash
curl -sS -X PUT http://127.0.0.1:8080/api/config/nalar \
  -H 'Content-Type: application/json' \
  -d '{
    "api_endpoint": "https://api.example.com/v1",
    "api_key": "test-key",
    "model": "gpt-4o"
  }'
grep -E '(notify_on_complete|model_compaction_size_kb)' "$XDG_CONFIG_HOME/nalar/config.json"
```

Expected: the GET returns the same values, the disk file still shows `"notify_on_complete": true` and `"model_compaction_size_kb": 250`. The `?bool` / `?usize` parse types in `ConfigInput` mean missing fields preserve the on-disk value.

- [ ] **Step 8: Clean up**

```bash
kill $SERVER_PID 2>/dev/null
rm -rf "$XDG_CONFIG_HOME"
unset XDG_CONFIG_HOME
```

---

## Chunk 6: Wrap-Up

### Task 13: Run all verifications and finalize

**Files:** No new code. Optional documentation update only.

- [ ] **Step 1: Run the full Zig test suite**

Run: `timeout 180 zig build test 2>&1 | tail -n 10`
Expected: all existing tests pass, plus the 4 new tests from Task 11.

- [ ] **Step 2: Run the TUI tests**

Run: `timeout 180 zig build test:ai_workflow:tui 2>&1 | tail -n 10`
Expected: all existing TUI tests pass. The `LlmConfigHolder` tests in `nalar_config_put_test.zig` are unaffected because they don't touch the parse struct.

- [ ] **Step 3: Run the frontend build (type-check)**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean build with no `vue-tsc` errors. The `bun run build` (not `bun run build-only`) runs `vue-tsc --build` for strict type checking — required per the project's memory rule.

- [ ] **Step 4: Capture the smoke-test output**

If the Task 12 smoke test passed, capture the key output (GET response, `grep` output) and record it as a comment block at the top of the new tests in `config_test.zig` (above the `url_style` test from Task 11):

```zig
// Smoke test confirmation (see plan `2026-06-11-nalar-config-url-style.md` §5):
//   - PUT with all three new values → 200 {"error":"Config saved successfully"}
//   - GET → url_style="anthropic", notify_on_complete=true, model_compaction_size_kb=250
//   - PUT omitting the new fields → values preserved on disk
//   - grep shows the three lines in the rewritten config.json
```

(Optional; skip if the team prefers clean test code without inline logs.)

- [ ] **Step 5: Final commit (if Step 4 added anything)**

```bash
git add src/modules/config/config_test.zig
git commit -m "docs(config): record smoke-test confirmation in url_style/notify_on_complete tests"
```

Skip this commit if Step 4 was skipped.

- [ ] **Step 6: Verify the branch is clean and ready to merge**

```bash
git log --oneline main..HEAD
git status
```

Expected: 8 commits (Tasks 1, 2, 3, 4, 5, 6, 10, 11) plus optionally Task 13's commit. Working tree clean. Ready for `finishing-a-development-branch` skill.

---

## Verification Summary

| Check | Command | Pass Criteria |
|---|---|---|
| Zig compile | `zig build install:linux` | exit 0 |
| All Zig tests | `zig build test` | all green, including 4 new tests in `config_test.zig` |
| TUI tests | `zig build test:ai_workflow:tui` | all green |
| Frontend types | `cd src/apps/desktop && bun run build` | clean (no `vue-tsc` errors) |
| Frontend render | manual: open settings panel | toggle visible, loads/saves correctly |
| PUT smoke (all 3 fields) | `curl PUT /api/config/nalar` with `url_style: anthropic`, `notify_on_complete: true`, `model_compaction_size_kb: 250` | 200 + `Config saved successfully` |
| GET smoke | `curl GET /api/config/nalar` after PUT | all 3 fields have the new values |
| Disk smoke | `grep` for the 3 fields in `config.json` after PUT | all 3 values present |
| Preservation smoke | `curl PUT` omitting the new fields | GET + disk still show the previous values |

## Pitfalls

- **Do not free the old `config_json.X` before overwriting it.** The per-request arena allocator owns the memory (see the `Custom HTTP server uses per-request arena` memory rule) and reaps it on request teardown. Adding explicit `allocator.free` calls would be use-after-free bugs.

- **Use `?T` (optional) for `notify_on_complete` and `model_compaction_size_kb` in `ConfigInput`.** The UI always sends them, but a partial PUT (e.g. an older client, or a future "save just the model" endpoint) must not clobber the on-disk value. The `?bool` / `?usize` pattern with `if (input.value.X) |v| { config_json.X = v; }` matches the existing `max_tokens` pattern at `nalar_config_put.zig:262`.

- **`url_style` is a non-optional `[]const u8` in `ConfigInput` (with default `"openai"`).** Strings follow the `if (input.value.X.len > 0)` skip pattern. The `?T` pattern is for fields the user might genuinely want to set to "no value" (e.g. `max_tokens: null` to clear the cap). `url_style` is always either `"openai"` or `"anthropic"`, so an empty input means "don't change" rather than "clear".

- **The two defaults for `notify_on_complete` are inconsistent in `Config.zig`.** `LlmConfig.notify_on_complete: bool = true` (line 29, struct default) vs `LlmConfigJson.notify_on_complete: bool = false` (line 96, JSON default). The `init()` path always uses the JSON default, so the *runtime* default is `false` for new configs. The struct default `true` only matters for direct construction (e.g. the test helper at `nalar_config_put_test.zig:37`). The plan preserves this — a brand-new config has notifications off everywhere. Don't be tempted to "fix" the inconsistency; it's documented behavior in the existing tests (`config_test.zig:337-348`).

- **The PUT handler's `ConfigJson` defaults MUST match `LlmConfigJson` in `Config.zig`.** `notify_on_complete: bool = false` and `model_compaction_size_kb: usize = 100` — these are the only values that make the PUT→disk→`LlmConfig.init` round-trip identity-preserving. If you change one, change the other in lockstep.

- **The `LlmConfig` field is `notify_on_complete`, not `notification_on_complete` or `notifyOnComplete`.** The whole codebase uses `snake_case` (matching NALAR.md JSON convention). The Vue ref is `notifyOnComplete` (camelCase) but the wire field and disk field are both `notify_on_complete`. Mixing these is the most common source of "field is missing" bugs in this project.

- **`model_compaction_size_kb` has NO UI in this plan.** It is wired through the backend only. Power users can edit `config.json` directly; the desktop settings UI doesn't expose it. If a future ticket asks to add a UI for it, the existing pattern (a labeled `<input type="number">` next to Max Tokens) is the obvious extension point.

- **The `LlmConfigHolder` swap (`nalar_config_put.zig:209-249`) re-reads config from disk via `LlmConfig.init`.** This means fixing the `ConfigJson` struct (Task 2) is what makes the live-reload path see the new values. Without Task 2, the disk would lose the field on the next save and the in-memory config would also lose it on the next PUT.

- **No `bun run build-only` — use `bun run build`.** The project memory rule: `bun run build` runs `vue-tsc --build` for strict type checking; `bun run build-only` skips it. TypeScript errors that pass at runtime (via vitest's `esbuild` transform) will still fail `vue-tsc`. Always use `bun run build` for verification.

- **The `temp` `XDG_CONFIG_HOME` test directory must be cleaned up explicitly** (`rm -rf "$XDG_CONFIG_HOME"`) — `mktemp -d` returns a directory that's NOT auto-cleaned. Failing to clean it leaves the test config in `/tmp`, which can confuse later debugging sessions.
