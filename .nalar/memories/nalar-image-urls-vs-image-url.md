# nalar — `image_urls` (array) vs `image_url` (string) — the two field shapes

The nalar backend has TWO related but distinct fields for image attachments,
and they live in different Zig structs on either side of the same API. Mixing
them up is a hard compile error and a subtle data-loss bug.

## The two fields

| Field                     | Type             | Lives in                                       | Used by                                                |
|---------------------------|------------------|------------------------------------------------|--------------------------------------------------------|
| `image_urls` (plural)     | `?[][]const u8`  | `llm_history.SaveMessageInput`, `TUIHistory`   | `llm_history.saveMessage`, `models.TUIHistory`         |
| `image_url` (singular)    | `?[]const u8`    | `OnEventInputLLMHistory`, `SseEventLLMHistory` | `on_event_sent.onEventSendLLMHistory`, REST `image_url` field in `SessionMessageResponse` |

The wire format is always **pipe-separated** (`"url1|url2|url3"`) for the
singular `image_url`. The plural `image_urls` is the in-memory split form
(an array of `[]const u8` slices), populated from the pipe-separated DB
column at read time.

## Symptom of the mix-up

You add `.image_url = null,` to a `saveMessage` call:

```zig
_ = llm_history.saveMessage(allocator, io, db, .{
    .session_id = ...,
    ...
    .is_input = true,
    .is_output = false,
    .image_url = null,   // ❌ wrong — SaveMessageInput has image_urls (array)
}) catch {};
```

The build fails with:

```
src/ai_workflow/tui/workflow.zig:85:18: error: no field named 'image_url' in
struct 'ai_workflow.tui.llm_history.SaveMessageInput'
src/ai_workflow/tui/llm_history.zig:900:30: note: struct declared here
```

The fix: use the singular form ONLY on `onEventSendLLMHistory` (the SSE
emitter), and the plural array ONLY on `saveMessage` / `TUIHistory`. The
two structs are siblings — neither one inherits from the other, and the
field names do not match.

## The correct pattern (in workflow.zig)

```zig
// 1. DB write — use plural ARRAY field on SaveMessageInput
_ = llm_history.saveMessage(allocator, io, db, .{
    ...
    .image_urls = image_urls,   // ?[][]const u8
});

// 2. SSE event — use singular STRING field on OnEventInputLLMHistory
on_event_sent.onEventSendLLMHistory(allocator, .{
    ...
    .image_url = if (queued.image_url.len > 0) queued.image_url else null,
    //                                  ^^^^^^^^^^^^ pipe-separated string
});
```

## Why two shapes?

- The **array** form is what the LLM's vision content_parts need
  (`transform_llm_history_to_agent_messages.zig` builds one
  `content_part` per image). Splitting once at read time avoids
  re-splitting on every LLM call.
- The **string** form is what fits in a single TEXT column
  (`llm_history.image_url TEXT`) and what the REST response returns
  (`SessionMessageResponse.image_url`). The frontend splits it back
  into an array via `msg.image_url.split('|')` in `loadChatHistory`
  and (post-fix) the SSE `full` event handler.

## The dual-population sites

`image_url` in the SSE payload is populated at **two** sites in
`workflow.zig` today:

1. **User message from queue** (`workflow.zig:342`) — `queued.image_url`
   is already pipe-separated in the `QueuedMessage` struct.
2. **All other call sites** (`workflow.zig:85`, `:502`, `:585`, `:625` in
   `on_event_sent.zig` after the fix) — pass `null` because the
   message being emitted has no user-attached images (assistant
   responses, error messages, retries).

`handle_tool.zig:593` (tool result path) also passes `null` — tool
results don't carry user images today, but the field is reserved for
forward compatibility (e.g. a future vision tool that returns image
data as a tool result).

## How to verify

After any change to either field:

1. `timeout 180 zig build -freference-trace=5 2>&1 | grep -E "error:|src/ai_workflow/tui/(workflow|handle_tool|on_event_sent|llm_history)\.zig"`
   — must show ZERO errors in those files.
2. `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
   — must show `test success` and no new failures vs the prior baseline.
3. The frontend regression test
   `src/apps/desktop/src/__tests__/sseImageUrls.spec.ts` must still pass
   (`bunx vitest run sseImageUrls`).

## When this bites

- Adding a new caller of `onEventSendLLMHistory` (5 existing call
  sites in `workflow.zig`, 1 in `handle_tool.zig`).
- Adding a new caller of `llm_history.saveMessage` (the array form).
- Migrating any message-store column or response field — both shapes
  need to change in lockstep, and the wire format (pipe-separated
  string) must stay consistent.
- Wiring up the SSE `full` event handler in the frontend — the
  `image_url` field must be split on `|` to populate
  `message.image_urls`, matching the REST `loadChatHistory` path.
