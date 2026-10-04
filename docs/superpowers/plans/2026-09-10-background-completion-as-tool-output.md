# Plan: Background `command` completion as XML tool card (role stays `user`)

Date: 2026-09-10 (v2 per user feedback: prose `"""""` envelope replaced by
`<background_command>` XML; role stays `user`, no migration, no drain change)
Task: `task_1789041520441_3` — "command background better tool output"
Status: planning only — no code changed in this plan.
Prior work: `docs/superpowers/plans/2026-09-09-background-command-completion-queue.md` (notify-then-delete into `session_queue_messages` + wake idle worker).

## 1. Problem (what the screenshot shows)

Background `command` completion currently renders as a dark-blue **user chat bubble**:

> This is an output from background command (pid 2781610, command `timeout 15 bash -c 'echo background test start; sleep 2; ...'`):
> `"""""` … stdout … `"""""`

Two defects, exactly as the user reports:

1. **Frontend treats it as user chat.** The completion is inserted via `insertQueueMessage` (`src/schedulers/cleanup_stale_background_process.zig:234-243`), and `session_queue_messages` has **no role column** — only `(id, session_id, message, image_url)` (`src/ai_workflow/tui/agentic_loop/insert_queue_message.zig:37-41`). At drain, `workflow.zig:792-884` inserts every queued row as `role="user", is_input=true, is_feed_to_llm=true` (`workflow.zig:826-874`) and deletes the queue row. Downstream it is indistinguishable from a typed user message. `ChatView.vue:3141-3148` renders `role=user` as the blue bubble (`--color-blue-1`, `max-w-[90%]`, right-aligned); the `v-if="group.role==='user'"` branch (`3152-3197`) prints raw text via `escapeHtml` — so the `"""""`/pid text renders literally inside the bubble.
2. **Backend envelope is not tool XML.** `buildCompletionMessage` (`src/ai_workflow/tui/agentic_loop/background_process.zig:336-362`) builds plain prose + 5×`"` fence (test vector at `:370` proves 5 quotes, not 3). It does **not** reuse `shell.result_to_xml` (`src/modules/agent/tools/shell.zig:802-834`, 9-tag `<command>/<stdout>/<stderr>/<exit_code>/<truncated>/<timeout>/<stdout_lines>/<stderr_lines>/<is_self>`) nor the outer `wrapToolOutput` `<tool><name>…<data>…` envelope (`src/ai_workflow/tui/agentic_loop/tools_wrap_output.zig:30-52`). Frontend `toolOutputParser.ts:304-365` (`parseCommand/parseShell`) and `unwrapToolOutput.ts:62-65` (only accepts `<tool>…</tool>`, else `MalformedToolEnvelope` → raw fallback) therefore cannot parse it. There is zero frontend handling of the `"""` envelope today (search `"""|pid \d+` in `src/apps/desktop/src` → no hits except `BackgroundCommandsPopup.spec.ts:158` for the popup dialog, not chat).

Goal: completion row stays `role="user"` in backend/DB/LLM (no migration, no drain change), but the chat renders it through the **existing tool card path** — `ShellTool.vue:1-78` (canonical shell renderer) — instead of the blue user bubble. Content becomes the same 9-tag XML shape as foreground `command` (`shell.result_to_xml`) so the frontend parser works unchanged; only the *renderer selection* is special-cased. The LLM prompt path is intentionally untouched (still sees a `user` message, as today).

## 2. Evidence / code refs (all verified 2026-09-10)

| Layer | File:line | Fact |
|---|---|---|
| Envelope build | `background_process.zig:336-362` | `This is an output from background command (pid {d}, command \`{s}\`):\n"""""…` ; truncated variant + `formatTruncationSuffix` `:313-322`; tests `:366-397` |
| Queue insert | `cleanup_stale_background_process.zig:170-254` (`notifySingleBackgroundCompletion`), esp `:216-223` build + `:234-243` `insertQueueMessage({session_id, message, image_url="", event_bus, is_emit_sse=true})` | reuses `queue_queued` SSE, no new event; `wakeSessionForCompletion` `:264+` uses `emit_run_agent` with `skip_initial_queue_message=true` |
| Queue schema | `insert_queue_message.zig:37-41` `INSERT INTO session_queue_messages (id, session_id, message, image_url)`; schema Mig 007+060+068/054 (`migration.zig:278,579,1138`) | **no `role`/`tool_name`/`tool_call_id` columns** |
| Queue drain → role | `workflow.zig:792-884`, esp `:826-874` `insertLLMHistories({response_content=queued.message, role=user, is_input=true, …})` + `:876-883` `deleteQueuedMessage` | completion becomes `role=user` row |
| Foreground XML | `command.zig:88-90` → `shell.result_to_xml` (`shell.zig:802-834`); outer `tools_wrap_output.zig:30-52` | 9-tag inner + `<tool><name><parameters><success><data>` outer; inner `data` NOT escaped, name/params/error ARE |
| Tool-row precedent | `handle_tool.zig:516-550` insert placeholder `role=tool, tool_call_id, tool_name, is_output=true` + `:678-724` `updateAndSendToolResult` in-place UPDATE + `:745` SSE | the pattern to mirror for async completion |
| DB→LLM | `get_llm_histories.zig:27-118` (27-col SELECT, `COALESCE(role,'assistant')`, `is_feed_to_llm=1`); `parsing.zig:9-27` tool→`AgentMessage{role=.tool, content=stripToolEnvelope, tool_call_id}`; per-style wire `Agent.zig:1404-1417` (Anthropic), `:1886-1926` (Responses skips empty `call_id`), `:1618` (OpenAI chat) | `role=tool` rows already flow correctly to all three `url_style`s |
| DB→frontend | `session_messages_get.zig:108-124` verbatim `role/content/tool_name/tool_call_id/tool_calls_json` (+`sanitizeUtf8`); live SSE `sse_on_event_send_llm_history.zig`, `on_event_sent.zig:270-289` | frontend dispatcher keys on `role=tool` + `tool_name` |
| Frontend user bubble | `ChatView.vue:3114,3133,3141-3148,3159-3166,3195`, `renderResponse.ts:68-122` (`user`→`escapeHtml` box; `assistant`→de-bubbled markdown; `tool`→transparent `tool-sequence` cards `:3202-3208`) | role alone decides bubble vs card |
| Frontend tool path | `ChatView.vue:3201-3444` dispatcher; `ShellTool.vue:1-78`; `tool_outputs/_shared/toolOutputParser.ts:304-365`; `helpers/unwrapToolOutput` (`:1227-1231`) | `tool_name=command` + inner 9-tag XML renders today with no changes |
| Pending-queue preview | `FileInput.vue:643-688` (`Queued N` pill + dropdown `{{msg.message}}`); `ChatView.vue:366,2581-2592,2726,3663` | queued rows also surface pre-drain; must not show raw XML there |
| No async-tool precedent | — | **no `role=tool` re-injection exists**; background completion is the first |

## 3. Goals / non-goals

Goals:
- Backend unchanged in role: completion still drains as `role="user"` (`workflow.zig:826-874` untouched) — **no migration, no new queue columns, no `tool_call_id` pairing problem**.
- Content becomes tool-style XML (same 9-tag `shell.result_to_xml` shape as foreground `command`) so one parser serves both paths.
- Chat renders a tool card (`ShellTool.vue`), never the blue user bubble — both for the drained message and the pending-queue preview — via a frontend-only detector.
- Backward compatible: old `"""""` prose rows keep rendering as today (detector falls back to the bubble when content isn't the new XML shape).

Non-goals:
- No new SSE event names (reuse `queue_queued` / `queue_deleted` + existing `llm_history` full-event; see SSE pair rule — `additionalEventTypes` + dispatch chain in `api/index.ts:3311,3407` stay untouched).
- No change to the cron cadence, log-cap, truncation suffix, or wake-idle-worker logic.
- No new tool card component; no change to `BackgroundCommandsPopup.vue` polling (`LIST_POLL_MS=5000`, `LOG_POLL_MS=2000`).
- No prompt-rule change (no new `MemoryToolRule`-style text).

## 4. Design

### 4.1 New envelope builder (backend, pure fn + unit tests) — role stays `user`

In `background_process.zig`, alongside `buildCompletionMessage`:

- New `buildCompletionUserXml(allocator, pid, command, log_content, exit_code_or_null, was_truncated, total_bytes, log_path) ![]u8`. Same inputs as today, different serialization:
  - Root tag MUST be distinct from foreground `<command>` so the frontend detector never fires on a user pasting foreground XML: `<background_command pid="{d}" exit_code="{d|unknown}" truncated="{true|false}">` containing the same field set as `shell.result_to_xml` (`<command>`, `<stdout>`, `<stderr>`, `<exit_code>`, `<truncated>`, `<timeout>`, `<stdout_lines>`, `<stderr_lines>`), reusing `xmlEscape` + NUL→U+FFFD. `stderr` stays empty (logger merges streams — do NOT invent a split). Keep the one-line human header (`This is an output from background command (pid …, command \`…\`):`) ABOVE the XML block so old frontends / old rows still read sensibly.
  - Do NOT use the outer `wrapToolOutput` `<tool>` envelope — that envelope is the `role=tool` contract (`unwrapToolOutput.ts:62-65` only accepts `<tool>…</tool>` for tool rows). A `<tool>` block inside a `role=user` row would be a lie to every future parser. The new root tag is the user-role equivalent.
- Keep `buildCompletionMessage` until the cron switches over, then replace its call site (no deprecation window needed — same role, same table, only content shape changes; old prose rows are handled by detector fallback in §4.3).
- Inline unit tests (mirror `:366-397` style): happy path has `<background_command pid=…>` + `<stdout>` + `<exit_code>`; truncation suffix inside `<stdout>`; empty log → `(empty output)`; FileNotFound marker; `]]>`/`<` in log escaped; header line preserved.

### 4.2 Queue + drain: NO CHANGE (deliberate)

- `insert_queue_message.zig`, `get_queue_message.zig`, `llm_history.zig:3040-3070`: untouched. No migration, no new columns.
- `notifySingleBackgroundCompletion` (`cleanup_stale_background_process.zig:216-243`): only change is calling `buildCompletionUserXml` instead of `buildCompletionMessage`. Same `insertQueueMessage({session_id, message=xml, image_url="", is_emit_sse=true})`, same `queue_queued` SSE, same `wakeSessionForCompletion` (`skip_initial_queue_message=true`).
- `workflow.zig:792-884` drain: untouched — completion still inserts as `role="user", is_input=true` (`:826-874`). No `tool_call_id` problem exists because we create none.

### 4.3 Frontend: `role=user` row renders as a tool card (the actual fix)

This is the only visual change. New helper `src/apps/desktop/src/helpers/isBackgroundCommandOutput.ts`:

- `parseBackgroundCommandOutput(content: string): { pid, command, stdout, stderr, exit_code, truncated } | null` — strict: trims, requires the `<background_command …>` root tag (regex or DOMParser, NOT a loose `includes("<command>")`), extracts fields with the same unescape rules as `toolOutputParser.ts:304-365`. Returns `null` for old `"""""` prose rows and for ordinary user text (including a user pasting foreground `<command>` XML — wrong root tag → null → bubble, correct).
- `isBackgroundCommandOutput(content): boolean` thin wrapper for templates.

`ChatView.vue` user branch (`3152-3197`, the `v-for="userMsg in group.messages"` loop at `3159-3166`):
- Per message: `v-if="isBackgroundCommandOutput(userMsg.content)"` → render `<ShellTool :tool-name="'command'" :content="toShellXml(userMsg.content)" />` (small adapter maps `<background_command>` fields to the 9-tag shape `parseShell` already expects — or reuse `parseShell` directly if the inner field names are kept identical, preferred) inside a transparent wrapper (same `.tool-sequence/.tool-item` classes as `:3202-3208`, NOT the blue bubble div).
- `v-else` → existing `<span>{{userMsg.content}}</span>` bubble path unchanged.
- Bubble chrome (`3141-3148` blue `background-color`, `3133 max-w-[90%]`, `3114 flex-row-reverse`): gate on "group contains at least one non-background user message" so a group made only of completions doesn't get the blue box/right-align; mixed groups keep today's layout for the real user lines. `hasBubbleContent (:1378-1396)` + `:1054-1073` filter: treat background-completion user rows as card-renderable (like `role=tool`), not bubble content.
- `renderResponse.ts:113-115`: bypass `escapeHtml`-only path for these rows (the card component owns rendering).

**Pending-queue preview (`FileInput.vue:660-688`):** same detector on `msg.message` — completion rows show `Background command finished (pid …)` label (pid from parsed XML, fallback generic), never raw XML. Queued SSE shape unchanged (plain `message` string), so no `api/index.ts` type change.

- **No `toolOutputParser` / `unwrapToolOutput` changes** — they keep serving `role=tool` rows only; the new helper is the user-role counterpart.
- **No `BackgroundCommandsPopup.vue` change.**

### 4.4 Prompt / history (no change by design, per user intent)

Row stays `role=user` end to end: `get_llm_histories` → `transformLLMHistoryToAgentMessage` → all three wire styles, plus `session_messages_get.zig:108-124` verbatim pass-through. The LLM continues to see the completion as a user message exactly as today — only the *pixels* change. (Consequence acknowledged: the "user instruction" prompt-injection surface is unchanged; that is the user's explicit trade-off for keeping `role=user`.)

### 4.5 Backward compatibility

- Old rows (plain `"""""` prose, `role=user`): detector returns null → blue bubble exactly as today. No history rewrite, no migration.
- New XML rows on an old frontend (one-release skew): shown as raw text in the bubble — header line still readable, XML block visible but ugly. Acceptable; no crash (it's just `escapeHtml` text).
- Wire: queue SSE + `QueuedMessage` type unchanged (still plain `message` string).

## 5. Alternatives considered (and why not)

1. **Backend `role=tool` with queue migration (`role/tool_name/tool_call_id` columns + drain branch).** Fully designed in the previous revision of this plan — rejected per user's clarification: role must stay `user`. Kept as a fallback if the team later wants the LLM to see completions as tool output; the migration path is documented in git history of this file.
2. **Bypass the queue: insert any row directly from the cron.** Rejected: loses ordering with concurrent user messages and bypasses the wake-idle-worker drain protocol (`skip_initial_queue_message=true`).
3. **Loose frontend detection (`includes("<command>")` or the prose prefix).** Rejected: fires on users pasting foreground XML. The distinct `<background_command>` root tag makes detection exact.

## 6. Test plan (no live server — functional harness only)

Per repo rule: never `nohup pabrik --port …` + `curl`; boot an isolated binary per test via `tests/functional/harness.py` (free port 8080-8199 excl. 8081, tmpdir HOME, `$PABRIK_BIN`).

- **Zig unit (inline, same files):**
  - `background_process.zig`: new `buildCompletionUserXml` tests — happy path has `<background_command pid=…>` + `<command>/<stdout>/<exit_code>`; truncation marker inside `<stdout>`; empty log; FileNotFound marker; `<`/`&`/`]]>` in log escaped; header line preserved.
  - No migration tests (no migration).
- **Functional (extend `tests/functional/background_command_completion_test.py` or new `background_command_tool_output_test.py`, 2 tests):**
  1. Run a short background command to completion; fetch session messages; assert the completion row has `role=="user"` AND content parses as `<background_command>` with `<exit_code>0</exit_code>` — and does NOT contain the `"""""` fence.
  2. Legacy compat: an old prose `"""""` row still drains as `role=user` bubble text (no regression).
  3. (Frontend, vitest) new `isBackgroundCommandOutput.spec.ts`: new-XML → parsed fields; old prose → null; user-pasted foreground `<command>` XML → null; `ChatView` user-branch renders `ShellTool` card for parsed rows and bubble otherwise; `FileInput` preview shows pid label, not raw XML.
- **Full gates:** `zig build test --summary all` (expect 0 fail; baseline ~3155/3163 per 2026-09-09 entry), `pnpm test:unit` touched specs green, `zig build pabrik-desktop --summary all` green.

## 7. Rollout (implementation order for the follow-up task)

1. Backend envelope: `buildCompletionUserXml` + unit tests (`background_process.zig`, distinct `<background_command>` root, same field names as `shell.result_to_xml`).
2. Cron switch: `notifySingleBackgroundCompletion` calls the new builder (content-only change; queue/drain/SSE untouched).
3. Frontend helper `isBackgroundCommandOutput.ts` + spec.
4. `ChatView.vue` user-branch card rendering + bubble-chrome gating + `FileInput.vue` preview label + vitest.
5. Functional harness tests (assert `role==user` + XML parses + no `"""""`).
6. Full gates + `PABRIK.md` changelog link.

## 8. Risks / open questions

- **LLM still sees `role=user`** — the prompt-injection surface ("This is an output…" as a user instruction) is unchanged by design, per your call. If that later proves to be a problem, the fallback is the `role=tool` migration sketched in §5.1.
- **User pasting a fake `<background_command>` block** would render as a card — accepted (same class of spoof as pasting any markup; strict root-tag + field parsing limits it to deliberate crafting).
- **`stderr` is empty by construction** (logger merges streams).
- **`success` flag semantics:** propose `success=true` whenever the completion was delivered (even on nonzero exit), with the exit code carrying failure — matches "tool ran, command failed" vs "tool itself errored" convention in `wrapToolOutput`. Confirm in review; flipping to `success=(exit==0)` is a one-line change with test updates.
- **Two completions racing one drain iteration:** both insert as separate `role=tool` rows in queue order — same as two user messages today; no dedup needed.
