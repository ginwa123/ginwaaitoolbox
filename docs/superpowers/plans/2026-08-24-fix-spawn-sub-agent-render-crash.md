# Fix `spawn_sub_agent` card shows "0 sub-agents" — SSE/REST wire-shape mismatch crashes `messageGroups`

> **Status:** planned (NOT yet executed). Awaiting human review.

## Problem

After PR #301 (spawn-subagent-live-progress) shipped, the chatview's
`<SpawnSubAgent>` card *should* show running/done/failed counts + per-agent
rows mid-run. Instead users (including this session) see the card stuck on
**"0 sub-agents"** for the entire sub-agent run, then either:

1. flip to the parsed-envelope view at completion (`✓N ✗N`), or
2. stay broken if anything in the envelope parse fails.

The user's console in their `task_1787586032476_9` ("cannot save profile")
session shows the smoking gun:

```
Uncaught (in promise) TypeError: msg.tool_calls_json?.trim is not a function
    at ChatView.vue:1390:32
    at Array.map (<anonymous>)
    at ComputedRefImpl.fn (ChatView.vue:1377:30)
    at refreshComputed (vue.runtime.esm-bundler-...)
    at get value (vue.runtime.esm-bundler-...)
    at hasBubbleContent (ChatView.vue:1500:42)
    at ChatView.vue:1312:34
    at Array.filter (<anonymous>)
    at ComputedRefImpl.fn (ChatView.vue:1312:17)
```

`messageGroups` recomputes → throws → Vue falls through the render error
boundary → `<SpawnSubAgent>` never renders, the card body collapses to
the placeholder text, the live `:progress` rows never appear.

## Root cause (verified by code read, no live test needed)

The wire shape of `tool_calls_json` is **inconsistent** between the SSE
path and the REST path:

| Path         | Source                                                      | Wire type             |
| ------------ | ----------------------------------------------------------- | | -------------------- |
| SSE event    | `on_event_sent.zig:80` — `SseEventLLMHistory.tool_calls_json: ?[]const ToolCallJson` | JSON **array** |
| SSE event (the alternate emitter used by some LLM-history rows) | `sse_on_event_send_llm_history.zig:29` — `SseEventLLMHistory.tool_calls_json: ?[]const u8` | JSON **string** |
| REST history | `http_response.zig:268` — `SessionMessage.tool_calls_json: []const u8`               | JSON **string** |
| REST loader  | `session_messages_get.zig:122` — copies `msg.tool_calls_json` directly (string)     | JSON **string** |

Frontend `SseEvent.tool_calls_json?: any` (api/index.ts:1107) accepts
both shapes — but `ChatView.vue:1390` assumes it's always a string:

```ts
if (msg.tool_calls_json?.trim()) {           // ← throws if value is Array
  const parsed = JSON.parse(msg.tool_calls_json)  // ← also crashes here
  ...
}
```

Two concrete mid-run deliveries trigger the crash:

1. **The assistant message's `tool_calls` row** arrives via
   `sendSSEForLatestMessage` (handle_tool.zig:457). This emits
   `tool_calls_json` as a JSON array (the `?[]agent.ToolCall` slice
   round-trips through `std.json.fmt`). `ChatView.vue:2311` pushes
   `event.tool_calls_json` verbatim into `messages.value` — so the
   row's `tool_calls_json` is a JS Array. The very next `messageGroups`
   recompute throws.
2. **Any chunked SSE event** where the emitter populates
   `tool_calls_json` (today: only the full assistant row). Chunks carry
   no tool_calls so they're safe; the crash is bounded to the full
   event.

On page refresh the REST path runs first, populates messages with string
`tool_calls_json`, then SSE-arrived rows may overwrite — but on a fresh
load the card works until the next assistant tool_call message arrives.
This is why users see "0 sub-agents" sometimes and not always.

**Bonus latent bug** confirmed during live SSE capture: `root.zig:466-470`
unconditionally `ev_bus.unsubscribe(rk)` in `handleClientDisconnect`,
which kills the shared `"llm"` bus callback for **all** clients when
**any** one disconnects. Symptoms: bus events briefly vanish for
survivors until a new client reconnects and re-subscribes. **Separate
fix, separate task — do NOT conflate with this one.**

## Fix (single-source-of-truth + defensive)

Two layered changes — the backend one stops shipping the bad shape, the
frontend one survives any future regression.

### Change 1 — Backend: emit `tool_calls_json` as a string

In `src/ai_workflow/tui/agentic_loop/on_event_sent.zig`, change the
SSE-emit payload struct so `tool_calls_json` is always serialized as a
JSON string (matching the REST path):

- Rename the field type: `tool_calls_json: ?[]const ToolCallJson` →
  `tool_calls_json: ?[]const u8` (a serialized JSON string).
- Where the caller passes the array (around `SseEventLLMHistory`
  construction in the same file, lines 270-285), serialize via
  `std.json.fmt` into a stable buffer and `.dupe` into `tool_calls_json`.
- Update every caller of `onEventSendLLMHistory` that passes
  `tool_calls_json` (mostly in `handle_tool.zig:457` →
  `sendSSEForLatestMessage` and the `sse_on_event_send_llm_history.zig`
  wrapper) — they can either keep passing the array and let the
  emitter serialize, or pass an already-serialized string. Choose ONE
  consistent rule; recommend callers continue to pass the typed array
  (already the case) and the emitter serializes once.

### Change 2 — Frontend: guard `ChatView.vue:1390`

Make the `.trim()` call defensive — the regression test is "if a
backend bug ever ships the array shape again, the card stays blank but
nothing throws":

```ts
// before
if (msg.tool_calls_json?.trim()) {
  const parsed = JSON.parse(msg.tool_calls_json)
  ...
}

// after
const tcj = msg.tool_calls_json
if (typeof tcj === 'string' && tcj.trim()) {
  const parsed = JSON.parse(tcj)
  ...
}
```

Apply the same guard to line 1568 (REST loader — `msg.tool_calls_json`
is already always a string there but the guard is free defense) and to
`findSubAgentArgsForToolGroup` at line 1457 (which also calls `.trim`
on the same field — same crash).

## Plan

- [ ] Backend: change `on_event_sent.zig` `SseEventLLMHistory.tool_calls_json`
      type + serialize at emit site. Keep behavior of the alternate
      emitter in `sse_on_event_send_llm_history.zig` (which already
      takes `?[]const u8`) unchanged — verify it stays in sync.
- [ ] Backend: add an inline test in `on_event_sent.zig` asserting the
      serialized `tool_calls_json` is a JSON **string** of an array,
      not an array directly. Reuse the `setupLlmBusAndIo()` pattern
      from `sse_on_event_send_llm_history.zig`.
- [ ] Frontend: guard `ChatView.vue:1390`, `1457`, `1568` with
      `typeof === 'string'`. (One line per site.)
- [ ] Frontend: add a vitest spec covering both shapes (string vs
      array) feeding the `messageGroups` computed — guard never
      throws.
- [ ] Build + run `zig build test --summary all` (must stay 0 fail / 0
      leak). Build `zig build nalar-desktop --summary all`. Run
      `bun run test:unit` (must stay green).
- [ ] Verify end-to-end with a live probe (raw `curl` on
      `/api/events?channels=llm` + a fresh sub-agent) — confirm the
      `tool_calls_json` field on the assistant row is now `"..."` (a
      JSON-encoded string of the array), not `[...]` (the array).
- [ ] Update `docs/Recent changes` changelog entry.

## Why this is small and safe

- The SSE emitter change is local: one struct field type + one
  serialize block at the only emit site.
- The frontend guards are zero-risk cosmetic changes (TypeScript
  doesn't see the runtime shape anyway).
- The wire change is **backward-compatible for the frontend** —
  string-shaped `tool_calls_json` is exactly what the consumer
  already expects. The only thing that changes is which side does the
  `JSON.stringify`.
- No migration, no schema change, no SSE event-name change (the
  3-site contract is unchanged).

## Files touched

Backend (3):
- `src/ai_workflow/tui/agentic_loop/on_event_sent.zig` (struct +
  emit-site serialize + inline test)

Frontend (2):
- `src/apps/desktop/src/components/views/ChatView.vue` (3-line guard
  at 1390/1457/1568)
- `src/apps/desktop/src/components/views/__tests__/ChatView.spec.ts`
  (new spec covering array vs string)

Changelog (1):
- `AGENTS.md` / `docs/Recent changes` entry.

## Out of scope (separate follow-ups)

- **`root.zig:466-470` ev_bus unsubscribe on disconnect** — also
  verified live that this kills the shared `"llm"` callback for all
  remaining SSE clients when any one disconnects. Symptoms are bus
  events briefly vanishing for survivors. Tracked as a separate
  follow-up kanban card; do not conflate with this fix.
- **`messageGroups` error boundary** — Vue's render-error fallback
  turns any thrown error into "blank card", which is the reason this
  bug manifested as "0 sub-agents" instead of a noisy console error.
  Worth wrapping `messageGroups` in a try/catch that logs the error
  and returns the LAST computed value, but again, separate task.

## Verification commands

```bash
# static + unit
zig build test --summary all
zig build nalar-desktop --summary all
bun run test:unit

# live wire (after rebuild)
curl -sN 'http://localhost:8080/api/events?channels=llm' >/tmp/probe.txt &
spawn a sub-agent via the UI
rg '"tool_calls_json":' /tmp/probe.txt | head   # must show strings, not arrays
```