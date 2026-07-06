//! Static regression checks for the `DesignView` chat toggle.
//!
//! Why this file exists
//! ────────────────────
//! The `Chat` toggle on the DesignView component creates a single
//! `workspace_item_tasks` row per design item, idempotently. This
//! test pins the contract at the source level (no behavioral test
//! infra is in scope for v1). The contract is enforced by reading
//! the component source and greping for the required substrings.
//! Future refactors that drop any of these would re-create a new
//! task on every toggle click (the worst-case regression), so the
//! assertions are deliberately redundant with the runtime logic.
//!
//! Contract summary:
//!   - The toggle button has `data-testid="design-toggle-chat"`
//!     for end-to-end testing.
//!   - The toggle calls `api.getTasks` BEFORE calling
//!     `api.createTask` (idempotency).
//!   - The toggle uses the literal `'Chat'` as the look-up AND
//!     create discriminator (so a re-toggle reuses the row).
//!   - The ChatView is gated by `v-if="showChat && chatTaskId"`.
//!   - The toggle OFF does NOT delete the task row (keeps it for
//!     instant re-toggle).
//!   - The toggle state resets when the user switches design items.

import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { beforeAll, test } from 'vitest'

const VIEW_PATH = resolve(process.cwd(), 'src/components/DesignView.vue')

let source = ''

beforeAll(() => {
  // Read the source from disk at test-boot. We don't normalize
  // line endings — the repo uses LF, and Vitest runs on Linux.
  source = readFileSync(VIEW_PATH, 'utf8')
})

function has(needle: string): boolean {
  return source.includes(needle)
}

test('DesignView has the chat-toggle button (design-toggle-chat testid)', () => {
  if (!has('data-testid="design-toggle-chat"')) {
    throw new Error(`DesignView.vue is missing data-testid="design-toggle-chat"`)
  }
})

test('DesignView toggle is idempotent: looks up existing chat task before creating', () => {
  // The idempotency invariant: on the first toggle ON, the code
  // MUST call api.getTasks(workspaceId, item.id) to find a
  // previously created chat task before falling through to
  // api.createTask. If this grep fails, a regression has made
  // the toggle create a duplicate task on every click.
  const hasGet = has('api.getTasks') || has('getTasks(')
  const hasCreate = has('api.createTask') || has('createTask(')
  if (!hasGet || !hasCreate) {
    throw new Error(
      `DesignView.vue must call both getTasks and createTask to be ` +
        `idempotent. Found getTasks=${hasGet}, createTask=${hasCreate}.`,
    )
  }
})

test('DesignView toggle creates a task named "Chat" (discriminator)', () => {
  // The discriminator string is used on both sides: the look-up
  // finds it (so a re-toggle reuses the row) and the create uses
  // it (so the row is findable on the next toggle). At least two
  // occurrences: the constant declaration + the createTask call.
  const chats = source.match(/'Chat'/g) ?? []
  if (chats.length < 2) {
    throw new Error(
      `DesignView.vue must reference the literal 'Chat' at least ` +
        `twice (look-up + create). Found ${chats.length}.`,
    )
  }
})

test('DesignView mounts ChatView only when the toggle is ON and a chatTaskId exists', () => {
  // The v-if must guard both the toggle state AND the resolved
  // task id — otherwise the panel can flash with an empty chat id.
  const guarded = has('v-if="showChat && chatTaskId"')
  if (!guarded) {
    throw new Error(
      `DesignView.vue must guard the ChatView with ` +
        `'v-if="showChat && chatTaskId"' (both conditions).`,
    )
  }
  if (!has('<ChatView')) {
    throw new Error(`DesignView.vue must render <ChatView ...> somewhere.`)
  }
})

test('DesignView toggle off does NOT delete the task row', () => {
  // OFF just hides the panel — the task row stays so a future ON
  // is instant. The component should not call api.deleteTask
  // anywhere (task deletion is a separate UI feature).
  if (has('api.deleteTask') || has('deleteTask(')) {
    throw new Error(
      `DesignView.vue should not delete the chat task on toggle OFF. ` +
        `Found an api.deleteTask reference. The task row must stay so a ` +
        `future toggle ON is instant.`,
    )
  }
})

test('DesignView watches item.id to reset chat state on design switch', () => {
  // When the user switches from design A to design B, the toggle
  // must reset (the new design may not have a chat task yet) and
  // the chat task lookup must re-run for the new item.
  if (!has("watch(() => props.item.id")) {
    throw new Error(
      `DesignView.vue must watch('item.id') and re-run the chat ` +
        `task resolution so the toggle reflects the new design's ` +
        `persisted state.`,
    )
  }
})

test('DesignView toggle awaits the eager resolve before creating a Chat task', () => {
  // Race fix (2026-07-06): the toggle must NOT call api.createTask
  // until the eager getTasks lookup has completed. The previous
  // version set `showChat = true` and called createTask whenever
  // `chatTaskId.value` was null, which raced with the async
  // `resolveExistingChatTask` call in onMounted — clicking the
  // toggle before the lookup finished created a SECOND Chat task
  // (no UNIQUE constraint on (workspace_item_id, name)) that
  // shadowed the original one and the user saw an empty chat.
  //
  // We assert two source-level contracts here:
  //   1. `handleToggleChat` MUST `await resolveExistingChatTask`
  //      when `chatReady` is false.
  //   2. The `showChat = true` flip MUST be the LAST mutation in
  //      the ON path — it happens AFTER both the await and the
  //      create, not before.
  //
  // The combined pattern is: `await resolveExistingChatTask` appears
  // between `function handleToggleChat` and the eventual
  // `showChat.value = true` line.

  // Grab the body of handleToggleChat.
  const fnMatch = source.match(/async function handleToggleChat\(\) \{([\s\S]*?)\n\}/)
  if (!fnMatch || !fnMatch[1]) {
    throw new Error(
      `DesignView.vue is missing the async function handleToggleChat() ` +
        `block. The toggle must be async so it can await the eager ` +
        `resolveExistingChatTask lookup.`,
    )
  }
  const body: string = fnMatch[1]

  // 1. The await must be present in the ON path.
  if (!body.includes('await resolveExistingChatTask')) {
    throw new Error(
      `handleToggleChat must 'await resolveExistingChatTask' when ` +
        `chatReady is false — otherwise a fast click before the ` +
        `eager lookup finishes will create a duplicate Chat task.`,
    )
  }

  // 2. The 'showChat.value = true' flip must come AFTER the
  //    await (and after any createTask call). If the optimistic
  //    flip is still in place (showChat=true before the await),
  //    the panel would briefly show the toggle in the 'Chat On'
  //    state with no ChatView mounted, which is the original
  //    symptom.
  const flipPos = body.indexOf('showChat.value = true')
  const awaitPos = body.indexOf('await resolveExistingChatTask')
  const createPos = body.indexOf('api.createTask')
  if (flipPos < 0) {
    throw new Error(
      `handleToggleChat must set 'showChat.value = true' at the end ` +
        `of the ON path (after the await and the create).`,
    )
  }
  if (awaitPos < 0 || awaitPos > flipPos) {
    throw new Error(
      `handleToggleChat must 'await resolveExistingChatTask' BEFORE ` +
        `flipping 'showChat.value = true' — otherwise the panel ` +
        `flashes to the 'Chat On' state with no ChatView mounted.`,
    )
  }
  if (createPos > 0 && (createPos > flipPos)) {
    throw new Error(
      `handleToggleChat must call 'api.createTask' BEFORE flipping ` +
        `'showChat.value = true' so the ChatView has a valid ` +
        `chatTaskId prop when it mounts.`,
    )
  }
})
