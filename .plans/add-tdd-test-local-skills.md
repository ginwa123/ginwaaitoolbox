# Plan: Add TDD Test Case for Local Project Skills

**Status:** COMPLETE
**Created:** 2025-03-05
**Updated:** 2025-03-05

---

## 1. Problem Summary
The skills module (`src/modules/agent/tools/skills.zig`) has comprehensive functionality for loading skills from a local project directory (`cwd/.nalar/skills/skill.md`), but the existing tests only verify path structure generation. No test validates the complete flow of actually loading, parsing, and listing skills from a local project directory.

---

## 2. Tasks

### TASK-001: Add test for resolveSkillsPath with local skills file
**Status:** DONE
**Description:** Create a test that verifies `resolveSkillsPath()` correctly finds and returns the local project skills path when the file exists.
**Depends On:** none
**Complexity:** Low

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-001-01 | [FILE_EDIT] | Open `src/modules/agent/tools/skills_test.zig`. After line 269 (after the last test), insert a new test block starting with `test "resolveSkillsPath returns local path when local skills file exists"` | New test block added at end of file | DONE |
| TASK-001-02 | [FILE_EDIT] | In the new test block, add code to create `.nalar/skills/` directory: `std.fs.cwd().makePath(".nalar/skills") catch \|err\| { return error.SkipZigTest; };` | Directory creation code in test | DONE |
| TASK-001-03 | [FILE_EDIT] | Add code to create the skill.md file: `const test_file = std.fs.cwd().createFile(".nalar/skills/skill.md", .{ .truncate = true }) catch { return error.SkipZigTest; }; defer { test_file.close(); std.fs.cwd().deleteFile(".nalar/skills/skill.md") catch {}; std.fs.cwd().deleteDir(".nalar/skills") catch {}; std.fs.cwd().deleteDir(".nalar") catch {}; };` | File creation with cleanup in test | DONE |
| TASK-001-04 | [FILE_EDIT] | Add test content and assertion: `try test_file.writeAll("# Test Skills\n\nTest content."); const path = skills.resolveSkillsPath(allocator); if (path) \|p\| { defer allocator.free(p); try testing.expect(std.mem.indexOf(u8, p, ".nalar") != null); } else { try testing.expect(false); // Should have found the local file }` | Test assertions added | DONE |
| TASK-001-05 | [CMD] | Run `zig build test` in project root | All tests pass, exit 0 | DONE |

---

### TASK-002: Add test for loadSkills from local project
**Status:** DONE
**Description:** Create a test that verifies `loadSkills()` correctly loads content from the local project skills file.
**Depends On:** TASK-001
**Complexity:** Low

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-002-01 | [FILE_EDIT] | Open `src/modules/agent/tools/skills_test.zig`. After the test from TASK-001, insert a new test block: `test "loadSkills loads from local project directory"` | New test block added | DONE |
| TASK-002-02 | [FILE_EDIT] | Add setup code to create `.nalar/skills/skill.md` with test content: `std.fs.cwd().makePath(".nalar/skills") catch { return error.SkipZigTest; }; const test_file = std.fs.cwd().createFile(".nalar/skills/skill.md", .{ .truncate = true }) catch { return error.SkipZigTest; }; defer { test_file.close(); std.fs.cwd().deleteFile(".nalar/skills/skill.md") catch {}; std.fs.cwd().deleteDir(".nalar/skills") catch {}; std.fs.cwd().deleteDir(".nalar") catch {}; }; const test_content = "# Local Project Skills\n\nSkills for this project."; try test_file.writeAll(test_content);` | Setup code with test content | DONE |
| TASK-002-03 | [FILE_EDIT] | Add assertion: `const result = skills.loadSkills(allocator); defer allocator.free(result); try testing.expectEqualStrings(test_content, result);` | Test assertion for content match | DONE |
| TASK-002-04 | [CMD] | Run `zig build test` in project root | All tests pass, exit 0 | DONE |

---

### TASK-003: Add test for listSkills from local project
**Status:** DONE
**Description:** Create a test that verifies `listSkills()` correctly parses and lists skills from the local project skills file.
**Depends On:** TASK-002
**Complexity:** Low

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-003-01 | [FILE_EDIT] | Open `src/modules/agent/tools/skills_test.zig`. After the test from TASK-002, insert a new test block: `test "listSkills parses skills from local project directory"` | New test block added | DONE |
| TASK-003-02 | [FILE_EDIT] | Add setup code with delimited skills: `std.fs.cwd().makePath(".nalar/skills") catch { return error.SkipZigTest; }; const test_file = std.fs.cwd().createFile(".nalar/skills/skill.md", .{ .truncate = true }) catch { return error.SkipZigTest; }; defer { test_file.close(); std.fs.cwd().deleteFile(".nalar/skills/skill.md") catch {}; std.fs.cwd().deleteDir(".nalar/skills") catch {}; std.fs.cwd().deleteDir(".nalar") catch {}; }; const test_content = "# Project Skills\n\n<!-- SKILL: local_debug -->\n## Local Debug\nDebug local issues.\n<!-- END_SKILL -->\n\n<!-- SKILL: local_test -->\n## Local Test\nTest local code.\n<!-- END_SKILL -->\n"; try test_file.writeAll(test_content);` | Setup with delimited skills | DONE |
| TASK-003-03 | [FILE_EDIT] | Add assertions: `const result = skills.listSkills(allocator); defer skills.freeSkillsList(allocator, result); try testing.expectEqual(@as(usize, 2), result.len); try testing.expectEqualStrings("local_debug", result[0].name); try testing.expectEqualStrings("local_test", result[1].name);` | Test assertions for skill list | DONE |
| TASK-003-04 | [CMD] | Run `zig build test` in project root | All tests pass, exit 0 | DONE |

---

### TASK-004: Add test for parseSkill from local project
**Status:** DONE
**Description:** Create a test that verifies `parseSkill()` correctly extracts a specific skill from the local project skills file.
**Depends On:** TASK-003
**Complexity:** Low

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-004-01 | [FILE_EDIT] | Open `src/modules/agent/tools/skills_test.zig`. After the test from TASK-003, insert a new test block: `test "parseSkill extracts skill from local project directory"` | New test block added | DONE |
| TASK-004-02 | [FILE_EDIT] | Add setup code with a delimited skill: `std.fs.cwd().makePath(".nalar/skills") catch { return error.SkipZigTest; }; const test_file = std.fs.cwd().createFile(".nalar/skills/skill.md", .{ .truncate = true }) catch { return error.SkipZigTest; }; defer { test_file.close(); std.fs.cwd().deleteFile(".nalar/skills/skill.md") catch {}; std.fs.cwd().deleteDir(".nalar/skills") catch {}; std.fs.cwd().deleteDir(".nalar") catch {}; }; const test_content = "# Project Skills\n\n<!-- SKILL: project_workflow -->\n## Project Workflow\nFollow this workflow.\n<!-- END_SKILL -->\n"; try test_file.writeAll(test_content);` | Setup with single skill | DONE |
| TASK-004-03 | [FILE_EDIT] | Add assertions: `const result = skills.parseSkill(allocator, "project_workflow"); defer if (result) \|r\| allocator.free(r); try testing.expect(result != null); try testing.expectEqualStrings("## Project Workflow\nFollow this workflow.", result.?);` | Test assertions for skill extraction | DONE |
| TASK-004-04 | [CMD] | Run `zig build test` in project root | All tests pass, exit 0 | DONE |

---

### TASK-005: Verify all tests pass together
**Status:** DONE
**Description:** Run the full test suite to ensure all new tests pass and no existing tests are broken.
**Depends On:** TASK-004
**Complexity:** Low

| Subtask ID | Type | Action | Expected Result | Status |
|------------|------|--------|-----------------|--------|
| TASK-005-01 | [CMD] | Run `zig build test` in project root | All tests pass, exit 0 | DONE |
| TASK-005-02 | [VERIFY] | Check test output for the 4 new test names: "resolveSkillsPath returns local path when local skills file exists", "loadSkills loads from local project directory", "listSkills parses skills from local project directory", "parseSkill extracts skill from local project directory" | All 4 new tests appear in output | DONE |

---

## 3. Execution Order
TASK-001 → TASK-002 → TASK-003 → TASK-004 → TASK-005 (strictly sequential).

---

## 4. Risks and Edge Cases

| Risk | Severity | Mitigation |
|------|----------|------------|
| Test cleanup fails, leaving `.nalar` directory | Medium | Use defer blocks for cleanup; tests use `catch { return error.SkipZigTest; }` to handle setup failures gracefully |
| Existing `.nalar/skills/` directory interferes with tests | Low | Tests create their own `skill.md` file; existing files won't affect test behavior since we truncate |
| Concurrent test runs interfere with each other | Low | Each test creates and cleans up its own file; tests are independent |

---

## 5. Success Criteria
- All 5 Tasks and all 17 Subtasks are DONE ✓
- All 4 new tests pass ✓
- All existing tests continue to pass ✓
- This file header shows Status: COMPLETE ✓
