# AGENT.md — Project Summary

> **Last Updated:** 2025-04-01
> **Auto-Update Rule:** MUST update after making changes. Keep concise, max ~200 lines.

---

# Mandatory
- Always update this file AGENT.md make sure its match with actual project or codebase

## Project Overview

**Name:** nalarcore
**Language:** Zig 0.15.2
**Type:** AI agentic coding toolbox with HTTP server + TUI interfaces

## Research Rule

> **MANDATORY: Use Context7 for library/module research!**

When needing **latest documentation, examples, or best practices** for any library or technology:
1. `mcp_context7_resolve-library-id` — Find the library ID (e.g., `/mongodb/mongoose`)
2. `mcp_context7_query-docs` — Query specific questions with examples

**Use Cases:**
- How to use a library API correctly
- Latest patterns/best practices
- Real code examples with proper syntax
- Version-specific documentation

**Never guess library APIs — research them first! If Context7 lacks results, use web search.**

## Build System

```bash
zig build              # Build all targets
zig build run          # Run HTTP server (port 8080)
zig build run:tui      # Run TUI app
zig build test         # Run tests
```

**Deps:** httpz, libsqlite3, libssl, libcrypto

## Tool Notes

### tree_dir Tool (`src/modules/agent/tools/tree_dir.zig`)
- Uses `fd` (file discovery) and `stat` to traverse directories
- **Fixed:** Added proper error handling when `fd` fails (returns error message instead of silent 0 entries)
- **Fixed:** Improved tree visualization with proper branch indicators (│, ├──, 📁)
- **Fixed:** Fixed memory leak in error path
- Uses `/usr/sbin/fd` and `/usr/bin/stat` for file operations

## Project Structure

```
src/
├── main.zig              # HTTP server entry point (257 lines)
├── root.zig              # Module exports
├── helpers/              # XML parsing, utilities
├── modules/
│   ├── agent/            # AI agent core + 20+ tools
│   ├── config/           # LLM configuration
│   ├── databases/        # SQLite + migrations
│   ├── http/             # HTTP client
│   ├── http_server/      # HTTP routing, SSE, panic broadcast
│   ├── logger/           # Structured logging + panic to file
│   ├── session/          # Session state + cancellation
│   └── cronjob/          # Background job scheduler
├── ai_workflow/tui/      # TUI workflows + tool handlers
└── apps/tui/             # Terminal UI app
```

## Key Modules

### HTTP Server (`src/main.zig`)
- REST API on port 8080 (httpz)
- SSE streaming for real-time updates
- Routes: `/api/command`, `/api/stream/:session_id`, `/api/session/*`
- Panic broadcasting to connected TUI clients

### Agent (`src/modules/agent/`)
- **Prompts (`prompts/`):** Modular prompts by purpose — core, agent, research, specialized, subagent, execution, memory, special
- **Tools:** bash, read_file, write_file, text_replace, search, glob, **tree_dir**, LSP tools
- **write_file:** Tool with `create_with_dir` option for automatic directory creation
- **Skills/Agents:** list_skill, get_skill, remove_skill, list_agents, change_agent, spawn_sub_agent
- **MCP:** LSP definition/references/hover/workspace_symbol/document_symbol
- **Self-Kill Protection:** `bash_selfkill.zig` — blocks dangerous commands (kill, killall, pkill, exit) that target self PID

### AI Workflow (`src/ai_workflow/tui/`)
- `workflow.zig` — Main TUI workflow orchestration
- `session_db.zig` — Session persistence with cursor-based pagination
- `http_handlers.zig` — HTTP request handlers (all TUI operations via REST)
- `/api/session` — Cursor-based pagination: `?limit=20&cursor=<timestamp>` → `{sessions, has_more, next_cursor}`
- 30+ tool handlers (bash, file ops, search, skills, agents, LSP)

### HTTP API Routes (`HttpRoutes.setup` in `main.zig`)
| Method | Endpoint | Purpose |
|--------|----------|--------|
| POST | `/api/command` | Generic command handler |
| GET | `/api/stream/:session_id` | SSE real-time events |
| POST | `/api/session` | Create session |
| GET | `/api/session` | List sessions |
| GET | `/api/session/:session_id` | Get session |
| GET | `/api/session/:session_id/messages` | Get messages |
| GET | `/api/session/exists/:session_id` | Check session exists |
| GET | `/api/session/latest` | Get latest by directory |
| POST | `/api/session/:session_id/cancel` | Cancel session |
| POST | `/api/session/:session_id/compact` | Trigger compaction |
| POST | `/api/llm/run` | Run LLM workflow |
| GET | `/api/ping/:session_id` | Connection health check |

### Logger (`src/modules/logger/`)
- Structured logging with timestamps
- Panic logging to `/tmp/agentic_coding.log`
- Color support (file mode)

### Session (`src/modules/session/`)
- Per-session state tracking
- Cancellation registry (cancel active sessions)
- Session monitor (exit when no active sessions)

### Desktop App (`src/apps/desktop-bun/`)
- Bun + SolidJS desktop application using webview-bun
- Connects to Zig HTTP server via REST API
- **Create session:** `POST /api/session` — creates new session, navigates to it
- **List sessions:** `GET /api/session` — infinite scroll with cursor pagination
- **Session chat:** `GET /api/session/:session_id/messages` — loads messages with infinite scroll
- **Run workflow:** `POST /api/llm/run` — sends message to agent
- **SSE streaming:** `GET /api/stream/:session_id` — real-time updates via SSE (`sseClient.ts`)
- **cwd_session:** Current working directory sent via RPC from Bun to webview, then to Zig backend
- Port passed via RPC from Bun to webview

**RPC Schema (`src/shared/rpc.ts`):**
- `getCwd`: Returns Bun's current working directory (used by webview to send cwd_session)

**SSE Client (`src/mainview/utils/sseClient.ts`):**
- Connects to `/api/stream/:session_id` for real-time updates
- Event types: `message`, `tool_result`, `status`, `error`, `done`, `step`, `ping`
- Auto-reconnect on connection loss

**Run desktop app:**
```bash
cd src/apps/desktop-bun && bun run src/bun/index.ts
```

## Important Conventions

- **Max lines per file:** 400 lines — split larger files
- `const tree1 = @import("nalarcore");` — module imports
- **Naming:** snake_case (vars/functions), PascalCase (structs/types)
- `ArrayList.empty` replaces `ArrayList.init` (Zig 0.15)
- `ArrayList.deinit(allocator)` — allocator required
- Never return stack-allocated slices from functions
- **Memory:** Prefer `ArenaAllocator` over manual `free()`

## Logging Conventions

**Desktop Bun Frontend (`src/apps/desktop-bun/`):**
- **Use `logger.ts`** — Never use `console.log/warn/error`
- Import: `import { log } from '../utils/logger';`
- Usage: `log.info('message')`, `log.warn('warning')`, `log.error('error')`
- Logger sends logs to Bun console via RPC for centralized logging

**Zig Backend:**
- Use `std.log` or the project's structured logger module

## JSON Conventions

- **JSON keys:** Always `snake_case` (e.g., `session_id`, `created_at`, `is_input`)
- This applies to all HTTP API responses and internal JSON builders

## Data Locations

| Data | Path |
|------|------|
| Database | `~/.config/nalar/agent.db` |
| Log file | `/tmp/agentic_coding.log` |
| Panic log | Same as log file |

## Related

- [MEMORY.md](./MEMORY.md) — AI learning & mistakes
- [.nalar/plans/](.nalar/plans/) — Design documents
- [docs/superpowers/](docs/superpowers/) — Skills


## Prompt Structure

Prompts split by purpose in `src/modules/agent/prompts/`:
- `core.zig` — Universal rules, auto-fix
- `agent.zig` — Main orchestration directive
- `research.zig` — Auto-research, tools
- `specialized.zig` — change_agent rules
- `subagent.zig` — Sub-agent brief
- `execution.zig` — Classification, execution, escalation
- `memory.zig` — Tasks, AGENTS.md, git
- `special.zig` — CompactionAgent, DestroyIdea

## Skills — MANDATORY SUPERPOWERS ⚡

**⚠️ SKILLS USAGE IS MANDATORY — NOT OPTIONAL!**

**Skills are specialized knowledge packs that dramatically improve quality and reduce mistakes.**
**YOU MUST load relevant skills BEFORE starting ANY task.**

### ⚡ MANDATORY SKILL WORKFLOW

Before doing ANY work, ALWAYS follow this workflow:
```
1. TASK ARRIVES → Analyze what type of work is this?
2. SKILL CHECK → Ask: "Is there a skill for this?"
3. DISCOVER → Call `list_skills` to see available capabilities
4. LOAD → Call `get_skill("relevant_skill_name")` to load the skill
5. WORK → Do the task with skill guidance + tools
6. REPEAT → Load more skills as needed for different aspects
```

### ⚡ SKILL TRIGGER PATTERNS

**DISCOVER → MATCH → LOAD:** First call `list_skills` to see what's available, then load the matching skill:

| Task Type | What to Do |
|-----------|------------|
| Language-specific code (`.zig`, `.py`, `.js`, `.go`, etc.) | `list_skills` → find matching language skill → load it |
| Frontend/UI work (components, styling, web) | `list_skills` → find frontend/design skill → load it |
| Backend/API development | `list_skills` → find backend or API skill → load it |
| Database/SQL/NoSQL work | `list_skills` → find database skill → load it |
| DevOps/Infrastructure/Cloud | `list_skills` → find DevOps/cloud skill → load it |
| Mobile development | `list_skills` → find mobile skill → load it |
| Creative work (features, design) | `list_skills` → find brainstorming/creative skill → load it |
| Multi-step implementation | `list_skills` → find planning skill → load it |
| Code review | `list_skills` → find review skill → load it |
| Testing/QA | `list_skills` → find testing skill → load it |
| Security work | `list_skills` → find security skill → load it |
| Data science/ML/AI | `list_skills` → find data/ML skill → load it |
| **ANY unfamiliar task** | `list_skills` first → find matching skill → load it |

### ⚡ QUICK COMMANDS

| Command | When to Use |
|---------|-------------|
| `list_skills` | **FIRST STEP** for any task — browse available skills |
| `get_skill("name")` | Load a specific skill's full guidance |

### ⚡ GENERIC EXAMPLE WORKFLOW

**NOTE: Skill names depend on your platform. Use `list_skills` to discover available skills, then load the appropriate one.**

**Example 1: User asks to build a feature**
```
1. THINK: What type of work is this?
2. list_skills → see what skills are available on this platform
3. Based on task type, load matching skill:
   - Frontend task → get_skill("frontend-specialist")   # or whatever name exists
   - Backend task → get_skill("backend-expert")          # or whatever name exists
   - Python task  → get_skill("python-developer")         # or whatever name exists
4. WORK: Do the task with skill guidance
```

**Example 2: User asks about code in a specific file**
```
1. THINK: What language is this file? (.js, .py, .zig, etc.)
2. list_skills → find skill matching that language/framework
3. get_skill("<language>-expert") → load the skill
4. WORK: Analyze/write code with language best practices
```

### ⚡ RULES

1. **NEVER skip the skill check** — skills exist for a reason
2. **LOAD skills BEFORE writing code** — not after
3. **Multiple skills are OK** — load what each task part needs
4. **Skills are FREE** — no performance penalty for using them
5. **When in doubt → `list_skills`** — browse and find what fits

## Agent Prompt — change_agent Rule

**⚡ SKILL + AGENT COMBO (Generic Pattern):**
1. Identify the type of work (language, framework, domain)
2. Load the relevant skill: `get_skill("matching-skill-name")`
3. Switch to specialized agent: `change_agent("domain-agent")`

**CRITICAL:** The main Agent MUST always use `change_agent` when:
- Saying "you" or "I" in any response
- Performing specialized work (coding, review, etc.)

**⚡ RECOMMENDED WORKFLOW:**
```
1. list_skills → discover available skills on this platform
2. get_skill("<matching-skill>") → load the relevant skill
3. change_agent("<agent>") → switch to specialized agent
4. WORK → do the task with skill + agent guidance
```

**⚡ COMMON COMBOS (Use `list_skills` to find actual names):**
| Task | What to Do |
|------|------------|
| Language coding | `list_skills` → find language skill → load it |
| Frontend/UI | `list_skills` → find frontend skill → load it |
| Backend/API | `list_skills` → find backend skill → load it |
| Code review | `list_skills` → find review skill → load it |

**REMEMBER:** You do orchestration. Agents do specialized work. Skills guide both.


## Dev Test

for testing use this command always
    you can use -q to use cli

- ./zig-out/bin/nalar-dev-tui --port 8082 --process nalar-dev


## Unit testing
### Zig
- use `zig build test` to run all tests
- put the test in test_runner.zig and import it in root.zig
- the test should be in the same folder as the file it's testing and end with `_test.zig`


# Mandatory
- Dont ever kill the process port 8081 !!!

---

# 🪞 Self-Learning & Self-Review (MANDATORY)

## ⚡ Self-Review Trigger Rule

**AFTER EVERY TASK COMPLETION**, before declaring success, perform self-review:

```
## Self-Review Checklist
1. ✅ TASK COMPLETED — Did I actually solve the user's request?
2. 🔍 PROCESS AUDIT — Did I follow best practices?
   - [ ] Loaded relevant skills BEFORE starting?
   - [ ] Used proper tools (read_file vs bash cat)?
   - [ ] Researched unknown APIs instead of guessing?
   - [ ] Spawned sub-agents for parallel work?
   - [ ] Delegated specialized work via change_agent?
3. 📝 KNOWLEDGE CAPTURE — What did I learn?
   - [ ] Any new patterns discovered?
   - [ ] Any mistakes made that should be documented?
   - [ ] Any skill gaps identified?
4. 🔄 IMPROVEMENT — What would I do differently?
   - [ ] Any tool usage that was suboptimal?
   - [ ] Any step that could be automated?
   - [ ] Any prompt improvements needed?
```

## 📚 Self-Learning Process

### When to Trigger Learning
| Event | Action |
|-------|--------|
| Task completed | Run self-review checklist |
| Error encountered | Document in MEMORY.md, update relevant skill |
| New pattern discovered | Add to skill or MEMORY.md |
| Skill gap found | Flag for skill creation |
| Repeated mistake | Create prevention rule |

### Learning Capture Format

**For MEMORY.md:**
```markdown
## [Category] Lesson Learned
**Date:** YYYY-MM-DD  
**Context:** What I was trying to do  
**Mistake/Insight:** What went wrong/right  
**Prevention:** How to avoid in future  
```

**For Skills:**
- Update skill description if pattern discovered
- Add new patterns to skill content
- Flag incomplete skills for enhancement

## 🎯 Agentic Coding Process Review

### Standard Workflow (What I Should Follow)

```
┌─────────────────────────────────────────────────────────────────┐
│  1. RECEIVE TASK                                                │
│     └── Analyze: What type? What tools? What skills?           │
│              ↓                                                   │
│  2. DISCOVER SKILLS                                             │
│     └── list_skills → find matching skill → get_skill          │
│              ↓                                                   │
│  3. RESEARCH (if needed)                                        │
│     └── Context7, LSP, web search — NEVER guess               │
│              ↓                                                   │
│  4. PLAN (if complex)                                           │
│     └── Plan block → "yes/proceed" → execute                   │
│              ↓                                                   │
│  5. EXECUTE                                                     │
│     └── Use tools, spawn sub-agents, change_agent for work    │
│              ↓                                                   │
│  6. VERIFY                                                      │
│     └── Build, test, read-back changes                         │
│              ↓                                                   │
│  7. SELF-REVIEW ⭐                                               │
│     └── Run checklist, capture learnings, update memory        │
│              ↓                                                   │
│  8. REPORT                                                      │
│     └── Clear summary with evidence                            │
└─────────────────────────────────────────────────────────────────┘
```

### Common Process Mistakes to Avoid

| ❌ WRONG | ✅ CORRECT |
|----------|------------|
| Starting without loading skills | Always load skills first |
| Using bash for file reading | Use `read_file` tool |
| Guessing library APIs | Research with Context7/LSP |
| Sequential parallel work | Spawn sub-agents |
| "I'll do this myself" | Delegate with change_agent |
| Declaring success without proof | Show build/test output |
| Skipping self-review | Mandatory after every task |

## 💡 Advice for AI Agentic Systems

### Essential Self-Improvement Mechanisms

1. **Persistent Memory (MEMORY.md)**
   - Capture mistakes immediately when they occur
   - Document patterns, not just errors
   - Keep concise — actionable insights only

2. **Skill System**
   - Skills should be LOADED before work, not during
   - Skill triggers should be automatic based on file type/task
   - On-demand skill creation when gap is found

3. **Mistake → Prevention Loop**
   ```
   Error occurs → Document in MEMORY.md → 
   Identify root cause → Update skill/prompt → 
   Prevention rule in AGENT.md → Future prevention
   ```

4. **Tool Preference Hierarchy**
   - Built-in tools first (LSP, read_file, glob, search)
   - Bash only for complex shell operations
   - Sub-agents for parallel/independent work

5. **Self-Awareness Prompts**
   - Explicit "you/I" detection → delegate immediately
   - "I'm not sure" → trigger research mode
   - "Done" → trigger self-review

### What Makes Agentic Coding "Easy"

| Factor | Implementation |
|--------|---------------|
| **Fast start** | Skills auto-load based on context |
| **No re-learning** | MEMORY.md persists across sessions |
| **Clear boundaries** | change_agent for specialized work |
| **Proof over claims** | Always show evidence |
| **Continuous improvement** | Self-review after every task |
| **Error resilience** | Document → Learn → Prevent |

## 🔄 The Self-Learning Loop

```
    ┌──────────────────────────────────────────┐
    │                                          │
    ▼                                          │
[TASK] → [SKILL LOAD] → [RESEARCH] → [EXECUTE]│
    ▲                              │           │
    │                              ▼           │
    │                         [VERIFIED?]     │
    │                            │    │       │
    │                       YES  │    │ NO    │
    │                        │    │    │       │
    │                        ▼    │    ▼       │
    │                    [DONE]   │  [FIX]     │
    │                        │    │    │       │
    │                        │    │    ▼       │
    │                        │    │  [RETRY]   │
    │                        │    │    │       │
    │                        ▼    ▼    │       │
    │                   [SELF-REVIEW]───┘       │
    │                        │                  │
    │                        ▼                  │
    │              ┌─────────────────┐          │
    │              │ CAPTURE LEARNED │          │
    │              │ • MEMORY.md     │          │
    │              │ • Update skills │          │
    │              │ • New patterns  │          │
    │              └─────────────────┘          │
    │                        │                  │
    └────────────────────────┴──────────────────┘
              (Next task benefits from learnings)
```

## 📋 Quick Reference: Self-Review Questions

Before declaring a task complete, ask:

1. **Did I solve the actual problem?**
   - Not just the symptoms, but the root cause?

2. **Did I use the right approach?**
   - Could this be simpler?
   - Did I use skills appropriately?

3. **Did I leave any traces?**
   - Tests passing?
   - Build succeeding?
   - Documentation updated?

4. **What did this teach me?**
   - New pattern? → Add to skill
   - Mistake? → Document in MEMORY.md
   - Gap? → Flag for skill creation

5. **Would I recommend this approach?**
   - If no, what's the better way?

---

**Remember:** The goal is not just to complete tasks — it's to get better at completing tasks.
