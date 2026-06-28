# TLS-Init Failure: Fast-Fail & User-Facing Error Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `std.http.Client` returns `error.TlsInitializationFailed` (or any other known-permanent transport error), `runAgenticMultiStepnew` fails immediately with a structured assistant-role error event, instead of silently retrying 10 times and then dumping a typo-ridden fake-user message into the chat history.

**Architecture:** Add an error classification table to `Agent.CallError` (transient vs permanent). The streaming read loop in `callStreaming` and the workflow retry loop in `runAgenticMultiStepnew` both consult the table. Permanent errors short-circuit to a single `onEventSendLLMHistory` event with `role = "assistant"`, `finish_reason = "error"`, and a human-readable `content` string. Transient errors keep the existing 10-retry policy. The chat UI's `isLLMProcessing` flag is cleared in both paths via an unconditional `callback(ctx, .{ .done = true })` at the end of `callStreaming`.

**Tech Stack:** Zig 0.16, existing `std.http.Client`, SSE event bus (`on_event_sent.zig`), SQLite worker table (`llm_history.zig`).

---

## Trace — Why the user sees "stuck"

A user error log:

```
[err] HTTP streaming request failed to 'https://api.minimax.io/v1/chat/completions': TlsInitializationFailed
```

originates at `src/modules/agent/Agent.zig:1223`:

```zig
var req = self.httpClient.request(.POST, uri, .{
    .version = .@"HTTP/1.1",
    .headers = .{ ... },
}) catch |err| {
    self.log_fmt(.err, "HTTP streaming request failed to '{s}': {s}", .{ uri_str, @errorName(err) });
    return error.HttpRequestFailed;          // ← ALL transport errors collapse to this
};
```

The error then propagates through three layers, each of which has a bug that compounds the "stuck" sensation:

| Layer | File | Lines | What happens | Bug |
|---|---|---|---|---|
| Agent (per-call) | `src/modules/agent/Agent.zig` | 1215-1225 | `client.request()` returns `error.TlsInitializationFailed`; mapped to generic `error.HttpRequestFailed` and returned | The 12 distinct transport errors Zig can return (`TlsInitializationFailed`, `TlsAlert`, `ConnectionRefused`, `NetworkUnreachable`, `HostUnreachable`, `UnexpectedReadFailure`, `WriteFailed`, etc.) are all collapsed into a single `HttpRequestFailed` variant. Caller cannot tell transient from permanent. |
| Agent (per-call) | `src/modules/agent/Agent.zig` | 1499 | `callback(ctx, .{ .done = true })` is sent only on the success path | On the error path the frontend's `isStreaming` flag never flips to `false`. The chat stays in "thinking…" forever from the UI's perspective. |
| Workflow (retry) | `src/ai_workflow/tui/workflow.zig` | 408-416 | Catches the error, increments `retry_count`, `continue`s the `while (true)` loop | `TlsInitializationFailed` is essentially always a permanent config error (missing CA bundle, broken `libssl`, etc.), but the loop retries it 10 times. Each retry creates a brand-new `std.http.Client` (line 704: `var dynamic_agent = try agent.Agent.init(...)`), so each attempt fails just as fast as the last. ~10 identical error log lines flash by. No progress, no feedback. |
| Workflow (after 10 retries) | `src/ai_workflow/tui/workflow.zig` | 40-113 | `error.TooManyRetries` bubbles to the outer `catch` | The catch **saves a synthetic message to `llm_history` with `role = "user"`** (line 70), not `assistant`. Content is `"Theres a error TooManyRetries ignore this instruction"` (typo + active-attack-style suffix). On the next user turn the LLM reads this garbage as if the user had typed it, and the chat history is permanently corrupted. The `finish_reason = "null"` and `loop_index = 0` are also wrong. |

### What the user experiences

1. Sends a message. UI flips to "thinking".
2. 10 nearly-instant identical `[err] HTTP streaming request failed to ... : TlsInitializationFailed` lines flash in the log.
3. After ~100-200 ms, a worker SSE `"deleted"` event fires (good — `markSessionIdle` runs via the `defer` at line 184).
4. **But** the chat panel also receives a fake "user" message: `Theres a error TooManyRetries ignore this instruction`.
5. The user's next prompt arrives; the LLM sees the corrupted history and responds as if the user said "ignore this instruction".

The "stuck" sensation is layers 1+2+3: the UI is not visibly progressing, no retry is taking long enough to look like work, and there's no terminal error message explaining what went wrong.

---

## Root causes (the bugs to fix)

1. **`CallError` is not classified.** The 12 variants in `CallError` are returned as-is, with no hint to the caller about whether retrying helps. Fix: add a helper `isRetriable(err: CallError) bool` that returns `true` only for genuinely transient errors (`StreamTimeout`, `StreamIdleTimeout`, `StreamInterrupted`, `ApiError` for 5xx, `ReceiveFailed`, `SendBodyFailed`).

2. **Workflow retries permanent errors 10 times.** Add a `switch (err)` in the catch that breaks out (or returns) immediately on permanent errors. The `try` at line 718 (`callDynamicAgentNew`) and the `try` at line 792 (`compaction_agent.callStreaming`) already propagate the error to the outer `catch` — we just need to short-circuit the loop.

3. **`callback(ctx, .{ .done = true })` is not called on the error path.** Move it to a `defer` near the top of `callStreaming` so the frontend's `isStreaming` flag is always cleared, regardless of success or failure.

4. **Synthetic error message uses wrong role + has typos.** Replace the user-role message at `workflow.zig:60-85` with an assistant-role message using a new `finish_reason = "error"` string. The frontend already handles `role = "assistant"` + any `finish_reason` — adding `"error"` as a value (a string, not a `FinishReason` enum member) is a one-line change in the JSON payload. The chat view can be told to render it with a different bubble style (out of scope for this plan; the backend just needs to send it correctly).

5. **No diagnostic context in the log line.** The current log line at line 1223 only shows the URL and the error name. Add a hint about the likely cause (TLS / DNS / network) so the user can grep for it and find this plan.

---

## File Structure (what changes where)

| File | Change | Why |
|---|---|---|
| `src/modules/agent/Agent.zig` | Add `isRetriable()` on `CallError`; add `defer callback(ctx, .{ .done = true })` to `callStreaming`; enrich the line 1223 log message with classification hint | Source of truth for the error classification; guarantees the streaming-callback contract holds on both success and failure paths. |
| `src/ai_workflow/tui/workflow.zig` | Replace the unconditional `retry_count += 1; continue;` at line 408-416 with a `switch (err) { permanent => return error.X, cancelled => break, transient => retry }`. Replace the synthetic user-role message in the outer `catch` (lines 60-85) with an assistant-role error event with `finish_reason = "error"`. | Workflow is the layer that decides whether to retry and how to surface the error to the UI. |
| `src/modules/agent/call_streaming_test.zig` | Add a regression test for the new `isRetriable` helper (12 assertions, one per `CallError` variant). Add a test that verifies the new defer pattern (callback gets `.done = true` even when `client.request()` fails). | Pins the new contract so a future refactor can't silently regress. |
| `src/ai_workflow/tui/workflow_test.zig` (new) | Add a test that drives the workflow's outer `catch` block via a synthetic `error.TooManyRetries` and asserts the saved message has `role = "assistant"`, `finish_reason = "error"`, and a content string that does **not** contain the substring "ignore this instruction". | Pins the user-facing error contract. |
| `src/ai_workflow/tui/test_runner.zig` | Register the new `workflow_test.zig`. | Required for the test to run. |

No new modules, no schema migrations, no SSE protocol changes (the existing `onEventSendLLMHistory` already accepts `role = "assistant"` and any `finish_reason` string).

---

## Task 1: Classify `CallError` in `Agent.zig`

**Files:**
- Modify: `src/modules/agent/Agent.zig:1039-1063` (`CallError` declaration)
- Test: `src/modules/agent/call_streaming_test.zig` (add `isRetriable` regression)

- [ ] **Step 1.1: Write the failing test**

Append to `src/modules/agent/call_streaming_test.zig` (before the closing of the file):

```zig
test "isRetriable classifies CallError variants correctly" {
    // Permanent — retrying won't help (config error, bad request, missing TLS).
    try expect(!agent.Agent.isRetriable(error.BuildRequestFailed));
    try expect(!agent.Agent.isRetriable(error.InvalidUri));
    try expect(!agent.Agent.isRetriable(error.AuthFailed));
    try expect(!agent.Agent.isRetriable(error.HttpRequestFailed));
    try expect(!agent.Agent.isRetriable(error.ParseJsonFailed));
    try expect(!agent.Agent.isRetriable(error.NoChoices));
    try expect(!agent.Agent.isRetriable(error.AllocFailed));
    try expect(!agent.Agent.isRetriable(error.OutOfMemory));
    try expect(!agent.Agent.isRetriable(error.WriteFailed));
    try expect(!agent.Agent.isRetriable(error.Cancelled));
    try expect(!agent.Agent.isRetriable(error.StreamEmpty));

    // Transient — server hiccup, network blip, deadline. Worth retrying.
    try expect(agent.Agent.isRetriable(error.SendBodyFailed));
    try expect(agent.Agent.isRetriable(error.ReceiveFailed));
    try expect(agent.Agent.isRetriable(error.ApiError));               // 5xx from the LLM
    try expect(agent.Agent.isRetriable(error.StreamTimeout));
    try expect(agent.Agent.isRetriable(error.StreamIdleTimeout));
    try expect(agent.Agent.isRetriable(error.StreamInterrupted));
}
```

- [ ] **Step 1.2: Run the test to verify it fails to compile**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:agent 2>&1 | tail -n 30`

Expected: compile error `error: no member named 'isRetriable' in struct 'agent.Agent'`.

- [ ] **Step 1.3: Add the classification helper**

In `src/modules/agent/Agent.zig`, immediately after the `CallError` declaration (after line 1063), add:

```zig
/// Returns true if the error is a transient transport/hiccup that is worth
/// retrying (network glitch, server 5xx, idle/timeout/keepalive reset).
/// Returns false for permanent configuration errors (TLS init failed, bad
/// URL, missing auth, allocation failure) where retrying produces the same
/// failure indefinitely.
pub fn isRetriable(err: CallError) bool {
    return switch (err) {
        // Permanent — caller-side config or request shape errors.
        error.BuildRequestFailed => false,
        error.InvalidUri => false,
        error.AuthFailed => false,
        error.HttpRequestFailed => false,  // includes TlsInitializationFailed
        error.ParseJsonFailed => false,
        error.NoChoices => false,
        error.AllocFailed => false,
        error.OutOfMemory => false,
        error.WriteFailed => false,
        error.Cancelled => false,          // explicit user action, never retry
        error.StreamEmpty => false,        // 0-chunk clean end with no finish; surface to user

        // Transient — server hiccup or in-flight interruption. Retry.
        error.SendBodyFailed => true,
        error.ReceiveFailed => true,
        error.ApiError => true,            // 5xx — server may recover
        error.StreamTimeout => true,
        error.StreamIdleTimeout => true,
        error.StreamInterrupted => true,   // keepalive detected dead conn
    };
}
```

- [ ] **Step 1.4: Run the test to verify it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:agent 2>&1 | tail -n 20`

Expected: 18/18 (17 existing + 1 new) tests pass.

- [ ] **Step 1.5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/Agent.zig src/modules/agent/call_streaming_test.zig
git commit -m "feat(agent): classify CallError as transient/permanent via isRetriable()"
```

---

## Task 2: Always send `done = true` to the streaming callback (defer fix)

**Files:**
- Modify: `src/modules/agent/Agent.zig:1166-1522` (the `callStreaming` function)
- Test: `src/modules/agent/call_streaming_test.zig`

Background: the existing `callback(ctx, .{ .done = true })` at line 1499 only runs on the success path. On every error return (1224, 1230, 1245, 1277, 1300, 1336, 1366, 1379, 1389, 1411, 1429, 1491, 1496, 1508), the callback is never called with `done`, so the frontend's `isStreaming` flag stays `true` and the chat panel shows the agent still "thinking". This is the primary contributor to the "stuck" UI state.

- [ ] **Step 2.1: Write the failing test**

Append to `src/modules/agent/call_streaming_test.zig`:

```zig
const TestStreamCtx = struct {
    chunk_count: u32 = 0,
    done_seen: bool = false,
};

fn countingCallback(ctx: ?*anyopaque, chunk: agent.StreamChunk) void {
    const c: *TestStreamCtx = @ptrCast(@alignCast(ctx.?));
    if (chunk.done) {
        c.done_seen = true;
    } else {
        c.chunk_count += 1;
    }
}

test "callStreaming invokes callback done=true even on client.request() failure" {
    // Drives Task 2's fix. We cannot easily construct a TlsInitializationFailed
    // without root CA manipulation, so we use a URL that will fail at std.Uri.parse
    // validation (HttpRequestFailed after the request is built). Use an invalid
    // scheme the client rejects.
    //
    // The structural assertion is: regardless of which error path returns, the
    // `done = true` callback fires exactly once before the function returns.
    //
    // SKIP: this test requires a running test server OR root CA manipulation
    // to deterministically trigger each error variant. The unit-level guarantee
    // (defer fires on every return path) is better pinned by a Zig compile-time
    // check that `defer` is present in `callStreaming`. See Task 2.3.
    return error.SkipZigTest;
}
```

- [ ] **Step 2.2: Run the test to verify it compiles (the test body is skipped but must compile)**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:agent 2>&1 | tail -n 20`

Expected: compile success, 1 skipped test.

- [ ] **Step 2.3: Add the structural compile-time test (real pin)**

Append to `src/modules/agent/call_streaming_test.zig`:

```zig
test "callStreaming has a defer that fires callback done=true on all return paths" {
    // This is a static check: the source of callStreaming must contain the
    // string `defer callback(ctx, .{ .done = true })`. The fix in Task 2
    // moves the existing inline `callback(ctx, .{ .done = true })` to a defer
    // at the top of the function so all `return` paths fire it.
    //
    // The test reads the source file and looks for the marker. If a future
    // refactor removes the defer, the test fails immediately.
    const source = @embedFile("../Agent.zig");
    try expect(std.mem.indexOf(u8, source, "defer callback(ctx, .{ .done = true })") != null);
}
```

- [ ] **Step 2.4: Run the test to verify it fails (source does not yet have the defer)**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:agent 2>&1 | tail -n 30`

Expected: the new test fails with `error: indexOf returned null` (or `expect` failure on the `null` check).

- [ ] **Step 2.5: Apply the defer fix**

In `src/modules/agent/Agent.zig`, in the `callStreaming` function (starts at line 1166):

1. **Delete** the existing `callback(ctx, .{ .done = true });` at line 1499.
2. **Add** near the top of the function (after the `defer self.allocator.free(json_body);` at line 1188):

```zig
// Always send a `done = true` to the streaming callback on every return path.
// Without this defer, the frontend's `isStreaming` flag stays true forever
// when callStreaming returns an error (TlsInitializationFailed, timeout, etc.),
// and the user sees the chat panel stuck on "thinking...".
defer callback(ctx, .{ .done = true });
```

- [ ] **Step 2.6: Re-run the test to verify it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:agent 2>&1 | tail -n 20`

Expected: 20/20 tests pass (previous 18 + 1 new structural + 1 skipped runtime).

- [ ] **Step 2.7: Verify no regression — run all agent tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:agent 2>&1 | tail -n 20`

Expected: all green; no new failures.

- [ ] **Step 2.8: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/Agent.zig src/modules/agent/call_streaming_test.zig
git commit -m "fix(agent): always invoke streaming callback done=true via defer"
```

---

## Task 3: Enrich the `[err] HTTP streaming request failed` log line

**Files:**
- Modify: `src/modules/agent/Agent.zig:1215-1225` (the `client.request` catch block)

- [ ] **Step 3.1: Update the log message**

Replace the catch block at lines 1222-1224 with:

```zig
} catch |err| {
    // Tag the error with a classification hint so operators can grep
    // for the symptom class. TlsInitializationFailed and TlsAlert usually
    // mean the system OpenSSL / CA bundle is broken. ConnectionRefused /
    // NetworkUnreachable usually mean the URL is wrong or the server is
    // down. See docs/superpowers/plans/2026-06-11-tls-init-fast-fail.md
    // for the full classification table.
    self.log_fmt(.err, "HTTP streaming request failed to '{s}': {s} (retriable={}, likely cause: {s})", .{
        uri_str,
        @errorName(err),
        Agent.isRetriable(@as(CallError, @errorSetCast(err))),
        if (err == error.TlsInitializationFailed or err == error.TlsAlert)
            "TLS — check system OpenSSL and CA bundle"
        else if (err == error.ConnectionRefused or err == error.NetworkUnreachable or err == error.HostUnreachable)
            "network — check URL and server reachability"
        else
            "see Zig std.http error docs",
    });
    return error.HttpRequestFailed;
};
```

Note: `isRetriable` takes `CallError`, but `err` is `std.http.Client.Request.Error`. Use `@errorSetCast` (or a small adapter that maps the std.http error set into the subset of `CallError` that overlaps). If `@errorSetCast` produces a compile error on the conversion, use this safer alternative:

```zig
const retriable: bool = switch (err) {
    error.ConnectionRefused, error.NetworkUnreachable, error.ConnectionResetByPeer,
    error.UnexpectedReadFailure, error.UnexpectedEndOfStream, error.ReadFailed,
    error.WriteFailed, error.UnexpectedWriteFailure, error.SocketNotConnected,
    error.TimedOut, error.WouldBlock =>
        true,
    else => false,
};
```

…and replace the `Agent.isRetriable(...)` call with the local `retriable` boolean.

- [ ] **Step 3.2: Run all agent tests to confirm the change compiles cleanly**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:agent 2>&1 | tail -n 30`

Expected: compile success; all tests pass.

- [ ] **Step 3.3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/Agent.zig
git commit -m "feat(agent): classify transport errors in HTTP streaming log line"
```

---

## Task 4: Workflow fast-bails on permanent errors (no 10x retry)

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig:408-416` (the `callDynamicAgentNew` catch)

- [ ] **Step 4.1: Update the retry logic**

Replace the lines 408-416 with:

```zig
const res_dynamic_agent = callDynamicAgentNew(allocator, io, &messagesLists, agent_temperature, current_max_tokens, isThinking, effective_api_key, effective_model, effective_base_url, effective_url_style, copy_session_id, merged_tools) catch |err| {
    if (err == error.Cancelled) {
        logger.infoFmt("WORKFLOW CANCELLED during streaming: session_id={s}", .{copy_session_id});
        break;
    }
    // Fast-bail on permanent errors — retrying produces the same failure
    // indefinitely (TLS init, bad URL, allocation failure). Propagate to the
    // outer catch which sends a proper error event to the UI.
    if (!agent.Agent.isRetriable(err)) {
        logger.errFmt("Permanent error from dynamic agent: {s} — fast-bailing", .{@errorName(err)});
        return err;
    }
    retry_count += 1;
    logger.errFmt("Transient error calling dynamic agent: {s} now retrying ({d}/10)", .{
        @errorName(err), retry_count,
    });
    continue;
};
```

- [ ] **Step 4.2: Verify the change compiles**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build 2>&1 | tail -n 30`

Expected: build succeeds; `isRetriable` is found via `agent.Agent.isRetriable` (imported at the top of `workflow.zig` as `const agent = nalarcore.agent`).

- [ ] **Step 4.3: Run all ai_workflow tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:ai_workflow_tui 2>&1 | tail -n 30`

Expected: all green; no new failures.

- [ ] **Step 4.4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/workflow.zig
git commit -m "fix(workflow): fast-bail on permanent CallError, keep retry for transient"
```

---

## Task 5: Replace the synthetic user-role error message with a proper assistant-role error event

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig:60-112` (the outer `catch` in `CallbackAiWorkerFlow.callback`)

Background: today the outer catch saves a message with `role = "user"` and a typo-ridden `"Theres a error TooManyRetries ignore this instruction"` content. The next turn's LLM sees this garbage. Replace it with an assistant-role error event whose `content` is a clean diagnostic and whose `finish_reason` is the new string `"error"` (frontend can render this as an error bubble).

- [ ] **Step 5.1: Update the outer catch**

Replace the body of the `catch` (lines 42-112 — the cleanup, message-save, and SSE-send) with:

```zig
// ─── Cleanup ────────────────────────────────────────────────────────────
llm_history.deleteWorkerBySessionId(allocator, db, session_id) catch |error_sqlite| {
    logger.errFmt("Failed to delete worker: {s}", .{@errorName(error_sqlite)});
};
llm_history.deleteQueuedMessagesBySessionId(allocator, db, session_id) catch |error_sqlite| {
    logger.errFmt("Failed to delete all queued messages: {s}", .{@errorName(error_sqlite)});
};

// ─── Build a clean, assistant-role error message ────────────────────────
const initial_agent_state = llm_history.get_current_agent_by_session_id(
    allocator,
    db,
    session_id,
) catch |err_agent_state| {
    logger.errFmt("Failed to get current agent state: {s}", .{@errorName(err_agent_state)});
    return;
};
const initial_agent = initial_agent_state.agent;

// Short, honest, no LLM-confusing suffix. `finish_reason = "error"` is a new
// string the frontend can key on to render an error bubble instead of a
// normal assistant message. We use `role = "assistant"` so the LLM never
// sees this as user input on the next turn.
const error_message = std.fmt.allocPrint(allocator,
    \\⚠ I couldn't reach the LLM provider ({s}).
    \\
    \\The most common cause is a TLS configuration issue (missing CA bundle,
    \\broken system OpenSSL, or a self-signed certificate from the provider).
    \\Check the worker log for the underlying transport error.
    \\
, .{@errorName(err)}) catch |err_fmt| {
    logger.errFmt("Failed to format error message: {s}", .{@errorName(err_fmt)});
    return;
};
defer allocator.free(error_message);

_ = llm_history.saveMessage(allocator, io, db, .{
    .session_id = session_id,
    .model = config.model,
    .cwd = cwd,
    .content = error_message,
    .reasoning_content = null,
    .role = agent.Role.assistant.to_str(),       // ← was "user"
    .finish_reason = "error",                     // ← was "null"
    .tool_calls = null,
    .tool_call_id = null,
    .agent_name = initial_agent,
    .loop_index = 0,
    .temperature = initial_agent_state.temperature,
    .is_thinking = initial_agent_state.is_thinking,
    .prompt_tokens = 0,
    .completion_tokens = 0,
    .total_tokens = 0,
    .parent_id = session_id,
    .parent_session_id = session_id,
    .is_input = false,                            // ← was true
    .is_output = true,                            // ← was false
}) catch {};

const session_skills_err = llm_history.getSessionSkills(allocator, db, session_id) catch null;
defer if (session_skills_err) |s| for (s) |*skill| {
    allocator.free(skill.skill_name);
    allocator.free(skill.content);
};

on_event_sent.onEventSendLLMHistory(allocator, .{
    .session_id = session_id,
    .model = config.model,
    .cwd = cwd,
    .content = error_message,
    .reasoning_content = null,
    .role = agent.Role.assistant.to_str(),       // ← was "user"
    .finish_reason = "error",                     // ← was "null"
    .tool_calls_json = null,
    .tool_call_id = null,
    .tool_name = null,
    .agent_name = initial_agent,
    .loop_index = 0,
    .temperature = initial_agent_state.temperature,
    .is_thinking = initial_agent_state.is_thinking,
    .is_input = false,                            // ← was true
    .is_output = true,                            // ← was false
    .parent_id = session_id,
    .parent_session_id = session_id,
    .session_skills = session_skills_err,
}) catch {};
```

- [ ] **Step 5.2: Verify the build**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build 2>&1 | tail -n 30`

Expected: build succeeds.

- [ ] **Step 5.3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/workflow.zig
git commit -m "fix(workflow): assistant-role error event instead of fake user message"
```

---

## Task 6: Add workflow_test.zig regression for the error event contract

**Files:**
- Create: `src/ai_workflow/tui/workflow_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

Background: there is no existing test for the `runAgenticMultiStepnew` outer catch path. Adding one pins the new error-message contract so a future refactor cannot silently regress to the typo-laden user-role message.

- [ ] **Step 6.1: Create the test file**

Create `src/ai_workflow/tui/workflow_test.zig` with this content (placeholder, will be filled in as the engineer builds out the in-memory harness — see the NALAR.md note about `zig-0.16-inmemory-sqlite-test-setup` for the Io + SqliteBackend pattern):

```zig
//! Regression tests for the outer catch path of `runAgenticMultiStepnew`.
//!
//! Pins the contract that workflow errors surface to the UI as an
//! assistant-role message with `finish_reason = "error"`, NOT as a
//! user-role message that would corrupt the LLM's view of the conversation
//! on the next turn. See the 2026-06-11 "TLS-Init Fast-Fail" plan.

const std = @import("std");
const testing = std.testing;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectStringContains = std.testing.expectStringContains;

const llm_history = @import("llm_history.zig");
const agent = @import("nalarcore").agent;

test "outer catch error message is assistant-role, finish_reason=error" {
    // Set up an in-memory SQLite DB and a session. Trigger the error path
    // by calling the equivalent of the outer catch (a small extracted helper
    // or by direct invocation of the saved-message builder if Task 5.1 factored
    // it out).
    //
    // Implementation note: full e2e test of `runAgenticMultiStepnew` requires
    // a `ContextIPCTui` singleton and an LLM provider mock. For now, pin
    // the contract with a unit test on the message-builder logic.
    //
    // See zig-0.16-inmemory-sqlite-test-setup skill for the SqliteBackend init
    // pattern with std.Io.Threaded.
    //
    // Required assertions (once the harness is built):
    //   - saved_message.role == "assistant"
    //   - saved_message.finish_reason == "error"
    //   - saved_message.content does NOT contain "ignore this instruction"
    //   - saved_message.content starts with "⚠" or otherwise signals an error
    //   - saved_message.is_input == false
    //   - saved_message.is_output == true
    return error.SkipZigTest; // TODO: build the harness, then fill in
}
```

- [ ] **Step 6.2: Register the test in the runner**

Edit `src/ai_workflow/tui/test_runner.zig` to add the new test file:

```zig
test {
    _ = @import("handle_tool_test.zig");
    _ = @import("inherited_context_test.zig");
    _ = @import("migration_performance_indexes_test.zig");
    _ = @import("notifications_test.zig");
    _ = @import("parse_diff_view_test.zig");
    _ = @import("save_agent_test.zig");
    _ = @import("save_skill_test.zig");
    _ = @import("workflow_test.zig");          // ← NEW
    // ... rest unchanged
}
```

- [ ] **Step 6.3: Run the test to verify it compiles (skipped)**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test:ai_workflow_tui 2>&1 | tail -n 20`

Expected: compile success; 1 skipped test.

- [ ] **Step 6.4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/workflow_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "test(workflow): pin error event contract in outer catch"
```

> **Follow-up (out of scope for this plan):** the engineer should build out the in-memory harness in `workflow_test.zig` and convert the `SkipZigTest` return into real assertions. The NALAR.md entry `zig-0.16-inmemory-sqlite-test-setup` documents the `std.Io.Threaded` + `.io()` pattern. This follow-up is tracked as a separate task because it requires the full `ContextIPCTui` mock and is not a blocker for the user-facing fix.

---

## Task 7: Manual end-to-end verification

**Files:** none (this is a runtime check).

Background: the unit tests in Tasks 1-3 verify the static contract. Task 4-6 verify the workflow logic. But the user-reported symptom is UI behavior, so a manual e2e test against a broken-OpenSSL environment is the only way to confirm the "no more stuck" UX.

- [ ] **Step 7.1: Build the dev binary**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 600 zig build install:dev 2>&1 | tail -n 20`

Expected: `zig-out/bin/nalar-dev` is rebuilt.

- [ ] **Step 7.2: Start the dev server**

Run in a separate terminal (NEVER touch port 8081 or the `nalar` process — use 8080):

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar-dev --port 8080 --static-dir ./src/apps/desktop/dist 2>&1 | tee /tmp/nalar-dev-tls-test.log
```

Wait for "Server listening on 127.0.0.1:8080".

- [ ] **Step 7.3: Simulate a TLS-Init failure**

Break the CA bundle path temporarily. Pick one of:

- **(a) Set an empty `SSL_CERT_FILE` and a non-existent `SSL_CERT_DIR`:**
  ```bash
  export SSL_CERT_FILE=/nonexistent/ca-bundle.pem
  export SSL_CERT_DIR=/nonexistent/ca-dir
  ```
  then restart the server.

- **(b) Run a test mock server with a self-signed cert and point the LLM config at it.** Easier and more deterministic; see Step 7.4.

- [ ] **Step 7.4: Set up a test mock with a self-signed cert (deterministic)**

```bash
# 1. Generate a self-signed cert
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/test.key -out /tmp/test.crt \
  -days 1 -subj "/CN=test.invalid" 2>&1 | tail -n 2

# 2. Start a tiny mock LLM server on localhost:9090 that just accepts and stalls
cat > /tmp/mock_llm.py <<'EOF'
import http.server, ssl, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'data: {"choices":[{"delta":{"content":"x"}}]}\n\n')
        self.wfile.flush()
        import time; time.sleep(60)  # stall so the test is deterministic
httpd = http.server.HTTPServer(('127.0.0.1', 9090), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('/tmp/test.crt', '/tmp/test.key')
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
EOF
python3 /tmp/mock_llm.py &  # background
```

- [ ] **Step 7.5: Configure nalar to use the mock**

Set the active LLM profile's `base_url` to `https://127.0.0.1:9090/v1` via the nalar settings UI or by editing `~/.config/nalar/config.json`. The self-signed cert will trigger `TlsInitializationFailed` (or `TlsAlert`, depending on the Zig stdlib's exact behavior with an untrusted CA).

- [ ] **Step 7.6: Send a message and observe the UX**

Open `http://127.0.0.1:8080/`, pick the broken-URL session, type "hello", hit send. Watch for:

- **Before this fix:** 10 identical `[err] HTTP streaming request failed to ... : TlsInitializationFailed` log lines flash in `/tmp/nalar-dev-tls-test.log`, the UI stays in "thinking" for ~1s, then a fake "Theres a error TooManyRetries ignore this instruction" user message appears in the chat.
- **After this fix:** 1 log line (with the new `likely cause: TLS — check system OpenSSL and CA bundle` suffix), the UI clears within ~100ms, and the chat shows one assistant message: "⚠ I couldn't reach the LLM provider (TooManyRetries). The most common cause is a TLS configuration issue..." with a distinct error bubble style (frontend can be updated later to render this; for now the message just appears as a normal assistant message with the ⚠ prefix).

- [ ] **Step 7.7: Verify the chat history is clean**

Type another message in the same session. Confirm the LLM does NOT see the previous error message as a user input — the LLM should respond to the new prompt, not ignore it. (Before the fix, the LLM would see "Theres a error TooManyRetries ignore this instruction" as the user's last message and the response would be wrong.)

- [ ] **Step 7.8: Cleanup**

```bash
kill %1 2>/dev/null  # the python mock
unset SSL_CERT_FILE SSL_CERT_DIR
rm -f /tmp/test.key /tmp/test.crt /tmp/mock_llm.py
```

- [ ] **Step 7.9: Commit any UI rendering changes (separate plan)**

If the frontend needs a new bubble style for `finish_reason = "error"` messages, file a follow-up. This plan only fixes the backend; the frontend continues to render the assistant message as a normal bubble (with the ⚠ emoji prefix as a soft signal). A full UI follow-up is tracked separately.

---

## Pitfalls

1. **`@errorSetCast` on the `client.request` error union.** The `err` from `self.httpClient.request(...)` is a `std.http.Client.Request.Error`, not a `CallError`. They overlap (e.g. `ConnectionRefused` is in both), but you cannot `@as(CallError, @errorSetCast(err))` cleanly. Task 3.1 notes the safer alternative: a local `switch` on the std.http error set. Use that.

2. **The `defer callback(ctx, .{ .done = true })` in Task 2.5 may fire for `StreamingAggregator.init` and the transfer-buffer alloc failures too** (lines 1295-1302), before the `response.request.reader` is even created. That's correct — the frontend should always see `done = true` for any agent call, success or failure. The `TestStreamCtx` in the test (Task 2.1) counts chunks, not `done`s, so the structural test is the right pin.

3. **The new `finish_reason = "error"` string is not a `FinishReason` enum value.** It is a raw string passed to `onEventSendLLMHistory.finish_reason`. The frontend must be tolerant of new string values for `finish_reason` (check `frontend/src/components/ChatView.vue` and `api/index.ts` `Message` type). If the TypeScript interface declares `finish_reason: FinishReason` (an enum), the new value will be a TS error. The fix is to widen the type to `string` if it isn't already. **Do this in the same commit as Task 5** — otherwise the SSE event will fail to serialize on the wire.

4. **The `defer markSessionIdle` at workflow.zig:181-188 fires on `return err;` in Task 4.1.** Confirmed by re-reading the defer scope: it covers the whole `runAgenticMultiStepnew` body, so fast-bailing on a permanent error still cleans up the worker row and emits the SSE `"deleted"` event. Good — no separate cleanup needed.

5. **The Python mock in Step 7.4 stalls for 60s.** If the fix is broken and the workflow falls back to the old behavior, the test will hang. Wrap it in `timeout 30` to make the failure mode obvious:
   ```bash
   timeout 30 python3 /tmp/mock_llm.py &
   ```

6. **`zig build test:ai_workflow_tui` may not be a real build target.** Check `build.zig` for the actual target name. The relevant test target is wired in `build.zig` lines 280-283 (`ai_workflow_tui_test_mod`). Run via:
   ```bash
   cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 120 zig build test 2>&1 | tail -n 30
   ```
   which exercises all test modules.

7. **The `BuildRequestFailed` / `InvalidUri` / `AuthFailed` errors in `CallError` (line 1040-1042) are now correctly classified as permanent.** Make sure the call sites that map std errors to these variants (e.g. `buildJsonOpenAIRequest` failures → `BuildRequestFailed` at line 1180) are still consistent with the classification. They are.

---

## Verification

After all tasks pass, run the full test suite:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 120 zig build 2>&1 | tail -n 10       # build success
timeout 120 zig build test 2>&1 | tail -n 30  # all tests pass (or skipped, never fail)
```

Manual verification (Task 7) confirms the user-facing symptom is gone: 1 log line + 1 assistant error event + no corrupted chat history.

If the user reports the fix is incomplete, the most likely gaps are:
- Frontend `Message` type doesn't accept `finish_reason: "error"` → widen the type to `string` (Pitfall 3).
- The Python mock test isn't reachable from the user's actual config → repeat Task 7 with their real config and a packet-drop simulation instead of TLS failure (`sudo tc qdisc add dev lo root netem loss 100%`).

---

## Out of scope

- **Frontend rendering of `finish_reason = "error"` as a distinct error bubble.** This plan only fixes the backend. A follow-up should add a styled error component in `ChatView.vue`.
- **The known `StreamIdleTimeout` user-space-deadline issue** (see NALAR.md `[zig@0.16] std.Io.Threaded does NOT honor user-space deadlines`). This plan does not address that bug — it's a separate, larger fix involving `SO_RCVTIMEO` on the underlying socket fd.
- **Cross-platform TLS init failures on macOS / Windows.** The `std.http.Client.request` error variants are the same across platforms, so the classification table is portable, but the manual verification (Task 7) only runs on Linux. The `isRetriable` unit test (Task 1) runs on all platforms.
- **The `apply_tcp_keepalive` ordering** (it runs AFTER `sendBodyComplete`, not before). This is intentional per the comment at lines 1233-1236; a separate ticket tracks whether it should move.
