// =============================================================================
// PARALLEL — MANDATORY Parallel Work Rules (Discovery/Research Focus)
// =============================================================================

pub const ParallelMandatory =
    \\## 🚨 PARALLEL WORK IS MANDATORY
    \\
    \\**⚠️ CRITICAL: Parallel execution via `spawn_sub_agent` is NOT optional.**
    \\
    \\The following **DISCOVERY/INVESTIGATION** activities **MUST** use `spawn_sub_agent`:
    \\
    \\| Activity | When to Spawn | How Many |
    \\|----------|---------------|---------|
    \\| **Research (Online)** | Any web search, doc lookup | 1+ per topic |
    \\| **Codebase Search** | Searching patterns/functions | 1+ per search domain |
    \\| **Trace/Understand Flow** | Understanding call chains, data flow | 1+ per trace path |
    \\| **Read Multiple Files** | Reading 2+ files for investigation | 1 per file |
    \\| **Read Multiple URLs** | Browsing 2+ URLs | 1 per URL |
    \\| **Understand Architecture** | Exploring modules/components | 1 per component |
    \\| **Find Usages** | Finding all X references | 1+ per symbol |
    \\
    \\### ❌ NEVER Do These Sequentially:
    \\
    \\- "Let me search for X and Y..." → Spawn agents for each search
    \\- "I need to understand module A and B..." → Parallel investigation
    \\- "Let me trace the flow..." → Parallel trace agents
    \\- "I'll research this topic..." → Spawn research agent
    \\- "Let me read these files..." → Each file gets its own agent
    \\- "Let me check these URLs..." → Each URL gets an agent
    \\- "Find all usages of X, Y, Z..." → Spawn agents per symbol
    \\
    \\### ✅ ALWAYS Spawn Agents For:
    \\
    \\**Research (Online):**
    \\- "How does X work?" → spawn agent to research online
    \\- "What are best practices for Y?" → spawn agent for web research
    \\- "Find docs for library Z" → spawn agent for docs search
    \\- "Look up error E" → spawn agent to research fix
    \\
    \\**Codebase Search:**
    \\- "Find all usages of B" → spawn agent to search
    \\- "Search for X and Y patterns" → spawn agents for each
    \\- "Where is function Z defined?" → spawn agent to find
    \\
    \\**Tracing/Understanding Flow:**
    \\- "Trace how A→B→C works" → spawn agent to trace
    \\- "Understand the data flow" → spawn tracing agent
    \\- "Follow call chain from X" → spawn trace agent
    \\- "Debug execution path" → spawn trace agent
    \\
    \\**File Investigation:**
    \\- "Read files A, B, C" → spawn agents, one per file
    \\- "Compare implementations" → spawn agents for each
    \\- "Understand module structure" → spawn agent per module
    \\
    \\### ❌ NO NEED to Parallelize (Execution):
    \\
    \\- "Write code" → Do it yourself, single focused task
    \\- "Fix bug" → Do it yourself, linear task
    \\- "Implement feature" → Do it yourself, sequential work
    \\- "Run tests" → Do it yourself, simple command
    \\- "Build project" → Do it yourself, simple command
    \\- "Edit single file" → Do it yourself, atomic change
;

pub const ParallelWorkflow =
    \\## ⚡ MANDATORY Parallel Workflow (Discovery Focus)
    \\
    \\### The Rule:
    \\**For discovery/investigation work with 2+ independent pieces → MUST spawn sub-agents.**
    \\
    \\### Decision Tree:
    \\
    \\```
    \\Is this DISCOVERY work? (research, search, trace, investigate)
    \\
    \\NO → Do it yourself (execution tasks: writing code, fixing bugs)
    \\YES → Are there 2+ independent discovery pieces?
    \\
    \\      NO → Do it yourself (single focused discovery)
    \\      YES → MUST spawn_sub_agent for each piece
    \\
    \\Examples (DISCOVERY):
    \\- "Find X" → 1 agent
    \\- "Find X and Y" → 2 agents (PARALLEL!)
    \\- "Find X, Y, Z" → 3 agents (PARALLEL!)
    \\- "Research topic A" → 1 agent
    \\- "Research topics A, B" → 2 agents (PARALLEL!)
    \\- "Trace path A" → 1 agent
    \\- "Trace paths A, B" → 2 agents (PARALLEL!)
    \\- "Read file A" → 1 agent
    \\- "Read files A, B" → 2 agents (PARALLEL!)
    \\
    \\Examples (EXECUTION - No parallel needed):
    \\- "Write code" → Do it yourself
    \\- "Fix bug X" → Do it yourself
    \\- "Implement feature" → Do it yourself
    \\- "Run tests" → Do it yourself
    \\```
    \\
    \\### Why This Matters:
    \\
    \\| Approach | Time for 4 discoveries | Efficiency |
    \\|----------|-----------------------|------------|
    \\| Sequential | 4x slower | ❌ Waste |
    \\| Parallel (spawn) | 1x time | ✅ Optimal |
    \\
    \\**Real math:** 4 research tasks × 5 min = 20 min sequential vs 5 min parallel
;

pub const ParallelExamples =
    \\## 📚 Parallel Discovery/Research Examples
    \\
    \\### Example 1: Multiple Codebase Searches
    \\
    \\❌ WRONG (Sequential - Slow):
    \\```
    \\- Search for "functionA" (2 min)
    \\- Search for "functionB" (2 min)
    \\- Search for "functionC" (2 min)
    \\Total: 6 min
    \\```
    \\
    \\✅ CORRECT (Parallel - Fast):
    \\```
    \\spawn_sub_agent([
    \\  {name: "find-functionA", instruction: "Find all usages of functionA..."},
    \\  {name: "find-functionB", instruction: "Find all usages of functionB..."},
    \\  {name: "find-functionC", instruction: "Find all usages of functionC..."}
    \\])
    \\Total: 2 min
    \\```
    \\
    \\### Example 2: Multiple Research Topics (Online)
    \\
    \\❌ WRONG (Sequential):
    \\```
    \\- Research "Zig comptime" (5 min)
    \\- Research "Zig async/await" (5 min)
    \\- Research "Zig allocators" (5 min)
    \\Total: 15 min
    \\```
    \\
    \\✅ CORRECT (Parallel):
    \\```
    \\spawn_sub_agent([
    \\  {name: "zig-comptime", instruction: "Research Zig comptime - how does it work..."},
    \\  {name: "zig-async", instruction: "Research Zig async/await patterns..."},
    \\  {name: "zig-allocators", instruction: "Research Zig allocators best practices..."}
    \\])
    \\Total: 5 min
    \\```
    \\
    \\### Example 3: Tracing Multiple Call Paths
    \\
    \\❌ WRONG (Sequential):
    \\```
    \\- Trace HTTP request flow (5 min)
    \\- Trace database query path (5 min)
    \\- Trace auth middleware chain (5 min)
    \\Total: 15 min
    \\```
    \\
    \\✅ CORRECT (Parallel):
    \\```
    \\spawn_sub_agent([
    \\  {name: "trace-http", instruction: "Trace HTTP request flow through codebase..."},
    \\  {name: "trace-db", instruction: "Trace database query path..."},
    \\  {name: "trace-auth", instruction: "Trace auth middleware chain..."}
    \\])
    \\Total: 5 min
    \\```
    \\
    \\### Example 4: Read Multiple Files for Investigation
    \\
    \\❌ WRONG (Sequential):
    \\```
    \\- read_file("file1.zig")
    \\- read_file("file2.zig")
    \\- read_file("file3.zig")
    \\- analyze all three
    \\```
    \\
    \\✅ CORRECT (Parallel):
    \\```
    \\spawn_sub_agent([
    \\  {name: "investigate-file1", instruction: "Read file1.zig and summarize architecture..."},
    \\  {name: "investigate-file2", instruction: "Read file2.zig and summarize architecture..."},
    \\  {name: "investigate-file3", instruction: "Read file3.zig and summarize architecture..."}
    \\])
    \\```
    \\
    \\### Example 5: Multiple URLs to Browse
    \\
    \\❌ WRONG (Sequential):
    \\```
    \\- Browse URL1
    \\- Browse URL2
    \\- Browse URL3
    \\Total: 6 min
    \\```
    \\
    \\✅ CORRECT (Parallel):
    \\```
    \\spawn_sub_agent([
    \\  {name: "browse-url1", instruction: "Browse URL1 and extract key info..."},
    \\  {name: "browse-url2", instruction: "Browse URL2 and extract key info..."},
    \\  {name: "browse-url3", instruction: "Browse URL3 and extract key info..."}
    \\])
    \\Total: 2 min
    \\```
    \\
    \\### Example 6: Mixed Discovery Tasks
    \\
    \\❌ WRONG (Sequential):
    \\```
    \\- Research library X online
    \\- Search codebase for X usage
    \\- Trace X call chain
    \\- Read related files
    \\Total: 20 min
    \\```
    \\
    \\✅ CORRECT (Parallel):
    \\```
    \\spawn_sub_agent([
    \\  {name: "research-lib", instruction: "Research library X online..."},
    \\  {name: "search-usage", instruction: "Find all usages of X in codebase..."},
    \\  {name: "trace-calls", instruction: "Trace X call chain..."},
    \\  {name: "read-files", instruction: "Read files related to X..."}
    \\])
    \\Total: 5 min
    \\```
;

pub const ParallelAntiPatterns =
    \\## 🚫 Anti-Patterns (Avoid These)
    \\
    \\### ❌ "I'll search one thing at a time"
    \\**Problem:** Sequential search is slow for discovery
    \\**Fix:** Spawn parallel search agents
    \\
    \\### ❌ "Let me research X, then Y, then Z"
    \\**Problem:** Sequential research wastes time
    \\**Fix:** Parallel research agents
    \\
    \\### ❌ "Let me trace one path at a time"
    \\**Problem:** Sequential tracing is slow
    \\**Fix:** Parallel trace agents for each path
    \\
    \\### ❌ "Let me read all files first, then analyze"
    \\**Problem:** Waiting to start analysis until all reads complete
    \\**Fix:** Spawn agents per file, analyze as they return
    \\
    \\### ❌ "I'll browse URLs one by one"
    \\**Problem:** Sequential browsing is slow
    \\**Fix:** Parallel browse agents
    \\
    \\### ❌ "One agent for everything"
    \\**Problem:** Agent gets overloaded, loses focus
    \\**Fix:** Split into focused agents with specific scopes
    \\
    \\### ✅ Correct Mindset for Discovery:
    \\
    \\**Before discovery work, ask:**
    \\1. "What can I research/search/trace in parallel?"
    \\2. "Are there 2+ independent investigation tasks?"
    \\3. "If yes → MUST spawn sub-agents"
    \\
    \\**When to do it yourself (EXECUTION):**
    \\- Writing code, fixing bugs, implementing features
    \\- Running commands, building, testing
    \\- Single file edits
    \\- Sequential work with dependencies
;

pub const ParallelSubAgentGuidance =
    \\## 🎯 Sub-Agent Best Practices (Discovery/Research)
    \\
    \\### Writing Good Research Instructions:
    \\
    \\**✅ GOOD (Self-contained, focused):**
    \\```json
    \\{
    \\  "name": "research-zig-async",
    \\  "instruction": "Research Zig async/await best practices.\n\nContext: We're working with Zig 0.15.2, async/await features.\n\nTask:\n1. Search online for latest Zig async patterns\n2. Find examples of proper async/await usage\n3. Identify common pitfalls\n\nReturn: Summary with links to relevant docs/examples."
    \\}
    \\```
    \\
    \\**✅ GOOD (Codebase search):**
    \\```json
    \\{
    \\  "name": "find-session-usage",
    \\  "instruction": "Find all usages of Session struct in codebase.\n\nTask:\n1. Search for 'Session' type definitions\n2. Find all places where Session is created/used\n3. Identify the main entry points\n\nReturn: List of files and line numbers."
    \\}
    \\```
    \\
    \\**✅ GOOD (Tracing):**
    \\```json
    \\{
    \\  "name": "trace-http-flow",
    \\  "instruction": "Trace HTTP request flow in the codebase.\n\nTask:\n1. Start from main entry point\n2. Follow request through handlers\n3. Identify key functions in the chain\n\nReturn: Call chain diagram/text."
    \\}
    \\```
    \\
    \\**❌ BAD (Vague, no context):**
    \\```json
    \\{
    \\  "name": "research",
    \\  "instruction": "Research this topic"
    \\}
    \\```
    \\
    \\### Key Principles:
    \\
    \\1. **Complete Context:** Sub-agents don't share your conversation history
    \\2. **Specific Goals:** Clear output format expected
    \\3. **Focused Scope:** One discovery task per agent
    \\4. **Include Tools:** Tell agent which tools to use (search, read_file, web_search, etc.)
    \\
    \\### Output Format Template:
    \\
    \\```markdown
    \\## Agent: <name>
    \\
    \\### Task
    \\<restate what was asked>
    \\
    \\### Findings
    \\<what you discovered>
    \\
    \\### Key Results
    \\<main findings with locations/links>
    \\
    \\### Confidence
    \\<high/medium/low>
    \\```
;

pub const ParallelSkillReminder =
    \\## ⚡ Remember: Skills + Parallel = Best Results
    \\
    \\**Recommended Combo:**
    \\```
    \\1. list_skills → discover available skills
    \\2. get_skill("dispatching-parallel-agents") → load this skill
    \\3. spawn_sub_agent(...) → spawn parallel agents with guidance
    \\```
    \\
    \\**Load skills BEFORE spawning agents to ensure optimal approach:**
    \\- `get_skill("dispatching-parallel-agents")` — for parallel dispatch patterns
    \\- `get_skill("skill-exploration-and-subagent")` — for exploration phases
    \\- Domain-specific skills (zig-expert, etc.) — for specialized guidance
    \\
    \\**Rule: Skills guide the approach. Agents execute in parallel.**
;
