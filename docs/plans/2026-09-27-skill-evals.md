# Skill Evals — the agent evaluates the skills it used, itself

> **Status:** plan only. Nothing in this document is implemented.
> **Written:** 2026-09-27; revised twice (prompt-driven trigger, then concurrency).
> Against `HEAD` = `e0d892c9`.
> **Revisions:** (1) the trigger is a **system-prompt rule**, not a post-task hook — the
> agent runs the eval itself; (2) **concurrency is designed for**, not assumed: an eval is
> keyed on `(skill, content, context)` so two agents cannot evaluate the same thing twice,
> and every state transition is a single-statement compare-and-set. See §11.
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
exist? what changed since?), then uses the existing sub-agent batch runner to fan out one
eval sub-agent per skill. Each scores its skill on a fixed rubric — relevance, whether the
procedure was followed, whether it helped, **freshness against today's code** ("must use the
new code"), accuracy, duplication — and must back every claim with machine-checkable
evidence. Verdicts, a proposed replacement body, and the evidence land in SQLite and surface
in a new Evals UI. **Nothing is auto-applied.**

---

## 2. The request, decomposed

| What was asked | Mechanism |
|---|---|
| "just put to **system prompt, so the ai agent will run eval self**" | a `SkillEvalToolRule` prompt constant beside `SkillsToolRule` (`core.zig:167`), appended at `prompts_build_messages_for_agent_prompt.zig:125` — the shape of the `ReadWorkspaceSessionToolRule` precedent (`d61be32b`) |
| "run evals **on demand**" | `POST /api/skill-evals/runs` + a UI button, in addition to the agent's self-trigger |
| "**the main agent** runs `spawn_sub_agent`" | `run_skill_eval` calls the **same batch runner** `spawn_sub_agent` uses (`std.Io.Group.concurrent` over `runSubAgent`) — §4.2 |
| "the **sub-agents eval the skills**" | one sub-agent per loaded skill, each with a narrow allowlist and the rubric inline |
| "the skill **is not relevant**" | rubric dimension `relevance`, **split from obsolescence** — see §4.5; "wrong skill for this task" and "skill is stale" are different findings with different fixes |
| "**must use the new code**" | a **deterministic, no-LLM pre-pass** — path existence + bounded `git log --since` (§4.4) |
| "based on **the history the main agent used that skill**" | the frozen evidence bundle (§4.3) from the usage ledger + the `llm_history` tool-call graph |
| **"what if agent A and agent B eval the same skills?"** | **an eval is keyed on `(skill, content, context)` and claimed with a single-statement CAS, so it is computed once and shared — and a verdict can never be applied on top of a body it was not computed against** (§4.6) |

---

## 3. Verified current state

All line numbers verified in this worktree against `HEAD` = `e0d892c9`.

### 3.1 The prompt-rule precedent exists and is one week old

`prompts_build_messages_for_agent_prompt.zig:110-125`:

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

`ReadWorkspaceSessionToolRule` (`core.zig:38-63`) landed in `d61be32b`. It is a markdown rule
with a numbered behaviors list and a `**Self-check:**` closer, appended **unconditionally**,
mirrored by a `PROMPT_SECTIONS` entry with `requires_tool` (`:1206`) purely for
documentation, and pinned by `prompts_test.zig:1699` ("reaches the live prompt, not just
PROMPT_SECTIONS") and `:1712` ("names the tool and the four behaviors"). **A skill-eval rule
follows that template exactly.**

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
`saveSkill` (`llm_history.zig:4243`). Gaps: **no `loop_index`**; `loaded_at_nano` is
**seconds** despite the name and `INSERT OR REPLACE` re-stamps it on reload
(`llm_history.zig:4340-4343`); `add_skill`/`edit_skill` never write it (the
`.auto_save_skill = true` flag has zero readers); **listed-but-not-loaded is invisible**; and
there is **no content hash**, so drift cannot be detected by key comparison.

### 3.4 The transcript is the enrichment source

`llm_history` (`migration.zig:597-626`, `:656`) has `tool_calls_json` on assistant rows
(`arguments` is a **JSON string inside JSON** — `llm_history.zig:1459-1464`), `loop_index`
(the turn counter), and `role='tool'` rows carrying `tool_name`, `tool_call_id` and
`response_content` = the `UseSkillJSON` with `skill_name` **and the full body**.

### 3.5 Sub-agents already do the rest

- Batch runner: one `spawn_sub_agent` call spawns N agents in parallel via
  `std.Io.Group.concurrent` (`tools_exec_spawn_sub_agent.zig:461, 554, 559`), hard cap **20**
  at the parse boundary (`spawn_sub_agent.zig:249`).
- `tools` is a **required, non-empty allowlist** — no omit, no `"all"` (`:277-297`);
  `ask_user` and `spawn_sub_agent` rejected (`:307`) and stripped again from the single
  source `MAIN_AGENT_ONLY_NAMES` (`ask_user.zig:260-263`, strip at `tool_eligibility.zig:134`).
- Results return as JSON: `{name, success, random_fallback, session_id, response, error}`
  inside `{results, summary}` (`tools_exec_spawn_sub_agent.zig:571-625`). **`response` is the
  sub-agent's final text** — the report transport, so no report tool is needed.
- Progress already streams over SSE (`subagent_progress.zig:48-60`).
- `agent_name` resolves per-profile only (`Config.zig:2194-2253`); a miss is a random
  fallback. **`timeout_seconds` is dead** — parsed (`:319-322`), read nowhere.

### 3.6 No eval, rating, or feedback primitive exists

`rg` over `src/**` for `rating|thumbs|feedback|score|verdict|eval` returns only prose in
comments. The structural precedent to copy is `agent_memories` (Migration 070,
`migration.zig:3466-3592`; module `src/agentic_loop/agent_memories.zig`).

### 3.7 `SKILL.MD` parsing and the crash class

`parseYamlFrontmatter` (`skills.zig:87-145`) returns `{name, description}` — **`tags:` is
parsed by nothing**. And the `*Absolute` filesystem family asserts `path.isAbsolute(path)`
and **aborts the whole process** — not catchable, and `isAbsolute("")` is `false` (PR #639).
The drift pre-pass feeds LLM-authored paths into that family, so it must validate at the
boundary (§4.4).

### 3.8 The concurrency primitives — decisive for §4.6

**There is no usable multi-statement transaction.** `src/http_handlers/workspaces_reorder.zig:128-137`,
verbatim:

> Atomicity: each UPDATE is atomic + mutex-protected by `SqliteBackend.exec`. We don't wrap
> the loop in a `BEGIN TRANSACTION` / `COMMIT` because `SqliteBackend.exec` **releases the
> mutex at the end of each call — a transaction across calls wouldn't actually be atomic.**

So: `exec`/`query` are mutex-protected **per call**, and any sequence of statements can be
interleaved by another session at each boundary. Every invariant must therefore hold at a
**single-statement boundary**, and **SELECT-then-INSERT is always a TOCTOU bug.**

The repo's two idioms for exactly this, both verified:

1. **Claim by insert** — `saveProgressiveTool` (`llm_history.zig:4345-4368`):
   ```zig
   const sql = "INSERT OR IGNORE INTO session_progressive_tool (...) VALUES (?, ?, COALESCE(?, ''), ...)";
   try db.exec(allocator, sql, &.{ session_id, tool_name, server_name });
   const inserted = db.changes() > 0;
   ```
   (and it carries the empty-slice→NULL warning into `COALESCE`, citing Migration 079).
2. **Claim by guarded update** — `claimForRun` (`routines/model.zig:194-208`):
   ```zig
   UPDATE workspace_routines SET last_status = 'running', ...
    WHERE id = ? AND (last_status IS NULL OR last_status != 'running')
   // 1 → we won the claim; 0 → another caller claimed it first
   return db.changes() > 0;
   ```

Also relevant: the owner convention is a **nullable `user_id TEXT`** column plus an index,
added by Migration 093 with `addColumnIfMissing` (`migration.zig:4963-4985`) — nullable
because of the empty-slice→NULL bind, and with no FK because `PRAGMA foreign_keys` is off
project-wide.

---

## 4. Target design

### 4.1 Trigger — a prompt rule the agent obeys

A new constant `SkillEvalToolRule` in `src/modules/agent/prompts/core.zig`, beside
`SkillsToolRule` (`core.zig:167-198`), in the established voice. Appended
**unconditionally** at `prompts_build_messages_for_agent_prompt.zig:125`, for the documented
cache reason at `:113-119`. It is **self-gating in its wording**, so an agent without the tool
reads a no-op section — **do not** wrap it in `hasTool(...)`, which is precisely the cache
fragmentation that comment forbids.

Draft (final wording is a review item — it is prose shipped to every agent):

```
## Skill Evals — evaluate the skill you used, before you answer

**A skill is only worth what it is worth today.** After you finish a task in which you
loaded at least one skill with `use_skill`, call `run_skill_eval` ONCE before your final
message. It reads the record of what this session actually loaded — you do not pass the
skill list, so you cannot cherry-pick — and has one eval sub-agent per skill check
relevance, whether the procedure was followed, whether it helped, whether the paths and
commands it names still exist in the code as it is now, and whether another skill already
covers it. Evals that other sessions already ran for the same skill content are reused
instead of repeated, so this is usually cheap.

- **Skip it** when you loaded no skill, or when `run_skill_eval` is not in your tool list.
- **Once per task.** A second call is a cheap no-op, not a second eval.
- **You are not the judge.** You choose *when*, not *what* and not the *verdict*.
- **Report it in one line** in your final message, e.g. "Evaluated 3 skills — 1 needs
  updating (`foo`)". Say so if a skill came back `needs_human`.

**Self-check:** "did I load a skill and forget to evaluate it?" If yes, call
`run_skill_eval` now.
```

### 4.2 One tool does the work — synchronous, in-session

`run_skill_eval` is the **only** new tool. Its exec:

1. **Resolve the target set from code, not from the agent** — the ledger/`session_skills`
   rows for `ctx.session_id`. `{}` = all loaded skills; `{skill_name}` = one (the UI button).
2. **Claim the run** — `INSERT OR IGNORE` into `skill_eval_runs` + `db.changes()` (§4.6 R2).
   The loser returns the winner's summary or "already in progress".
3. **Tier-0 pre-pass** (§4.4) — instant, no tokens.
4. **Per skill: claim or reuse the shared fact** (§4.6 R1). A cache hit spawns **no**
   sub-agent for the intrinsic half.
5. **Fan out** only for skills whose fact is missing: one sub-agent per skill, instruction =
   rubric + that skill's evidence slice, `tools` =
   `["read_file","search","glob","list_directory","command","list_skills","use_skill"]`.
6. **Collect** each `results[].response`, parse as JSON, `validateReport()` (§4.5),
   downgrade failures.
7. **Persist** the shared facts and the per-session results; finalize the run
   (`status='done'`, `total_tokens` summed exactly over the returned sub-session ids).
8. **Return a compact summary**: `{evaluated, reused, verdicts: {keep: 2, update: 1},
   needs_attention: [...], run_id}` — the agent quotes it.

**Fan-out is code, not LLM-written JSON.** Semantically identical to "the main agent runs
`spawn_sub_agent`" — same session, same concurrency, same sub-agent sessions with
`parent_session_id` — but the parse rules from §3.5 are enforced by construction rather than
by a model writing nested payloads. Extracting the batch runner into a shared function is its
own reviewed task (W3).

**Synchronous, not queued.** No scheduler, no claim/reaper state machine, no crash recovery,
no separate eval session. §8 R2 records the escape hatch.

### 4.3 The evidence bundle

`src/agentic_loop/skill_evals_evidence.zig` builds one frozen JSON per run, stored in
`skill_eval_runs.evidence_json`, sliced per skill into each sub-agent's instruction:

```json
{
  "schema": 1,
  "run_id": "skilleval_1790542201041721153",
  "evaluated": {
    "session_id": "task_1790542158293_5", "task_id": "task_1790542158293_5",
    "workspace_item_id": "item_1788811112791088699", "item_type": "kanban",
    "cwd": "/home/ginwa/ginwaaitoolbox", "head_sha": "e0d892c9",
    "final_message": "...", "user_intent": "...first user message, truncated to 2 KB..."
  },
  "skills": [{
    "name": "ginwaaitoolbox-resolve-pr-conflict", "scope": "global",
    "skill_key": "global:ginwaaitoolbox-resolve-pr-conflict",
    "context_key": "/home/ginwa/ginwaaitoolbox@e0d892c9",
    "first_loop_index": 7, "use_count": 2, "listed_count": 3,
    "listed_without_loading": false,
    "content_at_use": "---\nname: ...\n---\n## Procedure\n...",
    "content_hash_at_use": "sha256:9f2c...",
    "content_now": "---\nname: ... (current body)",
    "content_hash_now": "sha256:9f2c...",
    "content_changed_since_use": false,
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

`transcript_excerpt` is deliberately absent: the sub-agent has `read_workspace_session` and
the `loop_index` anchors, and a 200 KB prompt is not a feature.

**Cross-plan hazard.** `use_calls[].arguments` is `{path}` today; the sibling plan (§4.7
there) deletes `path` for `skill_name`. The extractor must accept **both** — `skill_name`,
then `path` basename, then `response_content.skill_name` as authority — or evals stop matching
the day 094 lands. W8 owns the switch-on case.

### 4.4 Tier 0 — the deterministic pre-pass (no LLM, no tokens)

`src/agentic_loop/skill_evals_drift.zig`, run before any sub-agent exists:

1. **Path extraction** — a conservative tokeniser over the skill body for path-shaped and
   `file:line`-shaped tokens. A false positive becomes a false "stale path" finding, so bias
   to under-matching. Cap at 50 paths per skill.
2. **Existence check** — resolve against the session `cwd`, then `statFileAbsolute` /
   `accessAbsolute`. **Validate `isAbsolute` at the boundary and turn a relative or empty
   token into a finding** — never pass it through (§3.7).
3. **Drift by git history** — `git -C <cwd> log --oneline --since=<loaded_at ISO> -- <paths>`.
   Bounded: `std.process.spawn` (the codebase is uniformly on `spawn`, not `Child.run`),
   `wait_pid_bounded` (`shell.zig:164`), 3 s deadline, capped output. **This is the "must use
   the new code" mechanism.**
4. **Structural checks** — frontmatter parses; `name:` kebab-case; `description:` present and
   ≤ 200 chars; body ≤ `MAX_SKILLS_SIZE` (100 KB, `skills.zig:7`); name collision and a cheap
   trigram/Jaccard description similarity → the `duplication` signal.

If the only findings are deterministic and none is `severity: high`, the run settles at **zero
token cost**. Build this first.

### 4.5 The rubric — split into **intrinsic** and **session-relative**

This split is what makes §4.6 possible, and it is also the right product design: "the skill is
not relevant" has two very different root causes with opposite fixes.

| Class | Dimensions | Depends on | Shareable across sessions? |
|---|---|---|---|
| **Intrinsic** | `freshness`, `accuracy`, `duplication`, structural findings | only the skill **body** + the code state at a commit | **Yes.** Two agents judging the same body at the same commit are answering the same question. |
| **Session-relative** | `relevance`, `used`, `helpfulness` | this task's transcript, this agent's choices | **No.** Cheap, and different every session. |

The sub-agent instruction always covers both; the **intrinsic** half is what gets cached and
shared, and it is the half that does the expensive work (searching the repo, `git log`,
running commands).

**Verdict is a pure function of the two halves, computed in Zig** — never by the model:

| Intrinsic | `relevance` | Verdict | Reading |
|---|---|---|---|
| `needs_human` on any dimension | any | `needs_human` | never resolve uncertainty upward |
| any `high` finding (stale path, wrong fact) | any | `delete` | the skill is wrong, and it misled an agent |
| `update` | ≥ 2 | `update` | correct-but-stale, and it was actually used |
| `keep` | 0 | `keep` | accurate skill, wrong task — **a discovery problem, not a skill problem** |
| `keep` | ≥ 1 | `keep` | healthy |
| `merge` | any | `merge` | duplication |

Row 4 is the one that matters: a skill that is *not relevant* to the task but is *accurate* is
not a bad skill. Reporting it as `update`/`delete` would destroy good skills, which is the
worst failure mode available to this feature. The split makes that impossible by construction.

**Scores and evidence.** Each dimension is 0-3 with a mandatory evidence pointer:

| Dimension | Question | Evidence it must cite |
|---|---|---|
| `relevance` | Did this skill match the task it was loaded for? | the user intent + the loading turn |
| `used` | Was the procedure followed, or loaded and ignored? | transcript tool calls |
| `helpfulness` | Did following it help, or mislead? | the outcome / final message |
| `freshness` | **Do the paths, symbols and commands it names still exist and behave as described?** | `deterministic_findings` + `drift_commits` + its own checks |
| `accuracy` | Is any stated fact wrong? | the file/line that contradicts it |
| `duplication` | Does `available_skills` already cover this? | the other skill's name |

**Validation** (`validateReport()`, in Zig, never bypassed): verdict ∈ enum; scores ∈ 0..3;
confidence ∈ 0..1; every finding has non-empty `evidence`; `proposed_content` non-empty for
`update`/`rewrite`; `merge_target` exists; **a `delete` without a `high` finding is downgraded
to `needs_human`**. A sub-agent whose final message does not parse, or fails validation, is
stored as `needs_human` with the raw text preserved in `rationale` — never silently dropped,
never trusted.

### 4.6 Concurrency — one writer per `(skill, content, context)`

**The constraint (§3.8):** `SqliteBackend` is mutex-protected per call and there is no
multi-statement transaction, so any two statements can interleave. The rule for this whole
feature:

> **No invariant may depend on two statements. Every state transition is one guarded
> statement whose `WHERE` carries the precondition, and the winner is decided by
> `db.changes()`. A SELECT before a write is an optimisation, never a guarantee.**

Four races, and only four.

#### R1 — Agent A and Agent B evaluate the same skill (the reported case)

Unmitigated, this wastes tokens **and is worse than that**: the two runs produce two verdicts
that can disagree (`keep` vs `delete`) with nothing saying which is authoritative, and the
second run's proposal may be computed against a body the first run already replaced.

**Fix — make the unit of work identical to the question being asked.** A new table
`skill_eval_facts` is keyed on **`(skill_key, content_hash, context_key)`**:

| Component | Value | Why |
|---|---|---|
| `skill_key` | `global:<name>` or `local:<canonical_cwd>:<name>` | after 094 the local identity is `(cwd, name)`; omitting cwd makes two workspaces' same-named local skills collide |
| `content_hash` | sha256 of the skill body judged | a changed body is a **different question**, so it is a different key — no TTL, no invalidation logic, no cache-coherence bug |
| `context_key` | `canonical_cwd '@' head_sha` | `freshness`/`accuracy` are repo-relative (paths resolve against cwd, "the new code" is a commit), so the same global skill evaluated in two repos is genuinely two questions |

Two agents that evaluate the same skill at the same content and the same commit are computing
**the same answer**, so the unique index makes the second a cache hit. That is not a heuristic
shortcut; it is the same question with the same inputs.

Claim / reuse / steal / publish, all single-statement:

```sql
-- CLAIM (one winner). 'computing' is a lease, not a value.
INSERT OR IGNORE INTO skill_eval_facts
  (id, skill_key, content_hash, context_key, verdict_intrinsic, computed_at)
VALUES (?, ?, ?, ?, 'computing', datetime('now'));
-- db.changes() == 1 → we own the computation; 0 → read what is there.
```

```sql
-- REUSE: a completed fact is a cache hit. Spawn nothing for the intrinsic half.
SELECT ... FROM skill_eval_facts
 WHERE skill_key=? AND content_hash=? AND context_key=? AND verdict_intrinsic != 'computing';
```

```sql
-- STEAL: an owner that crashed leaves a 'computing' row forever. The lease reclaims it.
UPDATE skill_eval_facts
   SET computed_at = datetime('now')
 WHERE skill_key=? AND content_hash=? AND context_key=?
   AND verdict_intrinsic = 'computing'
   AND computed_at < datetime('now', '-' || ? || ' seconds');
-- db.changes() == 1 → we now own it. 0 → a live owner holds it.
```

```sql
-- PUBLISH (only the owner can, and only once).
UPDATE skill_eval_facts
   SET verdict_intrinsic=?, freshness=?, accuracy=?, duplication=?,
       findings_json=?, evidence_json=?, proposed_content=?,
       missing_paths_json=?, drift_commits_json=?, computed_at=datetime('now')
 WHERE skill_key=? AND content_hash=? AND context_key=?
   AND verdict_intrinsic = 'computing';
-- db.changes() == 1 → published. 0 → someone else published or stole it; read theirs.
```

The only wait state: a live owner holds the lease and this session wanted the same fact. Then
this session does **not** duplicate the work — it records its result with the intrinsic half
marked `pending` and `intrinsic_fact_id` pointing at the row, and the UI attaches the shared
facts when they land. `verdict` for such a row is computed on read (§4.5), so a `pending`
intrinsic half is simply "not yet decided" and never a wrong answer.

**This is a cache, not a lock**, which matters: correctness does not depend on it. If the
claim/steal logic were removed entirely, the feature would still be correct (just wasteful),
because the apply-time guard (R4) is what protects the skill body. Say that out loud in the
code comment — a future reader must not "simplify" R4 assuming R1 is the safety net.

**Cross-user note:** `skill_eval_facts` deliberately has **no** `user_id` column, unlike
`skill_eval_runs`/`skill_eval_results`, which follow the Migration 093 convention (§3.8).
Facts are facts about code, and global skills are already shared across users; the runs and
results are user records. If the reviewer disagrees, add `user_id` to the fact key — it costs
one more cache miss, not correctness.

#### R2 — the same session calls `run_skill_eval` twice (or two tool calls in one turn)

The agent can emit parallel tool calls; both execs would see "no run yet" and both insert.
Fix: `uq_skill_eval_runs_self_prompt` plus `INSERT OR IGNORE` + `db.changes()` — **the index
is the arbiter, the pre-check is only an optimisation.** `changes() == 0` → SELECT the
existing run and return its summary if `done`, or "an eval of this session's skills is already
in progress" if `running`. Never wait on it: a synchronous tool call would deadlock against
itself.

#### R3 — two applies of the same result (double-click, two clients, two humans)

Fix: claim the apply with one guarded statement, then verify.

```sql
UPDATE skill_eval_results
   SET applied_at = datetime('now'), apply_action = ?
 WHERE id = ? AND applied_at IS NULL;
-- db.changes() == 1 → we won the right to apply. 0 → already applied; return the existing state.
```

#### R4 — apply on top of a body that changed since the verdict was computed

**The actual corruption race, and the one that must never be skipped.** A verdict's proposal is
computed against a specific body (`base_content_hash`, taken from the fact row's
`content_hash`). If a human edited the skill, or a sibling agent applied a different proposal
in between, replaying this proposal is a silent partial overwrite of someone else's work.

Sequence, after winning R3:

1. Re-read the skill and hash it.
2. `hash != base_content_hash` → **refuse**: revert the claim
   (`UPDATE skill_eval_results SET applied_at=NULL, apply_action='' WHERE id=?`), mark
   `status='stale'`, and return `409` carrying both hashes. The UI offers "re-evaluate" (which
   is now a cache miss by construction — `content_hash` changed — so it recomputes the
   intrinsic half for real).
3. Otherwise write through the **existing** `edit_skill` / `remove_skill` path (never a second
   writer), then return success.
4. If the write fails, revert the claim (compensating action) and return the error.

**Ordering trade, stated because there is no transaction to hide it:** write-the-file-first
would leave a modified skill with the result row looking unapplied, so a retry would
double-write. Claim-first (chosen) can leave a claim committed if the process dies between
steps 2 and 3 — the result reads "applied" while the file is untouched, which is visible,
harmless and retryable. Choose the failure mode that is detectable. Also: `edit` and `delete`
are idempotent by construction, so a retry of step 3 is safe.

#### R5 — the ledger (`session_skill_events`) needs no guard

Append-only with a fresh nanosecond id per row; two concurrent `list_skills` calls appending
two rows is **correct** — they are two events, and the `content_hash` distinguishes them.
`session_skills` keeps its existing `INSERT OR REPLACE` last-write-wins. Stating this
explicitly because not every table needs a claim, and adding one here would be noise.

### 4.7 Storage — Migrations **095** and **096**

Conventions copied from the repo: one statement per `db.exec`; `CREATE TABLE/INDEX IF NOT
EXISTS`; `DATETIME DEFAULT CURRENT_TIMESTAMP` set in SQL, never bound from Zig; **TEXT ids**
from `std.Io.Timestamp.now(io, .real).nanoseconds`; no foreign keys; register in
`registerAllMigrations` after the Migration093 entry at `migration.zig:2006`.

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
**Additive**: `session_skills` keeps its writers.

#### Migration 096 — the shared facts cache, the runs, the results

```sql
-- The intrinsic half of a verdict, keyed on the identity of the question (§4.6 R1).
-- No user_id on purpose: facts about code, shared like global skills are.
CREATE TABLE IF NOT EXISTS skill_eval_facts (
  id              TEXT PRIMARY KEY,
  skill_key       TEXT NOT NULL,             -- 'global:<name>' | 'local:<cwd>:<name>'
  content_hash    TEXT NOT NULL,             -- sha256 of the body these facts are about
  context_key     TEXT NOT NULL,             -- '<canonical_cwd>@<head_sha>'
  verdict_intrinsic TEXT NOT NULL DEFAULT 'computing',
  freshness       INTEGER NOT NULL DEFAULT 0,
  accuracy        INTEGER NOT NULL DEFAULT 0,
  duplication     INTEGER NOT NULL DEFAULT 0,
  findings_json   TEXT NOT NULL DEFAULT '',
  evidence_json   TEXT NOT NULL DEFAULT '',
  proposed_content TEXT NOT NULL DEFAULT '',
  missing_paths_json TEXT NOT NULL DEFAULT '',
  drift_commits_json TEXT NOT NULL DEFAULT '',
  computed_at     DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_eval_facts
  ON skill_eval_facts(skill_key, content_hash, context_key);
CREATE INDEX IF NOT EXISTS idx_skill_eval_facts_skill ON skill_eval_facts(skill_key, computed_at DESC);

CREATE TABLE IF NOT EXISTS skill_eval_runs (
  id              TEXT PRIMARY KEY,
  session_id      TEXT NOT NULL DEFAULT '',   -- the session whose skills were evaluated
  skill_name      TEXT NOT NULL DEFAULT '',   -- '' = every loaded skill
  scope           TEXT NOT NULL DEFAULT 'session',     -- 'session' | 'skill'
  trigger         TEXT NOT NULL DEFAULT 'self_prompt', -- 'self_prompt' | 'on_demand'
  status          TEXT NOT NULL DEFAULT 'running',     -- running|done|failed|skipped
  profile         TEXT NOT NULL DEFAULT '',
  model           TEXT NOT NULL DEFAULT '',
  cwd             TEXT NOT NULL DEFAULT '',
  context_key     TEXT NOT NULL DEFAULT '',
  evidence_json   TEXT NOT NULL DEFAULT '',
  sub_session_ids_json TEXT NOT NULL DEFAULT '',       -- exact cost attribution
  report_json     TEXT NOT NULL DEFAULT '',
  total_tokens    INTEGER NOT NULL DEFAULT 0,
  error           TEXT NOT NULL DEFAULT '',
  started_at      DATETIME, finished_at DATETIME,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
  user_id         TEXT                                  -- Migration 093 convention
);
CREATE INDEX IF NOT EXISTS idx_skill_eval_runs_session ON skill_eval_runs(session_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_eval_runs_self_prompt
  ON skill_eval_runs(session_id, trigger) WHERE trigger = 'self_prompt';

CREATE TABLE IF NOT EXISTS skill_eval_results (
  id              TEXT PRIMARY KEY,
  run_id          TEXT NOT NULL,
  skill_key       TEXT NOT NULL,
  skill_name      TEXT NOT NULL,
  session_id      TEXT NOT NULL DEFAULT '',
  status          TEXT NOT NULL DEFAULT 'pending', -- pending|done|failed|needs_human|stale|skipped
  verdict         TEXT NOT NULL DEFAULT 'needs_human',
  relevance       INTEGER NOT NULL DEFAULT 0,
  used            INTEGER NOT NULL DEFAULT 0,
  helpfulness     INTEGER NOT NULL DEFAULT 0,
  confidence      REAL NOT NULL DEFAULT 0,
  -- the intrinsic half lives in skill_eval_facts and is referenced, not copied
  intrinsic_fact_id TEXT NOT NULL DEFAULT '',
  -- the body this verdict's proposal was computed against: R4's staleness key
  base_content_hash TEXT NOT NULL DEFAULT '',
  content_at_use  TEXT NOT NULL DEFAULT '',
  proposed_diff   TEXT NOT NULL DEFAULT '',
  rationale       TEXT NOT NULL DEFAULT '',
  sub_session_id  TEXT NOT NULL DEFAULT '',
  applied_at      DATETIME,
  apply_action    TEXT NOT NULL DEFAULT '',       -- 'edit'|'delete'|'keep'|''
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
  user_id         TEXT                            -- Migration 093 convention
);
CREATE INDEX IF NOT EXISTS idx_skill_eval_results_run ON skill_eval_results(run_id);
CREATE INDEX IF NOT EXISTS idx_skill_eval_results_skill ON skill_eval_results(skill_key, created_at DESC);
```

Note what this buys: `freshness`/`accuracy`/`duplication` are stored **once per (skill,
content, context)** rather than duplicated per session, so N sessions evaluating one skill
store one intrinsic verdict and N cheap session-relative rows. (`skill_eval_facts` could be
its own Migration 097 if the reviewer prefers three single-purpose migrations; it has no FK
either way.)

Repository: **`src/agentic_loop/skill_evals_db.zig`**, next to `agent_memories.zig`. Integers
and booleans stringified on bind (`std.fmt.allocPrint(alloc, "{d}", ...)`) and compared on read
(`std.mem.eql(u8, row.values[i], "1")`) — the `design_model.zig:179-187` idiom. **Every
free-text write must be `COALESCE(?, '')`**: `SqliteBackend.exec` binds a zero-length slice as
SQL `NULL` and `NOT NULL` then fails **at runtime, mid-useCase** — Migration 079's `content`
column broke exactly this way, and `rationale`/`error`/`missing_paths_json` are all plausibly
empty. And `query`/`queryRow` do **not** have the guard, so `""` is `NULL` in a `WHERE` arg but
`''` in `VALUES` — guard the empty-name path explicitly. All CAS statements in §4.6 must be
`catch`-wrapped exactly like `claimForRun` (`routines/model.zig:199-204`), which logs and
returns `false` rather than propagating.

### 4.8 Guards

| Guard | Mechanism | Why |
|---|---|---|
| **No recursion** | `run_skill_eval` joins `MAIN_AGENT_ONLY_NAMES` (`ask_user.zig:260`) — one list, three enforcement points — and is absent from every eval sub-agent's allowlist | a fan-out of fan-outs has no bound |
| **No cherry-picking** | the tool reads the skill set from the ledger for `ctx.session_id`; the agent passes nothing | the agent must not omit the skill it worked around |
| **No duplicate work** | the `(skill_key, content_hash, context_key)` fact key (§4.6 R1) | two agents evaluating one skill = one computation |
| **Idempotent** | `uq_skill_eval_runs_self_prompt`; a repeat call returns the stored summary | the rule says "once"; an LLM will sometimes call twice |
| **Bounded fan-out** | `max_skills_per_run` (default 8); above it, prioritise by `use_count desc, first_loop_index asc` and record the rest as `skipped` | one run cannot fan out 20 agents over 300 skills |
| **Budget** | `max_evals_per_day`; denied runs return a clear message | a ceiling the user can reason about |
| **No blocking, no surprise** | synchronous but bounded; `subagent_progress` SSE shows "eval 2 of 3"; `total_tokens` in the summary the agent quotes | the user should see the cost of what just happened |
| **Opt-out** | removing `run_skill_eval` from the tool list is the switch | no new config flag |

### 4.9 Config — the allowlist *is* the on/off switch

Because the rule is a static constant, the trigger is gated the way every other tool is gated:
**the tool must be in the agent's tool list.** `run_skill_eval` is added to
`DEFAULT_CHAT_TOOLS` (`api/index.ts:1509-1529`) and categorised in `ToolsSection.vue:43-125`
(`'Skills'`). For a `kanban`/`design`/`agent` item, the per-item `agent_tools` allowlist decides
(secure-by-default: empty = zero tools, `agent_tools_allowed.zig:37-83`).

Config therefore shrinks to the cost knobs:

```json
"skill_evals": {
  "max_skills_per_run": 8,
  "max_evals_per_day": 10,
  "fact_lease_seconds": 300,
  "judge_sub_agent": "",
  "judge_profile": "",
  "apply_mode": "propose",
  "include_listed_without_loading": true
}
```

`apply_mode`: `off` | `propose` (**default**) | `auto_low_risk`. Mirror the `SubAgentConfig`
plumbing (`Config.zig:172-197` / `:360-378` / `:867` / `:1014` / `:1396-1412`) and expose via
`GET/PUT /api/nalar/config` (`nalar_config_put.zig:302-343`).

### 4.10 Applying a verdict

Default **propose-only**. Apply = §4.6 R3 (claim) → R4 (staleness check) → the **existing**
`edit_skill` / `remove_skill` / `add_skill` path (or the sibling plan's
`skills_db.upsertSkill`/`deleteSkill` after 094) → record `apply_action` + `applied_at` → emit
SSE. Never a second skill writer, so exactly one place touches a `SKILL.MD`.

`auto_low_risk` is deliberately narrow: only `delete`, only for a skill with ≥ 2 consecutive
`delete` verdicts across ≥ 2 different runs, no `keep` in between, zero `use` in 30 days. Every
`update`/`rewrite` stays human-gated. Auto-editing a skill body is not a risk this plan takes
in v1.

### 4.11 HTTP surface — a **separate prefix**, on purpose

All under `/api/skill-evals/*`, **not** nested under `/api/skills`. `matchRoute` walks routes in
registration order and `/api/skills/:name` is registered at `main.zig:602`, so a literal
`/api/skills/evals` registered after it is captured with `name="evals"`. A sibling prefix has
zero interaction with it. (Precedent for correct order if a sub-route is ever added under
`/api/skills/`: `…/knowledge/reorder` before `…/knowledge/:knowledge_id`, `main.zig:721-722`.)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/skill-evals/runs` | `{session_id, skill_name?}` → the summary (UI button path) |
| `GET` | `/api/skill-evals/runs` | list, filtered by `session_id`/`skill_key`/`status`, paged |
| `GET` | `/api/skill-evals/runs/:run_id` | run + all results + report |
| `POST` | `/api/skill-evals/results/:result_id/apply` | `{action}` → `200` / `409 stale` / `409 already_applied` |
| `GET` | `/api/skill-evals/skills/:skill_name/history` | verdict timeline, plus the shared facts for this content/context |
| `GET` | `/api/skill-evals/summary` | counts by verdict — powers the sidebar badge |

Handlers follow the `agent_knowledge_*` shape: `useCase(allocator, db, input)` with a closed
error set and two exhaustive `switch`es so adding a variant fails to compile.
`nalarcore.getSingleton()` is touched **in the handler only**.

### 4.12 SSE

New routing key `"skill_evals"` in `unified_events_sse.zig:248-273`; three event names:
`skill_eval_run_started`, `skill_eval_run_completed`, `skill_eval_run_failed`. Per-skill
verdicts ride in the completed payload; sub-agent progress needs nothing new
(`subagent_progress` already streams).

Each name must be registered in **all four** places in the same PR: the Zig emitter's
event-type ladder; `api/index.ts:3738-3799` `additionalEventTypes` (**missing here = silently
dropped**); a dispatch branch in `onEvent` (`:3801+`); and `SseEventMap` (`sseBus.ts:25-43`) +
`UnifiedChannels` (`api/index.ts:3620-3656`). Pin the wire strings with a Zig test in the
`sse_on_event_send_session.zig:209-232` shape and a TS registry test like
`unifiedSseBuffer.spec.ts:580-720`. **No fallthrough default** — that is how `session_unknown`
happened.

### 4.13 Frontend

| Piece | Built from | Notes |
|---|---|---|
| Settings "Evals" tab | `SettingsView.vue:78-121` (4th entry) | reuse the local toast at `:13-20, 120-133` |
| `SkillEvalsSettings.vue` | `SkillsSettings.vue:1-73` master/detail | left = runs + per-skill roll-up; right = report |
| Report view | `SkillDetail.vue` structure | score bars, rationale, evidence list, `proposed_diff` in the existing diff renderer, Apply / Dismiss, and a visible **"reused a shared eval from 4 min ago"** line when the intrinsic half was a cache hit |
| Verdict badge on skill rows | `WorkspaceItemTaskCard.vue:569-624` pattern | worst-of-last-N verdict, plus a `stale` state |
| Stale / conflict surface | new | when apply returns `409 stale`, show both hashes and a "Re-evaluate" button |
| "Evaluate" button | `SkillDetail.vue` next to Delete | `POST /runs` with `skill_name` |
| Right-sidebar panel | extend the `SidebarPanel` union at `ChatRightSidebar.vue:42` | inherits `?sidebar=evals` deep-link + localStorage — **never a second param** |
| Live state | `stores/skillEvalsSse.ts` modelled on `kanbanSse.ts:42-323` | plus the existing sub-agent progress pill |
| In-transcript card | `KanbanMove.vue:1-180` + `parseKanbanMove` (`toolOutputParser.ts:652-680`) | so the run and its verdicts are visible where they happened |
| Tool registration | `ToolsSection.vue:43-125` + `DEFAULT_CHAT_TOOLS` `api/index.ts:1509-1529` | missing here = filtered out of every session |

URL-param rule (repo convention): extend the view's existing param union, mount reads it back,
clicks write it with `router.replace`. A local `ref` boolean breaks refresh/Back/share.

---

## 5. Task breakdown

Ordered so each task is independently reviewable and everything works on today's filesystem
model with **no** dependency on the sibling plan.

- **W0 — Migrations 095 + 096.** Registered after `migration.zig:2006`, with a registration
  guard test in the `migration.zig:6042-6048` shape.
- **W1 — Usage ledger.** Writers at `handle_tool.zig:809-810` for `use_skill` (with
  `loop_index`, `llm_history_id`, `content_hash`) and `list_skills` (per entry,
  `event='listed'`), plus `add_skill`/`edit_skill`/`remove_skill`.
- **W2 — Repository + validation.** `skill_evals_db.zig` CRUD, `validateReport()`, the verdict
  function from §4.5, the downgrade rules. Pure functions, in-memory DB tests, no spawning.
- **W3 — Shared batch runner.** Extract `runSubAgent` + the `std.Io.Group.concurrent` loop out
  of `tools_exec_spawn_sub_agent.zig:413-630` into a reusable function; both
  `execSpawnSubAgent` and `execRunSkillEval` call it. Pure refactor — the static-contract tests
  at `:660-792` must keep passing unchanged.
- **W4 — CAS primitives.** `claimFact` / `readFact` / `stealFact` / `publishFact` (§4.6 R1),
  `claimRun` (R2), `claimApply` (R3) — each one guarded statement + `db.changes()`, each
  `catch`-wrapped like `claimForRun` (`routines/model.zig:199-204`). **This is a small,
  self-contained, fully unit-testable module** (`skill_evals_cas.zig` or in
  `skill_evals_db.zig`) and it should land before anything that calls it.
- **W5 — Evidence bundle.** `skill_evals_evidence.zig`: ledger + `llm_history` join on
  `tool_call_id`/`loop_index` + final and first user messages + `available_skills` +
  `skill_key`/`context_key` derivation + per-skill slicing. **Accepts both `{path}` and
  `{skill_name}` `use_skill` arguments.**
- **W6 — Drift pre-pass.** `skill_evals_drift.zig`: path extraction, existence check with the
  `isAbsolute` boundary guard, bounded `git log --since`, structural checks, description
  similarity. **Zero LLM.** This is where "must use the new code" comes from.
- **W7 — Prompt rule.** `SkillEvalToolRule` in `core.zig`; appended at
  `prompts_build_messages_for_agent_prompt.zig:125`; re-exported in `prompts.zig` and
  `modules/agent/prompts.zig`; `PROMPT_SECTIONS` mirror (`:1206` shape); tests mirroring
  `prompts_test.zig:1699` and `:1712`.
- **W8 — The tool.** `run_skill_eval`: resolve from the ledger, claim the run, Tier-0, claim or
  reuse facts, fan out via W3, validate, persist, finalize, return the summary. Registered in
  `UNIFIED_TOOL_REGISTRY`, added to `MAIN_AGENT_ONLY_NAMES`, `ToolsSection.vue`,
  `DEFAULT_CHAT_TOOLS`.
- **W9 — Sibling-plan compatibility.** Read `use_skill` arguments in both shapes; route all
  skill reads/writes through one accessor so 094's `skills_db` swap is a single-file change;
  a test that fails on a third argument shape.
- **W10 — HTTP + config.** The six `/api/skill-evals/*` routes (including the `409`s with
  distinct codes) + the config block.
- **W11 — SSE.** Channel + three event names + the four registrations + the pinning tests.
- **W12 — Frontend.** §4.13 in full, including the URL-param spec, the diff renderer, the
  reused-eval notice and the stale/conflict surface.
- **W13 — Functional + docs.** `tests/functional/skill_evals_test.py` (§6) and a `docs/SPEC.md`
  section.

### Test plan per task

| Task | Coverage |
|---|---|
| W0/W1/W2 | in-memory SQLite via `migration.registerAllMigrations` + `runMigrations()` — never hand-rolled `CREATE TABLE` (`.nalar/memories/llm-history-test-use-migrations-module.md`); the two partial unique indexes reject a second `self_prompt` run and a duplicate fact key; **`""` binds as `''`, not NULL**, for `rationale`/`error`/`missing_paths_json`; an unevidenced verdict is rejected; a `delete` without a `high` finding is downgraded; **§4.5 row 4**: accurate-but-irrelevant ⇒ `keep`, never `update`/`delete` |
| W3 | the extracted runner is behaviour-identical: existing `spawn_sub_agent` tests pass unchanged; a batch of 3 runs concurrently; `error.ConcurrencyUnavailable` is still surfaced, not swallowed |
| **W4** | **every CAS, sequentially, which is the same code path a race takes:** `claimFact` twice → first `true`, second `false`; `readFact` after a publish returns the facts; `stealFact` on a fresh `computing` row → `false`, and on a row whose `computed_at` is older than the lease → `true`; `publishFact` twice → first `true`, second `false` (and the winner's values stand); `claimRun` twice → one winner; `claimApply` twice → one winner and the second sees `applied_at` set. Note in the test header *why* sequential calls are a valid proof: `exec` is mutex-serialized per call, so the interleaving a race produces is exactly "statement, statement" — the only thing concurrency adds is arbitrary ordering, and the guarded predicates are order-independent |
| W5 | fixture session with assistant `tool_calls_json` + `role='tool'` rows → `first_loop_index`, `use_count`, `content_changed_since_use`, `listed_without_loading`; **both** `{path}` and `{skill_name}` argument shapes; `skill_key` distinguishes two cwds' same-named local skills |
| W6 | path extraction on a real SKILL.MD; a missing path detected; **the `isAbsolute("")` boundary returns a finding instead of aborting the process** (the PR #639 class — a test that panics *is* the failure being pinned); a relative path rejected; `git log --since` bounded and non-blocking on a non-repo cwd |
| W7 | the rule reaches the live prompt; it names the tool and the skip/once/no-pre-judging behaviors; **it is appended unconditionally** — assert it is *not* inside a `hasTool(...)` branch, because gating it fragments the cacheable prefix |
| W8 | the skill set comes from the ledger, not the args (a call naming a skill this session never loaded is ignored); a non-JSON sub-agent reply lands as `needs_human` with the raw text preserved; `total_tokens` equals the sum over the returned sub-session ids; **a second call with a fact already cached spawns zero sub-agents** |
| W8 | **static-contract assert that the built sub-agent payloads have non-empty `tools`, no `"all"`, no main-agent-only name, an `agent_name`, and ≤ 20 agents** — the parse rules from `spawn_sub_agent.zig:277-297`, `:307`, `:249` |
| W10/W11 | **Python functional**, not curl — §6 |
| W12 | the settings-tab/panel URL spec in the `SidebarDiffPanel.tabs.spec.ts:1-267` shape; SSE registry completeness like `unifiedSseBuffer.spec.ts:580-720` |

---

## 6. Verification — functional tests with a scripted stub LLM

Per the repo's rule: **no `nohup nalar --port 8080` + `curl`.** All three named failure modes
are live here — route order under a new prefix, empty strings collapsing to SQL NULL
mid-useCase, and strict validators rejecting `""`.

`tests/functional/skill_evals_test.py`, on the `harness` fixture (`port=None` → a random
20000-32000 port; **8081 is reserved, never used**; isolated tmpdir `HOME` gated by
`is_safe_tmp()`):

1. **The whole pipeline, deterministically.** The pattern exists in
   `tests/functional/anthropic_chat_headers_test.py:69-94`: boot the harness, `PUT` a profile
   pointing at a local `ThreadingHTTPServer` stub returning scripted SSE, `POST
   /api/llm/session` with a `queue_message`, poll until the reply lands. Here the stub plays
   both the task agent (emitting a `run_skill_eval` tool call) and the eval sub-agents
   (returning canned report JSON). The harness's own `stub_llm_profile=True` points at a dead
   port (`harness.py:1206`) and is **not** sufficient; the stub must be a live scripted server.
2. **Tier-0 settles with zero sub-agents** when the only finding is a missing path: the run is
   `done`, the fact row carries the low `freshness`, and the stub received **no** completion
   request for a sub-agent.
3. **★ The reported race, end to end.** Two concurrent `POST /api/skill-evals/runs` for the
   same skill from two different sessions, issued from two threads. Assert: exactly **one**
   intrinsic evaluation reached the stub; the second response reports `reused`; there is one
   `skill_eval_facts` row; and there are **two** `skill_eval_results` rows (per-session) sharing
   one `intrinsic_fact_id`. Then the sequential variant, which is the deterministic proof:
   `POST` twice in a row → the second is a pure cache hit with zero stub traffic.
4. **★ Apply on a stale body.** Win an apply, then have the test edit the `SKILL.MD` (or apply
   another result) before the second apply: assert `409` with both hashes, `status='stale'`,
   `applied_at` reverted to NULL, and the skill body **unchanged**. This is the test that proves
   no silent overwrite is possible.
5. **★ Double apply.** Two concurrent applies of one result → exactly one `200`, one
   `409 already_applied`, and one content write.
6. **Route order:** every literal `/api/skill-evals/*` path resolves to its own handler and is
   not swallowed by a `:param` sibling; `GET /api/skills/:name` is unaffected.
7. **The empty-string trap over the real wire:** a report with `rationale: ""`, `error: ""`,
   `missing_paths_json: ""` persists and reads back `""` rather than 500-ing.
8. **No recursion:** an eval sub-agent given `run_skill_eval` in its allowlist cannot call it
   (`MAIN_AGENT_ONLY_NAMES` parse rejection at `spawn_sub_agent.zig:307`).
9. **SSE:** subscribe to `/api/events?channels=skill_evals` and assert the three event names
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

Plus a cross-platform compile check for every touched Zig file. No `// NEW (plan: …)` comments
— comments explain *why*. Then a PR for review.

---

## 7. Cost model

One run ≈ the Tier-0 pre-pass (free) + N **cache-missed** eval sub-agents × (system prompt + a
small evidence slice + 1-3 tool turns + a report). For 3 skills that is roughly **3 sessions,
20-60 K tokens** — and the fact cache (§4.6 R1) means the *second* session to evaluate a given
skill at a given commit spends **zero** tokens on the intrinsic half, which is the expensive
part. On a busy day with many short sessions this is the difference between a linear and a
near-constant cost curve.

The tool returns verdict counts, the reused count and the token total, so the agent quotes the
cost in its final message; `skill_eval_runs.total_tokens` records it per run, summed exactly
over the returned sub-session ids. `max_evals_per_day` (10) and `max_skills_per_run` (8) bound
it. An eval feature that cannot tell the user what it just cost will be turned off the first
time it surprises them.

---

## 8. Risks

| # | Risk | Assessment / mitigation |
|---|---|---|
| R1 | **The agent simply does not call the tool.** Compliance is best-effort — the price of prompt-driven, and the repo already lives with it (the kanban "move your card" mandate is prompt-only). | **Accepted.** A missed eval is a missing eval, not a broken feature. The rule is phrased like the other `MANDATORY` rules, self-gated ("no skill loaded → skip", so a skip is usually *correct*), and the on-demand path always works. If compliance proves bad, the async arm is additive (R2). |
| R2 | **The agent's final answer waits for the fan-out.** | Bounded by `max_skills_per_run` (8), culled by Tier-0, and cut further by the fact cache; `subagent_progress` SSE shows progress. `spawn_sub_agent` already imposes this latency for up to 20 agents. **Escape hatch, no schema change:** the run row has a `status`, so a poller can drain `running` rows out-of-band later. |
| R3 | **Self-assessment bias** — the agent judges the skill it chose. | The agent decides *when* only: not *what* (the tool reads the ledger), not the *verdict* (fresh sub-agents judge). Residual bias is under-triggering, covered by R1. |
| R4 | **An LLM judge deletes a good skill.** | propose-only default; `delete` requires a `high` finding; the §4.5 verdict function makes "accurate but irrelevant ⇒ keep" structural; no auto-apply for `update`/`rewrite`. |
| R5 | **Evidence hallucination.** | `validateReport()` rejects a finding with empty evidence; Tier-0 facts are pre-computed, so freshness is adjudication, not recall. |
| **R6** | **★ Two agents evaluate the same skill** — duplicate tokens, and two disagreeing verdicts with no way to tell which is authoritative. | **`(skill_key, content_hash, context_key)` fact key + `INSERT OR IGNORE` CAS (§4.6 R1).** One computation, shared; the second session records a cheap session-relative row referencing the same fact id. Functional test §6.3. |
| **R7** | **★ A verdict applied on top of a body it was not computed against** — one agent's proposal silently overwrites another's edit. **The one race that corrupts work.** | `base_content_hash` + the apply-time staleness check, claiming first and refusing with `409 stale` on a mismatch (§4.6 R4). Functional test §6.4. |
| **R8** | **★ Two applies of one verdict** (double-click, two clients). | `UPDATE … WHERE applied_at IS NULL` + `db.changes()` (§4.6 R3); the second gets `409 already_applied`. Functional test §6.5. |
| **R9** | **A crash leaves a `computing` fact row forever**, so the cache never heals and everyone who wants that skill re-does the work — or worse, treats `computing` as an answer. | the row is a **lease**: `computed_at` older than `fact_lease_seconds` is stealable via a guarded `UPDATE` (§4.6 R1). Verification: `verdict_intrinsic != 'computing'` is required on every read, so a stale lease can never be mistaken for a verdict. |
| **R10** | **A fact-cache key collision** — two workspaces' same-named local skills, or one global skill judged against two repos, sharing a cache entry. | `skill_key` includes `canonical_cwd` for local skills; `context_key` includes `canonical_cwd@head_sha` for all of them. Test in W5. |
| **R11** | **Someone "simplifies" R1 away**, assuming it is the safety net, and then R4 rots too. | a code comment stating that R1 is a cache and R4 is the correctness guard, and that removing R1 keeps the feature correct-but-wasteful. |
| R12 | **`""` binds as SQL NULL** → `NOT NULL` failure mid-useCase. | `COALESCE(?, '')` on every free-text write; unit + functional test (precedent: Migration 079's `content`). |
| R13 | **Route shadowing.** | routes under a fresh `/api/skill-evals` prefix, never under `/api/skills/` (§4.11); functional test. |
| R14 | **SSE event dropped silently.** | four-point registration per §4.12 + Zig wire-string test + TS registry test in the same PR. |
| R15 | **`timeout_seconds` is dead** → a wedged sub-agent blocks the tool call. | do **not** rely on it. Pre-existing: a wedged sub-agent wedges `spawn_sub_agent` too. Fixing the dead field is a separate change. |
| R16 | **`use_skill` argument shape changes when 094 lands** → evals stop matching skills. | extractor accepts `skill_name`, then `path`, then `response_content.skill_name`; W9 test fails on a third shape. |
| R17 | **Migration-number collision** with the sibling plan's 094. | this plan takes 095/096; re-checked at W0. |
| R18 | **`cwd` canonicalisation drift** hides a local skill from the pre-pass or forks its cache key. | one `canonicalCwd` helper shared by the evidence builder, the pre-pass, the HTTP path and the fact key. |
| R19 | **A `*Absolute` call on a non-absolute path aborts the process.** | validate `isAbsolute` at the boundary, turn a bad token into a finding (§3.7, PR #639). |
| R20 | **The prompt rule fragments the cacheable prefix** if someone gates it on `hasTool`. | appended unconditionally next to `ReadWorkspaceSessionToolRule`; W7 gets a test asserting it is not inside a `hasTool` branch (rationale in the code comment at `prompts_build_messages_for_agent_prompt.zig:113-119`). |
| R21 | **A duplicate card exists** (`task_1790542119154_4`, in progress) for this same request. | landed as a reviewable plan first; the plan names exact modules so a collision is visible at the file level. |

---

## 9. Decision log

Resolved in this plan:

| # | Question | Decision |
|---|---|---|
| 1 | Hook in the workflow, or a prompt rule? | **Prompt rule** — the agent runs the eval itself (`ReadWorkspaceSessionToolRule` precedent). |
| 2 | Who writes the `spawn_sub_agent` JSON? | **Code**, inside `run_skill_eval`, reusing the extracted batch runner. |
| 3 | Synchronous or queued? | **Synchronous.** Removes the scheduler, claim/reaper, crash recovery and eval session; async stays additive. |
| 4 | **What is the unit of work?** | **`(skill_key, content_hash, context_key)`** — the identity of the question. Two agents evaluating the same body at the same commit share one computation. |
| 5 | **How is a race arbitrated, given no transactions?** | **Single-statement CAS + `db.changes()`** — `INSERT OR IGNORE` for claims, guarded `UPDATE` for transitions and steals. Never SELECT-then-write. |
| 6 | **Intrinsic vs session-relative rubric?** | **Split.** Intrinsic (freshness/accuracy/duplication) is shareable and cached; session-relative (relevance/used/helpfulness) is per-session. This is also what makes "accurate but irrelevant ⇒ keep" structural rather than a judgement call. |
| 7 | Auto-apply verdicts? | **No.** `apply_mode` default `propose`. |
| 8 | Config flag to enable/disable? | **None** — the tool allowlist is the switch, as for every other tool. |
| 9 | Where does "must use the new code" come from? | **Tier-0 deterministic pre-pass**, adjudicated by the sub-agent. |
| 10 | New tables, or reuse routines/background processes? | **New tables** (095/096). Routines are time-triggered and mark success at submit time; background processes have no LLM. |

Still needing a human answer before W8:

1. **Rule wording** — §4.1 carries the full draft; the prompt is prose shipped to every agent.
2. **Latency tolerance** — block the final answer for the fan-out (recommended), or ship the
   async poller from day one?
3. **`skill_eval_facts` shared across users** — recommended shared (no `user_id`, §4.6 R1), since
   global skills already are. Confirm.
4. **Judge model** — inherit the session profile (recommended), or a cheaper `judge_profile`?
5. **Migration numbers** — confirm 095/096; and whether `skill_eval_facts` should split to 097.
6. **`session_skill_events`** — accept the ledger (needed for `listed_without_loading` and a
   stable `content_hash` drift key), or drop that dimension and read `llm_history` only?

---

## 10. Explicitly out of scope

- **No `search_skill`.** Deferred by the sibling plan.
- **No FTS5 index on eval reports.** Small tables, always read by `run_id`/`skill_key`.
- **No cross-skill locking** — only the intrinsic half is shared and it is immutable per key, so
  there is nothing to lock between skills.
- **No workflow-blocking gate.** Evals are informational: they do not fail CI, block a PR, or
  block a kanban transition.
- **No `submit_skill_eval_report` tool** — reports travel in the `spawn_sub_agent` envelope's
  `response` field.
- **No new sub-agent CRUD tool.** A `skill-evaluator` definition is seeded via the existing
  `PUT /api/nalar/config`, and v1 works with none (random fallback).
- **Fixing `timeout_seconds`** and the 0-reader `auto_save_skill` flag — separate changes.

---

## 11. Revision history

**Revision 1 — prompt-driven trigger** (review: *"just put to system prompt, so the ai agent
will run eval self"*). Removed: the `run_completed` flag at `workflow.zig:1598` and the enqueue
inside the teardown `defer`; the whole 5 s poller (tick, `resetStuckRunning`, `claimForRun`,
reaper, `max_concurrent`, `isWorkerRunning`); the separate eval session and `sessions.is_eval`;
the `submit_skill_eval_report` tool; the `enabled`/`auto_after_task`/`eval_on` config axis; one
SSE event. Net: one prompt constant + one tool + one refactor.

**Revision 2 — concurrency** (review: *"what if agent A and agent B eval the same skills?"*).
That question exposed two holes, not one:

1. **Duplicate work and contradictory verdicts.** Fixed by making the unit of work the identity
   of the question — `(skill_key, content_hash, context_key)` — and splitting the rubric so the
   shareable half is *only* the half that depends on the skill and the code, not on the session.
   Added: `skill_eval_facts` (Migration 096), the claim/reuse/steal/publish CAS (§4.6 R1),
   `intrinsic_fact_id`, `content_hash` in the ledger, and the read-time verdict function (§4.5)
   that combines the shared intrinsic half with the per-session half. The cost model changed
   from linear to near-constant in the number of sessions.
2. **A lost update on apply** — the more serious one, which the question did not name: a verdict
   computed against an old body could be applied over a newer one. Added `base_content_hash` +
   the apply-time staleness check, the apply claim CAS, and `409 stale` / `409 already_applied`
   as first-class API responses. §4.6 R4, tests §6.4–6.5.

Also added as a result of the question: §3.8 (the verified no-transaction constraint and the two
CAS idioms it forces), W4 (CAS primitives, landed before any caller), six risks (R6–R11), one
config knob (`fact_lease_seconds`), and the rule's "evals other sessions already ran are reused,
so this is usually cheap" line.

---

## Sibling — `docs/plans/2026-09-28-skills-sqlite-table.md`

Read in full. Its four decision-log entries are taken as given (`is_global` on the wire, keep
the filesystem mirror, add `tags`, no `path` shim). Four consequences land here:

1. **Migration 094 is its claim** → this plan takes 095/096 (§8 R17).
2. **`use_skill` moves from `path` to `skill_name`** → the evidence extractor must accept both,
   or evals stop matching the day 094 lands (§4.3, §8 R16).
3. **It adds `tags`** → the `duplication` dimension can compare tags as well as descriptions
   (today `ParsedFrontmatter` is `{name, description}` only, `skills.zig:68`).
4. **It makes the local skill identity `(cwd, name)`** → which is exactly why `skill_key` must
   include the canonical cwd, or two workspaces' same-named local skills share one cache entry
   (§4.6 R1, §8 R10).
