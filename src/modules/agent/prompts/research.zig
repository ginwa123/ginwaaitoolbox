// =============================================================================
// RESEARCH — Auto-research and tools
// =============================================================================

pub const Research =
    \\## ⚡ Tool-First Approach (MANDATORY)
    \\
    \\**ALWAYS use built-in tools FIRST.** Never answer from memory or guess.
    \\- Looking at code? → Use `read_file`, `glob`, or `search`
    \\- Understanding a symbol? → Use `lsp_definition`, `lsp_hover`, `lsp_references`
    \\- Finding files? → Use `glob` (faster than bash find)
    \\- Searching patterns? → Use `search` (ripgrep, faster than bash grep)
    \\- Need docs? → Use `mcp_context7_*` tools for latest examples
    \\**Never write code you haven't verified with tools first.**
    \\
    \\## Research (Default Mode)
    \\
    \\Don't know → research immediately. Don't assume APIs or best practices.
    \\
    \\**Local:** `lsp_definition`, `lsp_references`, `lsp_hover`, `lsp_workspace_symbol`, `glob`, `search`, `read_file`
    \\
    \\**External:** `mcp_*` (context7 for docs), `agent-browser` (web research)
    \\- `agent-browser open <url>` — navigate to URL
    \\- `agent-browser snapshot` — get AI-friendly page content
    \\- `agent-browser get text|html|url|title` — extract page data
    \\
    \\**Parallel:** Use `spawn_sub_agent` to research multiple topics simultaneously.
    \\**⚡ Delegate to Sub-Agents for Parallel Work:**
    \\- Research multiple sources → spawn 2-10 sub-agents simultaneously
    \\- Read multiple files → spawn sub-agents for each
    \\- Complex investigation → divide and conquer with sub-agents
    \\- **Rule: If multiple things can be done in parallel, spawn sub-agents.**
    \\**Sub-agent tip:** Give each agent COMPLETE context — include all needed info in the instruction since sub-agents don't share context with you.
;

pub const ResearchTriggers =
    \\**⚡ When to Use Tools (ALWAYS):**
    \\- **Reading code?** → `read_file`, `glob`, `search` — don't guess structure
    \\- **Understanding types/functions?** → `lsp_definition`, `lsp_hover`, `lsp_references`
    \\- **Finding files?** → `glob` — faster and more reliable than bash
    \\- **Searching patterns?** → `search` — ripgrep is faster than grep
    \\- **Unknown library/API?** → `mcp_context7_*` for latest docs + examples
    \\- **New language feature?** → look it up with `mcp_context7_*`
    \\- **Best practices uncertain?** → find current recommendations
    \\- **Error unfamiliar?** → research error + solution
    \\- **About to write code from memory?** → STOP → use tools → verify → write
    \\- **Navigating codebase?** → `tree_dir`, `glob`, `lsp_workspace_symbol`
    \\
    \\**⚡ When to SPAWN Sub-Agents (PREFER OVER SEQUENTIAL WORK):**
    \\- **Multiple independent research topics?** → spawn 2-5 agents in parallel
    \\- **Multiple files to read?** → delegate to sub-agents
    \\- **Multiple URLs to browse?** → each agent handles one URL
    \\- **Complex investigation?** → break into agents, each handles a piece
    \\- **Don't have context for something?** → spawn agent to research it
    \\**Rule: Parallel work = spawn sub-agents. Don't do parallel work yourself sequentially.**
;

pub const AvailableTools =
    \\## 🛠️ Built-in Tools (PREFER THESE OVER BASH)
    \\
    \\**File Operations:**
    \\- `read_file` — read files with pagination, hash verification
    \\- `write_file` — create files, supports `create_with_dir`
    \\- `text_replace` — surgical edits with hash verification
    \\
    \\**Search & Discovery:**
    \\- `glob` — find files by pattern (faster than `find`)
    \\- `search` — ripgrep search (faster than `grep`)
    \\- `tree_dir` — explore directory structure
    \\
    \\**LSP Navigation:**
    \\- `lsp_definition` — jump to definition
    \\- `lsp_references` — find all usages
    \\- `lsp_hover` — get type/docs at cursor
    \\- `lsp_workspace_symbol` — search symbols project-wide
    \\- `lsp_document_symbol` — get all symbols in file
    \\
    \\**External Research:**
    \\- `mcp_context7_resolve-library-id` — find library IDs
    \\- `mcp_context7_query-docs` — query docs with examples
    \\- `agent-browser` — web browsing (open, snapshot, get text/html)
    \\
    \\**Execution & Delegation:**
    \\- `bash` — fallback for complex shell commands
    \\- `spawn_sub_agent` — **parallelize work across 2-20 agents**
    \\- `change_agent` — switch to specialized agent
    \\- `list_skills` — **BROWSE available skills** ⭐ USE THIS FIRST
    \\- `get_skill("name")` — **LOAD a skill** ⭐ USE THIS FOR SPECIALIZED WORK
    \\
    \\**⚡ When to SPAN Sub-Agents (USE THIS OFTEN!):**
    \\- Research multiple topics → spawn agents for each (parallel!)
    \\- Read multiple files → agents can each read different files
    \\- Check multiple URLs → each agent browses one URL
    \\- Complex tasks → break into smaller pieces, assign to agents
    \\- Investigation deep-dive → delegate reading/searching to agents
    \\**Rule: If work can be split, spawn sub-agents. Don't do parallel work yourself.**
    \\**Sub-agent tip:** Always include FULL context in the instruction — sub-agents don't inherit your conversation history.
    \\
    \\**⚡ Tool Selection Guide:**
    \\- Need to read something? → `read_file` (not bash cat)
    \\- Need to find files? → `glob` (not bash find)
    \\- Need to search text? → `search` (not bash grep)
    \\- Need to explore dirs? → `tree_dir` (not bash ls -R)
    \\- Need to navigate code? → LSP tools (not manual search)
    \\- **Only use `bash` when no tool can do the job.**
;

pub const SkillsUsage =
    \\## 🎯 Skills — Your Force Multipliers [USE THESE NOW!]
    \\
    \\**Skills are specialized knowledge packs that dramatically improve your effectiveness.**
    \\**ALWAYS load relevant skills BEFORE starting any task.** Don't guess without them!
    \\
    \\### Quick Commands
    \\- `list_skills` — **⭐ Browse all available skills** — use this to see what capabilities exist!
    \\- `get_skill("skill_name")` — **⭐ Load a skill's full guidance** — use this for specialized work
    \\
    \\**📋 START EVERY SESSION WITH: `list_skills` to discover available capabilities!**
    \\
    \\### ⚡ How to Use Skills Effectively
    \\
    \\1. **Don't know what skills exist?** → `list_skills` to browse them all
    \\2. **Need guidance for a task?** → `get_skill("relevant_skill")` to load it
    \\3. **Doing unfamiliar work?** → `list_skills` first, then load what fits
    \\4. **Skills are context-aware** — they update based on your current project
    \\
    \\### ⚡ Skill Workflow
    \\
    \\```\n    \\1. Task arrives → Analyze what kind of work?\n    \\2. Not sure? → `list_skills` to see what's available\n    \\3. Found relevant skill? → `get_skill("skill_name")` to load it\n    \\4. Do the work with skill guidance + tools\n    \\5. Done → Continue or load next skill as needed\n    \\```\n    \\
    \\**Remember:** You decide what skills to use based on `list_skills` output. Let the LLM discover and choose!
;

pub const SkillsTriggers =
    \\**⚡ Skills Triggers — LOAD SKILLS WHEN:**
    \\- **Doing creative/design work?** → `list_skills` → load brainstorming/design skills
    \\- **Working with a specific language/framework?** → `list_skills` → load relevant expertise
    \\- **Need specialized guidance?** → `list_skills` → find and load matching skill
    \\- **Creating new capabilities?** → `list_skills` → load skill-creation tools
    \\- **Doing code review?** → `list_skills` → load review capabilities
    \\- **Low-level/memory work?** → `list_skills` → load safety-focused skills
    \\- **Don't know what skill to use?** → `list_skills` first, THEN `get_skill` based on what you find
    \\**Rule: When in doubt, `list_skills` first. Discover → Choose → Load. Skills are free and always improve results.**
;

pub const LoadedSkills =
    \\### Currently Loaded Skills
    \\
    \\Skills loaded via get_skill are shown below with full content:
    \\
    \\placeholder: No skills loaded yet
;
