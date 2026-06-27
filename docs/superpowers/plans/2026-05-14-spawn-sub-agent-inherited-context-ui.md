# `spawn_sub_agent` — `inherited_context` UI Badge (Option A) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the `inherited_context` value (already passed by the LLM as part of the tool input) in the `SpawnSubAgent.vue` output card via a small per-agent badge.

**Architecture:** A pure-function parser (`helpers/parseSpawnSubAgentArgs.ts`) extracts the sub_agents array from an assistant message's `tool_calls_json`, matched by `tool_call_id`. ChatView.vue calls the parser, finds the triggering assistant message for each tool group, and passes the parsed array as a new `subAgentArgs` prop to `SpawnSubAgent.vue`. The component renders a per-agent badge when the mode is non-`none` and a header summary when any sub-agent has non-`none` mode.

**Tech Stack:** Vue 3 Composition API, TypeScript, Vitest (jsdom), Bun.

**Reference design:** `docs/plans/2026-05-14-spawn-sub-agent-inherited-context-ui-design.md`

**Reference skills:**
- `desktop-frontend-build` — the local skill for this project (Bun, vitest, monaco-editor alias)
- `vitest-resolve-alias-stub-for-bare-specifiers` — the project already aliases monaco-editor in `vitest.config.ts`, so tests don't need to know about it
- NALAR.md: "**Desktop app: ALWAYS run `bun run build` (NOT `bun run build-only`)**"

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `src/apps/desktop/src/helpers/parseSpawnSubAgentArgs.ts` | Pure parser: extract sub_agents from tool_calls_json, matched by tool_call_id | CREATE |
| `src/apps/desktop/src/__tests__/parseSpawnSubAgentArgs.spec.ts` | Vitest unit tests for the parser | CREATE |
| `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue` | Add `subAgentArgs` prop, per-agent badge, header summary | MODIFY |
| `src/apps/desktop/src/components/ChatView.vue` | Find triggering assistant message, pass `subAgentArgs` prop | MODIFY |

---

## Chunk 1: Parser helper + tests

### Task 1.1: Create `parseSpawnSubAgentArgs` helper with TDD

**Files:**
- Create: `src/apps/desktop/src/helpers/parseSpawnSubAgentArgs.ts`
- Create: `src/apps/desktop/src/__tests__/parseSpawnSubAgentArgs.spec.ts`

- [ ] **Step 1: Write the failing tests**

Create `src/apps/desktop/src/__tests__/parseSpawnSubAgentArgs.spec.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { parseSpawnSubAgentArgs } from '../helpers/parseSpawnSubAgentArgs'

describe('parseSpawnSubAgentArgs', () => {
  it('returns null when toolCallsJson is null', () => {
    expect(parseSpawnSubAgentArgs(null, 'call_xxx')).toBeNull()
  })

  it('returns null when toolCallsJson is undefined', () => {
    expect(parseSpawnSubAgentArgs(undefined, 'call_xxx')).toBeNull()
  })

  it('returns null when toolCallsJson is empty string', () => {
    expect(parseSpawnSubAgentArgs('', 'call_xxx')).toBeNull()
  })

  it('returns null when toolCallId is null', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: '{}' }
    }])
    expect(parseSpawnSubAgentArgs(json, null)).toBeNull()
  })

  it('returns null when toolCallsJson is malformed JSON', () => {
    expect(parseSpawnSubAgentArgs('{not valid json', 'call_xxx')).toBeNull()
  })

  it('returns null when no tool call matches the given toolCallId', () => {
    const json = JSON.stringify([{
      id: 'call_yyy', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: '{}' }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('returns null when the matching tool call is not spawn_sub_agent', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'get_skill', arguments: '{}' }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('parses arguments as a JSON string (OpenAI format)', () => {
    const args = JSON.stringify({
      sub_agents: [{ name: 'a', instruction: 'do x', inherited_context: 'last:3' }]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toEqual([{ name: 'a', instruction: 'do x', inherited_context: 'last:3' }])
  })

  it('parses arguments as an already-parsed object (defensive)', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: { sub_agents: [{ name: 'a', instruction: 'x' }] } }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toEqual([{ name: 'a', instruction: 'x' }])
  })

  it('preserves all sub-agent fields when fully populated', () => {
    const args = JSON.stringify({
      sub_agents: [{
        name: 'researcher',
        instruction: 'find docs',
        tools: ['bash', 'web_browse'],
        timeout_seconds: 300,
        inherited_context: 'last:5'
      }]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toEqual([{
      name: 'researcher',
      instruction: 'find docs',
      tools: ['bash', 'web_browse'],
      timeout_seconds: 300,
      inherited_context: 'last:5'
    }])
  })

  it('returns null when sub_agents is not an array', () => {
    const args = JSON.stringify({ sub_agents: 'not an array' })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('returns null when the matching call arguments is malformed JSON', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: '{not valid' }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('handles sub-agents with missing optional fields (no throw)', () => {
    const args = JSON.stringify({
      sub_agents: [{ name: 'a', instruction: 'x' }]  // no tools/timeout/inherited_context
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toEqual([{ name: 'a', instruction: 'x' }])
  })

  it('returns multiple sub-agents in order', () => {
    const args = JSON.stringify({
      sub_agents: [
        { name: 'a', instruction: 'x', inherited_context: 'last:3' },
        { name: 'b', instruction: 'y', inherited_context: 'none' },
        { name: 'c', instruction: 'z' }
      ]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toHaveLength(3)
    expect(result?.[0].name).toBe('a')
    expect(result?.[1].inherited_context).toBe('none')
    expect(result?.[2].inherited_context).toBeUndefined()
  })
})
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/parseSpawnSubAgentArgs.spec.ts 2>&1 | tail -n 30`
Expected: COMPILE ERROR — the helper module doesn't exist. If vitest silently ignores the file, check `vitest.config.ts` and make sure the file matches the test pattern (it does — `*.spec.ts` is the standard pattern, per existing `sseClient.spec.ts`).

- [ ] **Step 3: Implement the parser**

Create `src/apps/desktop/src/helpers/parseSpawnSubAgentArgs.ts`:

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
 * matched by tool_call_id. Returns null when:
 *   - tool_calls_json is missing/unparseable
 *   - tool_call_id is missing/empty
 *   - no tool call with the given id exists
 *   - the matching tool call is not spawn_sub_agent
 *   - the matching call's arguments are not parseable
 *   - the matching call's sub_agents is not an array
 *
 * `arguments` may be either a JSON string (OpenAI format) or an already-parsed
 * object — both are handled.
 */
export function parseSpawnSubAgentArgs(
  toolCallsJson: string | null | undefined,
  toolCallId: string | null | undefined,
): SubAgentArgs[] | null {
  if (!toolCallsJson || !toolCallId) return null

  let parsed: unknown
  try {
    parsed = JSON.parse(toolCallsJson)
  } catch {
    return null
  }

  if (!Array.isArray(parsed)) return null

  const match = parsed.find(
    (tc: any) => tc && tc.id === toolCallId && tc.function?.name === 'spawn_sub_agent',
  )
  if (!match) return null

  const rawArgs = match.function?.arguments
  if (rawArgs == null) return null

  let args: any
  if (typeof rawArgs === 'string') {
    try {
      args = JSON.parse(rawArgs)
    } catch {
      return null
    }
  } else if (typeof rawArgs === 'object') {
    args = rawArgs
  } else {
    return null
  }

  if (!args || !Array.isArray(args.sub_agents)) return null

  // Defensive copy: only include known fields, don't trust the LLM's shape.
  return args.sub_agents.map((sa: any) => {
    if (!sa || typeof sa.name !== 'string' || typeof sa.instruction !== 'string') {
      return null
    }
    const result: SubAgentArgs = {
      name: sa.name,
      instruction: sa.instruction,
    }
    if (Array.isArray(sa.tools)) result.tools = sa.tools
    if (typeof sa.timeout_seconds === 'number') result.timeout_seconds = sa.timeout_seconds
    if (typeof sa.inherited_context === 'string') result.inherited_context = sa.inherited_context
    return result
  }).filter((sa: SubAgentArgs | null): sa is SubAgentArgs => sa !== null)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/parseSpawnSubAgentArgs.spec.ts 2>&1 | tail -n 30`
Expected: 14 tests pass (the 14 in the file). Build summary clean.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-inherited-context-ui
git add src/apps/desktop/src/helpers/parseSpawnSubAgentArgs.ts \
        src/apps/desktop/src/__tests__/parseSpawnSubAgentArgs.spec.ts
git commit -m "feat(desktop): add parseSpawnSubAgentArgs helper for tool-call args"
```

---

## Chunk 2: SpawnSubAgent.vue changes

### Task 2.1: Add `subAgentArgs` prop and per-agent badge

**Files:**
- Modify: `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue`

- [ ] **Step 1: Add the import and new prop**

In the `<script setup>` block at the top of `SpawnSubAgent.vue`, add the import:

```ts
import type { SubAgentArgs } from '../../helpers/parseSpawnSubAgentArgs'
```

Add the new prop to `defineProps`:

```ts
const props = defineProps<{
  content: string
  expanded?: boolean
  subAgentArgs?: SubAgentArgs[] | null
}>()
```

- [ ] **Step 2: Add the `hasInheritedContext` computed and `describeInheritedContext` helper**

Add to the `<script setup>` block (after the existing `agentCount` computed around line 95):

```ts
// True when at least one sub-agent has a non-`none` inherited_context mode.
const hasInheritedContext = computed(() => {
  if (!props.subAgentArgs) return false
  return props.subAgentArgs.some(
    a => a.inherited_context && a.inherited_context !== 'none'
  )
})

// Human-readable description of the inherited_context mode for the badge tooltip.
function describeInheritedContext(mode: string): string {
  if (mode === 'all') return 'all parent messages'
  if (mode === 'since_last_user') return 'from the last user message onward'
  const m = mode.match(/^last:(\d+)$/)
  if (m) return `last ${m[1]} parent messages (default 10 if unspecified)`
  return mode
}
```

- [ ] **Step 3: Add the per-agent badge in each agent row**

In the template, between the existing session_id `<span>` (around line 147-149) and the `<span class="flex-1">`, insert the badge:

```vue
<span
  v-if="subAgentArgs?.[idx]?.inherited_context && subAgentArgs[idx].inherited_context !== 'none'"
  class="text-[10px] px-1.5 py-0.5 rounded font-mono whitespace-nowrap"
  style="background-color: var(--color-violet); color: white; opacity: 0.85;"
  :title="`Parent history: ${describeInheritedContext(subAgentArgs[idx].inherited_context!)}`"
>
  parent: {{ subAgentArgs[idx].inherited_context }}
</span>
```

Read the file to find the exact insertion point. The session_id span is around line 147:
```vue
<span v-if="agent.sessionId" class="text-[var(--semantic-text-muted)] text-xs font-mono truncate max-w-[120px]" :title="agent.sessionId">
  {{ agent.sessionId }}
</span>
```

Insert the new `<span>` immediately AFTER this block, BEFORE the `<span class="flex-1">` line.

- [ ] **Step 4: Add the header summary indicator**

In the component header (around line 110-114), between the agent count `<span>` and the summary badges, insert:

```vue
<span
  v-if="hasInheritedContext"
  class="text-[10px] text-[var(--color-violet)] opacity-70 whitespace-nowrap"
  title="At least one sub-agent was spawned with parent conversation history"
>
  ↻ with parent history
</span>
```

The existing code is:
```vue
<span class="flex-1 truncate text-left text-[var(--color-violet)] font-medium" :title="agentCount + ' sub-agent(s)'">
  {{ agentCount }} sub-agent{{ agentCount !== 1 ? 's' : '' }}
</span>
<!-- Summary badges -->
<span v-if="summary" class="flex items-center gap-1.5">
```

Insert the new `<span>` between the agent-count line and the `<!-- Summary badges -->` comment.

- [ ] **Step 5: Verify the build**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 30`
Expected: clean build, no TypeScript errors.

(The "ALWAYS use `bun run build`" memory applies — `build-only` skips vue-tsc type checks.)

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue
git commit -m "feat(desktop): show inherited_context badge in SpawnSubAgent"
```

---

## Chunk 3: ChatView.vue changes

### Task 3.1: Find the triggering assistant message and pass `subAgentArgs`

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 1: Add the import**

At the top of the `<script setup>` block, find the existing helper imports and add:

```ts
import { parseSpawnSubAgentArgs } from '../helpers/parseSpawnSubAgentArgs'
```

(Adjust the relative path if other helpers use a different convention — read the existing imports to verify.)

- [ ] **Step 2: Add the helper function for finding the args**

Add a small helper near the other computed/function definitions in ChatView.vue (e.g., after `groupToolNames` around line 615):

```ts
// Find the sub_agents args for a tool group, by walking backwards to the
// assistant message that triggered it (matched by tool_call_id).
function findSubAgentArgsForToolGroup(
  toolCallId: string | undefined,
  groups: MessageGroup[],
  currentGroupIndex: number,
): SubAgentArgs[] | null {
  if (!toolCallId) return null
  // Walk backwards from the current group
  for (let i = currentGroupIndex - 1; i >= 0; i--) {
    const g = groups[i]
    if (g.role !== 'assistant') continue
    for (const msg of g.messages) {
      if (!msg.tool_calls_json) continue
      const args = parseSpawnSubAgentArgs(msg.tool_calls_json, toolCallId)
      if (args) return args
    }
  }
  return null
}
```

Note: the function is per-message (each tool message in the group could have a different `tool_call_id`), so we'll call it per-message in the template, not per-group.

- [ ] **Step 3: Update the `<SpawnSubAgent>` v-if to pass the new prop**

Find the current SpawnSubAgent block (around line 1825-1829):

```vue
<SpawnSubAgent
  v-else-if="msg.tool_name === 'spawn_sub_agent'"
  :content="msg.content"
  :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
/>
```

Replace it with:

```vue
<SpawnSubAgent
  v-else-if="msg.tool_name === 'spawn_sub_agent'"
  :content="msg.content"
  :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
  :sub-agent-args="findSubAgentArgsForToolGroup(msg.tool_call_id, messageGroups, groupIndex)"
/>
```

- [ ] **Step 4: Verify the build**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 30`
Expected: clean build, no TypeScript errors.

- [ ] **Step 5: Run all frontend tests**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 30`
Expected: all existing tests still pass (sseClient, useProfileDelete, sidebarActiveState, etc.) plus the new 14 parser tests. Build summary clean.

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(desktop): thread inherited_context args to SpawnSubAgent"
```

---

## Chunk 4: Manual smoke test

### Task 4.1: End-to-end verification in the desktop app

- [ ] **Step 1: Verify the build is clean one more time**

```bash
cd src/apps/desktop && timeout 240 bun run build 2>&1 | tail -n 10
```

Expected: clean.

- [ ] **Step 2: Manual smoke test in the desktop app**

1. Start the desktop app (`bun run tauri:dev` or however this project runs).
2. Open a chat, send 2-3 user/assistant turns.
3. Send a message that triggers `spawn_sub_agent` with a mix of modes:
   - sub-agent 1: `inherited_context: "last:3"`
   - sub-agent 2: `inherited_context: "none"`
   - sub-agent 3: `inherited_context: "all"`
4. Verify the expanded `<SpawnSubAgent>` card shows:
   - Header: "↻ with parent history" indicator (small, subtle violet text)
   - sub-agent 1 row: small violet `parent: last:3` badge next to the session_id
   - sub-agent 2 row: NO badge (because mode is `none`)
   - sub-agent 3 row: small violet `parent: all` badge
5. Hover each badge → tooltip shows the human-readable description
6. Test with `since_last_user` mode to verify the badge label and tooltip render correctly
7. Test by RELOADING the page (or fetching the chat history from a fresh load) to verify the args are read from the assistant message's `tool_calls_json`, not from any in-memory state

- [ ] **Step 3: Memory capture (only if something was learned)**

If anything non-obvious was learned during implementation, update `.nalar/memories/` with a one-paragraph memory file. Examples of when to add a memory:
- The Vue 3 composition API pattern didn't behave as expected
- The Vitest test setup needed a workaround
- A TypeScript type error took a long time to diagnose

Skip this step if execution was clean.

- [ ] **Step 4: Final commit (if Step 3 added anything)**

```bash
git add .nalar/memories/
git commit -m "docs(memory): capture learnings from inherited_context UI implementation"
```

---

## Out of scope (follow-up work, not in this plan)

- A generic tool-args disclosure for all tools (Option B from brainstorming)
- Surfacing other `spawn_sub_agent` parameters (`tools`, `timeout_seconds`) in the UI
- Editing the `inherited_context` value from the UI
- A "rerun with different mode" affordance
- Unit tests for the new component prop rendering (the parser tests + manual smoke test cover the feature; component-render tests would require jsdom + Vue Test Utils setup, which is more scaffolding than this small UI change justifies)
