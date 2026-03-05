# Tasklist: Fix list_skills to Read from Individual .MD Files

**Status:** COMPLETE

**Goal:** Fix list_skills to read from individual .MD files in .zigginagentic/skills/ folder with YAML frontmatter

**Constraints:**
- Maintain existing SkillInfo struct signature
- Do not modify list_skills.zig or get_skill.zig tool wrappers
- Only support local .zigginagentic/skills/ directory (not global)
- Skip empty files silently
- Handle malformed YAML frontmatter gracefully

**Success Criteria:**
1. list_skills returns all 4 non-empty skills from .zigginagentic/skills/*.MD files ✅
2. Each skill has correct name and description from YAML frontmatter ✅
3. get_skill returns full content of the requested skill file ✅
4. Empty skill files are silently skipped ✅
5. All tests pass ✅
6. Build succeeds without errors ✅

---

## TASK-001: Add YAML Frontmatter Parser Helper — ✅ DONE

**Description:** Create a helper function to parse YAML frontmatter from skill file content and extract name and description fields.

**Depends On:** none

**Complexity:** Medium

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-001-01 | [FILE_EDIT] | Add ParsedFrontmatter struct after SkillInfo struct in skills.zig | Struct added to file | DONE |
| TASK-001-02 | [FILE_EDIT] | Add parseYamlFrontmatter() function | Function added to file | DONE |
| TASK-001-03 | [VERIFY] | Review parser handles quoted strings, unquoted strings, missing fields, empty content | Function handles edge cases | DONE |

---

## TASK-002: Add Skills Directory Iterator Helper — ✅ DONE

**Description:** Create a helper function to get the skills directory path and iterate over .MD files.

**Depends On:** none

**Complexity:** Medium

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-002-01 | [FILE_EDIT] | Remove/update SKILLS_FILENAME constant | Constant removed/updated | DONE |
| TASK-002-02 | [FILE_EDIT] | Add SKILLS_FILE_EXTENSION constant | Constant added | DONE |
| TASK-002-03 | [FILE_EDIT] | Add getSkillsDirPath() function | Function added | DONE |
| TASK-002-04 | [FILE_EDIT] | Add listSkillFiles() function | Function added | DONE |

---

## TASK-003: Refactor listSkills() Function — ✅ DONE

**Description:** Update the main listSkills() function to use the new multi-file approach with YAML frontmatter parsing.

**Depends On:** TASK-001, TASK-002

**Complexity:** High

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-003-01 | [FILE_EDIT] | Replace listSkills() to call listSkillsFromDir() | Function updated | DONE |
| TASK-003-02 | [FILE_EDIT] | Replace listSkillsFromPath() with listSkillsFromDir() | Function replaced | DONE |
| TASK-003-03 | [FILE_EDIT] | Add empty file handling | Empty file handling added | DONE |
| TASK-003-04 | [FILE_EDIT] | Add invalid frontmatter handling | Invalid frontmatter handling added | DONE |

---

## TASK-004: Refactor parseSkill() Function — ✅ DONE

**Description:** Update parseSkill() to find and read individual skill files by name instead of parsing delimited sections.

**Depends On:** TASK-002

**Complexity:** Medium

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-004-01 | [FILE_EDIT] | Replace parseSkill() to call parseSkillFromDir() | Function updated | DONE |
| TASK-004-02 | [FILE_EDIT] | Replace parseSkillFromPath() with parseSkillFromDir() | Function replaced | DONE |
| TASK-004-03 | [FILE_EDIT] | Ensure full content returned | Full content returned | DONE |

---

## TASK-005: Update Tests — ✅ DONE

**Description:** Update existing tests and add new tests for the multi-file YAML frontmatter format.

**Depends On:** TASK-001, TASK-002, TASK-003, TASK-004

**Complexity:** Medium

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-005-01 | [FILE_EDIT] | Update listSkills returns all skills test | Test updated | DONE |
| TASK-005-02 | [FILE_EDIT] | Update listSkills parses skills from local project directory test | Test updated | DONE |
| TASK-005-03 | [FILE_EDIT] | Add parseYamlFrontmatter test | Test added | DONE |
| TASK-005-04 | [FILE_EDIT] | Add listSkills skips empty files test | Test added | DONE |
| TASK-005-05 | [CMD] | Run zig build test | Tests pass | DONE |

---

## TASK-006: Verify End-to-End Functionality — ✅ DONE

**Description:** Verify the complete flow works with the actual skill files in .zigginagentic/skills/.

**Depends On:** TASK-005

**Complexity:** Low

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-006-01 | [CMD] | Run zig build | Build succeeds | DONE |
| TASK-006-02 | [VERIFY] | Verify list_skills returns correct skills | Correct skills returned | DONE |
| TASK-006-03 | [VERIFY] | Verify get_skill returns correct content | Correct content returned | DONE |

---

## Log

- [2025-01-15 12:00] TASK-001: PENDING → IN_PROGRESS
- [2025-01-15 12:05] TASK-001-01: PENDING → DONE (Added ParsedFrontmatter struct)
- [2025-01-15 12:05] TASK-001-02: PENDING → DONE (Added parseYamlFrontmatter function)
- [2025-01-15 12:05] TASK-001-03: PENDING → DONE (Verified parser handles edge cases)
- [2025-01-15 12:05] TASK-001: all subtasks done
- [2025-01-15 12:05] TASK-002: PENDING → IN_PROGRESS
- [2025-01-15 12:10] TASK-002-01: PENDING → DONE (Removed SKILLS_FILENAME constant)
- [2025-01-15 12:10] TASK-002-02: PENDING → DONE (Added SKILLS_FILE_EXTENSION constant)
- [2025-01-15 12:10] TASK-002-03: PENDING → DONE (Added getSkillsDirPath function)
- [2025-01-15 12:10] TASK-002-04: PENDING → DONE (Added listSkillFiles function)
- [2025-01-15 12:10] TASK-002: all subtasks done
- [2025-01-15 12:10] TASK-003: PENDING → IN_PROGRESS
- [2025-01-15 12:15] TASK-003-01: PENDING → DONE (Replaced listSkills to call listSkillsFromDir)
- [2025-01-15 12:15] TASK-003-02: PENDING → DONE (Replaced listSkillsFromPath with listSkillsFromDir)
- [2025-01-15 12:15] TASK-003-03: PENDING → DONE (Added empty file handling)
- [2025-01-15 12:15] TASK-003-04: PENDING → DONE (Added invalid frontmatter handling)
- [2025-01-15 12:15] TASK-003: all subtasks done
- [2025-01-15 12:15] TASK-004: PENDING → IN_PROGRESS
- [2025-01-15 12:20] TASK-004-01: PENDING → DONE (Replaced parseSkill to call parseSkillFromDir)
- [2025-01-15 12:20] TASK-004-02: PENDING → DONE (Replaced parseSkillFromPath with parseSkillFromDir)
- [2025-01-15 12:20] TASK-004-03: PENDING → DONE (Ensured full content returned)
- [2025-01-15 12:20] TASK-004: all subtasks done
- [2025-01-15 12:20] TASK-005: PENDING → IN_PROGRESS
- [2025-01-15 12:25] TASK-005-01: PENDING → DONE (Updated listSkills returns all skills test)
- [2025-01-15 12:25] TASK-005-02: PENDING → DONE (Updated listSkills parses skills from local project directory test)
- [2025-01-15 12:25] TASK-005-03: PENDING → DONE (Added parseYamlFrontmatter test)
- [2025-01-15 12:25] TASK-005-04: PENDING → DONE (Added listSkills skips empty files test)
- [2025-01-15 12:25] TASK-005-05: PENDING → DONE (All tests pass)
- [2025-01-15 12:25] TASK-005: all subtasks done
- [2025-01-15 12:25] TASK-006: PENDING → IN_PROGRESS
- [2025-01-15 12:30] TASK-006-01: PENDING → DONE (Build succeeds)
- [2025-01-15 12:30] TASK-006-02: PENDING → DONE (list_skills returns 4 skills: brainstorming, executing-plans, systematic-debugging, writing-plans)
- [2025-01-15 12:30] TASK-006-03: PENDING → DONE (get_skill returns full content of brainstorming skill)
- [2025-01-15 12:30] TASK-006: all subtasks done
- [2025-01-15 12:30] ALL TASKS COMPLETE
