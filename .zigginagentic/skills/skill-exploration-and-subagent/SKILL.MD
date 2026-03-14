---
name: skill-exploration-and-subagent
description: "Comprehensive skill for handling exploration phases and sub-agent management. Use when tasks require discovery, investigation, or when delegating work to sub-agents."
---

# Skill: Exploration & Subagent Management

Master the art of exploration (Step 0 in the Agent workflow) and sub-agent orchestration.

## When to Use This Skill

- **Exploration Trigger Detection**: Task requires reading, searching, or discovering information
- **Sub-agent Planning**: Need to spawn multiple sub-agents for parallel exploration
- **Target Enumeration**: Breaking down complex discovery into independent agents
- **Context Synthesis**: Aggregating findings from multiple sub-agents

---

## Part 1: Exploration Phase Mastery

### The Exploration Gate

Before ANY task execution, answer this critical question:

> **"Do I need to read, search, or discover anything to complete this task?"**

```
┌─────────────────────────────────────────────────────────────┐
│                    EXPLORATION GATE                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Do I need to read, search, or discover anything?          │
│                                                             │
│   ┌───────────┐                                            │
│   │    YES     │ ──→ Proceed to Step 0D (Enumerate)        │
│   └───────────┘                                            │
│                                                             │
│   ┌───────────┐                                            │
│   │    NO     │ ──→ Skip to Step 1 (Domain Signals)        │
│   └───────────┘                                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Exploration Signals

You need exploration when the task involves:

| Signal Category | Examples | Exploration Type |
|-----------------|----------|------------------|
| **Unknown files** | "check this codebase", "what's in src/" | File discovery |
| **Search needs** | "find where X is used", "search for Y" | Code search |
| **Understanding needed** | "how does X work", "explain Y" | Concept exploration |
| **Multi-target** | "compare A and B", "analyze all services" | Parallel exploration |
| **Context gathering** | "given the current state", "looking at the project" | Project context |

### Complexity-Based Exploration Strategy

**Simple Tasks:**
- Direct execution, no exploration needed
- Skip to Step 1 immediately

**Moderate Tasks:**
- Light exploration required
- Brief plan (3 lines max), then explore if needed

**Complex Tasks:**
- Full exploration phase mandatory
- Write Plan Block BEFORE spawning any sub-agents

---

## Part 2: Step 0D — Target Enumeration

### The Mandatory List

Before spawning ANY sub-agent, enumerate ALL exploration targets:

```
Exploration targets:
1. <specific target> — <one focused question to answer>
2. <specific target> — <one focused question to answer>
3. <specific target> — <one focused question to answer>

Dependencies: [none | target N depends on target M]
```

### Splitting Rules (CRITICAL)

These rules prevent weak sub-agents:

| Rule | Description | ❌ Wrong | ✅ Right |
|------|-------------|----------|----------|
| **One target per agent** | Each agent gets ONE file/directory/concept | "Explore auth AND users" | Two agents: auth + users |
| **One question per agent** | Each agent answers ONE question | "What does it do AND export?" | Agent only: "What does it do?" |
| **Sub-parts split** | Split directories into individual files | "All auth files" | Per-file agents |
| **No "and" in instructions** | If you write "and", split it | "Explore X and Y" | Two separate agents |

### Enumeration Examples

**Example 1: Codebase exploration**
```
Exploration targets:
1. src/auth/login.zig — What authentication flow does it implement?
2. src/auth/session.zig — How are sessions managed?
3. src/auth/middleware.zig — What middleware is available?

Dependencies: none
```

**Example 2: Multi-file analysis**
```
Exploration targets:
1. docs/api.md — What endpoints exist and their contracts?
2. src/server.zig — How does the server handle requests?
3. src/database.zig — What database operations are supported?

Dependencies: none
```

**Example 3: With dependencies**
```
Exploration targets:
1. src/core/types.ts — What types are defined?
2. src/core/parser.ts — How does parsing work? (depends on #1)

Dependencies: target 2 depends on target 1
```

---

## Part 3: Sub-Agent Spawning

### Parallelism is Mandatory

Spawn ALL independent agents in ONE batch. Never spawn sequentially unless dependencies exist.

```json
{
  "sub_agents": [
    {
      "name": "explorer-auth-files",
      "instruction": "List all files in src/auth. For each file, describe what it does and what functions it exports.",
      "tools": ["read_file", "list_skills", "get_skill"]
    },
    {
      "name": "explorer-auth-usages",
      "instruction": "Search the entire codebase for every call to 'verifyToken'. Report file paths, line numbers, and calling context.",
      "tools": ["search", "read_file"]
    },
    {
      "name": "explorer-auth-tests",
      "instruction": "Find all test files related to auth. Report what scenarios are covered and what is missing.",
      "tools": ["search", "read_file"]
    }
  ]
}
```

### Tool Selection Guide

**Include ALL tools** when:
- Sub-agent needs to make judgment calls
- Task is open-ended or exploratory
- Errors are costly to detect later

**Restrict tools** (narrow focus) when:
- Task is narrow and well-defined
- Sub-agent is a specialist tool
- Context would add noise

**Exploration agents**: Use read_file, search, list_skills, get_skill only. NEVER include write_file or text_replace.

### Context vs Instructions

| Scenario | Approach | Example |
|----------|----------|---------|
| Judgment calls needed | Full context | "You're exploring auth system. Current project uses JWT..." |
| Narrow task | Just instructions | "List files in src/" |
| Failure handling | Include guidance | "If not found, check src/backup/" |

---

## Part 4: Synthesis & Execution

### After Sub-Agents Report

```
┌─────────────────────────────────────────────────────────────┐
│                 SYNTHESIS PHASE                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Aggregate findings from all sub-agents                 │
│  2. Identify patterns, conflicts, gaps                      │
│  3. Check Plan checkpoints (if Complex)                    │
│  4. Make decisions for Phase 3                              │
│                                                             │
│  THEN ──→ Proceed to Execute (Phase 3)                      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Execution Phase Rules

- **NEVER** explore yourself in main agent (use sub-agents)
- **ALWAYS** provide full context to sub-agents
- **NEVER** bundle multiple files/concepts in one agent
- **ALWAYS** validate enumeration before spawning
- **NEVER** spawn without completing Step 0D

---

## Part 5: Checkpoints & Validation

### Pre-Spawn Validation Checklist

- [ ] Each target is a single file, directory, or concept
- [ ] Each agent instruction answers exactly ONE question
- [ ] No instruction contains "and" connecting two tasks
- [ ] Dependencies are explicitly noted
- [ ] Agent count ≥ number of distinct targets

### Checkpoint After Exploration (Complex Only)

```
Checkpoints:
- After Phase 1 (Explore): All sub-agents reported, no gaps
- After Phase 2 (Synthesise): Decisions made, open questions resolved
- After Phase 3 (Execute): Implementation complete
- Before delivery: Verification passed
```

---

## Common Pitfalls

| Pitfall | Why It's Wrong | Fix |
|---------|----------------|-----|
| Skip enumeration | Leads to weak sub-agents | Always enumerate first |
| One agent for all | Agent gets confused | One agent per target |
| Include write in exploration | Sub-agent might modify | Read-only tools only |
| Sequential spawning | Wastes time | Parallel for independent |
| No dependencies noted | Can't order properly | Always list dependencies |

---

## Integration with Other Skills

This skill works WITH:
- **skill-creator**: Create exploration-focused skills
- **skill-on-demand**: Create new skills when gaps found
- **brainstorming**: Use before exploring (design first)
- **writing-plans**: Convert exploration findings to plans
- **systematic-debugging**: Use when exploration reveals bugs

---

## Summary: Exploration Flow

```
Step 0 ────────────────────────────────────────────────────────
 │
 ├─► 0A: Self-tune (set_agent_properties)
 │
 ├─► 0B: Classify complexity (Simple/Moderate/Complex)
 │
 ├─► 0C: Exploration gate
 │       └─► "Do I need to read, search, or discover?"
 │            ├─► NO ──→ Step 1
 │            └─► YES ──→ 0D
 │
 ├─► 0D: Enumerate ALL targets
 │       └─► Write list (one target = one agent)
 │
 ├─► 0E: Validate list (5-point check)
 │
 └─► 0F: Spawn parallel sub-agents
          └─► Wait for all to report

Phase 1 Complete ─────────────────────────────────────────────
 │
 ▼
Phase 2: Synthesise
 │  └─► Aggregate findings, check checkpoints
 ▼
Phase 3: Execute
 │  └─► Main agent executes after synthesis
 ▼
Phase 4: Verify (Complex only)
```

Remember: **Exploration is delegated, never done by the main agent directly.**