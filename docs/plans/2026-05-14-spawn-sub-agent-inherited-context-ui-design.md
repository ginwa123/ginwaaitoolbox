# `spawn_sub_agent` — `inherited_context` UI Badge (Option A)

**Status:** Approved (brainstorming complete 2026-05-14)
**Owner:** Frontend desktop app
**Depends on:** `inherited_context` backend feature (merged 2026-06-09)

## Goal

Surface the `inherited_context` value (already passed by the LLM as part of the tool input) in the `SpawnSubAgent.vue` output card, so the user can see at-a-glance which sub-agents got parent conversation history. Currently the parameter is invisible in the UI.

## Decisions locked during brainstorming

1. **Scope:** Focused — only touches `spawn_sub_agent`'s output component. No generic tool-args disclosure (deferred to a separate plan if needed).
2. **Per-agent badge:** Show one badge per sub-agent in its header row, not a single header summary. Each sub-agent can have its own `inherited_context` value, so a per-agent display is honest.
3. **Header summary too:** A small "with parent history" indicator in the component header when ANY sub-agent has non-`none` mode, for at-a-glance context.
4. **Visual style:** Subtle — small text label like `parent: last:5` with a soft violet/blue background tint, matching the tool's existing color theme. No icon emoji (avoids font-rendering inconsistency).
5. **Source of truth:** Parse the assistant message's `tool_calls_json` to extract the args; pass them as a structured prop. ChatView.vue handles the matching by `tool_call_id`.

## Data flow

```
Assistant message (role='assistant')
  └─ msg.tool_calls_json: '[{id: "call_xxx", type: "function", function: {name: "spawn_sub_agent", arguments: "{\"sub_agents\":[{name, instruction, inherited_context, ...}]}"}}]'
       ↓
Tool result message (role='tool')
  └─ msg.tool_call_id: "call_xxx"   ← matches the assistant's tool call id
  └─ msg.content: "<agent>...<response>...</response></agent>..."   ← rendered by <SpawnSubAgent>
```

Currently `ChatView.vue` only passes `:content` and `:expanded` to `<SpawnSubAgent>`. The new prop `:sub-agent-args` (parsed) will be added.

## New helper: `parseSpawnSubAgentArgs`

`src/apps/desktop/src/helpers/parseSpawnSubAgentArgs.ts`

```ts
export interface SubAgentArgs {
  name: string
  instruction: string
  tools?: string[]
  timeout_seconds?: number
  inherited_context?: string
}

/**
 * Extract the sub_agents array from an assistant message's tool_calls_json,
 * matching by tool_call_id. Returns null when:
 *   - tool_calls_json is missing/unparseable
 *   - no tool call with the given id exists
 *   - the matching tool call is not spawn_sub_agent
 *   - the matching tool call's arguments are not parseable
 *   - the matching tool call's arguments.sub_agents is not an array
 */
export function parseSpawnSubAgentArgs(
  toolCallsJson: string | null | undefined,
  toolCallId: string | null | undefined
): SubAgentArgs[] | null
```

Behavior notes:
- `arguments` may be a JSON string (OpenAI format) or a parsed object — handle both.
- Defensive: any missing field → `undefined` in the result (no errors).
- The matcher's `null` return is the "no badge" signal — component handles it gracefully.

## Component changes: `SpawnSubAgent.vue`

### New prop

```ts
const props = defineProps<{
  content: string
  expanded?: boolean
  subAgentArgs?: SubAgentArgs[] | null  // NEW
}>()
```

### New badge in each agent row

Between the session_id and the "success"/"failed" label (current line 147-149 area), insert:

```vue
<span
  v-if="subAgentArgs?.[idx]?.inherited_context && subAgentArgs[idx].inherited_context !== 'none'"
  class="text-[10px] px-1.5 py-0.5 rounded font-mono"
  :style="{
    backgroundColor: 'var(--color-violet)',
    color: 'var(--semantic-on-violet, white)',
    opacity: 0.85,
  }"
  :title="`Parent history: ${describeInheritedContext(subAgentArgs[idx].inherited_context)}`"
>
  parent: {{ subAgentArgs[idx].inherited_context }}
</span>
```

A small helper for the human-readable description:

```ts
function describeInheritedContext(mode: string): string {
  if (mode === 'all') return 'all parent messages'
  if (mode === 'since_last_user') return 'from the last user message onward'
  const m = mode.match(/^last:(\d+)$/)
  if (m) return `last ${m[1]} parent messages (default 10 if unspecified)`
  return mode
}
```

### New header summary

In the component header (around line 110-113), if any sub-agent has non-`none` mode, add a small indicator:

```vue
<span
  v-if="hasInheritedContext"
  class="text-[10px] text-[var(--color-violet)] opacity-70"
  title="At least one sub-agent was spawned with parent conversation history"
>
  ↻ with parent history
</span>
```

`hasInheritedContext` is a `computed`:
```ts
const hasInheritedContext = computed(() => {
  if (!props.subAgentArgs) return false
  return props.subAgentArgs.some(a =>
    a.inherited_context && a.inherited_context !== 'none'
  )
})
```

## ChatView.vue changes

In the `<SpawnSubAgent>` v-if block (current line 1825-1829), find the assistant message that triggered the tool and pass the parsed args.

### Logic

A tool group contains 1+ tool messages all sharing the same `tool_call_id` (from the single spawn_sub_agent call). To find the assistant message that triggered them:

1. Look at the first message in the tool group: `group.messages[0]`
2. Get its `tool_call_id`
3. Walk backwards through `messageGroups` to find the assistant group with the matching `tool_call_id` in any of its messages' `tool_calls_json`
4. Parse the assistant's `tool_calls_json` to extract the args for that call
5. Pass the result as `:sub-agent-args` to `<SpawnSubAgent>`

### Helper extraction

Add a small `findArgsForToolCall` helper in `ChatView.vue` (or extract to `helpers/parseSpawnSubAgentArgs.ts` alongside the parser) that takes `(messageGroups, currentGroupIndex, toolCallId)` and returns `SubAgentArgs[] | null`. The component takes the pre-parsed result as a prop — the parsing happens at the ChatView layer where the message groups are available.

For backwards compatibility, if the helper returns `null` (missing args, missing tool_call_id, malformed JSON), the component receives `null` and shows no badge.

## Failure modes

- `tool_calls_json` missing (older messages loaded from DB) → no badge
- `tool_call_id` missing on the tool message → no badge
- Assistant message with matching `tool_call_id` not found (defensive) → no badge
- `arguments` not valid JSON → no badge
- `sub_agents` not an array → no badge
- `inherited_context` missing, null, empty string, or `"none"` → no badge for that sub-agent
- A sub-agent's `inherited_context` is some other valid value (`"last:5"`, `"all"`, `"since_last_user"`) → badge shows the raw value

## Test plan

`src/apps/desktop/src/__tests__/parseSpawnSubAgentArgs.spec.ts` — Vitest unit tests for the parser:

1. Returns null when `toolCallsJson` is null/undefined/empty
2. Returns null when `toolCallId` is null/undefined/empty
3. Returns null when `toolCallsJson` is malformed JSON
4. Returns null when no tool call matches the given `toolCallId`
5. Returns null when the matching tool call is not `spawn_sub_agent`
6. Returns the sub_agents array when `arguments` is a JSON string (OpenAI format)
7. Returns the sub_agents array when `arguments` is already a parsed object
8. Returns sub_agents with all fields when fully populated
9. Returns sub_agents with `inherited_context` field preserved
10. Returns null when the matching call's `sub_agents` is not an array
11. Defensive: returns empty `inherited_context` (not throws) when the field is missing

Test count: ~11 cases. Plus a small render test for SpawnSubAgent.vue that mounts the component with mock props and asserts the badge appears/disappears based on the `inherited_context` value.

## Files touched

| File | Action |
|---|---|
| `src/apps/desktop/src/helpers/parseSpawnSubAgentArgs.ts` | CREATE |
| `src/apps/desktop/src/__tests__/parseSpawnSubAgentArgs.spec.ts` | CREATE |
| `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue` | MODIFY (add prop, badge, header summary) |
| `src/apps/desktop/src/components/ChatView.vue` | MODIFY (find assistant message, pass args) |

## Out of scope (deferred to a follow-up if needed)

- A generic tool-args disclosure for all tools (Option B from brainstorming)
- A "show raw JSON" debug toggle
- Editing the `inherited_context` value from the UI (the LLM chose it; user just observes)
- A "rerun with different mode" affordance
- Surfacing other `spawn_sub_agent` parameters (`tools`, `timeout_seconds`) — the user's question was specifically about `inherited_context`

## Verification

- `bun run build` clean (per NALAR.md: ALWAYS use `bun run build`, not `build-only`, to catch type errors)
- `bun test` (or `vitest run`) — all new parser tests pass; no regressions
- Manual smoke test in the desktop app:
  1. Open a chat, send 2-3 user/assistant turns
  2. Send a message that triggers `spawn_sub_agent` with `inherited_context: "last:3"` on one sub-agent and `"none"` on another
  3. Verify the expanded `<SpawnSubAgent>` card shows:
     - Header: "with parent history" indicator
     - Each sub-agent's row has a `parent: last:3` or no badge depending on its individual mode
  4. Hover the badge → tooltip shows "Parent history: last 3 parent messages (default 10 if unspecified)" (or appropriate description)
  5. Test with all 4 modes (`none`, `last:N`, `all`, `since_last_user`) to verify the badge label and tooltip
