const std = @import("std");
const builtin = @import("builtin");
const prompts = @import("prompts/prompts.zig");
const memory_prompts = @import("prompts/memory.zig");
const tool_list_skills_mod = @import("tools/list_skills.zig");
const tool_models = @import("Agent.zig");
const tool_memories_mod = @import("tools/memories.zig");

// =============================================================================
// Re-exports only.
//
// As of 2026-08-23 (plan: docs/superpowers/plans/2026-08-23-move-build-agent-prompt-body.md),
// the orchestrator-side prompt assembly file
// (`src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig`)
// owns `build_agent_prompt` and every helper it depends on. This file is
// now a thin shim that re-exports the static prompt-template constants
// below; rendering logic lives in the orchestrator file.
// =============================================================================

// Re-export all prompts for easy access
pub const UniversalRules = prompts.UniversalRules;
pub const PromptAutoFix = prompts.PromptAutoFix;
pub const Agent = prompts.Agent;
pub const ParallelWork = prompts.ParallelWork;
pub const Classification = prompts.Classification;
pub const Execution = prompts.Execution;
pub const Escalation = prompts.Escalation;
pub const MemoryPrompt = prompts.MemoryPrompt;
pub const NalarMdAutoUpdate = prompts.NalarMdAutoUpdate;
pub const GitPrompt = prompts.GitPrompt;
pub const GlobalMemorySystem = prompts.GlobalMemorySystem;
pub const LocalMemorySystem = prompts.LocalMemorySystem;
pub const CompactionAgent = prompts.CompactionAgent;
pub const GenerateSessionNameAgent = prompts.GenerateSessionNameAgent;
pub const ResponseFormatting = prompts.ResponseFormatting;
pub const UpdateActivityRule = prompts.UpdateActivityRule;
pub const SearchToolRule = prompts.SearchToolRule;
pub const SearchHistoryToolRule = prompts.SearchHistoryToolRule;
pub const MemoryToolRule = prompts.MemoryToolRule;

// ---------------------------------------------------------------------------
// Thin delegating re-exports for the two pure helpers that
// `prompts_test.zig` exercises directly. They now live next to
// `build_agent_prompt` in the orchestrator file (see plan §5.4);
// forwarding here keeps the test surface unchanged.
// ---------------------------------------------------------------------------
pub const loadGlobalKnowledge = @import("../../ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig").loadGlobalKnowledge;
pub const loadLocalKnowledge = @import("../../ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig").loadLocalKnowledge;
pub const SubAgentListingRow = @import("../../ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig").SubAgentListingRow;
pub const appendSubAgentsListing = @import("../../ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig").appendSubAgentsListing;
