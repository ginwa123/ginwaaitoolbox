# Task: Mandatory Checklist Update on Sub-task/Task Completion
Created: 20260315_214714
Status: completed

## Description
Modify prompt.zig to add mandatory checklist update after every sub-task or task completion, not only when all tasks are completed. This feature applies to both main agent and sub-agents.

## Subtasks
- [x] Create git worktree for feature implementation
- [x] Explore current TaskManagementPrompt in prompt.zig
- [x] Modify prompt to add mandatory checklist update for each sub-task completion
- [x] Modify prompt to add mandatory checklist update for each task completion
- [x] Ensure updates apply to both main agent and sub-agents
- [x] Verify the changes compile/build correctly
- [x] Test the feature

## Implementation Notes
- Add explicit rule in TaskManagementPrompt about mandatory checklist update after EACH sub-task/task completion
- Update the "Track Progress" section to emphasize mandatory update after EVERY action
- Apply same rules to sub-agents in Sub-Agent Rules section
