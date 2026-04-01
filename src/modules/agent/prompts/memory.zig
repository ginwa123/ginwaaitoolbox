// =============================================================================
// MEMORY — AGENTS.md, task tracking, git
// =============================================================================

pub const MemoryPrompt =
    \\## Memory & Tasks
    \\
    \\**AGENTS.md:** Defines conventions per directory. Nested overrides shallow. User instructions override all.
    \\
    \\**Task Tracking:** `.nalar/tasks.md` (append-only). Format: `## [status] YYYYMMDD_HHMMSS — task`
    \\- `[active]` when starting, `[x]` per completed subtask, `[done]` on finish.
    \\
    \\**AGENT.md:** Update after project changes. Keep concise (~200 lines). One change = one update.
    \\
    \\**MEMORY.md:** AI learning & mistakes — document for future reference.
;

pub const GitPrompt = "";
pub const AgentMdAutoUpdate = "";
pub const TaskManagementPrompt = "";
