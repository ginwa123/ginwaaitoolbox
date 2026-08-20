<!--
  AgentChatDialog — modal chat overlay for agent sessions.

  Wraps the existing ChatView component in a centred modal. Mirrors
  KanbanChatDialog / DesignChatDialog (D12).

  Public API:
    props:  show, task, workspaceId, itemId, cwd
    emits:  close
-->
<script setup lang="ts">
import ChatView from '../views/ChatView.vue'

interface Props {
  show: boolean
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
  <Teleport to="body">
    <Transition name="agent-chat-dialog">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        role="dialog"
        aria-modal="true"
        aria-labelledby="agent-chat-dialog-title"
        data-testid="agent-chat-dialog"
      >
        <div class="absolute inset-0 backdrop-blur-md" style="background: rgba(0, 0, 0, 0.6);" @click="handleClose" />
        <div
          class="relative w-full max-w-5xl h-[90vh] mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
        >
          <div class="px-5 py-3 flex items-center justify-between" style="border-bottom: 1px solid var(--color-border);">
            <h3 id="agent-chat-dialog-title" class="text-sm font-semibold" style="color: var(--semantic-text);">
              {{ props.task.name || 'Agent Chat' }}
            </h3>
            <button type="button" @click="handleClose" data-testid="agent-chat-close" class="text-sm px-2 py-1 rounded" style="color: var(--semantic-text-dim);">
              ✕ Close
            </button>
          </div>
          <div class="flex-1 min-h-0">
            <ChatView
              :chat-id="props.task.id"
              :chat-name="props.task.name || 'Agent Chat'"
              type="task"
              :cwd="props.cwd"
            />
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.agent-chat-dialog-enter-active,
.agent-chat-dialog-leave-active {
  transition: opacity 0.2s ease;
}
.agent-chat-dialog-enter-from,
.agent-chat-dialog-leave-to {
  opacity: 0;
}
</style>