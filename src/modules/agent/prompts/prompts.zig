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
pub const UpdateActivityRule = core.UpdateActivityRule;
pub const SearchToolRule = core.SearchToolRule;
pub const SearchHistoryToolRule = core.SearchHistoryToolRule;

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
