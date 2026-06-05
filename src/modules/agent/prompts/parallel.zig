// =============================================================================
// PARALLEL — MANDATORY Parallel Work Rules (CONSOLIDATED - Single Source of Truth)
// =============================================================================

pub const ParallelWork =
    \\## Parallel Work (Mandatory for Independent Tasks)
    \\
    \\spawn sub_agent whenever 2+ tasks can run independently.
    \\The rule is simple: **discovery tasks → parallelize, execution tasks → sequential.**
    \\
    \\### When to Spawn (Always)
    \\
    \\| Task Type              | Strategy                  |
    \\|------------------------|---------------------------|
    \\| Research 2+ topics     | 1 agent per topic         |
    \\| Read 2+ files          | 1 agent per file          |
    \\| Search 2+ patterns     | 1 agent per pattern       |
    \\| Debug 2+ failures      | 1 agent per failure       |
    \\| Investigate components | 1 agent per component     |
    \\| Browse 2+ URLs         | 1 agent per URL           |
    \\
    \\### When NOT to Spawn
    \\
    \\- Writing or fixing code
    \\- Running tests or builds
    \\- Single-file edits
    \\- Any task with sequential dependencies
    \\
    \\### Correct vs. Wrong
    \\
    \\**Wrong — sequential, slow:**
    \\```
    \\// "Let me search X, then Y, then Z..."
    \\search(X); search(Y); search(Z);
    \\```
    \\
;
