# Skill Evals — HANDOFF

> Updated 2026-09-29 at the end of the audit + increments 7-10 session.
> Worktree: `/home/ginwa/.config/nalar/.worktrees/skill-evals-impl-1790542117855`
> Branch: `worktree/skill-evals-impl-1790542117855`, PR **#717**
>
> **Read this first, then the plan in PR #703** (`docs/plans/2026-09-27-skill-evals.md`).
> This file is the operational state; the plan is the design and its rationale.

---

## 1. Status: all ten increments landed

`zig build test --summary all` → **3819 pass, 8 skip, 0 fail**.
`tests/functional/skill_evals_api_test.py` → **12 pass**.
Frontend: `vue-tsc` clean; the 4 new Evals-tab specs pass. **25 vitest failures
are PRE-EXISTING** (verified by stashing) and are not ours.

| # | What | Files |
|---|---|---|
| 1 | Migrations **095** (`session_skill_events`) + **096** (the three eval tables) | `src/migrations/migration.zig` |
| 2 | `config.json` master switch `skill_evals.enabled`, **default OFF** | `src/modules/config/Config.zig` |
| 3 | The usage ledger, written from `handle_tool.zig` | `src/agentic_loop/skill_evals_db.zig` |
| 4 | `validateReport()`, `decideVerdict()`, the CAS primitives | same |
| 5a | `SkillEvalToolRule` + `run_skill_eval` + Tier-0 drift eval | `core.zig`, `run_skill_eval.zig`, `skill_evals_drift.zig`, `workflow.zig`, `tools_equipped.zig` |
| 6 | The read surface: `GET /api/skill-evals/{runs,summary}` | `src/http_handlers/skill_evals.zig`, `main.zig` |
| 7 | **The apply endpoint** `POST /api/skill-evals/results/apply` | same + `tests/functional/skill_evals_api_test.py` |
| 8 | **The `skill_evals` SSE channel** (all four registration places) | `skill_eval_events.zig`, `unified_events_sse.zig`, `api/index.ts`, `helpers/sseBus.ts` |
| 9 | **The LLM judge tier** + the extracted batch runner | `sub_agent_batch.zig`, `skill_eval_judge.zig`, `run_skill_eval.zig` |
| 10 | **The frontend Evals tab** | `SkillEvalsPanel.vue`, `SidebarDiffPanel.vue`, `SidebarDiffPanel.evalsTab.spec.ts` |

---

## 2. The audit — what it found

The previous session stopped mid-audit by choice. This session ran a
**systematic audit with four parallel sub-agents** (memory/ownership, SQL
correctness, edge cases + test quality, wiring). It found **more bugs than the
handoff listed**, including one that made the whole feature dead.

### The critical one

**`run_skill_eval` was never injected into any tool list.** It was added to
`UNIFIED_TOOL_REGISTRY()` — the *dispatcher's* table — but
`filterAndMergeTools` iterates `equips()`, the *tool-list builder's* table. The
config injection loop could never match, so the tool never reached the LLM.
**The feature had never worked.** A test in `prompts_test.zig` certified it as
present by grepping the whole file for the string, which is why it passed
review. That test now asserts membership of `equips()`.

### Everything else fixed

| Bug | Class |
|---|---|
| `.reusable` dropped `intrinsic_fact_id` | reused verdicts stored with **no evidence**; `shared_fact` inverted |
| `claimFact` bound 3 NOT NULL columns raw | an empty `context_key` became SQL NULL, `INSERT OR IGNORE` silently skipped the row, killing the fact cache with no error |
| `runEval` never finalized the run on error | stuck `running` **and** permanently blocked re-eval (the partial unique index still held it) |
| `claimRun`'s error path | leaked `run_id`; reported a DB failure to the model as "no skill was loaded" |
| `stealFact` had no production caller | one crash poisoned a fact for that question forever |
| `markResultStale` wrote a JSON array into `proposed_diff` | that column means "the text this verdict would write into the skill" |
| `listResults`' LEFT JOIN lacked `!= 'computing'` | a stuck lease surfaced as a scored fact |
| Ledger row ids collided (ordinal always 0) | two events in one nanosecond lost one row silently |
| Drift: bare filenames stat'd against the repo root | healthy skills reported stale, and the false positive was **cached into the shared fact** |
| Drift: a glob's directory prefix (`src/` from `src/**/*.zig`) stat'd as a path | meaningless check |
| Drift: every `statFile` error reported as "does not exist" | a permission error is "cannot tell", not rot |
| Drift: a cwd that does not exist | every relative reference became a false miss — and a removed worktree is routine here |
| Drift: `startsWith("http")` | swallowed real files like `http_server.zig` |
| Drift: every absolute path skipped | a skill naming one was never checked |
| Two vacuous tests | `has_high` is a hard-coded `false`, so asserting on it proved nothing |

### Deferred (documented, not fixed)

- **`context_key` has no commit hash.** The design says "the same body *at the
  same commit*", but the key is `"{cwd}@"` — the commit slot is always empty.
  So a fact is reused across code changes, and the drift signal itself goes
  stale. Needs a `git rev-parse` call; design-level.
- **`user_id` is never written or filtered** on the authed read routes. Both
  tables carry the Migration 093 owner column and neither writer sets it, so
  `GET /api/skill-evals/{runs,summary}` exposes every user's eval history.
  Needs an owner write + `auth_common.ownerVisibilityClause`.
- **`db.changes()` is read outside the backend mutex.** Repo-wide idiom, not
  introduced here; a fix is repo-wide.
- **`max_evals_per_day` is never enforced.** Harmless while Tier 0 is free.
- **`skill_key` is hardcoded `global:`** even when the body came from the local
  scope.

---

## 3. The invariant you must not break

**The intrinsic / session-relative split is enforced in the schema.**

- `freshness`, `accuracy`, `duplication`, `missing_paths_json`, `findings_json`,
  `proposed_content` → **only** on `skill_eval_facts`
- `relevance`, `used`, `helpfulness` → only on `skill_eval_results`
- `skill_eval_results.intrinsic_fact_id` → references the fact; read it with a
  `LEFT JOIN` (and `AND f.verdict_intrinsic != 'computing'`)

They are split because the intrinsic half depends only on the skill body and the
code state, so it is **shareable and cached** across sessions. Copying intrinsic
fields onto each result would reintroduce exactly the duplication the fact cache
exists to remove.

Two more structural invariants:

- **Tier 0 never emits severity `high`.** `decideVerdict` promotes any high
  finding to `delete`. A renamed path means *update*, not destruction, so Tier 0
  caps at `medium`. Deletion is reserved for the LLM tier. The tests now assert
  this on the **emitted severities**, not on the hard-coded `has_high` flag.
- **The agent chooses WHEN, never the verdict.** `run_skill_eval` takes **zero
  parameters** and reads the skill set from the ledger.

---

## 4. Zig gotchas in this repo — all of them cost a build cycle

- **No default parameter values.** `fn f(x: bool = false)` does not compile.
- **A `///` doc comment inside a parameter list is a syntax error.** Use `//`.
- **Struct declarations must come after all fields.**
- **Two prompt re-export layers.** `src/modules/agent/prompts/prompts.zig` (from
  `core.zig`) **and** `src/modules/agent/prompts.zig` (from the former).
- **`expectColumnsEqual(list, expected)` needs a slice**, `&[_][]const u8{...}`.
- **`zig build test` does not forward `--test-filter`.** Budget ~1 min per run.
- **New test files are not discovered automatically.** Add
  `_ = @import("x.zig");` to `src/agentic_loop/test_runner.zig`.
- **Never `git commit -m "... \`word\` ..."`** in a double-quoted string — that is
  shell command substitution. Use `cat > f <<'EOF' … EOF` then `git commit -F f`.
- **`std.json.parseFromSlice` borrows slices into its input.** Deinit the parsed
  value BEFORE freeing the buffer, or the testing allocator reports a leak.

---

## 5. House rules for this repo that apply

- **Never verify HTTP behaviour with a live server + curl.** Use
  `tests/functional/harness.py`. Do not touch port 8081.
- **The `*Absolute` filesystem family asserts on a non-absolute path and aborts
  the whole process** (PR #639). `skill_evals_drift` uses
  `std.Io.Dir.cwd().statFile` precisely because the paths come from LLM text.
- **`SqliteBackend.exec` binds an empty slice as SQL `NULL`;** `query`/`queryRow`
  do not. Every `NOT NULL` free-text column needs `COALESCE(NULLIF(?, ''), '')`.
- **No usable multi-statement transaction** — every invariant must be a single
  guarded statement decided by `db.changes()`.
- **No `// NEW (plan: …)` comments.**
- **Frontend:** every view switch must be deep-linkable — extend the existing URL
  param union, mount reads it back, clicks write with `router.replace`. No
  `try`/`catch` in new frontend code; a failure must be in the type, not a silent
  `[]`.

---

## 6. What is left

Nothing from the original ten increments. The deferred items in §2 are the
candidates for a follow-up, in rough priority order:

1. `user_id` on the read routes (a real cross-user exposure).
2. `context_key` with a commit hash (the cache is currently wrong across code
   changes).
3. A `config.json` knob for the judge tier — it is reachable only via
   `RunArgs.judge_enabled` today, because turning on a token-spending fan-out is
   a cost decision, not a code one.
4. `max_evals_per_day` enforcement.
