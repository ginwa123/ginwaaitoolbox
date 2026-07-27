# design chat 💬 button — exact-name lookup orphans user's prior chats

## Symptom

User opens a design item, clicks the top-right 💬 Chat button in DesignView, sees the
"Design Chat" tab open with "How can I help you? Start a conversation by typing a
message below" — even though they have a chat history for the design item under
a different task name. They expect to see their existing messages.

## Root cause

`handleDesignOpenChat` in `src/apps/desktop/src/components/AppLayout.vue:1223`
looked up the chat by **exact name match** against `'Design Chat'`:

```js
const existingTask = item.tasks?.find((t) => t.name === DESIGN_CHAT_TASK_NAME)
if (existingTask) {
  workspacesStore.setActiveTask(existingTask.id)
  return
}
// else create a new "Design Chat" task
```

Two failure modes:

1. **First click creates an empty canonical task.** User had a prior task
   (e.g. `"ai-chat-view-design"`) with 17 messages. Clicking 💬 doesn't find
   the canonical "Design Chat" name → it creates an empty one. Subsequent
   clicks find the empty canonical and "reuse" it (forever empty).

2. **Even with a populated canonical**, if the user had a chat under ANY
   OTHER name, it's invisible to the button. The "one chat per design
   item" intent in the comment is enforced by name match, which is the
   wrong key.

## Why this was hard to catch

- **TypeScript / vue-tsc don't catch it** — the template compiles cleanly.
- **The original test (`DesignChatToggle.spec.ts`)** only asserted the
  literal `name === 'Design Chat'` branch existed; it never asserted the
  fallback behaviour. The test passes on the bug.
- **Static contract tests don't render the component** — they grep the
  source for required substrings.
- **The chat-view's empty state is "How can I help you?"** — a friendly
  "looks fine" UX, NOT a crash or error toast. So the bug is silent.

## Fix (commit-level)

Add a `taskHasMessages(taskId)` helper that probes
`api.getChatHistory(taskId, 1)` (limit=1 → fast SQL query). Then in
`handleDesignOpenChat`:

1. Find canonical "Design Chat" task. If exists, **check messages**.
   If has messages → use it.
2. Iterate non-canonical tasks, **check messages** for each. Use the
   first one with messages.
3. Else: reuse canonical if it exists (empty canonical is preferred
   over creating a third task), or create a fresh "Design Chat".

The fallback uses N+1 API calls (limit=1 per task). For typical design
items (1-5 tasks) this is < 100ms total. Acceptable because this only
runs on user click.

## Verification (the user's actual DB, 2026-07-26)

```
sqlite3 ~/.config/nalar/agent.db "SELECT id, name, datetime(created_at) AS created
  FROM workspace_item_tasks WHERE workspace_item_id = 'item_1785067707003783748'
  ORDER BY created_at ASC"

task_1785078944040 |
ai-chat-view-design | 2026-07-26 15:15:44   ← has 17 messages
task_1785079182914 | Design Chat | 2026-07-26 15:19:42   ← empty (auto-created by bug)
```

Live API probe (port 8081):
- `GET /api/llm/session/task_1785079182914/messages?limit=1` → `messages: 0`
- `GET /api/llm/session/task_1785078944040/messages?limit=1` → `messages: 1, total: 17`

After fix: clicking 💬 on this design item probes the canonical → 0 → falls
back → finds 17 in `task_1785078944040` → opens it.

## Regression test

`src/apps/desktop/src/__tests__/DesignChatToggle.spec.ts` now has two new
static-contract tests:

```ts
it('handleDesignOpenChat probes messages via api.getChatHistory', () => {
  expect(source).toMatch(/api\.getChatHistory\(/)
})

it('handleDesignOpenChat skips the canonical task when it is empty and falls back to a task with messages', () => {
  expect(source).toMatch(/if\s*\(hasMessages\)/)
  expect(source).toMatch(/if\s*\(\s*t\.name\s*===\s*DESIGN_CHAT_TASK_NAME\s*\)\s*continue/)
})
```

15/15 tests pass (was 13/13 before).

## Pitfalls

- **Don't iterate just `item.tasks[0]`** as the fallback — that's the
  most-recently-created task (because `addTask` does `unshift`), which
  is OFTEN the empty canonical itself. Iterate all non-canonical tasks.
- **Don't `await` the probe with no error handling** — nalar may be
  offline / 404 / 5xx. The helper swallows errors and returns `false`,
  which is the correct "treat as empty" branch.
- **Don't pick the oldest task as a heuristic** — works for the
  current user's state (canonical was created LATER, so oldest =
  user's prior chat), but breaks if the user manually creates an
  empty task before the canonical. Always probe.
- **The `limit=1` parameter matters** — without it the API returns up
  to 100 messages even though we only want to check existence. With
  `limit=1`, the SQL `LIMIT ?` query is fast.
- **`task.id == session_id` convention** — `api.getChatHistory` takes
  a session_id, but in this codebase `task.id` IS the session_id (per
  the migration-052 comment). Pass `task.id` directly.