# Instant Stop — cancel an in-flight LLM turn without the ~1 s tail

> **Status: PLAN ONLY — not executed.** Awaiting the go-ahead at
> `in_review_planning`.

> **For agentic workers:** this is a *planning* artefact. Before implementing, use
> subagent-driven-development / executing-plans. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** clicking **Stop** during an LLM streaming turn halts generation within
one SSE chunk (~30–100 ms) instead of waiting for the in-flight response to finish,
and the transcript settles cleanly (no stale streaming row, partial text kept).

Generated 2026-09-14 against `main` @ `b7c2d39e`.

Card: *instant stop session llm* (`task_1789383365976_2`).

**This plan spans two repos.** `kabelweb` is a pinned tarball dependency
(`build.zig.zon:18-20`, commit `519f42b0`) and is also checked out locally at
`/home/ginwa/kabelweb` (sibling workspace item). Phase A lands in
`ginwaaitoolbox`; Phase B needs a ≤3-line `kabelweb` change plus a pin bump.

---

## 1. Symptom, and what it actually is

> "when i click stop it still need to wait a second, can instant stop ?"

**There is no `1 s` timer anywhere on this path.** I grepped for it: the only
second-scale constants are `sseClient.ts` reconnect backoff (1000 ms, unrelated)
and `retry_delay_ms.zig`'s 50 ms poll slices. The observed ~1 s is
**the remainder of the in-flight LLM response** — the workflow thread does not
learn about the cancel until the response it is already reading has ended.

Reproduce/measure (do this first, and record the number):

1. Start a turn that streams steadily (any reasoning/chat model).
2. Click **Stop** and note the wall time until the Stop button disappears
   (= `worker_deleted` → `App.handleWorkerEvent` → `processingState` cleared).
3. Repeat, clicking Stop at different points in the stream.
   - If the delay tracks "how much longer the response would have run", the
     diagnosis below is confirmed.
   - If it is a flat 1.0 s regardless, stop and re-investigate — something else
     is in play and this plan does not apply.

---

## 2. Root cause (evidence chain)

**The write side is already instant** — the Stop button is not the problem:

| Hop | Code | Cost |
|---|---|---|
| Click → POST | `api/index.ts:1719-1731` `stopSession()` → `POST /llm/session/:id/stop` | one RTT |
| Handler → DB | `src/http_handlers/session_stop.zig:30` → `llm_history.cancelSession()` | `UPDATE worker SET cancelled = 1 WHERE id = ?` — `src/agentic_loop/llm_history.zig:2815-2822` | µs |

**The read side is the problem.** `cancelled` is only polled in three places, and
none of them runs during an LLM stream:

| Poll site | When it runs | Helps here? |
|---|---|---|
| `workflow.zig:694-702` (loop top) | **before** each LLM call, i.e. *after* `callStreaming` returned | ❌ too late |
| `retry_delay_ms.zig:89-117` | during the retry backoff (≤50 ms slices) | ❌ not reached |
| `workflow.zig:388-395` (`mcp_cancel_thunk`) | MCP `tools/list` fetch only | ❌ unrelated |

The main agentic loop (`runAgenticMultiStepnew`, `workflow.zig:415`, `while (true)`
at `:591`) blocks in `callDynamicAgentNew` (`:1100`) → `Agent.callStreaming`
(`src/modules/agent/Agent.zig:2735`), whose SSE read loop
(`Agent.zig:2964-3042`) **has no cancellation check of any kind**:

```zig
var scanner_null_count: u32 = 0;
while (true) {
    const next_result = scanner.next() catch |err| { ... return error.StreamInterrupted; };
    if (next_result) |line| { ... callback(ctx, chunk); aggregator.process_chunk(chunk) catch {}; ... continue; }
    scanner_null_count += 1;
    if (scanner_null_count >= 2) break;
}
```

`error.Cancelled` **is** declared in `CallError` (`Agent.zig:2012-2036`) and the
caller **already** handles it (`workflow.zig:1100-1104`):

```zig
const res_dynamic_agent = callDynamicAgentNew(...) catch |err| {
    if (err == error.Cancelled) {
        logger.infoFmt("WORKFLOW CANCELLED during streaming: session_id={s}", .{copy_session_id});
        break;
    }
    retry_count += 1;
    ...
```

…but nothing in `Agent.zig` ever returns it. That arm is **dead code today**, and
the previous Stop-button plan explicitly deferred filling it in —
`docs/superpowers/plans/2026-08-06-chatview-stop-button.md:396`:

> **Mid-stream cancellation in `Agent.zig::callStreaming`**: add a `state.cancelled`
> atomic polled in the chunk read loop, return `error.Cancelled` when set. …
> This would make the Stop button truly instant (within one SSE chunk).

**This card is that follow-up.**

### 2.1 The trap that makes the naive fix not work

Returning `error.Cancelled` from the loop is *not* sufficient on its own, because
of `Agent.zig:2875`:

```zig
var stream = self.client.openStream(self.io, req, options) catch |err| { ... };
defer stream.deinit();
```

and kabelweb `src/client/stream.zig:462-468`:

```zig
pub fn deinit(self: *ResponseStream) void {
    self.state.cancel();
    self.thread.join();          // ← blocks here
    self.state.deinit();
    ...
}
```

`deinit()` **joins the libcurl worker thread**. And the worker only observes
`cancelled` in one place — `writeCallback`'s queue-full branch
(`kabelweb src/client/stream.zig:588`):

```zig
.full => {
    if (state.cancelled.load(.acquire)) return 0;
    if (monotonicNs() -% start_ns >= BACKPRESSURE_MAX_WAIT_NS) return 0;
    workerSleepNs(BACKPRESSURE_POLL_NS);
},
```

So:

- `SharedState.cancel()` (`kabelweb stream.zig:336-338`) only *stores a flag* — it
  does **not** bump `signal_gen` and does **not** `futexWake` the parked consumer.
- `ResponseStream.next()` (`:351-436`) never checks `cancelled` — it parks in
  `futexWaitTimeout` on `signal_gen` for up to `poll_budget_ns = 300 s` (`:384`).
- `writeCallback` only samples `cancelled` when the queue is **full**. With the
  consumer keeping up, the queue is not full, so `cancel()` is effectively a
  **no-op**; and with no bytes arriving (reasoning pause) `writeCallback` isn't
  running at all.

The kabelweb file itself already documents this failure mode
(`stream.zig:553-560`): *"`cancel()` a no-op that left `deinit()` blocked on the
join for up to `CURLOPT_TIMEOUT_MS`"* — a previous fix closed part of it, but the
queue-full-gated sampling is the remaining hole.

**Consequence:** if we make the Agent loop return `error.Cancelled` but do nothing
else, `deinit()`'s join then waits for the ring buffer (`QUEUE_CAPACITY = 64`,
`stream.zig:32`) to fill — ~64 chunks, i.e. **~2 s** at 30 chunks/s — or for the
stream to end. `worker_deleted` (and therefore the UI) is emitted from the
function-scope `defer` in `workflow.zig:507-518`, which runs *after* the join.
Net latency would be unchanged, and the fix would look like it did nothing.

---

## 3. Decisions (locked)

| Decision | Value | Why |
|---|---|---|
| Where does the cancel check live? | **In `Agent.callStreaming`'s SSE loop**, via a `cancel_fn` on `AgentCall` | `StreamCallback` returns `void` (`Agent.zig:923`), so `stream_callback` cannot signal cancel. `StreamingContext` (`workflow.zig:108`) has no function pointer, and `Agent.zig` must not import workflow's DB helpers (cycle). A `?*const fn () bool` thunk keeps the dependency direction workflow → agent — same shape as the existing `mcp_cancel_thunk` (`workflow.zig:381-407`). |
| Transport of the cancel signal | **Keep the DB flag as the source of truth** (Phase A). Add an in-memory token only for the stalled-park case (Phase B2) | The stop handler and the workflow share one process (`session_stop.zig:44` uses `nalarcore.getSingleton()`), so an atomic is valid — but the DB write must stay: `workflow.zig:695`, `retry_delay_ms.zig:92` and the MCP thunk all read it. |
| Do we abort the HTTP transfer? | **Yes** — call `stream.cancel()` as soon as cancel is detected | Otherwise `deinit`'s join waits on the queue to fill (§2.1). |
| What does the UI do on Stop? | **Keep the current design** — no optimistic flip; the UI settles when `worker_deleted` arrives | `ChatView.vue:2953-2957` deliberately documents this, and with Phase A+B that event now lands within ~1 chunk. Avoids the flicker race the comment describes, and avoids the "chunks keep arriving after we said stopped" clamping problem. |
| Stall case (reasoning pause, zero bytes)? | **Phase B2, recommended but separable** | While parked in `futexWaitTimeout` there is nothing the Agent can poll. Needs kabelweb to wake the consumer on `cancel()`. |
| Resurrect `CURLOPT_XFERINFOFUNCTION`? | **No — deferred** (§9 Q1) | It was deliberately disabled after **intermittent segfaults** (`kabelweb stream.zig:896-913`). Not needed for the token-flowing case, which is the reported one. |
| Tool execution (`handle_tool`) cancel checks | **Out of scope** — documented follow-up (§7) | A stop mid-tool waits for the tool. Real, but a different card: `handle_tool.zig` has zero `isWorkerCancelled` references. |
| Partial response on stop | **Persist it** (Phase C) | Today every cancel `break` exits before the assistant `INSERT` at `workflow.zig:1240-1268`, so the partial text is lost on refresh — and the client-side row keeps showing it until unmount. Inconsistent. |

---

## 4. Phase A — make the streaming loop observe the cancel (ginwaaitoolbox)

Fixes the reported symptom: latency drops from "the rest of the response" to
**one chunk interval**.

- [ ] **A1. Add the cancel seam to `AgentCall`.**
  `src/modules/agent/Agent.zig:1117-1122` — add a defaulted field so every
  existing literal still compiles (8 test call sites in
  `src/modules/agent/call_streaming_test.zig`, plus the session-name agent at
  `workflow.zig:1436` and `workflow_compact_message.zig:735`):

  ```zig
  pub const AgentCall = struct {
      tools: []const AgentTool,
      messages: []const AgentMessage,
      temperature: ?f32 = null,
      max_tokens: ?usize = null,
      /// Polled between SSE chunks. When it returns true, `callStreaming`
      /// aborts the transfer and returns `error.Cancelled` so the workflow
      /// can break out instead of reading the response to completion.
      cancel_fn: ?*const fn () bool = null,
  };
  ```

- [ ] **A2. Check it in the SSE loop, and abort the transfer.**
  `Agent.zig:2964`, top of `while (true)` — before `scanner.next()`:

  ```zig
  if (params.cancel_fn) |should_cancel| {
      if (should_cancel()) {
          // Abort the libcurl transfer, not just the read: `defer stream.deinit()`
          // joins the worker thread, and the worker only samples `cancelled` on
          // a body chunk (kabelweb writeCallback). Without this call the join
          // waits for the ring buffer to fill (~64 chunks).
          stream.cancel();
          self.log_fmt(.info, "[STREAM] cancelled by user after {} chunk(s)", .{chunk_count});
          return error.Cancelled;
      }
  }
  ```

- [ ] **A3. Never let a cancel masquerade as a transport failure.**
  This is the regression guard. A cancel-abort surfaces to the scanner as
  `CURLE_WRITE_ERROR` → `WriteError` → today's `catch` maps **everything** to
  `StreamInterrupted` (`Agent.zig:2965-2995`), which the workflow's generic catch
  turns into `retry_count += 1` + `saveRetryAttemptMessage` + a full retry — i.e.
  pressing Stop would silently re-run the request. In that `catch`, and in the
  post-loop `finish_reason == null` branch (`Agent.zig:3047`), check the flag
  first:

  ```zig
  const cancelled = if (params.cancel_fn) |f| f() else false;
  if (cancelled) return error.Cancelled;
  ```

  Also handle the `next()`-returned `null` path (`scanner_null_count >= 2` break,
  `:3041`) the same way, so a cancelled stream never becomes `StreamEmpty`.

- [ ] **A4. Wire the thunk from the workflow.**
  `callDynamicAgentNew` (`workflow.zig:1606`) already receives `session_id` and
  the caller has `db`. Reuse the proven `mcp_cancel_thunk` shape
  (`workflow.zig:381-407`) — a `threadlocal var state: ?Ctx` + `fn call() bool`
  that returns `isWorkerCancelled(IsWorkerCancelledInput{ .allocator = std.heap.page_allocator, .db = ..., .session_id = ... })`.
  Add a `cancel_fn` parameter (or build the thunk inside) and set
  `.cancel_fn = &cancel_thunk.call` on the `AgentCall` literal at
  `workflow.zig:1660`. Pass it from the `:1100` call site.

- [ ] **A5. Unit test the seam.**
  `src/modules/agent/call_streaming_test.zig` already drives `callStreaming`
  against a stub server. Add: a `cancel_fn` that flips true after N chunks →
  assert `error.Cancelled`, and assert the response was **not** read to the end
  (stub records how many chunks it wrote vs. how many the client consumed).

- [ ] **A6. Measure — do not assume.**
  Time (i) `POST /stop` → `worker_deleted` on the SSE wire, and (ii) `POST /stop`
  → no further `llm_chunk` on the wire, for a steadily-streaming stub. Target:
  both < 250 ms, and the join must not dominate.

**Phase A alone is necessary but not sufficient** — A2's `stream.cancel()` needs
Phase B1 to actually take effect promptly.

---

## 5. Phase B — make `cancel()` observable (kabelweb PR)

Small, surgical, and independently testable. Land as a `kabelweb` PR, then bump
the pin in `build.zig.zon:18-20`.

- [ ] **B1 (required, ~2 lines). Sample `cancelled` on every write callback.**
  `kabelweb src/client/stream.zig:561`, first statement of `writeCallback`:

  ```zig
  fn writeCallback(buf: [*]const u8, size: u64, nmemb: u64, userdata: *anyopaque) callconv(.c) u64 {
      const state: *SharedState = @ptrCast(@alignCast(userdata));
      // Cancel request: abort the transfer (CURLE_WRITE_ERROR) instead of
      // delivering one more chunk. Previously sampled only in the queue-full
      // branch, which made `cancel()` a no-op whenever the consumer kept up —
      // and left `ResponseStream.deinit()`'s join waiting for the ring buffer
      // to fill.
      if (state.cancelled.load(.acquire)) return 0;
      ...
  ```

  This is what turns Phase A's win into a real one: the worker now aborts on the
  **next** body chunk instead of after ~64.

- [ ] **B2 (recommended). Wake a parked consumer.**
  `SharedState.cancel()` (`stream.zig:336-338`) is currently
  `self.cancelled.store(true, .release);` — the consumer parked in
  `ResponseStream.next()` is never woken. Add the same signal used on completion
  (`stream.zig:680-681`):

  ```zig
  fn cancel(self: *SharedState) void {
      self.cancelled.store(true, .release);
      _ = self.signal_gen.fetchAdd(1, .release);
      self.io.futexWake(u32, &self.signal_gen.raw, 1);
  }
  ```

  and in `next()`'s loop (`stream.zig:387-390`), alongside the existing checks:

  ```zig
  if (self.state.cancelled.load(.acquire)) return error.Cancelled;
  ```

  `error.Cancelled` must be a **distinct** outcome from `null` — `null` already
  means "clean EOF *or* poll budget elapsed", and the Agent loop treats two
  consecutive nulls as a mid-stream death (`Agent.zig:3040-3047`), which would be
  mis-mapped to `StreamEmpty`/`StreamInterrupted` → retry. Map it in
  `Agent.zig:2965` explicitly (`if (err == error.Cancelled) return error.Cancelled;`).

- [ ] **B3 (optional). Break the park without a stop-thread handshake.**
  B2 needs something to call `cancel()` while the consumer is parked — that is
  the stop handler, which needs a handle to the live stream. Cheaper alternative
  that needs no registry: expose the poll budget as an option
  (`Options.next_poll_budget_ms: ?u64 = null`, default 300_000 to preserve
  behaviour), have `next()` use it instead of the hardcoded `poll_budget_ns`
  (`stream.zig:384`), and set ~250 ms from `Agent.zig` whenever `cancel_fn != null`.
  The consumer then wakes itself ≥4×/s and re-checks the flag — no stop-side
  plumbing, no use-after-free surface over a stack-owned `ResponseStream`.
  (Extra cost: 4 wakeups/s per live stream, negligible.)
  If B3 is not taken, the stalled case needs a
  `session_id → &stream` registry — the lock must be held across `cancel()` and
  the workflow must unregister under the same lock before `deinit`, which is
  more moving parts than this bug justifies.

- [ ] **B4. kabelweb tests.**
  Add to `src/client/streaming_test.zig` / the `ChunkQueue` contract tests
  (`stream.zig:931-1007`): (a) `cancel()` mid-stream aborts within one chunk;
  (b) `cancel()` while the consumer is parked in `next()` returns
  `error.Cancelled` promptly (assert < 1 s, not the 300 s budget);
  (c) `deinit()` after `cancel()` joins without waiting for the stream to end.

- [ ] **B5. Bump the pin.** `build.zig.zon:18-20` — new commit hash + hash;
  verify `zig build` and the kabelweb test suites (`zig build test`).

**Result of A + B1–B3:** live-token stream → **~1 chunk interval (30–100 ms)**;
stalled stream → bounded by the poll budget (~250 ms), and the workflow thread is
never pinned for the 300 s curl timeout.

---

## 6. Phase C — make the stop *look* right (ginwaaitoolbox)

Independent of latency, and currently broken. Verified: the cancel path emits
**only `worker_deleted`** (`delete_worker.zig:19-49` → `sse_send_event_worker.zig:56-63`).
Nothing else settles the transcript.

| Symptom | Evidence |
|---|---|
| Stale `streaming-*` assistant row left in the transcript | Removed only in the `full` handler (`ChatView.vue:2418`) or `disconnectSse` (`:2671-2672`). The frontend has **no `worker_deleted` listener in `ChatView.vue` at all** — `worker` events go only to `App.vue:23-44`. |
| `isStreaming` stuck `true` | Set at `ChatView.vue:2650-2654`, cleared only by `full` (`:2447`, `:2552`) or `disconnectSse` (`:2670`). `chunk_final` (`:2375-2384`) explicitly does not clear it. |
| Partial text lost on refresh | The assistant `INSERT` + `llm_full` emit (`workflow.zig:1240-1268` → `insert_llm_histories.zig:196-239`) sits on the `finish_reason == .stop` path; every cancel `break` exits before it. The stream snapshot (`stream_snapshot.zig`) holds the text but is never flushed on cancel. |
| `isStopping` / `Stopping…` | **Already correct** — clears via the `isLLMProcessing` watcher (`FileInput.vue:156-161`) once `worker_deleted` lands. No change needed. |

- [ ] **C1. Finalize the transcript on cancel.** On the cancel path, before the
  loop exits, flush what was accumulated: emit `sendStreamChunkFinal`
  (`on_event_sent.zig:676-699`, the same call the success path makes at
  `workflow.zig:1231-1239`) and/or an `llm_full` for the partial content, so the
  existing `full` handler replaces the `streaming-*` row and clears `isStreaming`.
  Prefer reusing `full` over inventing a new event type.
- [ ] **C2. Persist the partial assistant message.** Insert the partial
  `stream_snapshot` text into `llm_history` on cancel so the stopped turn survives
  a reload and the transcript matches the DB (today the client-side residue has no
  DB counterpart at all). Decide the marker text in §9 Q2.
- [ ] **C3. Frontend test.** Extend the existing
  `src/apps/desktop/src/__tests__/ChatView.stopSession.spec.ts` and
  `src/apps/desktop/src/__tests__/FileInput.stopButton.spec.ts` (they cover the
  button/`isStopping` path today) to assert that after a stop the `streaming-*`
  row is gone, `isStreaming === false`, and the partial text is still visible.

---

## 7. Out of scope (documented, not forgotten)

| Item | Why deferred |
|---|---|
| Cancellation during **tool execution** | `workflow.zig:1326` calls `handle_tool` with zero cancel checks (`rg cancel src/agentic_loop/handle_tool.zig` → no matches). A Stop mid-`bash`/sub-agent waits for the tool — unbounded. Real, but a separate card: each executor (`execSpawnSubAgent`, `execBash`, MCP) needs its own interrupt path. |
| `CURLOPT_XFERINFOFUNCTION` re-enable | See §9 Q1. |
| Sub-agent sessions inheriting the parent's cancel | `tools_exec_spawn_sub_agent.zig` would need to propagate. |
| TUI stop path | The TUI has its own entry (`src/apps/tui`); this plan targets the desktop/HTTP path the card is about. |

---

## 8. Verification

**Per the repo rules, no `nohup ./nalar --port 8080` + `curl`.** Use the
functional harness (`tests/functional/harness.py`) — it picks a free port in
8080..8199, isolates `HOME` to a tmpdir, and tears down. **Never touch port 8081.**

- [ ] **Functional latency test — `tests/functional/stop_session_latency_test.py`.**
  Clone the stub-provider pattern from `tests/functional/tui_turn_streaming_test.py`
  (it already boots a real binary + a `ThreadingHTTPServer` stub LLM + a session,
  `:69-121`): have the stub emit an SSE chunk every ~100 ms for ~30 s (slow enough
  that the turn is unambiguously in flight), write a profile pointing `base_url` at
  it, subscribe to `/api/events`, send a chat message, wait for ≥5 `llm_chunk`
  frames, then `POST /api/llm/session/<sid>/stop` and assert:
  - **time from POST to the last `llm_chunk` < 250 ms** ← the actual fix assertion;
  - `worker_deleted` arrives, and no further `llm_chunk` for that session;
  - a terminal `llm_full`/`full` arrives (Phase C) so the transcript settles.
  Both arms matter: this is a **wire** behaviour, so it belongs in this harness,
  not a unit test.
- [ ] **Functional stall test.** Same, with the stub emitting a chunk then pausing
  ~10 s with no bytes; assert the stop still lands < 1 s (Phase B2/B3). If B3 is
  skipped, this test documents the known gap instead of passing.
- [ ] **Unit (ginwaaitoolbox):** `call_streaming_test.zig` A5; plus a Zig test
  asserting the `catch` classification in A3 — a cancel-induced stream error must
  yield `error.Cancelled` and must **not** reach the retry branch (this is the
  regression that would silently re-run the user's request).
- [ ] **Unit (kabelweb):** B4.
- [ ] **No-retry assertion:** in the functional test, assert
  `retry`/`saveRetryAttemptMessage` diagnostics did **not** appear in the session
  after a stop (guards A3 at the integration level).
- [ ] **Regression:** the whole existing stop suite —
  `ChatView.stopSession.spec.ts` — plus `tests/functional/session_wire_test.py`
  and `tests/functional/tui_turn_streaming_test.py` (both touch streaming wire
  behaviour).
- [ ] **Measurement table** in the PR description: before/after latency for
  (a) mid-stream stop, (b) stop at the tail of a short response, (c) stop during a
  byte-silent pause.

---

## 9. Open questions

1. **Do we resurrect `CURLOPT_XFERINFOFUNCTION`?** It was disabled after
   *intermittent segfaults* — the callback fires on the worker thread inside
   `easy_perform`, and the userdata pointer chain landed on freed memory
   (`kabelweb stream.zig:896-913`). It is the only way to abort a transfer that is
   parked in a socket read with **zero** incoming bytes, so without it the stalled
   case's *worker* lingers until `CURLOPT_TIMEOUT_MS` (300 s) — though B3's
   poll-budget wakeup means the *user-visible* stop is still ~250 ms. Recommendation:
   land A + B1–B3 first, and only chase XFERINFO if profiling shows accumulating
   worker threads/sockets during heavy stop usage. If we do it, the fix must mirror
   the `WRITEDATA` wiring exactly (`@as(*anyopaque, @ptrCast(state))`, `stream.zig:891`,
   which is proven safe) rather than the old pointer math, and land with a stress
   test that cancels thousands of streams.
2. **Marker text for a stopped turn.** `"*[stopped by user]*"` appended to the
   partial, a `finish_reason: "cancelled"` on the emitted `full`, or a UI badge?
   Affects `sse_on_event_send_llm_history.zig:204` and the history renderer.
3. **Rate-limit the hot-loop check.** A4 mirrors the existing DB-polling thunk, so
   a fast stream does one indexed `SELECT` per chunk (~30–100/s). That is within
   the envelope the repo already accepts (`retry_delay_ms.zig:92` polls every
   50 ms), but if the perf suite complains, throttle to ≤10 Hz with a cached
   timestamp — or take the atomic-token route (`src/root.zig:75-105`
   `ContextIPCTui`, mirroring `stream_snapshot.zig:43`'s registry) so the stop
   handler flips an atomic the stream loop reads for free. Which one depends on
   the Q1 outcome (an atomic token is also what B2/B3 would read).
4. **Should Stop also cancel a queued-but-not-started message?** Out of scope here
   (the 2026-08-06 plan, `:83`, says queued messages stay queued) — confirming so
   nobody assumes this plan changes it.

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| **Cancel silently becomes a retry** — the abort surfaces as `CURLE_WRITE_ERROR` → `StreamInterrupted` → `retry_count += 1` → the request re-runs | A3 classification + the explicit no-retry functional assertion |
| Only Phase A lands → latency unchanged, "fix" looks broken | Phase A6 measurement gate; the plan states plainly that A needs B1 |
| `stream.cancel()` from the stop handler → use-after-free on the stack-owned `ResponseStream` | Avoided entirely by B3 (self-wakeup); if a registry is ever used, hold the lock across `cancel()` and unregister before `deinit` |
| kabelweb bump destabilises the vendored curl build | B is confined to `src/client/stream.zig`; run the full kabelweb `zig build test` before the pin bump |
| Emitting a terminal `full` while a late chunk is in flight | The abort is synchronous with detection (A2), so at most the in-flight chunk ordering differs; the `streaming-` row is filtered by prefix, so a late `chunk` cannot resurrect it. Verify in the functional test |

---

## 11. Recommended landing order

1. **B1 + B2** (kabelweb) — tiny, independently tested, unblocks everything.
2. **A1–A4** (ginwaaitoolbox) — the actual latency fix; measure at A6.
3. **C1–C2** — transcript settles, partial survives.
4. **B3** + the stall test — closes the reasoning-pause case.
5. **§9 Q1** only if profiling justifies it.
6. **§7 tool-execution cancellation** as its own card.
