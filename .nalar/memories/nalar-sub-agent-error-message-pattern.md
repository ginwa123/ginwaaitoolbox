# nalar — Sub-agent error messages follow the workflow.zig pattern

The `spawn_sub_agent` tool's `<error>` field is the only error message
the PARENT LLM sees when a sub-agent fails. The rich diagnostic that
`workflow.zig` saves to the SUB-AGENT's chat history (line 410-475)
is NOT visible to the parent — so without a clear message here, the
parent has no idea what went wrong.

## The pattern

In `src/ai_workflow/tui/tool_registry.zig` `runSubAgent`, every error
path follows the format:

```
Agent Nalar System error, the actual error is ->>>> <context>
```

or for TooManyRetries (mirrors workflow.zig's rich bail):

```
[Agent Nalar System error] sub-agent workflow halted after TooManyRetries (10+ consecutive failures).
This typically indicates a network connectivity issue to the LLM API endpoint,
API rate limit exceeded, authentication/authorization failure, or upstream
service unavailability. The sub-agent's session logs contain the full chain
of errors at each retry attempt — review them before retrying.
```

## Why

Before the fix (commit `a475347f` on main), the error was just:
```
Workflow error: TooManyRetries
```

The parent LLM (and the user) saw only the error name with no
explanation. The fix mirrors `workflow.zig:68` (`Agent Nalar System
error, the actual error is ->>>> {s}`) for general errors and
`workflow.zig:410-415` for TooManyRetries specifically.

## Where it lives

`src/ai_workflow/tui/tool_registry.zig` `runSubAgent`:
- "Failed to create session_id" (line 1188-1198)
- "Failed to copy session_id" (line 1204-1212)
- "Workflow error: TooManyRetries" → rich TooManyRetries diagnostic
  (line 1238-1268)
- "getLatestMessage: {err}" (line 1272-1283)
- "Failed to copy response" (line 1288-1296)
- "Empty response content" (line 1300-1302)
- "No message found in database" (line 1304-1306)

All 6 paths now use the "Agent Nalar System error, the actual error
is ->>>> ..." prefix for consistency.

## When to apply

Any new error path added to `runSubAgent` (or any future sub-agent
spawning helper) should follow this pattern. The pattern is also
useful for ANY place where a tool's error needs to be visible to a
parent agent — bare error names like "TooManyRetries" are useless
to LLMs and users alike.

## Verification

`timeout 180 zig build test --summary all` → 848/851 pass, no
regressions. `zig build install:linux:system` → compiles cleanly.