# Tool Output Parameters Visible Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every frontend tool output card shows the tool call parameters persistently (not just while running), so users see what the agent called with.

**Architecture:** No backend/wire change — `wrapToolOutput` already emits `<parameters>` and `ChatView.vue` already threads `:parameters` to most cards. Add a shared collapsible parameters block (mirroring `McpTool.vue` Arguments `<details>`) to all cards, and close the 2 dispatcher gaps where `:parameters` is not threaded today.

**Tech Stack:** Vue 3 + TypeScript (desktop app `src/apps/desktop/src/components/tool_outputs/`), existing helpers `helpers/unwrapToolOutput.ts`, `helpers/extractParam.ts`, `tool_outputs/_shared/toolOutputParser.ts`; vitest for frontend specs. No Zig, no migration, no SSE change.

## Global Constraints

- DONT KILL PORT 8081 server; functional tests use harness free port (8080..8199 excl 8081).
- Follow existing `McpTool.vue:102-107` Arguments `<details>` pattern — do NOT invent a new visual language.
- `parameters` prop is XML today (`<path>/foo</path>`) with legacy JSON tolerated — helpers must handle both via `extractParam` / existing pretty-print, never assume one shape.
- Empty params (`''` / `'{}'` / whitespace) render NOTHING (same guard as McpTool) — no empty "Arguments" block.
- `UpdatePlan.vue` / `GetPlan.vue` take `:message` not `:content/:parameters` — respect that; read params from message if needed, don't force prop-shape change.
- No backend change in this plan. If `parameters` is missing on the wire for some tool, file a follow-up — do NOT touch `tools_wrap_output.zig` / `handle_tool.zig` here.
- Each task ends with commit; run `pnpm test:unit` subset + `vue-tsc --noEmit` before claiming done.

## Background (research summary)

Backend `src/ai_workflow/tui/agentic_loop/tools_wrap_output.zig:30 wrapToolOutput(allocator, tool_name, parameters, success, error_message, data)`:
- `parameters` arg at ~40 call sites (`tools_exec_*.zig`) is always `tc.function.arguments` — verbatim LLM JSON string.
- Inside, `jsonArgsToXml` converts JSON object → `<key>value</key>` XML; malformed → `<raw>escaped</raw>`; empty → empty string (outer `<parameters></parameters>` still emitted).
- Envelope `<tool><name/><parameters/><success/> + <data/>|<error/></tool>` stored in `llm_history.response_content` (placeholder INSERT then in-place UPDATE in `handle_tool.zig`), sent via SSE `onEventSendLLMHistory` with `content=response_content`, re-served over REST `get_llm_histories`.

Frontend `src/apps/desktop/src/components/views/ChatView.vue:1140-1168`:
- `unwrappedByMessageId = computed(Map<id, tryUnwrapToolOutput(m.content)>)`, `innerToolData(m) = unwrapped?.data ?? m.content`, `getParametersForMessage(m) = unwrapped?.parameters ?? '{}'`.
- Template `3091-3328` dispatches `msg.tool_name` → card, passing `:content="innerToolData(msg)" :parameters="getParametersForMessage(msg)"`.
- Today params are header fallback while running (`ReadFile displayPath = parseReadFile(content).path ?? extractParam(parameters,'path')`, same idiom in ShellTool/Glob/GetSkill/SaveMemory) + only `McpTool.vue` shows full args post-completion in `<details><summary>Arguments</summary>`.
- Gaps: `UpdatePlan/GetPlan` take `:message` (no `:parameters` threading, comment L3254-63 says intentional), skill-read cards (`ViewSkill/ListSkills/Add/Edit/RemoveSkill`) don't receive `:parameters`.

## File Structure

New:
- `src/apps/desktop/src/components/tool_outputs/_shared/ToolParameters.vue` — shared collapsible args block (1 responsibility: pretty-print + hide-when-empty).
- `src/apps/desktop/src/components/tool_outputs/_shared/ToolParameters.spec.ts` — unit tests.

Edit (presentational only, one card per task):
- `tool_outputs/ReadFile.vue`, `WriteFile.vue`, `Search.vue`, `SearchHistory.vue`, `TextReplace.vue`, `ListDirectory.vue`, `RemoveFile.vue`, `SaveMemory.vue`, `LoadMemory.vue`, `DeleteMemory.vue`, `ShowPreview.vue`, `GenerateImage.vue`, `SpawnSubAgent.vue`, `NalarBrowser.vue`, `SetGitWorktree.vue`, `ReadCompactedMessages.vue`, `KanbanMove.vue`, `KanbanList.vue`, `preview/ShellTool.vue`, `preview/Glob.vue`, `preview/Bash.vue`, `preview/GetSkill.vue` (whichever exist — verify via glob at execution time).
- `components/views/ChatView.vue` — only for the 2 gap closures (thread `:parameters` to skill cards; decide UpdatePlan/GetPlan handling).
- `tool_outputs/McpTool.vue` — refactor to USE the shared component (no visual change, dedupe only).

No change: `src/ai_workflow/**`, `src/modules/**`, SSE, API, migrations.

---

## Tasks

### Task 1 — Shared ToolParameters component + tests

- [ ] Read `tool_outputs/McpTool.vue:100-110` Arguments block + `tool_outputs/_shared/toolOutputParser.ts` pretty-print + `helpers/extractParam.ts`.
- [ ] Write failing test `tool_outputs/_shared/ToolParameters.spec.ts`: empty/{} → renders nothing; XML `<path>/foo</path>` → shows pretty block; JSON `{"path":"/foo"}` → shows pretty block; malformed → raw fallback.
- [ ] Run it to make sure it fails (component missing).
- [ ] Implement `tool_outputs/_shared/ToolParameters.vue`: props `{ parameters?: string }`, guard `trim() in ('','{}') → render nothing`, else `<details class="tool-params"><summary>Parameters|Arguments</summary><pre>pretty</pre></details>` reusing McpTool styling + existing pretty helper (no new CSS language).
- [ ] Run `pnpm test:unit ToolParameters` — green.
- [ ] Commit.

### Task 2 — Migrate McpTool to shared component (no visual change)

- [ ] Write failing test: `McpTool.spec.ts` — mock `:parameters` XML + JSON, assert shared component stub receives same string (or rendered output identical to today).
- [ ] Run to confirm fail (still inline block).
- [ ] Replace inline `<details>` in `McpTool.vue:102-107` with `<ToolParameters :parameters="parameters" />`.
- [ ] Run `pnpm test:unit McpTool` + visual check (collapsed Arguments still appears iff params non-empty).
- [ ] Commit.

### Task 3 — Add parameters block to file cards (ReadFile/WriteFile/TextReplace/ListDirectory/RemoveFile)

- [ ] Write failing tests per card (or one parametrized spec): with `:parameters="<path>/foo</path>"` + minimal `:content`, assert Parameters block visible post-completion (not just header).
- [ ] Run to confirm fail.
- [ ] Add `<ToolParameters :parameters="parameters" />` to each of the 5 cards (verify each already declares `parameters?: string` prop — add if missing, mirroring `ReadFile.vue` props).
- [ ] Run `pnpm test:unit` for the 5 specs — green.
- [ ] Commit.

### Task 4 — Add parameters block to search/shell cards (Search/SearchHistory/ShellTool/Glob/Bash)

- [ ] Write failing tests: Search with `<query>foo</query>`, ShellTool with `<command>ls</command>` → Parameters block visible.
- [ ] Run to confirm fail.
- [ ] Add `<ToolParameters>` to each card (ShellTool lives in `preview/ShellTool.vue` — same pattern).
- [ ] Run specs — green.
- [ ] Commit.

### Task 5 — Add parameters block to memory/plan-adjacent cards (SaveMemory/LoadMemory/DeleteMemory/ShowPreview/GenerateImage/SpawnSubAgent/NalarBrowser/SetGitWorktree/ReadCompactedMessages/KanbanMove/KanbanList)

- [ ] Write failing tests per card with representative params (`<id>`, `<content>`, kanban fields, etc.).
- [ ] Run to confirm fail.
- [ ] Add `<ToolParameters>` to each.
- [ ] Run specs — green.
- [ ] Commit.

### Task 6 — Close dispatcher gaps (skill cards + UpdatePlan/GetPlan decision)

- [ ] Read `ChatView.vue:3091-3328` dispatcher branches for `view_skill/list_skills/add_skill/edit_skill/remove_skill` + `update_plan/get_plan` (`:message` idiom + L3254-63 comment).
- [ ] Write failing test (ChatView or dispatcher spec): skill tool message with envelope parameters → card receives `:parameters` (or renders block); UpdatePlan/GetPlan → document decision (option A: leave as-is since plan content IS the params; option B: add params block from `msg` envelope).
- [ ] Run to confirm fail.
- [ ] Implement: thread `:parameters="getParametersForMessage(msg)"` to skill cards + add `<ToolParameters>` inside them; for UpdatePlan/GetPlan implement the decided option (default recommendation: leave content as-is, add small collapsed params block only if envelope params non-empty — self-contained via `msg`, no prop-shape break).
- [ ] Run `pnpm test:unit ChatView` subset + `vue-tsc --noEmit -p tsconfig.app.json` — clean.
- [ ] Commit.

### Task 7 — Full verification + human review handoff

- [ ] Run `pnpm test:unit` (full) — all green, no regressions.
- [ ] Run `vue-tsc --noEmit` — clean.
- [ ] Manual check: trigger 2-3 tools (e.g. read_file, search, bash) in dev, confirm collapsed Parameters block appears on each card post-completion and stays hidden for empty params.
- [ ] No backend verification needed (no Zig change); do NOT run `zig build test` unless ChatView-only doubt — note why skipped.
- [ ] Present this plan + verification for human review (card stays `in_review_planning`; do NOT move to `in progress` until approved).
