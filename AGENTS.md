
#Mandatory
DONT KILL THE PORT 8081 SERVER,
for testing use another port like 8080

## SSE Wire-Format Contract — Always Add Event Names in Pairs

The browser's `EventSource` drops named events whose listener isn't pre-registered. There is **no error, no warning** — the event just vanishes at the wire. User-visible symptom: "feature X never updates live, only after I refresh the page".

When you add (or rename) any SSE event_type name, change **all three** sites together — they're one contract, not three independent changes:

1. **Backend emitter** (`src/ai_workflow/tui/**/on_event_sent*.zig` or `agentic_loop/sse_on_event_send_*.zig`): add the action → `event_type` mapping to the `event_type_name` if/else.
2. **Frontend pre-registration** (`src/apps/desktop/src/api/index.ts` → `additionalEventTypes`): add the name to the list passed to `createSseClient`.
3. **Frontend dispatch check** (same file → named-event `if (eventType === ...)` chain): add the name to the branch that routes to `opts.channels.<channel>`.

If only one side changes, the bug is silent. Skip a step, and users see "doesn't update until refresh" — no error in the console, no failed test, no broken type check.

**Verification (before claiming done):** grep for the new event_type name across the codebase. It must appear in:

- All backend `onEventSend*` functions that emit it
- `additionalEventTypes` in `api/index.ts`
- The named-event dispatch chain in `api/index.ts`

If any of those is missing, the wire contract is broken.

**Concrete example** (task_1786507100896, PR #215): backend's `onEventSendSessions` had an `event_type_name` if/else that knew about `created` and `deleted` and fell through to `session_unknown` for everything else. `action="updated"` (the most common case — fired by the auto-rename-on-first-message cascade in `workflow.zig` and the unattended toggle in `llm_history.zig`) reached the wire as `event: session_unknown`, which the frontend's `additionalEventTypes` didn't pre-register. The browser silently dropped it. Sidebar task rows kept showing "New Chat" until a manual page refresh.

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


## Recent changes

- **Anthropic profile SSE parsing + raw-error surfacing** (2026-08-13): `src/modules/agent/Agent.zig` now parses Anthropic's `/v1/messages` SSE events (`message_start` / `content_block_delta` / `content_block_start` / `message_delta` / `message_stop`) and surfaces raw server output in the retry-log error message when parsing fails. 3 commits on `worktree/anthropic-sse-parsing`: `4a783794` (raw SSE sample), `c137ebc9` (Anthropic SSE parser + UrlStyle dispatch), `c4d6853e` (also capture non-SSE lines). Plan: `docs/superpowers/plans/2026-08-13-anthropic-profile-sse-parsing.md`.
