// =============================================================================
// PARALLEL — MANDATORY Parallel Work Rules (CONSOLIDATED - Single Source of Truth)
// =============================================================================

pub const ParallelWork =
    \\## 🚨 PARALLEL WORK IS MANDATORY (NOT OPTIONAL!)
    \\
    \\**⚠️ CRITICAL:** Use `spawn_sub_agent` for 2+ independent discovery tasks.
    \\
    \\**🎯 WHEN TO SPAWN (MANDATORY):**
    \\| Situation | Action |
    \\|-----------|--------|
    \\| Research 2+ topics | Spawn 1 agent per topic |
    \\| Read 2+ files | Spawn 1 agent per file |
    \\| Search 2+ patterns | Spawn 1 agent per pattern |
    \\| Debug 2+ failures | Spawn 1 agent per failure |
    \\| Investigate 2+ components | Spawn 1 agent per component |
    \\| Browse 2+ URLs | Spawn 1 agent per URL |
    \\
    \\**❌ WRONG (Sequential - slow!):**
    \\- "Let me search X then Y then Z..."
    \\- "I'll read file A, then file B..."
    \\- "I need to research topic 1, 2, 3..."
    \\
    \\**✅ CORRECT (Parallel - fast!):**
    \\```
    \\spawn_sub_agent([
    \\  {name: "task1", instruction: "Research X..."},
    \\  {name: "task2", instruction: "Research Y..."},
    \\  {name: "task3", instruction: "Research Z..."}
    \\])
    \\```
    \\
    \\**⚡ EXAMPLE:**
    \\- 4 research tasks × 5 min = 20 min sequential vs 5 min parallel
    \\
    \\**❌ NO NEED to Parallelize (EXECUTION):**
    \\- Writing code, fixing bugs, implementing features
    \\- Running tests, building projects
    \\- Single file edits
    \\
    \\**⚡ Sub-agent tip:** Give each agent COMPLETE context — they don't share your history.
    \\
    \\**⚡ Skills + Parallel Combo:**
    \\```
    \\1. list_skills → discover available skills
    \\2. get_skill("dispatching-parallel-agents") → load skill
    \\3. spawn_sub_agent(...) → spawn parallel agents
    \\```
;

// Legacy exports for backwards compatibility
pub const ParallelMandatory = ParallelWork;
pub const ParallelWorkflow = ParallelWork;
pub const ParallelExamples = "";
pub const ParallelAntiPatterns = "";
pub const ParallelSubAgentGuidance = "";
pub const ParallelSkillReminder = "";
