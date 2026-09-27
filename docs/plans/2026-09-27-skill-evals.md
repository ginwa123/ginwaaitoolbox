# Skill Evals — the agent evaluates the skills it used, itself

> **Status:** plan only. Nothing in this document is implemented.
> **Written:** 2026-09-27, revised 2026-09-27 after review feedback, against `HEAD` = `e0d892c9`.
> **Revision:** the trigger is a **system-prompt rule**, not a post-task hook. The agent runs
> the eval itself. This deleted the hook, the scheduler, the eval session, and one tool from
> the first draft (see §11 for the full delta).
> **Sibling plan:** `docs/plans/2026-09-28-skills-sqlite-table.md` — unimplemented, reserves
> Migration 094. This plan therefore takes **095 / 096**.

---

## 1. Goal, in one paragraph

Today a skill is a file the agent may or may not load, and **nothing ever checks whether it
was right**. A skill can describe an API renamed three months ago, duplicate another skill,
or be loaded for a task it has nothing to do with — and the only feedback loop is a human
noticing. This plan adds **Skill Evals**, driven by a new system-prompt rule that tells the
agent: *when you loaded a skill this session, evaluate it before you answer*. The agent calls
one new tool, `run_skill_eval`, which reads the frozen record of which skills this session
actually loaded, runs a **no-LLM deterministic pre-pass** (do the paths the skill names still
exist? what changed since?), then uses the existing sub-agent batch runner to fan out **one
eval sub-agent per skill**. Each scores its skill against a fixed rubric — relevance, whether
the procedure was actually followed, whether it helped, **freshness against today's code**
("must use the new code"), accuracy, duplication — and must back every claim with
machine-checkable evidence. Verdicts, a proposed replacement body, and the evidence land in
SQLite and surface in a new Evals UI. **Nothing is auto-applied.**

---

## 2. The request, decomposed

| What was asked | Mechanism |
|---|---|
| "just put to **system prompt, so the ai agent will run eval self**" | a new `SkillEvalToolRule` prompt constant beside `SkillsToolRule` (`core.zig:167`), appended at `prompts_build_messages_for_agent_prompt.zig:125` — **the exact shape of the `ReadWorkspaceSessionToolRule` precedent added in `d61be32b`** |
| "run evals **on demand**" | `POST /api/skill-evals/runs` + a UI button, in addition to the agent's self-trigger |
| "**the main agent** runs `spawn_sub_agent`" | `run_skill_eval`'s exec calls the **same batch runner** `spawn_sub_agent` uses (`std.Io.Group.concurrent` over `runSubAgent`) — see §4.2 for why code, not the LLM, writes that JSON |
| "the **sub-agents eval the skills**" | one sub-agent per loaded skill, each with its own narrow allowlist and the rubric inline |
| "the skill **is not relevant**" | rubric dimension `relevance`, judged against the task that loaded it |
| "**must use the new code**" | a **deterministic, no-LLM pre-pass** — path existence + bounded `git log --since` (§4.4) — so the sub-agent adjudicates pre-computed facts instead of trying to recall the codebase |
| "based on **the history the main agent used that skill**" | the frozen evidence bundle (§4.3), built from the usage ledger + the `llm_history` tool-call graph |

---

## 3. Verified current state

All line numbers verified in this worktree against `HEAD` = `e0d892c9`.

### 3.1 The prompt-rule precedent exists and is one week old

This is the load-bearing fact for the whole revision. `prompts_build_messages_for_agent_prompt.zig:110-125`:

```zig
// The four "tools the agent must actually use" mandates: the special tool
// (search the catalog for a tool), the special skills (load the skill a
// task needs), memory (load prior context / persist new facts), and
// workspace session history (the past is queryable, not guesswork).
// Unconditional — never gated on hasTool, because a gate keyed on the tool
// list is a per-agent bit in the cacheable prefix, and these rules must
// stay byte-identical across every agent so the block is one cache hit
// rather than N fragments.
try final_system.appendSlice(allocator, prompts_const.ProgressiveToolRule);
try final_system.appendSlice(allocator, prompts_const.SkillsToolRule);
try final_system.appendSlice(allocator, prompts_const.MemoryToolRule);
try final_system.appendSlice(allocator, prompts_const.ReadWorkspaceSessionToolRule);
```

`ReadWorkspaceSessionToolRule` (`core.zig:38-63`) was added days ago in commit `d61be32b`
("feat(prompts): add ReadWorkspaceSessionToolRule to buildMessages (live path)"). It is:
a markdown rule with a `**FOUR BEHAVIORS**` list and a `**Self-check:**` closer; appended
**unconditionally** in the live path; mirrored by a `PROMPT_SECTIONS` entry with
`requires_tool` (`:1206`) purely for documentation; and pinned by two tests —
`prompts_test.zig:1699` "reaches the live prompt, not just PROMPT_SECTIONS" and `:1712`
"names the tool and the four behaviors".

**A skill-eval rule follows that template exactly.** Copy it; invent nothing.

### 3.2 A skill is a file, and nothing records whether it was *used*

- `<root>/<name>/SKILL.MD`; global root `$XDG_CONFIG_HOME/nalar/skills` else
  `$HOME/.config/nalar/skills` (`skills.zig:474`), local root `<cwd>/.nalar/skills`
  (`skills.zig:55`). `SkillInfo` is `{name, description, path}` (`skills.zig:62`).
- `use_skill` takes **`path`**, not `skill_name` (`skill_tools.zig:145-194`).
- **No SQLite `skills` table** — the sibling plan is plan-only. Highest migration is **93**
  (`migration.zig:4964`); the registration list ends at `migration.zig:2006`.

### 3.3 The only usage record is `session_skills`, and it is lossy

`session_skills` (Migration 008, `migration.zig:90-99`) is written **only** by `use_skill` →
`ToolExecResult.skill_save` (`tools_exec_skills.zig:60-67`) → `handle_tool.zig:809-810` →
`saveSkill` (`llm_history.zig:4243`). Gaps that matter:

1. **No `loop_index`** — "which turn loaded this skill" is not stored. `loaded_at_nano` is
   **seconds** despite the name (`llm_history.zig:4340-4343`) and `INSERT OR REPLACE`
   re-stamps it on reload.
2. **`add_skill` / `edit_skill` never write it**, despite carrying `.auto_save_skill = true`
   — that flag has zero readers.
3. **Listed-but-not-loaded is invisible** — `list_skills` returns name/description/path only,
   so a skill that was *offered and ignored* (a real finding) leaves no trace.
4. **No content hash** — drift detection has to re-read and diff rather than compare a key.

### 3.4 The transcript is the enrichment source

`llm_history` (`migration.zig:597-626`, `:656`) has `tool_calls_json` on assistant rows
(`arguments` is a **JSON string inside JSON** — `llm_history.zig:1459-1464`), `loop_index`
(the turn counter), and `role='tool'` rows carrying `tool_name`, `tool_call_id` and
`response_content` = the `UseSkillJSON` with `skill_name` **and the full body**. So the turn
a skill was loaded is fully recoverable from `llm_history` alone; `session_skills` is only
the cheap "did this session use any skill at all" gate.

### 3.5 Sub-agents already do the rest

- `spawn_sub_agent` is a **batch runner**: one call spawns N agents in parallel via
  `std.Io.Group.concurrent` (`tools_exec_spawn_sub_agent.zig:461, 554, 559`), hard cap **20**
  at the parse boundary (`spawn_sub_agent.zig:249`).
- `tools` is a **required, non-empty allowlist** — no omit, no `"all"` (`:277-297`);
  `ask_user` and `spawn_sub_agent` are rejected (`:307`) and stripped again at filter time
  from the single source `MAIN_AGENT_ONLY_NAMES` (`ask_user.zig:260-263`, strip at
  `tool_eligibility.zig:134`, test at `:326`).
- Per-sub-agent results come back as JSON: `{name, success, random_fallback, session_id,
  response, error}` inside `{results: [...], summary: {...}}`
  (`tools_exec_spawn_sub_agent.zig:571-625`). **`response` is the sub-agent's final text** —
  that is the transport for the eval report, so no report-submission tool is needed.
- Live progress already streams over SSE (`subagent_progress.zig:48-60`, `launched|completed|failed`).
- `agent_name` resolves per-profile only (`Config.zig:2194-2253`); a miss is a **random
  fallback**. **`timeout_seconds` is dead** — parsed (`:319-322`), read nowhere.

### 3.6 No eval, rating, or feedback primitive exists

`rg` over `src/**` for `rating|thumbs|feedback|score|verdict|eval` returns only prose in
comments. No table, no endpoint, no component. The structural precedent to copy is
`agent_memories` (Migration 070, `migration.zig:3466-3592`; `src/agentic_loop/agent_memories.zig`).

### 3.7 4.1 `SKILL.MD` parsing and the crash class

`parseYamlFrontmatter` (`skills.zig:87-145`) returns `{name, description}` — **`tags:` is
parsed by nothing** though the prompt mandates it. And the `*Absolute` filesystem family
(`statFileAbsolute`, `openFileAbsolute`, …) asserts `path.isAbsolute(path)` and **aborts the
whole process** on failure — not a catchable error, and `isAbsolute("")` is `false`
(PR #639's crash class). The drift pre-pass will feed paths extracted from LLM-authored text
into exactly that family, so it must validate at the boundary (§4.4).

---

## 4. Target design

### 4.1 Trigger — a prompt rule the agent obeys

A new constant `SkillEvalToolRule` in `src/modules/agent/prompts/core.zig`, beside
`SkillsToolRule` (`core.zig:167-198`), written in the established voice: header, bold framing,
a numbered loop, a `**Self-check:**` closer. It is appended **unconditionally** at
`prompts_build_messages_for_agent_prompt.zig:125`, right after
`prompts_const.ReadWorkspaceSessionToolRule`, for the documented cache reason at `:113-119`.
It is self-gating in its wording, so an agent that does not have the tool simply reads a
no-op section — **do not** wrap it in `hasTool(...)`, which is exactly the cache
fragmentation the comment forbids.

Draft of the rule (final wording is a review item — it is prose shipped to every agent):

```
## Skill Evals — evaluate the skill you used, before you answer

**A skill is only worth what it is worth today.** After you finish a task in which you
loaded at least one skill with `use_skill`, call `run_skill_eval` ONCE before your final
message. It reads the record of what this session actually loaded — you do not pass the
skill list, so you cannot cherry-pick — and spawns one eval sub-agent per skill to check
relevance, whether the procedure was followed, whether it helped, whether the paths and
commands it names still exist in the code as it is now, and whether another skill already
covers it.

- **Skip it** when you loaded no skill, or when `run_skill_eval` is not in your tool list.
- **Once per task.** A second call is a cheap no-op, not a second eval.
- **You are not the judge.** The sub-agents produce the verdicts; do not pre-judge or
  argue with them.
- **Report it in one line** in your final message, e.g. "Evaluated 3 skills — 1 needs
  updating (`foo`)". If a skill came back `needs_human`, say so.

**Self-check:** "did I load a skill and forget to evaluate it?" If yes, call
`run_skill_eval` now.
```

### 4.2 One tool does the work — synchronous, in-session

`run_skill_eval` is the **only** new tool. Its exec:

1. **Resolve the target set from code, not from the agent** — the ledger/`session_skills`
   rows for `ctx.session_id`. This is what stops the agent from silently omitting the skill
   it worked around. `{}` = all loaded skills; `{skill_name}` = one (for the UI's per-skill
   button).
2. **Dedupe** — if a run already exists for `(session_id, 'self_prompt')`, return the stored
   summary instead of re-running.
3. **Tier-0 pre-pass** (§4.4) — instant, no tokens. If every finding is deterministic and
   none is `severity: high`, settle the run with **zero sub-agents**.
4. **INSERT** a `skill_eval_runs` row (`status='running'`, `trigger='self_prompt'`).
5. **Build one sub-agent per skill**: instruction = rubric + that skill's evidence slice;
   `tools` = `["read_file","search","glob","list_directory","command","list_skills","use_skill"]`.
6. **Fan out through the shared batch runner** — the same `runSubAgent` +
   `std.Io.Group.concurrent` path `spawn_sub_agent` uses, so `parent_session_id` links the
   sub-agents to this session, `subagent_progress` SSE streams "eval 2 of 3" for free, and the
   ≤20 / non-empty-allowlist / no-main-agent-only-names rules are enforced by code instead of
   by an LLM writing JSON.
7. **Collect** each `results[].response`, parse as JSON, run `validateReport()` (§4.5),
   downgrade what fails, persist `skill_eval_results`.
8. **Finalize** the run (`status='done'`, `total_tokens` summed exactly over the returned
   `session_id`s — the envelope hands them back) and **return a compact summary** the agent
   can quote: `{evaluated, verdicts: {keep: 2, update: 1}, needs_attention: [...], run_id}`.

**Why the fan-out is code, not the LLM writing a `spawn_sub_agent` call** (it is worth being
explicit, since "the main agent runs `spawn_sub_agent`" is the ask): the *effect* is
identical — same session, same concurrency, same sub-agent sessions with
`parent_session_id`. The difference is only who writes the JSON. Handing that to the model
means asking it to produce ≤20 well-formed nested payloads with a non-empty allowlist each
and no main-agent-only names — precisely the parse rules §3.5 shows are easy to violate and
that only wire tests catch. The plan therefore keeps the semantics and puts the serialization
in code. Extracting the batch runner out of `tools_exec_spawn_sub_agent.zig` into a shared
function used by both callers is its own reviewed task (§5 W4).

**Synchronous, not queued.** The tool blocks until the sub-agents finish, exactly as
`spawn_sub_agent` already does. The cost is latency on the agent's final message; the
benefit is no scheduler, no claim/reaper state machine, no crash-recovery path, no
"queued-but-never-ran" rows, and no separate eval session. §11 records what this removed and
§8 R2 records the escape hatch if blocking proves painful.

### 4.3 The evidence bundle

`src/agentic_loop/skill_evals_evidence.zig` builds one frozen JSON document per run, stored
in `skill_eval_runs.evidence_json`, sliced per skill into each sub-agent's instruction:

```json
{
  "schema": 1,
  "run_id": "skilleval_1790542201041721153",
  "evaluated": {
    "session_id": "task_1790542158293_5", "task_id": "task_1790542158293_5",
    "workspace_item_id": "item_1788811112791088699", "item_type": "kanban",
    "cwd": "/home/ginwa/ginwaaitoolbox", "finish_reason": "stop",
    "final_message": "...the assistant's last message...",
    "user_intent": "...the session's first user message, truncated to 2 KB..."
  },
  "skills": [{
    "name": "ginwaaitoolbox-resolve-pr-conflict",
    "scope": "global",
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
  "deterministic_findings": [{ "dimension": "stale_path", "severity": "high",
                              "claim": "referenced path does not exist",
                              "path": "src/ai_workflow/tui/agentic_loop/workflow.zig" }]
}
```

`transcript_excerpt` is deliberately **not** included: the sub-agent has
`read_workspace_session` and can pull the turns it needs, and a 200 KB prompt is not a
feature. What it does get is the `loop_index` anchors, so the read is targeted.

**Cross-plan hazard.** `use_calls[].arguments` is `{path: ...}` today, but the sibling plan
(§4.7 there) deletes `path` and makes `use_skill` take `skill_name`. The extractor must accept
**both** shapes — `skill_name`, then `path` basename, then `response_content.skill_name` as
the authority — or evals silently stop matching the day 094 lands. W8 owns the switch-on case.

### 4.4 Tier 0 — the deterministic pre-pass (no LLM, no tokens)

`src/agentic_loop/skill_evals_drift.zig`, run before any sub-agent exists:

1. **Path extraction** — a conservative tokeniser over the skill body for path-shaped and
   `file:line`-shaped tokens. Conservative on purpose: a false positive becomes a false
   "stale path" finding. Cap at 50 paths per skill.
2. **Existence check** — resolve against the session `cwd`, then `statFileAbsolute` /
   `accessAbsolute`. **Validate `isAbsolute` at the boundary and turn a relative or empty
   token into a finding** — never pass it through (§3.7's abort-the-process class).
3. **Drift by git history** — for the referenced paths: `git -C <cwd> log --oneline
   --since=<loaded_at ISO> -- <paths>`. Bounded: `std.process.spawn` (the codebase is
   uniformly on `spawn`, not `Child.run`), `wait_pid_bounded` (`shell.zig:164`), 3 s deadline,
   capped output. **This is the "must use the new code" mechanism** — it produces the commit
   list; the sub-agent decides whether those commits invalidate the skill.
4. **Structural checks** — frontmatter parses; `name:` kebab-case; `description:` present and
   ≤ 200 chars; body ≤ `MAX_SKILLS_SIZE` (100 KB, `skills.zig:7`); name collision and a cheap
   trigram/Jaccard description similarity → the `duplication` signal.

If the only findings are deterministic and none is `severity: high`, the run settles at
**zero token cost**. Build this first: it is fully unit-testable and it makes the feature
useful on the cheapest, most common cases (a skill naming a file that no longer exists).

### 4.5 Tier 1 — the rubric and the strict output contract

Each eval sub-agent's instruction carries: the role statement, its skill's evidence slice,
the rubric verbatim, and the output contract. Its **final message must be the report JSON**
(no tool needed — §3.5's `response` field is the transport).

Each dimension is scored **0-3** with a mandatory evidence pointer:

| Dimension | Question | Evidence it must cite |
|---|---|---|
| `relevance` | Did this skill match the task it was loaded for? | the user intent + the turn that loaded it |
| `used` | Was the procedure followed, or loaded and ignored? | transcript tool calls |
| `helpfulness` | Did following it help, or mislead? | the outcome / final message |
| `freshness` | **Do the paths, symbols and commands it names still exist and behave as described?** | `deterministic_findings` + `drift_commits` + its own `read_file`/`search`/`command` checks |
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

`validateReport()` runs in Zig and is never bypassed: verdict ∈ enum; scores ∈ 0..3;
confidence ∈ 0..1; every finding has non-empty `evidence`; `proposed_content` non-empty for
`update`/`rewrite`; `merge_target` exists; **a `delete` without a `high` finding is
downgraded to `needs_human`**. A sub-agent whose final message does not parse as JSON, or
fails validation, is stored as `needs_human` with the raw text preserved in `rationale` —
never silently dropped, and never trusted. An unevidenced verdict is the most damaging
failure mode of an LLM judge, so it is rejected structurally.

### 4.6 Storage — Migrations **095** and **096**

Conventions copied from the repo: one statement per `db.exec` (`sqlite3_prepare_v2` compiles
only the first); `CREATE TABLE/INDEX IF NOT EXISTS`; `DATETIME DEFAULT CURRENT_TIMESTAMP` set
in SQL, never bound from Zig; **TEXT ids** from
`std.Io.Timestamp.now(io, .real).nanoseconds`; no foreign keys (`PRAGMA foreign_keys` is off
project-wide); register in `registerAllMigrations` after the Migration093 entry at
`migration.zig:2006`.

#### Migration 095 — the usage ledger

```sql
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
```

Writers: `handle_tool.zig`, beside the existing `SaveSkill` call at `:809-810` — one row for
`use_skill`, one per entry returned by `list_skills` (that is what makes
`listed_without_loading` observable), one each for `add_skill`/`edit_skill`/`remove_skill`.
**Additive**: `session_skills` keeps its writers untouched and remains the compaction drift
detector.

#### Migration 096 — runs and results

```sql
CREATE TABLE IF NOT EXISTS skill_eval_runs (
  id              TEXT PRIMARY KEY,
  session_id      TEXT NOT NULL DEFAULT '',   -- the session whose skills were evaluated
  skill_name      TEXT NOT NULL DEFAULT '',   -- '' = every loaded skill
  scope           TEXT NOT NULL DEFAULT 'session',    -- 'session' | 'skill'
  trigger         TEXT NOT NULL DEFAULT 'self_prompt',-- 'self_prompt' | 'on_demand'
  status          TEXT NOT NULL DEFAULT 'running',    -- running|done|failed|skipped
  profile         TEXT NOT NULL DEFAULT '',
  model           TEXT NOT NULL DEFAULT '',
  cwd             TEXT NOT NULL DEFAULT '',
  evidence_json   TEXT NOT NULL DEFAULT '',
  sub_session_ids_json TEXT NOT NULL DEFAULT '',      -- exact cost attribution
  report_json     TEXT NOT NULL DEFAULT '',
  total_tokens    INTEGER NOT NULL DEFAULT 0,
  error           TEXT NOT NULL DEFAULT '',
  started_at      DATETIME, finished_at DATETIME,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_skill_eval_runs_session ON skill_eval_runs(session_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_eval_runs_self_prompt
  ON skill_eval_runs(session_id, trigger) WHERE trigger = 'self_prompt';

CREATE TABLE IF NOT EXISTS skill_eval_results (
  id              TEXT PRIMARY KEY,
  run_id          TEXT NOT NULL,
  skill_name      TEXT NOT NULL,
  session_id      TEXT NOT NULL DEFAULT '',
  status          TEXT NOT NULL DEFAULT 'pending', -- pending|done|failed|needs_human
  verdict         TEXT NOT NULL DEFAULT 'needs_human',
  relevance       INTEGER NOT NULL DEFAULT 0,
  used            INTEGER NOT NULL DEFAULT 0,
  helpfulness     INTEGER NOT NULL DEFAULT 0,
  freshness       INTEGER NOT NULL DEFAULT 0,
  accuracy        INTEGER NOT NULL DEFAULT 0,
  duplication     INTEGER NOT NULL DEFAULT 0,
  confidence      REAL NOT NULL DEFAULT 0,
  content_at_use  TEXT NOT NULL DEFAULT '',
  content_hash_at_use TEXT NOT NULL DEFAULT '',
  missing_paths_json TEXT NOT NULL DEFAULT '',
  drift_commits_json TEXT NOT NULL DEFAULT '',
  proposed_content TEXT NOT NULL DEFAULT '',
  proposed_diff   TEXT NOT NULL DEFAULT '',
  evidence_json   TEXT NOT NULL DEFAULT '',
  rationale       TEXT NOT NULL DEFAULT '',
  sub_session_id  TEXT NOT NULL DEFAULT '',
  applied_at      DATETIME,
  apply_action    TEXT NOT NULL DEFAULT '',       -- 'edit'|'delete'|'keep'|''
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_skill_eval_results_run ON skill_eval_results(run_id);
CREATE INDEX IF NOT EXISTS idx_skill_eval_results_skill ON skill_eval_results(skill_name, created_at DESC);
```

`applied_at` + `apply_action` exist so the eval can itself be scored — did the human accept
the verdict? That is the only honest way to calibrate a judge, and it costs two columns.

Repository: **`src/agentic_loop/skill_evals_db.zig`**, next to `agent_memories.zig`. Integers
and booleans are stringified on bind (`std.fmt.allocPrint(alloc, "{d}", ...)`) and compared on
read (`std.mem.eql(u8, row.values[i], "1")`) — the `design_model.zig:179-187` idiom.
**Every free-text write must be `COALESCE(?, '')`**: `SqliteBackend.exec` binds a zero-length
slice as SQL `NULL` and `NOT NULL` then fails **at runtime, mid-useCase** — Migration 079's
`content` column broke exactly this way, and `rationale`/`error`/`missing_paths_json` are all
plausibly empty. Note the asymmetry: `query`/`queryRow` do **not** have the guard, so `""` is
`NULL` in a `WHERE` arg but `''` in `VALUES` — guard the empty-name path explicitly.

### 4.7 Guards

| Guard | Mechanism | Why |
|---|---|---|
| **No recursion** | `run_skill_eval` goes into `MAIN_AGENT_ONLY_NAMES` (`ask_user.zig:260`) — one list, three enforcement points (parse rejection at `spawn_sub_agent.zig:307`, the strip at `tool_eligibility.zig:134`, the progressive-equip bypass) — and it is absent from every eval sub-agent's allowlist | a fan-out of fan-outs has no bound |
| **No cherry-picking** | the tool reads the skill set from the ledger for `ctx.session_id`; the agent passes nothing | the agent must not be able to omit the skill it worked around |
| **Idempotent** | partial unique index `uq_skill_eval_runs_self_prompt`; a repeat call returns the stored summary | the rule says "once", but an LLM will sometimes call twice; a duplicate must be free, not a second eval |
| **Bounded fan-out** | `max_skills_per_run` (default 8) — above it, prioritise by `use_count desc, first_loop_index asc` and record the rest as `skipped` | one run cannot fan out 20 agents over 300 skills |
| **Budget** | `max_evals_per_day`; denied runs return a clear message instead of silently doing nothing | a ceiling the user can reason about |
| **No blocking, no surprise** | synchronous but bounded; `subagent_progress` SSE shows "eval 2 of 3"; `total_tokens` in the summary the agent quotes | the user should see the cost of what just happened |
| **Opt-out** | removing `run_skill_eval` from the tool list is the off switch (§4.8) | no new config flag needed to disable it |

### 4.8 Config — the allowlist *is* the on/off switch

Because the rule is a static constant, the trigger is gated the way every other tool is
gated in this repo: **the tool must be in the agent's tool list**. `run_skill_eval` is added
to `DEFAULT_CHAT_TOOLS` (`api/index.ts:1509-1529`) and categorised in
`ToolsSection.vue:43-125` (`eval: 'Skills'`), so a user turns evals off by toggling the tool
off — the same gesture as every other tool, no new concept. For a `kanban`/`design`/`agent`
workspace item, the per-item `agent_tools` allowlist decides (secure-by-default: an empty
list means zero tools, `agent_tools_allowed.zig:37-83`).

Config therefore shrinks to the cost knobs only:

```json
"skill_evals": {
  "max_skills_per_run": 8,
  "max_evals_per_day": 10,
  "judge_sub_agent": "",
  "judge_profile": "",
  "apply_mode": "propose",
  "include_listed_without_loading": true
}
```

`apply_mode`: `off` (never write) | `propose` (**default**) | `auto_low_risk`. Mirror the
`SubAgentConfig` plumbing (`Config.zig:172-197` / `:360-378` / `:867` / `:1014` /
`:1396-1412`) and expose via `GET/PUT /api/nalar/config` (`nalar_config_put.zig:302-343`).

### 4.9 Applying a verdict

Default **propose-only**: a human clicks Apply. Apply reuses the **existing** skill write path
— `edit_skill` / `remove_skill` / `add_skill` (or the sibling plan's
`skills_db.upsertSkill`/`deleteSkill` after 094) — never a second writer, so exactly one place
touches a `SKILL.MD`. Apply records `apply_action` + `applied_at` and emits an SSE event so
open views refresh.

`auto_low_risk` is deliberately narrow: only `delete`, only for a skill with ≥ 2 consecutive
`delete` verdicts across ≥ 2 different runs, no `keep` in between, and zero `use` in 30 days.
Every `update`/`rewrite` stays human-gated. Auto-editing a skill body is not a risk this plan
takes in v1.

### 4.10 HTTP surface — a **separate prefix**, on purpose

All under `/api/skill-evals/*`, **not** nested under `/api/skills`. This dodges the documented
route-order trap: `matchRoute` walks routes in registration order and `/api/skills/:name` is
registered at `main.zig:602`, so a literal `/api/skills/evals` registered after it is captured
with `name="evals"`. A sibling prefix has zero interaction with it. (Precedent for the correct
order if a sub-route is ever added under `/api/skills/`: `…/knowledge/reorder` before
`…/knowledge/:knowledge_id`, `main.zig:721-722`.)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/skill-evals/runs` | `{session_id, skill_name?, apply?}` → the summary (the UI button path) |
| `GET` | `/api/skill-evals/runs` | list, filtered by `session_id`/`skill_name`/`status`, paged |
| `GET` | `/api/skill-evals/runs/:run_id` | run + all results + report |
| `POST` | `/api/skill-evals/results/:result_id/apply` | `{action:"edit"|"delete"|"keep"}` |
| `GET` | `/api/skill-evals/skills/:skill_name/history` | verdict timeline for one skill |
| `GET` | `/api/skill-evals/summary` | counts by verdict — powers the sidebar badge |

Handlers follow the `agent_knowledge_*` shape: `useCase(allocator, db, input)` with a closed
error set and two exhaustive `switch`es (status + message) so adding a variant fails to
compile. `nalarcore.getSingleton()` is touched **in the handler only**.

### 4.11 SSE

New routing key `"skill_evals"` in `unified_events_sse.zig:248-273`, and three event names:
`skill_eval_run_started`, `skill_eval_run_completed`, `skill_eval_run_failed`. The per-skill
verdicts ride inside the completed payload — no separate event. Sub-agent progress needs
nothing new (it already streams on `subagent_progress`).

Each name must be registered in **all four** places in the same PR: the Zig emitter's
event-type ladder; `api/index.ts:3738-3799` `additionalEventTypes` (**missing here = silently
dropped by the browser**); a dispatch branch in `onEvent` (`:3801+`); and `SseEventMap`
(`sseBus.ts:25-43`) + `UnifiedChannels` (`api/index.ts:3620-3656`). Pin the wire strings with
a Zig test in the `sse_on_event_send_session.zig:209-232` shape and a TS registry test like
`unifiedSseBuffer.spec.ts:580-720`. **No fallthrough default** — that is how `session_unknown`
happened.

### 4.12 Frontend

| Piece | Built from | Notes |
|---|---|---|
| Settings "Evals" tab | `SettingsView.vue:78-121` (4th entry) | reuse the local toast at `:13-20, 120-133` |
| `SkillEvalsSettings.vue` | `SkillsSettings.vue:1-73` master/detail | left = runs + per-skill roll-up; right = report |
| Report view | `SkillDetail.vue` structure | score bars, rationale, evidence list, `proposed_diff` in the existing diff renderer, Apply / Dismiss |
| Verdict badge on skill rows | `WorkspaceItemTaskCard.vue:569-624` pattern | worst-of-last-N verdict |
| "Evaluate" button | `SkillDetail.vue` next to Delete | `POST /runs` with `skill_name` |
| Right-sidebar panel | extend the `SidebarPanel` union at `ChatRightSidebar.vue:42` | inherits `?sidebar=evals` deep-link + localStorage — **never a second param** |
| Live state | `stores/skillEvalsSse.ts` modelled on `kanbanSse.ts:42-323` | plus the existing sub-agent progress pill (`BackgroundCommandsPopup.vue`) |
| In-transcript card | `KanbanMove.vue:1-180` + `parseKanbanMove` (`toolOutputParser.ts:652-680`) | so the run and its verdicts are visible where they happened |
| Tool registration | `ToolsSection.vue:43-125` + `DEFAULT_CHAT_TOOLS` `api/index.ts:1509-1529` | missing here = filtered out of every session |

URL-param rule (repo convention): extend the view's existing param union, mount reads it
back, clicks write it with `router.replace`. A local `ref` boolean would break
refresh/Back/share.

---

## 5. Task breakdown

Ordered so each task is independently reviewable and everything works on today's filesystem
model with **no** dependency on the sibling plan.

- **W0 — Migration 095 + 096.** Tables above, registered after `migration.zig:2006`, with a
  registration guard test in the `migration.zig:6042-6048` shape.
- **W1 — Usage ledger.** Writers at `handle_tool.zig:809-810` for `use_skill` (with
  `loop_index`, `llm_history_id`, `content_hash`) and `list_skills` (per entry,
  `event='listed'`), plus `add_skill`/`edit_skill`/`remove_skill`.
- **W2 — Repository + validation.** `skill_evals_db.zig` CRUD, `validateReport()`, the
  downgrade rules (§4.5). Pure functions, in-memory DB tests, no spawning.
- **W3 — Evidence bundle.** `skill_evals_evidence.zig`: ledger + `llm_history` join on
  `tool_call_id`/`loop_index` + final and first user messages + `available_skills` +
  per-skill slicing. **Accepts both `{path}` and `{skill_name}` `use_skill` arguments.**
- **W4 — Shared batch runner.** Extract `runSubAgent` + the `std.Io.Group.concurrent`
  loop out of `tools_exec_spawn_sub_agent.zig:413-630` into a reusable function; both
  `execSpawnSubAgent` and `execRunSkillEval` call it. Pure refactor — the existing
  static-contract tests at `:660-792` must keep passing unchanged.
- **W5 — Drift pre-pass.** `skill_evals_drift.zig`: path extraction, existence check with the
  `isAbsolute` boundary guard, bounded `git log --since`, structural checks, description
  similarity. **Zero LLM.** This is where "must use the new code" comes from.
- **W6 — Prompt rule.** `SkillEvalToolRule` in `core.zig` beside `SkillsToolRule`; appended
  at `prompts_build_messages_for_agent_prompt.zig:125`; re-exported in `prompts.zig` and
  `modules/agent/prompts.zig`; `PROMPT_SECTIONS` entry with `requires_tool` (`:1206` shape);
  tests mirroring `prompts_test.zig:1699` (reaches the live prompt) and `:1712` (names the
  tool and its behaviors).
- **W7 — The tool.** `run_skill_eval`: resolve from the ledger, dedupe, Tier-0, build
  instructions, fan out via W4, validate, persist, finalize, return the summary. Registered
  in `UNIFIED_TOOL_REGISTRY`, added to `MAIN_AGENT_ONLY_NAMES`, `ToolsSection.vue`,
  `DEFAULT_CHAT_TOOLS`.
- **W8 — Sibling-plan compatibility.** Read `use_skill` arguments in both shapes; route all
  skill reads/writes through one accessor module so 094's `skills_db` swap is a single-file
  change; add a test that fails on a third argument shape.
- **W9 — HTTP + config.** The six `/api/skill-evals/*` routes + the `skill_evals` config block.
- **W10 — SSE.** Channel + three event names + the four registrations + the pinning tests.
- **W11 — Frontend.** §4.12 in full, including the URL-param spec and the diff renderer.
- **W12 — Functional + docs.** `tests/functional/skill_evals_test.py` (§6) and a section in
  `docs/SPEC.md`.

### Test plan per task

| Task | Coverage |
|---|---|
| W0/W1/W2 | in-memory SQLite via `migration.registerAllMigrations` + `runMigrations()` — never hand-rolled `CREATE TABLE` (the convention recorded in `.nalar/memories/llm-history-test-use-migrations-module.md`); the partial unique index rejects a second `self_prompt` run; **`""` binds as `''`, not NULL**, for `rationale`/`error`/`missing_paths_json`; an unevidenced verdict is rejected; a `delete` without a `high` finding is downgraded |
| W3 | fixture session with assistant `tool_calls_json` + `role='tool'` rows → assert `first_loop_index`, `use_count`, `content_changed_since_use`, `listed_without_loading`; **both** `{path}` and `{skill_name}` argument shapes |
| W4 | the extracted runner is behaviour-identical: existing `spawn_sub_agent` tests pass unchanged; a batch of 3 runs concurrently; `error.ConcurrencyUnavailable` on a bare blocking `Io` is still surfaced, not swallowed |
| W5 | path extraction on a real SKILL.MD; a missing path is detected; **the `isAbsolute("")` boundary returns a finding instead of aborting the process** (the PR #639 class — a test that panics *is* the failure being pinned); a relative path is rejected; `git log --since` is bounded and does not hang on a non-repo cwd |
| W6 | the rule reaches the live prompt (not just `PROMPT_SECTIONS`); it names the tool and the skip/once/no-pre-judging behaviors; **it is appended unconditionally** — a test asserting it is *not* inside a `hasTool(...)` branch, because gating it fragments the cacheable prefix |
| W7 | dedupe: a second call returns the stored summary and spawns nothing; the skill set comes from the ledger, not the args (a call passing a skill the session never loaded is ignored/rejected); a sub-agent whose final message is not JSON lands as `needs_human` with the raw text preserved; `total_tokens` equals the sum over the returned sub-session ids |
| W7 | **static-contract assert that the built sub-agent payloads have non-empty `tools`, no `"all"`, no main-agent-only name, an `agent_name`, and ≤ 20 agents** — the parse-time rules from `spawn_sub_agent.zig:277-297`, `:307`, `:249`. A regression must fail at build, not at 3 a.m. |
| W9/W10 | **Python functional**, not curl — §6 |
| W11 | the settings-tab/panel URL spec in the `SidebarDiffPanel.tabs.spec.ts:1-267` shape; SSE registry completeness like `unifiedSseBuffer.spec.ts:580-720` |

---

## 6. Verification — functional tests with a scripted stub LLM

Per the repo's rule: **no `nohup nalar --port 8080` + `curl`.** All three named failure modes
are live here — route order under a new prefix, empty strings collapsing to SQL NULL
mid-useCase, and strict validators rejecting `""`.

`tests/functional/skill_evals_test.py`, on the `harness` fixture (`port=None` → a random
20000-32000 port; **8081 is reserved, never used**; isolated tmpdir `HOME` gated by
`is_safe_tmp()`):

1. **The whole pipeline, deterministically.** The pattern already exists in
   `tests/functional/anthropic_chat_headers_test.py:69-94`: boot the harness, `PUT` a profile
   pointing at a local `ThreadingHTTPServer` stub returning scripted SSE, `POST
   /api/llm/session` with a `queue_message`, poll until the reply lands. Here the stub plays
   both the task agent (it emits a `run_skill_eval` tool call) and the eval sub-agents (they
   return canned report JSON), so hook→ledger→Tier-0→fan-out→validate→persist is asserted
   without a real LLM. The harness's own `stub_llm_profile=True` points at a dead port
   (`harness.py:1206`) and is **not** sufficient; the stub must be a live scripted server.
2. **Tier-0 settles with zero sub-agents** when the only finding is a missing path — assert
   the run is `done`, a result row exists with `freshness` low, and the stub received **no**
   sub-agent completion request.
3. **Route order:** every literal `/api/skill-evals/*` path resolves to its own handler and is
   not swallowed by a `:param` sibling; `GET /api/skills/:name` is unaffected.
4. **The empty-string trap over the real wire:** a report with `rationale: ""`,
   `error: ""`, `missing_paths_json: ""` persists and reads back `""` rather than 500-ing —
   the case unit tests miss because they never pass `""` through a `useCase`.
5. **Dedupe:** two `run_skill_eval` calls in one session produce one run and the second
   returns the stored summary.
6. **No recursion:** an eval sub-agent given `run_skill_eval` in its allowlist cannot call
   it (`MAIN_AGENT_ONLY_NAMES` parse rejection at `spawn_sub_agent.zig:307`).
7. **Apply:** `POST /results/:id/apply {action:"delete"}` removes the skill via the existing
   path and flips `apply_action`/`applied_at`; a second apply is a no-op.
8. **SSE:** subscribe to `/api/events?channels=skill_evals` and assert the three event names
   arrive with the exact strings the Zig test pins — the `session_unknown` regression class,
   which only a wire test catches.

### Verification gates

```
zig build test --summary all
cd src/apps/desktop && pnpm test:unit
cd src/apps/desktop && pnpm run build
zig build install:linux
NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/skill_evals_test.py -v
```

Plus a cross-platform compile check for every touched Zig file. No `// NEW (plan: …)`
comments — comments explain *why*. Then a PR for review.

---

## 7. Cost model

One run ≈ the Tier-0 pre-pass (free) + N eval sub-agents × (system prompt + a small evidence
slice + 1-3 tool turns + a report). For 3 skills that is roughly **3 sessions, 20-60 K
tokens**, and Tier-0 settles the trivial cases at zero. The tool returns the verdict counts
and the token total in its summary, so the agent quotes the cost to the user in its final
message; `skill_eval_runs.total_tokens` records it per run, summed exactly over the returned
sub-session ids. `max_evals_per_day` (10) and `max_skills_per_run` (8) bound it. An eval
feature that cannot tell the user what it just cost will be turned off the first time it
surprises them.

---

## 8. Risks

| # | Risk | Assessment / mitigation |
|---|---|---|
| R1 | **The agent simply does not call the tool.** Compliance is best-effort — this is the price of prompt-driven, and the repo already lives with it (the kanban "move your card" mandate is prompt-only and nothing enforces it). | **Accepted.** A missed eval is a missing eval, not a broken feature. The rule is phrased in the same voice as the other `MANDATORY` rules and has a `**Self-check:**`; the rule states "you loaded no skill → skip", so a skip is usually *correct*. The on-demand UI/HTTP path guarantees a way to eval regardless. If compliance proves bad in practice, the async arm is additive (see R2). |
| R2 | **The agent's final answer waits for the fan-out.** | Bounded by `max_skills_per_run` (8) and culled by Tier-0; the existing `subagent_progress` SSE shows progress. `spawn_sub_agent` already imposes exactly this latency for up to 20 agents, so it is an accepted pattern. **Escape hatch, no schema change needed:** the run row already has a `status`, so a future poller can pick up `running`/queued rows and drain them out-of-band. |
| R3 | **Self-assessment bias** — the agent judges the skill it chose. | The agent decides *whether* and *when*, never *what* (the tool reads the ledger) and never the *verdict* (fresh sub-agents judge from a frozen bundle). Residual bias is limited to under-triggering, which R1 already covers. |
| R4 | **An LLM judge deletes a good skill.** | propose-only default; `delete` requires a `high` finding; no auto-apply for `update`/`rewrite` in v1; `applied_at`/`apply_action` make accept/reject measurable. |
| R5 | **Evidence hallucination** — a confident verdict with an invented file:line. | `validateReport()` rejects a finding with empty evidence; Tier-0 facts are pre-computed, so freshness is adjudication, not recall. |
| R6 | **`""` binds as SQL NULL** → `NOT NULL` failure mid-useCase. | `COALESCE(?, '')` on every free-text write; dedicated unit + functional test (precedent: Migration 079's `content`). |
| R7 | **Route shadowing.** | routes live under a fresh `/api/skill-evals` prefix, never under `/api/skills/` (§4.10); functional test. |
| R8 | **SSE event dropped silently.** | four-point registration per §4.11 + a Zig wire-string test + a TS registry test in the same PR. |
| R9 | **`timeout_seconds` is dead** → a wedged sub-agent blocks the tool call. | do **not** rely on it. The bound is `max_skills_per_run` plus the fact that a wedged sub-agent wedges `spawn_sub_agent` too — a pre-existing condition, not one this feature introduces. Fixing the dead field is a separate change. |
| R10 | **`use_skill` argument shape changes when 094 lands** → evals stop matching skills. | extractor accepts `skill_name`, then `path`, then `response_content.skill_name`; W8 test fails on a third shape. |
| R11 | **Migration-number collision** with the sibling plan's 094. | this plan takes 095/096; stated in the header and re-checked at W0. |
| R12 | **`cwd` canonicalisation drift** hides a local skill from the pre-pass. | one `canonicalCwd` helper shared by the evidence builder, the pre-pass and the HTTP query path. |
| R13 | **A `*Absolute` call on a non-absolute path aborts the process** — the pre-pass feeds LLM-authored paths into that family. | validate `isAbsolute` at the boundary, turn a bad token into a finding, never pass it through (§3.7, PR #639). |
| R14 | **The prompt rule fragments the cacheable prefix** if someone "helpfully" gates it on `hasTool`. | the rule is appended unconditionally next to `ReadWorkspaceSessionToolRule`, and W6 gets a test asserting it is not inside a `hasTool` branch (the rationale is written in the code comment at `prompts_build_messages_for_agent_prompt.zig:113-119`). |
| R15 | **A duplicate card exists** (`task_1790542119154_4`, in progress) for this same request. | landed as a reviewable plan first; the plan names exact modules so a collision is visible at the file level. |

---

## 9. Decision log

Resolved in this plan:

| # | Question | Decision |
|---|---|---|
| 1 | Hook in the workflow, or a prompt rule? | **Prompt rule.** Revised on review feedback: the agent runs the eval itself, following the `ReadWorkspaceSessionToolRule` precedent. |
| 2 | Who writes the `spawn_sub_agent` JSON? | **Code**, inside `run_skill_eval`, reusing the extracted batch runner. Same semantics, none of the malformed-payload risk. |
| 3 | Synchronous or queued? | **Synchronous.** Removes the scheduler, claim/reaper, crash recovery and eval session; the exit to async is additive. |
| 4 | Auto-apply verdicts? | **No.** `apply_mode` default `propose`; narrow `delete`-only auto-apply exists in config but not in v1. |
| 5 | Config flag to enable/disable? | **None needed** — the tool allowlist is the switch, as for every other tool. |
| 6 | Where does "must use the new code" come from? | **Tier-0 deterministic pre-pass** (path existence + bounded `git log --since`), adjudicated by the sub-agent. |
| 7 | New tables, or reuse routines/background processes? | **New tables** (095/096). Routines are time-triggered and mark success at submit time; background processes have no LLM. |

Still needing a human answer before W7:

1. **Rule wording** — the prompt is prose shipped to every agent; §4.1 carries a draft for
   review. Anything that must be said differently?
2. **Latency tolerance** — is blocking the final answer for the fan-out acceptable, or should
   v1 ship the async poller from the start? (Recommended: synchronous, revisit with data.)
3. **Judge model** — inherit the session profile (recommended), or allow a cheaper
   `judge_profile` override to be used by default?
4. **Migration numbers** — confirm 095/096, given the sibling plan reserved 094 but has not
   landed.
5. **`session_skill_events`** — accept the new ledger (needed for `listed_without_loading`
   and a stable `content_hash` drift key), or drop that dimension and read `llm_history` only?

---

## 10. Explicitly out of scope

- **No `search_skill`.** Not needed for evals; the sibling plan already deferred it.
- **No FTS5 index on eval reports.** The tables are small and always read by `run_id` or
  `skill_name`.
- **No workflow-blocking gate.** Evals are informational: they do not fail CI, block a PR, or
  block a kanban transition.
- **No `submit_skill_eval_report` tool** — sub-agent reports travel back in the existing
  `spawn_sub_agent` envelope's `response` field (§3.5).
- **No new sub-agent CRUD tool.** A `skill-evaluator` definition is seeded through the
  existing `PUT /api/nalar/config`; and v1 works with none at all, because a missing
  `agent_name` falls back to the existing random-fallback path.
- **Fixing `timeout_seconds`** (`spawn_sub_agent.zig:319-322`) and the 0-reader
  `auto_save_skill` flag — real bugs, separate changes. The sibling plan's W0 owns that file's
  cleanup; this plan's ledger makes the missing writes observable without touching the flag.

---

## 11. What the revision deleted

Review feedback ("just put it in the system prompt, so the agent runs the eval itself")
removed more than the trigger. Recorded so the simplification is visible and reversible:

| Dropped | Was in |
|---|---|
| the `run_completed` flag at `workflow.zig:1598` and the enqueue call inside the teardown `defer` (`:712-724`) | §4.1 of the first draft |
| the whole `skill_eval_runs` poller: 5 s tick, `resetStuckRunning`, `claimForRun`/`db.changes()`, the `max_run_minutes` reaper, `max_concurrent` gate, `isWorkerRunning` check | W6 |
| the **separate eval session** and `sessions.is_eval` — no longer needed, because the eval's sub-agents are spawned by a tool call from the task's own session and are main-agent-only-stripped from spawning further | Migration 095, §4.2, W6 |
| `eval_session_id`, `uq_…_after_task`, the `after_task`/`sweep` trigger values | Migration 096 |
| the `submit_skill_eval_report` tool and its eval-session-only validation | W8 |
| the `enabled` / `auto_after_task` / `eval_on` config axis | §4.10 |
| the 5th SSE event (`skill_eval_verdict`) and the `worker_deleted`-inference coupling | §4.12 |

Net: **one prompt constant, one tool, one shared-refactor — instead of a hook, a scheduler, a
state machine, and two extra config flags.** The evidence bundle, Tier-0 drift pre-pass,
rubric, validation-with-downgrade, storage, HTTP, SSE and frontend work are unchanged; they
were the parts worth keeping.

---

## Sibling — `docs/plans/2026-09-28-skills-sqlite-table.md`

Read in full. Its four decision-log entries are taken as given (`is_global` on the wire, keep
the filesystem mirror, add `tags`, no `path` shim). Three consequences land here:

1. **Migration 094 is its claim** → this plan takes 095/096 (§8 R11).
2. **`use_skill` moves from `path` to `skill_name`** → the evidence extractor must accept both,
   or evals stop matching the day 094 lands (§4.3, §8 R10).
3. **It adds `tags`** → the `duplication` dimension can compare tags as well as descriptions
   (today `ParsedFrontmatter` is `{name, description}` only, `skills.zig:68`).
