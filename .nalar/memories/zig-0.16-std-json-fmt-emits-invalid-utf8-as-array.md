# Zig 0.16 — `std.json.fmt` emits invalid-UTF-8 strings as ARRAYS of bytes

Zig 0.16's `std.json.fmt` (and `std.json.Stringify.valueAlloc`) emits a `[]const u8`
slice as a JSON STRING only when the slice is valid UTF-8. If the slice contains
any invalid UTF-8 byte, it falls through to the ARRAY branch:

```zig
// /usr/local/lib/zig/std/json/Stringify.zig:506
if (!self.options.emit_strings_as_arrays and std.unicode.utf8ValidateSlice(slice)) {
    return self.stringValue(slice);  // ← emitted as JSON string
}
// else: emitted as JSON array of byte values
try self.beginArray();
for (slice) |x| {
    try self.write(x);
}
try self.endArray();
```

`emit_strings_as_arrays = false` is the default, but it ONLY applies when
the slice is valid UTF-8. There is NO opt-in that forces "always emit as
string".

## Symptom

User-facing: a chat message's `content` field in the JSON response is an
array of integers instead of a string:

```json
"content": [
    60, 116, 111, 116, 97, 108, 60, 116, 105, 109, 101, 115, 60, 47,
    ...
],
"tool_call_id": "call_019f020f9ff9787185b3da91",
```

The decoded bytes are the correct UTF-8 string (`<total<times</total`),
but the JSON wire format is wrong because the value is not a string.

The DB column itself (`response_content` in `llm_history`) stores the
correct TEXT — it's only at the JSON serialization point that the
content becomes an array. So `SELECT response_content FROM llm_history
WHERE id = ...` returns correct text, but the REST API returns an array.

## Why this happens in nalar

The `bash` tool's stdout can contain binary bytes (e.g. `\x89`, `\x93`
from test programs that print raw bytes — `0x89` and `0x93` are
invalid UTF-8 continuation bytes without a start byte). The bash tool
stores stdout as-is in `response_content`. When the SSE path
(`onEventSendLLMHistory` in `src/ai_workflow/tui/on_event_sent.zig`)
emits the event via `std.json.fmt`, the invalid UTF-8 → array
branch fires.

The REST API path (`sessionMessagesHandler` in
`src/ai_workflow/tui/http_handlers/session_messages_get.zig`) ALREADY
calls `helpers.sanitize.sanitizeUtf8(allocator, msg.content)` before
serializing — that's why the REST endpoint shows the correct string
when `makeSessionMessagesResponse` emits it. The SSE path was the
inconsistent one.

## Fix

In any function that serializes a `[]const u8` to JSON via
`std.json.fmt`, sanitize with `helpers.sanitize.sanitizeUtf8` FIRST
if the bytes could contain non-UTF-8 data:

```zig
const sanitized_content: ?[]u8 = blk: {
    const c = input.content orelse break :blk null;
    break :blk try helpers.sanitize.sanitizeUtf8(allocator, c);
};
defer if (sanitized_content) |s| allocator.free(s);

// ... use `sanitized_content orelse input.content orelse ""` in the
// payload struct, so the sanitizer's output goes into the JSON
// serializer, not the raw bytes.
```

`sanitizeUtf8` replaces each invalid byte with U+FFFD (the UTF-8
replacement character, `EF BF BD`), so the output is always valid
UTF-8 and the JSON serializer emits it as a string.

## Where to apply

- `onEventSendLLMHistory` (SSE events) — fixed in commit at the
  bash-tool-corruption task. Apply same to ANY other `std.json.fmt`
  call site that receives tool stdout/stderr or other potentially
  binary data.

## When this bites

- Any tool that pipes or returns binary output (test binaries that
  print control chars, `cat`-ing a binary file, `xxd`, `od`, `time`
  output on systems that emit binary, etc.).
- Any other path that puts user/LLM/tool content into JSON without
  first validating or sanitizing it.
- The frontend receiving `[60, 116, ...]` arrays and trying to render
  them as text (typically fails — Vue templates expect strings).
- SSE streams particularly, because they're a one-shot event with
  no time to fix after the fact (the array is emitted immediately
  and cannot be "corrected" on retry).

## How to verify

```bash
# 1. Check DB content (should be correct text, but bytes may be invalid UTF-8)
sqlite3 ~/.config/nalar/agent.db \
  "SELECT response_content FROM llm_history WHERE id = '1782446723214101839'" \
  | xxd | head -n 30

# 2. After fix: hit the SSE endpoint and confirm content is a JSON string
# (quotes around it), not an array (square brackets after "content":)

# 3. Run the regression test (in src/ai_workflow/tui/on_event_sent_sanitize_test.zig):
#    - "sanitizeUtf8 fixes the exact bytes from the bug"
#    - "SseEventLLMHistory with sanitized UTF-8 emits content as JSON string"
#    - "SseEventLLMHistory with INVALID UTF-8 emits content as byte ARRAY
#      (demonstrates the bug)" — this test DOCUMENTS the bug; if you
#      remove the sanitizeUtf8 call from onEventSendLLMHistory, the
#      static-contract tests in the same file will fail.
```

## Related

- `nalar-http-handler-thin-wrapper-pattern.md` — REST handlers use
  `parseFromSliceLeaky` and `valueAlloc` for proper JSON handling.
- `zig-slice-headers-across-defer-lifetimes.md` — different Zig
  0.16 lifetime/slice bug pattern.
- `nalar-tui-history-tool-call-id-field.md` — different JSON
  serialization pattern (manual `std.fmt.allocPrint` + `jsonEscape`)
  used by `buildSessionMessagesJson`.
