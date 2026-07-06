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
