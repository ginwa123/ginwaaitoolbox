# Skill Evals — evaluate the skills an agent actually used

> **Status:** plan only. Nothing in this document is implemented.
> **Written:** 2026-09-27, against `HEAD` = `e0d892c9` (branch base `origin/main`).
> **Sibling plan:** `docs/plans/2026-09-28-skills-sqlite-table.md` — unimplemented, and it
> **claims Migration 094**. This plan therefore takes **095 / 096** and is written so that
> every phase before W9 works whether or not 094 has landed (§4.3, §5 W9).
> **Product request:** *"run evals skills on demand after task done — that means the main
> agent runs `spawn_sub_agent`, the sub-agents eval the skills, for example: the skill is
> not relevant, the skill must use the new code, etc., based on the history the main agent
> used that skill."*

---

## 1. Goal, in one paragraph

Today a skill is a file the agent may or may not load, and **nothing ever checks whether
it was right**. A skill can describe an API that was renamed three months ago, duplicate
another skill, or be loaded for a task it has nothing to do with — and the only feedback
loop is a human noticing. This plan adds **Skill Evals**: after a task finishes (and on
demand), a **separate main-agent session** is queued which reads the frozen evidence of
*which skills the task actually loaded and what it did with them*, then calls the existing
`spawn_sub_agent` tool to fan out **one eval sub-agent per skill**. Each sub-agent scores
that skill on a fixed rubric — relevance, whether the procedure was actually followed,
whether it helped, **freshness against today's code** ("must use the new code"), accuracy,
and duplication — and must back every claim with machine-checkable evidence. Verdicts
(`keep | update | rewrite | merge | delete | needs_human`), a proposed replacement body, and
the evidence are stored in SQLite and surfaced in a new Evals UI, where a human applies or
dismisses them. **Nothing is auto-applied by default.**

---

## 2. The request, decomposed

The request names six things. Each maps to exactly one mechanism in this plan — no more,
no less.

| What was asked | Mechanism | Where |
|---|---|---|
| "run evals **on demand**" | `POST /api/skill-evals/runs`, a UI button, and a `run_skill_eval` agent tool so the user can literally say *"eval my skills"* in chat | §4.11, §4.13, W9, W11 |
| "**after task done**" | one hook in the existing per-run teardown `defer` — the only place that runs on *every* exit path | §4.1, W7 |
| "the **main agent** runs `spawn_sub_agent`" | a dedicated eval session with `is_sub_agent = false` (mandatory — see §4.2) that spawns the eval sub-agents | §4.2, W6 |
| "the sub-agents **eval the skills**" | one sub-agent per used skill, each with its own narrow tool allowlist and a fixed rubric | §4.5, §4.6 |
| "e.g. the skill **is not relevant**" | rubric dimension `relevance`, judged against the task the skill was loaded for | §4.5 |
| "e.g. **must use the new code**" | rubric dimension `freshness` **plus** a deterministic no-LLM drift pre-pass (path existence + `git log --since`) so the sub-agent adjudicates pre-computed facts instead of guessing | §4.4, §4.5 |
| "based on **the history the main agent used that skill**" | the frozen evidence bundle built from `session_skill_events` + the `llm_history` tool-call graph | §4.3, W3 |

Two additional dimensions the request implies but does not name, and which are the ones a
human reviewer will actually want: `accuracy` (is any stated fact wrong?) and `duplication`
(does another skill already cover this?).

---

## 3. Verified current state

All line numbers verified in this worktree against `HEAD` = `e0d892c9`.

### 3.1 A skill is a file, and nothing records whether it was *used*

- `<root>/<name>/SKILL.MD`; global root `$XDG_CONFIG_HOME/nalar/skills` else
  `$HOME/.config/nalar/skills` (`src/modules/agent/tools/skills.zig:474`), local root
  `<cwd>/.nalar/skills` (`skills.zig:55`). `SkillInfo` is `{name, description, path}`
  (`skills.zig:62`) — **no id, no tags, no content**.
- The five tools live in `src/modules/agent/tools/skill_tools.zig`; `use_skill` takes
  **`path`**, not `skill_name` (`skill_tools.zig:145-194`).
- **There is no SQLite `skills` table** — the sibling plan (§Sibling) is plan-only.
  Highest migration in the tree is **93** (`migration.zig:4964`); the registration list ends
  at `migration.zig:2006`.

### 3.2 The only usage record is `session_skills`, and it is lossy

`session_skills` (Migration 008, `migration.zig:90-99`; `loaded_at` → `loaded_at_nano` in
Migration 075, `migration.zig:3291`):

```sql
session_id TEXT NOT NULL, skill_name TEXT NOT NULL, content TEXT NOT NULL,
loaded_at_nano ..., PRIMARY KEY (session_id, skill_name)
```

- Written **only** by `use_skill` → `ToolExecResult.skill_save`
  (`tools_exec_skills.zig:60-67`) → `handle_tool.zig:809-810` → `saveSkill`
  (`llm_history.zig:4243`, `INSERT OR REPLACE`).
- **Gaps that matter for evals:**
  1. **No `loop_index`.** "Which turn loaded this skill" is not stored. `loaded_at_nano` is
     **seconds** despite the name (`llm_history.zig:4340-4343`) and `INSERT OR REPLACE`
     re-stamps it on a reload, so a reload destroys the original load time.
  2. **`add_skill` / `edit_skill` do not write here**, despite carrying
     `.auto_save_skill = true` — the flag has zero readers (the sibling plan's §3.3).
  3. **Listed-but-not-loaded is invisible.** `list_skills` returns
     `{name, description, path}` only (`skills.zig:62`), so a skill that was *offered and
     ignored* — a real eval finding — leaves no trace at all.

### 3.3 The transcript is queryable, and is the enrichment source

`llm_history` carries everything needed to reconstruct a `use_skill` call
(`migration.zig:597-626`, `:656`):

| Column | Use for evals |
|---|---|
| `tool_calls_json` (assistant rows) | serialized `[]ToolCall` where `arguments` is a **JSON string inside JSON** — `llm_history.zig:1459-1464` |
| `loop_index` | the turn number — joins an assistant call to its result and to the transcript |
| `tool_name`, `tool_call_id` (tool rows) | `role='tool'`, `tool_name='use_skill'`, `response_content` = the `UseSkillJSON` containing `skill_name` **and the full skill body** |
| `parent_session_id` | needed to sum an eval run's own token cost (§8) |

This is why the plan does **not** depend on `session_skills.loaded_at_nano` for ordering:
the tool row has a real `loop_index`. `session_skills` is still the fastest way to answer
"did this session load any skill at all", which is the hook's cheapest gate.

### 3.4 Post-task does not exist

- The one place that runs on **every** exit path is the teardown `defer` at
  `workflow.zig:712-724` (armed *before* the loop). There is no per-run success hook. The
  terminal-success exit is `workflow.zig:1598` (`break` inside the `.stop` branch, after
  `insertLLMHistories` at `:1533` persisted the final assistant message and after
  `deleteWorker` at `:1585`). **There is a commented-out `markSessionIdle` immediately
  before it at `workflow.zig:1584`** — the abandoned hook site.
- Three other terminal exits exist and must be *explicitly* excluded, not forgotten:
  queued-message continuation (`:1565-1573`, `continue` — **not** finished), `ask_user`
  pending (`:1653-1661`), unexpected `finish_reason` (`:1695`), plus cancellation
  (`flushCancelledPartial`, `workflow.zig:514`) and callback-level error
  (`workflow.zig:143-196`, where the loop's `break` is never reached).
- The reusable launch primitive is `di.emit_run_agent(.{ ..., .skip_initial_queue_message = true })`
  — two working call sites: `src/schedulers/cleanup_stale_background_process.zig:308-320`
  (`wakeSessionForCompletion`, gated on `isWorkerRunning` at `:279`) and
  `ask_user_pending.zig:627`.
- The reusable polling-scheduler shape is `src/ai_workflow/tui/routines/Scheduler.zig`
  (`TICK_INTERVAL_NS = 5s` `:49`, `resetStuckRunning` `:58`, claim-then-fire
  `fire.zig:111-158` with `db.changes() > 0`). Its `markSuccess` fires at **submit** time
  (`fire.zig:164`), so routines themselves are the wrong container — only the loop shape is
  reusable.

### 3.5 Sub-agents already do everything else

- `spawn_sub_agent` is a **batch runner**: one call spawns N agents in parallel via
  `std.Io.Group.concurrent` (`tools_exec_spawn_sub_agent.zig:461, 554, 559`), hard cap
  **20** enforced at the parse boundary (`spawn_sub_agent.zig:249`).
- `tools` is a **required, non-empty allowlist** — no omit, no `"all"`
  (`spawn_sub_agent.zig:277-297`); `ask_user` and `spawn_sub_agent` are rejected
  (`:307`), and the same list is enforced again at filter time from the single source of
  truth `MAIN_AGENT_ONLY_NAMES` (`ask_user.zig:260-263`, strip at
  `tool_eligibility.zig:134`).
- `agent_name` is resolved **per-profile only** from `~/.config/nalar/config.json`
  (`Config.zig:2194-2253`); a miss is a **random fallback** flagged
  `is_random_fallback` and badge-rendered by the frontend (`SpawnSubAgent.vue:103`).
- **`timeout_seconds` is dead** — parsed and validated (`spawn_sub_agent.zig:319-322`) and
  read nowhere; `group.await` is unbounded.
- Sub-agents cannot inherit tool calls (`inherited_context.zig:122-181` filters to
  `role IN ('user','assistant')`) and cannot spawn further agents (§4.2).

### 3.6 There is no eval, rating, or feedback primitive anywhere

`rg` over `src/**` for `rating|thumbs|feedback|score|verdict|eval` returns only prose in
comments. No table, no endpoint, no component. **This feature owns the first one.**
The precedent to copy for "structured notes in SQLite + FTS5" is `agent_memories`
(Migration 070, `migration.zig:3466-3592`; module `src/agentic_loop/agent_memories.zig`).

### 3.7 Frontend surfaces that already exist and must be reused

| Concern | Reuse |
|---|---|
| Master/detail settings page | `SettingsView.vue:78-121` + `SkillsSettings.vue:1-73` + `SkillList.vue` + `SkillDetail.vue:1-203` |
| Verdict badge on a skill row | `WorkspaceItemTaskCard.vue:569-624` (the review-dot pattern) |
| Proposed-patch diff | the existing diff renderers (`SidebarDiffView.vue:279`, `GitFileViewer.vue:235`) |
| Deep-linkable panel | `ChatRightSidebar.vue:42` `SidebarPanel` union (+ `readSidebarParam` `:44-54`, `setPanel` `:84-96`) — extend the union, never add a second param |
| SSE | `src/helpers/sseBus.ts:25-43` (`SseEventMap`) + `src/api/index.ts:3620-3656` (`UnifiedChannels`) + `:3738-3799` (`additionalEventTypes`) + a dispatch branch in `onEvent` |
| Store-side SSE | `src/stores/kanbanSse.ts:42-323` is the template |

**The `session_unknown` lesson applies directly.** An `event:` name that is not
pre-registered in `additionalEventTypes` (`api/index.ts:3738-3799`) is dropped silently by
the browser before `onEvent` ever fires — this is exactly how `action="updated"` produced
`event: session_unknown` and rows stayed stale until refresh (PR #215). Every new event
name in this plan needs a Zig test *and* a TS registration in the same PR.

---

## 4. Target design

### 4.1 Trigger — one queue row, two producers

```
T1 on demand  ── POST /api/skill-evals/runs ─┐
              ── run_skill_eval agent tool  ─┤
T2 after task ── per-run teardown defer ─────┤
                                             ▼
                              INSERT skill_eval_runs (status='queued')
                                             │  (microseconds, no LLM)
                                             ▼
                     skill_evals_poller (5 s tick, crash-recoverable)
                                             │  claim → status='running'
                                             ▼
                     di.emit_run_agent(eval_session_id, skip_initial_queue_message=true)
```

**T2 hook point: `workflow.zig:712-724`, inside the existing `defer`.** That defer is armed
before the loop, so it is the only place guaranteed to run on *every* exit path. The hook is
gated on a local `run_completed: bool` that is set to `true` immediately before the `break`
at `workflow.zig:1598` — i.e. "the final assistant message was persisted and the worker is
being torn down". Errors, cancellation, `ask_user`-pending and unexpected `finish_reason`
all leave it `false`, so they do not schedule an eval by default. `eval_on =
"all_terminal"` in config (§4.10) opts the other exits in.

The hook does exactly three cheap things and returns:

1. `SELECT 1 FROM session_skill_events WHERE session_id = ? LIMIT 1` — no skills used, no eval.
2. Guard checks (§4.9) — config enabled, `sessions.is_eval = 0`, per-day budget, dedupe.
3. `INSERT INTO skill_eval_runs (... status='queued')`.

**It must not call an LLM and must not block.** The `defer` runs while the worker row is
being deleted; anything slow here delays `worker_deleted` and the frontend's
`isStreaming` flag.

### 4.2 The runner is a **main** agent session — not a sub-agent

This is forced by the code, not a preference:

- Sub-agents are stripped of `spawn_sub_agent` (`tool_eligibility.zig:134`, source of truth
  `ask_user.zig:260-263`). A sub-agent **cannot** fan out, so the eval runner must be
  `is_sub_agent = false`.
- The runner must therefore be a normal session: `sessions.is_eval = 1` (Migration 095) and
  `skill_eval_runs.eval_session_id` pointing back at it.
- Its `allowed_tools` (a CSV in `RunParamsNew`, authoritative for sub-agents because the
  per-agent override chain is skipped when `is_sub_agent`, `workflow.zig:600-641`) is:
  `list_skills, use_skill, read_file, search, glob, list_directory, command, used_tools,
  spawn_sub_agent, submit_skill_eval_report`
  — plus `edit_skill, add_skill, remove_skill` **only** in apply mode (§4.8).
- **Rejected alternative:** having the *task's own* session spawn the eval sub-agents at
  the end. It extends the user's session, pollutes its transcript and compaction window,
  cannot be retried or cancelled independently, and — decisively — the task session has
  already emitted its final message, so appending an eval turn would surface eval chatter
  in the user's chat. The runner-as-separate-session still literally satisfies "the main
  agent runs `spawn_sub_agent`": the runner *is* a main agent.

### 4.3 The evidence bundle — the contract of the whole feature

`src/agentic_loop/skill_evals_evidence.zig` builds one frozen JSON document per run, stored
in `skill_eval_runs.evidence_json` and handed verbatim to the runner. Freezing it means the
report can be re-derived and audited later, and the eval is reproducible even after
`llm_history` rows are compacted away.

```json
{
  "schema": 1,
  "run_id": "skilleval_1790542201041721153",
  "evaluated": {
    "session_id": "task_1790542158293_5", "task_id": "task_1790542158293_5",
    "workspace_item_id": "item_1788811112791088699", "item_type": "kanban",
    "cwd": "/home/ginwa/ginwaaitoolbox", "finish_reason": "stop",
    "final_message": "...the assistant's last message...",
    "user_intent": "...the session's first user message, truncated to 2 KB...",
    "started_at_nano": 1790542158599884172, "ended_at_nano": 1790542201041721153
  },
  "skills": [{
    "name": "ginwaaitoolbox-resolve-pr-conflict",
    "scope": "global",
    "load_event": "loaded",
    "first_loop_index": 7, "use_count": 2, "listed_count": 3,
    "listed_without_loading": false,
    "content_at_use": "---\nname: ...\n---\n## Procedure\n...",
    "content_hash_at_use": "sha256:9f2c...",
    "content_now": "---\nname: ... (current body)",
    "content_changed_since_use": true,
    "referenced_paths": ["src/agentic_loop/workflow.zig:1598", "docs/plans/"],
    "missing_paths": ["src/ai_workflow/tui/agentic_loop/workflow.zig"],
    "drift_commits": [{ "sha": "838caba8", "subject": "Remove unused prompt sections", "date": "2026-09-19" }],
    "use_calls": [{ "loop_index": 7, "tool_call_id": "call_1",
                    "arguments": {"path": "/home/u/.config/nalar/skills/.../SKILL.MD"},
                    "result_excerpt": "{\"skill_name\":\"...\",\"loaded\":true,...}" }]
  }],
  "available_skills": [{ "name": "other-skill", "description": "..." }],
  "transcript_excerpt": [{ "role": "assistant", "loop_index": 7, "content": "..." }],
  "deterministic_findings": [{ "dimension": "stale_path", "severity": "high",
                              "claim": "referenced path does not exist",
                              "path": "src/ai_workflow/tui/agentic_loop/workflow.zig" }]
}
```

`transcript_excerpt` is the *compact* window around each `first_loop_index` (a few turns
either side), not the whole session — the whole session is available to the sub-agents
through the `read_workspace_session` tool if they need it, and a 200 KB prompt is not a
feature.

**Cross-plan hazard, called out now:** `use_calls[].arguments` is `{path: ...}` **today**,
but the sibling plan (§4.7 there) deletes `path` and makes `use_skill` take `skill_name`.
The extractor must therefore accept **both** shapes (`skill_name` first, then `path`
basename, then `response_content.skill_name` as the authority) or evals silently stop
matching the moment 094 lands. This is a two-line tolerance, and it is the single most
likely way this feature breaks in the future. W9 owns the switch-on case.

### 4.4 Tier 0: the deterministic pre-pass (no LLM, no tokens)

`src/agentic_loop/skill_evals_drift.zig`. Cheap structural evals run **before** any agent is
spawned, and their results are pre-computed facts in the bundle:

1. **Path extraction** — a conservative tokeniser over the skill body for path-shaped and
   `file:line`-shaped tokens. Conservative on purpose: a false positive becomes a false
   "stale path" finding. Cap at 50 paths per skill.
2. **Existence check** — for each path, resolve against the session `cwd` and `statFileAbsolute`
   / `accessAbsolute`. **Every path must be validated `isAbsolute` before reaching a
   `*Absolute` call** — `std.fs.path.isAbsolute("")` is `false`, and the `*Absolute` family
   asserts and aborts the whole process (PR #639's crash class). A relative or empty token
   is rejected at the boundary, never passed through.
3. **Drift by git history** — for each referenced path, `git -C <cwd> log --oneline
   --since=<loaded_at ISO> -- <paths>`, bounded: `std.process.spawn` (not `Child.run` — the
   codebase is uniformly on `spawn`), `wait_pid_bounded` (`shell.zig:164`), 3 s deadline,
   output capped. This *is* the "must use the new code" mechanism — it produces the commit
   list, and the sub-agent decides whether those commits invalidate the skill.
4. **Structural checks** — frontmatter parses; `name:` is kebab-case; `description:`
   present and ≤ 200 chars; body ≤ `MAX_SKILLS_SIZE` (100 KB, `skills.zig:7`); **name
   collision** with another skill by `name`, and by description similarity (a cheap
   trigram/Jaccard over descriptions, no LLM) → the `duplication` signal.

If the only findings are deterministic and none is `severity: high`, the run can be
**settled without spawning any sub-agent at all** and the token cost is zero. This is worth
building first: it makes the feature immediately useful on the cheapest cases and it is
fully unit-testable.

### 4.5 Tier 1: the rubric and the strict output contract

The runner's queued instruction (`src/agentic_loop/skill_evals_prompt.zig`) is a generated
markdown document: role statement, the frozen evidence bundle, the rubric verbatim, the
output contract, **and the explicit statement that this session is an eval session and must
not attempt the original task**.

Each dimension is scored **0-3** with a mandatory evidence pointer:

| Dimension | Question the sub-agent must answer | Evidence it must cite |
|---|---|---|
| `relevance` | Did this skill match the task it was loaded for? | the user intent + the turn that loaded it |
| `used` | Was the procedure actually followed, or loaded and ignored? | transcript tool calls |
| `helpfulness` | Did following it help, or mislead? | the outcome / final message |
| `freshness` | **Do the paths, symbols and commands the skill names still exist and behave as described?** | `deterministic_findings` + `drift_commits` + its own `read_file`/`search`/`command` checks |
| `accuracy` | Is any stated fact wrong? | the file/line that contradicts it |
| `duplication` | Does `available_skills` already cover this? | the other skill's name |

Verdict is exactly one of:

| Verdict | Requires |
|---|---|
| `keep` | may have zero findings |
| `update` | ≥ 1 finding **and** `proposed_content` |
| `rewrite` | `proposed_content` |
| `merge` | `merge_target` ∈ `available_skills` |
| `delete` | ≥ 1 `severity: high` finding |
| `needs_human` | the honest default when evidence is insufficient |

Submitted via the `submit_skill_eval_report` tool (W8) as strict JSON, then **validated in
Zig** (`validateReport()`), never trusted: verdict ∈ enum; scores ∈ 0..3; confidence ∈
0..1; every finding has non-empty `evidence`; `proposed_content` non-empty for
`update`/`rewrite`; `merge_target` exists; a `delete` verdict without a `high` finding is
downgraded to `needs_human`. On validation failure the runner gets **one** repair turn with
the error fed back, then the result is stored as `needs_human`. An unevidenced verdict is
the single most damaging failure mode of an LLM judge — it is rejected structurally.

### 4.6 Fan-out

One `spawn_sub_agent` call, one sub-agent **per skill**, capped at
`min(max_skills_per_run, 20)`. Above the cap, skills are prioritised by
`use_count desc, first_loop_index asc` and the remainder are recorded as
`status='skipped'` in the run report rather than silently dropped.

Each sub-agent's `tools` (required, non-empty, no `"all"`, never a main-agent-only name):

```
["read_file", "search", "glob", "list_directory", "command", "list_skills", "use_skill"]
```

plus `write_file`/`text_replace` only if the sub-agent is asked to draft a patch (default:
it returns `proposed_content` in its report instead — the parent owns all writes).

`agent_name` = `skill_evals.judge_sub_agent` if configured, else the profile's first
sub-agent, else `""` → the existing random fallback still works, so **v1 needs zero
configuration**. The recommended sub-agent definition (a `skill-evaluator` entry with the
rubric as its `system_prompt`) ships as a documented one-click seed, and the UI shows a
"using a random agent — configure one" affordance off `is_random_fallback`.

**`timeout_seconds` must not be relied on** — it is dead today (§3.5). The bound comes from
the poller's reaper (§4.7): a run whose `eval_session_id` has no live worker and no report
after `max_run_minutes` is marked `failed` and can be retried. Fixing the dead field is
tempting but is a separate change to a shared tool; note it, do not bolt it on here.

### 4.7 Storage — Migrations **095** and **096**

Conventions copied from the repo, not invented: one statement per `db.exec`
(`sqlite3_prepare_v2` compiles only the first); `CREATE TABLE/INDEX IF NOT EXISTS`;
`DATETIME DEFAULT CURRENT_TIMESTAMP` set in SQL, never bound from Zig; **TEXT ids** from
`std.Io.Timestamp.now(io, .real).nanoseconds`; no foreign keys (`PRAGMA foreign_keys` is
deliberately off project-wide); register in `registerAllMigrations` after the Migration093
entry at `migration.zig:2006`.

#### Migration 095 — usage ledger + eval marker

```sql
-- the append-only record of "which skill, which turn, what body" (fixes §3.2 gaps 1 & 3)
CREATE TABLE IF NOT EXISTS session_skill_events (
  id           TEXT PRIMARY KEY,
  session_id   TEXT NOT NULL,
  skill_name   TEXT NOT NULL,
  event        TEXT NOT NULL DEFAULT 'loaded',  -- 'listed' | 'loaded' | 'created' | 'edited' | 'removed'
  source       TEXT NOT NULL DEFAULT '',        -- tool name that produced it
  content_hash TEXT NOT NULL DEFAULT '',        -- sha256 of the body AS READ (drift key)
  loop_index   INTEGER NOT NULL DEFAULT 0,
  llm_history_id TEXT NOT NULL DEFAULT '',      -- the role='tool' row id
  created_at   DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_session_skill_events_session ON session_skill_events(session_id);
CREATE INDEX IF NOT EXISTS idx_session_skill_events_skill ON session_skill_events(skill_name, created_at);

-- the recursion guard for §4.1 (an explicit flag, NOT a session-id substring sniff —
-- `tools_exec_spawn_sub_agent.zig:241` already shows how fragile that heuristic is)
ALTER TABLE sessions ADD COLUMN is_eval INTEGER NOT NULL DEFAULT 0;
```

Writers: `handle_tool.zig`, immediately beside the existing `SaveSkill` call at
`handle_tool.zig:809-810` — one `INSERT` for `use_skill`, one per entry returned by
`list_skills` (that is what makes `listed_without_loading` observable), one for
`add_skill`/`edit_skill`/`remove_skill`. `session_skills` keeps its current writers
untouched; it remains the compaction drift detector. **The ledger is additive — it never
replaces `session_skills`.**

#### Migration 096 — runs and results

```sql
CREATE TABLE IF NOT EXISTS skill_eval_runs (
  id              TEXT PRIMARY KEY,
  session_id      TEXT NOT NULL DEFAULT '',   -- evaluated session ('' for a skill-scope run)
  eval_session_id TEXT NOT NULL DEFAULT '',   -- the main-agent session doing the eval
  skill_name      TEXT NOT NULL DEFAULT '',   -- '' = whole-session scope
  scope           TEXT NOT NULL DEFAULT 'session',   -- 'session' | 'skill' | 'sweep'
  trigger         TEXT NOT NULL DEFAULT 'on_demand', -- 'on_demand' | 'after_task' | 'manual_ui'
  status          TEXT NOT NULL DEFAULT 'queued',    -- queued|running|done|failed|cancelled|skipped
  profile         TEXT NOT NULL DEFAULT '',
  model           TEXT NOT NULL DEFAULT '',
  cwd             TEXT NOT NULL DEFAULT '',
  evidence_json   TEXT NOT NULL DEFAULT '',
  report_json     TEXT NOT NULL DEFAULT '',
  total_tokens    INTEGER NOT NULL DEFAULT 0,        -- computed at finalize (§8)
  error           TEXT NOT NULL DEFAULT '',
  started_at      DATETIME, finished_at DATETIME,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_skill_eval_runs_status ON skill_eval_runs(status, created_at);
CREATE INDEX IF NOT EXISTS idx_skill_eval_runs_session ON skill_eval_runs(session_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_eval_runs_after_task
  ON skill_eval_runs(session_id, skill_name, trigger) WHERE trigger = 'after_task';

CREATE TABLE IF NOT EXISTS skill_eval_results (
  id              TEXT PRIMARY KEY,
  run_id          TEXT NOT NULL,
  skill_name      TEXT NOT NULL,
  session_id      TEXT NOT NULL DEFAULT '',
  status          TEXT NOT NULL DEFAULT 'pending', -- pending|done|failed|skipped
  verdict         TEXT NOT NULL DEFAULT 'needs_human',
  relevance       INTEGER NOT NULL DEFAULT 0,
  used            INTEGER NOT NULL DEFAULT 0,
  helpfulness     INTEGER NOT NULL DEFAULT 0,
  freshness       INTEGER NOT NULL DEFAULT 0,
  accuracy        INTEGER NOT NULL DEFAULT 0,
  duplication     INTEGER NOT NULL DEFAULT 0,
  confidence      REAL NOT NULL DEFAULT 0,
  content_at_use  TEXT NOT NULL DEFAULT '',
  missing_paths_json TEXT NOT NULL DEFAULT '',
  drift_commits_json TEXT NOT NULL DEFAULT '',
  proposed_content TEXT NOT NULL DEFAULT '',
  proposed_diff   TEXT NOT NULL DEFAULT '',
  evidence_json   TEXT NOT NULL DEFAULT '',
  rationale       TEXT NOT NULL DEFAULT '',
  sub_session_id  TEXT NOT NULL DEFAULT '',
  applied_at      DATETIME,
  apply_action    TEXT NOT NULL DEFAULT '',       -- 'edit'|'delete'|'keep'|'' (what a human did)
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_skill_eval_results_run ON skill_eval_results(run_id);
CREATE INDEX IF NOT EXISTS idx_skill_eval_results_skill ON skill_eval_results(skill_name, created_at DESC);
```

`applied_at` + `apply_action` exist so the eval itself can later be scored — did the human
accept the verdict? That is the only honest way to calibrate a judge, and it costs two
columns.

Repository module: **`src/agentic_loop/skill_evals_db.zig`**, next to `agent_memories.zig`
(the established home for a table's SQL). `is_global`-style booleans and every integer are
stringified on bind (`std.fmt.allocPrint(alloc, "{d}", ...)`) and compared on read
(`std.mem.eql(u8, row.values[i], "1")`) — the `design_model.zig:179-187` idiom.
**Every free-text write must be `COALESCE(?, '')`**: `SqliteBackend.exec` binds a
zero-length slice as SQL `NULL` and `NOT NULL` then fails **at runtime**, mid-useCase —
Migration 079's `content` column broke exactly this way, and `source_path`/`error`/`rationale`
are all plausibly empty. Note the asymmetry: `query`/`queryRow` do **not** have the guard,
so `""` is `NULL` in a `WHERE` arg but `''` in a `VALUES` — guard the empty-name path
explicitly.

### 4.8 Applying a verdict

Default **propose-only**: the eval writes rows; a human clicks Apply. `apply_mode` config
values: `off` (never write), `propose` (**default**), `auto_low_risk`.

Apply reuses the **existing** skill write path — `edit_skill` / `remove_skill` / `add_skill`
(or the sibling plan's `skills_db.upsertSkill`/`deleteSkill` after 094) — never a second
writer, so there is exactly one place that touches a `SKILL.MD`. Apply records
`apply_action` + `applied_at` and emits an SSE event so open views refresh.

`auto_low_risk` is deliberately narrow: only `delete` for a skill with ≥ 2 consecutive
`delete` verdicts across ≥ 2 different runs, no `keep` in between, and zero `use` in the
last 30 days. Everything else — including every `update`/`rewrite` — stays human-gated.
Auto-editing a skill body is not a risk this plan takes in v1.

### 4.9 Guards — the part that decides whether this is a feature or a token leak

| Guard | Mechanism | Why |
|---|---|---|
| **No eval-of-eval recursion** | `sessions.is_eval = 1` checked in the T2 hook; eval sessions never enqueue a run | an eval run is itself a task that loads skills |
| **No sub-agent can trigger evals** | `run_skill_eval` is added to `MAIN_AGENT_ONLY_NAMES` (`ask_user.zig:260`), which is simultaneously the parse-time rejection (`spawn_sub_agent.zig:307`), the tool strip (`tool_eligibility.zig:134`), and the progressive-equip bypass — one list, three enforcement points | a fan-out of fan-outs has no bound |
| **Nothing without skills** | hook gate 1: any `session_skill_events` row for the session | most sessions use no skill |
| **Dedupe** | partial unique index `uq_skill_eval_runs_after_task` (096) — a re-run of the same task cannot double-enqueue | the T2 hook can fire more than once for one logical task (queued-message continuation, retries) |
| **Budget** | `max_evals_per_day`, `max_concurrent`, counted with `SELECT COUNT(*) FROM skill_eval_runs WHERE created_at >= date('now')` | a hard ceiling a user can reason about |
| **Blast radius** | `max_skills_per_run` (default 8), `min_skills_used` (default 1), `max_run_minutes` (poller reaper) | one run cannot fan out 20 agents over 300 skills |
| **Opt-in** | `skill_evals.enabled = false` by default | it spends money |
| **No blocking** | the T2 hook only inserts; the poller does all LLM work | `defer` runs during worker teardown |

### 4.10 Config

New `skill_evals` block in `~/.config/nalar/config.json`, mirroring the `SubAgentConfig`
plumbing (`Config.zig:172-197` / `:360-378` / `:867` / `:1014` / `:1396-1412` — struct,
JSON mirror with defaults, parse, dup, profile clone) and exposed through
`GET/PUT /api/nalar/config` (`nalar_config_put.zig:302-343` shape):

```json
"skill_evals": {
  "enabled": false,
  "auto_after_task": false,
  "eval_on": "success_only",
  "min_skills_used": 1,
  "max_skills_per_run": 8,
  "max_evals_per_day": 10,
  "max_concurrent": 1,
  "max_run_minutes": 10,
  "apply_mode": "propose",
  "judge_sub_agent": "",
  "judge_profile": "",
  "include_listed_without_loading": true
}
```

`enabled: false` + `auto_after_task: false` means a fresh install does nothing until the
user turns it on — and the on-demand path (button / `run_skill_eval`) works immediately
without it, because an explicit user request is its own consent.

### 4.11 HTTP surface — a **separate prefix**, on purpose

All routes under `/api/skill-evals/*`, i.e. **not** nested under `/api/skills`. This is a
deliberate dodge of the documented route-order trap: `matchRoute` walks routes in
registration order and `/api/skills/:name` is registered at `main.zig:602`, so any new
literal like `/api/skills/evals` registered after it is captured with `name="evals"`. A
sibling prefix has zero interaction with it. (If a sub-route is ever added under
`/api/skills/`, the in-repo precedent for the correct order is
`…/knowledge/reorder` before `…/knowledge/:knowledge_id` at `main.zig:721-722`.)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/skill-evals/runs` | `{session_id?|skill_name?, scope, apply?}` → `{run_id, status}` |
| `GET` | `/api/skill-evals/runs` | list, filtered by `session_id`/`skill_name`/`status`, paged |
| `GET` | `/api/skill-evals/runs/:run_id` | run + all results + report |
| `POST` | `/api/skill-evals/runs/:run_id/cancel` | cancel queued/running |
| `POST` | `/api/skill-evals/results/:result_id/apply` | `{action:"edit"|"delete"|"keep"}` |
| `GET` | `/api/skill-evals/skills/:skill_name/history` | verdict timeline for one skill |
| `GET` | `/api/skill-evals/summary` | counts by verdict — powers the sidebar badge |

Handlers follow the `agent_knowledge_*` shape: a `useCase(allocator, db, input)` with a
closed error set and two exhaustive `switch`es (status + message) so adding a variant fails
to compile. `nalarcore.getSingleton()` is touched **in the handler only**.

### 4.12 SSE

New routing key `"skill_evals"` in `unified_events_sse.zig:248-273`, and five event names:

`skill_eval_run_created`, `skill_eval_run_started`, `skill_eval_run_completed`,
`skill_eval_run_failed`, `skill_eval_verdict`.

Each must be registered in **all four** places, in the same PR:

1. the Zig emitter's event-type ladder;
2. `src/api/index.ts:3738-3799` `additionalEventTypes` — **missing here = silently dropped**;
3. a dispatch branch in `onEvent` (`api/index.ts:3801+`);
4. `SseEventMap` (`sseBus.ts:25-43`) + `UnifiedChannels` (`api/index.ts:3620-3656`).

Zig side gets a regression test in the `sse_on_event_send_session.zig:209-232` shape pinning
the exact wire strings; the frontend side gets a registry-completeness assertion like
`unifiedSseBuffer.spec.ts:580-720`. **No fallthrough default in the ladder** — that is how
`session_unknown` happened.

### 4.13 Frontend

| Piece | Built from | Notes |
|---|---|---|
| Settings "Evals" tab | `SettingsView.vue:78-121` (4th entry) | reuse the local toast at `:13-20, 120-133` |
| `SkillEvalsSettings.vue` | `SkillsSettings.vue:1-73` master/detail | left = runs + per-skill roll-up; right = report |
| Report view | `SkillDetail.vue` structure | score bars, rationale, evidence list, `proposed_diff` in the existing diff renderer, Apply / Dismiss |
| Verdict badge on skill rows | `WorkspaceItemTaskCard.vue:569-624` pattern | worst-of-last-N verdict, `GET /summary` or per-skill history |
| "Evaluate" button | `SkillDetail.vue` next to Delete | `POST /runs` with `scope: "skill"` |
| Right-sidebar panel | extend the `SidebarPanel` union at `ChatRightSidebar.vue:42` | inherits `?sidebar=evals` deep-link + localStorage — **do not add a second param** |
| Live progress | new `stores/skillEvalsSse.ts` modelled on `kanbanSse.ts:42-323` | "eval 2 of 5" via `BackgroundCommandsPopup.vue`'s pill pattern |
| In-transcript `run_skill_eval` card | `KanbanMove.vue:1-180` + `parseKanbanMove` in `toolOutputParser.ts:652-680` | so "eval my skills" shows its result in chat |
| Tool toggles | `ToolsSection.vue:43-125` + `DEFAULT_CHAT_TOOLS` `api/index.ts:1509-1529` | new tools must be added or they are filtered out of every session |

URL-param rule (repo convention, non-negotiable): extend the view's existing param union,
mount reads it back, clicks write it with `router.replace`. A local `ref` boolean for the
selected tab would break refresh/Back/share.

---

## 5. Task breakdown

Ordered so each task is independently reviewable, and so everything before W9 works
**today**, on the filesystem model, with no dependency on the sibling plan.

- **W0 — Seams (no behaviour).** `src/agentic_loop/skill_evals_db.zig` skeleton + the two
  migrations 095/096 registered after `migration.zig:2006`, with a registration guard test
  in the `migration.zig:6042-6048` shape. Add `skills_read`/`skills_write` accessor helpers
  in one place so W9's swap is a single-file change. Delete nothing; do not fix the
  0-reader `auto_save_skill` here (the sibling plan owns that file's cleanup).
- **W1 — Usage ledger.** Writers at `handle_tool.zig:809-810` for `use_skill` (with
  `loop_index`, `llm_history_id`, `content_hash`) and for `list_skills`
  (per entry, `event='listed'`), plus `add_skill`/`edit_skill`/`remove_skill`.
  `sessions.is_eval` written by the runner in W6.
- **W2 — Repository + report validation.** `skill_evals_db.zig` CRUD, `validateReport()`,
  and the verdict-downgrade rules (§4.5). Pure functions, in-memory DB tests, **no**
  `spawn_sub_agent` yet.
- **W3 — Evidence bundle.** `skill_evals_evidence.zig`: ledger read + `llm_history` join on
  `tool_call_id`/`loop_index` + final message + first user message + `available_skills` +
  transcript excerpt. **Accepts both `{path}` and `{skill_name}` `use_skill` arguments** (§4.3).
- **W4 — Drift pre-pass.** `skill_evals_drift.zig`: path extraction, existence check with
  the `isAbsolute` boundary guard, bounded `git log --since`, structural checks, description
  similarity. **Zero LLM.** This is where "must use the new code" actually comes from.
- **W5 — Prompt + rubric.** `skill_evals_prompt.zig`: the runner instruction, the rubric,
  the output contract, the "you are an eval session" statement, and the negative-space rules
  (do not attempt the original task; do not edit skills in propose mode).
- **W6 — Runner + poller.** `skill_evals_runner.zig` (claim → set `is_eval` → snapshot
  `evidence_json` → `emit_run_agent(skip_initial_queue_message = true)` →
  `updateSessionIsEval`) and `src/schedulers/skill_evals_poller.zig` (`TICK = 5s`,
  `resetStuckRunning` on boot, `claimForRun` via `db.changes() > 0`, reaper for
  `max_run_minutes`, `max_concurrent` gate `isWorkerRunning`). Registered beside the
  routine scheduler in `startup.zig`/`main.zig:297-306`.
- **W7 — The post-task hook.** `run_completed: bool` set at `workflow.zig:1598`; the
  enqueue call inside the `defer` at `workflow.zig:712-724`; `auto_after_task` +
  `eval_on` + all guards from §4.9. **Zero LLM work in the hook.**
- **W8 — Tools.** `run_skill_eval` (main-agent-only — add to
  `MAIN_AGENT_ONLY_NAMES`, `ask_user.zig:260`) and `submit_skill_eval_report` (validates
  the caller is an eval session via `skill_eval_runs.eval_session_id`). Registry +
  `ToolsSection.vue` + `DEFAULT_CHAT_TOOLS`.
- **W9 — Sibling-plan compatibility.** Read `use_skill` arguments in both shapes; route all
  skill reads/writes through the W0 seam so 094's `skills_db` swap is one file. Add a test
  that fails if a third argument shape appears.
- **W10 — HTTP.** The seven `/api/skill-evals/*` routes + `skill_evals` in
  `nalar_config_get`/`put`.
- **W11 — SSE.** Channel + five event names + Zig wire-pinning tests + the four frontend
  registrations.
- **W12 — Frontend.** §4.13 in full, including the URL-param spec and the diff renderer.
- **W13 — Functional + docs.** `tests/functional/skill_evals_test.py` (§6), plus a section
  in `docs/SPEC.md`.

### Test plan per task

| Task | Coverage |
|---|---|
| W0/W1/W2 | in-memory SQLite via `migration.registerAllMigrations` + `runMigrations()` (never hand-rolled `CREATE TABLE` — the convention recorded in `.nalar/memories/llm-history-test-use-migrations-module.md`); partial-unique-index rejection; **`""` binds as `''` not NULL** for `rationale`/`error`/`missing_paths_json`; an unevidenced verdict is rejected; a `delete` without a `high` finding is downgraded |
| W3 | fixture session with assistant `tool_calls_json` + `role='tool'` rows → assert `first_loop_index`, `use_count`, `content_changed_since_use`; **both** `{path}` and `{skill_name}` argument shapes |
| W4 | path extraction on a real SKILL.MD; missing path detected; the `isAbsolute("")` boundary returns a finding instead of aborting (**the PR #639 crash class — a unit test that panics is the failure mode to pin**); a relative path is rejected; `git log --since` bounded and non-blocking on a non-repo cwd |
| W5 | the prompt contains the rubric, the output contract, the eval-session statement, and every skill name from the bundle; **static-contract assert that every `spawn_sub_agent` payload it builds has non-empty `tools`, no `"all"`, no main-agent-only name, an `agent_name`, and ≤ 20 agents** — those are the parse-time rules and a regression must fail at build, not at 3 a.m. |
| W6 | claim atomicity (`db.changes() > 0`); second claim loses; `resetStuckRunning` on boot; reaper marks an orphan `running` run `failed`; `max_concurrent` blocks a second fire |
| W7 | a `.stop` run enqueues exactly one row; a cancelled run enqueues none; an eval session (`is_eval = 1`) enqueues none; `auto_after_task = false` enqueues none; the unique index makes a double-fire a no-op |
| W8 | `run_skill_eval` is rejected at `spawn_sub_agent` parse time for a sub-agent (the `MAIN_AGENT_ONLY_NAMES` test already exists at `tool_eligibility.zig:326` — extend it); `submit_skill_eval_report` from a non-eval session is rejected |
| W10/W11 | **Python functional**, not curl — see §6 |
| W12 | `SidebarEv…`/settings-tab URL spec in the `SidebarDiffPanel.tabs.spec.ts:1-267` shape; SSE registry completeness in the `unifiedSseBuffer.spec.ts:580-720` shape |

---

## 6. Verification — functional tests with a scripted stub LLM

Per the repo's verification rule: **no `nohup nalar --port 8080` + `curl`.** The three
failure modes the rule names are all live here — route order under a new prefix, empty
strings collapsing to SQL NULL mid-useCase, and strict validators rejecting `""`.

`tests/functional/skill_evals_test.py`, on the `harness` fixture (`port=None` → a random
2000-32000 port; **8081 is reserved and must never be used**; isolated tmpdir `HOME` gated
by `is_safe_tmp()`):

1. **The pipeline, end to end, deterministically.** The proven pattern already exists in
   `tests/functional/anthropic_chat_headers_test.py:69-94`: boot the harness, `PUT` a
   profile pointing at a local `ThreadingHTTPServer` stub that returns scripted SSE,
   `POST /api/llm/session` with a `queue_message`, poll until the reply lands. Here the stub
   plays **both** the runner and the eval sub-agents (it returns a canned
   `submit_skill_eval_report` call), so the whole chain — hook → queue row → poller →
   eval session → `spawn_sub_agent` → report → `skill_eval_results` — is asserted without
   a real LLM. The harness's own `stub_llm_profile=True` points at a dead port
   (`harness.py:1206`) and is **not** sufficient; the stub must be a live scripted server.
2. **On-demand route:** `POST /api/skill-evals/runs` → 201, `status:"queued"`, and a
   `GET /api/skill-evals/runs/:id` round-trip.
3. **Route order:** every literal `/api/skill-evals/*` path resolves to its own handler and
   is not swallowed by a `:param` sibling; and `GET /api/skills/:name` is unaffected
   (regression for the §4.11 dodge).
4. **Empty-string trap over the real wire:** a run whose report has
   `rationale: ""`, `error: ""`, `missing_paths_json: ""` persists and reads back `""`
   rather than 500-ing — the case unit tests miss because they never pass `""` through
   `useCase`.
5. **The recursion guard:** an eval session that itself loads a skill does **not** enqueue
   a second run.
6. **Dedupe:** firing the after-task trigger twice for one session yields one row.
7. **Apply:** `POST /results/:id/apply {action:"delete"}` removes the skill via the existing
   path and flips `apply_action`/`applied_at`; a second apply is a no-op.
8. **SSE:** subscribe to `/api/events?channels=skill_evals` and assert the five event names
   arrive with the exact strings pinned by the Zig test (this is the `session_unknown`
   regression class — the browser drops unregistered names, and only a wire test catches a
   name mismatch between the Zig ladder and `additionalEventTypes`).

### Verification gates

```
zig build test --summary all
cd src/apps/desktop && pnpm test:unit
cd src/apps/desktop && pnpm run build          # delete any stray .js next to .ts
zig build install:linux
NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/skill_evals_test.py -v
```

Plus a cross-platform compile check for every touched Zig file. No `// NEW (plan: …)`
comments — comments explain *why*. Then a PR for review.

---

## 7. Cost model — stated honestly, then bounded

One run ≈ 1 runner turn (a large prompt: evidence bundle, so 5-30 K tokens) + N sub-agent
sessions × (system prompt + evidence slice + 1-3 tool turns + a report). For 5 skills that
is roughly **6 sessions and 60-200 K tokens**. A user with `auto_after_task` on and 20
coding tasks a day would spend ~1.5-4 M tokens a day — completely invisible unless the UI
shows it.

So: `skill_eval_runs.total_tokens` is computed at finalize by summing
`llm_history.total_tokens` for `session_id = eval_session_id` **and** every
`parent_session_id = eval_session_id` (the sub-agents), and the Evals UI shows tokens and
an estimated cost per run and per rolling week. `max_evals_per_day` defaults to **10**. The
Tier-0 pre-pass (§4.4) settles trivial cases at zero cost. None of this is optional
polish — an eval feature that cannot tell the user what it costs will be turned off
permanently the first time it surprises them.

---

## 8. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | **Eval-of-eval recursion** — the eval session loads a skill, its teardown enqueues another eval, forever | explicit `sessions.is_eval` flag (not a session-id substring sniff); `run_skill_eval` is main-agent-only so no sub-agent can trigger one; W7 test |
| R2 | **Silent token leak** | `enabled`/`auto_after_task` default false; four budget knobs; `total_tokens` shown in the UI |
| R3 | **An LLM judge deletes a good skill** | propose-only default; `delete` requires a `high` finding; no auto-apply for `update`/`rewrite` in v1; `applied_at`/`apply_action` make accept/reject measurable |
| R4 | **Evidence hallucination** — a confident verdict with invented file:line | `validateReport()` rejects a finding with empty evidence; Tier-0 facts are pre-computed, so freshness is adjudication not recall |
| R5 | **`""` binds as SQL NULL** → `NOT NULL` failure mid-useCase | `COALESCE(?, '')` on every free-text write; dedicated unit + functional test (R1 precedent: Migration 079's `content`) |
| R6 | **Route shadowing** | routes live under a fresh `/api/skill-evals` prefix, never under `/api/skills/` (§4.11); functional test |
| R7 | **SSE event dropped silently** | four-point registration per §4.12 + a Zig wire-string test + a TS registry test in the same PR |
| R8 | **The hook delays worker teardown** | the hook only `INSERT`s; all LLM work is in the poller |
| R9 | **`timeout_seconds` is dead** → a wedged sub-agent blocks the runner forever | do **not** rely on it; the poller reaper marks runs with no live worker and no report as `failed` after `max_run_minutes`. Fixing the dead field is a separate change |
| R10 | **`use_skill` argument shape changes when 094 lands** → evals stop matching skills | extractor accepts `skill_name`, then `path`, then `response_content.skill_name`; W9 test fails on a third shape |
| R11 | **Migration-number collision** with the sibling plan's 094 | this plan takes 095/096; stated in the header and re-checked at W0 |
| R12 | **`cwd` canonicalisation drift** makes a local skill invisible to the drift pre-pass | one `canonicalCwd` helper shared by the evidence builder, the pre-pass, and the HTTP query path — the same trap the sibling plan calls out |
| R13 | **A `*Absolute` call on a non-absolute path aborts the process** (mixed into the pre-pass by a skill that references a relative path) | validate `isAbsolute` at the boundary, reject with a finding, never pass through — the PR #639 crash class |
| R14 | **The after-task trigger fires for a session that never really finished** | `run_completed` is set only at `workflow.zig:1598`; other terminal exits are opt-in via `eval_on = "all_terminal"` |
| R15 | **Two duplicate cards exist for this request** (`task_1790542119154_4` and this one) — a parallel agent may land a competing plan/implementation | land the plan doc as a PR for review before any implementation; the plan names the exact modules so a collision is visible at the file level |

---

## 9. Decision log — resolved here, and what still needs the human

Resolved in this plan (stated so the reviewer can reject them explicitly):

| # | Question | Decision |
|---|---|---|
| 1 | Does the eval run in the task's own session, or a separate one? | **Separate main-agent session** (`is_sub_agent = false`, `sessions.is_eval = 1`). Forced by `tool_eligibility.zig:134` (sub-agents cannot spawn) and by not wanting eval chatter in the user's transcript. |
| 2 | Auto-apply verdicts? | **No.** `apply_mode` default `propose`; only a narrow `delete` case may ever auto-apply, and not in v1. |
| 3 | Config on by default? | **No.** `enabled: false`, `auto_after_task: false`. |
| 4 | Where does the eval get a model? | **Inherit the session profile**; optional `judge_profile`/`judge_sub_agent` override. Zero-config must work. |
| 5 | Where does "must use the new code" come from? | **Tier-0 deterministic pre-pass** (path existence + bounded `git log --since`), adjudicated by the sub-agent — not by asking an LLM to remember the codebase. |
| 6 | New tables, or reuse routines/background processes? | **New tables** (095/096). Routines are time-triggered and mark success at submit time; background processes have no LLM. Only their *loop shape* is reused. |

Still needing a human answer before W6 (these change the build, not the design):

1. **Scope of v1** — session-scoped evals only (recommended), or also a weekly "sweep all
   skills" cron? The sweep is cheap to add on the same queue but roughly 10× the token spend.
2. **Judge model** — may an eval spend tokens on a *different*, cheaper profile than the task
   used, or must it inherit? (Inherit is the safer default; cheap is the better product.)
3. **Migration numbers** — confirm 095/096, given the sibling plan has reserved 094 but has
   not landed.
4. **Auto-apply appetite** — is a narrow `delete`-only auto-apply ever wanted, or should
   `auto_low_risk` be deleted from the config surface entirely to avoid the ambiguity?
5. **`session_skill_events`** — accept the new ledger table (needed for
   `listed_without_loading` and for a stable `content_hash` drift key), or do the eval from
   `llm_history` alone and drop that one dimension?

---

## 10. Explicitly out of scope

- **No `search_skill` / skill search.** Not needed for evals; the sibling plan already
  deferred it.
- **No FTS5 index on eval reports.** The tables are small and always read by `run_id` or
  `skill_name`. Add it only if the UI needs full-text search over rationales.
- **No workflow-blocking gate.** Evals are informational; they do not fail CI, do not block
  a PR, and do not block a kanban column transition. Making a skill's verdict a merge gate
  is a product decision nobody has asked for.
- **No new sub-agent CRUD tool.** `skill-evaluator` is seeded through the existing
  `PUT /api/nalar/config` path.
- **Fixing `timeout_seconds`** (`spawn_sub_agent.zig:319-322`) — real bug, separate change.
- **Fixing the 0-reader `auto_save_skill` flag** and the missing `session_skills` writes for
  `add_skill`/`edit_skill` — the sibling plan's W0 owns that file; this plan's ledger (W1)
  makes those writes observable *without* touching the flag, so the two changes do not
  collide.

---

## Sibling — `docs/plans/2026-09-28-skills-sqlite-table.md`

Read in full before writing this document. Its four decision-log entries are taken as given
(`is_global` on the wire, keep the filesystem mirror, add `tags`, no `path` shim). Three
consequences land here:

1. **Migration 094 is its claim** → this plan takes 095/096 (§8 R11).
2. **`use_skill` moves from `path` to `skill_name`** → the evidence extractor must accept
   both, or evals silently stop matching skills the day 094 lands (§4.3, §8 R10).
3. **It adds `tags`** → the `duplication` dimension can compare tags as well as descriptions
   (currently `tags:` is parsed by nothing; `ParsedFrontmatter` is `{name, description}`
   only, `skills.zig:68`).
