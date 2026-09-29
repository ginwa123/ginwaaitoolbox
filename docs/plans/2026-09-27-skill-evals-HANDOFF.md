# Skill Evals — HANDOFF

> Written 2026-09-27 at the end of a long session, for the agent picking this up.
> Worktree: `/home/ginwa/.config/nalar/.worktrees/skill-evals-impl-1790542117855`
> Branch: `worktree/skill-evals-impl-1790542117855` (base `origin/main` @ `dea0b835`)
>
> **Read this first, then the plan in PR #703** (`docs/plans/2026-09-27-skill-evals.md`).
> This file is the operational state; the plan is the design and its rationale.

---

## 1. Read this first: the last session ended mid-audit

The previous session was asked to *"fix the bugs, add many testcase to handle edge
cases"* and **stopped after ~10 minutes of spot-checking**, for two reasons worth
knowing before you start:

1. **The author's own review quality was degrading** at the end. It caught two bugs by
   luck of where it looked, and had already written two tests in the same session that
   passed review-by-eye and only failed at runtime (a `''` bound to a `NOT NULL`
   column, and a `listResults` selecting columns from the wrong table). On a feature
   whose entire purpose is judging correctness, a confidently-wrong test is worse than
   no test. So it handed over rather than ship a half-audited patch.
2. **The two bug-hunt sub-agents it spawned returned nothing.** No systematic audit
   exists. What follows is spot-checking only.

**So: assume there are more bugs, and the ones listed in §3 are the ones that happen
to have been *found*, not the ones that exist.**

---

## 2. What is done and working

Seven increments, all on `worktree/skill-evals-impl-1790542117855`, PR **#717**.
`zig build test --summary all` at head `4d5b37f8`: **3770 pass, 8 skip, 0 fail**.

| # | What | Files |
|---|---|---|
| 1 | Migrations **095** (`session_skill_events`) + **096** (`skill_eval_facts` / `_runs` / `_results`) | `src/migrations/migration.zig` |
| 2 | `config.json` master switch `skill_evals.enabled`, **default OFF** | `src/modules/config/Config.zig` |
| 3 | The usage ledger is **written** (one call site in `handle_tool.zig`) | `src/agentic_loop/skill_evals_db.zig` |
| 4 | `validateReport()`, `decideVerdict()`, the CAS primitives | same |
| 5a | `SkillEvalToolRule` prompt rule + `run_skill_eval` tool + Tier-0 drift eval, injected only when the switch is on | `core.zig`, `run_skill_eval.zig`, `skill_evals_drift.zig`, `workflow.zig`, `tools_equipped.zig` |
| 6 | The read surface: `GET /api/skill-evals/runs` + `/summary` | `src/http_handlers/skill_evals.zig`, `main.zig` |

**Working end to end today:** set `"skill_evals": { "enabled": true }` in
`~/.config/nalar/config.json`, run a session that loads a skill, and the agent
evaluates it before answering. Verdict, rationale, missing paths and the shared
intrinsic fact are stored, and readable over HTTP. **Zero token cost** — Tier 0 is
mechanical (path existence + structural checks).

The plan is PR **#703**; its §4.6 (concurrency design) and §11 (revision history)
are the parts most likely to save you time.

---

## 3. Bugs found — fix these first

### 3.1 `sessionSkillSet` takes a pointer into an `ArrayList` that can reallocate

`src/agentic_loop/skill_evals_db.zig:1458-1468`

```zig
if (slot == null) {
    try out.append(allocator, .{ ... });
    slot = &out.items[out.items.len - 1];   // <-- pointer into the backing array
}
const it = slot.?;
```

`out` is a `std.ArrayList(SessionSkillUse)`. On a later iteration another
`append` may reallocate, invalidating any pointer held from an earlier one. It
happens to be safe *today* only because the pointer is re-derived each iteration and
nothing holds one across an `append` — that is luck, not design. It becomes a
use-after-free the moment the loop is refactored, and it is invisible in review
because the pattern looks correct.

**Fix:** make it an index, not a pointer.

```zig
var idx: ?usize = null;
for (out.items, 0..) |it, i| {
    if (std.mem.eql(u8, it.skill_name, name)) { idx = i; break; }
}
if (idx == null) {
    try out.append(...);
    idx = out.items.len - 1;
}
const it = &out.items[idx.?];
```

**Add a test that grows the set past the reallocation threshold** (e.g. 64 distinct
skill names) and asserts every one is aggregated correctly. The current test only
uses two, so it cannot catch this.

### 3.2 `FactRow.deinit` frees fields that may not be allocated

`src/agentic_loop/skill_evals_db.zig:801-808` frees six fields unconditionally,
while the sibling types guard:

```zig
// Analysis.deinit (skill_evals_drift.zig:61)      — guarded
if (self.findings_json.len > 0) allocator.free(self.findings_json);

// RunOutcome.deinit (run_skill_eval.zig:85)        — guarded
if (self.run_id.len > 0) allocator.free(self.run_id);

// FactRow.deinit (skill_evals_db.zig:801)         — NOT guarded
allocator.free(self.id);
allocator.free(self.findings_json);
...
```

`FactRow` is only ever built by `readFact`, which always dupes, so it is **safe
today**. It is a trap for the next person who constructs one with a `&.{}` default.
Make it consistent with its two siblings.

### 3.3 Bugs found and already fixed earlier in the session

Recorded so you do not reintroduce them, and because each one shows a *class*:

| Bug | Class | Note |
|---|---|---|
| `claimRun` bind list in **signature** order, not placeholder order | silent column mix-up | `trigger` never landed as `self_prompt`, so the partial unique index silently stopped applying and "one run per session" quietly vanished. Caught only by a **row-count** assertion. Assert on state, not on return values. |
| `runEval` duped `run_id` without freeing the original | leak | one leaked allocation per run; the testing allocator caught it |
| `run_skill_eval` wrote the loop index into `sub_session_id` | semantic misuse | that column means "the sub-agent that produced the session-relative half" (LLM tier). The Tier-0 anchor is the **ledger's** `loop_index` / `llm_history_id`. |
| `listResults` selected `missing_paths_json` and `freshness/accuracy/duplication` from `skill_eval_results` | wrong table | those are **intrinsic** and live on `skill_eval_facts`. Now read via `LEFT JOIN ON f.id = r.intrinsic_fact_id`. `ResultRow` carries a comment: do not add those columns to the result. |
| new test bound `''` to a `NOT NULL` column via `exec` | the empty-slice→NULL trap | omit the column so the schema default applies |

---

## 4. The invariant you must not break

**The intrinsic / session-relative split is enforced in the schema.**

- `freshness`, `accuracy`, `duplication`, `missing_paths_json`, `findings_json`,
  `proposed_content` → **only** on `skill_eval_facts`
- `relevance`, `used`, `helpfulness` → only on `skill_eval_results`
- `skill_eval_results.intrinsic_fact_id` → references the fact; read it with a
  `LEFT JOIN`

They are split because the intrinsic half depends only on the skill body and the
code state, so it is **shareable and cached** across sessions; the session-relative
half is not. Copying intrinsic fields onto each result would reintroduce exactly the
duplication the fact cache exists to remove — and would let two sessions disagree
about the same skill's freshness.

Two more structural invariants worth keeping in mind:

- **Tier 0 never emits severity `high`.** `decideVerdict` promotes any high finding to
  `delete`. A renamed path means *update*, not destruction, so Tier 0 caps at
  `medium` and a test asserts `decideVerdict(analysis) != .delete`. Deletion is
  reserved for the LLM tier, which can judge that a skill's subject matter is *gone*
  rather than *moved*.
- **The agent chooses WHEN, never the verdict.** `run_skill_eval` takes **zero
  parameters** and reads the skill set from the ledger, so it cannot cherry-pick
  around the skill it had to work around.

---

## 5. Edge cases that need tests

The behaviour below is implemented but **not** covered. Each is cheap to add and
each is a place a reasonable refactor breaks something.

### `skill_evals_drift.zig`
- skill name / path containing `%`, `'`, `"`, a newline, or a backslash
- a token that is only an extension (`.zig`) — already partly covered
- a body at exactly `MAX_BODY_BYTES` and at `MAX_BODY_BYTES + 1`
- more than `MAX_REFERENCED_PATHS` distinct paths (the cap must hold, and the
  overflow must not error)
- `file:line:col` and `file:999999999999` (line-suffix stripping must not eat a
  legitimate colon)
- `cwd` empty vs. a cwd that does not exist vs. a relative cwd
- a path that resolves to a **directory** rather than a file
- a symlink loop / permission-denied path → must produce a finding, not crash
- `extractPaths` on a body that is only delimiters, only whitespace, or only
  `//`
- determinism: same body twice → byte-identical JSON

### `run_skill_eval.zig` / `skill_evals_db.zig`
- a session whose ledger has a skill with `event='listed'` only
- a skill that was edited between the read and the eval (body hash differs) — the
  `changed` rationale branch has no test
- `max_skills = 0` (should evaluate nothing, not crash)
- a run id that collides (impossible in practice — prove the index handles it)
- `verdictCounts` / `listRuns` on an empty table
- `limit = 0`, `limit = 99999` (capped), `limit = "abc"` (400)
- a result whose `intrinsic_fact_id` points at a **deleted** fact → the `LEFT JOIN`
  must yield `""` for the scores, not NULL and not a crash
- `FactRow` whose stored `verdict_intrinsic` is garbage → must degrade to
  `needs_human` (the code says so; nothing tests it)
- a score stored out of range (`9`) → `parseScore` clamps to 3; test it

### `skill_evals.zig` (HTTP)
- `?limit=0` and `?limit=abc` → 400 with the documented message
- `?run_id=` present but matching **no** run → 200 with empty `runs` (not 404, not
  500)
- `?session_id=` matching nothing
- a body containing `"` — confirms the JSON escaping survives
- the response is valid JSON with **no** double-encoded `missing_paths` confusion

### Prompt / wiring
- assert `run_skill_eval` is reachable **only** when `skill_evals.enabled` (the
  injection block in `filterAndMergeTools` currently has no test)
- assert a **sub-agent** never receives `run_skill_eval` even with the switch on
- assert the tool is absent from `equips()`/catalog expectations that count tools

---

## 6. Remaining work, in order

1. **Finish the audit** (§1) — fix §3.1, §3.2, then hunt systematically. The two
   bug-hunt sub-agent prompts from the previous session are in that session's
   transcript; re-issue them if you have access, or use this checklist:
   memory/ownership → SQL correctness → logic → TOCTOU → edge cases → test quality.
2. **Add the edge-case tests** in §5. Run with `zig build test --summary all`
   (~1 min; the testing allocator will catch leaks).
3. **Increment 7 — the apply endpoint.** `POST /api/skill-evals/results/apply?result_id=`
   with `409 stale` and `409 already_applied`. `claimApply` / `releaseApply` /
   `markResultStale` and the `base_content_hash` guard **already exist** from
   increment 4; only the handler and the hash re-check are missing.
   **Route order:** the `/apply` literal must be registered **before** any
   `:result_id` route.
4. **Increment 8 — the `skill_evals` SSE channel.** Event names must be registered in
   **all four** places or the browser drops them silently (the `session_unknown` /
   PR #215 bug class): the Zig event-type ladder, `api/index.ts` `additionalEventTypes`
   (~:3738-3799), an `onEvent` dispatch branch, and `SseEventMap`
   (`sseBus.ts:25-43`) + `UnifiedChannels` (`api/index.ts:3620-3656`).
5. **Increment 9 — the LLM judge tier.** Sub-agent fan-out filling
   `relevance`/`used`/`helpfulness` and able to reach `delete`. Needs the batch
   runner extracted from `tools_exec_spawn_sub_agent.zig:413-630` so the payload is
   serialized **by code**, not by a model — the required-allowlist / max-20 /
   no-main-agent-only rules are exactly what an LLM gets wrong.
6. **Increment 10 — frontend Evals tab + functional tests** with a scripted stub LLM
   (pattern: `tests/functional/anthropic_chat_headers_test.py:69-94`;
   `harness.py` `port=None` picks 20000-32000, **never 8081**).

---

## 7. Zig gotchas in this repo — all of them cost a build cycle

- **No default parameter values.** `fn f(x: bool = false)` does not compile
  ("expected ',' after parameter"). This is why `filterAndMergeTools` has a
  **required** `inject_skill_evals: bool` and its ~15 call sites were updated.
- **A `///` doc comment inside a parameter list is a syntax error.** Use `//`.
- **Struct declarations must come after all fields.** A `const Foo = struct` between
  two fields gives "field before declarations here".
- **Two prompt re-export layers.** `src/modules/agent/prompts/prompts.zig` (from
  `core.zig`) **and** `src/modules/agent/prompts.zig` (from the former). Adding a
  constant to `core.zig` alone does not compile.
- **`expectColumnsEqual(list, expected)` needs a slice**, `&[_][]const u8{...}` —
  a tuple literal gives "tuple field index must be comptime-known".
- **`zig build test` does not forward `--test-filter`**, and the built test binary
  rejects it too. Budget ~1 min per run.
- **New test files are not discovered automatically.** Add
  `_ = @import("x.zig");` to `src/agentic_loop/test_runner.zig` (its header explains
  this).
- **Never `git commit -m "... \`word\` ..."`** in a double-quoted string — that is
  shell command substitution and it silently eats the word. Use
  `cat > f <<'EOF' … EOF` then `git commit -F f`.

---

## 8. House rules for this repo that apply

- **Never verify HTTP behaviour with a live server + curl.** Use
  `tests/functional/harness.py` (see §6.6). It picks a free port and points `HOME` at
  an isolated tmpdir. Do not touch port 8081.
- **The `*Absolute` filesystem family asserts on a non-absolute path and aborts the
  whole process** (PR #639). A `catch` cannot save you. `skill_evals_drift` uses
  `std.Io.Dir.cwd().statFile` precisely because the paths come from LLM-authored text.
- **`SqliteBackend.exec` binds an empty slice as SQL `NULL`;** `query`/`queryRow` do
  not. Every `NOT NULL` free-text column needs `COALESCE(NULLIF(?, ''), '')`, and
  `WHERE (? = '' OR col = ?)` is a valid optional-filter idiom **only** in `query`.
- **No usable multi-statement transaction** — `exec` releases its mutex per call, so
  every invariant must be a single guarded statement decided by `db.changes()`.
  SELECT-then-write is always a TOCTOU bug here.
- **No `// NEW (plan: …)` comments.** Explain *why* in one sentence, or not at all.
- **Frontend:** every view switch must be deep-linkable — extend the existing URL
  param union, mount reads it back, clicks write with `router.replace`. No
  `try`/`catch` in new frontend code; a failure must be in the type, not a silent
  `[]`.
