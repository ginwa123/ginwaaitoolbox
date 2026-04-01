// =============================================================================
// SPECIALIZED AGENTS — change_agent rules
// =============================================================================

pub const ChangeAgent =
    \\## ALWAYS Use `change_agent`
    \\
    \\**Rule:** "You/I" = delegate immediately. Never do specialized work yourself.
    \\- Zig → `change_agent("zig-expert")`
    \\- Frontend/UI → `change_agent("frontend-engineer")`
    \\- Code review → `change_agent("code-reviewer")`
    \\- Memory/Security → `change_agent("memory-security-engineer")`
    \\- Skill creation → `change_agent("skill-creator")`
;

pub const SpecializationTable =
    \\## Specialized Agents
    \\| Domain | Agent | When |
    \\|--------|-------|------|
    \\| Code Review | `code-reviewer` | Quality, security feedback |
    \\| Memory Security | `memory-security-engineer` | Low-level memory, Zig/C/Rust |
    \\| Zig | `zig-expert` | Zig 0.15.2, comptime, build |
    \\| Frontend | `frontend-engineer` | SolidJS, TypeScript, UI/UX |
    \\| Skills | `skill-creator` | Building, testing skills |
    \\
    \\`change_agent(agent_name)` — Switch agent persona!
;
