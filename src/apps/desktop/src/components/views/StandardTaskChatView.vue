<!--
  StandardTaskChatView — thin wrapper around <ChatView> for the
  standard (non-kanban / non-agent / non-design) task chat branch in
  AppLayout: folder, memory, chat and routine items.

  Why a wrapper at all?
    - DesignChatDialog already wraps <ChatView>
      for its host branch. Standard task chat is the third branch
      of the same v-else-if chain — extracting it into its own
      component keeps the layout's right-pane rendering rules in one
      place (the v-if / v-else-if ladder) and the per-mount behaviour
      next to the ChatView primitive it consumes.
    - Migration 052 invariant: task.id == session.id. We pass
      `chat-${task.id}` as the chat session id, matching the inline
      behaviour this component replaced.

  App bar
  ───────
  This mode used to render NO bar at all (ChatView's `showHeader` was
  never set), so the ◫ sidebar toggle floated over the transcript and
  there was no way to leave the chat from the surface. It now sets
  `:show-header="true"` and re-emits ChatView's `close`, so all three
  workspace-item modes (kanban / agent / standard) render the same
  shared ChatAppBar — same height, background, title, sidebar toggle
  and ✕.

  Public API:
    props:
      task    Task       the active task (required; used to derive
                         chat-id, chat-name, and the :key)
      cwd     string     the resolved working directory forwarded
                         to ChatView (default: '')
    emits:
      update-chat-id     [oldId: string, newId: string]   forwarded
                         verbatim from ChatView when the underlying
                         session id changes (e.g. auto-rename on
                         first message)
      close              []                                forwarded
                         verbatim from ChatView's app-bar ✕
-->
<script setup lang="ts">
import ChatView from './ChatView.vue'
import type { Task } from '../../stores/workspaces'

withDefaults(
  defineProps<{
    task: Task
    cwd?: string
  }>(),
  {
    cwd: '',
  },
)

const emit = defineEmits<{
  'update-chat-id': [oldId: string, newId: string]
  close: []
}>()
</script>

<template>
  <!--
    Migration 052 invariant — task.id == session.id. The leading
    `chat-` namespace distinguishes task chats from other chat-id
    prefixes (`pending-…` for unsaved drafts, plain `chat-…` for
    sidebar-opened chats, etc.) and matches the format AppLayout's
    standalone ChatView branch uses for `activeChatId`.

    The template expression is evaluated on every re-render, so when
    the host switches tasks (different task.id) the :key changes and
    Vue remounts <ChatView> — preserving useChatScrollRestore's
    scroll-position contract across task switches (same as the
    kanban chat branch's `:key="'kanban-chat-' + activeTask.id"`).
  -->
  <ChatView
    :key="`chat-${task.id}`"
    :chat-id="`chat-${task.id}`"
    :chat-name="task.name ?? ''"
    :cwd="cwd"
    :show-header="true"
    @update-chat-id="(oldId, newId) => emit('update-chat-id', oldId, newId)"
    @close="emit('close')"
  />
</template>
