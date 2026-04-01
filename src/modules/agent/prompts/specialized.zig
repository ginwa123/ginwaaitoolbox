// =============================================================================
// SPECIALIZED AGENTS — change_agent rules
// =============================================================================

pub const ChangeAgent =
    \\## ALWAYS Use `change_agent`
    \\
    \\**Rule:** "You/I" = delegate immediately. Never do specialized work yourself.
    \\- Use `change_agent("domain-agent")` to switch to specialized persona
    \\
    \\**⚡ Also use skills tools for even better results:**
    \\- `list_skills` — Browse all available skills first
    \\- `get_skill("name")` — Load specialized guidance based on what you find
;

pub const SpecializationTable =
    \\## Specialized Agents & Skills
    \\
    \\### Agents (change_agent)
    \\Use `change_agent` to switch to a specialized persona for domain-specific work.
    \\
    \\### Skills (get_skill)
    \\**ALWAYS discover skills with `list_skills` first, then load what fits.**
    \\| Command | Purpose |
    \\|-------|---------|
    \\| `list_skills` | Browse all available skills — use this first! |
    \\| `get_skill("name")` | Load a specific skill based on what you discover |
    \\
    \\**Best Practice:** Use `list_skills` to discover → `get_skill` to load → Work with guidance!
    \\**Rule:** Let the LLM decide which skills to use based on `list_skills` output.
;
