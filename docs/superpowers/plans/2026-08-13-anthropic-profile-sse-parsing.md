# Anthropic URL-Style Profile — Surface Real Server Errors + Parse Anthropic SSE

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-13
**Branch:** `worktree/anthropic-sse-parsing`
**Bug report:** task `task_1786601628444` (kanban: "antropic profile not work")
**User quote (verbatim):** *"when using profile with api style antropic its not working, the error like this, can show the real error message from server ?"*

User's symptom (production log, 2026-08-13 06:12:48 UTC, session `session-1786601533417`):

```
[CHECKPOINT] calling LLM session_id=session-1786601533417 model=MiniMax-M3 loop_counter=1 prompt_msg_count=2 max_tokens=20000 retry_count=2
ERROR Error calling dynamic agent: StreamInterrupted now retrying after 10000ms delay — server: stream ended without finish_reason after 0 chunk(s)
ERROR Retry 3/10: StreamInterrupted (callDynamicAgentNew). Retrying in 10000ms.
```

The user is asking two related questions:
1. **Why does Anthropic not work?** (Profile is configured with `url_style=anthropic`, but every call retries 10× and bails.)
2. **Where is the real server error?** (The message says "0 chunk(s)" — the server's actual response is hidden.)

## TL;DR

`Agent.zig::callStreaming` parses the LLM provider's SSE stream with **OpenAI-only assumptions** (`choices[0].delta.content` etc.). Anthropic's `/v1/messages` endpoint uses a **different SSE format** (`event: …` lines + `data: {"type":"content_block_delta", …}` JSON), so every line parses to `null` and `chunk_count` stays at 0. When the stream finishes with no `finish_reason` chunk observed, the code synthesises the opaque message `"stream ended without finish_reason after 0 chunk(s)"` — which hides what the server actually sent.

The fix has two parts:

- **Part A (cheap, ships first)** — Capture a raw SSE sample whenever `parse_stream_chunk` fails while `chunk_count == 0`, and surface that sample in `last_error_message` so the user (and any future debug tooling) sees what the server really returned. Independent value: helps diagnose every future profile that uses a different SSE format.
- **Part B (the real fix)** — Add a sibling parser `parse_anthropic_stream_chunk` that maps Anthropic's events into the same `StreamChunk` shape the workflow already consumes, and dispatch on `self.UrlStyle` from `parse_stream_chunk`. After Part B, the profile actually streams and the chat works.

Both parts land in this plan because Part B alone still leaves Part A's value on the table for any *other* non-OpenAI profile.

## Investigation findings

### The bug surface

`src/modules/agent/Agent.zig:1192` — `callStreaming`:

- **L1204-1219** — builds the request body: branches on `self.UrlStyle == "anthropic"` to call `buildJsonAnthropicRequest` (the **request** is correctly Anthropic-shaped — `model`, `messages`, `max_tokens`, `stream`, `tools`, `thinking`, `metadata`, `stream_options.include_usage`).
- **L1232-1235** — picks the endpoint: `/v1/messages` for Anthropic, `/chat/completions` otherwise. ✅ Correct.
- **L1267-1283** — auth header: `Bearer <apiKey>` (matches both). ✅ Correct.
- **L1306-1338** — drains the HTTP error body when `status >= 400`, sets `last_error_message = "HTTP {d}: {body}"`, returns `error.ApiError`. ✅ Correctly surfaces 401/400/429 etc.
- **L1341** — wraps the body in `StreamScanner` for line-by-line SSE reads.
- **L1091-1097** — `parse_sse_line` keeps only lines starting with `data: ` (drops `event: …` lines and `[DONE]`). For OpenAI that's all the lines; for Anthropic it still extracts the `data:` payload — but…
- **L1099-1190** — `parse_stream_chunk` only handles `choices[0].delta.*` (OpenAI format). For Anthropic every payload looks like `{"type":"message_start","message":{…}}` / `{"type":"content_block_delta","delta":{"type":"text_delta","text":"…"}}` / `{"type":"message_delta","delta":{"stop_reason":"end_turn"}}` / `{"type":"message_stop"}` — none of which have a `choices` key, so the function returns `null` for every line.
- **L1416-1422** — caller logs `"[STREAM] parse_stream_chunk returned null for: {data}"` at `.err` level but does **not** capture the raw line anywhere else.
- **L1441-1457** — final check: `if (aggregator.finish_reason == null)` → log `"[STREAM] stream ended without finish_reason (chunks={N})"`, set `last_error_message = "stream ended without finish_reason after {N} chunk(s)"`, return `error.StreamInterrupted`.

Net effect for Anthropic: server sends a perfectly valid SSE stream, the parser silently drops every event, `chunk_count` stays at 0, `finish_reason` is `null`, and the workflow sees `error.StreamInterrupted` with no hint about why.

### Anthropic's SSE format (the spec we're missing)

Anthropic sends events like this on `POST /v1/messages` with `"stream": true`:

```
event: message_start
data: {"type":"message_start","message":{"id":"msg_…","type":"message","role":"assistant","content":[],"model":"claude-…","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":N,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":N}}

event: message_stop
data: {"type":"message_stop"}
```

Extended-thinking profile adds `type: "thinking"` blocks with `thinking_delta` events carrying the reasoning text:

```
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"…"}}
```

Tool-use profile emits `type: "tool_use"` blocks with `input_json_delta` partial JSON:

```
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_…","name":"bash","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"ls"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":\""}}
```

Error responses (auth, model not found, overloaded) come back as **non-streaming** HTTP errors with `status >= 400` — those are already drained at L1306-1338. ✅ No change needed there.

### Mapping Anthropic events → existing `StreamChunk`

| Anthropic event | Existing `StreamChunk` field |
|---|---|
| `content_block_delta.delta.text_delta.text` | `content` |
| `content_block_delta.delta.thinking_delta.thinking` | `reasoning_content` |
| `content_block_start.content_block` (type=`tool_use`) | `tool_calls_delta[i]` with `id` + `function_name` |
| `content_block_delta.delta.input_json_delta.partial_json` | `tool_calls_delta[i].function_arguments` (appended by aggregator) |
| `message_delta.delta.stop_reason` (`end_turn` → `.stop`, `max_tokens` → `.length`, `tool_use` → `.tool_calls`, `stop_sequence` → `.stop`, `refusal` → `.content_filter`) | `finish_reason` |
| `message_delta.usage.output_tokens` | (merged into `usage` — input_tokens comes from `message_start`) |

`message_start.usage.input_tokens` is the only usage hint that arrives before any chunk — emit it on the first delta so the aggregator can carry it through. (Or stash it in a per-call context variable; the minimal change is to emit a `usage` chunk on the **first** `content_block_delta` after `message_start`, populated with the cached input_tokens. This is what the existing OpenAI parser already does with `stream_options.include_usage=true`.)

### `StreamingAggregator.process_chunk` already handles the delta shape

`Agent.zig:611-654` — given `StreamChunk` with `tool_calls_delta[]`, the aggregator:

- Buffers `id`, `function_name` (overwrites), appends `function_arguments` per index. ✅ Exact shape we need.
- On `finalize()` (L656-712) sorts indices ascending and emits one `ToolCall` per index. ✅ Already handles non-contiguous indices (Anthropic tools always use `index=0` for single calls, but for parallel calls Anthropic uses `index=0,1,2…`).

So Part B's parser just needs to emit the right `StreamChunk` — no aggregator changes.

## Architecture

### Single file touched: `src/modules/agent/Agent.zig`

1. **Part A** — Add a `raw_sse_sample: std.ArrayList(u8)` buffer in `callStreaming` (init/deinit alongside the existing `line_arena`). When `parse_stream_chunk` returns `null` AND `chunk_count == 0`, append the raw `data` line + `'\n'` (capped at 2 KiB). When the stream ends with no `finish_reason` and the buffer is non-empty, fold a 2 KiB-truncated sample (with a trailing `…` marker) into `last_error_message`. The error log line gets the same content for post-mortem grep.

2. **Part B** — Add a new private function `parse_anthropic_stream_chunk(self: Agent, data: []const u8, arena: std.mem.Allocator, input_tokens: *u32) ?StreamChunk` that:
   - Reads `type` from the root.
   - `message_start` → cache `message.usage.input_tokens` into `input_tokens.*` (no chunk emitted — wait for first delta so the aggregator sees a single usage event at the right time).
   - `content_block_delta` → if `delta.text_delta.text` present, set `chunk.content`; if `delta.thinking_delta.thinking` present, set `chunk.reasoning_content`; if `delta.input_json_delta.partial_json` present, set `chunk.tool_calls_delta = &[_]ToolCallDelta{.{.index = index, .function_arguments = partial_json}}`. Emit `chunk.usage = .{input_tokens, 0, input_tokens}` on the first delta only.
   - `content_block_start` (tool_use) → set `chunk.tool_calls_delta = &[_]ToolCallDelta{.{.index = index, .id = content_block.id, .function_name = content_block.name}}`.
   - `message_delta` → set `chunk.finish_reason` from `delta.stop_reason` (mapping table above) and `chunk.usage.output_tokens` from `delta.usage.output_tokens`.
   - `message_stop` / `content_block_stop` → return `null` (no-op signals).
   - Anything else → return `null`.
3. **Part B (wire-up)** — Inside `parse_stream_chunk`, branch on `self.UrlStyle` at the top: if `"anthropic"` → call `parse_anthropic_stream_chunk`; else (OpenAI/default) → existing logic. The `input_tokens` accumulator is a tiny per-call scratch value — simplest implementation: a stack `var input_tokens: u32 = 0;` passed by pointer, lives next to the `line_arena`.

### Files changed

| File | Change |
|---|---|
| `src/modules/agent/Agent.zig` | New: `parse_anthropic_stream_chunk`. Modified: `callStreaming` (raw SSE buffer + UrlStyle dispatch), `parse_stream_chunk` (delegate to anthropic branch). |
| `src/modules/agent/parse_anthropic_sse_test.zig` (NEW) | Unit tests for the parser + end-to-end via fake HTTP server (reuses the `FakeServer` pattern from `call_streaming_test.zig`). |
| `src/modules/agent/test_runner.zig` | Add `_ = @import("parse_anthropic_sse_test.zig");`. |
| `docs/SPEC.md` | Changelog entry. |
| `AGENTS.md` | Changelog entry. |

### Files NOT changed

- `src/ai_workflow/tui/agentic_loop/workflow.zig` — error propagation already wired (`last_dynamic_agent_error_message` → logger). The Part A fix in `Agent.zig` flows through automatically.
- `src/root.zig` — already re-exports `agent` publicly; no surface change.
- Frontend (Vue/TS) — no change. The existing error message rendering already shows `last_dynamic_agent_error_message` in the user-visible retry log.
- `build.zig` — no change. Tests pick up via `src/modules/agent/test_runner.zig`.
- `buildJsonAnthropicRequest` — request body already correct (verified via `agent_request_user_id_test.zig`).

## Behavioural matrix (after both parts)

| Profile `url_style` | Server response | Before | After (Part A only) | After (Parts A+B) |
|---|---|---|---|---|
| `openai` (or unset) | OpenAI 200 + chunks | Works | Works | Works |
| `openai` | OpenAI 200 + no `finish_reason` chunk | `StreamInterrupted`, "0 chunk(s)" | `StreamInterrupted`, "0 chunk(s)" + raw SSE sample | Same as Part A |
| `openai` | OpenAI 401/400/429 | `ApiError` + HTTP body | `ApiError` + HTTP body | `ApiError` + HTTP body |
| `anthropic` | Anthropic 200 + valid stream | `StreamInterrupted`, "0 chunk(s)" | `StreamInterrupted`, "0 chunk(s)" + raw SSE sample | **Streams normally** (text deltas → `chunk.content`, reasoning → `chunk.reasoning_content`, tool_use → `chunk.tool_calls_delta`, stop_reason → `chunk.finish_reason`) |
| `anthropic` | Anthropic 401 (bad key) | `ApiError` + HTTP body | `ApiError` + HTTP body | `ApiError` + HTTP body |
| `anthropic` | Anthropic 400 (model not found) | `ApiError` + HTTP body | `ApiError` + HTTP body | `ApiError` + HTTP body |
| `anthropic` | Anthropic 200 + extended thinking | `StreamInterrupted`, "0 chunk(s)" | `StreamInterrupted`, "0 chunk(s)" + raw SSE sample | **Streams normally** (reasoning → `chunk.reasoning_content`) |
| `anthropic` | Anthropic 200 + tool_use | `StreamInterrupted`, "0 chunk(s)" | `StreamInterrupted`, "0 chunk(s)" + raw SSE sample | **Streams normally** (tool_use → `chunk.tool_calls_delta[]`) |
| `custom` (anything else) | Unknown | Falls through to OpenAI parser | Falls through + raw SSE sample on failure | Falls through to OpenAI parser (Part A still helps) |

## Global Constraints

- **No wire-shape change.** `StreamChunk` shape stays the same; the `StreamingAggregator` stays the same; the `CallResponse` stays the same.
- **No new error variant.** Re-use `error.StreamInterrupted` (the existing label fits both "the connection died" and "the stream ended without a parseable finish reason").
- **Cross-platform parity.** Pure Zig change — Linux/macOS/Windows compile + test must all pass.
- **Surgical edits only.** No refactoring of existing OpenAI parsing; the new parser is a sibling, and the dispatch is one `if/else` at the top of `parse_stream_chunk`.
- **Backward compatible.** A profile with `url_style=openai` (the default) and an OpenAI-shaped server keeps working unchanged — the new branch is only taken when `url_style == "anthropic"`.
- **No DB migration.** No schema change.
- **No frontend change.** Existing error-rendering path already surfaces `last_dynamic_agent_error_message`.

## Task 1: Capture raw SSE sample when chunk_count stays at 0 (Part A)

**File:** `src/modules/agent/Agent.zig` (modify `callStreaming`, L1192-1479)

**Step 1.1:** Write the failing test.

**File:** `src/modules/agent/parse_anthropic_sse_test.zig` (NEW)

Add this test (uses the same `FakeServer` pattern as `call_streaming_test.zig:210-288`; copy the `FakeServer` + `serve` + `nowMs` helpers from that file into the new test file so this one is self-contained):

```zig
test "callStreaming includes raw SSE sample in last_error_message when 0 chunks parsed (url_style=anthropic, OpenAI-shaped server)" {
    const a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.apiKey = "test-key";
    a.model = "claude-test";
    a.baseUrl = "http://127.0.0.1";
    a.UrlStyle = "anthropic"; // forces the URL path to /v1/messages
    a.httpOptions.read_timeout_ms = 5_000;

    // Server sends valid SSE but with OpenAI-shaped JSON (mimics the user's
    // reproduction: the server speaks, but our parser doesn't understand it
    // because url_style=anthropic was selected and we're about to wire in
    // the Anthropic parser in Task 2 — for now, we just want to see the raw
    // SSE in the error message).
    const head =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    const body =
        "7\r\n" ++
        "event: foo\r\n" ++
        "\r\n" ++
        "0\r\n\r\n";

    var server = try FakeServer.startWithResponse(head, body);
    defer server.shutdown();

    const port = server.port;
    const base_url = try std.fmt.allocPrint(testing_allocator, "http://127.0.0.1:{d}", .{port});
    defer testing_allocator.free(base_url);
    a.baseUrl = base_url;

    const params = agent.AgentCall{ .messages = &.{}, .tools = &.{} };
    var cb_ctx: agent.StreamChunk = .{};
    _ = a.callStreaming(params, &cb_ctx, dummyCallback) catch |err| {
        try expectEqual(error.StreamInterrupted, err);
        try expect(a.last_error_message != null);
        const msg = a.last_error_message.?;
        // The error message must include the actual raw SSE we received —
        // not just "0 chunk(s)".
        try expect(std.mem.indexOf(u8, msg, "event: foo") != null);
        return;
    };
    return error.TestExpectedCallStreamingError;
}
```

(Use `expectError` and `expect` from `std.testing`. The `dummyCallback` is a no-op `*const fn (ctx, chunk) void`. The `FakeServer.startWithResponse` is a 5-line helper added to this test file — it takes prebuilt head+body strings instead of a `ServerBehavior` enum. The chunked-encoding wrapper `7\r\n…\r\n0\r\n\r\n` is what `Transfer-Encoding: chunked` requires; `7` is the byte-length of `"event: foo"`.)

**Step 1.2:** Register the new test file.

**File:** `src/modules/agent/test_runner.zig`

Add `_ = @import("parse_anthropic_sse_test.zig");` alongside the existing `call_streaming_test.zig` import (L9).

**Step 1.3:** Run the test and confirm it FAILS.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg -A 3 'parse_anthropic_sse_test|FAIL'
```

Expected: the new test fails with `last_error_message == null` or `msg` not containing `"event: foo"`. The OpenAI parser swallows everything because no `choices` key exists.

**Step 1.4:** Implement the raw SSE buffer in `callStreaming`.

**File:** `src/modules/agent/Agent.zig`

Inside `callStreaming`, alongside the existing `line_arena` (L1348-1349), add:

```zig
// Raw SSE sample buffer. Populated when parse_stream_chunk returns null
// AND chunk_count stays at 0 — lets us surface the server's actual
// payload in the StreamInterrupted error message instead of hiding
// everything behind "0 chunk(s)". Capped at 2 KiB; older content is
// discarded once the cap is reached (we keep the FIRST bytes so the
// user sees the start of the stream, which is where auth errors and
// framework-specific error envelopes tend to appear).
var raw_sse_sample: std.ArrayList(u8) = .empty;
defer raw_sse_sample.deinit(self.allocator);
const max_raw_sse_sample_len: usize = 2048;
```

In the SSE loop (L1412-1425), change the `parse_stream_chunk` branch from:

```zig
if (self.parse_stream_chunk(data, line_arena.allocator())) |chunk| {
    chunk_count += 1;
    callback(ctx, chunk);
    aggregator.process_chunk(chunk) catch {};
} else {
    self.log_fmt(.err, "[STREAM] parse_stream_chunk returned null for: {s}", .{data});
}
```

to:

```zig
if (self.parse_stream_chunk(data, line_arena.allocator())) |chunk| {
    chunk_count += 1;
    callback(ctx, chunk);
    aggregator.process_chunk(chunk) catch {};
} else {
    self.log_fmt(.err, "[STREAM] parse_stream_chunk returned null for: {s}", .{data});
    // Capture the raw SSE line for the final-error message — only while
    // chunk_count == 0 (i.e. the server's first lines are still unparsed).
    // Once we successfully parse ANY chunk we know the format is one we
    // understand, so additional raw samples would just be noise.
    if (chunk_count == 0 and raw_sse_sample.items.len < max_raw_sse_sample_len) {
        raw_sse_sample.appendSlice(self.allocator, data) catch {};
        raw_sse_sample.append(self.allocator, '\n') catch {};
    }
}
```

Update the "stream ended without finish_reason" block (L1441-1457) to:

```zig
if (aggregator.finish_reason == null) {
    self.log_fmt(.err, "[STREAM] stream ended without finish_reason (chunks={d})", .{chunk_count});

    // Build the error detail. When we received ANY SSE lines but parsed
    // 0 of them, include a truncated raw sample so the user can see what
    // the server actually sent. Format:
    //   "stream ended without finish_reason after 0 chunk(s); first server lines: event: foo\n..."
    const truncated = raw_sse_sample.items.len >= max_raw_sse_sample_len;
    const sample_for_msg: []const u8 = if (raw_sse_sample.items.len > 0)
        if (truncated)
            raw_sse_sample.items[0 .. max_raw_sse_sample_len - 3] ++ "..."
        else
            raw_sse_sample.items
    else
        "";
    const detail: ?[]u8 = if (sample_for_msg.len > 0)
        std.fmt.allocPrint(
            self.allocator,
            "stream ended without finish_reason after {d} chunk(s); first server lines: {s}",
            .{ chunk_count, sample_for_msg },
        ) catch null
    else
        std.fmt.allocPrint(
            self.allocator,
            "stream ended without finish_reason after {d} chunk(s)",
            .{chunk_count},
        ) catch null;
    if (detail) |d| {
        if (self.last_error_message) |prev| self.allocator.free(prev);
        self.last_error_message = d;
    }
    return error.StreamInterrupted;
}
```

**Step 1.5:** Re-run the test and confirm it PASSES.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg -A 3 'parse_anthropic_sse_test|FAIL'
```

Expected: test passes. The error message now contains `"event: foo"`.

**Step 1.6:** Run the full test suite and confirm zero regressions.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg -E '(FAIL|error:|leaked)'
```

Expected: zero new failures, zero new leaks. (The OpenAI parser tests still pass because they hit the OpenAI-shaped server with OpenAI's UrlStyle, which never enters the new branch.)

**Step 1.7:** Commit.

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/modules/agent/Agent.zig src/modules/agent/parse_anthropic_sse_test.zig src/modules/agent/test_runner.zig
git commit -m "agent: capture raw SSE sample in last_error_message when 0 chunks parsed

When a profile's url_style doesn't match the server's SSE format (e.g.
url_style=anthropic with a custom server speaking a different dialect),
every SSE line fails to parse and the workflow sees the opaque
'stream ended without finish_reason after 0 chunk(s)' — with no hint
about what the server actually sent.

Capture the first 2 KiB of raw SSE data lines (only while chunk_count
stays at 0, to keep the buffer focused on the failure case) and fold a
truncated sample into last_error_message. The workflow retry log then
shows what the server really returned, e.g.:
  'stream ended without finish_reason after 0 chunk(s); first server
   lines: event: foo\n...'

Independent of any future parser — every other profile that fails to
parse benefits."
```

## Task 2: Implement `parse_anthropic_stream_chunk` (Part B — parser)

**File:** `src/modules/agent/Agent.zig`

**Step 2.1:** Extend the failing test with a positive case.

**File:** `src/modules/agent/parse_anthropic_sse_test.zig`

Add this test (server speaks real Anthropic SSE):

```zig
test "callStreaming parses Anthropic SSE: text content + stop_reason = end_turn" {
    const a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.apiKey = "test-key";
    a.model = "claude-test";
    a.UrlStyle = "anthropic";
    a.httpOptions.read_timeout_ms = 5_000;

    // Hand-craft a valid Anthropic /v1/messages response (chunked-encoded):
    //   event: message_start (carries input_tokens=10)
    //   event: content_block_start (text)
    //   event: content_block_delta (text "Hello")
    //   event: content_block_delta (text " world")
    //   event: content_block_stop
    //   event: message_delta (stop_reason=end_turn, output_tokens=2)
    //   event: message_stop
    const sse =
        "event: message_start\r\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_x\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-test\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\r\n" ++
        "\r\n" ++
        "event: content_block_start\r\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\r\n" ++
        "\r\n" ++
        "event: content_block_delta\r\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\r\n" ++
        "\r\n" ++
        "event: content_block_delta\r\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}\r\n" ++
        "\r\n" ++
        "event: content_block_stop\r\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\r\n" ++
        "\r\n" ++
        "event: message_delta\r\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":2}}\r\n" ++
        "\r\n" ++
        "event: message_stop\r\n" ++
        "data: {\"type\":\"message_stop\"}\r\n" ++
        "\r\n";
    const head =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    const body = try chunkEncode(testing_allocator, sse);
    defer testing_allocator.free(body);

    var server = try FakeServer.startWithResponse(head, body);
    defer server.shutdown();

    const base_url = try std.fmt.allocPrint(testing_allocator, "http://127.0.0.1:{d}", .{server.port});
    defer testing_allocator.free(base_url);
    a.baseUrl = base_url;

    const params = agent.AgentCall{ .messages = &.{}, .tools = &.{} };
    var cb: CapturingCb = .{};
    const resp = try a.callStreaming(params, &cb, capturingCallback);

    try expectEqualStrings("Hello world", resp.content.?);
    try expectEqual(@as(?agent.FinishReason, .stop), resp.finish_reason);
    try expectEqual(@as(usize, 10), resp.usage.prompt_tokens);
    try expectEqual(@as(usize, 2), resp.usage.completion_tokens);
}
```

Where `chunkEncode` is a small helper that wraps an SSE body in chunked-encoding (`<len-hex>\r\n<body>\r\n0\r\n\r\n`) and `CapturingCb` / `capturingCallback` capture every `StreamChunk` that the streaming path emits (just an `std.ArrayList(agent.StreamChunk)` + a global in the test file). Both helpers are added at the top of `parse_anthropic_sse_test.zig`.

**Step 2.2:** Run and confirm FAIL.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg -A 4 'parses Anthropic SSE|FAIL'
```

Expected: the new test fails — currently `parse_stream_chunk` returns null for every line because the parser is OpenAI-only.

**Step 2.3:** Implement `parse_anthropic_stream_chunk`.

**File:** `src/modules/agent/Agent.zig`

Add the function immediately after `parse_stream_chunk` (after L1190). Signature takes a `*u32` for the input_tokens accumulator:

```zig
/// Anthropic streaming-SSE → StreamChunk mapper.
///
/// Anthropic's /v1/messages streams `event:` + `data:` pairs (the wire shape
/// the OpenAI parser doesn't understand). We translate the events the
/// workflow cares about into the same `StreamChunk` shape the OpenAI
/// parser produces, so the rest of the pipeline (StreamingAggregator,
/// CallResponse, the workflow loop) doesn't need to know which provider
/// it's talking to.
///
/// Event → StreamChunk mapping (see plan §"Mapping Anthropic events →
/// existing StreamChunk"):
///   message_start           → caches input_tokens (no chunk emitted)
///   content_block_delta     → text_delta|thinking_delta|input_json_delta
///   content_block_start     → tool_use → tool_calls_delta[i] with id+name
///   message_delta           → finish_reason + output_tokens
///   message_stop            → no-op (signal-only)
///   content_block_stop      → no-op (signal-only)
///   anything else           → return null
///
/// `input_tokens_acc` is a per-call scratch value — the agent caches the
/// input_tokens from message_start and emits it on the first delta so the
/// aggregator sees a single usage event with all known counts.
fn parse_anthropic_stream_chunk(
    self: Agent,
    data: []const u8,
    arena: std.mem.Allocator,
    input_tokens_acc: *u32,
) ?StreamChunk {
    const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
        const max_data_len = 200;
        const truncated = data.len > max_data_len;
        const data_to_log = if (truncated) data[0..max_data_len] else data;
        if (truncated) {
            self.log_fmt(.err, "Anthropic SSE JSON parse failed: {s}\nData (truncated): {s}...", .{ @errorName(err), data_to_log });
        } else {
            self.log_fmt(.err, "Anthropic SSE JSON parse failed: {s}\nData: {s}", .{ @errorName(err), data_to_log });
        }
        return null;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const type_val = root.object.get("type") orelse return null;
    if (type_val != .string) return null;
    const event_type = type_val.string;

    if (std.mem.eql(u8, event_type, "message_start")) {
        // Cache input_tokens from message.message.usage.input_tokens.
        const message = root.object.get("message") orelse return null;
        if (message != .object) return null;
        const usage = message.object.get("usage") orelse return null;
        if (usage != .object) return null;
        if (usage.object.get("input_tokens")) |it| {
            if (it == .integer) input_tokens_acc.* = @intCast(it.integer);
        }
        return null; // No chunk to emit; first delta will carry the usage.
    }

    var chunk: StreamChunk = .{};

    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const index = root.object.get("index") orelse return null;
        const cb = root.object.get("content_block") orelse return null;
        if (index != .integer or cb != .object) return null;
        const cb_type = cb.object.get("type") orelse return null;
        if (cb_type != .string) return null;
        if (!std.mem.eql(u8, cb_type.string, "tool_use")) return null;

        const id_val = cb.object.get("id") orelse return null;
        const name_val = cb.object.get("name") orelse return null;
        if (id_val != .string or name_val != .string) return null;

        const delta_slice = arena.alloc(ToolCallDelta, 1) catch return null;
        delta_slice[0] = .{
            .index = @intCast(index.integer),
            .id = id_val.string,
            .function_name = name_val.string,
        };
        chunk.tool_calls_delta = delta_slice;
    } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const index_val = root.object.get("index") orelse return null;
        const delta = root.object.get("delta") orelse return null;
        if (index_val != .integer or delta != .object) return null;
        const index: usize = @intCast(index_val.integer);

        const delta_type = delta.object.get("type") orelse return null;
        if (delta_type != .string) return null;

        if (std.mem.eql(u8, delta_type.string, "text_delta")) {
            const text = delta.object.get("text") orelse return null;
            if (text != .string) return null;
            chunk.content = text.string;
        } else if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
            const thinking = delta.object.get("thinking") orelse return null;
            if (thinking != .string) return null;
            chunk.reasoning_content = thinking.string;
        } else if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
            const partial = delta.object.get("partial_json") orelse return null;
            if (partial != .string) return null;
            const delta_slice = arena.alloc(ToolCallDelta, 1) catch return null;
            delta_slice[0] = .{
                .index = index,
                .function_arguments = partial.string,
            };
            chunk.tool_calls_delta = delta_slice;
        } else {
            return null; // unknown delta type — ignore
        }

        // Emit a usage chunk on the FIRST delta so the aggregator sees the
        // input_tokens count we cached from message_start. Mirrors how the
        // OpenAI parser uses stream_options.include_usage=true to get a
        // trailing usage chunk.
        if (input_tokens_acc.* > 0 and !self._anthropic_usage_emitted) {
            chunk.usage = .{
                .prompt_tokens = input_tokens_acc.*,
                .completion_tokens = 0,
                .total_tokens = input_tokens_acc.*,
            };
            // We can't mutate `self` from a free function — see Step 2.4
            // for how this flag moves into the agent struct.
        }
    } else if (std.mem.eql(u8, event_type, "message_delta")) {
        const delta = root.object.get("delta") orelse return null;
        if (delta != .object) return null;
        if (delta.object.get("stop_reason")) |sr| {
            if (sr == .string) {
                chunk.finish_reason = FinishReason.from_str(map_anthropic_stop_reason(sr.string));
            }
        }
        if (root.object.get("usage")) |usage_val| {
            if (usage_val == .object) {
                if (usage_val.object.get("output_tokens")) |ot| {
                    if (ot == .integer) {
                        chunk.usage = .{
                            .prompt_tokens = input_tokens_acc.*,
                            .completion_tokens = @intCast(ot.integer),
                            .total_tokens = input_tokens_acc.* + @as(u32, @intCast(ot.integer)),
                        };
                    }
                }
            }
        }
    } else {
        // message_stop, content_block_stop, ping, anything else — no-op.
        return null;
    }

    return chunk;
}

/// Anthropic's stop_reason strings don't match OpenAI's. Map them:
///   end_turn       → "stop"
///   tool_use       → "tool_calls"
///   max_tokens     → "length"
///   stop_sequence  → "stop"
///   refusal        → "content_filter"
fn map_anthropic_stop_reason(s: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, s, "end_turn")) return "stop";
    if (std.mem.eql(u8, s, "tool_use")) return "tool_calls";
    if (std.mem.eql(u8, s, "max_tokens")) return "length";
    if (std.mem.eql(u8, s, "stop_sequence")) return "stop";
    if (std.mem.eql(u8, s, "refusal")) return "content_filter";
    return null;
}
```

**Step 2.4:** Add a per-Agent "usage already emitted" flag so the `input_tokens` is sent exactly once per call.

**File:** `src/modules/agent/Agent.zig`

In the `Agent` struct (L770-790), add a new field (alongside `last_error_message`):

```zig
/// Set by `parse_anthropic_stream_chunk` when we emit the first usage
/// chunk on the first `content_block_delta` after `message_start`.
/// Resets to false at the top of every `callStreaming` invocation.
/// Mirrors how the OpenAI parser only emits usage once (driven by
/// `stream_options.include_usage=true`).
_anthropic_usage_emitted: bool = false,
```

Reset it at the top of `callStreaming` (just after L1200 — the `[STREAM START]` log):

```zig
self._anthropic_usage_emitted = false;
```

Update the `parse_anthropic_stream_chunk` function to consult and set this flag instead of the `_anthropic_usage_emitted` placeholder comment from Step 2.3. The reference becomes `if (input_tokens_acc.* > 0 and !self._anthropic_usage_emitted) { ...; self._anthropic_usage_emitted = true; }`.

**Step 2.5:** Wire the dispatch in `parse_stream_chunk`.

**File:** `src/modules/agent/Agent.zig`

At the top of `parse_stream_chunk` (L1099-1112), add a UrlStyle branch. The Anthropic branch needs the `input_tokens_acc` state — so we stash it on the Agent struct (Step 2.4 already added `_anthropic_usage_emitted`; add a sibling `_anthropic_input_tokens: u32 = 0`):

```zig
_anthropic_input_tokens: u32 = 0,
```

Reset it next to `_anthropic_usage_emitted` at the top of `callStreaming`:

```zig
self._anthropic_input_tokens = 0;
```

Then change the top of `parse_stream_chunk` from:

```zig
pub fn parse_stream_chunk(self: Agent, data: []const u8, arena: std.mem.Allocator) ?StreamChunk {
    const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
        ...
    };
```

to:

```zig
pub fn parse_stream_chunk(self: Agent, data: []const u8, arena: std.mem.Allocator) ?StreamChunk {
    // Anthropic uses a different SSE event shape (event: + data: with a
    // `type` field). Dispatch on UrlStyle so the rest of the pipeline
    // sees the same StreamChunk shape regardless of provider.
    if (std.mem.eql(u8, self.UrlStyle, "anthropic")) {
        return self.parse_anthropic_stream_chunk(data, arena, &self._anthropic_input_tokens);
    }
    const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
        ...
    };
```

(The `parse_anthropic_stream_chunk` signature stays `(self, data, arena, *u32)` — the dispatcher wires `&self._anthropic_input_tokens` in.)

**Step 2.6:** Re-run the test and confirm PASS.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg -A 4 'parses Anthropic SSE|FAIL'
```

Expected: the Anthropic test passes. The Part A test from Step 1.1 still passes (the test sends `event: foo` with no JSON body — `parse_anthropic_stream_chunk` returns null because there's no `type` field, raw SSE buffer captures the line, error message includes the sample).

**Step 2.7:** Add extended-thinking + tool_use test cases (regression coverage).

**File:** `src/modules/agent/parse_anthropic_sse_test.zig`

Add two more tests:

```zig
test "callStreaming parses Anthropic SSE: extended thinking deltas populate reasoning_content" {
    // Same shape as the text test, but:
    //   - block 0 is type=thinking with thinking_delta events
    //   - block 1 is type=text with text_delta events
    // Assert: resp.reasoning_content contains the concatenated thinking
    // text; resp.content contains the concatenated response text;
    // resp.finish_reason == .stop.
}

test "callStreaming parses Anthropic SSE: tool_use produces tool_calls_delta with id+name+args" {
    // Stream emits:
    //   content_block_start (tool_use, id=toolu_x, name=bash, input={})
    //   content_block_delta (input_json_delta partial='{"command":')
    //   content_block_delta (input_json_delta partial=' "ls"}')
    //   content_block_stop
    //   message_delta (stop_reason=tool_use, output_tokens=5)
    // Assert: resp.finish_reason == .tool_calls; resp.tool_calls[0].id ==
    // "toolu_x"; resp.tool_calls[0].function.name == "bash"; arguments
    // parses to {"command": "ls"}.
}
```

Run the test suite and confirm all three new tests pass + zero regressions.

**Step 2.8:** Run the full test suite.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg -E '(FAIL|error:|leaked)'
```

Expected: zero new failures, zero new leaks.

**Step 2.9:** Commit.

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/modules/agent/Agent.zig src/modules/agent/parse_anthropic_sse_test.zig
git commit -m "agent: parse Anthropic /v1/messages SSE events into StreamChunk

Anthropic's streaming protocol uses event: + data: pairs with a 'type'
field (message_start, content_block_start, content_block_delta,
content_block_stop, message_delta, message_stop) — completely different
from OpenAI's choices[0].delta shape. The existing parse_stream_chunk
returned null for every Anthropic line, so the workflow saw
'stream ended without finish_reason after 0 chunk(s)' on every call.

Add parse_anthropic_stream_chunk that maps the events the workflow
actually consumes into the same StreamChunk shape:

  content_block_delta.text_delta       → chunk.content
  content_block_delta.thinking_delta   → chunk.reasoning_content
  content_block_delta.input_json_delta → chunk.tool_calls_delta[i].args
  content_block_start (tool_use)       → chunk.tool_calls_delta[i].id+name
  message_delta.stop_reason            → chunk.finish_reason
                                        (end_turn→stop, tool_use→tool_calls,
                                         max_tokens→length, refusal→content_filter)
  message_start.usage.input_tokens     → cached, emitted on first delta

The StreamingAggregator needs no changes — its tool_calls_delta[i]
indexed-merge logic already handles non-contiguous indices (Anthropic
parallel tool calls use index=0,1,2…).

dispatcher: parse_stream_chunk branches on self.UrlStyle == 'anthropic'
at the top. OpenAI parser is untouched — backward compatible."
```

## Task 3: Cross-compile + build verification

**Steps:**

- [ ] `timeout 180 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig` — expect clean.
- [ ] `timeout 180 zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig` — expect clean.
- [ ] `timeout 240 rm -rf zig-out/bin && zig build` — expect all binaries produced.
- [ ] Confirm `zig build test --summary all` still passes end-to-end.

## Task 4: Live smoke (manual, against a real Anthropic profile)

**Steps:**

- [ ] **DO NOT kill the existing `pabrik` on port 8081** (PID 538546 — that's the user's running instance per the port rules in `AGENTS.md`). Use port 8080 for testing.
- [ ] Start the freshly-built binary on 8080:
    ```bash
    cd /home/ginwa/ginwaaitoolbox
    timeout 180 ./zig-out/bin/pabrik --port 8080 > /tmp/anthropic_smoke_8080.log 2>&1 &
    echo $! > /tmp/anthropic_smoke_8080.pid
    ```
- [ ] Configure a profile in `~/.config/pabrik/config.json` with `url_style=anthropic`, `base_url=https://api.anthropic.com` (or a test-compatible relay), `model=claude-…`, `api_key=sk-ant-…`. (Skip if the user already has such a profile configured — confirm with them.)
- [ ] Open `http://localhost:8080`, pick the Anthropic profile in the chatview dropdown.
- [ ] Send a short message ("hi").
- [ ] Tail `/tmp/anthropic_smoke_8080.log`. **Confirm**: the response streams token-by-token (NOT a single retry-then-fail loop). The user-visible chat shows the model's reply.
- [ ] **Negative case**: temporarily set `api_key` to a bogus value, repeat. **Confirm**: the log shows `ERROR … ApiError … HTTP 401: {"type":"error","error":{"type":"authentication_error",…}}` — i.e. the existing HTTP-error draining surfaces the real Anthropic error JSON, no change needed there.
- [ ] **Bonus Part A check**: point the Anthropic profile at a non-Anthropic URL (e.g. an OpenAI-compatible relay that the OpenAI parser DOES handle). Send a message. **Confirm**: the log shows `… stream ended without finish_reason after 0 chunk(s); first server lines: data: {"id":"…","object":"chat.completion.chunk",…}` — Part A surfaces the raw SSE so the user can see the mismatch.
- [ ] Stop the test server: `kill $(cat /tmp/anthropic_smoke_8080.pid)`. Verify port 8081 is still alive (`ss -tlnp | grep 8081`).

## Task 5: Documentation

**Files:**
- `docs/SPEC.md` — append a changelog entry
- `AGENTS.md` — append a brief "Recent changes" entry

**Steps:**

- [ ] In `docs/SPEC.md`, find the most recent 2026-08-13 section (or create one if missing) and append:
    > **2026-08-13 — Anthropic URL-style profile**: `Agent.callStreaming` now parses Anthropic's `/v1/messages` SSE event shape (`message_start` / `content_block_delta` / `message_delta` / `message_stop`) into the same internal `StreamChunk` that the OpenAI parser produces, dispatching on `Agent.UrlStyle`. Anthropic profiles with extended thinking and tool_use now stream correctly. Independently, when any profile fails to parse the server's SSE stream (e.g. a misconfigured `url_style`), the first 2 KiB of raw server lines are folded into `last_error_message` so the workflow retry log shows what the server actually returned, instead of hiding it behind "0 chunk(s)".
- [ ] In `AGENTS.md`, under "Recent changes" (or append at the end if no such section), add:
    > **Anthropic profile SSE parsing + raw-error surfacing** (2026-08-13): `src/modules/agent/Agent.zig` now parses Anthropic's `/v1/messages` SSE events and surfaces raw server output in the retry-log error message when parsing fails.

## Verification (per AGENTS.md pre-commit checklist)

```bash
cd /home/ginwa/ginwaaitoolbox

# 1. Unit tests
timeout 180 zig build test --summary all
# Expect: 4 new tests pass (1 raw-SSE + 3 anthropic), 0 new failures, 0 new leaks

# 2. Linux binary build
timeout 180 zig build install:linux:system
# Expect: compile succeeds

# 3. Fresh rebuild
rm -rf zig-out/bin
timeout 360 zig build
# Expect: all binaries produced

# 4. Cross-compile smoke (mandatory)
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig
# Expect: both clean (no errors)

# 5. Frontend — no changes expected, but sanity-check
cd src/apps/desktop
timeout 240 bunx vitest run 2>&1 | tail -n 20
# Expect: same baseline as before this plan (no new failures)

# 6. Live smoke (per Task 4) on port 8080 — DO NOT touch port 8081
```

## Pitfalls (record for future agents)

- **`Agent.last_error_message` ownership.** It's heap-allocated via `self.allocator` and freed by `deinit()` (Agent.zig:781-790 doc + L1545 `defer dynamic_agent.deinit()` in workflow.zig). The new error message strings in Task 1 must use `std.fmt.allocPrint(self.allocator, ...)` — not a stack buffer, not the line_arena (the line_arena is per-line reset).

- **Reset `_anthropic_input_tokens` and `_anthropic_usage_emitted` at the top of `callStreaming`, not in `init`.** `Agent` is reused across many calls; without per-call reset, the second call on the same agent would see stale state from the first.

- **`parse_anthropic_stream_chunk` doesn't know about `[DONE]`.** The OpenAI wire sends `data: [DONE]` as a terminator; `parse_sse_line` filters that out at L1095. Anthropic doesn't send `[DONE]` — it sends `event: message_stop` + `data: {"type":"message_stop"}` instead, and our `parse_anthropic_stream_chunk` returns null for that (correct). The scanner loop ends naturally when the server closes the connection.

- **The "first delta usage emission" can race with extended thinking.** A response that starts with `content_block_start (thinking)` + `content_block_delta (thinking_delta)` will fire the `usage` chunk on the first `thinking_delta`, not on the first `text_delta`. That's fine — the aggregator's `usage` field is just a last-writer-wins (`process_chunk` L649-653), and `StreamingAggregator.finalize` returns whichever usage chunk arrived last with `total_tokens > 0`. The trailing `message_delta` always carries the final output_tokens, which wins.

- **`chunkEncode` test helper must produce well-formed chunked encoding.** Each chunk: `<hex-length>\r\n<body>\r\n`; final chunk: `0\r\n\r\n`. libcurl's `Transfer-Encoding: chunked` decoder is strict — a missing trailing CRLF or wrong hex length produces a `DecodeError` that bubbles up as `StreamInterrupted` before our parser sees any line. Copy the format from the existing `call_streaming_test.zig::serve` head (L300-305) verbatim.

- **Don't refactor `parse_sse_line` to handle `event:` lines.** The OpenAI parser still relies on `parse_sse_line` returning only `data:` payloads — adding `event:` handling there would require also rewriting `parse_stream_chunk`'s OpenAI branch. The dispatcher pattern (Task 2) is the surgical fix.

- **`self.UrlStyle` is `[]const u8` borrowed from the workflow's `effective_url_style` arena (workflow.zig:1549).** Don't free it; don't dupe it. The `std.mem.eql(u8, ...)` compare is the only operation we do on it.

- **`buildJsonAnthropicRequest` already sets `stream_options.include_usage = true` (Agent.zig:450-452).** That field is OpenAI-only — Anthropic ignores it. Harmless. We rely on Anthropic's own `message_start.usage.input_tokens` + `message_delta.usage.output_tokens` for our usage tracking.

- **No new test for `buildJsonAnthropicRequest`.** Already covered by `agent_request_user_id_test.zig` (44-72) and the existing call_streaming tests. Don't duplicate.

## Out of scope

- **Other non-OpenAI providers** (Gemini, Mistral, Cohere, local llama.cpp). They use different SSE shapes again. The dispatch pattern established in Task 2 makes adding a new `parse_<provider>_stream_chunk` + branch trivial, but each provider is a separate plan.
- **Streaming non-text content blocks** (Anthropic image blocks — currently not used by any tool in this repo).
- **Tool-use input validation** (Anthropic sends `input_json_delta` partial JSON that the aggregator concatenates; if the server sends malformed JSON, `finalize()` will succeed but the tool execution will fail downstream — that's the existing OpenAI parser's behaviour too, not a regression).
- **Persisting streaming progress to the DB**. Out of scope — chat history is persisted at the end of each iteration by the workflow.
- **Telemetry / metrics for Anthropic-specific events**. Out of scope — the existing `[STREAM]` log lines cover what's needed.
- **Cancelling a long Anthropic stream**. The existing `Cancelled` error path (workflow.zig:1108) handles it; no change.

## Plan revision history

- 2026-08-13 — Initial plan.
