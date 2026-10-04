# Plan — `functional_test_ui/chatview_ui_test.py` — DB-seeded Playwright coverage

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-20
**Task:** `task_1787259118173_0` (the broader "add functional_test_ui" task — this plan is a chunk of it)
**User's spec (verbatim):** *"i want you test functional test ui, chatview, because this test will not using a llm to generate test, instead we just insert the isolated db for chat history, the test is example doing ai chat agent , llm tool call output etc, write a plan to do that functional test ui"*
**Branch / worktree:** Continues on the same branch as the rest of `functional_test_ui` — `worktree/functional-test-ui` (or whatever branch the parent PR is on). Per the project rule, work in a git worktree and open a PR for review.

**Goal:** Add a chatview UI test suite that **does not call a real LLM**. Instead, each test opens a Python `sqlite3` connection against the harness's isolated `agent.db`, INSERTs pre-shaped `sessions` + `llm_history` rows that simulate a real conversation (user prompts, assistant replies, tool-call + tool-result pairs, reasoning traces, image attachments, compaction cards, etc.), then drives a headless Chromium browser at `/app/chat/<session_id>` and verifies each scenario renders correctly.

**Architecture:**

- New helper module `tests/functional_ui/chatview_fixtures.py` exposes pure DB-seed functions (`seed_session`, `seed_user_message`, `seed_assistant_message`, `seed_tool_call`, `seed_tool_result`, `seed_image_user_message`, `seed_compaction_user_message`, `seed_reasoning_message`). All accept a `sqlite3.Connection` and a `session_id`; each returns the inserted `llm_history.id` so tests can wire assertions.

- New test file `tests/functional_ui/chatview_ui_test.py` (≈10 tests) uses the existing `ui_harness` + `page` fixtures from `tests/functional_ui/conftest.py` and the new `chatview_fixtures.py` helpers.

- DB access path: `temp_dir / ".config" / "pabrik" / "agent.db"` (the harness already creates this on boot via `FunctionalHarness.boot()`). Tests open it with stdlib `sqlite3`, INSERT, commit, close — then navigate the browser.

- **Why DB-seed instead of HTTP-seed?** The chatview's `GET /api/llm/session/<id>/messages` reads from `llm_history` exactly the way a real agent would write to it. DB-seeding is:
  1. **Honest** — it tests the *exact* wire shape the production agent emits, including edge cases the LLM never produces (e.g. malformed tool_calls_json, very long reasoning, empty content rows).
  2. **Fast** — `sqlite3` INSERTs are O(ms); HTTP round-trips to `messages` endpoint are O(ms); no agent loop warm-up.
  3. **Reproducible** — no LLM non-determinism.
  4. **Cheap** — no API-key quota burned.

  HTTP-seeding would force us to drive the agent loop (which requires a real or stubbed LLM, a profile, an SSE channel, and ≥3s of warm-up per test). DB-seeding skips all of that and tests the **render path** — which is the layer UI bugs live in.

**Tech Stack:** Python 3.9 stdlib `sqlite3`, existing `tests/functional_ui/ui_harness.py` (composition over `FunctionalHarness`), existing `tests/functional_ui/conftest.py` (`ui_harness`, `page`, `browser` fixtures), Playwright Python sync API.

---

## 1. Context — what exists today

### The existing UI suite (parent of this plan)

- `tests/functional_ui/ui_harness.py` boots pabrik + Vite via `UIHarness.boot(pabrik_bin)`.
- `tests/functional_ui/conftest.py` provides `ui_harness` (function-scoped) + `browser` (session-scoped) + `page` (function-scoped) + `artifacts_dir` (function-scoped). Screenshots auto-captured to `tests/functional_ui/artifacts/<test>/<timestamp>.png` on failure.
- `tests/functional_ui/smoke_boot_test.py` (5 tests, pass) and `kanban_lifecycle_ui_test.py` (4 tests, pass) are the existing patterns this plan extends.
- Isolation: ALL `rmtree` goes through `FunctionalHarness.teardown` (parent of `UIHarness`). The harness's `is_safe_tmp` validates the tempdir before rmtree; this plan does NOT add any new rmtree path.

### The chatview's data shape (what we seed)

`llm_history` (key columns from `src/ai_workflow/tui/agentic_loop/llm_history_row.zig`):

| Column | Type | Required for test seed |
|---|---|---|
| `id` | TEXT PK | yes (use `msg_<uuid12>`) |
| `session_id` | TEXT | yes (links to `sessions.id`) |
| `model` | TEXT | yes (any model name string) |
| `created_at` | TEXT/DATETIME | yes (UTC ISO 8601) |
| `role` | TEXT | yes (`'user'`/`'assistant'`/`'tool'`/`'system'`) |
| `response_content` | TEXT | yes (`""` for non-content rows; `is_input=true` rows store user text here) |
| `finish_reason` | TEXT | yes (`""` default, `'stop'` / `'tool_calls'` for terminal rows) |
| `tool_calls_json` | TEXT | yes (`"[]"` default; JSON-encoded array for assistant tool-calling rows) |
| `is_input` | INTEGER (0/1) | yes (1 for user/system/tool-result rows) |
| `is_output` | INTEGER (0/1) | yes (1 for assistant rows) |
| `is_thinking` | INTEGER (0/1) | optional (1 when `reasoning_content` was streamed) |
| `reasoning_content` | TEXT NULL | optional |
| `tool_call_id` | TEXT NULL | required for `role='tool'` rows (links back to `tool_calls_json[i].id` in the parent assistant row) |
| `tool_name` | TEXT | required for `role='tool'` rows |
| `image_urls` | TEXT (Pipe-joined data URLs) | optional |
| `diffview_before` / `diffview_after` | TEXT NULL | optional (used by `TextReplace` fallback) |
| `agent` | TEXT (default `'Agent'`) | optional |
| `session_name` | TEXT (default `''`) | optional |
| `loop_index` | INTEGER (default 0) | optional |
| `parent_session_id` | TEXT NULL | optional |
| `parent_id` | TEXT NULL | optional |
| `temperature` | REAL (default 0.2) | optional |
| `prompt_tokens` / `completion_tokens` / `total_tokens` | INTEGER | optional |
| `cache_creation_input_tokens` / `cache_read_input_tokens` | INTEGER | optional (Anthropic-only) |
| `is_feed_to_llm` | INTEGER (default 1) | optional |

`tool_calls_json` JSON shape (OpenAI-compatible, double-encoded `arguments`):
```json
[{"id":"call_abc","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]
```

`sessions` (key columns — Migration 077):
- `id` TEXT PK (`sess_<unix>_<16hex>`)
- `name` TEXT
- `status` TEXT (`'active'`)
- `cwd` TEXT NULL
- `selected_profile_model` TEXT NULL
- `is_auto_retry_until_stop` TEXT DEFAULT '0'
- `user_id` TEXT NULL

For UI tests, we only need `id`, `name`, `status='active'`. The chatview's `onMounted` calls `api.getChatHistory(sid)` which only requires the session row + `llm_history` rows keyed to that session_id.

### ChatView render contract (from `src/apps/desktop/src/components/views/ChatView.vue`)

- Route: `/app/chat/:sessionId` (matches `src/apps/desktop/src/router/index.ts`).
- History fetch: `api.getChatHistory(sid, limit=1000)` → `GET /api/llm/session/:sessionId/messages`.
- `response_content` is the **rendered** field for user text (no separate `content` column). The Zig `LLMHistory.response_content` is what the frontend's `MessageBubble` shows via `{{ content }}` (the frontend re-projects it to `content` in `api/index.ts`).
- `messageGroups` is computed by grouping consecutive messages with the same `role`.
- User bubble layout: `flex-row-reverse` (avatar right). Assistant bubble: `flex-row` (avatar left).
- Tool messages render one card per message inside `.tool-sequence`, dispatched by `msg.tool_name` (ReadFile, WriteFile, Bash, Search, etc.). Fallback: collapsible `.tool-summary` button.
- Assistant messages with tool calls render `.tool-calls-summary` header (only when the *next* group is NOT a tool group).
- Markdown is rendered via `marked` + `v-html` into `.markdown-content`.
- Auto-scroll on push; "scroll to bottom" floating button when not at bottom.
- Streaming messages have `id: 'streaming-${Date.now()}'` (transient). Not relevant to DB-seeded tests — we never simulate streaming.

### Testids that exist on ChatView

- `chat-header-name-${chatId}` (header title span)
- `chat-header-close-${chatId}` (close ✕ button)
- `load-more-messages` (pagination button)
- `send-message-button` / `stop-session-button` (in `FileInput.vue`)
- `profile-picker-default` / `profile-picker-${name}` / `profile-picker-active-badge`
- `worktree-status-button`, `restore-preview-panel-button`

**No message-specific testids exist.** Tests must assert by:
- Text content: `page.locator("text=hello")`
- Class: `.markdown-content`, `.assistant-item`, `.chat-attached-image-img`, `.tool-sequence`, `.tool-summary`, `.tool-calls-summary`
- ARIA role: bubble rows have `role="button" tabindex="0"`

This is fine for UI tests — assertions on rendered content are the right level. We don't need testids.

### Why this is safe across macOS / Linux / Windows

- Python stdlib `sqlite3` ships everywhere (3.9+ — matches `.venv-func`'s Python 3.9.6).
- The DB path uses `pathlib.Path` (cross-platform separators).
- `is_safe_tmp()` already handles Windows path separators (the parent `functional/harness.py` fix landed in this PR).
- No `subprocess`, no `shutil.rmtree` from this plan — all cleanup goes through the harness's existing teardown.

---

## 2. Files to create / modify

### NEW: `tests/functional_ui/chatview_fixtures.py` (~180 lines)

Pure DB-seed helpers. Exposes one class `ChatviewSeed` with the methods listed above. Each method:
1. Opens (or reuses) a `sqlite3.Connection` to the harness's `temp_dir / ".config" / "pabrik" / "agent.db"`.
2. Runs the INSERT.
3. `commit()`s + closes (or leaves the connection open — see below).
4. Returns the inserted `llm_history.id` (string) so tests can assert on it.

Connection strategy: **one connection per test** (open at start of test, close in `finally`). Helpers accept `conn: sqlite3.Connection` as their first arg — they don't manage connection lifecycle themselves. This keeps them composable and easy to test.

Validation: at the top of every helper, assert the DB file path matches `is_safe_tmp()` + the `pabrik-func-` substring (defense in depth — should be impossible because the harness already validated the tempdir, but a regression here would let a test corrupt the real home, so we belt-and-suspenders it).

Method signatures:

```python
class ChatviewSeed:
    def __init__(self, db_path: Path): ...
    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]: ...  # validates is_safe_tmp
    def seed_session(self, conn, session_id: str, name: str = "Test Chat") -> str: ...
    def seed_user_message(self, conn, session_id: str, text: str,
                          image_urls: list[str] | None = None,
                          created_at: str | None = None) -> str: ...
    def seed_assistant_message(self, conn, session_id: str, text: str,
                               finish_reason: str = "stop",
                               tool_calls: list[dict] | None = None,
                               reasoning_content: str | None = None,
                               is_thinking: bool = False,
                               created_at: str | None = None) -> str: ...
    def seed_tool_result(self, conn, session_id: str, tool_call_id: str,
                         tool_name: str, content: str,
                         created_at: str | None = None) -> str: ...
    def seed_system_message(self, conn, session_id: str, text: str,
                            created_at: str | None = None) -> str: ...
    def seed_compaction_user_message(self, conn, session_id: str,
                                    envelope_json: str,
                                    created_at: str | None = None) -> str: ...
```

`created_at` defaults to `datetime.now(timezone.utc).isoformat()` if `None`.

### NEW: `tests/functional_ui/chatview_ui_test.py` (~280 lines, 10 tests)

Test file. Each test is function-scoped (gets a fresh harness + DB). Structure:

```python
def test_chatview_renders_empty_state(ui_harness, page):
    h = ui_harness
    session_id = "sess_chatview_empty_001"
    db = h.temp_dir / ".config" / "pabrik" / "agent.db"
    with ChatviewSeed(db).connect() as conn:
        ChatviewSeed(db).seed_session(conn, session_id, "Empty Chat")
    page.goto(h.web_url(f"/app/chat/{session_id}"))
    page.wait_for_selector(f'[data-testid="chat-header-name-{session_id}"]', timeout=10000)
    # Empty-state copy is "💬 How can I help you?" + "Start a conversation
    # by typing a message below" (ChatView.vue lines 2401/2407).
    assert page.locator("text=How can I help you?").count() > 0
```

Then 9 more scenarios (see §4).

### MODIFY: `tests/functional_ui/README.md`

Add a section "Chatview DB-seeded tests" explaining:
- The DB path (`temp_dir/.config/pabrik/agent.db`).
- How to add a new scenario (drop a row, navigate, assert).
- The list of 10 covered scenarios.

No code changes to `ui_harness.py` or `conftest.py` — they already provide everything we need.

---

## 3. Step-by-step

- [ ] **3.1** Create `tests/functional_ui/chatview_fixtures.py` with `ChatviewSeed` class.
- [ ] **3.2** Implement `seed_session` — INSERT into `sessions`, return `session_id`.
- [ ] **3.3** Implement `seed_user_message` — INSERT into `llm_history` with `role='user'`, `is_input=1`, `response_content=<text>`, optional `image_urls` (Pipe-joined data URLs).
- [ ] **3.4** Implement `seed_assistant_message` — INSERT with `role='assistant'`, `is_output=1`, `finish_reason` (default `'stop'`), optional `tool_calls` (list of dicts → JSON-encoded `tool_calls_json`), optional `reasoning_content` + `is_thinking=1`.
- [ ] **3.5** Implement `seed_tool_result` — INSERT with `role='tool'`, `is_input=1`, `tool_call_id`, `tool_name`, `response_content=<stdout/stderr>`. The caller is expected to have already seeded the parent assistant row that contains the matching `tool_calls_json[i].id`.
- [ ] **3.6** Implement `seed_system_message` — INSERT with `role='system'`, `is_input=1`. (For the rare case the user wants to seed an explicit system message — most tests won't use this.)
- [ ] **3.7** Implement `seed_compaction_user_message` — INSERT with `role='user'`, `is_input=1`, `response_content='<compact_messages>' + envelope_json`. The frontend's `<CompactionCard>` triggers when `content.startsWith('<compact_messages>')` (verified in `ChatView.vue`).
- [ ] **3.8** Add the `is_safe_tmp` belt-and-suspenders check inside `ChatviewSeed.__init__` (assert the DB path's parent is a safe tmpdir; raise `FunctionalHarnessError` if not).
- [ ] **3.9** Create `tests/functional_ui/chatview_ui_test.py` with helper `_open_chatview(page, h, session_id)` that navigates and waits for the `chat-header-name-${session_id}` testid.
- [ ] **3.10** Add `_wait_for_text(page, text, timeout=10s)` helper that waits for `text=<text>` to appear (Playwright's auto-waiting locator).
- [ ] **3.11** Implement **Test 1**: `test_chatview_renders_empty_state` — empty session, verify empty-state copy.
- [ ] **3.12** Implement **Test 2**: `test_chatview_renders_plain_user_assistant_exchange` — 2 messages, verify both render + the order (user right, assistant left).
- [ ] **3.13** Implement **Test 3**: `test_chatview_renders_multi_turn_conversation` — 8 messages alternating user/assistant, verify the conversation renders top-to-bottom in created_at order, with `messageGroups` correctly grouping consecutive same-role rows.
- [ ] **3.14** Implement **Test 4**: `test_chatview_renders_assistant_with_tool_calls` — assistant row with `tool_calls_json` containing a `bash` call. Verify `.tool-calls-summary` header appears + the tool-call id is visible.
- [ ] **3.15** Implement **Test 5**: `test_chatview_renders_tool_result_pair` — assistant row with `tool_calls_json=[{id: call_x, name: bash, ...}]` + matching `role='tool'` row with `tool_call_id='call_x'`, `tool_name='bash'`, `response_content=<stdout>`. Verify the `.tool-sequence` Bash card renders the stdout.
- [ ] **3.16** Implement **Test 6**: `test_chatview_renders_markdown_in_assistant_message` — assistant text containing `**bold**`, `# Heading`, `` `inline_code` ``, and a fenced code block. Verify `.markdown-content` contains the rendered `<strong>`, `<h1>`, `<code>`, `<pre><code>`.
- [ ] **3.17** Implement **Test 7**: `test_chatview_renders_user_message_with_images` — user row with `image_urls=<pipe-joined data URLs>` (use a tiny 1×1 PNG fixture). Verify `.chat-attached-image-img` thumbnails render with the right count.
- [ ] **3.18** Implement **Test 8**: `test_chatview_renders_reasoning_content` — assistant row with `is_thinking=1` + `reasoning_content=<long thinking trace>`. Verify the reasoning block appears (selector: `[data-thinking]` or `.reasoning-content` — confirm in `ChatView.vue` while implementing).
- [ ] **3.19** Implement **Test 9**: `test_chatview_renders_code_block_copy_buttons` — assistant text with a fenced `bash` code block. Verify at least one `[data-code-block-copy]` or similar copy button renders. (Selector may need adjustment based on `setupCodeBlockCopyButtons()` output.)
- [ ] **3.20** Implement **Test 10**: `test_chatview_renders_compaction_card` — user row with content starting `<compact_messages>{...envelope JSON...}`. Verify `.compaction-card` renders with the expected envelope summary.
- [ ] **3.21** Add `tests/functional_ui/README.md` "Chatview DB-seeded tests" section.
- [ ] **3.22** Run `pytest tests/functional_ui/chatview_ui_test.py -v` and confirm all 10 pass.
- [ ] **3.23** Run the full `pytest tests/functional_ui/ -v` and confirm no regressions vs. the 20 existing tests.
- [ ] **3.24** Run the parent `pytest tests/functional/harness_safety_test.py -v` and confirm 12/12 still pass.

---

## 4. Test scenarios (detail)

| # | Scenario | DB rows seeded | Browser assertion |
|---|---|---|---|
| 1 | Empty state | 1 sessions row | Empty-state placeholder visible |
| 2 | Plain exchange | session + user("hi") + assistant("hello!") | Both bubbles render; user right, assistant left |
| 3 | Multi-turn | session + 4×(user, assistant) pairs | All 8 messages visible in created_at order |
| 4 | Assistant with tool call | session + user + assistant(tool_calls=[bash]) | `.tool-calls-summary` header + tool-call id text |
| 5 | Tool call + result pair | session + user + assistant(tool_calls=[bash]) + tool(bash, stdout="hello") | `.tool-sequence` Bash card with stdout text |
| 6 | Markdown rendering | session + user + assistant(`# Heading\n**bold**\n\`code\`\n\`\`\`bash\nls\n\`\`\``) | `.markdown-content` has `<h1>`, `<strong>`, `<code>`, `<pre><code>` |
| 7 | User with images | session + user(text + 2 image URLs) | 2× `.chat-attached-image-thumb` rendered |
| 8 | Reasoning trace | session + user + assistant(reasoning_content="<50-char trace>", is_thinking=1) | Reasoning block visible |
| 9 | Code block copy button | session + user + assistant(`` ```bash\nls\n``` ``) | At least one copy button in the rendered code block |
| 10 | Compaction card | session + user(content="<compact_messages>{...envelope JSON...}") | `[data-testid="compaction-card"]` visible |

Each test pays ~3s setup (harness boot) + ~5-10s first-call Vite compile (the chatview navigates to a Vite-served page). Once the Vite dep cache is warm across the session (sequential tests share the harness in the same Vite process), tests 2-10 run in ~2-4s each. Total suite ≈ 30-60s.

---

## 5. Verification

- `pytest tests/functional_ui/chatview_ui_test.py -v` → 10 passed.
- `pytest tests/functional_ui/ -v` → 30 passed (20 existing + 10 new).
- `pytest tests/functional/harness_safety_test.py -v` → 12 passed (regression check on the parent's `is_safe_tmp` Windows fix).
- Verify isolation: after a full run, `ls $HOME` shows zero new `.config/pabrik/agent.db` or `pabrik-func-*` files. (The harness's `is_safe_tmp` guarantees this; the belt-and-suspenders check inside `ChatviewSeed.__init__` makes it explicit.)
- Cross-platform sanity: confirm `ChatviewSeed(db_path)` works on Windows by reading the validation logic — it should accept `C:\Users\<u>\AppData\Local\Temp\pabrik-func-...\agent.db` after the parent fix.

---

## 6. Pitfalls / known gotchas

- **Vite dep cache warm-up**: The first chatview test pays ~5-10s for monaco-editor's `optimizeDeps`. Subsequent tests in the same Vite process run much faster. We can NOT share the Vite process across tests in this plan (the harness is function-scoped per the existing fixture). If the suite ends up too slow, the follow-up is to make the harness session-scoped + use unique workspace IDs per test (mirrors the recommended optimization from the parent plan).

- **No message-specific testids**: ChatView doesn't add testids to message bubbles. We assert on text content + CSS class. If a test starts failing because the frontend renamed a class, the fix is one line in the test — the *content* the test cares about is unchanged.

- **Chatview doesn't render messages until `api.getChatHistory` returns**: We must `wait_for_selector` on the header testid (which appears synchronously after `onMounted`) AND wait for the actual message content separately (the messages render after the fetch resolves). Each test uses `_wait_for_text(page, <needle>)` to wait for the message body, not just the header.

- **`tool_calls_json` is double-encoded**: The `arguments` field is a JSON string INSIDE a JSON array. The OpenAI wire format. `json.dumps(json.dumps(...))` for the inner — `ChatviewSeed.seed_assistant_message` handles this internally; tests pass `tool_calls=[{"id": "call_x", "function": {"name": "bash", "arguments": {"command": "ls"}}}]` (as a Python dict) and the helper does the encoding.

- **`created_at` ordering matters**: The chatview reverses the API response (`messages.value = newMessages.slice().reverse()`) before rendering. Messages with later `created_at` appear at the BOTTOM. Tests must seed `created_at` in chronological order (Test 3 uses 30s apart increments).

- **Reasoning block selector**: As of this writing, `ChatView.vue` may render reasoning content inline or in a collapsible section. Confirm the selector during implementation; if it doesn't have a class, fall back to text-content assertion (`page.locator("text=<unique reasoning substring>")`).

- **Compaction card envelope shape**: The `<compact_messages>` JSON envelope has a specific structure (`{"summary": "...", "messages": [...]}`). Use a representative sample from the existing functional tests or the frontend's `useCompaction` composable. Document the shape in `chatview_fixtures.py` so future tests can reuse it.

- **Direct DB access bypasses the harness's HTTP layer**: If a future change moves the chatview's data source away from `llm_history` (e.g. to a separate `messages` table), these tests will silently start failing. The breakage is a feature, not a bug — it tells us the wire shape changed and the seed helper needs an update.

---

## 7. Out of scope (deferred follow-ups)

- **Session-scoped harness** for faster suite runs (would drop the chatview suite from ~30s to ~15s). Worth a separate PR — touches the existing `ui_harness` fixture scope, not this plan.
- **Auto-screenshot diffs** — capture baseline screenshots and detect regressions. The existing `artifacts/` dir already saves on failure; diffing against baselines is a separate feature.
- **Streaming messages** — DB-seeded tests can't simulate live SSE chunks. If we want streaming coverage, that's a separate test that drives a stub-LLM profile + waits on `llm_chunk` events. Out of scope here.
- **Cross-browser** (Firefox / WebKit) — Chromium only for now.