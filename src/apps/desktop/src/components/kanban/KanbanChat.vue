<!--
  KanbanChat — inline chat view for a kanban task.

  Replaces the former KanbanChatDialog modal overlay. Renders inline
  (no Teleport, no backdrop, no show prop, no Esc handling) so the
  kanban task chat lives in the normal layout flow, mirroring
  AgentChatView / StandardTaskChatView.

  Mounted in AppLayout's <main> v-else-if chain BEFORE KanbanView so
  the chat REPLACES the board when a task is active (same swap
  semantics as AgentChatView replacing AgentView). Closing the chat
  (@close → handleCloseTaskView clears activeTask) falls back to
  KanbanView.

  ChatView is mounted with :show-header="false" so this component's
  own header carries the task name + close button and we don't
  double up.

  The :key="'task-' + task.id" preserves the useChatScrollRestore
  scroll position across task switches and forces a fresh mount when
  the user clicks a different task card while the chat is open
  (Notion/Linear content-swap pattern).

  Public API:
    props:
      task          Task | null
      workspaceId   string
      itemId        string        (the kanban item id; for context)
      projectName   string        (→ ChatView :project-name)
      cwd           string        (→ ChatView :cwd)
    emits:
      close         []            (forwarded from ChatView @close + header ✕)
-->
<script setup lang="ts">
import ChatView from '../views/ChatView.vue'
import type { Task } from '../../stores/workspaces'

withDefaults(
  defineProps<{
    task: Task | null
    workspaceId?: string
    itemId?: string
    projectName?: string
    cwd?: string
  }>(),
  {
    workspaceId: '',
    itemId: '',
    projectName: '',
    cwd: '',
  },
)

const emit = defineEmits<{
  close: []
}>()

const handleClose = () => {
  emit('close')
}
</script>

<template>
  <div
    class="w-full h-full flex flex-col overflow-hidden"
    style="background: var(--semantic-content-bg);"
    data-testid="kanban-chat"
  >
    <header
      class="flex items-center gap-3 px-6 py-3 shrink-0 h-14"
      style="
        background: linear-gradient(
          90deg,
          rgba(137, 146, 167, 0.18),
          rgba(142, 164, 162, 0.10) 70%,
          transparent
        );
        border-bottom: 1px solid var(--color-border);
      "
    >
      <div
        class="w-9 h-9 rounded-lg flex items-center justify-center shrink-0"
        style="
          background: linear-gradient(135deg, var(--color-violet), var(--color-aqua));
          color: var(--color-bg);
        "
        aria-hidden="true"
      >
        <svg
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2.5"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
        </svg>
      </div>
      <h3
        class="text-base font-semibold truncate flex-1"
        style="color: var(--semantic-text);"
        data-testid="kanban-chat-title"
      >
        {{ task?.name || 'Chat' }}
      </h3>
      <button
        type="button"
        class="shrink-0 w-10 h-10 rounded-md flex items-center justify-center text-lg transition-all"
        style="
          color: var(--semantic-text-muted);
          background: transparent;
          border: 1px solid transparent;
        "
        data-testid="kanban-chat-close"
        aria-label="Close chat"
        title="Close"
        @click="handleClose"
        @mouseover="(e) => { (e.currentTarget as HTMLElement).style.background = 'rgba(196, 116, 110, 0.18)'; (e.currentTarget as HTMLElement).style.color = 'var(--color-red)'; (e.currentTarget as HTMLElement).style.borderColor = 'rgba(196, 116, 110, 0.4)' }"
        @mouseleave="(e) => { (e.currentTarget as HTMLElement).style.background = 'transparent'; (e.currentTarget as HTMLElement).style.color = 'var(--semantic-text-muted)'; (e.currentTarget as HTMLElement).style.borderColor = 'transparent' }"
      >
        ✕
      </button>
    </header>

    <div class="flex-1 min-h-0">
      <ChatView
        v-if="task"
        :key="'task-' + task.id"
        :chat-id="task.id"
        :chat-name="task.name"
        :type="'task'"
        :cwd="cwd"
        :task-id="task.id"
        :task-name="task.name"
        :project-name="projectName"
        :show-header="false"
        @close="handleClose"
      />
    </div>
  </div>
</template>
