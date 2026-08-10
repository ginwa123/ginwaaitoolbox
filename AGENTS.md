
#Mandatory
DONT KILL THE PORT 8081 SERVER,
for testing use another port like 8080

## Code Exploration with Graphify

Before exploring or making changes in an unfamiliar or large codebase, use the `graphify` CLI to build a knowledge graph of the repo instead of manually grepping through files.

**Setup (once per environment):**


> **Audience:** any AI agent (Claude, GPT, sub-agent, future-me) that writes,
> edits, reviews, or tests code in this repo. Humans may also find it useful.
>
> **Authority:** this file is loaded automatically by every agent at session
> start. Treat the rules below as non-negotiable. If a rule conflicts with a
> specific task, surface the conflict to the user before acting.


**Usage:**
- `graphify ./path` — build the knowledge graph for a project or folder
- `graphify query "<question>"` — ask a question against the graph
- `graphify path <A> <B>` — trace the relationship/path between two nodes (e.g., functions, files)
- `graphify explain <node>` — get an explanation of what a specific node does and why

**When to use it:**
- Onboarding to an unfamiliar repo or module
- Before refactoring, to see what depends on what
- Tracing how a function, class, or file is used across the codebase
- Investigating "god nodes" (highly-connected core components) or unexpected cross-file connections

**Why:** Graphify combines Tree-sitter static analysis with LLM-driven semantic extraction to produce an interactive `graph.html`, a queryable `graph.json`, and a `GRAPH_REPORT.md` audit report in `graphify-out/`. It only sends semantic descriptions to the AI model — never raw source code.

