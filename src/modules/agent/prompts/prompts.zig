// =============================================================================
// PROMPTS — Unified prompt system
// =============================================================================
// Split by purpose:
//   - core:        Universal rules, response formatting, update-activity
//   - agent:       Main orchestration directive
//   - parallel:    MANDATORY parallel work rules
//   - memory:      AGENTS.md, tasks, git, NALAR.md, skills system
//   - execution:   Classification, execution, escalation
//   - special:     CompactionAgent, GenerateSessionNameAgent
// =============================================================================

pub const core = @import("core.zig");
pub const agent = @import("agent.zig");
pub const parallel = @import("parallel.zig");
pub const execution = @import("execution.zig");
pub const memory = @import("memory.zig");
pub const special = @import("special.zig");

// Re-export for convenience
pub const UniversalRules = core.UniversalRules;
pub const PromptAutoFix = core.PromptAutoFix;
pub const ResponseFormatting = core.ResponseFormatting;
pub const SearchToolRule = core.SearchToolRule;
// Progressive tool search: `search_tool` is the agent's special tool — the
// mandate to search the catalog for the tool a task needs (search_tool ->
// view_tool -> use_tool). Gated on search_tool being in the resolved tool set.
// Skills: `list_skills` / `use_skill` are the agent's special skills — the
// mandate to load the skill a task needs. Gated on use_skill being present.
pub const ProgressiveToolRule = core.ProgressiveToolRule;
pub const SkillsToolRule = core.SkillsToolRule;
pub const SkillEvalToolRule = core.SkillEvalToolRule;
pub const ReadWorkspaceSessionToolRule = core.ReadWorkspaceSessionToolRule;
pub const MemoryToolRule = core.MemoryToolRule;
pub const CrossProjectCwdRule = core.CrossProjectCwdRule;

pub const Agent = agent.Agent;

pub const ParallelWork = parallel.ParallelWork;

pub const Classification = execution.Classification;
pub const Execution = execution.Execution;
pub const Escalation = execution.Escalation;

pub const MemoryPrompt = memory.MemoryPrompt;
pub const GitPrompt = memory.GitPrompt;
pub const NalarMdAutoUpdate = memory.NalarMdAutoUpdate;
pub const GlobalMemorySystem = memory.GlobalMemorySystem;
pub const LocalMemorySystem = memory.LocalMemorySystem;

pub const CompactionAgent = special.CompactionAgent;
pub const GenerateSessionNameAgent = special.GenerateSessionNameAgent;
