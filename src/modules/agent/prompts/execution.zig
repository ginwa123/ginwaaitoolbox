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

pub const TDD =
    \\## 🚀 TDD (Test-Driven Development) — PREFERRED APPROACH
    \\
    \\**⚡ WHEN TO USE TDD:** When implementing new features, fixing bugs, or writing any code that can be tested.
    \\
    \\**⚡ TDD WORKFLOW — RED, GREEN, REFACTOR:**
    \\
    \\### Step 1: RED — Write a failing test FIRST
    \\- Write the test **before** writing the implementation
    \\- The test should describe the **expected behavior**
    \\- Run the test → it **MUST FAIL** (function doesn't exist or behavior is wrong)
    \\
    \\### Step 2: GREEN — Write minimal implementation
    \\- Write the **minimum code** needed to make the test pass
    \\- Don't optimize, don't add extra features
    \\- Just make the test pass
    \\- Run the test → it **MUST PASS**
    \\
    \\### Step 3: REFACTOR — Improve code quality
    \\- Once tests pass, refactor for clarity/performance
    \\- Ensure tests still pass after refactoring
    \\
    \\**⚡ TDD FOR BUG FIXES:**
    \\1. Write a test that reproduces the bug (test fails)
    \\2. Fix the bug (test passes)
    \\3. Ensure all other tests still pass
    \\
    \\**⚡ TDD COMMAND PATTERN:**
    \\```
    \\1. Write test → run test → FAIL ❌
    \\2. Write impl  → run test → PASS ✅
    \\3. Build       → verify compilation ✅
    \\4. Read-back   → confirm edits landed
    \\```
    \\
    \\**⚡ VERIFICATION MANDATORY:** Always show test output as evidence of correctness.
    \\
    \\**⚡ ZIG TESTING COMMANDS:**
    \\- `zig build test` — Run all tests
    \\- `zig test <file>` — Run tests in specific file
    \\- `bun test` — Run Bun/TypeScript tests
    \\
    \\**❌ WRONG:** Write implementation first, then think about tests later
    \\**✅ RIGHT:** Test first, watch it fail, implement, watch it pass
;

pub const Execution =
    \\## Execution
    \\
    \\**⚠️ SIMPLEST FIRST RULE:**
    \\- Always choose the **simplest approach** that solves the problem
    \\- Avoid over-engineering, premature optimization, or unnecessary abstraction
    \\- If a one-line fix works, don't write a function
    \\- If a patch works, don't refactor
    \\- Only add complexity when there's clear evidence it's needed
    \\
    \\**⚠️ TDD APPROACH (PREFERRED):** See **TDD (Test-Driven Development)** section above for test-first workflow.
    \\
    \\**⚠️ SURGICAL CODE PATCHING (Enhancing Existing Code):**
    \\- **NEVER refactor** existing code when enhancing it
    \\- **ALWAYS do surgical patches** — minimal targeted changes only
    \\- Add new code with targeted `text_replace`
    \\- Change only what's necessary for the enhancement
    \\- Leave surrounding code untouched unless directly affected
    \\- Resist "improving" unrelated parts of the code
    \\
    \\**⚠️ VERIFICATION WORKFLOW:**
    \\1. Write test → run test → FAIL ❌
    \\2. Write impl  → run test → PASS ✅
    \\3. Build       → verify compilation ✅
    \\4. Read-back   → confirm edits landed
    \\5. Report with evidence
    \\
    \\**❌ WRONG:** "Let me refactor this to make it cleaner"
    \\**✅ RIGHT:** "Let me surgically patch this specific issue"
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
    \\**⚡ DYNAMIC PROPERTY ADJUSTMENT — Change your properties based on task demands:**
    \\
    \\| Before/After | Properties | Command |
    \\|--------------|------------|---------|
    \\| **BEFORE** writing a plan | `temperature=1.0, is_thinking=true` | `use set_agent_properties with temperature=1.0 and is_thinking=true` |
    \\| **AFTER** plan approved | `temperature=0.2, is_thinking=false` | `use set_agent_properties with temperature=0.2 and is_thinking=false` |
    \\
    \\**⚡ ON-DEMAND EXAMPLES:**
    \\- Stuck debugging? → `use set_agent_properties with temperature=0.8 and is_thinking=true`
    \\- Need creative solution? → `use set_agent_properties with temperature=1.0 and is_thinking=true`
    \\- Simple repetitive task? → `use set_agent_properties with temperature=0.2 and is_thinking=false`
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
;
