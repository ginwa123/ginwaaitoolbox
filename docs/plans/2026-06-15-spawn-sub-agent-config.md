# `spawn_sub_agent` — Config-Driven Sub-Agent Selection

**Status:** Approved (brainstorming complete 2026-06-15)
**Owner:** Backend tools

## Goal

Extend `spawn_sub_agent` so each sub-agent in the call can opt in to a
**named sub-agent from config** by passing a new `agent_name` field. When
the name resolves, the sub-agent runs with that sub-agent's
`model` / `base_url` / `api_key` / `url_style` / `thinking` / `temperature` /
`system_prompt`. When the name is not found anywhere, the sub-agent falls
back to a **random identifier** and uses the **orchestrator's default**
model/api_key/base_url/url_style (the default `build_agent_prompt`
scaffold, no specialized system prompt injected).

The `LlmConfig.sub_agents` infrastructure already exists in
`src/modules/config/Config.zig` (added previously) — this plan wires it
into the spawn path and the workflow/prompt builders.

## Decisions locked during brainstorming

1. **Profile resolution order** — Active profile's `sub_agents` → top-level
   `sub_agents` (the "if no profile used, use the default" reading).
2. **Random sub-agent name when not found** — Generate
   `agent-{timestamp_nanoseconds}-{randomhex}` for labeling/tracking only;
   use the orchestrator's default `model`/`api_key`/`base_url`/`url_style`;
   the system prompt is the default `build_agent_prompt` output (no
   specialized system_prompt injected).
3. **`system_prompt` placement** — Injected as the
   `## Your Active Agent Configuration` section of `build_agent_prompt`
   (replaces what the main agent sees from `BuildDynamicAgentContent` for
   that turn). The static `SubAgentPrompt` (research-only instructions)
   is **removed entirely** — sub-agents now use the full main agent
   scaffold plus their specialized instructions.
4. **`thinking` and `temperature` from `SubAgentConfig`** — Both apply when
   the sub-agent is loaded. `"auto"` (the default) means "inherit from
   parent's value at run time".

## Deletion note

`pub fn build_sub_agent_prompt` in `src/modules/agent/prompts.zig` is
**deleted**. Sub-agents no longer use the simple research-only prompt;
they use `build_agent_prompt` with the sub-agent's `system_prompt`
injected as the `activeAgentContent` parameter. The static
`SubAgentPrompt` const in `src/modules/agent/prompts/subagent.zig` can
also be deleted (or left unused — see "Optional cleanup" below).

## Data flow

```
LLM call → spawn_sub_agent(json_input={sub_agents:[{name, instruction, agent_name: "foo"}]})
        → parseSubAgentsFromValue (parse + dupe + validate agent_name)
        → SubAgentsInput.sub_agents[i].agent_name : ?[]const u8
        → execSpawnSubAgent (tool_registry.zig):
            for each sub_agent:
              config = nalar_mod.getLlmConfig(di)
              resolved = config.resolveSubAgent(profile_model_from_session, sa.agent_name)
                // look up in active profile's sub_agents first, then top-level
                // → returns ResolvedSubAgent with is_random_fallback flag
              args = SubAgentThreadArgs{
                  ...,
                  effective_model       = resolved.model,
                  effective_api_key     = resolved.api_key,
                  effective_base_url    = resolved.base_url,
                  effective_url_style   = resolved.url_style,
                  effective_thinking    = resolved.is_thinking,  // null = inherit
                  effective_temperature = resolved.temperature,  // null = inherit
                  sub_agent_system_prompt = resolved.system_prompt,
                  sub_agent_resolved_name = resolved.name,
              }
              group.concurrent(runSubAgent, .{args})
        → runSubAgent:
            sess_id = "subagent_{ns}_{resolved_name}"   // or random
            params = RunParamsNew{
                ...,
                sub_agent_overrides = SubAgentOverrides{...},  // NEW
            }
            workflow.runAgenticMultiStepnew(di, params)
        → runAgenticMultiStepnew:
            // 1. Existing profile resolution: profile > top-level
            // 2. NEW: apply sub_agent_overrides on top of (1)
            //    if override.X.len > 0, use override.X; else keep (1)
            // 3. Build messages with activeAgentContent = sub_agent_overrides.system_prompt
        → buildMessages → build_agent_prompt(activeAgentContent = sub-agent's system_prompt)
        → returns full agent prompt + "## Your Active Agent Configuration" block
```

## Schema additions

### `SubAgentInput` — `src/modules/agent/tools/spawn_sub_agent.zig`

```zig
pub const SubAgentInput = struct {
    name: []const u8,
    instruction: []const u8,
    tools: ?[]const []const u8 = null,
    timeout_seconds: ?u32 = null,
    inherited_context: ?[]const u8 = null,
    agent_name: ?[]const u8 = null, // NEW: name of a sub-agent from config
};
```

Add one `if (sa.agent_name) |n| allocator.free(n);` line in
`SubAgentsInput.deinit`.

### `parseSubAgentsFromValue` — same file

- After parsing `inherited_context`, look for `agent_name`.
- `try allocator.dupe(u8, value.string)`.
- Treat empty string `""` as "not specified" (store as `null`).
- No validation at parse time (validation is deferred to
  `Config.resolveSubAgent`, which is the single source of truth on
  "does this name exist?"). Returning `error.AgentNameTooLong` (e.g.
  > 256 chars) is the only parse-time guard, to avoid absurdly long
  input.

### Tool description update

In the `description` block of `spawn_sub_agent_tool` (around line 41),
append a new section:

```
\\
\\AGENT_NAME (sub-agent from config):
\\- Each sub-agent may include "agent_name" to load a pre-configured
\\  sub-agent from your LlmConfig.
\\- Resolution order: active profile's sub_agents → top-level sub_agents.
\\- If the name is found, the sub-agent uses that sub-agent's
\\  model/base_url/api_key/url_style/thinking/temperature/system_prompt.
\\- If the name is not found, a random name is generated
\\  ("agent-{ns}-{randhex}") for tracking and the orchestrator's
\\  default model/api_key/base_url/url_style is used.
\\- "agent_name" field in each sub-agent's JSON:
\\    { "name": "...", "instruction": "...", "agent_name": "code-reviewer" }
```

## Config resolution

### `Config.zig` — new `resolveSubAgent` function

Add a new method to `LlmConfig` (after `hasSubAgent` at line 828):

```zig
/// Resolve a sub-agent by name, applying profile overlay rules.
///
/// Lookup order (per locked decision #1):
///   1. If `profile_name` is non-empty AND a profile with that name
///      exists, search `profile.sub_agents` first.
///   2. Fall back to `self.sub_agents` (top-level).
///
/// If `agent_name` is empty OR not found in either list, the returned
/// struct has `is_random_fallback = true`, a generated random
/// `name` of the form `"agent-{nanoseconds}-{randomhex}"`, and the
/// orchestrator's default model/api_key/base_url/url_style/system_prompt
/// (empty system_prompt).
///
/// The returned struct's LLM fields are *overlays* on the orchestrator's
/// defaults: any field that's empty in the SubAgentConfig falls through
/// to the orchestrator's value. The caller is expected to apply the
/// overlay against the parent's already-resolved values (which is what
/// `RunParamsNew.sub_agent_overrides` does).
///
/// `thinking` and `temperature` are resolved into the strongly-typed
/// `?bool` / `?f32` shapes the workflow needs. `"auto"` (the default
/// in SubAgentConfig) maps to `null` (inherit from parent).
///
/// `is_random_fallback` is true iff `agent_name` was provided but not
/// found in any sub_agents list. It's `false` if `agent_name` was
/// empty (caller didn't opt in) — but in that case the caller should
/// skip calling this function entirely.
pub fn resolveSubAgent(
    self: *const LlmConfig,
    profile_name: []const u8,
    agent_name: []const u8,
) ResolvedSubAgent
```

### `ResolvedSubAgent` struct — `Config.zig`

New public type, defined next to `SubAgentConfig`:

```zig
pub const ResolvedSubAgent = struct {
    /// Name to record as `agent_name` for the sub-agent's session.
    /// Either the resolved config name or a random fallback
    /// (`"agent-{nanoseconds}-{randomhex}"`).
    name: []const u8,

    /// True iff `agent_name` was provided but not found in any
    /// sub_agents list. False when the name was found (or when
    /// `agent_name` was empty and the caller didn't opt in).
    is_random_fallback: bool,

    /// The name the LLM originally requested. Empty if no `agent_name`
    /// was provided. Useful for logging.
    requested_name: []const u8,

    /// Resolved LLM endpoint fields. Empty string = "use orchestrator
    /// default" (overlay semantics).
    model: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    url_style: []const u8,

    /// Resolved `thinking` setting. `null` = "auto" → inherit from
    /// parent's value at run time.
    is_thinking: ?bool,

    /// Resolved `temperature` setting. `null` = "auto" → inherit from
    /// parent's value at run time.
    temperature: ?f32,

    /// System prompt to inject as the sub-agent's
    /// `## Your Active Agent Configuration`. Empty for the
    /// random-fallback case (sub-agent uses default build_agent_prompt).
    system_prompt: []const u8,

    /// Which sub_agents list supplied this config: the profile name
    /// (e.g. `"profile1"`) or `""` for top-level. Useful for logging
    /// "loaded from profile1's sub_agents" vs "top-level".
    source: []const u8,
};
```

### Helper: random name generation — `Config.zig`

Add a tiny private helper:

```zig
fn generateRandomAgentName(allocator: std.mem.Allocator) ![]u8 {
    const ns = std.Io.Timestamp.now(...).nanoseconds; // or std.time
    var buf: [8]u8 = undefined;
    std.crypto.random.bytes(&buf);
    const hex = std.fmt.bytesToHex(buf, .lower);
    return std.fmt.allocPrint(
        allocator,
        "agent-{d}-{s}",
        .{ ns, &hex },
    );
}
```

For Zig 0.16 randomness, use `std.crypto.random` (see
`zig-0.16-process-spawn-api` skill for context). If that's awkward
inside the const-init context, fall back to a counter-based name
(`agent-{nanoseconds}-{counter++}`).

## Workflow changes

### `RunParamsNew` — `src/ai_workflow/tui/workflow.zig`

Add a new optional overlay field at the end of the struct
(currently ends at line 1029):

```zig
pub const RunParamsNew = struct {
    // ... existing fields ...
    selected_profile_model: []const u8 = "",
    inherited_context: []const u8 = "",

    /// NEW: pre-resolved sub-agent config overlay. When non-null, the
    /// fields here are applied on top of the existing
    /// `selected_profile_model` resolution. Strings with `.len == 0`
    /// mean "inherit the resolved value". `is_thinking` / `temperature`
    /// null fields mean "auto — inherit parent's value".
    sub_agent_overrides: ?SubAgentOverrides = null,
};

pub const SubAgentOverrides = struct {
    /// Final name to record in `llm_history.agent_name` and the
    /// session_id suffix (e.g. "code-reviewer" or
    /// "agent-1234567890-aabbccdd").
    resolved_name: []const u8,
    /// True when the original `agent_name` was not found in any
    /// sub_agents list. Forwarded to the frontend via
    /// `<is_random_fallback>` in the tool result.
    is_random_fallback: bool,
    /// LLM fields (overlay on profile-resolved values).
    model: []const u8 = "",
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    url_style: []const u8 = "",
    /// `null` = "auto — inherit parent's value at run time"
    is_thinking: ?bool = null,
    temperature: ?f32 = null,
    /// System prompt to inject. Empty = no injection (use default
    /// build_agent_prompt scaffold).
    system_prompt: []const u8 = "",
};
```

### `runAgenticMultiStepnew` — same file, lines 138–176

The existing profile resolution produces:

```zig
const effective_api_key:   []const u8 = ...;  // profile or config.api_key
const effective_model:     []const u8 = ...;  // profile or config.model
const effective_base_url:  []const u8 = ...;  // profile or config.base_url
const effective_url_style: []const u8 = ...;  // profile or config.url_style
```

After this block (around line 176), add a new "apply sub-agent
overrides" step. The overrides are **strings that override** the
profile-resolved values; **bool/f32 null fields** mean "auto" (inherit
the profile-resolved value):

```zig
// ─── Apply sub-agent config overlay (post-profile) ──────────────
// Empty-string fields in `overrides` mean "keep the profile-resolved
// value". `null` is_thinking / temperature fields mean "auto" (also
// inherit). Non-empty/non-null fields win.
var resolved_model      = effective_model;
var resolved_api_key    = effective_api_key;
var resolved_base_url   = effective_base_url;
var resolved_url_style  = effective_url_style;
var resolved_is_thinking: ?bool = null; // null = "use session's current value"
var resolved_temperature: ?f32 = null;
var resolved_system_prompt: []const u8 = "";
var sub_agent_session_name: []const u8 = "";
var sub_agent_is_random: bool = false;

if (params.sub_agent_overrides) |ov| {
    if (ov.model.len > 0)         resolved_model     = ov.model;
    if (ov.api_key.len > 0)       resolved_api_key   = ov.api_key;
    if (ov.base_url.len > 0)      resolved_base_url  = ov.base_url;
    if (ov.url_style.len > 0)     resolved_url_style = ov.url_style;
    if (ov.is_thinking) |t|       resolved_is_thinking  = t;
    if (ov.temperature) |t|       resolved_temperature  = t;
    resolved_system_prompt = ov.system_prompt;
    sub_agent_session_name = ov.resolved_name;
    sub_agent_is_random    = ov.is_random_fallback;
}
```

Then:

- Replace every later reference to `effective_model` /
  `effective_api_key` / `effective_base_url` / `effective_url_style`
  with the `resolved_*` names.
- For `is_thinking` / `temperature`: in the inner loop, where the
  code reads `currentAgentState.is_thinking` / `currentAgentState.temperature`
  (around line 359), apply the override:

  ```zig
  var agent_temperature = currentAgentState.temperature;
  if (resolved_temperature) |t| agent_temperature = t;
  var isThinking = currentAgentState.is_thinking;
  if (resolved_is_thinking) |t| isThinking = t;
  ```

- For `agent_name`: in every `saveMessage` / `onEventSendLLMHistory`
  call where `agent_name = current_agent` is used, prefer
  `sub_agent_session_name` when it's non-empty (this is the
  sub-agent flow). For the main agent flow, `sub_agent_session_name`
  is empty and the existing `current_agent` is used unchanged.
  **Cleanest approach:** introduce a `const effective_agent_name: []const u8`
  that defaults to `current_agent` and is replaced by
  `sub_agent_session_name` when the sub-agent flow applies.
  Since `runAgenticMultiStepnew` is called by BOTH the main session
  POST handler AND the sub-agent path, gate this on whether
  `sub_agent_session_name.len > 0`.

### `buildMessages` call site — line 393

```zig
const initialMessages = try build_msg_prompt.buildMessages(
    allocator, io, db, copy_cwd, copy_session_id, copy_parent_session_id,
    db_messages, merged_tools, copy_inherited_context,
);
```

Add a new `activeAgentContent` argument (see next section). For the
sub-agent flow, pass `resolved_system_prompt`. For the main agent flow,
continue to pass the `BuildDynamicAgentContent(db, session_id)`
result.

## Prompt builder changes

### `buildMessages` — `src/ai_workflow/tui/build_messages_for_agent_prompt.zig`

Add a new parameter (after `inherited_context_mode`):

```zig
pub fn buildMessages(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    session_id: []const u8,
    parent_session_id: []const u8,
    historyMessages: []TUIHistory,
    tools: []tool_models.AgentTool,
    inherited_context_mode: []const u8,
    activeAgentContent: []const u8 = "", // NEW (existing behaviour: compute from session_agents table)
) ![]agent.AgentMessage
```

Inside, replace:

```zig
const agentUsed = try BuildDynamicAgentContent(allocator, db, session_id);
defer allocator.free(agentUsed);
```

with:

```zig
// If the caller supplied an explicit activeAgentContent (sub-agent
// flow with a config-driven system_prompt), use it verbatim. Otherwise
// fall back to the per-session agents loaded via change_agent (the
// "main agent" flow).
const effective_active_agent_content: []const u8 = if (activeAgentContent.len > 0)
    activeAgentContent
else
    try BuildDynamicAgentContent(allocator, db, session_id);
defer if (activeAgentContent.len == 0) allocator.free(effective_active_agent_content);
```

Then pass `effective_active_agent_content` to `build_agent_prompt`
where `agentUsed` was passed before.

### Workflow integration

- **Main agent path** (no sub-agent): caller passes
  `activeAgentContent = ""`; `buildMessages` falls back to
  `BuildDynamicAgentContent` (current behavior, unchanged).
- **Sub-agent path** (with config): caller passes
  `activeAgentContent = resolved_system_prompt`; `buildMessages` uses
  it verbatim. The sub-agent's system prompt is rendered as the
  `## Your Active Agent Configuration` section.

### `build_sub_agent_prompt` — DELETE

Remove `pub fn build_sub_agent_prompt` from
`src/modules/agent/prompts.zig` (lines 306–407). The function is no
longer called from anywhere (verified — `spawn_sub_agent` uses
`buildMessages` → `build_agent_prompt`).

Also remove the now-unused `SubAgentPrompt` and `SubAgentBrief` imports
from `prompts.zig` (lines 36–37). See "Optional cleanup" below for
the `SubAgentPrompt` constant itself.

### `prompts_test.zig`

Delete the four `build_sub_agent_prompt` test blocks:

- `build_sub_agent_prompt with no environment: no Global Knowledge section` (line 34)
- `build_sub_agent_prompt with empty memories dir: no Global Knowledge section` (line 177)
- `build_sub_agent_prompt loads memory files into Global Knowledge section` (line 209)
- `build_sub_agent_prompt loads large memory files fully (no aggregate cap)` (line 551)

## Tool registry / sub-agent spawning

### `SubAgentThreadArgs` — `src/ai_workflow/tui/tool_registry.zig`

Add a new field for the resolved sub-agent config (around line 728):

```zig
const SubAgentThreadArgs = struct {
    // ... existing fields ...
    inherited_context: []const u8 = "",

    // NEW: resolved sub-agent config (overlay on top of profile).
    sub_agent_overrides: ?workflow.RunParamsNew.SubAgentOverrides = null,
};
```

`SubAgentOverrides` is a top-level public type in `workflow.zig`, so
importing it here is just `workflow.SubAgentOverrides` (or
`workflow.RunParamsNew.SubAgentOverrides`).

### `execSpawnSubAgent` — same file, around line 800

Before launching each sub-agent, call
`config.resolveSubAgent(profile_name, sa.agent_name)`:

```zig
// Profile name to drive sub-agent resolution. Use the current
// session's `selected_profile_model` if set; otherwise the
// orchestrator's top-level config is used (and
// `resolveSubAgent` skips the profile lookup).
//
// In v1, the parent session's `selected_profile_model` is not yet
// accessible from `ctx` (only `model` / `api_key` / `base_url`
// are). To keep this surgical, pass `""` (top-level only) for now
// and document the limitation. Follow-up: thread
// `selected_profile_model` through `ToolExecContext`.

const resolved = ctx.config.resolveSubAgent("", sa.agent_name);

const overrides = workflow.SubAgentOverrides{
    .resolved_name      = resolved.name,
    .is_random_fallback = resolved.is_random_fallback,
    .model              = resolved.model,
    .base_url           = resolved.base_url,
    .api_key            = resolved.api_key,
    .url_style          = resolved.url_style,
    .is_thinking        = resolved.is_thinking,
    .temperature        = resolved.temperature,
    .system_prompt      = resolved.system_prompt,
};
```

Then add `.sub_agent_overrides = overrides` to the `SubAgentThreadArgs`
literal.

**Known v1 limitation:** the profile overlay is *not* applied because
`ToolExecContext` doesn't carry the parent's `selected_profile_model`.
The follow-up work (out of scope) is to thread the profile name
through `ToolExecContext`. Until then, the lookup hits
`config.sub_agents` only — which still satisfies the "sub-agent from
config" use case, just not the "per-profile sub-agent override" use
case. Document this prominently in the plan and the schema
description (an extra sentence: "v1: only the top-level
`sub_agents` list is consulted; per-profile `sub_agents` is
scanned in a follow-up.").

### `runSubAgent` — same file, around line 870

The function takes `*SubAgentThreadArgs`. Build the `RunParamsNew`:

```zig
const sess_id = std.fmt.allocPrint(
    sub_agent_allocator,
    "subagent_{}_{s}",
    .{ std.Io.Timestamp.now(args_ptr.io, .real).nanoseconds, args_ptr.sub_agent_overrides.?.resolved_name },
) catch { ... };
```

And:

```zig
ai_workflow.runAgenticMultiStepnew(di, .{
    .parent_session_id = args_ptr.parent_sess_id,
    .session_id = sess_id,
    .message = args_ptr.instruction,
    .cwd = args_ptr.cwd,
    .body = "",
    .allowed_tools = ...,
    .is_sub_agent = true,
    .inherited_context = args_ptr.inherited_context,
    .sub_agent_overrides = args_ptr.sub_agent_overrides,
}) catch ...;
```

## Frontend changes

### `SpawnSubAgent.vue`

The result XML now needs to carry the random-fallback signal back to
the UI. Add a `<random_fallback>true</random_fallback>` field to the
per-agent output (next to `<session_id>`). The frontend shows a small
"random name" badge when this is present.

In `execSpawnSubAgent`'s loop, when writing each agent's block:

```zig
try w.print("<agent name=\"{s}\" success=\"{s}\" random_fallback=\"{s}\">\n", .{
    result.name,
    success,
    if (result.is_random_fallback) "true" else "false",
});
```

(`result.is_random_fallback` is a new field on `ThreadResult` that
`runSubAgent` writes after `resolveSubAgent` returns.)

In `SpawnSubAgent.vue` (line 22–47), add `randomFallback: boolean`
to the `AgentResult` interface and read it from
`match[4]`. Show a small chip in the agent header (next to
`sessionId`) when true:

```vue
<span v-if="agent.randomFallback"
      class="text-[10px] px-1.5 py-0.5 rounded font-mono"
      style="background-color: var(--semantic-text-muted); color: white; opacity: 0.7;"
      title="Requested agent_name not found in config; a random name was used and the orchestrator's default model was applied.">
  random
</span>
```

The tooltip (added to the plan for future hardening) explains the
fallback. **v1 scope:** UI just shows the badge; the user can click
into the sub-agent's session to see the full model/system prompt if
the dev tools expose it.

## Test plan

New file: `src/modules/config/config_resolve_sub_agent_test.zig`.
Register in `src/modules/config/test_runner.zig` (or wherever
config tests are registered — verify before implementing).

### `resolveSubAgent` tests (no DB needed)

- **profile hit** — Set up an `LlmConfig` with a profile `"profile1"`
  whose `sub_agents` contains `{name: "foo", model: "gpt-4o",
  system_prompt: "you are foo"}`. Call
  `resolveSubAgent("profile1", "foo")`. Assert: `name == "foo"`,
  `is_random_fallback == false`, `model == "gpt-4o"`,
  `system_prompt == "you are foo"`, `source == "profile1"`.
- **top-level hit** — Same config but `profile1.sub_agents` is empty.
  Call `resolveSubAgent("profile1", "foo")` where `foo` is in the
  top-level `sub_agents`. Assert: `name == "foo"`, `source == ""`.
- **no profile** — `resolveSubAgent("", "foo")` where `foo` is in
  top-level. Assert: hit found, `source == ""`.
- **miss** — `resolveSubAgent("profile1", "unknown")` with neither
  list containing `unknown`. Assert: `is_random_fallback == true`,
  `name` matches `^agent-[0-9]+-[0-9a-f]{16}$`,
  `model == config.model`, `system_prompt == ""`.
- **empty profile_name + miss** — `resolveSubAgent("", "unknown")`.
  Same as above, `source == ""`.
- **overlay (empty field)** — `SubAgentConfig` has `model: "gpt-4o"`
  but empty `api_key` and empty `base_url`. Resolve. Assert:
  `model == "gpt-4o"`, `api_key == ""` (overlay semantics — the
  caller is expected to fill from orchestrator default), `base_url == ""`.
- **"auto" thinking** — `SubAgentConfig.thinking == "auto"`. Resolve.
  Assert: `is_thinking == null`.
- **"true" thinking** — `SubAgentConfig.thinking == "true"`. Resolve.
  Assert: `is_thinking == ?true`.
- **"false" thinking** — Assert: `is_thinking == ?false`.
- **temperature "auto"** — Assert: `temperature == null`.
- **temperature "0.5"** — Assert: `temperature == ?@as(f32, 0.5)`.

### `parse_sub_agents` (spawn_sub_agent.zig) — JSON parsing tests

Add to existing `src/modules/agent/tools/spawn_sub_agent_test.zig`
(recreate the test file — see "File creation" below):

- JSON with `agent_name: "code-reviewer"` → `sub_agents[0].agent_name == "code-reviewer"`.
- JSON with `agent_name: ""` → `sub_agents[0].agent_name == null`.
- JSON with no `agent_name` key → `sub_agents[0].agent_name == null`.
- `deinit` frees the dupe (no leak under ASan).

### `SubAgentOverrides` resolution — integration test (no DB)

Add to `spawn_sub_agent_test.zig` (or a new
`sub_agent_overrides_test.zig`):

- Construct a fake `LlmConfig` and `SubAgentConfig`.
- Call `config.resolveSubAgent("", "foo")`.
- Build `SubAgentOverrides` from the result.
- Assert the struct fields are exactly as expected.

### Frontend tests

- `SpawnSubAgent.vue.spec.ts` — render an `<agent random_fallback="true">`
  tag in the content; assert the "random" badge appears.
- Render an `<agent random_fallback="false">` tag; assert the badge
  does NOT appear.

## Files touched

### Create
- `src/modules/config/config_resolve_sub_agent_test.zig` — unit tests
  for `resolveSubAgent` (register in config test_runner).
- `src/modules/agent/tools/spawn_sub_agent_test.zig` — recreate the
  removed test file with parser tests for `agent_name` + integration
  tests for the new `resolveSubAgent` flow.

### Modify
- `src/modules/agent/tools/spawn_sub_agent.zig` — add `agent_name`
  field, parser, deinit, description.
- `src/ai_workflow/tui/tool_registry.zig` — add `sub_agent_overrides`
  to `SubAgentThreadArgs`, resolve in `execSpawnSubAgent`, pass
  through `runSubAgent`, write `random_fallback` to result XML.
- `src/ai_workflow/tui/workflow.zig` — add `SubAgentOverrides` and
  `sub_agent_overrides` to `RunParamsNew`, apply overlay after
  profile resolution, pass through to `buildMessages`.
- `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` — add
  `activeAgentContent` parameter to `buildMessages`.
- `src/modules/agent/prompts.zig` — DELETE `build_sub_agent_prompt`
  (lines 306–407). Remove `SubAgentPrompt` / `SubAgentBrief` imports.
- `src/modules/agent/prompts_test.zig` — DELETE the 4
  `build_sub_agent_prompt` tests (lines 34, 177, 209, 551).
- `src/modules/agent/test_runner.zig` — register
  `spawn_sub_agent_test.zig`.
- `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue` —
  parse `random_fallback` attribute, render the "random" badge.
- `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue` —
  update TypeScript types.

### Optional cleanup (left for follow-up)
- `src/modules/agent/prompts/subagent.zig` — `SubAgentPrompt` and
  `SubAgentBrief` consts are now unused. They can be deleted, or
  left as dead-but-compiling code with a comment marking them
  obsolete. Recommend deletion for cleanliness.

## Backward compatibility

The new `agent_name` field is **optional** and **off by default**.
Existing `spawn_sub_agent` calls without `agent_name` continue to:

1. Use the parent's profile-resolved `model` / `api_key` /
   `base_url` / `url_style`.
2. Use the default `build_agent_prompt` scaffold (full main agent
   prompt) for the system message, with no sub-agent-specific
   `system_prompt` injection.
3. Record `agent_name` as the *LLM-provided* `name` (the original
   sub-agent name), not a random one.

The new system prompt behavior (sub-agents use `build_agent_prompt`
instead of the research-only `SubAgentPrompt`) is a **behavior
change** for all sub-agents, not just those with `agent_name`. This
is intentional per the locked decision #3. Document in the plan's
"Behavior change" section below.

## Behavior change to call out

Sub-agents in v1 will see a **longer and more capable** system prompt
(the full main agent scaffold + skills listing + memory files +
tools) compared to v0 (the simple research-only prompt). This is
intentional but may affect prompt token counts and (in edge cases)
sub-agent behavior. The user's locked decision #3 explicitly
requested this. Mention in the PR description and the
`spawn_sub_agent` schema description that the system prompt is now
the full agent prompt.

## Out of scope (follow-up work)

- **Per-profile sub-agent resolution** — `ToolExecContext` doesn't
  carry the parent's `selected_profile_model`, so the v1 lookup
  hits the top-level `sub_agents` only. The "active profile first"
  rule per locked decision #1 will work in v2 once the profile
  name is threaded through. Document in the v1 tool description.
- **Sub-agent-specified `selected_profile_model`** — Sub-agents
  can only opt in via `agent_name`, not their own profile name.
- **"auto" / `null` thinking/temperature fields in the
  spawn_sub_agent JSON** — Could be useful as an override shortcut
  but is redundant with `agent_name` (which already carries
  thinking/temperature). Not needed in v1.
- **`SkillSaveInfo` / `AgentSaveInfo` for sub-agents** — Sub-agents
  still can't save skills/agents they discover (out of scope for
  this plan).
- **Token-aware truncation of the injected system_prompt** — v1
  passes the full string. Follow-up: cap at 50 KB to match
  `loadGlobalKnowledge`.

## Verification

1. `zig build` clean (Zig 0.16).
2. New tests pass:
   - `config_resolve_sub_agent_test.zig` — 11+ tests.
   - `spawn_sub_agent_test.zig` — 4+ parser + 1+ integration tests.
3. `src/modules/agent/test_runner.zig` runs and includes the new
   file. `src/modules/config/test_runner.zig` (or equivalent)
   registers the new config test.
4. **Existing test suite unaffected** — `workflow.zig`,
   `build_messages_for_agent_prompt.zig`, and `tool_registry.zig`
   all preserve the old behavior when `sub_agent_overrides == null`
   and `activeAgentContent == ""`. Run the full test suite
   (`timeout 180 zig build test --summary all`) and confirm no
   regressions.
5. **Manual smoke** (desktop app):
   - With no sub_agents in config, spawn a sub-agent without
     `agent_name` → confirm it uses the default model and the
     sub-agent's session shows the full agent prompt (open dev
     tools to inspect the system prompt).
   - Add a `sub_agents` entry to `~/.config/nalar/config.json`:
     ```json
     { "sub_agents": [
         { "name": "reviewer",
           "model": "gpt-4o",
           "system_prompt": "You are a strict code reviewer." }
     ]}
     ```
   - Spawn a sub-agent with `agent_name: "reviewer"` → confirm
     the sub-agent's session shows the specialized system prompt
     and the model is `gpt-4o`.
   - Spawn a sub-agent with `agent_name: "unknown"` → confirm
     the result XML has `random_fallback="true"` and the
     "random" badge shows in the UI.
   - Spawn 2 sub-agents in parallel, one with `agent_name` and
     one without → confirm both succeed with the right config.
6. **Frontend type-check** — `cd src/apps/desktop && timeout 120
   bun run build` clean (TypeScript strict mode).
