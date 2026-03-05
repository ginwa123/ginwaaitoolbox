# Plan: Implement handleListSkills and handleGetSkill (TDD)

**Status:** COMPLETE
**Created:** 2025-03-05
**Updated:** 2025-03-05

---

## 1. Problem Summary
The `handleListSkills` and `handleGetSkill` functions in `tui_workflow.zig` were stubs. They have been implemented to integrate the skills tools with the agent workflow, following TDD methodology.

---

## 2. Tasks

### TASK-001: Add TDD tests for list_skills tool execution
**Status:** DONE
**Description:** Add tests to verify `executeListSkills` returns correct JSON structure.
**Depends On:** none
**Complexity:** Low

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-001-01 | [FILE_EDIT] | Open `src/modules/agent/tools/skills_test.zig`. Add import: `const list_skills = @import("list_skills.zig");` | Import added | DONE |
| TASK-001-02 | [FILE_EDIT] | Add test `"executeListSkills returns valid JSON with skills array"`. Create local skill file, call `executeListSkills`, verify JSON contains `{"skills":[` | Test passes | DONE |
| TASK-001-03 | [CMD] | Run `zig test src/modules/agent/tools/skills_test.zig` | All tests pass | DONE |

---

### TASK-002: Add TDD tests for get_skill tool execution
**Status:** DONE
**Description:** Add tests to verify `executeGetSkill` handles success and error cases.
**Depends On:** TASK-001
**Complexity:** Low

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-002-01 | [FILE_EDIT] | Open `src/modules/agent/tools/skills_test.zig`. Add import: `const get_skill = @import("get_skill.zig");` | Import added | DONE |
| TASK-002-02 | [FILE_EDIT] | Add test `"executeGetSkill returns skill content for valid skill"`. Create skill file with delimited skill, call `executeGetSkill` with valid name, verify JSON contains `"loaded":true` | Test passes | DONE |
| TASK-002-03 | [FILE_EDIT] | Add test `"executeGetSkill returns error for invalid skill"`. Call `executeGetSkill` with invalid name, verify JSON contains `"loaded":false` and `available_skills` | Test passes | DONE |
| TASK-002-04 | [CMD] | Run `zig test src/modules/agent/tools/skills_test.zig` | All tests pass | DONE |

---

### TASK-003: Implement handleListSkills handler
**Status:** DONE
**Description:** Implement the handler to execute list_skills and manage the response.
**Depends On:** TASK-002
**Complexity:** Medium

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-003-01 | [FILE_EDIT] | Open `src/ai_workflow/tui_workflow.zig`. Add imports: `const list_skills_tool = tree1_mod.list_skills_tool;` and `const get_skill_tool = tree1_mod.get_skill_tool;` | Imports added | DONE |
| TASK-003-02 | [FILE_EDIT] | Implement `handleListSkills`: Call `list_skills_tool.executeListSkills(self.allocator)`, handle errors, create `AgentMessage`, append to `messages_list`, call `saveMessageUnified`, call `sendToolResult` | Handler implemented | DONE |

---

### TASK-004: Implement handleGetSkill handler
**Status:** DONE
**Description:** Implement the handler to execute get_skill with parsed arguments.
**Depends On:** TASK-003
**Complexity:** Medium

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-004-01 | [FILE_EDIT] | Implement `handleGetSkill`: Parse `tool_call.function.arguments` to `get_skill_tool.GetSkillInput` using `std.json.parseFromSlice` | JSON parsing added | DONE |
| TASK-004-02 | [FILE_EDIT] | Call `get_skill_tool.executeGetSkill(self.allocator, parsed.value)`, handle errors, create `AgentMessage`, append to `messages_list`, call `saveMessageUnified`, call `sendToolResult` | Handler implemented | DONE |

---

### TASK-005: Register tools in agent tool array
**Status:** DONE
**Description:** Add the skill tools to the agent's available tools list.
**Depends On:** TASK-004
**Complexity:** Low

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-005-01 | [FILE_EDIT] | Find the `tools` array definition (around line 470). Add `list_skills_tool.listSkillsTool` and `get_skill_tool.getSkillTool` to the array | Tools registered | DONE |
| TASK-005-02 | [CMD] | Run `zig build` | Build succeeds | DONE |

---

### TASK-006: Final verification
**Status:** DONE
**Description:** Run all tests to ensure everything works together.
**Depends On:** TASK-005
**Complexity:** Low

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-006-01 | [CMD] | Run `zig build test` | All tests pass | DONE |
| TASK-006-02 | [VERIFY] | Check test output for new test names | All new tests listed | DONE |

---

## 3. Execution Order
TASK-001 → TASK-002 → TASK-003 → TASK-004 → TASK-005 → TASK-006 (strictly sequential to follow TDD).

---

## 4. Success Criteria
- All 6 Tasks and all 13 Subtasks are DONE ✓
- TDD tests for `executeListSkills` and `executeGetSkill` pass ✓
- Handlers are implemented and integrated ✓
- This file header shows Status: COMPLETE ✓
