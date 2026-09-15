# `ask_user` agent tool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new agent tool `ask_user` lets the model **stop and ask the human a question** — with 2–6 selectable options and/or a free-text answer. The tool call **ends the agent turn**; the question renders as an interactive card inline in the chat transcript; when the human answers, the answer is written back as the tool result and a **new run resumes the conversation** with that answer in context.

**Why this shape (reviewer decision, 2026-09-16):** the loop does **not** park inside the tool. `ask_user` returns immediately, the batch finishes, and the agentic loop **breaks**. That makes the whole feature a row-lifecycle problem instead of a concurrency problem, and it deletes most of the machinery a blocking design needs — see §1.2 for the diff.

**Spec / wireframe:** this document IS the spec. Visual wireframe: `docs/wireframes/ask-user-tool.html`.

**Worktree:** `/home/ginwa/.config/nalar/.worktrees/agent-tool-ask-user-1789509458939` on branch `worktree/agent-tool-ask-user-1789509458939`.

**Base:** `origin/main` @ `3bc0e389`.

**Status:** planning artifact. This PR contains `docs/superpowers/plans/2026-09-16-agent-tool-ask-user.md` + `docs/wireframes/ask-user-tool.html`.

---

## 0. Current state (verified 2026-09-16 by first-hand read + 3×2 sub-agent surveys)

| # | Fact | Evidence | Consequence |
|---|---|---|---|
| 1 | **Phase 1 of `handle_tool` inserts a placeholder tool-result row for EVERY tool call in the batch — including unknown tools.** The `has_known_tools` flag only gates a log line; the insert loop has no filter. | `src/agentic_loop/handle_tool.zig:459-467` (flag), `:513-566` (insert loop + `is_feed_to_llm = true`, `tool_call_id`, `tool_name`) | Ending the run after `handle_tool` leaves a **matched** chain: assistant `tool_calls` + one `role=tool` row per call. The OpenAI "every tool_call_id needs a tool response" contract is satisfied by construction. **This is what makes the break-the-loop design safe.** |
| 2 | The assistant row is written before the placeholders, with `.tool_calls = tc`. Phase 3 UPDATES each placeholder **in place** (content only — never `is_feed_to_llm`/`tool_call_id`/`tool_name`). | `handle_tool.zig:471-505`, `:640-665`; `llm_history.updateToolResultById` = `UPDATE llm_history SET response_content = ?, … WHERE id = ?` (`llm_history.zig:3040-3071`) | We can rewrite the question's tool-result row **in place** when the human answers, keeping the row id stable — so the open `ChatView` patches the card live over the existing `llm_full` path. |
| 3 | Placeholder rows are `is_feed_to_llm = 1`. | `handle_tool.zig:513-566`; fetched by `get_llm_histories.zig:30-57` (`WHERE is_feed_to_llm = 1 OR IS NULL`) | The tool-result row **will** be replayed to the model on the resume run. Therefore the answer **must** be written into that row *before* the resume run starts (§1.4). |
| 4 | **There is no orphan-sanitizer and no pairing validation anywhere** in the history→payload path (fetch → `parsing.transformLLMHistoryToAgentMessage` → `prompts_build_messages_for_agent_prompt` → `buildJsonOpenAIRequest` / Anthropic / Responses). Pure concatenation. | `get_llm_histories.zig:30-57`, `parsing.zig:9-32,40-84`, `prompts_build_messages_for_agent_prompt.zig:240-247`, `Agent.zig:1669-1719,1360-1428,1905-1952` | Two-edged: no safety net if the chain *were* broken — and no obstacle when it is intact. Fact #1 is what keeps it intact. The one guard that exists is for an orphan tool *output* (empty `call_id`), not an orphan tool *call* (`Agent.zig:1947-1952`). |
| 5 | **`FinishReason` is an enum with `from_str`/`to_str`, and there is NO exhaustive `switch` on it anywhere.** All uses are `== .stop` / `== .length` / `== .tool_calls` comparisons plus assignments. | `Agent.zig:94-129`; `workflow.zig:1386,1480,1487` | Adding an `awaiting_user` variant is cheap and type-safe (no switch arms to update). The precedent for free-form is `"cancelled"` (`workflow.zig:541`), deliberately outside the enum. |
| 6 | `sessions.last_finish_reason` is **display-only**. The kanban card paints dots on `=== 'stop'`; the API doc enumerates `'stop'` / `''` only. Nothing branches on it for control flow. | `http_response.zig:517-525`, `WorkspaceItemTaskCard.vue:429,448`, `tasks_list.zig:211-214`, `session_mark_touched.zig:123` | A new terminal value cannot break behaviour. Product note: a pending question gets **no** kanban dot unless we extend the `=== 'stop'` conditions (§5 T9, optional). |
| 7 | The `.stop` branch cleanup is: persist assistant row → `hasQueuedMessages` guard (`continue`) → optional OS notify → `deleteWorker(is_emit_sse=true)` → `break`. | `workflow.zig:1386-1479` | The break path mirrors this, **minus** the queue guard (a queued message must not be allowed to run while a question is pending — it would send the model a `pending` envelope, §1.5). |
| 8 | `deleteWorker` is idempotent (`DELETE` matching 0 rows is not an error; tests assert the no-op and the null-bus cases). | `delete_worker.zig:19-62` + its tests | Safe to call from a new break path, even twice. |
| 9 | A run can be started with **no new user message**: `emit_run_agent(.{ …, skip_initial_queue_message = true })`. Two existing callers. | `root.zig:57-73` (struct), `:139-248` (impl, dupes all strings into the long-lived allocator); `start_agent.zig` (step 4); `cleanup_stale_background_process.zig:258-320` (`wakeSessionForCompletion`) | The "resume after an answer" trigger already exists — it is the same shape as "wake a session for a background-process completion". No new mechanism. |
| 10 | `session_create.zig` is the single funnel for every user-sent message → `emit_run_agent` at line 258. | `session_create.zig:258`; `root.zig:139` | One guard here covers chat send, kanban create-and-run and any API caller (§1.6). |
| 11 | `updateAndSendToolResult` (`handle_tool.zig:763`) and `sendSSEForMessageById` (`:840`) are **private `fn`**. But their ingredients are public: `llm_history.updateToolResultById`, `llm_history.getMessageById` (`:2422`), `onEventSendLLMHistory`. | quoted in §5 T6 | The answer handler composes the public pieces (~20 lines) rather than widening `handle_tool`'s API. |
| 12 | Tool registration needs **two** lists (`equips()` + `UNIFIED_TOOL_REGISTRY()`) + the re-export hub; sub-agent stripping is hardcoded in **4** sites; `DEFAULT_AGENT_TOOLS` seeds agent + kanban items; chat mode uses the frontend's `DEFAULT_CHAT_TOOLS`. | `tools_equipped.zig:71,145,280`; `tool_eligibility.zig:113-123`; `workflow.zig:2019`; `progressive_catalog.zig:132,148`; `tools.zig:14-74`; `api/index.ts:1340-1350` | Unchanged from the earlier survey — T4/T8 handle it. |
| 13 | `src/migrations/migration.zig` is a single file; 086 was the highest when this plan was written. `SqliteBackend.exec` binds `""` as NULL. | `migration.zig`; Migration 079 precedent | Migration **088** + nullable columns + `COALESCE` on read (§4). Written as 087; by rebase time `main` had taken 087 for the agent-routines mirror, so the number moved and nothing else. |
| 14 | Frontend running-state is driven **purely by worker lifetime**: `App.vue` `processingState` ← `worker_created|worker_deleted` → `ChatView.isLLMProcessing` → `FileInput` swaps Stop↔Send. Nothing reads a local streaming flag for it. | `App.vue:12-13,32-51,114-130`; `ChatView.vue:451-454`; `FileInput.vue:794,825` | When the run breaks, the composer returns to **idle** (Send visible, Stop hidden) while the card waits. That is why §1.6 needs the `abandoned` rule. |
| 15 | Frontend `finish_reason` is a plain `string` with no exhaustive switch; tool cards are dispatched by an exact `msg.tool_name` `v-if` chain; card content comes from `innerToolData(msg)` (the `&lt;data&gt;` inside the `<tool>` envelope) and args from `getParametersForMessage(msg)`. `unwrapToolOutput` ignores unknown inner tags. | `ChatView.vue:180,1424,1693,1946,3211,4178-4420,1575-1603`; `helpers/unwrapToolOutput.ts:61-95` | A `<status>` element inside `<data>` parses fine; the card is one `v-else-if` branch with no helper changes. |
| 16 | `ToolCardHeader.running` exists (yellow "running…" badge) but is only ever set by `ProgressiveTool.vue`, derived from *empty content*. | `ToolCardHeader.vue:46-59,124-128`; `ProgressiveTool.vue:58` | The `AskUser` card derives its own "waiting for you" badge from `<status>pending</status>` and passes `:running="true"` itself. |
| 17 | Functional-harness precedent: sqlite3 direct seeding into `harness.temp_dir/.config/nalar/agent.db`, `harness.http(...)`, SSE assertions via `for line in response.iter_lines()`. | `tests/functional/harness.py`; `session_pr_url_test.py:48-70`; README:209 | §8.4 is a genuine end-to-end test of this feature **with no LLM** — see the note there. |

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
  "recommended":     "staging"                                   // optional, MUST match one of options
}
```

- **No `timeout_seconds`.** With the loop broken there is nothing to wait on: the question can sit for a week at zero cost. Removing it removes a knob, a sentinel, a test and a failure mode.
- **`options` is a flat array of strings**, not `{label,value}` — `ToolParameters.properties` has no nested-object support (`schemas.zig:30-36`).
- **`header` ≤ 40 chars**, validated; over-length → `success=false` + `<error>`.
- The `description` must say: use only when a decision is genuinely ambiguous and cannot be inferred from the repo or the conversation; never to confirm something you can verify yourself; one question at a time; never in the same batch as other tools.

**Tool result envelope** (written by Phase 3 into the tool-result row):

```xml
<!-- immediate return: the turn is ending, the human has been asked -->
<ask_user><status>pending</status><question_id>q_…</question_id>
  <instruction>The human has been asked and this turn is ending. Do not continue and do not guess — you will be resumed with their answer.</instruction>
</ask_user>

<!-- written in place by the answer endpoint, BEFORE the resume run starts -->
<ask_user><status>answered</status><question_id>q_…</question_id>
  <question>Which environment should I deploy to?</question>
  <answer>staging</answer><answers_count>1</answers_count>
</ask_user>

<ask_user><status>skipped</status><question_id>q_…</question_id>
  <instruction>The human declined to answer. Do not guess. State what you are blocked on and stop this line of work.</instruction>
</ask_user>

<!-- the human sent a different message instead of answering (§1.6) -->
<ask_user><status>abandoned</status><question_id>q_…</question_id>
  <instruction>The human moved on without answering. Do not guess. If the answer is still needed, ask again once.</instruction>
</ask_user>

<!-- unattended run or sub-agent: returned immediately, NO row is written -->
<ask_user><status>unavailable</status><reason>no_human</reason>
  <instruction>No human is available. Choose the most reasonable option yourself, state the assumption explicitly, and continue. Do not call ask_user again.</instruction>
</ask_user>
```

`skipped` / `abandoned` / `unavailable` are **successful tool calls with a degraded outcome** → outer envelope `success=true` + `<data>`. Only malformed input produces `success=false` + `<error>` (the repo's contract: `<error>` means "the call was invalid", never "the outcome was negative" — `tools_exec_create_kanban_task.zig:53-60`).

### 1.2 The loop **breaks** — and what that deletes

The call arrives as a tool call, so the LLM turn's `finish_reason` is `tool_calls` (`workflow.zig:1487`). `handle_tool` runs the batch to completion (every tool_call gets its row, fact #1), and then the workflow **breaks instead of looping back**.

| Machinery a blocking design needs | Needed here? |
|---|---|
| Blocking wait loop + 100 ms DB poll | **no** |
| `timeout_seconds` + `expires_at` sentinel | **no** |
| `orphaned` state + boot-time sweep for runs that died mid-question | **no** — nothing is parked; the run ended cleanly |
| Ephemeral `role="ask_user"` SSE frames + emitter module | **no** — the card reads the tool-result row, which is real persisted `llm_history` |
| Frontend side map + reducer + `GET …/pending_questions` rehydration | **no** — refresh-safety is free because the row is in `llm_history` |
| `cancelled` card state (Stop mid-question) | **no** — there is no in-flight run to stop |
| Sub-agent **deadlock** hazard | **no** — a sub-agent asking would simply end its own run (still stripped, §1.7, but the risk drops from deadlock to uselessness) |
| Parked-forever session holding an `active_loops` slot | **no** |

Net effect: a **smaller** backend (no new concurrency primitive at all) and a much smaller frontend (one card component + one `v-else-if`).

### 1.3 Where the run ends

Immediately after `try handle_tool(...)` in the `.tool_calls` arm (`workflow.zig:1502`):

```
if (hasPendingQuestion(allocator, db, session_id)) {
    // persist the assistant row for this turn with finish_reason = "awaiting_user"
    // then mirror the .stop cleanup: deleteWorker(is_emit_sse = true); break;
}
```

Deliberately **no** `hasQueuedMessages` guard (unlike `.stop`): a queued user message must not be allowed to start another iteration while a question is pending, because the loop would send the model the `pending` envelope and the model might guess (§1.5).

`finish_reason = "awaiting_user"` is persisted on the assistant row **and** mirrored into `sessions.last_finish_reason` via the existing `updateSessionLastFinishReason` (`workflow.zig:1373-1384`). Add `awaiting_user` to the `FinishReason` enum (`Agent.zig:94-129`, plus `from_str`/`to_str`) so it round-trips — cheap, because no exhaustive switch exists (fact #5). The alternative (`"cancelled"`-style free-form, `workflow.zig:541`) is noted but rejected: an enum variant makes any *future* `switch` fail to compile until it is handled.

### 1.4 The answer writes itself back into the tool-result row, then resumes

`POST /api/llm/session/:session_id/answer` does, in this order:

1. validate (§1.5);
2. `UPDATE session_pending_question SET status='answered', answer=?, resolved_at=?`;
3. **UPDATE the tool-result `llm_history` row in place** with the `answered` envelope, and emit its `llm_full` → the open `ChatView` flips the card live, no new event type (fact #2);
4. `emit_run_agent(.{ …, skip_initial_queue_message = true })` guarded by `isWorkerRunning` → a fresh run reads history, finds the answered tool result, and continues.

Order matters: the row must be rewritten **before** the resume run fetches history, or the model would see `<status>pending</status>` (fact #3). If step 3 fails, do **not** start the run — return 500 and leave the row `pending` so the user can retry (the reverse order would silently converge on "the model saw pending and guessed").

### 1.5 Validation & errors (`POST …/answer`)

```jsonc
{ "question_id": "q_…",          // preferred
  "tool_call_id": "call_abc",    // fallback for a client that only has the row args
  "answer": "staging",           // JSON array string when multi_select
  "skip": false }                // true → status 'skipped'
```

| Case | Response |
|---|---|
| neither `question_id` nor `tool_call_id` | 400 |
| unknown id | 404 |
| row belongs to another session | 403 (never let session A answer session B) |
| `answer` empty and `!skip` | 400 (validation runs on the **parsed** value — the empty-slice-as-NULL trap does not apply because `""` is *rejected*, not stored) |
| `multi_select` and `answer` is not a JSON array | 400 |
| `allow_free_text = false` and `answer` ∉ `options` | 400 |
| already resolved | **200** `{status:"answered"\|"skipped"\|"abandoned", answer:…}` — a double-click or a Retry must never 4xx (same discipline as `POST …/stop`) |

`allow_free_text` / `options` come from re-parsing the **tool-result row's own envelope**: `wrapToolOutput` embeds the original arguments as `<parameters>{…}</parameters>` (`tools_wrap_output.zig`), so the endpoint parses them from the row — no duplicated columns (§4).

### 1.6 A new user message resolves a pending question instead of dead-ending

Because the run ended, the composer is **idle** (Send visible — fact #14). If the user ignores the card and types a message, the session must not start a run that shows the model a `pending` envelope.

**Rule:** in `session_create.zig`'s use-case, immediately before `emit_run_agent` (line 258), if the session has a pending question → resolve it as **`abandoned`** (rewrite the tool-result row with the `abandoned` envelope, no separate SSE needed — the resume run's history fetch carries the final content) → then run normally with the user's message.

So the human is never dead-ended and the model never guesses: moving on *is* an answer, and the model is told exactly that. One guard, at the single funnel, covering chat send + kanban create-and-run + every API caller (fact #10).

Defensive second guard: at the top of each loop iteration (next to the existing cancel poll at `workflow.zig:846`), if `hasPendingQuestion(session_id)` → `break`. Covers scheduler-initiated runs (`wakeSessionForCompletion`) that bypass the `session_create` funnel. One indexed `SELECT 1 … LIMIT 1` per LLM round-trip — negligible.

### 1.7 Gates — when the agent must not ask

| Condition | Behaviour |
|---|---|
| sub-agent (`ctx.is_sub_agent`) | stripped at equip time (§5 T4) **and** runtime `unavailable` + `logger.warnFmt`. A sub-agent run has no answer surface: the question would sit forever and the sub-agent would return nothing useful. |
| unattended (`sessions.is_auto_retry_until_stop = 1`) | `unavailable` immediately, **no row** — the model decides in the same run and the run completes. Scheduled/routine runs must not leave dangling questions. |
| otherwise | ask. No viewer check: the card is a persisted row, so whoever opens the session later sees it. |

### 1.8 Scope — seeded in **every** agent mode by default

Chat (`DEFAULT_CHAT_TOOLS`), agent items (`DEFAULT_AGENT_TOOLS`) and kanban items (which seed `DEFAULT_AGENT_TOOLS` + `DEFAULT_KANBAN_TOOLS`). Never for sub-agents. Design/folder items seed no tool list at all, so they are unaffected by construction.

---

## 2. UX / card states

Full visual: **`docs/wireframes/ask-user-tool.html`**. The card derives **everything** from two things it already has: `msg.tool_name`, `innerToolData(msg)` (the `<data>` payload → `<status>`), and `getParametersForMessage(msg)` (the args → question, options, header, recommended, flags).

| State | `<status>` | Card |
|---|---|---|
| `pending` (single-select) | `pending` | `ToolCardHeader` (violet `ask_user` pill, `header` as primary, yellow `● waiting for you` badge, no countdown) + question markdown + radio list, `recommended` chip, "Other…" textarea when `allow_free_text`, **Send answer** / **Skip**. |
| `pending` (multi-select) | `pending` | Same with checkboxes; Send enabled when ≥1 checked. |
| `pending` (free text only) | `pending` | Textarea only; Send disabled while blank. |
| `submitting` | `pending` | Buttons disabled + spinner (POST in flight). |
| `answered` | `answered` | Chosen answer as a resolved chip; options dimmed; collapses to a one-line summary. |
| `skipped` | `skipped` | Muted "You skipped this question." |
| `abandoned` | `abandoned` | Muted "You moved on without answering." |
| `unavailable` | `unavailable` | Muted "No human was available — the agent decided on its own." (unattended runs only) |
| `error` | `pending` | POST failed + **Retry** (keeps the typed text). |
| invalid args | — | `success=false` + `<error>` (e.g. `recommended` not in `options`). |

Interaction: auto-scroll into view + focus when the card appears; if `document.hidden`, raise a `stores/notifications.ts` toast. Keys while pending: `1..6` select, `Enter` send, `Esc` skip. No optimistic swap — the card stays `submitting` until the `llm_full` row update lands, then falls back to a local patch after 2 s.

The composer stays idle and functional (§1.6) — the card is the affordance, and typing a message is a legitimate "I'm moving on" signal rather than an error path.

---

## 3. Files touched

**New — backend**

| Path | Purpose |
|---|---|
| `src/modules/agent/tools/ask_user.zig` | `ask_user_tool: AgentTool`, `AskUserInput`, `validateAskUserInput`, XML builders, system prompt, colocated tests |
| `src/agentic_loop/tools_exec_ask_user.zig` | `execAskUser(ctx, tc) !ToolExecResult` — parse → gate → insert row → return the `pending` envelope immediately |
| `src/agentic_loop/ask_user_pending.zig` | DB layer (`insert/get/resolve/markAbandoned/hasPending`) + `writeAnswerToToolResultRow` (row rewrite + SSE) + `resumeSession` (the `emit_run_agent` shape) |
| `src/http_handlers/ask_user_answer.zig` | `POST /api/llm/session/:session_id/answer` |
| — (no separate migration test file) | The migration's columns are covered by the DB-layer tests in `src/agentic_loop/ask_user_pending.zig` and by `tests/functional/ask_user_test.py`, which exercises the real schema through the app. |

**Modified — backend**

| Path | Change |
|---|---|
| `src/migrations/migration.zig` | `Migration088AddSessionPendingQuestion` (`version: u32 = 87`) |
| `src/agentic_loop/tools_equipped.zig` | `+ask_user` in `equips()` and `UNIFIED_TOOL_REGISTRY()`; `+ask_user` in `DEFAULT_AGENT_TOOLS`; new `MAIN_AGENT_ONLY_NAMES` |
| `src/agentic_loop/tools.zig` | re-export `execAskUser` |
| `src/agentic_loop/tool_eligibility.zig` | loop `MAIN_AGENT_ONLY_NAMES` instead of the hardcoded `spawn_sub_agent` compare |
| `src/agentic_loop/progressive_catalog.zig` | same generalization (`:132,148`) |
| `src/agentic_loop/workflow.zig` | the break after `handle_tool` (§1.3); the iteration-top guard (§1.6); the progressive re-add guard (`:2019`) |
| `src/modules/agent/Agent.zig` | `awaiting_user` variant in `FinishReason` + `from_str` + `to_str` |
| `src/http_handlers/session_create.zig` | the `abandoned` guard before line 258 |
| `src/main.zig` | the one new route, with the route-order comment |
| `docs/agent-tools.md` | `## ask_user` section |

**New — frontend**

| Path | Purpose |
|---|---|
| `src/apps/desktop/src/components/tool_outputs/AskUser.vue` | the card (all §2 states) |
| `src/apps/desktop/src/__tests__/AskUser.spec.ts` | Vitest: each state, keyboard, the exact POST body |

**Modified — frontend**

| Path | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | `answerQuestion(sessionId, body)`; `ask_user` added to `DEFAULT_CHAT_TOOLS` |
| `src/apps/desktop/src/components/views/ChatView.vue` | **one** `v-else-if="msg.tool_name === 'ask_user'"` branch, placed before the `mcp_*` `startsWith` guard |

**Optional (product touch, §5 T9):** `WorkspaceItemTaskCard.vue:429,448` — paint the orange "awaiting review" dot for `last_finish_reason === 'awaiting_user'` so a kanban card whose run is waiting on a question is visible in the board.

**Not touched:** `agent_tools_registry.zig` (auto-derives → the Tools tab shows `ask_user` for free), `models/session.zig`, any SSE event-name list (`additionalEventTypes` unchanged — no new event type anywhere).

---

## 4. Data model — Migration 088

```sql
CREATE TABLE IF NOT EXISTS session_pending_question (
    id             TEXT PRIMARY KEY,          -- q_<nanos>_<rand>
    session_id     TEXT NOT NULL,
    tool_call_id   TEXT NOT NULL,             -- the LLM's tool_call id
    llm_history_id TEXT NOT NULL,             -- the tool-result row we rewrite on answer
    question       TEXT NOT NULL,             -- for logs/debug; the UI reads the args
    status         TEXT NOT NULL DEFAULT 'pending',  -- pending|answered|skipped|abandoned
    answer         TEXT,                      -- NULL-able: '' is a legitimate value
    created_at     INTEGER NOT NULL,
    resolved_at    INTEGER
);

-- one question per tool call (idempotent re-exec / retry safety)
CREATE UNIQUE INDEX IF NOT EXISTS idx_spq_tool_call
    ON session_pending_question(tool_call_id);

-- the pending-check hot path: hasPendingQuestion() and the abandon guard
CREATE INDEX IF NOT EXISTS idx_spq_session_status
    ON session_pending_question(session_id, status);
```

There is **no** `options_json` / `allow_free_text` / `recommended` / `expires_at` column: the args live in the tool-result row's `<parameters>` (fact #2/#15) and there is no timeout (§1.1). Fewer columns = fewer places for the empty-slice trap.

> ⚠️ **`answer` is NULL-able, never bound as `""`.** `SqliteBackend.exec` binds an empty slice as SQL NULL (Migration 079's `content` column broke exactly this way), and an empty answer is meaningless anyway — but a single-select answer of `""` must still be *rejected by validation*, not by a NOT NULL constraint. Reads use `COALESCE(answer,'')`.

Statuses are exactly `pending | answered | skipped | abandoned` — `unavailable` writes **no row** (§1.7).

---

## 5. Implementation tasks (TDD, one commit per task)

### 5.1 T1 — Tool definition
`src/modules/agent/tools/ask_user.zig`: `AskUserInput`, the `AgentTool` literal in the `present_files.zig:78-106` style, `ask_user_tool_system_prompt`, `validateAskUserInput` (`question` non-empty; `header` ≤ 40; `options` 2..6; `recommended` ∈ `options`; `multi_select` requires options), `buildAskUserPendingXml` + `buildAskUserResolvedXml(status, answer, count)`, CDATA/XML-escaping the question so `</ask_user>` inside it cannot break the envelope (`update_plan.zig` precedent).

**Tests:** schema contract; one per rejection reason; one per status envelope; the escaping case.

### 5.2 T2 — Migration 088 + DB layer
`src/agentic_loop/ask_user_pending.zig`:
- `insertPendingQuestion`, `getPendingQuestion(id | tool_call_id)`, `markQuestionStatus(id, status, answer)`, `markAbandonedForSession(session_id)`, `hasPendingQuestion(allocator, db, session_id) bool` (`SELECT 1 … LIMIT 1`, mirroring `hasQueuedMessages`/`isWorkerRunning`).
- All SELECTs `COALESCE(answer,'')`; the INSERT binds `null` for `answer` (never `""`).

**Tests (in-memory SQLite):**
1. insert with `answer` NULL → reads back `""`; insert with an explicit empty-string *slice* must not be attempted (assert the helper's contract).
2. `hasPendingQuestion` true only while `status='pending'`; false after resolve; false for another session.
3. UNIQUE(`tool_call_id`): a second insert for the same tool call is ignored (`INSERT OR IGNORE`) — idempotent re-exec safety.
4. `markAbandonedForSession` resolves **all** pending rows for that session, and none for others.

### 5.3 T3 — Exec adapter + gate
`src/agentic_loop/tools_exec_ask_user.zig`: parse → validate → gate (§1.7) → `insertPendingQuestion` → return `ToolExecResult{ .output = pending_envelope, .output_allocated = true }`. Never block, never sleep, never write to `llm_history` (Phase 3 does that).

**Tests:** each gate row; "the returned envelope is `success=true` with `<status>pending</status>`"; "no pending row is written on the `unavailable` path".

### 5.4 T4 — Registry, eligibility, defaults, FinishReason
- `equips()` + `UNIFIED_TOOL_REGISTRY()` (+ an `=== INTERACTIVE (main agent only) ===` section) + `DEFAULT_AGENT_TOOLS`.
- `MAIN_AGENT_ONLY_NAMES = { "spawn_sub_agent", "ask_user" }` replacing the 4 hardcoded comparisons (`tool_eligibility.zig:113-123`, `workflow.zig:2019`, `progressive_catalog.zig:132,148`); keep existing tests green, add an `ask_user` case to each.
- `Agent.zig`: `awaiting_user` in `FinishReason` + `from_str` + `to_str`.

**Static-contract tests:** present in both registry lists; in `DEFAULT_AGENT_TOOLS`; in `MAIN_AGENT_ONLY_NAMES`; the 3 strip sites reference the list (no re-hardcoded literal); `FinishReason.from_str("awaiting_user") != null` and round-trips through `to_str`.

**Also:** `tests/functional/agent_tools_defaults_test.py:21-45` — `EXPECTED_DEFAULTS` 25 → 26, `EXPECTED_KANBAN_DEFAULTS` 27 → 28. That test *will* fail otherwise, by design.

### 5.5 T5 — The break
`src/agentic_loop/workflow.zig`:
- after `try handle_tool(...)` (`:1502`): `if (hasPendingQuestion(...)) { persist assistant row with finish_reason="awaiting_user"; try deleteWorker(.{ …. is_emit_sse = true }); break; }` — mirroring `.stop` minus the queue guard (§1.3);
- iteration top (near `:846`): the defensive `hasPendingQuestion` → `break` guard (§1.6);
- persist `sessions.last_finish_reason` through the existing `updateSessionLastFinishReason` call.

**Tests:** static-contract (the break exists in the `.tool_calls` arm; there is **no** `hasQueuedMessages` guard on this path); a workflow-level test that a session with a pending row does not reach a second LLM call.

### 5.6 T6 — HTTP endpoint + the row rewrite + the resume
`src/http_handlers/ask_user_answer.zig`, route in `main.zig` (after the `…/messages` / `…/queue_messages` siblings, with the route-order comment — `main.zig:462-465`).

- Validation/status matrix per §1.5; options/free-text read by unwrapping `<parameters>` from the tool-result row.
- **Row rewrite:** `llm_history.updateToolResultById` (`llm_history.zig:3040`) → `llm_history.getMessageById` (`:2422`) → `onEventSendLLMHistory` with `tool_call_id = msg.tool_call_id orelse msg.id` (the exact wire convention `sendSSEForMessageById` documents at `handle_tool.zig:832-903`). Written as a ~20-line pub helper in `ask_user_pending.zig` — `updateAndSendToolResult`/`sendSSEForMessageById` are private and also do diffview extraction we do not need (fact #11).
- **Resume:** `emit_run_agent` with `skip_initial_queue_message = true`, `isWorkerRunning` guarded, session fields (`name`, `cwd`, `selected_profile_model`, `is_auto_retry_until_stop`) read from the `sessions` row — the exact shape of `start_agent.zig` step 4 / `wakeSessionForCompletion` (fact #9).
- Order: DB → row rewrite → emit (never the reverse, §1.4).

**Tests:** static-contract (route registered after the siblings; the emit happens **after** `updateToolResultById` in source order — a grep-able ordering contract); the `isWorkerRunning` guard means a second answer does not start a second run.

### 5.7 T7 — The abandon guard
`src/http_handlers/session_create.zig` before line 258: pending → `markAbandonedForSession` + rewrite that tool-result row with the `abandoned` envelope → continue with the normal emit.

**Tests:** static-contract (the guard precedes `emit_run_agent`); in-memory test that `markAbandonedForSession` + rewrite produces a row whose content contains `<status>abandoned</status>`.

### 5.8 T8 — Frontend
- `api/index.ts`: `answerQuestion()`; `ask_user` in `DEFAULT_CHAT_TOOLS`.
- `AskUser.vue`: chrome from `_shared/ToolCardHeader.vue` (`toolName="ask_user"`, `:primary="header"`, `:running="status==='pending'"` for the yellow badge — set by the card itself, fact #16), body per §2, theme tokens only. Parse its three inputs: `content` (`<data>`), `parameters` (args), and derive the state from `<status>`.
- `ChatView.vue`: one `v-else-if` branch before the `mcp_*`/`ProgressiveTool`/fallback region (`:4382-4420`), passing `:content="innerToolData(msg)"`, `:parameters="getParametersForMessage(msg)"`, `:session-id`, `:expanded`.
- Vitest: every state; keyboard `1`/`Enter`/`Esc`; the exact POST body; multi-select array serialization; free-text-disallowed hides the textarea; an unknown `<status>` degrades to a plain completed card rather than throwing.

### 5.9 T9 — Docs + optional kanban dot
`docs/agent-tools.md`: `## ask_user` in the existing format, with the **SSE event** line reading *"none — the card renders from the standard `llm_full` tool-result row (`tool_name='ask_user'`); the answer rewrites that same row in place."*

Optional: extend `WorkspaceItemTaskCard.vue:429,448` so `awaiting_user` paints the orange "awaiting review" dot (fact #6 says this is a display-only, zero-risk change). Reviewer call — see §10.

---

## 6. Non-goals (explicit)

1. **Answering from the composer.** The answer goes through the card; typing a message instead is the `abandoned` path, not an answer (§1.6).
2. **Questions from sub-agents.** Stripped; a sub-agent has no answer surface (§1.7).
3. **Several simultaneous questions per session.** The break stops the run at the first batch containing a question, and the tool description tells the model to ask alone. If a model asks twice in one batch, both rows are written and both cards render; the resume run happens on the first answer, and the second question's card then becomes `abandoned` by the §1.6 guard if the user keeps going. Documented, not engineered around.
4. **Routine / scheduled-run questions.** Unattended runs return `unavailable` (§1.7).
5. **Attachments/images in an answer.** Options + free text only.
6. **A TUI/CLI answer surface.** Out of scope — but verify the TUI path never equips `ask_user` (§1.8 reasoning + §7 item 9).
7. **Rich option metadata** (per-option descriptions, multi-page questions). Flat strings only.
8. **Auto-resuming a question that was never answered.** Nothing resumes on its own; the resume is always triggered by a human action (answer, or the next message via `abandoned`).
9. **Timeouts / expiry / nagging reminders.** Deliberately absent (§1.1).

---

## 7. Traps & risks (each has a test)

1. **The `pending` envelope reaching the model.** If any run starts while a question is pending and unanswered, the model sees `<status>pending</status>` and may guess. Three guards: the unconditional break (no queue guard), the `session_create` abandon rule, and the iteration-top break. *Test:* §5.5 tests + the §8.4 harness case that seeds a pending row and asserts a new message resolves it to `abandoned` before any run.
2. **Ordering bug in the answer endpoint** (emit before rewrite) → the resume run reads `pending`. *Test:* the source-order grep contract in §5.6.
3. **Empty-slice-binds-as-NULL** → `answer` NULL-able + `COALESCE` + T2 test 1 + a harness assertion. *(Migration 079.)*
4. **Route-order shadowing** → registration after the siblings + comment + a harness test hitting the path and asserting its distinctive JSON keys. *(PR #291 / `/knowledge/reorder` class.)*
5. **Sub-agent hazard** → `MAIN_AGENT_ONLY_NAMES` in all 4 sites + static-contract tests + the runtime `unavailable` fallback.
6. **`DEFAULT_CHAT_TOOLS` miss** → the tool would be filtered out of every plain chat session and the feature would look broken with zero errors. T8 adds it; the harness asserts it stays equipped.
7. **`is_feed_to_llm` surprise** → placeholders are fed to the model (fact #3). Any new "temporary" content written into a tool row must be rewritten before the next run. *Test:* the harness asserts the row content is the `answered` envelope **before** the worker row appears.
8. **`finish_reason` drift** → a display-only value today (fact #6). Keep the enum variant so a future `switch` fails to compile rather than silently mis-handling (§1.3).
9. **TUI/CLI** → verify the TUI path never equips `ask_user` (§1.8). A TUI that equips it would end runs with a question nobody can answer.
10. **SSE-emit failure** → `onEventSendLLMHistory` errors must be caught and logged, never propagated: a failed card refresh must not roll back a valid answer or block the resume.
11. **`.vue` edits** — tracked `.vue` files are large; use the repo's python-patching approach for ChatView (minimal hunks, then `pnpm run build` + Vitest), not whole-file rewrites.
12. **No `// NEW (plan: …)` comments** — explain *why* in one sentence or not at all.

---

## 8. Test plan

### 8.1 Zig unit (colocated + migration)
Per task. Every tool file carries its own schema test (`update_plan.zig:412-434` precedent).

### 8.2 Zig integration (in-memory SQLite)
The row lifecycle: insert → `hasPendingQuestion` true → resolve → false; `abandoned` sweeps all pending rows for a session; UNIQUE idempotency.

### 8.3 Static-contract greps
`ask_user` in both registry lists / `DEFAULT_AGENT_TOOLS` / `MAIN_AGENT_ONLY_NAMES`; no hardcoded `"spawn_sub_agent"` literal in the 3 strip sites; the break exists in the `.tool_calls` arm **without** a queue guard; `updateToolResultById` precedes `emit_run_agent` in `ask_user_answer.zig`; the abandon guard precedes `emit_run_agent` in `session_create.zig`; the route is registered.

### 8.4 **Python functional harness — mandatory** (`tests/functional/ask_user_test.py`)

This design is **fully testable end-to-end without an LLM**, which the blocking design was not: seed the two rows with sqlite3, POST the exact body `AskUser.vue` sends, and assert both the row rewrite and the resume.

```python
def _seed_question(harness, sid, tool_call_id="call_abc", options=("staging", "production")):
    """Insert the assistant tool_calls row + its tool-result row + the pending row,
    exactly as handle_tool Phase 1/3 would, then return the question id."""
    # args_json = {"header": ..., "question": ..., "options": [...], "allow_free_text": true}
    # tool row content = <tool><name>ask_user</name><parameters>{args}</parameters>
    #                    <success>true</success><data><ask_user><status>pending</status>…</data></tool>


def test_answer_rewrites_the_tool_row_and_resumes_the_run(harness):
    sid = _create_session(harness)
    qid, row_id = _seed_question(harness, sid)

    r = harness.http("POST", f"/api/llm/session/{sid}/answer",
                     json_body={"question_id": qid, "answer": "staging"}, expect=200)
    assert r.json()["status"] == "answered"

    # 1. the question row resolved
    assert _question(harness, qid)["status"] == "answered"
    # 2. the tool-result ROW was rewritten in place (same row id) — the model's view
    row = _llm_row(harness, row_id)
    assert "<status>answered</status>" in row["response_content"]
    assert "<answer>staging</answer>" in row["response_content"]
    # 3. a run was started (resume) — observable as a worker row, no LLM involved
    assert _has_worker(harness, sid)
    # 4. the rewrite landed BEFORE the resume (trap #7)
    assert _worker_created_at(harness, sid) >= _row_updated_at(harness, row_id)


def test_double_answer_is_idempotent(harness):
    """Second POST → 200 already-resolved, and exactly one resume attempt."""
    ...


def test_empty_answer_rejected(harness): ...
def test_answer_not_in_options_when_free_text_disallowed(harness): ...
def test_answer_for_another_session_is_forbidden(harness): ...
def test_skip_marks_skipped_and_still_resumes(harness): ...
def test_new_user_message_resolves_pending_as_abandoned(harness):
    """POST /api/llm/session with a queue_message while a question is pending →
    the tool row becomes <status>abandoned</status> and the run proceeds."""
    ...
def test_answer_route_not_shadowed_by_sibling_param_routes(harness):
    """The route-order regression guard."""
    ...
```

### 8.5 What is deliberately NOT done
No `nohup ./zig-out/bin/nalar --port 8080` + `curl`. No port 8081. The harness owns the binary lifecycle and the tmpdir teardown.

---

## 9. Rollout

Single PR, no feature flag: the tool is inert until the model calls it, and the two gates (§1.7) prevent unattended questions. Merge order T1–T2 (invisible) → T3–T5 (tool live; a call ends the run and writes a row) → T6–T7 (the answer path) → T8 (UI — until this lands the card renders via the generic tool fallback, which is acceptable but ugly) → T9 (docs). Each task is independently green.

---

## 10. Reviewer decisions (locked 2026-09-16)

| # | Question | Answer |
|---|---|---|
| 1 | Ephemeral or persistent question? | **Persistent.** The design goes further than the original answer: there is no in-memory wait at all, so persistence is free rather than engineered. |
| 2 | Does `ask_user` end the turn? | **Yes — the loop breaks.** `finish_reason = tool_calls` on the LLM turn, then the workflow breaks and persists `awaiting_user`. No timeout, no parked thread. |
| 3 | Answer as a `user` bubble too? | **Inside the card only.** |
| 4 | `skipped` vs Stop? | **Run continues**; the model must not guess. (There is no Stop-mid-question state any more — nothing is running.) |
| 5 | Which modes get the tool? | **All modes by default** — chat + agent + kanban. |

Carried forward as implementation-time notes, not blockers:

- **TUI/CLI** — verify the TUI never equips `ask_user` (§7 item 9). It is seeded through `DEFAULT_AGENT_TOOLS`, which only the agent/kanban item-creation flows call, so the expectation is "unaffected" — verify, do not assume.
- **Kanban dot (T9, optional)** — `awaiting_user` currently paints no icon on a kanban task card (fact #6). Extending the `=== 'stop'` conditions to also accept `awaiting_user` is a 2-line display change; **not** in scope unless asked.
- **Card placement** — inline in the transcript. A sticky banner above the composer is **not** being built.

---

## 11. Implementation notes — where the code deviates from this plan

Written after implementing T1–T9, so the spec matches what actually shipped. Each deviation was forced by something the plan assumed wrongly.

### 11.1 The question's shape travels in the envelope, not in the tool row's arguments

§1.2 and §5.7 assumed the card could render the question from `getParametersForMessage(msg)`. **It cannot.** `handle_tool`'s Phase 1 builds the placeholder content with `wrapToolOutput`, which runs the raw arguments through `jsonArgsToXml` (`tools_wrap_output.zig:113`) — so the `<parameters>` block is *XML*, not parseable JSON — and the tool row carries no `tool_calls_json` (that field lives on the assistant row).

So `buildAskUserXml` emits the whole question (`header`, `question`, `options`, `allow_free_text`, `multi_select`, `recommended`) in the envelope itself. The card parses that, which has the side benefit the plan wanted anyway: the pending state renders identically live and after a page reload, from one source.

### 11.2 Migration 088 gained one column: `multi_select`

§4 deliberately avoided storing question-shape columns. That was right for everything except `multi_select`: without it the answer endpoint cannot reject a scalar answer to a multi-select question at the wire boundary, and the only alternative was reverse-parsing the XML `<parameters>` blob. One boolean column is the cheaper, more honest option. `answer` stays NULL-able (Migration 079's empty-slice-as-NULL trap) and is `COALESCE`d on read.

### 11.3 `resolveQuestion` must own its strings

The first implementation returned slices of the `PendingQuestion` row it had just freed, so an idempotent answer replied with **0xAA undefined bytes** (`[170, 170, …]` in the JSON). `AnswerOutcome` now dupes `status`/`answer` and the caller `deinit`s them. Worth keeping in mind for any future helper that reads a row and returns part of it.

### 11.4 One new default tool means four test files

`DEFAULT_AGENT_TOOLS` is mirrored in **four** functional tests, not one:

| File | Shape |
|---|---|
| `agent_tools_defaults_test.py` | `EXPECTED_DEFAULTS` / `EXPECTED_KANBAN_DEFAULTS` |
| `agent_tools_toggle_test.py` | `EXPECTED_DEFAULTS` |
| `command_tool_test.py` | `_DEFAULTS` ×2 + `_DEFAULTS_MINUS_COMMAND` |
| `agent_kanbans_test.py` | an inline list inside the bundle assertion |

All four are updated. This is the same "two lists to maintain" hazard §0 flags for the registry — it just lives in the tests instead.

### 11.5 The functional test must NOT create its session with `POST /api/llm/session`

`POST /api/llm/session` starts an agent run. A live run's DB transaction then hides this test's externally-seeded rows from the app, and every seeded question looks missing (404). `ask_user_test.py` therefore uses `PUT /api/llm/session/:id` (which auto-creates via `ensureSessionExists`) — exactly why `session_human_touched_at_test._create_session_via_update` exists and documents the same thing.

Related: the test helper's source-read cap had to grow. `src/migrations/migration.zig` is a single file that grows with every migration and crossed 256 KiB, which surfaced as a *bogus* "Migration 043 is missing" failure rather than an I/O error (readFileAlloc returns `StreamTooLong`). I raised it to 1 MiB; by the time this branch was rebased, `main` had landed the same fix at 512 KiB, so the rebase dropped mine and kept theirs.

### 11.6 `awaiting_user` is persisted on the session, not on the assistant row

§1.3 said "persist the assistant row with `finish_reason = awaiting_user`". The code instead leaves the assistant row at `tool_calls` — that IS what the LLM returned, and the frontend's TOOLS-pill logic keys off it (`ChatView.vue:1693`) — and writes `awaiting_user` to `sessions.last_finish_reason` via the existing `updateSessionLastFinishReason`. The authoritative "this session is waiting on you" signal is the `session_pending_question` row itself, which `GET`-able state makes explicit.

### 11.7 The `GET …/pending_questions` endpoint was dropped

§5.5 planned a rehydration endpoint. Nothing needs it: the card reads the question out of the tool-result row (11.1), and history already returns that row. `listRecentQuestions` remains in `ask_user_pending.zig` because the `session_create` abandon guard uses it.
