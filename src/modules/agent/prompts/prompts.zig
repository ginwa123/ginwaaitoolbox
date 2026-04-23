// =============================================================================
// PROMPTS — Unified prompt system
// =============================================================================
// Split by purpose:
//   - core: Universal rules, auto-fix
//   - agent: Main orchestration directive
//   - parallel: MANDATORY parallel work rules
//   - research: Auto-research, tools
//   - specialized: change_agent rules
//   - subagent: Sub-agent brief
//   - execution: Classification, execution, escalation
//   - memory: Tasks, AGENTS.md, git
// =============================================================================

pub const core = @import("core.zig");
pub const agent = @import("agent.zig");
pub const parallel = @import("parallel.zig");
pub const research = @import("research.zig");
pub const specialized = @import("specialized.zig");
pub const subagent = @import("subagent.zig");
pub const execution = @import("execution.zig");
pub const memory = @import("memory.zig");
pub const special = @import("special.zig");
pub const agentic = @import("agentic.zig");

// Re-export for convenience
pub const UniversalRules = core.UniversalRules;
pub const PromptAutoFix = core.PromptAutoFix;
pub const DynamicProperties = core.DynamicProperties;
pub const ResponseFormatting = core.ResponseFormatting;
pub const UpdateActivityRule = core.UpdateActivityRule;

pub const Agent = agent.Agent;

// ✅ CONSOLIDATED: Single ParallelWork section (was spread across 5 files)
pub const ParallelWork = parallel.ParallelWork;

pub const Research = research.Research;
pub const DynamicAdaptation = research.DynamicAdaptation;
pub const ResearchTriggers = research.ResearchTriggers;
pub const FileEditingRules = research.FileEditingRules;
pub const SkillsUsage = research.SkillsUsage;
pub const SkillsTriggers = research.SkillsTriggers;
pub const ProceduralMemory = research.ProceduralMemory;

pub const ChangeAgent = specialized.ChangeAgent;
pub const SpecializationTable = specialized.SpecializationTable;

pub const SubAgentPrompt = subagent.SubAgentPrompt;
pub const SubAgentBrief = subagent.SubAgentBrief;

pub const Classification = execution.Classification;
pub const Execution = execution.Execution;
pub const Escalation = execution.Escalation;
pub const PlanBlock = execution.PlanBlock;
pub const TDD = execution.TDD;

pub const ThinkBeforeCoding = execution.ThinkBeforeCoding;
pub const SimplicityFirst = execution.SimplicityFirst;
pub const SurgicalChanges = execution.SurgicalChanges;
pub const GoalDrivenExecution = execution.GoalDrivenExecution;
pub const SuccessCriteria = execution.SuccessCriteria;
pub const AntiPatterns = execution.AntiPatterns;
pub const GuidelinesSummary = execution.GuidelinesSummary;

pub const MemoryPrompt = memory.MemoryPrompt;
pub const GitPrompt = memory.GitPrompt;
pub const NalarMdAutoUpdate = memory.NalarMdAutoUpdate;

pub const CompactionAgent = special.CompactionAgent;
pub const GenerateSessionNameAgent = special.GenerateSessionNameAgent;

// Agentic Coding enhancements
pub const AutonomousBehavior = agentic.AutonomousBehavior;
pub const DeepResearch = agentic.DeepResearch;
pub const QualityGates = agentic.QualityGates;
pub const ErrorRecovery = agentic.ErrorRecovery;
pub const ToolChaining = agentic.ToolChaining;
pub const ContextAwareness = agentic.ContextAwareness;
pub const ProactiveLearning = agentic.ProactiveLearning;
pub const DecisionFramework = agentic.DecisionFramework;
pub const AggressiveDelegation = agentic.AggressiveDelegation;
pub const IterationMindset = agentic.IterationMindset;
pub const SafetyFirst = agentic.SafetyFirst;
