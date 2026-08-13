# Fix Plan: Anthropic Request-Building Bugs

Target: `buildJsonAnthropicRequest`, `AnthropicRequest`, `AnthropicThinking`, and related
structs in the LLM agent module (`url_style = "anthropic"` code path).

## Bugs being fixed, in priority order

1. **System messages sent as `role: "system"` inside `messages`** — Anthropic rejects this.
   Breaks every call that has a system prompt.
2. **`thinking: {type: "enabled"}` missing `budget_tokens`** — required field, so every call
   with `thinkingEnabled = true` (the default) 400s.
3. **`temperature` sent alongside `thinking: enabled` when not 1** — Anthropic requires
   temperature to be omitted or `1` when thinking is on.
4. **Dead/incorrect `stream_options` block in `AnthropicRequest.jsonStringify`** — not part of
   the Anthropic schema, copy-pasted from the OpenAI serializer.
5. **(Verify only) missing `tool_choice`** — confirm Anthropic's implicit `auto` default is
   what we want; no code change unless we find we need `tool_choice: {type: "auto"}` explicitly.

---

## Step 1 — Add a top-level `system` field to `AnthropicRequest`

**Struct change:**

```zig
const AnthropicRequest = struct {
    model: []const u8,
    messages: []const AnthropicMessage,
    max_tokens: usize,
    stream: bool,
    tools: ?[]const AnthropicTool = null,
    thinking: ?AnthropicThinking = null,
    temperature: ?f32 = null,
    system: ?[]const u8 = null,   // NEW
    metadata: ?AnthropicMetadata = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("model");
        try stringify.write(self.model);
        if (self.system) |s| {                 // NEW — emit before "messages"
            try stringify.objectField("system");
            try stringify.write(s);
        }
        try stringify.objectField("messages");
        try stringify.write(self.messages);
        // ...unchanged...
    }
};
```

Anthropic's `system` field accepts a plain string (or an array of content blocks, but a
string is sufficient for now — no cache_control / multi-block system prompts in scope here).

**`buildJsonAnthropicRequest` change:**

- Before building `json_messages`, scan `params.messages` for `role == .system` entries.
- Concatenate their `.content` (joined with `"\n\n"` if there's more than one — in practice
  there should only ever be one) into a single arena-owned string, assign to
  `json_request.system`.
- Build `json_messages` from **only the non-system messages** — i.e. skip `.system` entries
  when populating the `AnthropicMessage` array, rather than falling into the current
  `else` branch that serializes them with `role.to_str()`.

Concretely, in the loop:

```zig
const json_messages = try arena_alloc.alloc(AnthropicMessage, params.messages.len);
var json_message_count: usize = 0;
var system_text: std.ArrayList(u8) = .empty; // arena-backed, no manual free needed

for (params.messages) |msg| {
    if (msg.role == .system) {
        if (msg.content) |c| {
            if (system_text.items.len > 0) try system_text.appendSlice(arena_alloc, "\n\n");
            try system_text.appendSlice(arena_alloc, c);
        }
        continue; // do not emit into json_messages
    }
    // ...existing assistant / tool / user branches, writing into
    // json_messages[json_message_count], then json_message_count += 1...
}
```

Then slice `json_messages[0..json_message_count]` when constructing `AnthropicRequest`, and
set `.system = if (system_text.items.len > 0) system_text.items else null`.

**Why arena is safe here:** same lifetime reasoning as the existing `content_blocks` — the
arena is torn down after `std.json.fmt` serializes the request in this function, so no
free-before-use risk.

---

## Step 2 — Add `budget_tokens` to `AnthropicThinking`

**Struct change:**

```zig
const AnthropicThinking = struct {
    type: []const u8 = "enabled",
    budget_tokens: usize,   // NEW — required by Anthropic when type == "enabled"

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.type);
        try stringify.objectField("budget_tokens");   // NEW
        try stringify.write(self.budget_tokens);
        try stringify.endObject();
    }
};
```

**Call-site change** in `buildJsonAnthropicRequest`: budget must be `>= 1024` and strictly
less than `max_tokens`. Derive it from the resolved `max_tokens` rather than hardcoding:

```zig
const resolved_max_tokens = params.max_tokens orelse self.maxTokens;
const thinking_budget: usize = @min(
    @max(resolved_max_tokens / 2, 1024),   // at least the 1024 floor
    resolved_max_tokens -| 1,              // strictly under max_tokens
);

const json_request = AnthropicRequest{
    // ...
    .thinking = if (self.thinkingEnabled)
        .{ .type = "enabled", .budget_tokens = thinking_budget }
    else
        null,
    // ...
};
```

Add a guard/log: if `resolved_max_tokens < 1025`, thinking can't legally be enabled (budget
floor is 1024 and must be `< max_tokens`) — either bump `max_tokens` for that call or force
`thinkingEnabled = false` for the request and log a warning, rather than sending an
unsatisfiable budget. Prefer making this explicit rather than silently clamping to something
invalid.

Longer-term: consider exposing `thinkingBudgetTokens` as a configurable field on `Agent`
(with the derived default above as fallback) instead of hardcoding the 50%-of-max heuristic.

---

## Step 3 — Fix temperature/thinking conflict

Anthropic requires `temperature` to be **omitted or exactly `1`** whenever
`thinking.type == "enabled"`.

**Call-site change** in `buildJsonAnthropicRequest`:

```zig
const thinking_on = self.thinkingEnabled;

const json_request = AnthropicRequest{
    // ...
    .thinking = if (thinking_on)
        .{ .type = "enabled", .budget_tokens = thinking_budget }
    else
        null,
    .temperature = if (thinking_on) null else params.temperature,   // CHANGED
    // ...
};
```

Omitting is simpler and safer than forcing `1`, since it avoids silently overriding a
caller-specified temperature value with something they didn't ask for — Anthropic's default
under thinking is 1 anyway. Log at `.debug` when a non-null `params.temperature` is being
dropped because thinking is on, so this isn't a silent behavior change during debugging.

---

## Step 4 — Remove the bogus `stream_options` block from `AnthropicRequest.jsonStringify`

Delete:

```zig
if (self.stream) {
    try stringify.objectField("stream");
    try stringify.write(true);
    try stringify.objectField("stream_options");
    try stringify.write(.{ .include_usage = true });
}
```

Replace with just:

```zig
if (self.stream) {
    try stringify.objectField("stream");
    try stringify.write(true);
}
```

Anthropic streams usage on `message_start`/`message_delta` events unconditionally — there is
no request-side toggle — so nothing else needs to change here or in
`parse_anthropic_stream_chunk`.

---

## Step 5 — Verify `tool_choice` omission is intentional

No struct/schema change expected. Action item: confirm against Anthropic docs that omitting
`tool_choice` defaults to `{"type": "auto"}` behavior for our use case (tools present, model
free to choose to call or not). If a future workflow needs to force tool use
(`tool_choice: {"type": "any"}` / `{"type": "tool", "name": "..."}`), that's a separate
follow-up, not part of this fix.

---

## Testing

1. **Unit test `buildJsonAnthropicRequest`:**
   - Messages list containing a `.system` message + user/assistant turns → assert output JSON
     has a top-level `"system"` string field and **no** `role: "system"` entry inside
     `"messages"`.
   - `thinkingEnabled = true` → assert `"thinking"` object has both `"type"` and
     `"budget_tokens"`, and `"temperature"` is absent from the output even if
     `params.temperature` was set.
   - `thinkingEnabled = false` → assert `"thinking"` is absent and `"temperature"` is emitted
     as before.
   - `stream = true` → assert `"stream": true` present and no `"stream_options"` key at all.
   - Edge case: `max_tokens` small enough that `budget_tokens` floor (1024) would violate
     `budget_tokens < max_tokens` → assert the guard fires (error or thinking forced off,
     per whichever behavior we pick in Step 2) rather than emitting an invalid request.

2. **Integration smoke test** (real API key, gated behind an env var / not run in normal CI):
   - One call with a system prompt + `thinkingEnabled = true`, streaming — assert HTTP 200
     and a valid SSE stream instead of the current 400.
   - One call with `thinkingEnabled = false` and a custom low temperature — assert temperature
     is honored (indirectly, via response variability or just checking the outbound body in a
     mock transport).

3. **Regression check on OpenAI path:** none of the above touches `JsonRequest` /
   `buildJsonOpenAIRequest`, so existing OpenAI-profile tests should be unaffected — run them
   to confirm no accidental cross-talk (e.g. from shared arena helpers).

## Rollout

- Land Steps 1–4 together (they're all in the same function and struct, low risk of a
  half-fixed intermediate state).
- Since `thinkingEnabled` defaults to `true` on `Agent`, existing Anthropic-profile users are
  currently either not hitting this path at all (never actually working) or have
  `thinkingEnabled = false` set explicitly. Worth grepping config/call sites before merge to
  confirm nobody is relying on today's (broken) request shape.
- No wire-format change for the OpenAI (`url_style = "openai"`) path — safe to ship
  independently of any OpenAI-side work.
