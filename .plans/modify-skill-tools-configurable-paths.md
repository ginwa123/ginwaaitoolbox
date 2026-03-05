# Tasklist: Modify Skill Tools to Use Configurable Paths

**Status:** COMPLETE
**Created:** 2025-01-15
**Goal:** Modify skill tools to use configurable paths (.config/zigginagentic/skills and cwd/.zigginagentic/skills) with consistent app name

---

## TASK-001: Add Path Resolution Functions to skills.zig
**Description:** Add functions to get local and global skills directory paths, and a function to resolve which path to use.
**Depends On:** none
**Complexity:** Medium
**Status:** DONE
**Acceptance Criteria:** Three new functions added: `getLocalSkillsPath()`, `getGlobalSkillsPath()`, `resolveSkillsPath()` that return allocated paths following XDG standards.

| Subtask ID     | Type        | Action                                                                                                          | Expected Result                                      | Status  |
|----------------|-------------|-----------------------------------------------------------------------------------------------------------------|------------------------------------------------------|---------|
| TASK-001-01    | [FILE_EDIT] | Add getLocalSkillsPath() function that builds cwd/.zigginagentic/skills/skill.md path | Function returns allocated path or null if cwd unavailable | DONE |
| TASK-001-02    | [FILE_EDIT] | Add getGlobalSkillsPath() function using XDG pattern (Linux: ~/.config/zigginagentic/skills/skill.md, macOS: ~/Library/Application Support/zigginagentic/skills/skill.md, Windows: %APPDATA%/zigginagentic/skills/skill.md) | Function returns allocated path or error             | DONE |
| TASK-001-03    | [FILE_EDIT] | Add resolveSkillsPath() function that tries local first, then global, returns first existing path | Function returns allocated path or null if none exist | DONE |
| TASK-001-04    | [FILE_EDIT] | Add freeSkillsPath() helper function to free allocated path strings | Function frees allocated memory                      | DONE |
| TASK-001-05    | [VERIFY]    | Run zig build in project root                                                                                 | Compiles without errors                              | DONE |

---

## TASK-002: Modify Skill Loading Functions to Use New Paths
**Description:** Update `loadSkills()`, `parseSkill()`, and `listSkills()` to use the new path resolution.
**Depends On:** TASK-001
**Complexity:** Medium
**Status:** DONE
**Acceptance Criteria:** Default skill functions search both local and global paths; `*FromPath` variants remain unchanged for backward compatibility.

| Subtask ID     | Type        | Action                                                                                                          | Expected Result                                      | Status  |
|----------------|-------------|-----------------------------------------------------------------------------------------------------------------|------------------------------------------------------|---------|
| TASK-002-01    | [FILE_EDIT] | Modify loadSkills() to call resolveSkillsPath() instead of SKILLS_PATH | Function uses new path resolution                    | DONE |
| TASK-002-02    | [FILE_EDIT] | Modify parseSkill() to use resolveSkillsPath() | Function uses new path resolution                    | DONE |
| TASK-002-03    | [FILE_EDIT] | Modify listSkills() to use resolveSkillsPath() | Function uses new path resolution                    | DONE |
| TASK-002-04    | [VERIFY]    | Run zig build in project root                                                                                 | Compiles without errors                              | DONE |

---

## TASK-003: Update Tests for New Path Resolution
**Description:** Add tests for the new path resolution functions and ensure existing tests still pass.
**Depends On:** TASK-002
**Complexity:** Low
**Status:** DONE
**Acceptance Criteria:** All existing tests pass; new tests cover path resolution logic.

| Subtask ID     | Type        | Action                                                                                                          | Expected Result                                      | Status  |
|----------------|-------------|-----------------------------------------------------------------------------------------------------------------|------------------------------------------------------|---------|
| TASK-003-01    | [FILE_EDIT] | Add test for getLocalSkillsPath() returning a valid path structure | Test passes                                          | DONE |
| TASK-003-02    | [FILE_EDIT] | Add test for getGlobalSkillsPath() returning XDG-compliant path | Test passes                                          | DONE |
| TASK-003-03    | [FILE_EDIT] | Add test for resolveSkillsPath() preferring local over global | Test passes                                          | DONE |
| TASK-003-04    | [CMD]       | Run zig build test in project root                                                                             | All tests pass, exit 0                               | DONE |

---

## TASK-004: Remove or Deprecate Old Hardcoded Path
**Description:** Clean up the unused `SKILLS_PATH` constant or mark it as deprecated.
**Depends On:** TASK-003
**Complexity:** Low
**Status:** DONE
**Acceptance Criteria:** `SKILLS_PATH` constant removed or marked deprecated; no references to it in active code.

| Subtask ID     | Type        | Action                                                                                                          | Expected Result                                      | Status  |
|----------------|-------------|-----------------------------------------------------------------------------------------------------------------|------------------------------------------------------|---------|
| TASK-004-01    | [FILE_EDIT] | Mark SKILLS_PATH constant as deprecated with documentation note | Constant marked deprecated                           | DONE |
| TASK-004-02    | [VERIFY]    | Run zig build in project root                                                                                 | Compiles without errors                              | DONE |

---

## Log
- [2025-01-15 10:00] Tasklist created, starting TASK-001
- [2025-03-05 09:30] Fixed MAX_PATH_BYTES -> max_path_bytes bug on line 27
- [2025-03-05 09:31] Verified build passes and skills tests pass (10/10)
- [2025-03-05 09:32] TASK-001, TASK-002, TASK-003 marked DONE
- [2025-03-05 09:33] Added deprecation notice to SKILLS_PATH constant
- [2025-03-05 09:34] TASK-004 marked DONE, plan COMPLETE
