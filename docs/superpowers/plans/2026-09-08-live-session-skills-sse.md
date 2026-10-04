# Live Session-Skills SSE → Frontend Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the ChatView 🧠 skills badge update live when the agent equips a skill, without page refresh.

**Architecture:** No new SSE `event_type`. Reuse the existing `event: llm_full` payload's `session_skills` field (already emitted by the backend on every full message) by exposing it on the frontend `SseEvent` type and applying it to `sessionSkills` in ChatView's `llm` channel handler. REST remains the initial-load source.

**Tech Stack:** Zig backend (`sse_on_event_send_llm_history.zig`, `on_event_sent.zig`, `insert_llm_histories.zig`, `handle_tool.zig`, `llm_history.zig`), TypeScript frontend (`api/index.ts`, `ChatView.vue`, `SkillsPopup.vue`), vitest, pytest functional harness (`tests/functional/harness.py`).

## Global Constraints

- DONT KILL PORT 8081 server. Functional tests use harness random port (40000-60000), never 8081, never live `nohup` + `curl`.
- SSE wire-format contract is triple-site: backend `event_type` + frontend `additionalEventTypes` + frontend dispatch chain (`api/index.ts`). This plan adds NO new event name, so no contract change.
- Backend key names are frozen: REST = `skills`, SSE = `session_skills`. Frontend must read both (do NOT rename backend keys in this plan — that would touch 2 emitters + REST handler + all tests).
- Zig 0.16: per-request arena owns `ctx.allocator` memory — no `defer free` for arena slices in handlers. `rows.deinit()` (sqlite finalize) still required.
- `zig build test --summary all` must stay green; `pnpm test:unit` (vitest) must stay green; `vue-tsc --noEmit` clean.
- TDD: failing test first, then minimal implement, then verify. Commit per task.

## Context: What Exists Today (verified 2026-09-08)

Backend already sends skills on SSE, frontend already drops them:

- `tools_equipped.zig:171,174` — `get_skill`/`add_skill` have `auto_save_skill=true`.
- `handle_tool.zig:658-662` — after exec, `if (skill_saved) SaveSkill(...)` → `INSERT OR REPLACE INTO session_skills`.
- `llm_history.zig:3696-3710 saveSkill`, `:3725-3756 getSessionSkills` (`SELECT skill_name, content, loaded_at_nano AS loaded_at WHERE session_id=?`).
- Emit sites (all `event_type="llm_full"`, dual emit on `session_id` + `llm` keys):
  - `insert_llm_histories.zig:205-238` (read at `:207`, attach at `:229`).
  - `sse_on_event_send_llm_history.zig:87-204` (copy `:143-150`, payload `:177`, emit `:199,203`).
  - `on_event_sent.zig:235-367` duplicate emitter (copy `:301-314`, payload `:341`, emit `:362,366`).
  - `handle_tool.zig:836-886 sendSSEForLatestMessage` (read `:849`, attach `:879`, caller `:459` — STALE by one turn, runs before save).
  - `handle_tool.zig:755-834 sendSSEForMessageById` (read `:789`, attach `:830`, caller `:745` via `updateAndSendToolResult` — FRESH, runs after save).
- REST: `llm_history.zig:770-771,820` → `SessionMessageResponse.skills`, `session_messages_get.zig:139` → top-level `skills` (NOT per-message; `SessionMessage` in `http_response.zig:245-269` has no skills field).
- Frontend:
  - `api/index.ts:1193-1197 SkillInfo`, `:1230,1290 getChatHistory.skills` (REST, no normalize; error path `:1295-1309` omits `skills`).
  - `api/index.ts:1404-1459 SseEvent` — NO `session_skills`/`skills` field. Dispatch `:3361-3370` funnels `llm_chunk|llm_full` to `channels.llm.onEvent` skills-blind.
  - `ChatView.vue:895 sessionSkills`, `:1420 data.skills` (ONLY write site, `!loadMore` only), badge `:3713-3737` (`v-if length>0`, `:skills` passthrough to `SkillsPopup`), live handler `2179-2484` never touches `sessionSkills` (push `:2372-2400` copies content/role/tool_* /reasoning/diffview/image but no skills; in-place `:2300-2311` same).
  - `SkillsPopup.vue:4-8` pure presentational (`show, skills, sessionCwd`), `formatDate :23-31` expects seconds (`new Date(ts*1000)`).
- Tests: zero skills-content assertions. SSE tests pass `session_skills=&.{}`, shape test `:286-335` never checks `session_skills`. `session_messages_get_test.zig:361` passthrough only. No functional test touches session `skills`/`session_skills` (`memories_skills_test.py` is global `/api/skills` only).

Stale-by-one-turn note: assistant/placeholder `llm_full` (handle_tool `:459,:564`) is emitted BEFORE dispatch/s save, so it cannot carry the just-equipped skill. The tool-result `llm_full` (`:745` → `:789`) is emitted AFTER save and IS fresh. Live badge will therefore update on the tool-result event, not the assistant event — acceptable, document in code comment.

---

## Task 1: Backend static-contract test — `session_skills` survives SSE JSON

- [ ] Read `src/ai_workflow/tui/agentic_loop/sse_on_event_send_llm_history.zig:19-52,139-150` (payload struct + copy loop).
- [ ] Write failing test in same file: call `onEventSendLLMHistory` with `.session_skills = &.{.{.skill_name="my-skill", .content="hello", .loaded_at=123}}`, capture `SseEvent` via EventBus subscribe on `"llm"`, assert `ev.data` contains `"session_skills"` AND `"my-skill"`.
- [ ] Run it to confirm it fails (field missing or not serialized — if it already passes, keep test as regression lock and note pass in commit msg).
- [ ] If failing, fix copy/serialize path (likely nothing to fix — emitter already copies; test is lock-in).
- [ ] Run `timeout 120 zig build test --summary all 2>&1 | tail -n 20` — green.
- [ ] Commit: `test(sse): lock session_skills in llm_full payload`.

## Task 2: Frontend type — expose `session_skills` on `SseEvent`

- [ ] Read `src/apps/desktop/src/api/index.ts:1404-1459` (SseEvent) + `1193-1197` (SkillInfo).
- [ ] Write failing vitest (new `src/apps/desktop/src/api/__tests__/sseSkills.spec.ts`): construct `SseEvent` with `session_skills: [{skill_name, content}]`, assert type accepts it (compile) + runtime passthrough. Run `timeout 60 pnpm test:unit --run src/apps/desktop/src/api/__tests__/sseSkills.spec.ts` to see fail (property does not exist).
- [ ] Implement minimal: add `session_skills?: SkillInfo[]` next to `is_error?: boolean` (`~1458`) with comment `// Backend llm_full piggyback (sse_on_event_send_llm_history.zig:45) — REST uses top-level skills, SSE uses session_skills; read both`.
- [ ] Re-run spec — pass. Run `timeout 60 npx vue-tsc --noEmit -p tsconfig.app.json 2>&1 | tail -n 10` — clean.
- [ ] Commit: `feat(frontend): expose session_skills on SseEvent`.

## Task 3: ChatView live update — apply `session_skills` in `llm` handler (both paths)

- [ ] Read `ChatView.vue:2179-2484` handler + `:2268-2460 full` branch (in-place `:2300-2311`, push `:2372-2400`) + `:895,1420` state.
- [ ] Write failing vitest (new `ChatView.skillsLive.spec.ts` or extend existing ChatView spec): mount with mocked SSE bus, emit `full` event with `session_skills:[{skill_name:'live-skill',...}]`, assert `sessionSkills` ref / badge count updates without `loadChatHistory`. Run to confirm fail.
- [ ] Implement minimal in handler (cover BOTH returns):
  ```ts
  // Live skills: backend piggybacks session_skills on every llm_full (fresh on tool-result emit, stale on assistant emit — see handle_tool.zig:459 vs :745). REST remains initial source.
  if ((event as any).session_skills) sessionSkills.value = (event as any).session_skills as api.SkillInfo[]
  ```
  Place before `return` at `~2335` (in-place path) AND before `return` at `~2460` (push path). Guard with `Array.isArray` + `event.session_id === sid` (existing filter at `:2180` already scopes; keep same scope).
- [ ] Re-run spec — pass. Full `timeout 120 pnpm test:unit 2>&1 | tail -n 10` — green.
- [ ] Commit: `feat(chatview): live-update skills badge from llm_full`.

## Task 4: Error-path totality — `getChatHistory` failure returns `skills: []`

- [ ] Read `api/index.ts:1295-1309` error return.
- [ ] Write/extend `sseSkills.spec.ts`: mock `apiFetch` throw, assert `getChatHistory` resolves with `skills: []` (not `undefined`). Run — fail.
- [ ] Implement: add `skills: []` to error return object.
- [ ] Re-run — pass.
- [ ] Commit: `fix(frontend): getChatHistory error path returns skills []`.

## Task 5: Functional wire test — REST + SSE agree after `get_skill`

- [ ] Read `tests/functional/harness.py` boot + `sse_endtoend_test.py:29-87` (`_open_sse`, `_drain_until llm_full`) + `session_wire_test.py` REST pattern. Check `tests/functional/fixtures/` for a skill fixture or global `/api/skills` seed; reuse `memories_skills_test.py` seed if usable.
- [ ] Write `tests/functional/session_skills_live_test.py`:
  1. create session (harness helper), seed one `session_skills` row via agent `get_skill`/`add_skill` tool call OR direct DB insert through existing API (prefer real tool path if cheap, else document why direct insert).
  2. REST: `GET /api/llm/session/{sid}/messages?limit=10` → assert `body["skills"][0]["skill_name"]=="..."`.
  3. SSE: open `/api/events?channels=llm`, trigger one agent turn (or re-emit), drain until `llm_full` with `session_id==sid`, assert `data["session_skills"][0]["skill_name"]=="..."`.
  4. Assert key-name contract explicitly: REST key `skills`, SSE key `session_skills` (locks the mismatch so future renames fail loudly).
- [ ] Run `timeout 180 PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/session_skills_live_test.py -v 2>&1 | tail -n 20` — green (rebuild binary via `install:linux` first if stale; `pabrik-desktop` step does NOT rebuild core).
- [ ] Commit: `test(functional): session skills REST+SSE wire`.

## Task 6: Docs + verification sweep

- [ ] Update `docs/SPEC.md` § chat/skills (1-2 lines: live badge source = `llm_full.session_skills`, initial = REST `skills`).
- [ ] Run `timeout 120 zig build test --summary all 2>&1 | tail -n 5`, `timeout 120 pnpm test:unit 2>&1 | tail -n 5`, `vue-tsc` clean. Paste counts into plan PR description.
- [ ] Commit: `docs: live skills badge sources`.

## Out of Scope (explicit non-goals)

- New `event_type` (e.g. `skill_equipped`) — rejected: triple-site SSE contract change for zero benefit; piggyback already works.
- Renaming backend keys (`session_skills` ↔ `skills`) — rejected: touches 2 emitters + REST + tests; frontend reads both.
- Fixing stale assistant-emit (`handle_tool.zig:459`) to re-read after save — rejected: would require second emit or deferred read; tool-result emit is already fresh.
- `loaded_at` seconds-vs-nanos audit (`SkillsPopup formatDate` assumes seconds; `loaded_at_nano` column name suggests nanos) — note as follow-up, do not change units in this plan.
- Deleting dead `parseSkillFromResult` (`handle_tool.zig:328-342`, no callers) — follow-up cleanup, not this plan.

## Verification (before claiming done)

- [ ] `zig build test --summary all` green (new SSE skills lock test passes).
- [ ] `pnpm test:unit` green (new SseEvent + ChatView live specs pass).
- [ ] `PABRIK_BIN=... python3 -m pytest tests/functional/session_skills_live_test.py -v` green (REST `skills` + SSE `session_skills` agree).
- [ ] Manual: equip skill mid-run → 🧠 badge count increments without refresh; `SkillsPopup` lists new skill; zero-skill sessions show no badge (unchanged).
- [ ] Grep `session_skills` appears in: both backend emitters, `SseEvent` in `api/index.ts`, ChatView handler. `additionalEventTypes` unchanged (no new event name).
