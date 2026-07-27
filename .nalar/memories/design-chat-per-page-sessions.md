# design chat 💬 — each page must get its own disjoint chat session

## Symptom

User opens a design item with multiple pages ("AI Chat View", "Kanban Mode"). Clicks
💬 on page A → chats (17 messages). Switches to page B → clicks 💬 → sees page A's
17 messages. Expected: page B has its own separate chat.

The legacy `AppLayout.handleDesignOpenChat` looked up a SINGLE canonical
`"Design Chat"` task across the whole design item, so all pages shared one chat.

## Root cause

`handleDesignOpenChat` keyed the chat task lookup on the *design item*, not the
*design page*. There was no per-page scoping — every 💬 click resolved to the
same task. The 2026-07-26 fix (`design-chat-canonical-name-lookup-orphans-prior-chats.md`)
added an N+1 message-probe fallback for the single-canonical case but did NOT
address the per-page scoping need (multiple pages was rare then; Figma-lite
multi-page tabs landed later in the 2026-07-08 design-mode redesign).

## Fix (2026-07-28)

Plan: `docs/superpowers/plans/2026-07-28-design-per-page-chat-sessions.md`

1. **Per-page canonical name** — task name pattern: `Design Chat: <page_name>`
   (e.g., `Design Chat: AI Chat View`). Each design page gets a disjoint
   `WorkspaceItemTask` row. Lookup is deterministic — no N+1 message probe.
2. **`@open-chat` emit payload** — `DesignView` now emits
   `{ pageId, pageName }`. `AppLayout.handleDesignOpenChat(payload)` uses
   `payload.pageName` to build the per-page name and look up the task.
3. **Legacy migration** — users with a pre-fix `"Design Chat"` canonical
   task that has messages get it renamed in place via `api.updateTask` to
   `"Design Chat: <activePageName>"` on first 💬 click. Task id is preserved
   so all `llm_history` rows stay attached. Empty legacy tasks are NOT
   migrated (they were artifacts of the 2026-07-26 bug, not user-owned
   conversations) — a fresh per-page task is created instead.
4. **Page-switch does NOT swap chat** — when the user clicks a different
   design tab while a chat is open, the chat stays bound to the page that
   opened it. Closing + reopening on the new page binds to the new page.
   This is INTENDED — switching pages mid-conversation shouldn't disrupt
   the user's context.

## File touch map

| File | Change |
|---|---|
| `src/apps/desktop/src/components/design/DesignView.vue` | `openChat` emit now carries `{ pageId, pageName }` from `activePage.value` |
| `src/apps/desktop/src/components/AppLayout.vue` | `handleDesignOpenChat(payload)` rewritten: per-page lookup → legacy rename via `api.updateTask` → fresh create fallback |
| `src/apps/desktop/src/__tests__/DesignChatToggle.spec.ts` | Rewritten: 18 static-contract tests locking per-page behavior + legacy migration |
| `src/apps/desktop/src/__tests__/DesignView.spec.ts` | Updated: 2 emit-payload tests rewritten for the per-page shape |
| `src/apps/desktop/src/stores/workspaces.ts` | Comment-only update on `activeDesignPageId` documenting chat scope |

No backend changes. No new endpoints. Uses existing `api.updateTask` /
`api.createTask` / `api.getChatHistory`.

## Why not a backend `design_page_id` foreign-key column

A textbook answer would be a `design_page_id` column on `workspace_item_tasks`,
but:
- Every chat-related surface (`fireRoutine`, `llm_history.session_id`
  indexing, `/api/llm/session/.../messages`) already keys on
  `session_id = task_id`. A FK would be invisible indirection.
- The user-visible chat list (Chats sidebar) is keyed by task; a hidden FK
  would not be exposed to users.
- The naming convention is sufficient for in-DB queries and via API.
- No migration risk for users with existing design chats.

## Why no N+1 message-probe fallback

The pre-fix handler iterated `item.tasks` looking for ANY task with
messages (a workaround for the single-canonical bug). The per-page lookup
is now deterministic, so the iteration is unnecessary AND actively wrong:
it would surface chats the user typed into other tasks (e.g., a folder
chat on the same design item) under the design-canvas 💬 button. Removing
the iteration makes the wire deterministic — each page binds to its
own chat, period.

The cost: a user who had been chatting with the LLM under a non-canonical
task name (like `"ai-chat-view-design"`) before the fix will see a fresh
empty per-page chat when they click 💬. Their prior chat is still in the
Chats sidebar; they can click it directly to access. This is a
known minor regression acknowledged in the plan, traded for the
deterministic per-page guarantee.

## Page rename + delete behavior (limitations)

- **Rename a page** → chat task keeps its old name (visible as a stale
  entry in the Chats sidebar). New chat for the renamed page uses the
  new name. Documented limitation; a "rename chat on page rename"
  follow-up is out of scope.
- **Delete a page** → chat task becomes orphan (visible in sidebar but
  not bound to any page). Cascade-delete is out of scope; the legacy
  `deleteDesignPage` handler does NOT touch chat tasks.

## Verification

```bash
cd src/apps/desktop
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build   # MUST be clean
timeout 180 bunx vitest run                                     # 1492/1492 pass
timeout 240 bun run build                                       # vue-tsc + vite clean
```

Static-contract tests in `DesignChatToggle.spec.ts` lock the wire:

- `declares openChat in defineEmits with the per-page payload`
- `handleOpenChat emits openChat with the active page payload`
- `handleDesignOpenChat accepts a (pageId, pageName) payload`
- `handleDesignOpenChat looks up the per-page canonical "Design Chat: <pageName>"`
- `handleDesignOpenChat retains DESIGN_CHAT_TASK_NAME constant for legacy migration`
- `handleDesignOpenChat renames the legacy task via api.updateTask`
- `handleDesignOpenChat does NOT iterate all item.tasks for the message-probe fallback`
- `handleDesignOpenChat creates a per-page task via workspacesStore.addTask`
- `handleDesignOpenChat probes legacy task messages via api.getChatHistory`
- `handleDesignOpenChat short-circuits when payload.pageId or payload.pageName is empty`
- `forwards @open-chat to handleDesignOpenChat on every <DesignView>`

## Related

- `design-chat-canonical-name-lookup-orphans-prior-chats.md` — the 2026-07-26
  single-canonical fallback that this plan supersedes for the design domain.
- `docs/superpowers/plans/2026-07-28-design-per-page-chat-sessions.md` — the
  full plan.
