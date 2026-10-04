# LLM History Inspector in Settings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Git worktree:** All implementation MUST happen on a dedicated worktree (e.g. `worktree/llm-history-inspector`). Never commit directly to `main`. See § Worktree Setup.

## Goal

Add an **LLM History** inspector inside **Settings** (new sidebar tab) that lets the user:

1. Pick any `session_id` (searchable dropdown, defaults to the most-recent session).
2. See the **full chain of LLM request messages** for that session — from the system prompt through every user / assistant / tool turn up to the last message — exactly as the app builds it before calling the provider.
3. Copy a ready-to-run **`curl` command for each of the 3 provider wire formats** the app supports:
   - `anthropic` → `POST /v1/messages` (Anthropic Messages API)
   - `openai` → `POST /v1/chat/completions` (OpenAI Chat Completions)
   - `openai-response` → `POST /v1/responses` (OpenAI Responses API)
4. Understand **how this app builds the chain** — the inspector is a debug/learning tool, not just a log viewer.

No secrets are leaked: `api_key` is redacted to `sk-...****` in every curl preview.

---

## Worktree Setup

```bash
# From repo root — create and bind the worktree (one-time)
git worktree add worktree/llm-history-inspector -b worktree/llm-history-inspector
# All subsequent bash/read_file/write_file/glob/search operate on the worktree
# via the session's cwd binding (set_git_worktree tool). Verify with:
git -C worktree/llm-history-inspector status
```

Every commit lands on `worktree/llm-history-inspector`. Open a PR from that branch when done. Do NOT push to `main` directly.

---

## Architecture

```
SettingsView.vue (sidebar: Pabrik | Skills | Memories | [NEW] LLM History)
        │
        └── LlmHistorySettings.vue  (new)
                ├── SessionPicker  (searchable, paginated GET /api/sessions)
                ├── ChainViewer    (GET /api/llm/history/:session_id → AgentMessage[])
                └── CurlTabs       (anthropic | openai | openai-response)
                        └── Copy button per tab (navigator.clipboard.writeText)

Backend
  GET /api/llm/history/:session_id
        │
        ├── llm_history.getMessages(allocator, db, session_id)  // existing
        ├── prompts_build_messages_for_agent_prompt (system prompt assembly)
        │       └── transform_llm_history_to_agent_message  // existing
        └── Agent.buildJson*Request  (reuse, no network call)
                ├── buildJsonAnthropicRequest  → body + curl
                ├── buildJsonOpenAIRequest     → body + curl
                └── buildJsonResponsesRequest  → body + curl
```

Key decision: **reuse the existing `Agent.buildJson*Request` builders verbatim — zero duplication.** The endpoint MUST call the same Zig methods the real `Agent.callStreaming` calls, so the preview curl is byte-for-byte identical to what the app actually sends. Do NOT re-implement JSON serialization, do NOT hand-build request bodies, do NOT copy-paste builder logic into the handler.

```
Real path:   workflow → Agent{model, baseUrl, UrlStyle, thinkingEnabled, reasoningEffort, temperature, maxTokens}
                      → buildJsonAnthropicRequest / buildJsonOpenAIRequest / buildJsonResponsesRequest
                      → json_body → HTTP POST

Inspector:   handler → Agent{ same fields from resolved LlmProfile }  // ephemeral, no Client needed
                      → buildJsonAnthropicRequest / buildJsonOpenAIRequest / buildJsonResponsesRequest  // SAME methods
                      → json_body → curl string (shell-escaped) + pretty JSON
```

The handler constructs 3 ephemeral `Agent` instances (one per `UrlStyle`) with the session's resolved profile (`model`, `base_url`, `thinking`, `reasoning_effort`, `temperature`, `max_tokens`) and calls each builder with `AgentCall{messages: chain, tools, temperature, max_tokens}` and `stream=false`. The returned `[]u8` body is used directly for both the `bodies` field and the `curl -d '<body>'` string (single-quote shell escaping via `'\''`). Curl is then `curl -X POST '<baseUrl><endpoint>' -H 'Authorization: Bearer sk-...****' -H 'Content-Type: application/json' -d '<body>'` where endpoint is `/v1/messages` / `/v1/chat/completions` / `/v1/responses`.

This guarantees: if `Agent.zig` changes its serialization (e.g. new `reasoning` field, new `thinking` shape), the inspector automatically reflects it with no handler change. A regression test asserts the handler imports and calls `Agent.buildJson*Request` (grep for the symbol) so a future refactor that inlines the logic fails the test.

Alternative considered and rejected: storing the raw request body at call time in `llm_history`. That would require a migration + per-call write and would only show the *actual* url_style used, not all 3. The on-demand builder approach shows all 3 side-by-side for comparison with zero storage cost.

---

## What exists today (read before changing anything)

- **Storage:** `src/ai_workflow/tui/agentic_loop/llm_history.zig` — `getMessages`, `getSessionListWithCursor`, `saveMessage`, `SessionMessage`, `TUIHistory`. `llm_history` table holds one row per chat turn (role, response_content, tool_calls_json, reasoning_content, etc.). No request-body column.
- **Builders:** `src/modules/agent/Agent.zig` — `buildJsonAnthropicRequest`, `buildJsonOpenAIRequest`, `buildJsonResponsesRequest` (all `![]u8`, arena-backed, take `AgentCall{messages, tools, temperature, max_tokens}` + `stream: bool`). `AgentCall.messages` is `[]AgentMessage` (role enum + content + tool_calls + reasoning_content + content_parts).
- **Message assembly:** `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig` + `workflow.zig` — system prompt is assembled from `agent_knowledge`, `agent_system_prompt`, `workspace_context`, `skills`, `plan`, etc., then `transform_llm_history_to_agent_message` converts DB rows to `AgentMessage[]`. The inspector should reuse this assembly (or a simplified version) so the chain matches what the LLM actually sees.
- **Settings UI:** `src/apps/desktop/src/components/views/SettingsView.vue` — 240px sidebar + content panel, 3 tabs (pabrik/skills/memories) via `activeSettingsTab` ref. `PabrikSettings.vue`, `SkillsSettings.vue`, `MemoriesSettings.vue` are the tab bodies. Add a 4th tab the same way.
- **HTTP handlers:** `src/ai_workflow/tui/http_handlers/` — ~60 handlers, each `pub fn useCase(allocator, db, ...)`. Registered in `src/main.zig` via `router.addRoute`. Follow the existing `session_messages_get.zig` pattern for the new endpoint.
- **Config / profiles:** `src/modules/config/Config.zig` — `LlmConfig` with `profiles: StringHashMap(LlmProfile)` (each has `model`, `base_url`, `url_style`, `thinking`, `reasoning_effort`, etc.). `resolveSessionProfile` picks the effective profile for a session.
- **Frontend API:** `src/apps/desktop/src/api/index.ts` — `createSseClient`, `additionalEventTypes`, typed `api.*` helpers. Add `api.getLlmHistory(sessionId)` there.

---

## Plan

### Phase 0 — Scaffolding & contracts

- [ ] **0.1 Create worktree** — `git worktree add worktree/llm-history-inspector -b worktree/llm-history-inspector` and bind the session cwd to it.
- [ ] **0.2 Add plan file** — this file at `docs/superpowers/plans/2026-09-02-llm-history-inspector-in-settings.md` (already done).
- [ ] **0.3 Define wire contract** — decide the JSON shape for `GET /api/llm/history/:session_id`:

```json
{
  "session_id": "sess_abc",
  "model": "gpt-4o",
  "url_style": "openai",
  "chain": [
    { "role": "system", "content": "...", "id": null },
    { "role": "user", "content": "hello", "id": "h1", "created_at": "..." },
    { "role": "assistant", "content": "hi", "tool_calls": [...], "reasoning_content": "..." },
    { "role": "tool", "content": "...", "tool_call_id": "call_123", "tool_name": "bash" }
  ],
  "curl": {
    "anthropic": "curl -X POST https://api.anthropic.com/v1/messages ...",
    "openai": "curl -X POST https://api.openai.com/v1/chat/completions ...",
    "openai_response": "curl -X POST https://api.openai.com/v1/responses ..."
  },
  "bodies": {
    "anthropic": { /* raw JSON object for pretty-print */ },
    "openai": { /* raw JSON object */ },
    "openai_response": { /* raw JSON object */ }
  }
}
```

`chain` is the `AgentMessage[]` the app would send (system first, then history in `created_at_nano ASC` order, filtered to `is_feed_to_llm=1`). `curl` strings are redacted. `bodies` are the parsed JSON objects (for pretty-print + copy-JSON button). All 3 bodies are generated regardless of the session's actual `url_style` so the user can compare.

### Phase 1 — Backend: chain + curl endpoint

- [ ] **1.1 New handler `src/ai_workflow/tui/http_handlers/llm_history_inspector.zig`**
  - `pub fn useCase(allocator, db, session_id) !LlmHistoryInspectorResponse` — pure function, no DI globals (takes `db` + `session_id`, returns struct). Testable with in-memory SQLite.
  - **MUST reuse `Agent.zig` builders verbatim** — the handler imports `pabrikcore.agent.Agent` and calls the same 3 methods `Agent.callStreaming` calls. No duplicated serialization. See Architecture diagram above.
  - Steps inside `useCase`:
    1. Validate `session_id` non-empty (400 if empty).
    2. Load `sessions` row to get `selected_profile_model` + `model` fallback.
    3. Resolve effective `LlmProfile` via `LlmConfig.resolveSessionProfileCompat` (or `getLlmConfig` singleton when available; fall back to defaults in tests).
    4. Load `llm_history` rows for the session via `getMessages` (or `getCompactedMessages` with `feed_filter=.all` to include everything — decide: inspector should show the *live* chain, so `is_feed_to_llm=1` only; add a `?include_compacted=true` query param later if needed).
    5. Build `AgentMessage[]` via `transform_llm_history_to_agent_message` + prepend the system prompt (reuse `prompts_build_messages_for_agent_prompt` or call `buildSystemPrompt` directly — keep it simple: if the full prompt assembly is too heavy, start with just the DB chain + a synthetic system message and iterate).
    6. Collect `tools` via `tools_equipped` / `buildMCPToolsRun` (or pass empty `&.{}` for v1 — the curl still shows the message chain; tools can be added in a follow-up).
    7. **Reuse Zig builders — for each of the 3 url_styles, construct an ephemeral `Agent` (stack-allocated, `Agent.init(allocator, io)` + set `model`, `baseUrl`, `UrlStyle`, `thinkingEnabled`, `reasoningEffort`, `temperature`, `maxTokens` from the resolved profile) and call `Agent.buildJsonAnthropicRequest` / `Agent.buildJsonOpenAIRequest` / `Agent.buildJsonResponsesRequest` with `AgentCall{messages: chain, tools, temperature, max_tokens}` and `stream=false`. Capture each `[]u8` body. This is the SAME code path as the real LLM call — the preview cannot drift.**
    8. Build curl strings from the builder output: `curl -X POST '<baseUrl><endpoint>' -H 'Authorization: Bearer sk-...****' -H 'Content-Type: application/json' -d '<body>'` where endpoint is `/v1/messages` / `/v1/chat/completions` / `/v1/responses`. Shell-escape single quotes in body via `'\''` (replace `'` with `'\''`). The body is the verbatim `[]u8` returned by the builder — no re-serialization.
    9. Return struct with `chain`, `curl`, `bodies` (bodies as `std.json.Value` or raw `[]u8` — pick one and keep it consistent).
  - Error cases: 404 if session not found, 400 if session_id empty, 500 on DB error.
  - **Static-contract test:** grep the handler source for `buildJsonAnthropicRequest`, `buildJsonOpenAIRequest`, `buildJsonResponsesRequest` — if any is missing, the test fails. This prevents a future refactor from silently duplicating the logic.

- [ ] **1.2 Wire the route in `src/main.zig`**
  - `router.addRoute(.GET, "/api/llm/history/:session_id", llm_history_inspector.handler)` — register BEFORE any `/:id` catch-all that could shadow it (see `router.zig:182` route-order rule). Add a static-contract test that the literal route is registered before the param route.

- [ ] **1.3 Unit tests for the handler** (`llm_history_inspector_test.zig` or inline in the handler file)
  - Empty session_id → 400.
  - Unknown session_id → 404.
  - Known session with 3 messages → chain has system + 3, curl strings contain the correct endpoint per style, api_key is redacted.
  - Session with tool calls → chain includes tool_call items, bodies include `tools` array.
  - Session with reasoning_content → chain includes reasoning, Responses body has `reasoning` item.

- [ ] **1.4 Functional test `tests/functional/llm_history_inspector_test.py`**
  - Boots real `pabrik` binary via `harness.py` (isolated tmpdir HOME, free port ≠ 8081).
  - Creates a workspace + session + 2 messages via the existing `POST /api/llm/session` or direct DB seed.
  - `GET /api/llm/history/:session_id` → assert 200, chain length, curl strings contain expected endpoints, no raw api_key in body.
  - Also test the 404 and 400 cases.

### Phase 2 — Frontend: Settings tab + inspector UI

- [ ] **2.1 New component `src/apps/desktop/src/components/llm/LlmHistorySettings.vue`**
  - Props: none (reads `api.getLlmHistory` directly).
  - State: `sessionId: string` (v-model on a searchable select), `chain: AgentMessage[]`, `curl: Record<string,string>`, `bodies: Record<string,object>`, `activeCurlTab: 'anthropic'|'openai'|'openai_response'`, `loading`, `error`.
  - Session picker: reuse the existing session list endpoint (`GET /api/sessions` or `GET /api/workspaces/:id/items/:id/tasks` — whichever is already used by `ChatsList.vue`). Show `session_name (session_id)` in the dropdown. Default to the most-recent session (first in the list). Debounced search input filters the dropdown locally.
  - Chain viewer: vertical list, each message as a collapsible card:
    - Header: `role` badge (system=gray, user=blue, assistant=green, tool=orange) + `id` + `created_at` + `model` if present.
    - Body: `content` (pre-wrap, truncated at 2k chars with "Show more"), `reasoning_content` in a separate collapsible block (amber), `tool_calls` as JSON, `tool_call_id`/`tool_name` for tool rows.
    - System message is always expanded and pinned at top.
  - Curl tabs: 3 tabs (Anthropic | OpenAI Chat | OpenAI Responses) — each shows:
    - The `curl` command in a `<pre>` with a Copy button (writes to clipboard, shows "Copied!" toast for 2s).
    - A "Copy JSON body" button (copies the pretty-printed `bodies[style]`).
    - The pretty-printed JSON body below the curl (collapsible, syntax-highlighted via simple `<pre>` or `shiki` if already in deps — don't add a new dep for v1).
  - Empty state: "No messages yet for this session" when chain is empty.
  - Loading state: thin yellow slider (reuse `SessionSlider.vue` pattern) or simple spinner.
  - Error state: red banner with `error.message`.

- [ ] **2.2 Wire into `SettingsView.vue`**
  - Add 4th sidebar button: `🪵 LLM History` (or `🔍 LLM History` — pick one, keep it consistent with the tab value `llm_history`).
  - Add `v-else-if="activeSettingsTab === 'llm_history'"` content block that mounts `<LlmHistorySettings />`.
  - No URL query param for v1 (keep it simple; add `?tab=llm_history` deep-link later if needed).

- [ ] **2.3 API helper `src/apps/desktop/src/api/index.ts`**
  - `api.getLlmHistory(sessionId: string): Promise<LlmHistoryInspectorResponse>` — `GET /api/llm/history/${encodeURIComponent(sessionId)}`, throws `ApiError` on 404/400.
  - Add TypeScript types for `LlmHistoryInspectorResponse`, `ChainMessage`, `CurlMap`.

- [ ] **2.4 Frontend unit tests**
  - `LlmHistorySettings.spec.ts` — mount with mocked `api.getLlmHistory`, assert session picker renders, chain cards render per role, curl tabs switch, copy buttons call `navigator.clipboard.writeText` with the expected string.
  - `SettingsView.spec.ts` — assert 4th tab exists, clicking it mounts the inspector, other tabs still work.

### Phase 3 — Polish & verification

- [ ] **3.1 Redaction audit** — grep for `apiKey` / `api_key` in the new handler; ensure no raw key reaches the wire. The curl builder must use a redacted placeholder (`sk-****` or `Bearer ****`). Add a test that the response body does not contain the real key even when the DB has one.
- [ ] **3.2 Large-session handling** — if a session has >200 messages, the chain could be large. The handler should cap at 200 (or paginate) and include `total_count` + `truncated: true` so the UI can show "Showing 200 of 412 messages". For v1, cap at 200 and document it.
- [ ] **3.3 Run verification**
  ```bash
  zig build test --summary all
  zig build pabrik-desktop --summary all
  pnpm test:unit
  PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/llm_history_inspector_test.py -v
  ```
- [ ] **3.4 Manual smoke** — start `pabrik` on a non-8081 port, create a session with a few turns (including a tool call), open Settings → LLM History, pick the session, verify chain + all 3 curl tabs + copy buttons.

---

## Pitfalls

- **Route shadowing** — `matchRoute` walks routes in registration order. Register `/api/llm/history/:session_id` BEFORE any generic `/api/llm/:id` or `/api/sessions/:id` param route, or the literal `history` segment will be captured as `:id`. Add a static-contract test.
- **Empty-slice-as-NULL** — `SqliteBackend.exec` binds `""` as SQL NULL. The handler's `session_id` validation must reject `""` before it reaches `db.query` (400, not a silent NULL bind that returns 0 rows and looks like 404).
- **Arena lifetime** — the handler's `allocator` is the per-request arena (freed at request end). All `dupe`'d strings for the response must be allocated on that arena; don't `defer free` them (see `Per-Request Arena Cleanup` memory).
- **System prompt assembly** — the full `prompts_build_messages_for_agent_prompt` pulls in workspace context, skills, memories, plan, etc. For v1, it's acceptable to show just the DB chain + a synthetic system message ("System prompt assembly is profile-dependent — see the curl bodies for the exact `instructions`/`system` field"). Don't block v1 on perfect system-prompt fidelity; iterate.
- **api_key in curl** — never emit the real key. The profile's `api_key` is in `LlmConfig` (process-global). The handler should read it only to decide whether to show `Bearer ****` vs `Bearer (not configured)`, never to embed it.

---

## Verification

- `zig build test --summary all` — 0 failures, 0 leaks (new handler tests + existing suite).
- `zig build pabrik-desktop --summary all` — 21/21 steps OK.
- `pnpm test:unit` — all specs pass (new `LlmHistorySettings.spec.ts` + updated `SettingsView.spec.ts`).
- `pytest tests/functional/llm_history_inspector_test.py -v` — happy path + 404 + 400 + redaction.
- Manual: Settings → LLM History → pick session → chain visible → 3 curl tabs → copy works.

---

## Out of scope (follow-ups)

- Pagination / virtual scroll for very long chains (v1 caps at 200).
- Live update via SSE when the session receives new messages (v1 is fetch-on-pick; add SSE later).
- Storing the raw request body at call time (the on-demand builder is cheaper and shows all 3 styles).
- Deep-link `?tab=llm_history&session_id=...` (add when the tab proves useful).
- Tool definitions in the curl bodies (v1 can show empty `tools: []`; add real tool schemas in a follow-up by threading `tools_equipped` into the handler).
