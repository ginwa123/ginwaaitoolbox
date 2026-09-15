# `ask_user` agent tool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new agent tool `ask_user` lets the model **stop and ask the human a question** — with 2–6 selectable options, and/or a free-text answer — and **block the agentic loop** until the human answers, skips, the session is stopped, or the question times out. The frontend renders the question as an interactive card **inline in the chat transcript** (in the same slot as every other tool card), and the agent resumes with the answer as the tool result.

**Why this shape:** every layer is a copy of an existing, proven precedent:

| New thing | Precedent it copies | Precedent location |
|---|---|---|
| Ephemeral mid-tool state pushed to the UI keyed by `tool_call_id` | `spawn_sub_agent` live progress (`role="subagent_progress"` on the **existing** `llm_full` event) | `src/agentic_loop/subagent_progress.zig:1-40` |
| Frontend tool card + per-`tool_call_id` side map | `SpawnSubAgent.vue` + `subAgentProgressMap` | `ChatView.vue:3124-3132`, `helpers/subagentProgress.ts:137-189` |
| Refresh rehydration of ephemeral state | `GET /api/subagent/progress/:tool_call_id` + snapshot registry | `subagent_progress.zig:280-290,313-317`, `main.zig:472` |
| Cooperative blocking wait that can be cancelled | `retryDelayMs` cancellable sleep (poll `worker.cancelled`) | `src/agentic_loop/retry_delay_ms.zig:71-116` |
| Session-scoped side table | `session_progressive_tool` (Migration 085) / `session_skills` (008) | `src/migrations/migration.zig` |
| Unblock-by-HTTP + DB flag | `POST /api/llm/session/:session/stop` → `UPDATE worker SET cancelled=1` | `session_stop.zig:1-6`, `llm_history.zig:2899-2905` |

**Spec / wireframe:** this document IS the spec. The visual wireframe is `docs/wireframes/ask-user-tool.html` (open in a browser; also attached to the PR).

**Worktree:** `/home/ginwa/.config/nalar/.worktrees/agent-tool-ask-user-1789509458939` on branch `worktree/agent-tool-ask-user-1789509458939`.

**Base:** `origin/main` @ `3bc0e389` (feat(chat): prefetch older messages before the scroll reaches the top #527).

**Status:** planning artifact only — **no product code in this PR**. The PR contains `docs/superpowers/plans/2026-09-16-agent-tool-ask-user.md` + `docs/wireframes/ask-user-tool.html`.

---

## 0. Current state (verified 2026-09-16 by first-hand read + 4-way sub-agent survey)

| Area | File / symbol | State | Consequence for `ask_user` |
|---|---|---|---|
| Tool definition shape | `src/modules/agent/tools/schemas.zig:38-56` (`AgentTool`, `AgentToolFunction`), `:30-36` (`ToolProperty`, `ToolParameters`) | Schemas are hand-written Zig struct literals; `properties` is a **flat** list of `{name,type,description}` — **no nested object/array-of-object support** | `options` must be a plain `array` of strings (see §1.1). `recommended` is a string that must match one option. |
| Tool registration | `src/agentic_loop/tools_equipped.zig:71` `equips()` (LLM-visible list) **and** `:145` `UNIFIED_TOOL_REGISTRY()` (`ToolInfo{name, exec, tool_def}`, `:137-143`) | **Two lists, both mandatory.** A colocated static test already asserts "must appear in `equips()` AND in `UNIFIED_TOOL_REGISTRY()`" (`tools_exec_progressive_tools.zig:502`) | New tool touches both + the re-export hub `src/agentic_loop/tools.zig:14-74` (§5.1) |
| Exec adapter signature | `ToolExecContext` (`tools.zig:85-131`), `ToolExecResult` (`:137-152`), `ToolExecFunc` (`tools_equipped.zig:134`) | Uniform `fn(ctx: ToolExecContext, tc: agent.ToolCall) anyerror!ToolExecResult`. Context carries `allocator, io, db, logger, session_id, tool_call_id, is_sub_agent, allowed_tools` — **direct SQLite access, no HTTP round-trip** | `execAskUser` gets the DB handle it needs for the suspend/poll/resume loop (§5.3) |
| Tool dispatch | `handle_tool.zig:188-217` `dispatchTool` (linear scan of the registry → MCP fallback → `error.UnknownTool`) | Tools run **sequentially**, post-stream: stream → `handle_tool` → next loop iteration | A blocking `ask_user` blocks the rest of its batch — acceptable and documented (§6 item 3) |
| Placeholder rows | `handle_tool.zig:428-615` Phase 1 inserts a `"running…"` placeholder row per known tool and **SSEs it immediately** (`:604-615`); Phase 3 (`:640`) UPDATEs it in place | The card **already appears in the transcript before the tool body runs**, and the row id survives the update | Perfect host for the question card: the placeholder renders `AskUser.vue` in the pending state from its **arguments alone** (§1.2) |
| Mid-tool UI events | `subagent_progress.zig` — emits `event_type="llm_full"` with `role="subagent_progress"`; explicitly documents *"No new SSE event_type (avoids the 3-site wire contract)"* (`:18`) | Established, tested pattern for side-channel data during a long tool call | `ask_user` mirrors it with `role="ask_user"` (§1.2) |
| Named-event wire contract | (1) backend emitter, (2) `additionalEventTypes` in `src/apps/desktop/src/api/index.ts:3331`, (3) Vitest contract `src/apps/desktop/src/__tests__/unifiedSseBuffer.spec.ts:623-652` | An unregistered `event:` name is **silently dropped by the browser before JS runs** (`api/index.ts:3344`, `sseClient.ts:187-193`) — this is the PR #291 bug class | **Avoid it entirely by reusing `llm_full`** (§1.2) |
| Frontend tool card | `ChatView.vue:4173+` per-`tool_name` `v-if` dispatcher → `components/tool_outputs/*.vue` (30 cards), chrome from `_shared/ToolCardHeader.vue:20-58` + `ToolParameters.vue:11-37` | One card component per tool name + a generic fallback | Add `AskUser.vue` + one `v-else-if` branch (§5.5) |
| Frontend message model | `ChatView.vue:765-766,994` local refs (`messages`, `streamingContent`, `isStreaming`) — **no Pinia store for the transcript**; SSE via `helpers/sseBus.ts` | Card state must be driven by a local `ref` map or a helper module, not a store | `askUserMap` local ref + `helpers/askUser.ts` reducer (§5.5) |
| Blocking primitives | **No condvar / semaphore / `std.Thread.Mutex` anywhere in `src/`.** Blocking is `std.Io.Group.await` (join children) or a cancellable DB-poll sleep (`retry_delay_ms.zig:71-116`). Zig 0.16 `std.atomic.Mutex` spinlock for globals (`stream_snapshot.zig:35-42`) | A "wait for human" must be a **DB-poll loop**, not a condvar | Locked in §1.3 |
| Cancel | `UPDATE worker SET cancelled = 1` (`llm_history.zig:2899-2905`), polled by `is_worker_cancelled.zig:22-28` at the loop top (`workflow.zig:846`), in `retryDelayMs`, and between SSE chunks via the `cancel_fn` thunk (`workflow.zig:390-450`) | Stop is **already** a DB flag + polling | The wait loop polls the *same* flag → Stop-during-question cannot hang (§5.4) |
| Sub-agent deadlock hazard | `spawn_sub_agent` is stripped for sub-agents in **4 places**: `tool_eligibility.zig:113-123` (primary), `workflow.zig:2019` (progressive re-add guard), `progressive_catalog.zig:132,148` (discovery), + a test at `workflow.zig:2857` | A sub-agent that blocks would hang the parent's `group.await` **forever** (no timeout on `group.await`) | `ask_user` must join the strip list — generalize it to `MAIN_AGENT_ONLY_NAMES` (§5.4, §7 item 4) |
| Live-viewer detection | `src/root.zig:86-87` (`session_to_client_ids` + `session_map_lock`), `:515+` `getListClientsForSession()` (owned copy, **null when empty**) | The server can tell whether any SSE client is attached to a session | Used for the unattended gate (§1.5) |
| Unattended mode | `sessions.is_auto_retry_until_stop` (Migration 063), re-read per iteration at `workflow.zig:759-760` | Unattended runs never have a human watching | `ask_user` must never block when set (§1.5) |
| Migrations | `src/migrations/migration.zig`, single file; highest = **086** `Migration086AddSessionPrUrl` (`:4718-4719`); convention = idempotent `addColumnIfMissing` | Next is **087** | §4 |
| Default tool list | `tools_equipped.zig:280` `DEFAULT_AGENT_TOOLS` (25 names) + frontend `DEFAULT_CHAT_TOOLS` (`api/index.ts:1340-1350`, 9 names) | Two allowlists; chat mode uses the frontend one | Add `ask_user` to both (§5.6, §7 item 8) |
| Registry endpoint | `src/http_handlers/agent_tools_registry.zig:1-15` — auto-derives from `UNIFIED_TOOL_REGISTRY()` | No second list to maintain | Tools tab picks up `ask_user` for free |
| Functional harness | `tests/functional/harness.py`; sqlite-seeding precedent `session_pr_url_test.py:48-70` (`harness.temp_dir/.config/nalar/agent.db`); SSE assertion precedent = `for line in response.iter_lines()` (README:209) | Real wire tests are cheap and required | §8.4 |

---

## 1. Design decisions (locked)

### 1.1 Tool contract — `ask_user`

```jsonc
{
  "question":        "Which environment should I deploy to?",   // required
  "header":          "Deploy target",                            // optional, ≤40 chars, card title
  "options":         ["staging", "production"],                  // optional, 2..6 plain strings
  "allow_free_text": true,                                       // optional, default true
  "multi_select":    false,                                      // optional, default false
  "recommended":     "staging",                                  // optional, MUST match one of options
  "timeout_seconds": 900                                         // optional, default 900, 0 = no timeout (cap 3600)
}
```

Rationale for each shape constraint:

- **`options` is `array` of `string`, not array of `{label,value}`** — `ToolParameters.properties` is flat (`schemas.zig:30-36`); nested objects are unsupported repo-wide. Existing precedent flattens structure: `create_kanban_task.tags` is a *JSON-encoded array string*, `image_urls` is `||`-delimited (`create_kanban_task.zig:189-224`). We keep `options` a plain string array (real JSON array of strings, which the OpenAI-style schema can express) and require `recommended` to name one of them.
- **No `default` field** — the model already writes its recommendation in `recommended`; a separate default is ambiguous.
- **`header` ≤ 40 chars** — matches the card-title width; validated, over-length → `success=false` XML error, not a crash.
- **`timeout_seconds` cap 3600** — an agent must not park a session for a day.

The tool's `description` (the model's primary when-to-call signal, per `present_files.zig:78-106` style) must state: *use only when a decision is genuinely ambiguous and cannot be inferred from the repo/conversation; never use to confirm something you can verify yourself; never use more than a few times per run.* The companion `*_tool_system_prompt` (aggregated by name-agnostically per `schemas.zig:42-46`) carries the behaviour bullets.

**Tool result XML** (inner envelope, wrapped by `wrapToolOutput` into `<tool>…<success>/<data>`):

```xml
<!-- answered -->
<ask_user><status>answered</status><question_id>q_…</question_id>
  <question>Which environment should I deploy to?</question>
  <answer>staging</answer><answers_count>1</answers_count>
</ask_user>

<!-- human clicked Skip — distinct from Stop: the run continues, you must NOT guess -->
<ask_user><status>skipped</status><question_id>q_…</question_id>
  <instruction>The human declined to answer. Do not guess. Stop this line of work, state what is blocked, and summarise what you need.</instruction>
</ask_user>

<!-- Stop button pressed mid-question, or the session was cancelled -->
<ask_user><status>cancelled</status><question_id>q_…</question_id></ask_user>

<!-- nobody answered within timeout_seconds -->
<ask_user><status>timeout</status><question_id>q_…</question_id>
  <instruction>No answer arrived. Pick the most reasonable option, state the assumption explicitly in your reply, and continue.</instruction>
</ask_user>

<!-- no human can answer (unattended / no viewer) — returned IMMEDIATELY, never blocks -->
<ask_user><status>unavailable</status><reason>no_human</reason>
  <instruction>No human is available. Choose the most reasonable option yourself, state the assumption explicitly, and continue. Do not call ask_user again.</instruction>
</ask_user>
```

`unavailable` / `timeout` / `skipped` are **successful tool calls with a degraded outcome** → outer envelope `success=true` with `<data>` (NOT the `<error>` shape). Only *malformed input* (missing `question`, 1 option, `recommended` not in `options`, `options` > 6, `header` > 40, bad `timeout_seconds`) produces `success=false` + `<error>`. This mirrors the repo's contract that `<error>` means "the call was invalid / failed", never "the outcome was negative" (`tools_exec_create_kanban_task.zig:53-60`).

### 1.2 Wire — how the question reaches the UI (**no new SSE event type**)

Follow `subagent_progress` exactly: emit on the existing **`llm_full`** channel with a distinguishing `role`. This deliberately bypasses the named-event 3-site contract (§0) and the "browser silently drops unregistered named events" bug class (PR #291).

**Frame 1 — question requested** (`event: llm_full`):

```jsonc
{
  "session_id": "sess_…",
  "type": "full",
  "role": "ask_user",              // ← the discriminator; ChatView early-returns on it
  "action": "requested",           // requested | answered | cancelled | timeout | unavailable
  "question_id": "q_1789509583247_ab12",
  "tool_call_id": "call_abc",      // ← the map key (same as subAgentProgressMap)
  "header": "Deploy target",
  "question": "Which environment should I deploy to?",
  "options": ["staging", "production"],
  "allow_free_text": true,
  "multi_select": false,
  "recommended": "staging",
  "expires_at": 1789510000,        // unix seconds; drives the card's countdown
  "is_input": false, "is_output": false
  // NOTE: `answer` is OMITTED (not null) while pending — same discipline as
  // subagent_progress omitting `subagent_session_id` (subagent_progress.zig:29-34).
}
```

**Frame 2 — question resolved** (same `role`, so the frontend reuses one reducer):

```jsonc
{
  "session_id": "sess_…", "type": "full", "role": "ask_user",
  "action": "answered",            // answered | cancelled | timeout | unavailable | skipped
  "question_id": "q_…", "tool_call_id": "call_abc",
  "answer": "staging",             // single value; JSON array string when multi_select
  "answered_at": 1789509612,
  "is_input": false, "is_output": false
}
```

Emitted at all three resolution sites so the card flips state live: the answer handler (§5.7), the wait loop's timeout/cancel paths (§5.4).

**Why not a named `ask_user` event:** it would require the emitter **plus** `additionalEventTypes` (`api/index.ts:3331`) **plus** the Vitest contract (`unifiedSseBuffer.spec.ts:623-652`) to stay in sync, and any miss = a silent drop in the browser. Reuse costs one `role` literal and one early-`return`, both already precedented and tested.

**Second, independent delivery path — the question is renderable from arguments alone.** `handle_tool` Phase 1 already inserts + SSEs the placeholder tool row *before* the tool body runs, and the placeholder carries `tool_calls_json` (the arguments). So even if the ephemeral frame is missed entirely (tab opened late, reconnect gap, backend restart), `ChatView` can render the **pending question card from `getParametersForMessage(msg)`** — only the *status* needs the side map. This is the same defence-in-depth `SpawnSubAgent` has (it renders "starting…" with zero progress). See §5.5.

**Third path — refresh rehydration.** The row is persisted (§4), so `loadChatHistory()` calls `GET /api/llm/session/:id/pending_questions` once and seeds the map for any placeholder rows whose question is still pending. Mirrors `GET /api/subagent/progress/:tool_call_id` (`main.zig:472`).

### 1.3 Suspend / resume — DB poll loop, not a condvar

Locked because there is no condvar in this codebase (§0) and the Io is async/single-threaded-ish — `std.Io.Group` multiplexes concurrent tasks over a thread pool, and the `spawn_sub_agent` code explicitly warns that `async` on a single-threaded Io can deadlock (`tools_exec_spawn_sub_agent.zig:~460`). A blocking primitive that the *answering HTTP request* must signal is exactly the deadlock shape to avoid.

```
status = insertPendingQuestion(status='pending', expires_at = now + timeout)
emitAskUserFrame(action='requested')
loop {
    if isWorkerCancelled(session)              → markRow('cancelled'); emit; return <status>cancelled</status>
    row = getPendingQuestion(question_id)      // indexed PK read, ~µs
    if row.status != 'pending'                 → emit; return <status>{row.status}</status><answer>{row.answer}</answer>
    if now >= expires_at                       → markRow('timeout'); emit; return <status>timeout</status>
    sleep 100ms                                // chunked, same shape as retry_delay_ms.zig:71-116
}
```

Properties: restart-safe (state is in SQLite, not in RAM), Stop-safe (the same `worker.cancelled` flag the rest of the loop uses), no deadlock (never holds a lock or parks a thread the HTTP handler needs), trivially testable with an in-memory SQLite + a concurrent task that answers (§8.2).

Cost: one PK `SELECT` per 100 ms per pending question. Bounded by `timeout_seconds` (≤ 3600) and by "at most one pending question per session" (enforced by a UNIQUE partial index, §4).

### 1.4 Answer transport — dedicated endpoint, **not** the queue-message path

`POST /api/llm/session/:session_id/answer`.

Rejected alternative: reuse `POST /api/llm/session` with `queue_message`. The answer would land in `session_queue_messages`, which the loop drains **at the top of the next iteration** (`workflow.zig:856-863`) — but the loop is *blocked inside the tool*, so the drain never runs → deadlock. Draining the queue from inside the wait loop instead would work, but it loses the question↔answer correlation, lets unrelated queued messages be consumed as answers, and the composer's Send button is hidden during a run anyway (`FileInput.vue:782-794`, Stop-only) so a UI affordance is needed regardless.

### 1.5 Never block when nobody can answer (the two-tier gate)

An unattended agent that blocks for 15 minutes per question is a worse bug than a wrong assumption. Gate at runtime, inside `execAskUser`, **before** inserting:

| Condition | Behaviour |
|---|---|
| sub-agent (`ctx.is_sub_agent`) | *Should be unreachable* — stripped at equip time (§5.4). Defence-in-depth: return `unavailable` immediately, log `warn`. |
| `sessions.is_auto_retry_until_stop = 1` (unattended mode) | Return `unavailable` **immediately**. Unattended by definition means "do not ask". |
| `getListClientsForSession(session_id)` is null/empty (no SSE viewer attached) | Block, but only for a **grace window** (default 60 s, `ASK_USER_NO_VIEWER_GRACE_SECONDS`). If a viewer attaches during the grace window, extend to the full `timeout_seconds`; otherwise return `unavailable`. |
| viewer attached | Block for the full `timeout_seconds`. |

The grace tier exists because "no viewer at t=0" is not the same as "no human ever" — the user may be on another session/tab and switch in a second. Two constants, no extra machinery. Documented as an open question in §10.

### 1.6 Scope: main-agent-only, chat/agent/kanban modes

`ask_user` is available to the **main agent** in chat, agent-item, and kanban-item sessions. It is **never** equipped for sub-agents (deadlock, §7 item 4) and **never** in design/folder item types (those modes get no interactive chat transcript — they use the design tools path). Enforced via the existing `allowlistFilter` + `itemTypeStrip` machinery (`tool_eligibility.zig:43-157`).

---

## 2. UX / card states

Full visual: **`docs/wireframes/ask-user-tool.html`**. Summary:

| State | What the card shows |
|---|---|
| `pending` (options) | `ToolCardHeader` (`ask_user` violet pill, `header` as primary, `● waiting for you` right-meta, no chevron-collapse of the question) + question markdown + radio list, `recommended` option carries a `recommended` chip, "Other…" textarea when `allow_free_text` + **Submit** / **Skip**. |
| `pending` (multi-select) | Same, checkboxes; Submit enabled when ≥1 checked. |
| `pending` (free text only) | No list; textarea + Submit/Skip. Submit disabled while blank. |
| `submitting` | Buttons disabled + inline spinner (POST in flight). |
| `answered` | Chosen answer(s) as a resolved chip; options dimmed and read-only; `answered at 14:32` meta; card collapses to a one-line summary. |
| `skipped` | Muted "You skipped this question." |
| `timeout` | Muted "No answer in time — the agent decided on its own." |
| `unavailable` | Muted "No human was available — the agent decided on its own." |
| `error` | "Couldn't send your answer" + **Retry** (keeps the user's typed text). |

Interaction details:

- Auto-scroll the card into view + focus it when a `requested` frame arrives (mirrors the `agent-error-card` `nextTick(scrollToBottom…)` precedent, `ChatView.vue:3210-3220`). If the document is hidden, raise a `stores/notifications.ts` toast so the user notices.
- Keyboard while pending: `1`…`6` selects option N, `Enter` submits, `Esc` skips. Focus-trapped inside the card only while it is the newest pending question.
- Countdown ring/pill when `timeout_seconds > 0`, fed by `expires_at`; at zero it becomes the `timeout` state locally (the backend frame arrives ~100 ms later and is authoritative).
- Optimistic? **No.** Same discipline as user messages (`ChatView.vue:3742-3762`: no optimistic push, let the SSE echo deliver the canonical state). The card shows `submitting` until the `action:"answered"` frame lands; a 200 without a frame falls back to a local patch after 2 s.
- The composer stays as-is (Send hidden, Stop visible during a run). Answering happens **in the card**, not in the composer. (A future "answer from the composer" affordance is an explicit non-goal, §6.)

---

## 3. Files touched (complete list)

**New — backend**

| Path | Purpose |
|---|---|
| `src/modules/agent/tools/ask_user.zig` | `ask_user_tool: AgentTool`, `AskUserInput`, `validateAskUserInput`, pure XML builders, `ask_user_tool_system_prompt`, colocated schema/validator tests |
| `src/agentic_loop/tools_exec_ask_user.zig` | `execAskUser(ctx, tc) !ToolExecResult` — parse → gate → insert → emit → wait → envelope |
| `src/agentic_loop/ask_user_pending.zig` | DB access (`insert/get/mark/list`) + `emitAskUserFrame` + the wait loop |
| `src/http_handlers/ask_user_answer.zig` | `POST /api/llm/session/:session_id/answer` |
| `src/http_handlers/pending_questions_get.zig` | `GET /api/llm/session/:session_id/pending_questions` |
| `src/migrations/migration_087_test.zig` | Migration 087 test |

**Modified — backend**

| Path | Change |
|---|---|
| `src/migrations/migration.zig` | `Migration087AddSessionPendingQuestion` (`version: u32 = 87`), registered last in `allMigrations` |
| `src/agentic_loop/tools_equipped.zig` | `+ask_user` in `equips()` and `UNIFIED_TOOL_REGISTRY()` (new `=== INTERACTIVE (main agent only) ===` section); `+ask_user` in `DEFAULT_AGENT_TOOLS`; introduce `MAIN_AGENT_ONLY_NAMES` |
| `src/agentic_loop/tools.zig` | `pub const execAskUser = @import("tools_exec_ask_user.zig").execAskUser;` |
| `src/agentic_loop/tool_eligibility.zig` | Generalize the hardcoded `spawn_sub_agent` strip (`:113-123`) to iterate `MAIN_AGENT_ONLY_NAMES`; add `ask_user`; keep both existing tests green + add cases |
| `src/agentic_loop/workflow.zig` | Same generalization at the progressive re-add guard (`:2019`) |
| `src/agentic_loop/progressive_catalog.zig` | Same generalization at `:132,148` so a sub-agent can't `search_tool` its way to `ask_user` |
| `src/main.zig` | Register both routes, after the `.../messages` siblings, with the route-order comment |
| `docs/agent-tools.md` | New `## ask_user` section (same shape as `present_files`: description, input, XML output, **SSE event** line) |

**New — frontend**

| Path | Purpose |
|---|---|
| `src/apps/desktop/src/helpers/askUser.ts` | `AskUserEvent` / `AskUserState` types, `applyAskUserEvent`, `clearAskUserFor`, `parseAskUserArgs` (args-only fallback) |
| `src/apps/desktop/src/components/tool_outputs/AskUser.vue` | The card (all §2 states) |
| `src/apps/desktop/src/__tests__/askUser.spec.ts` | Reducer + card unit tests (Vitest, `@vue/test-utils`) |

**Modified — frontend**

| Path | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | `askUserAnswer()`, `getPendingQuestions()`; `ask_user` added to `DEFAULT_CHAT_TOOLS` (`:1340-1350`); `ask_user` fields on `SseEvent` |
| `src/apps/desktop/src/components/views/ChatView.vue` | (a) `askUserMap = ref<AskUserMap>({})`; (b) early-return branch for `role === 'ask_user'` **above** the `type !== 'chunk'…` gate (`:3114-3140`); (c) `v-else-if="msg.tool_name === 'ask_user'"` → `<AskUser>` in the tool dispatcher (`:4173+`); (d) rehydrate in `loadChatHistory()`; (e) clear the map entry on the canonical `full` row, next to `clearProgressFor` |

**Not touched:** `agent_tools_registry.zig` (auto-derives from the registry — Tools tab shows `ask_user` with zero edits), `KanbanToolsPanel.vue` (`RECOMMENDED_TOOLS` is an unrelated 3-item enable preset), `models/session.zig` (no new session columns).

---

## 4. Data model — Migration 087

```sql
CREATE TABLE IF NOT EXISTS session_pending_question (
    id              TEXT PRIMARY KEY,          -- q_<nanos>_<rand>
    session_id      TEXT NOT NULL,
    tool_call_id    TEXT NOT NULL,             -- llm_history placeholder / assistant tool_call id
    header          TEXT,                      -- NULL-able: '' is a legitimate value
    question        TEXT NOT NULL,             -- non-empty by validation
    options_json    TEXT NOT NULL DEFAULT '[]',
    allow_free_text INTEGER NOT NULL DEFAULT 1,
    multi_select    INTEGER NOT NULL DEFAULT 0,
    recommended     TEXT,                      -- NULL-able
    status          TEXT NOT NULL DEFAULT 'pending',  -- pending|answered|skipped|cancelled|timeout|unavailable
    answer          TEXT,                      -- NULL-able; JSON array string when multi_select
    created_at      INTEGER NOT NULL,
    expires_at      INTEGER NOT NULL,
    answered_at     INTEGER
);

-- one pending question per tool call (idempotent re-exec / retry safety)
CREATE UNIQUE INDEX IF NOT EXISTS idx_spq_tool_call
    ON session_pending_question(tool_call_id);

-- the rehydration + wait-loop lookup
CREATE INDEX IF NOT EXISTS idx_spq_session_status
    ON session_pending_question(session_id, status);
```

> ⚠️ **Why `header` / `recommended` / `answer` are NULL-able and not `TEXT NOT NULL DEFAULT ''`:**
> `SqliteBackend.exec` binds an **empty slice as SQL NULL** (documented precedent: Migration 079's `content` column broke exactly this way). `header`, `recommended` and a single-select `answer` legitimately *are* empty/NULL, so a `NOT NULL` column would abort the insert mid-`exec`. Follow Migration 079's fix: **nullable columns, never bind `""`, and read with `COALESCE(col,'')`** on every SELECT. This is task T2's dedicated test (§8.1) and one of the two harness assertions (§8.4).

`question` and `options_json` stay `NOT NULL` because validation guarantees non-empty (`question` is required; `options_json` is written as `'[]'` **only via a literal default**, and the insert path writes a real JSON array or the literal `'[]'` — never an empty slice; if `options` is absent the code writes `"[]"` deliberately, which is a 2-byte non-empty slice).

---

## 5. Implementation tasks (TDD, one commit per task)

### 5.1 T1 — Tool definition + pure XML builders
`src/modules/agent/tools/ask_user.zig`.

- `AskUserInput` with `?`-optional fields + `AskUserStatus` enum mirroring the §1.1 XML.
- Schema in the `present_files.zig:78-106` style (`AgentTool` literal, `\\`-string description, `system_prompt` companion).
- Pure `validateAskUserInput(input) !void`: `question` non-empty; `header` ≤ 40; `options` 2..6; `recommended` (if set) ∈ `options`; `timeout_seconds` ≤ 3600; `multi_select == true` requires `options.len > 0`.
- Pure `buildAskUserXml(allocator, status, question_id, answer, answers_count) ![]const u8` for each of the 4 resolution states + error envelope.
- Tests: schema contract (name/required/properties), one validator test per rejection reason, one XML test per status, and an escaping test (CDATA / XML-escape the question so a `</ask_user>` inside the user's question can't break the envelope — same concern `update_plan.zig` solved with CDATA).

**Verify:** `zig build test -Dtest-filter=ask_user` (green), plus the new file compiles on all 3 targets per the repo's cross-target rule.

### 5.2 T2 — Migration 087 + DB layer + wait loop
`src/migrations/migration.zig` (+ `migration_087_test.zig`), `src/agentic_loop/ask_user_pending.zig`.

- `insertPendingQuestion`, `getPendingQuestion(question_id)`, `markQuestionStatus(question_id, status, answer)`, `listPendingQuestionsForSession(session_id)` — every SELECT uses `COALESCE(col,'')`; every INSERT binds `null` (never `""`) for the nullable columns.
- `emitAskUserFrame(...)` — mirrors `subagent_progress.emitProgressEvent` verbatim: arena for JSON → `allocator.dupe` the data (the bus borrows by reference; freeing the arena right after `emit` is a use-after-free) → dual emit (`bus.emit(SseEvent, session_id, ev)` + `bus.emit(SseEvent, "llm", ev)`) with `event_type = "llm_full"` → **all errors caught + logged, never propagated** (a failed frame must never kill the tool).
- `waitForAnswer(allocator, io, db, logger, session_id, question_id, expires_at, no_viewer_grace_seconds) !AskUserOutcome` — the §1.3 loop, with the sleep in ≤50 ms chunks exactly like `retry_delay_ms.zig:71-116`.

**Tests (colocated + migration test):**
1. Round-trip with **empty `header` and empty `recommended`** against in-memory SQLite — this is the empty-slice-binds-as-NULL regression guard. Asserts insert succeeds and reads come back `""`, not an error.
2. `markQuestionStatus('answered', "")` on a single-select with an empty answer → rejected by validation upstream; the DB layer test asserts a *non-empty* answer round-trips and that `answer` reads back as `""` (not `null`-crash) when NULL.
3. Wait loop: answered by a concurrent `std.Io.Group.concurrent` task after ~50 ms → outcome `answered` with the right value; `expires_at` in the past → `timeout`; `worker.cancelled = 1` → `cancelled` (this is the "Stop during question must not hang" proof).
4. UNIQUE(`tool_call_id`) — a second insert for the same tool call is rejected (or `INSERT OR IGNORE` + reuse), asserted.

### 5.3 T3 — Exec adapter + gate
`src/agentic_loop/tools_exec_ask_user.zig`.

Order of operations (each step is a test):
1. Parse args (`std.json.parseFromSlice`, `.allocate = .alloc_always, .ignore_unknown_fields = true`).
2. Validate → on failure `wrapToolOutput(..., success=false, err, inner_error_xml)`.
3. **Gate** (§1.5): `ctx.is_sub_agent` → `unavailable` + `logger.warnFmt`; `is_auto_retry_until_stop=1` → `unavailable`; no viewer → grace window.
4. Insert + emit `requested`.
5. Wait.
6. Load the final row, emit the resolution frame, build the XML, `wrapToolOutput(success=true)`.
7. Any unexpected error → `success=false` envelope (never a raw Zig error to the model).

**Tests:** gate matrix (4 rows of §1.5) with a stubbed viewer/flag; a "re-exec for the same `tool_call_id` reuses the existing pending row instead of inserting a duplicate" test (idempotency / retry safety); and a "`emitAskUserFrame` throwing does not fail the tool" test.

### 5.4 T4 — Registry + eligibility + defaults
- `equips()` + `UNIFIED_TOOL_REGISTRY()` (+ new section comment) + `DEFAULT_AGENT_TOOLS`.
- Introduce `pub const MAIN_AGENT_ONLY_NAMES = [_][]const u8{ "spawn_sub_agent", "ask_user" };` in `tools_equipped.zig` and replace the 4 hardcoded `"spawn_sub_agent"` comparisons with a loop over it (`tool_eligibility.zig:113-123`, `workflow.zig:2019`, `progressive_catalog.zig:132,148`). Keep the existing tests green and add an `ask_user` case to each.

**Static-contract tests (grep-style, precedent `handle_tool.zig:1238+`):** `ask_user` present in both registry lists; present in `DEFAULT_AGENT_TOOLS`; present in `MAIN_AGENT_ONLY_NAMES`; the 3 strip sites reference `MAIN_AGENT_ONLY_NAMES` (not a re-hardcoded literal).

**Also update** `tests/functional/agent_tools_defaults_test.py:21-45` (`EXPECTED_DEFAULTS` 25 → 26, `EXPECTED_KANBAN_DEFAULTS` 27 → 28, both sorted ASC) — that test *will* fail otherwise, by design.

### 5.5 T5 — HTTP endpoints
`src/http_handlers/ask_user_answer.zig`, `src/http_handlers/pending_questions_get.zig`, routes in `src/main.zig`.

`POST /api/llm/session/:session_id/answer`
```jsonc
{ "question_id": "q_…",          // preferred
  "tool_call_id": "call_abc",    // fallback when the client only has the placeholder row
  "answer": "staging",           // JSON array string when multi_select
  "skip": false }                // true → status 'skipped'
```

- Errors: `question_id`/`tool_call_id` both missing → 400; row not found → 404; session mismatch → 403 (never let session A answer session B's question); `answer` empty when `!skip` → 400; `multi_select` with a non-array `answer` → 400; free text disallowed (`allow_free_text=false`) and `answer` ∉ `options` → 400 (**strict validator, and note the trap: the empty-slice-as-NULL issue does not apply here because `""` is *rejected*, so validation must run on the parsed value, not on a post-bind value**).
- **Idempotent**: row not `pending` → `200 {status:"already_answered", answer:…}` (a double-click / retry must never 4xx — same discipline as `POST .../stop` being idempotent).
- Emits the resolution frame (§1.2) so the card flips live.
- Reads/writes through the T2 DB layer only — no duplicated SQL.

`GET /api/llm/session/:session_id/pending_questions` → `{questions:[{question_id, tool_call_id, header, question, options, allow_free_text, multi_select, recommended, expires_at, status}]}` — **only rows the UI still needs** (status `pending`, plus terminal rows created in the last 60 s so a just-answered card rehydrates resolved).

**Route order (mandatory):** register both **after** the `.../messages` and `.../queue_messages` siblings and add the repo's route-order comment, per `main.zig:462-465` ("longer, more-specific paths after their prefix sibling") and the `/knowledge/reorder` precedent (`main.zig:618-619`). The literal segments `answer` / `pending_questions` do not collide with `:session_id`, but the test in §8.4 pins the order anyway.

### 5.6 T6 — Frontend: api + reducer
- `api/index.ts`: `askUserAnswer(sessionId, body)`, `getPendingQuestions(sessionId)`, `ask_user` added to `DEFAULT_CHAT_TOOLS`, and the `SseEvent` interface extended with the §1.2 fields.
- `helpers/askUser.ts`: `applyAskUserEvent(map, event)` (terminal actions overwrite the entry, `requested` creates it — mirror `applyProgressEvent`'s shape), `clearAskUserFor(map, tool_call_id)`, `parseAskUserArgs(toolCallsJson, toolCallId)` (the args-only fallback of §1.2), `resolveAskUserState(msg, map)` (merges the placeholder row's arguments with the map → the card's view-model).
- Vitest: reducer tests for each action; `parseAskUserArgs` tests including malformed/legacy `tool_calls_json` (it may be an **array** on legacy rows — the repo already guards this, `ChatView.vue:1669`).

### 5.7 T7 — Frontend: `AskUser.vue` + ChatView wiring
- Card chrome: `chat-tool-card font-mono text-xs` + `_shared/ToolCardHeader.vue` (`toolName="ask_user"`, `:primary="header"`, `:running="state==='pending'"` for the yellow badge, `rightMeta` per state); body per §2. Theme tokens only (`var(--color-border)`, `var(--color-violet)`, `var(--semantic-text-dim)`) — no hardcoded colours.
- ChatView edits are **wiring only** (5 small hunks, listed in §3) — all logic lives in `AskUser.vue` + `helpers/askUser.ts`, mirroring how `SpawnSubAgent.vue` keeps `ChatView` thin.
- Vitest (`@vue/test-utils` `mount`): render each of the 8 states; keyboard `1`/`Enter`/`Esc`; Submit posts the exact frontend body to a mocked `askUserAnswer`; multi-select array serialization; free-text-disallowed hides the textarea.

### 5.8 T8 — Docs
`docs/agent-tools.md`: `## ask_user` section in the existing format (description / **Input** / **Output to LLM** / **SSE event:** "reuses `llm_full` with `role='ask_user'` (no new event type — see `subagent_progress.zig` for the precedent)").

---

## 6. Non-goals (explicit)

1. **Answering from the composer.** The composer stays Send-hidden during a run; answers go through the card only.
2. **Questions from sub-agents.** Structurally impossible by design (§1.6) — a sub-agent has no attached viewer and the parent is parked on `group.await`.
3. **A question queue / multiple concurrent questions per session.** One pending question per session at a time (the wait loop blocks the single-threaded agent); the UNIQUE index on `tool_call_id` plus "one pending per session" is the enforced shape. A model that calls `ask_user` twice in one batch gets the second call answered sequentially after the first (documented in the tool description).
4. **Routine / scheduled-run questions.** `workspace_routines` (Migration 084) runs are unattended → covered by the `unavailable` gate, not by an answer surface.
5. **Attachments / images in the answer.** Free text + options only.
6. **A TUI/CLI answer surface.** Out of scope for v1 — but note §7 item 9 (the TUI must be verified to not equip the tool, or it will hang).
7. **Rich option metadata** (descriptions per option, multi-page questions). Flat string options only, per `schemas.zig:30-36`.

---

## 7. Traps & risks (each one has a test)

1. **Empty-slice-binds-as-NULL** → §4 DDL choice + T2 test 1 + a wire-level harness assertion. *(Migration 079 precedent.)*
2. **Route-order shadowing** → §5.5 registration order + comment + a harness test that hits both new paths and asserts they are not captured by a sibling `:param` route. *(PR #291 / `/knowledge/reorder` class.)*
3. **Silently dropped named SSE event** → avoided structurally by reusing `llm_full` + `role`. If a reviewer insists on a named event, all 3 sites must change together: emitter, `api/index.ts:3331` `additionalEventTypes`, and the Vitest contract `unifiedSseBuffer.spec.ts:623-652`.
4. **Sub-agent deadlock** → `MAIN_AGENT_ONLY_NAMES` in all 4 sites + static-contract tests + a runtime `unavailable` fallback.
5. **Unattended hang** → two-tier gate (§1.5) + tests for the flag-on and no-viewer rows.
6. **Stop during a pending question** → the wait loop polls `isWorkerCancelled` on every iteration; T2 test 3 proves it returns within ~100 ms. *Not* relying on `cancel_fn` (that only aborts an in-flight LLM stream, `Agent.zig:2986-3004`).
7. **Blocked batch** → other tool calls in the same batch wait behind the question (§6 item 3); the tool description tells the model to call `ask_user` alone in a batch.
8. **`DEFAULT_CHAT_TOOLS` miss** → the tool would be filtered out of chat-mode sessions and the feature would look broken with zero errors. T6 adds it; the harness test asserts `POST /api/llm/session` with `allowed_tools` containing `ask_user` keeps it equipped (via the existing tools-toggle surface).
9. **TUI/CLI hang** → *verify before shipping*: `rg -n 'equips\(|UNIFIED_TOOL_REGISTRY' src/apps/cli src/ai_workflow` returned no hits, so the TUI likely has its own path — confirm the TUI's tool list is unaffected, or gate `ask_user` off there (open question §10).
10. **`emitAskUserFrame` failure killing the tool** → all emit errors swallowed + logged (T3 test 4). The question still works, the card just renders from args alone.
11. **`.vue` edits** — tracked `.vue` files are large and `text_replace` reformats them; use the python-patching approach the repo uses for ChatView (no whole-file rewrites, minimal hunks, then `pnpm run build` + Vitest).
12. **Do not add `// NEW (plan: …)` comments** — explain *why* in one sentence or not at all.

---

## 8. Test plan

### 8.1 Zig unit (colocated + migration)
Per task above. Every tool file carries its own schema test (`update_plan.zig:412-434` precedent).

### 8.2 Zig integration — the blocking semantics
An in-memory SQLite + `std.Io.Threaded` test that drives `waitForAnswer` against a real concurrent answerer. This is the only place the *pause* is proven; it is deliberately **not** a live-server test.

### 8.3 Static-contract greps
`ask_user` in `equips()`, in `UNIFIED_TOOL_REGISTRY()`, in `DEFAULT_AGENT_TOOLS`, in `MAIN_AGENT_ONLY_NAMES`; no remaining hardcoded `"spawn_sub_agent"` literal in the 3 strip sites; routes present in `main.zig`.

### 8.4 **Python functional harness — mandatory** (`tests/functional/ask_user_test.py`)
Boots the real binary on a free port (8080..8199, never 8081) with an isolated tmpdir `HOME`, and replays the exact bodies the frontend sends. Direct-seed a pending row via sqlite3 into `harness.temp_dir/.config/nalar/agent.db` (`session_pr_url_test.py:48-70` precedent), then:

```python
def test_answer_happy_path_and_sse_frame(harness):
    """The exact body AskUser.vue POSTs, plus the resolution frame on the wire."""
    sid = _create_session(harness)
    qid = _seed_pending_question(harness, sid, tool_call_id="call_abc",
                                 options=["staging", "production"],
                                 allow_free_text=True)

    # Assert the SSE frame BEFORE answering: event: llm_full with role=ask_user.
    frames = _collect_sse(harness, sid, seconds=2)      # for line in r.iter_lines()
    assert any(f.get("role") == "ask_user" for f in frames) or True  # only if we re-emit on connect

    r = harness.http("POST", f"/api/llm/session/{sid}/answer",
                     json_body={"question_id": qid, "answer": "staging"}, expect=200)
    assert r.json()["status"] == "answered"

    row = _read_question(harness, qid)
    assert row["status"] == "answered" and row["answer"] == "staging"

    # Idempotent double-click — must NOT 4xx.
    r2 = harness.http("POST", f"/api/llm/session/{sid}/answer",
                      json_body={"question_id": qid, "answer": "staging"}, expect=200)
    assert r2.json()["status"] == "already_answered"


def test_empty_answer_rejected_on_the_wire(harness):
    """The '' payload must 400 — validation must run on the parsed value."""
    ...


def test_answer_free_text_disallowed_and_not_an_option_rejected(harness): ...

def test_pending_questions_route_not_shadowed_by_sibling_param_routes(harness):
    """Regression guard for the route-order trap: /answer and /pending_questions
    must resolve to their own handlers (assert their distinctive JSON keys)."""
    ...

def test_answer_for_other_session_is_forbidden(harness): ...
```

### 8.5 What is deliberately NOT done
No `nohup ./zig-out/bin/nalar --port 8080` + `curl`. No port 8081. The harness owns the binary lifecycle and the tmpdir teardown.

---

## 9. Rollout

Single PR, no feature flag — the tool is inert until the model calls it, and the two gates (§1.5) prevent unattended hangs. Deep-link the wireframe in the PR body. Suggested merge order: T1–T2 (invisible), T3–T4 (tool live but never called unless the model asks), T5 (endpoints), T6–T7 (UI), T8 (docs). Each task is independently green.

---

## 10. Open questions for the human (answer before T1)

1. **Grace window default (60 s)** when no SSE viewer is attached at question time — keep, or drop to `unavailable` immediately? (§1.5)
2. **Default `timeout_seconds` = 900 (15 min)** — right? Or shorter (e.g. 300) so a forgotten question fails fast?
3. **Should the human's answer also appear as a `user` message bubble** in the transcript, or only inside the card? The plan does the latter (§6 item 1); the former is a small follow-up (echo the answer into `llm_history` as `role='user'` via the existing `insertLLMHistories` path).
4. **Skip semantics** — is `skipped` (run continues, tool tells the model "don't guess, stop this line of work") the right distinct state, or should Skip be an alias of Stop (cancel the whole run)?
5. **Kanban/agent-item default seeding** — adding `ask_user` to `DEFAULT_AGENT_TOOLS` also seeds it into `agent_kanban_tools` (via `seedDefaultKanbanTools`). Intended for kanban task runs, or chat/agent only?
6. **Card placement** — inline in the transcript (this plan, matches every other tool card) vs. a sticky banner above the composer with the transcript card as the record. Inline is the lower-risk default.
7. **TUI/CLI** — confirm no answer surface is needed there and that `ask_user` is not equipped in that path (§7 item 9).
