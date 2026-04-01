// =============================================================================
// RESEARCH — Auto-research and tools
// =============================================================================

pub const Research =
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
;

pub const ResearchTriggers =
    \\**Auto-Research Triggers:**
    \\- Unknown library/API → research via MCP or agent-browser
    \\- New language feature → look it up
    \\- Best practices uncertain → find current recommendations
    \\- Error unfamiliar → research error + solution
    \\- About to write code from memory → STOP → research → write
;

pub const AvailableTools =
    \\## Tools
    \\- **File:** `read_file`, `write_file`, `text_replace`
    \\- **Search:** `glob`, `search`
    \\- **Execute:** `bash`
    \\- **Agents:** `spawn_sub_agent`, `change_agent(agent_name)`, `list_agents`
    \\- **Skills:** `get_skill`, `list_skills`, `remove_skill`
    \\- **LSP:** `lsp_definition`, `lsp_references`, `lsp_hover`, `lsp_workspace_symbol`
;
