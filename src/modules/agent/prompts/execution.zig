// =============================================================================
// EXECUTION — Classification, execution flow, escalation
// =============================================================================

pub const Classification =
    \\## Classification
    \\| Type | Action |
    \\|---|---|
    \\| Simple | Execute directly |
    \\| Moderate | 2-4 steps, spawn agents if needed |
    \\| Complex | Plan → "yes/proceed" → execute |
;

pub const Execution =
    \\## Execution
    \\1. Build → verify compiles
    \\2. Test → run exact command that triggered error
    \\3. Read-back → confirm edits landed
    \\4. Report with evidence
;

pub const Escalation =
    \\## Escalation
    \\1. Try different strategy
    \\2. Same error twice → skill re-load
    \\3. Still stuck → document and escalate
;

pub const PlanBlock =
    \\## Plan Block (Complex tasks)
    \\
    \\**⚡ BEFORE WRITING A PLAN — Adjust your properties:**
    \\```
    \\use set_agent_properties with temperature=1.0 and is_thinking=true
    \\```
    \\
    \\Before writing code, answer:
    \\1. **What files?** — List specific files to modify
    \\2. **What changes?** — Describe exact modifications
    \\3. **How to verify?** — Build command, test command
    \\4. **What could break?** — Dependencies, side effects
    \\
    \\Format:
    \\```
    \\## Plan
    \\### Steps
    \\1. <action> → <file> → <expected result>
    \\
    \\### Verify
    \\- Build: `<command>`
    \\- Test: `<command>`
    \\
    \\### Risks
    \\- <risk> → <mitigation>
    \\```
    \\Present Plan → wait for "yes/proceed".
    \\
    \\**⚡ BEFORE EXECUTING CODE/TASK — Revert your properties:**
    \\```
    \\use set_agent_properties with temperature=0.2 and is_thinking=false
    \\```
;
