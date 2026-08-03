// =============================================================================
// PARALLEL — MANDATORY Parallel Work Rules (CONSOLIDATED - Single Source of Truth)
// =============================================================================

pub const ParallelWork =
    \\## Parallel Work
    \\
    \\**Rule:** If 2+ tasks share zero dependencies AND each is
    \\substantial enough to be worth the coordination overhead, spawn
    \\sub-agents. Trivial tasks (a two-line config read, a one-word
    \\lookup) usually aren't — just do them inline.
    \\
    \\```
    \\independent + substantial tasks → parallelize
    \\independent + trivial tasks     → do inline, don't spawn
    \\dependent tasks                 → sequential
    \\```
    \\
    \\### Spawn Sub-Agents For
    \\
    \\| Scenario                  | Strategy                         |
    \\|---------------------------|----------------------------------|
    \\| Read N files              | N agents, 1 per file              |
    \\| Research N topics         | N agents, 1 per topic             |
    \\| Search N patterns/symbols | N agents, 1 per pattern           |
    \\| Investigate N components  | N agents, 1 per component         |
    \\| Debug N independent bugs  | N agents, 1 per bug (see below)   |
    \\| Fetch N URLs              | N agents, 1 per URL               |
    \\| Run N independent tests   | N agents, 1 per test suite        |
    \\
    \\### Fan-out ceiling
    \\
    \\Don't spawn unbounded numbers of agents at once. Above ~8
    \\concurrent tasks, batch them (e.g. 8 at a time) rather than
    \\firing all N simultaneously — this keeps synthesis manageable and
    \\avoids overwhelming the coordination step.
    \\
    \\### Fan-in: sub-agents return findings, not raw output
    \\
    \\**This is the part that's easy to get wrong.** A sub-agent
    \\reading a file should NOT dump the full file content back to the
    \\parent — that just moves the bloat problem from serial to
    \\parallel. Instead:
    \\
    \\- Sub-agent's job: do the work, then return a short distilled
    \\  summary of what matters for the parent's task (the answer, the
    \\  relevant excerpt, the finding) — not the full transcript of how
    \\  it got there.
    \\- Parent's job: synthesize N short summaries, not N full outputs.
    \\- If the parent genuinely needs the raw content later (e.g. to
    \\  edit the file), it re-reads it directly at that point — the
    \\  sub-agent's exploratory read doesn't need to carry the full
    \\  content back "just in case."
    \\
    \\### Never Spawn For
    \\
    \\- Edits that touch the **same file** or **same shared mutable
    \\  state** (race conditions, corrupted writes) — independent files
    \\  with independent edits are fine to parallelize.
    \\- Any task where step B needs output from step A.
    \\- Single-file edits or single-target operations.
    \\- Build/test pipelines with ordered stages.
    \\
    \\### Mixed dependency graphs
    \\
    \\Most real tasks aren't purely parallel or purely sequential.
    \\Break the work into stages at each sync point:
    \\
    \\```
    \\spawn(read(a.ts), read(b.ts), read(c.ts))   // stage 1: parallel
    \\→ synthesize findings
    \\edit(shared-config.ts)                       // stage 2: sequential
    \\→ spawn(test(a), test(b), test(c))           // stage 3: parallel
    \\```
    \\
    \\Identify the sync points, then parallelize freely within each
    \\stage.
    \\
    \\### Decision Test
    \\
    \\Before starting: ask "Can task B begin before task A finishes?"
    \\- Yes → parallel
    \\- No  → sequential
    \\
    \\And: "Is this task substantial enough that spawning beats doing
    \\it inline?" If not, just do it directly.
    \\
    \\### Handling partial failures
    \\
    \\If some spawned agents fail or return low-confidence results:
    \\
    \\- Retry only the failed ones, not the whole batch.
    \\- If a task is on the critical path for a later sequential step,
    \\  don't proceed on partial/failed results — surface the gap.
    \\- If it's not critical (e.g. one of 10 independent research
    \\  topics came back empty), proceed with what succeeded and note
    \\  the gap rather than blocking everything.
    \\
    \\### Examples
    \\
    \\**Wrong — sequential read:**
    \\```
    \\read(auth.ts); read(router.ts); read(db.ts); // slow, wasteful
    \\```
    \\
    \\**Right — parallel read, distilled return:**
    \\```
    \\spawn(read(auth.ts), read(router.ts), read(db.ts));
    \\// each sub-agent returns e.g. "auth.ts: uses JWT, no refresh
    \\// token logic" — not the full file content
    \\```
    \\
    \\**Wrong — parallel write to same file:**
    \\```
    \\spawn(edit(auth.ts), edit(auth.ts)); // race condition, corrupts file
    \\```
    \\
    \\**Right — sequential write to same file:**
    \\```
    \\edit(auth.ts); edit(auth.ts); // safe, ordered
    \\```
    \\
    \\**Right — parallel write, independent files:**
    \\```
    \\spawn(edit(auth.ts), edit(billing.ts), edit(search.ts));
    \\// safe: no shared file or state between them
    \\```
;
