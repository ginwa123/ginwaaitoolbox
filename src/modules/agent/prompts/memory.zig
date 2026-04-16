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
    \\
    \\## 📚 Self-Learning: Environment & Conventions
    \\
    \\**Actively observe and learn from the environment:**
    \\1. **Project conventions** — Note coding styles, naming patterns, file organization
    \\2. **Build patterns** — Learn how the project builds, tests, and runs
    \\3. **Tool preferences** — Discover which tools/libraries are used
    \\4. **Error patterns** — Learn from errors and how they were resolved
    \\
    \\**Update memory files PROACTIVELY:**
    \\* After discovering a convention → update AGENT.md or project docs
    \\* After solving an error → update MEMORY.md with what worked
    \\* After learning a workflow → consider creating a skill
    \\
    \\**Self-Review Checklist (AFTER EVERY TASK):**
    \\1. ✅ TASK COMPLETED — Did I actually solve the user's request?
    \\2. 🔍 PROCESS AUDIT
    \\* ☐ Loaded relevant skills BEFORE starting?
    \\* ☐ Used proper tools (read_file vs bash cat)?
    \\* ☐ Researched unknown APIs instead of guessing?
    \\* ☐ Spawned sub-agents for parallel work?
    \\* ☐ Delegated specialized work via change_agent?
    \\3. 📝 KNOWLEDGE CAPTURE — What did I learn?
    \\4. 🔄 IMPROVEMENT — What would I do differently?
    \\
    \\**Capture lessons in MEMORY.MD:**
    \\* New facts about the codebase or environment
    \\* What approach worked best
    \\* Mistakes to avoid next time
    \\* Useful patterns discovered
;

pub const GitPrompt =
    \\## Git History — Know Your Codebase Better
    \\
    \\**Use git history to understand code evolution and decisions:**
    \\- `git log --oneline -20` — recent commits
    \\- `git log -p --follow -S "search_string" -- src/file.zig` — find when code was added/removed
    \\- `git blame src/file.zig` — who changed each line and when
    \\- `git show <commit>:src/file.zig` — see file at specific commit
    \\- `git diff HEAD~5 -- src/file.zig` — recent changes to a file
    \\- `git log --graph --oneline --all -15` — branch/merge history
    \\
    \\**When exploring unfamiliar code:**
    \\1. Check git blame to see who last touched the code
    \\2. Use `git log -p -S "function_name"` to find when it was introduced
    \\3. Check recent commits affecting the file for context
    \\4. Use `git show` to see full commit details and diffs
    \\
    \\**Git history reveals:**
    \\- Why code exists (commit messages)
    \\- How patterns evolved
    \\- What bugs were fixed (helps avoid repeating)
    \\- Original intent behind abstractions
;

pub const AgentMdAutoUpdate =
    \\## AGENT.md Auto-Update Rule
    \\
    \\**MANDATORY: Update AGENT.md after any project change.**
    \\
    \\Keep concise (~200 lines). Include: project overview, build commands,
    \\file structure, key conventions. One change = one update.
    \\
    \\Update when: new modules added, build system changed, conventions
    \\discovered, or architecture evolves.
;

pub const TaskManagementPrompt =
    \\## Task Management
    \\
    \\**`.nalar/tasks.md`** — Per-directory append-only task log.
    \\Format: `## [status] YYYYMMDD_HHMMSS — task description`
    \\
    \\Lifecycle: `[active]` → `[x]` per completed subtask → `[done]`
    \\
    \\Example:
    \\```markdown
    \\## [active] 20250416_143000 — Implement user auth
    \\- [x] Design API endpoints
    \\- [ ] Write database migration
    \\- [ ] Implement handler
    \\## [done] 20250415_090000 — Set up project structure
    \\```
;
