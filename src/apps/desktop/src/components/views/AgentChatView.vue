<!--
  AgentChatView — inline chat view for agent sessions.

  Replaces the former AgentChatDialog modal overlay. Renders inline
  (no Teleport, no backdrop, no show prop) so the agent chat lives
  in the normal layout flow, mirroring StandardTaskChatView.

  Public API:
    props:  task, workspaceId, itemId, cwd
    emits:  close
-->
<script setup lang="ts">
import ChatView from './ChatView.vue'
import SessionSlider from '../SessionSlider.vue'

interface Props {
  task: { id: string; name?: string; task_type?: string }
  workspaceId: string
  itemId: string
  cwd: string
}

const props = defineProps<Props>()
const emit = defineEmits<{ close: [] }>()

function handleClose() {
  emit('close')
}
</script>

<template>
  <!-- Wrapper bg must match AppLayout's main-content (--semantic-content-bg, #181616),
       not --semantic-card-bg (#1D1C19), or agent chats render a warmer/lighter
       shade than standalone + design chats. -->
  <div
    class="w-full h-full flex flex-col overflow-hidden"
    style="background-color: var(--semantic-content-bg)"
    data-testid="agent-chat-view"
  >
    <div
      class="relative px-5 py-3 flex items-center justify-between shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <h3 class="text-sm font-semibold" style="color: var(--semantic-text)">
        {{ props.task.name || 'Agent Chat' }}
      </h3>
      <button
        type="button"
        @click="handleClose"
        data-testid="agent-chat-close"
        class="text-sm px-2 py-1 rounded"
        style="color: var(--semantic-text-dim)"
      >
        ✕ Close
      </button>
      <!-- Same per-session worker indicator the sidebar/task rows show:
           a yellow circle spinner while
           processingState[task.id] is true. The key matches the inner
           ChatView's session id (it strips a leading `chat-`, and we
           pass the raw task id, so both resolve to task.id). -->
      <SessionSlider :session-id="props.task.id" test-id="agent-chat-slider" />
    </div>
    <div class="flex-1 min-h-0">
      <ChatView
        :key="'agent-chat-' + props.task.id"
        :chat-id="props.task.id"
        :chat-name="props.task.name || 'Agent Chat'"
        type="task"
        :cwd="props.cwd"
      />
    </div>
  </div>
</template>
