---
name: skill-on-demand
description: "Automatically triggered when the user needs a skill that doesn't exist, no skill is currently equipped, or existing skills don't cover the required topic. Creates new skills on-the-fly, enhances existing skills, and proactively identifies skill gaps. Use whenever tasks require specialized capabilities beyond available skills, or when existing skills need improvement."
---

# Skill On Demand

## Overview

This skill enables the AI to dynamically create, enhance, and manage skills based on real-time needs. It fills skill gaps by creating new skills when needed and improves existing ones.

## When to Activate

This skill triggers when ANY of these conditions are met:

1. **No skill equipped** - User's task requires capabilities but no skill is currently loaded
2. **Skill gap detected** - Available skills don't cover the required topic or domain
3. **Skill enhancement opportunity** - Existing skills could be improved or extended
4. **New domain request** - User asks for something in an unfamiliar area
5. **User requests skill creation** - Explicitly asks to create a new skill

## The Skill Creation Protocol

### Step 1: Assess the Need

When triggered, analyze what capability is needed:
- What is the user trying to accomplish?
- What domain/technology is involved?
- What would an ideal skill for this look like?
- Is there an existing skill that could be enhanced instead?

### Step 2: Check Existing Skills

Before creating a new skill:
1. List all available skills
2. Check if any existing skill could be adapted or enhanced
3. If enhancement is possible, proceed to Step 4
4. If no existing skill fits, proceed to Step 3

### Step 3: Create New Skill

If creating a new skill is necessary:

**Skill Structure:**
```
skill-name/
├── SKILL.md (required)
│   ├── YAML frontmatter (name, description required)
│   └── Markdown instructions
└── Bundled Resources (optional)
    ├── scripts/    - Executable code for deterministic/repetitive tasks
    ├── references/ - Docs loaded into context as needed
    └── assets/     - Files used in output
```

**Required Components:**
- **name**: Clear, kebab-case identifier
- **description**: When to trigger, what it does (pushy, specific)
- **Instructions**: Step-by-step guidance for the skill

**Write the SKILL.md:**
1. Define the skill's purpose clearly
2. List specific triggers (phrases, contexts, use cases)
3. Provide detailed instructions
4. Include examples where helpful
5. Add anti-patterns (what NOT to do)

### Step 4: Enhance Existing Skill

If enhancing an existing skill:

1. Read the current skill content
2. Identify what needs improvement:
   - Missing capabilities
   - Better triggering descriptions
   - More comprehensive instructions
   - Additional edge cases
3. Update the skill with enhancements
4. Test the enhanced skill

### Step 5: Integration

After creating/enhancing a skill:
1. Confirm the skill is properly saved
2. Verify it's discoverable in available skills
3. Load and apply the new/enhanced skill to the current task
4. Document what was created/enhanced for future reference

## Decision Tree

```
User needs capability
        │
        ▼
Any existing skill suitable?
    │           │
    NO          YES
    │           │
    ▼           ▼
Create new   Enhance existing
skill        skill
    │           │
    └─────┬─────┘
          │
          ▼
    Apply to task
```

## Skill Naming Conventions

- Use kebab-case: `skill-name`
- Be descriptive: `database-migrations`
- Domain prefix when helpful: `react-hooks`, `python-api`

## Description Best Practices

Make descriptions "pushy" to ensure proper triggering:

**Weak (won't trigger):**
> "Helps with file operations"

**Strong (will trigger):**
> "Handles all file operations including reading, writing, and organizing files. Use whenever working with files, directories, or any file system tasks. Essential for file management, data import/export, and file organization."

## Examples of Skill Creation

### Example 1: Creating a New Skill

**Trigger:** User asks to work with Excel files
**Action:** Create `excel-operations` skill with file handling, data manipulation, formatting

### Example 2: Enhancing Existing Skill

**Trigger:** User needs advanced git features but skill is basic
**Action:** Enhance `git-worktrees` skill with rebase, stash, and advanced branching

### Example 3: Domain Extension

**Trigger:** User works with PostgreSQL but only generic SQL skill exists
**Action:** Create `postgresql` skill with PostgreSQL-specific features

## Anti-Patterns to Avoid

1. **Don't over-engineer** - Simple skills are better than complex ones
2. **Don't duplicate** - Check existing skills first
3. **Don't ignore enhancement** - If existing skill can be improved, do so
4. **Don't forget to load** - New skills must be loaded after creation
5. **Don't make skills too narrow** - Aim for general applicability

## Integration with Other Skills

- Works with **skill-creator** - Uses the full skill creation workflow
- Works with **mistake-learner** - Learns from skill-related mistakes
- Works with **brainstorming** - Can use brainstorming before creating complex skills

## Key Principles

- **Proactive creation** - Create skills before the user explicitly asks when pattern is clear
- **Continuous improvement** - Always look for enhancement opportunities
- **Minimal viable** - Start simple, expand as needed
- **Discoverable** - Write clear descriptions for proper triggering
- **Practical focus** - Create skills that solve real user problems