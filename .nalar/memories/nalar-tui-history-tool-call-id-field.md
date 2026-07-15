# nalar — TUIHistory has BOTH `tools` and `tool_call_id` fields

The `TUIHistory` struct in `src/ai_workflow/tui/models.zig` has TWO fields that
look similar but mean different things. When a tool-result message is being
constructed, you MUST use the right one for the right purpose.

## The fields

- `tools: []const u8` (line 19) — holds the **tool_calls JSON array** (the
  OpenAI-style `[{"id":"...","function":{"name":"...","arguments":"..."}}]`
  string the assistant produced to call tools). It is what
  `transform_llm_history_to_agent_messages` parses into
  `agent.AgentMessage.tool_calls`. Defaults to `""` for non-assistant
  messages.

- `tool_call_id: ?[]const u8 = null` (line 36) — holds the **tool_call_id
  string** that pairs a tool-result message back to the tool_call that
  produced it. Read by the tool branch of
  `transform_llm_history_to_agent_messages` (line 18) to populate
  `agent.AgentMessage.tool_call_id`. Nullable because non-tool messages
  don't have one.

## Why this bites

A test that was written before the `tool_call_id` field was introduced
(stored the value in `tools` instead) continued to work because the
implementation also read from `tools`. Then commit `ed5e010` ("fixing tool
call id") changed the implementation to read from `tool_call_id` and the
test silently started failing because the test was still setting `tools`.

## Symptom

```
test.transform - tool message ignores image_url (root.zig)
    try std.testing.expect(std.mem.eql(u8, msg.tool_call_id.?, "tool_call_id_123"));
```

`msg.tool_call_id` is `""` (or null) instead of the expected value. The
expectation `msg.tool_call_id != null` passes but the equality check fails.

## Fix in tests

When constructing a `TUIHistory` for a tool-result message, set BOTH fields:

```zig
var history = TUIHistory{
    .id = try allocator.dupe(u8, "msg-1"),
    .role = try allocator.dupe(u8, "tool"),
    .tools = try allocator.dupe(u8, ""),                                    // no tool_calls JSON for tool results
    .tool_call_id = try allocator.dupe(u8, "tool_call_id_123"),            // the tool_call_id of the call this is the result of
    .response_content = try allocator.dupe(u8, "Tool result here"),
    // ...
};
```

The `deinit` on `TUIHistory` (line 58) handles `tool_call_id` correctly:
`if (self.tool_call_id) |tci| allocator.free(tci);`. No special cleanup
needed.

## How to verify

If you see a tool-message transform test fail with `msg.tool_call_id` not
matching, check the test's `TUIHistory` literal — it's almost certainly
putting the value into `.tools` instead of `.tool_call_id`.

The implementation is at `src/ai_workflow/tui/transform_llm_history_to_agent_messages.zig:18`:
`try allocator.dupe(u8, message.tool_call_id orelse "")` — reads from
`tool_call_id`, NOT `tools`. Don't be misled by the field name's similarity
to the SQL column name or the old code.
