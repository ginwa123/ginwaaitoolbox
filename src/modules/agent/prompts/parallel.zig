// =============================================================================
// PARALLEL — MANDATORY Parallel Work Rules (CONSOLIDATED - Single Source of Truth)
// =============================================================================

pub const ParallelWork =
    \\## Parallel Work
    \\
    \\**Rule:** If 2+ tasks share zero dependencies, spawn sub-agents. No exceptions.
    \\
    \\```
    \\independent tasks → parallelize (always)
    \\dependent tasks   → sequential  (always)
    \\```
    \\
    \\### Spawn Sub-Agents For
    \\
    \\| Scenario                  | Strategy                         |
    \\|---------------------------|----------------------------------|
    \\| Read N files              | N agents, 1 per file             |
    \\| Research N topics         | N agents, 1 per topic            |
    \\| Search N patterns/symbols | N agents, 1 per pattern          |
    \\| Investigate N components  | N agents, 1 per component        |
    \\| Debug N independent bugs  | N agents, 1 per bug              |
    \\| Fetch N URLs              | N agents, 1 per URL              |
    \\| Run N independent tests   | N agents, 1 per test suite       |
    \\
    \\### Never Spawn For
    \\
    \\- Writing or modifying code (race conditions on shared files)
    \\- Any task where step B needs output from step A
    \\- Single-file edits or single-target operations
    \\- Build/test pipelines with ordered stages
    \\
    \\### Decision Test
    \\
    \\Before starting: ask "Can task B begin before task A finishes?"
    \\- Yes → parallel
    \\- No  → sequential
    \\
    \\### Examples
    \\
    \\**Wrong — sequential read:**
    \\```
    \\read(auth.ts); read(router.ts); read(db.ts); // slow, wasteful
    \\```
    \\
    \\**Right — parallel read:**
    \\```
    \\spawn(read(auth.ts), read(router.ts), read(db.ts)); // 3x faster
    \\```
    \\
    \\**Wrong — parallel write:**
    \\```
    \\spawn(edit(auth.ts), edit(auth.ts)); // race condition, corrupts file
    \\```
    \\
    \\**Right — sequential write:**
    \\```
    \\edit(auth.ts); edit(auth.ts); // safe, ordered
    \\```
    \\
;
