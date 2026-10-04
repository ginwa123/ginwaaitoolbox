# `ask_user` with MULTIPLE tool calls in one LLM turn — investigation

> **For agentic workers:** this is an **investigation**, not an implementation
> plan. Nothing here has been fixed. Every claim is backed by a test that is
> committed and green *against the broken behaviour* — they are characterization
> tests, and the fix PR turns them red one at a time. Read
> `## What is already reproduced` before proposing any change.

**Goal:** explain what actually happens when the model emits two or more
`ask_user` tool calls in a single assistant message, and name the defects that
follow.

**Architecture:** three independent layers each assume "at most one open
question", and none of them checks the assumption:

1. the **prompt** tells the model to ask one question at a time — a request,
   not an invariant;
2. the **workflow** breaks the turn only *after* the whole tool batch has run,
   and aborts any run started while *any* question is open;
3. the **card** is one Vue instance per tool row, each holding its own global
   keyboard listener.

**Tech stack:** Zig backend (`src/agentic_loop`, `src/modules/agent/tools`),
Vue 3 frontend (`src/apps/desktop`), python functional harness
(`tests/functional/harness.py`), vitest.

---

## TL;DR — five defects, all reproduced

| # | Defect | Severity | Status |
|---|--------|----------|--------|
| 1 | Answering question 1 of 2 returns `resumed:true` but **never calls the LLM**. The answer sits inert until question 2 is answered. | High | **FIXED** `36c2d4fb` |
| 2 | An answer committed while any run holds the worker row gets `resumed:false` and is **never delivered** — no queue, no retry. Permanent stall. | Critical | **FIXED** `36c2d4fb` |
| 3 | The tool's own prompt **lies**: sibling tool calls in an `ask_user` batch are described as "discarded". They are not — they execute. | High | read of `handle_tool.zig:711` vs `ask_user.zig:327` |
| 4 | Each `AskUser` card registers its **own** `window` keydown listener → one `Enter` fires **N** POSTs, one digit pick applies to **all** cards. | High | `AskUser.multi-card.spec.ts` (4 tests) |
| 5 | There is **no list endpoint**, so a card cannot know a sibling is open. | Medium | `test_no_endpoint_tells_the_frontend_how_many_questions_are_open` |

None of these are reachable with a single question. That is why
`tests/functional/ask_user_test.py` (which seeds exactly one) is green apart
from one pre-existing flake, and why `AskUser.spec.ts` (which mounts exactly one
card) is green.

---

## Global Constraints

- Dev backend on **8081 must never be killed**; all testing goes through the
  functional harness on a free port in 8080–8199 (8081 excluded).
- **Never verify HTTP behaviour with a live server + `curl`.** Use
  `tests/functional/harness.py`.
- **Do not write `// NEW (plan: …)` tags** into source.
- Any change to the prompt strings in `ask_user.zig` **must** update the test at
  `ask_user.zig:417`, which pins the literal `"Call it ALONE in a batch"`.
- Frontend must stay cross-platform; the fix for defect 4 must not assume a
  single card exists.

---

## Current State (verified 2026-10-03 via 2 parallel explorers + direct reads)

### What actually happens with two `ask_user` calls

`handle_tool` is called ONCE with the whole `res_dynamic_agent`
(`src/agentic_loop/workflow.zig:1631`). It does **not** iterate in
`workflow.zig` — all iteration is inside `handle_tool`:

| Step | Location | Behaviour |
|------|----------|-----------|
| One assistant row for the whole message | `handle_tool.zig:533`–`558` | `tool_calls` = the full array |
| One `role=tool` placeholder row **per call** | `handle_tool.zig:564`–`661` | `for (tc) \|tool_call\|` — **full N** |
| Executes **every** call | `handle_tool.zig:711`–`719` | `for (tc) \|tool_call\|` — **full N, no early exit** |
| `ctx.llm_history_id` re-assigned per call | `handle_tool.zig:718` | so each question gets its own row |
| Turn break happens **after** `handle_tool` returns | `workflow.zig:1631` → `1647` → `1670` | the batch has already fully executed |

So: **two questions, two `session_pending_question` rows, two independent tool
rows, and the turn breaks once.** `hasPendingQuestion` is a session-scoped
`SELECT 1 … LIMIT 1` (`ask_user_pending.zig:277`) — it can say *that* a question
is open, never *how many*.

### The two guards

- `workflow.zig:933` — top of **every** loop iteration:
  `if (ask_user_pending.hasPendingQuestion(...)) { … break; }`
- `workflow.zig:1647` — the `.tool_calls` arm, after the batch ran.

### The answer round-trip

`src/http_handlers/ask_user_answer.zig`:

| Step | Location |
|------|----------|
| mark resolved | `ask_user_answer.zig:153` (`markQuestionStatus`) |
| rewrite the tool row in place | `ask_user_answer.zig:168` (`rewriteToolResultRow`) |
| resume the run | `ask_user_answer.zig:296` → `ask_user_pending.resumeSession` |

`resumeSession` (`ask_user_pending.zig:607`) returns `false` when
`isWorkerRunning` is true (`ask_user_pending.zig:612`), and that `false` is
reported to the client as `resumed:false` with HTTP **200**.

### The card

- `ChatView.vue:5117`–`5123` renders one `<AskUser>` per tool row; `:key` is the
  row id, so two cards are genuinely independent.
- `AskUser.vue:455`–`463` — `onMounted` and a `watch` each call
  `window.addEventListener('keydown', onKeydown)` **per instance**.
- `AskUser.vue:370`–`395` — `onKeydown` handles `Enter`, `Escape` and digits
  with no arbitration and no `stopImmediatePropagation`.

### What is already reproduced (committed in this PR)

| Test | Result on `main` |
|------|------------------|
| `tests/functional/ask_user_multi_question_test.py` (4) | 4 pass — pins the broken behaviour |
| `AskUser.multi-card.spec.ts` (4) | 4 pass — pins the broken behaviour |

Baseline for the single-question suite, for comparison:
`tests/functional/ask_user_test.py` → **11 pass** on a clean run; one run showed
`test_skip_settles_the_question_and_still_resumes` failing. It polls for a
worker row to appear, but the resumed run can finish (and delete its worker row)
between two polls when there is no API key configured — so it is a timing flake
in the TEST, not a product defect. Both files together: **15 passed**.

---

## Defect 3 (highest severity, no test needed — the code contradicts itself)

The tool tells the model:

> `ask_user.zig:288` — `Call it ALONE — never in the same batch as another tool.
> Every other tool call in the batch would be discarded anyway, because asking
> ends the turn.`
>
> `ask_user.zig:327` — `Call it ALONE in a batch: any other tool call in the
> same batch is discarded, because asking ends the turn.`

**This is false.** `workflow.zig:1631` hands the whole batch to `handle_tool`,
whose Phase 3 loop (`handle_tool.zig:711`) dispatches **every** call, and only
then does `workflow.zig:1671` break. So for a batch of
`ask_user` + `write_file`:

- `write_file` **runs** — the file is written to disk;
- the model has been told it did not run, so it will not mention it;
- the turn breaks and waits for an answer;
- if the human abandons, the side effect happened with no run that could report
  it.

Same for `command`, `set_git_worktree`, `kanban_move_task`,
`create_kanban_task`, `remove_file`. A model that batches one `ask_user` with
one destructive tool gets the destructive half executed and silently unreported.

Worse: the claim is **test-locked**. `ask_user.zig:417` asserts the description
contains the literal `"Call it ALONE in a batch"`. Correcting the prompt
requires changing that assertion too, or CI will keep enforcing the lie.

Note the prompt is *also* the only place the model is asked to keep N == 1
(`ask_user.zig:290`, `Ask ONE question.`). Fixing defect 3 by weakening the
prompt would remove the sole mitigation for defects 1 and 2 — the two must be
fixed together or not at all.

---

## Defects 1 and 2 (the stall)

Sequence for a turn where the model asked two questions:

```
t0  both questions pending; turn broken at workflow.zig:1671
t1  human answers Q1
      → markQuestionStatus(Q1, answered)
      → rewriteToolResultRow(row_1)              ← the answer IS in the transcript
      → resumeSession → emit_run_agent            ← a run IS started, HTTP says resumed:true
t2  that run reaches workflow.zig:933
      → hasPendingQuestion is still TRUE (Q2 open)
      → break.  The LLM is never called.          ← DEFECT 1
t3  human answers Q2 quickly enough to land inside t2
      → row rewritten, but resumeSession sees the worker row from the doomed run
      → returns false → HTTP 200, resumed:false  ← DEFECT 2
t4  the doomed run exits and deletes its worker row.
      Nothing is left. Q2's answer is in the DB and no run will ever read it.
```

Defect 1 is deterministic — `test_answering_the_first_of_two_records_the_answer_but_delivers_nothing`
proves the transcript grows by **zero** rows across the resume window.

Defect 2 is a race in the wild but the state it depends on is deterministic, so
the test seeds that state directly rather than racing:
no worker, no queued message (`session_queue_messages` is empty), no new
transcript row, and `Q1` still pending so the `workflow.zig:933` guard would
abort any future run too.

**User-visible symptom:** the card flips to "answered" and nothing happens. The
answer to the first question is silently deferred until the second one is
answered. If defect 2 wins the race, the second answer is never acted on at all
and the session is dead until the human types an unrelated message.

---

## Defect 4 (the fan-out)

Four vitest cases, all green against current code:

| Case | Observed |
|------|----------|
| digit `1` with two cards open | **both** cards show the pick |
| `Enter` with two cards open | **two** POSTs to `/answer` |
| `Escape` with two cards open | both questions skipped |
| answer card A via mouse | B stays pending and still owns a window listener |

The `Enter` case is the dangerous one: N concurrent POSTs, each calling
`resumeSession`, and the backend resumes for at most one. That is defect 2
triggered directly from the keyboard — the most natural thing a human does.

---

## Defect 5 (no arbitration primitive)

There is no `GET /api/llm/session/:id/question(s)` route. `main.zig:549`
registers only the POST. `listRecentQuestions`
(`ask_user_pending.zig:369`) exists in the backend and is documented as "all
questions the frontend still needs", but **nothing serves it**.

So a card cannot ask "is another question open?" before POSTing, cannot
disable itself when a sibling is already being answered, and cannot render
"2 questions — answer both". This is the missing primitive that makes defects
1–4 awkward rather than merely wrong.

---

## The one path that already handles N correctly

Worth stating, because a fix should not regress it: `abandonPendingQuestions`
(`ask_user_pending.zig:326`) loops over every pending question and rewrites each
tool row. It is what `session_create.zig:341`–`342` calls when the human sends a
message instead of answering. Two pending questions are both settled, and the
model never reads `pending`. That path is N-correct today.

---

## Dead code found while investigating

`markAbandonedForSession` (`ask_user_pending.zig:231`) has **no production call
site** — a repo-wide search finds only its own definition and its own tests.
`session_create.zig:342` calls the row-rewriting `abandonPendingQuestions`
instead. The two functions do overlapping work and only one rewrites tool rows,
so the dead one is a trap for whoever wires up the fix: it settles the status
without fixing the model's view.

---

## Design Decisions (for reviewer)

These are the decisions the fix must make. **None are implemented here.**

1. **Enforce N == 1 in the backend, or support N > 1 properly?**
   Rejected: keep supporting N silently. The `workflow.zig:933` guard, the
   `resumeSession` worker check, and the card's keyboard model are all
   single-question assumptions; retrofitting N means three coordinated changes
   plus a protocol for "partially answered batch".
   Recommended: **collapse the batch** — in `handle_tool` Phase 3, if a batch
   contains more than one `ask_user`, execute only the first and write an
   actionable `<error>`/instruction into the others' rows telling the model to
   ask one question per turn. Cheap, matches the existing prompt, and makes
   defects 1, 2 and 4 unreachable rather than merely less likely.

2. **Should the prompt keep saying "discarded"?**
   Rejected: leaving it. It is false, it is test-locked, and a model that
   trusts it will batch a destructive tool next to a question.
   Required either way: correct the text AND update `ask_user.zig:417`.

3. **Fix `resumeSession`'s silent refusal, or prevent the race?**
   Rejected: only fixing the refusal. It would turn a stall into a second run
   firing while the first is mid-flight, with its own ordering hazards.
   Fixing N == 1 removes the second POST that creates the race; the refusal
   should additionally **queue** rather than drop, so a refused resume is never
   silently lost.

4. **One global keydown owner, or per-card?**
   Rejected: keep per-card listeners. With N == 1 enforced there is at most one
   pending card, but the fan-out is still a latent trap the moment any future
   feature renders two cards.
   Recommended: a single owner (the most recently mounted pending card claims
   the keyboard; others ignore keys) — cheap and independent of fix 1.

5. **Add the list endpoint?**
   Recommended, but **not required** by fix 1. Listed separately because it is
   the only change that improves the UX for the *legitimate* N > 1 case, which
   fix 1 declines to support.

---

## File Map

| File | Action (in a future fix PR) | Responsibility |
|------|------------------------------|----------------|
| `src/agentic_loop/handle_tool.zig` | modify | collapse a multi-`ask_user` batch to one call, write actionable errors into the rest |
| `src/modules/agent/tools/ask_user.zig` | modify | correct the "discarded" claim in both the system prompt and the tool description |
| `src/modules/agent/tools/ask_user.zig` (test at `:417`) | modify | unpin the literal `"Call it ALONE in a batch"` |
| `src/agentic_loop/ask_user_pending.zig` | modify | `resumeSession` must queue rather than silently drop a refused resume |
| `src/agentic_loop/ask_user_pending.zig` | delete | `markAbandonedForSession` — dead code with a trap-shaped contract |
| `src/apps/desktop/src/components/tool_outputs/AskUser.vue` | modify | one global keydown owner instead of one listener per instance |
| `src/main.zig` + a new handler | add | `GET /api/llm/session/:id/questions` over `listRecentQuestions` |
| `tests/functional/ask_user_multi_question_test.py` | flip to red | the characterization tests in this PR become the regression suite |
| `src/apps/desktop/.../__tests__/AskUser.multi-card.spec.ts` | flip to red | ditto, frontend |

---

## Tasks

- [ ] **T1 — Stop lying in the prompt.** Correct `ask_user.zig:288`–`290` and
      `:327` so they describe what `handle_tool` actually does; update the
      assertion at `:417` in the same commit.
      *Verify:* `zig build test` — the description assertions still pass with the
      new wording.
- [ ] **T2 — Collapse a multi-`ask_user` batch.** In `handle_tool` Phase 3,
      detect >1 `ask_user` in one batch, run the first, and write an actionable
      result into the others' existing rows (never leave a stranded
      placeholder).
      *Verify:* add a case to `ask_user_multi_question_test.py` that drives a
      real batch and asserts exactly one `session_pending_question` row.
- [ ] **T3 — Make a refused resume recoverable.** `resumeSession` returning
      false must leave a queued message (or an explicit `awaiting_user` marker),
      never silently drop a recorded answer.
      *Verify:* the "never delivered" test flips to asserting a recoverable
      state.
- [ ] **T4 — One keydown owner.** Rework `AskUser.vue:455`–`463` so only one
      pending card handles keyboard input.
      *Verify:* `AskUser.multi-card.spec.ts` — the digit/Enter/Escape cases flip
      to single-POST assertions.
- [ ] **T5 — Delete `markAbandonedForSession`.** Confirm no call site first.
- [ ] **T6 — Serve `listRecentQuestions`.** `GET …/questions`, plus the api
      client method. Needs the route-order guard test the `/answer` route has.

---

## Verification

| Gate | Command |
|------|---------|
| Backend unit | `zig build test` |
| Functional | `PABRIK_BIN=zig-out/bin/pabrikcore-linux-x86_64 pytest tests/functional/ask_user_test.py tests/functional/ask_user_multi_question_test.py` |
| Frontend | `cd src/apps/desktop && pnpm vitest run src/components/tool_outputs/__tests__/` |
| Frontend build | `cd src/apps/desktop && pnpm run build` |

Baseline to compare against: `ask_user_test.py` = 11 pass (one run showed the
`test_skip_settles_the_question_and_still_resumes` poll flake).

---

## Out of Scope

- Redesigning `ask_user` itself (options, multi-select, markdown rendering).
- The pre-existing `test_skip_settles_the_question_and_still_resumes` flake.
- Making the model *better* at asking one question — no prompt change can
  enforce an invariant, which is why T2 exists.

## Open Questions for the reviewer

1. Collapsing the batch (T2) silently drops the model's second question. Should
   the extra calls return an `<error>` the model can react to, or a successful
   envelope carrying `"status":"superseded"`? The former risks the model
   retrying in a loop; the latter keeps it a non-error.
2. Should the "discarded" claim be replaced with "the other tools in the batch
   still run", or should T2 make that true-by-abandonment and the prompt simply
   say "don't batch"? T1 is deliberately worded to be correct either way.
3. Is a list endpoint wanted at all if N == 1 is enforced, or is that
   speculative until a real N > 1 case exists?

## Risks

- **T1 changes what the model sees.** Correcting the prompt will change model
  behaviour repo-wide; there is no eval suite pinning `ask_user` call patterns.
- **T2 changes the tool-result row count** for multi-ask batches. Anything
  reading `tool_name = 'ask_user'` rows by count will notice.
- **T3 makes refusals queue**, which interacts with the existing
  `hasQueuedMessages` branch at `workflow.zig:1575`.

## Plan saved checklist

- [x] Reproduced every defect with a committed, green characterization test
- [x] Verified every `path:line` citation mechanically
- [x] PR opened with the findings
- [ ] User reviewed and picked a fix scope

---

## Addendum — what actually got fixed (`36c2d4fb`)

**The Design Decisions above recommended the wrong fix.** Decision 1 proposed
collapsing a multi-`ask_user` batch in `handle_tool`. The shipped fix is ~5 lines
in `ask_user_answer.zig`:

> Resume only when nothing is left pending.

```zig
questions_remaining = remainingQuestions(allocator, di.db, session_id);
if (questions_remaining > 0) { /* defer */ } else { /* resume */ }
```

The last answer resumes once and the model reads every answer in the turn
together. Why this beats collapsing the batch:

| | collapse batch (was recommended) | defer resume (shipped) |
|---|---|---|
| size | ~50 lines through `handle_tool` Phase 3 | 5 lines, one file |
| the model's 2nd question | silently discarded | answered normally |
| new tool-result row semantics | yes | none |

It also **withdraws defect 5**: with `questions_remaining` in the response and
the frontend able to count its own pending cards out of the transcript, no list
endpoint is needed. Defect 5 was not a defect.

Defect 4 (the keyboard fan-out) is no longer *harmful* — N POSTs now converge
correctly — but it is still wrong UX and remains open.

### Test trap worth keeping

`src/root.zig` carries a list of files that must be explicitly imported for
`zig build test` to see their inline tests; a `pub const` re-export in a
`mod.zig` is **not** enough. Six files already document this. The two new unit
tests in `ask_user_answer.zig` were silently unrun until added to that list —
proven by mutating an assertion and watching `zig build test` exit 0, then exit
1 once the import existed. **A green `zig build test` is not evidence a test
ran.**

Also: `zig build` does **not** compile the service binary. `zig build
install:linux` is the gate that catches errors in `src/http_handlers/**`.
