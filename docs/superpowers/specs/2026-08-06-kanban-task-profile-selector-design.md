# Kanban New Task Dialog — Profile Model Selector — Design

> **For agentic workers:** This is a design spec. After the user approves, the next step is to invoke the `superpowers:writing-plans` skill to create a bite-sized implementation plan.

**Goal:** Add a profile-model selector to the New Task dialog (`KanbanTaskDetailDialog`, `mode: 'create'`). The user pre-selects which `LlmConfig.profiles_models[name]` profile the agent should use; the choice flows through `POST /api/llm/session` and is persisted on the new session. When the user lands in the chatview, the chatview's profile picker reflects the chosen profile automatically (per PR #158 — chatview profile persists across page refresh).

**Architecture:** Mirror ChatView's profile picker. The dialog loads profiles via `api.getPabrikConfig()` → `config.profiles`. Local `selectedProfile: string` ref (default `''` = backend default / top-level config). Add `selectedProfile?: string` to both `create` and `create-and-run` emit payloads. `KanbanView.handleCreateTaskSave` forwards it to `workspacesStore.runAgentOnNewTask`, which forwards to `api.sendChatMessage`. No backend changes — `POST /api/llm/session` already accepts `selected_profile_model` and persists to `sessions.selected_profile_model`.

**Tech Stack:** Vue 3 + TypeScript + Pinia + Vitest (`@vue/test-utils`). No new dependencies. Reuses the existing `api.getPabrikConfig()` and `api.sendChatMessage(selectedProfile)` patterns.

## 1. Why now — the problem

Today's "Create task & run agent" flow always uses the backend's default profile (the top-level `LlmConfig` model/base_url). If the user wants a non-default profile, they have to:

1. Click "Create task & run agent".
2. Land in the chatview.
3. Click the chatview's profile picker → select profile.
4. The next message (if any) uses the new profile.

The first message (the queued title+description) is already sent with the backend default. For an agent run on a sensitive task (cost / latency / quality), the user often wants the profile choice at task-creation time, not after the first message.

## 2. Current state — what exists today

- `ChatView.vue:730-755` — `loadProfiles()` + `selectedProfile` + dropdown UI. Reads `api.getPabrikConfig()`, shows the chatview picker.
- `api.sendChatMessage(sessionId, message, cwdSession, imageUrls?, selectedProfile?, isAutoRetryUntilStop?)` — already accepts `selectedProfile`. Backend's `POST /api/llm/session` persists `selected_profile_model` on the session.
- `api.updateSession(sid, { selectedProfile })` — the chatview uses this to set the profile mid-session.
- `workspacesStore.runAgentOnNewTask` (PR #160) — currently hardcodes `''` for selectedProfile.
- `KanbanTaskDetailDialog.vue` — create mode has Name, Description, Tags, Unattended toggle. No profile selector.
- `LlmConfig.profiles_models: Record<string, LlmProfile>` — backend-side map of profile name → {model, base_url, sub_agents}.

## 3. Design — UX, wire, sequencing

### 3.1 UX — the new picker (Q2 = 2a: same row as Unattended mode)

```
┌─────────────────────────────────────────────────┐
│ Profile                  Unattended mode         │
│ [🤖 Default (top-level) ▾]    Keep retrying… ● ◯ │
└─────────────────────────────────────────────────┘
```

- The Unattended-mode row becomes a 2-column flex with the profile picker on the left and the existing toggle on the right.
- Profile button: `🤖 <name> ▾` (emoji + name + chevron), mirroring the chatview's picker style.
- Click opens a small dropdown below the button: "Default (top-level config)" + each profile (with `model · base_url` as a subtle subtitle).
- Default selection: `''` (= backend default = "Default (top-level config)"). User opts in by picking a profile.
- Profile list is loaded on dialog open via `api.getPabrikConfig()` (parallel to `ChatView.loadProfiles`). Failure → empty list (no profile options, just the "Default" entry); user sees a non-blocking fallback (the button still works, just only shows "Default").
- The button shows a subtle loader/spinner while profiles are being fetched (matches chatview's UX pattern of `loadProfiles()`).
- Only rendered in `mode: 'create'`. Edit mode keeps today's behavior (no profile picker).

### 3.2 Wire — emit shape

Add `selectedProfile?: string` to the existing `create` and `create-and-run` emit payloads. Both modes of submission carry the chosen profile so:

- "Create task" → task created → user later opens chat → chat's profile picker reflects the chosen profile on first send (since the session was created with that profile).
- "Create task & run agent" → task created → `runAgentOnNewTask` is called with the selected profile → `POST /api/llm/session` sets it on the session.

The existing `api.createTask` doesn't accept `selected_profile_model` (it just creates the row). The profile is set when the session is created — either immediately (via `runAgentOnNewTask`) or later (when the user sends the first message, which goes through `api.sendChatMessage`). For plain "Create task" without an agent run, the profile won't be set on the session until the user manually picks one in the chatview OR sends a message. **Mitigation**: pass `selectedProfile` to `api.createTask` as well? No — `createTask` doesn't accept it; the backend's `task_create.zig` doesn't read `selected_profile_model`. So if the user creates without running, the profile is lost.

Two paths:
- **Path A**: Only thread `selectedProfile` via `runAgentOnNewTask` (for the create-and-run path). For plain create, ignore. → Simpler. Plain-create users would manually set profile in chatview.
- **Path B**: Also thread `selectedProfile` to `api.createTask` (would need backend change to Migration 067+ to write `selected_profile_model` at task-create time if `is_auto_retry_until_stop: '1'`). → Bigger scope.

My recommendation is **Path A** — minimal scope. The use case "user knows they want profile X at task create" usually implies they're going to run the agent anyway (otherwise the choice has no immediate effect). If the user creates a placeholder task and picks a profile, they can still set it later from the chatview.

### 3.3 Sequencing — host (`KanbanView.vue`)

`handleCreateTaskSave` threads `selectedProfile` into the existing `create_and_run` branch's `runAgentOnNewTask` call:

```ts
if (payload.mode === 'create_and_run') {
  const queueMessage = /* ... as before ... */
  const result = await workspacesStore.runAgentOnNewTask(
    wsId, itId, taskId, {
      queueMessage,
      cwd: props.item.path || '',
      isAutoRetryUntilStop: payload.is_auto_retry_until_stop,
      selectedProfile: payload.selectedProfile,  // NEW — empty string = backend default
    },
  )
  // ...
}
```

For plain `create` mode, `selectedProfile` is captured in the dialog's payload but **not persisted** to the new task (per Path A). The dialog still forwards it for consistency; the host ignores it for plain create.

### 3.4 Store — `runAgentOnNewTask` param

```ts
async function runAgentOnNewTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  params: {
    queueMessage: string
    cwd: string
    isAutoRetryUntilStop?: '0' | '1'
    selectedProfile?: string  // NEW — empty/undefined = backend default
  },
): Promise<{ status: string } | undefined> {
  try {
    return await api.sendChatMessage(
      taskId,
      params.queueMessage,
      params.cwd,
      undefined,                                  // imageUrls
      params.selectedProfile ?? '',               // CHANGED — was ''
      params.isAutoRetryUntilStop ?? '',
    )
  } catch (err) { /* ... */ }
}
```

### 3.5 Persistence semantics

| User action | Profile persisted? | Where |
|---|---|---|
| Create task (plain) | ❌ no | The dialog forwards `selectedProfile` but the backend's `task_create.zig` doesn't write it. User can set it later from chatview. |
| Create task & run agent | ✅ yes | `POST /api/llm/session` with `selected_profile_model` → `sessions.selected_profile_model` column. Reflected in the chatview's picker immediately. |
| Edit mode (no picker) | n/a | No profile selector in edit mode (Q1 = 1a). |
| Open chatview later, click picker | ✅ yes | `PUT /api/llm/session/:id` with `selectedProfile`. Same flow as today. |

## 4. Out of scope (deferred)

- **Profile selector in edit mode** (Q1 = 1a). Follow-up.
- **Path B: persist `selected_profile_model` on task create** (would need backend + migration). Follow-up.
- **Profile creation from the picker** (today: "No profiles configured. Add one in Settings." link to PabrikSettings).
- **Profile filtering** (search by model name). Out of scope.

## 5. Files to touch

| Type | Path | Change |
|---|---|---|
| EDIT | `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | Add profile picker UI in create mode; add `selectedProfile` ref + loadProfiles on mount; add `selectedProfile` to `create` and `create-and-run` emit payloads; add `canRunAgent` doesn't gate on profile (any profile OK including default) |
| EDIT | `src/apps/desktop/src/stores/workspaces.ts` | Extend `runAgentOnNewTask` params with `selectedProfile?: string`; forward to `api.sendChatMessage` |
| EDIT | `src/apps/desktop/src/components/kanban/KanbanView.vue` | Forward `payload.selectedProfile` to `runAgentOnNewTask` |
| NEW  | `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.profile.spec.ts` | Behavioural: picker visible in create mode only; loads via `api.getPabrikConfig`; selection updates ref; emit shape includes `selectedProfile`; edit mode hides picker |
| EDIT | `src/apps/desktop/src/__tests__/workspacesStoreRunAgent.spec.ts` | Add 1-2 tests: `selectedProfile` forwarded to `api.sendChatMessage`; empty/undefined → `''` |
| EDIT | `src/apps/desktop/src/__tests__/KanbanView.createAndRun.spec.ts` | Add 1 test: `selectedProfile` flows from dialog emit to store action |

Total: **6 files** (1 NEW, 5 EDIT).

## 6. Verification

- `bun run build` (vue-tsc): clean.
- `bunx vitest run`: all new + existing tests pass (no regression).
- Manual smoke (port 8080):
  1. Open kanban → + on Todo → set title + description → click profile dropdown → pick "900r1bu" → click ▶ Create task & run agent.
  2. Assert: chatview opens with the chatview profile picker showing "900r1bu" (not "Default").
  3. The queued message in the chat is the title + description; the agent runs with the 900r1bu profile.
  4. Pick "Default" → create-and-run → chatview picker shows "Default".
  5. Create-without-run → task created → click card → open chatview → picker shows "Default" (because profile wasn't persisted — Path A).

## 7. Risks & open questions

- **None blocking.** The picker mirrors the chatview's proven pattern. The only subtle behavior is Path A (plain-create loses the profile choice) — accepted as scope-limited and documented for the user.
- **Open**: should the picker ALSO show a "no profiles configured" empty state? — YES, mirror the chatview's "Add one in Settings" hint. Spec'd above.
- **Open**: what if `api.getPabrikConfig()` returns zero profiles? — Picker still shows "Default"; the dropdown only contains the "Default (top-level config)" entry. The user can still proceed with the default. Spec'd above.