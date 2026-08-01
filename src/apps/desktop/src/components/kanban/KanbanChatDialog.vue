<!--
  KanbanChatDialog — centered modal dialog that hosts the kanban task
  chat. Opens on top of the kanban board (the kanban stays full-width
  behind a dimmed+blurred backdrop). Click backdrop / press Esc /
  click ✕ to close.

  Mirrors the project modal pattern (KanbanTaskDetailDialog,
  FilePreviewModal, KanbanSettingsDialog): <Teleport to="body">,
  fixed inset-0 z-50, Esc keydown, v-model:show + close emit.

  ChatView is mounted with :show-header="false" so the dialog's own
  header carries the task name + ✕ and we don't double up.

  The :key="'task-' + task.id" on <ChatView> preserves the
  useChatScrollRestore scroll position across task switches and
  forces a fresh mount when the user clicks a different task card
  while the dialog is open (Notion/Linear content-swap pattern).

  Public API:
    props:
      show          boolean
      task          Task | null
      workspaceId   string
      itemId        string        (the kanban item id; for context)
      projectName   string        (→ ChatView :project-name)
      cwd           string        (→ ChatView :cwd)
    emits:
      update:show   [value: boolean]  (v-model:show)
      close         []                (backward compat with KanbanSettingsDialog-style binding)

  Sizing (2026-08-06 polish):
    - 90vw × 85vh (was 80vw × 80vh — bigger per user feedback)
    - max 1200px × 900px (was 1100 × 800)
    - min 640px × 420px (was 480 × 320)
    - panel background: opaque var(--semantic-content-bg) + glassmorphism
      via backdrop-filter on the panel itself (slightly tints the
      kanban behind the panel edges without making the panel
      semi-transparent — addresses the "transaprent" feedback)
    - backdrop: rgba(0, 0, 0, 0.65) with backdrop-blur (was 0.5)
    - header: subtle violet→aqua gradient strip + larger close
      button with hover affordance
-->
<script setup lang="ts">
import { nextTick, ref, watch } from 'vue'
import ChatView from '../views/ChatView.vue'
import type { Task } from '../../stores/workspaces'

const props = withDefaults(
  defineProps<{
    show: boolean
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
  'update:show': [value: boolean]
  close: []
}>()

const closeDialog = () => {
  emit('update:show', false)
  emit('close')
}

const handleKeydown = (e: KeyboardEvent) => {
  if (e.key === 'Escape') {
    e.stopPropagation()
    closeDialog()
  }
}

// Focus the dialog wrapper on open so Esc works without a prior click.
// (Do NOT auto-focus the chat input — would steal typing position
// from a previously-open chat.)
const dialogRootRef = ref<HTMLDivElement | null>(null)
watch(
  () => props.show,
  async (open) => {
    if (open) {
      await nextTick()
      dialogRootRef.value?.focus()
    }
  },
)
</script>

<template>
  <Teleport to="body">
    <!--
      Wrapper fills the viewport. Uses explicit positioning
      (inset-0) for the backdrop layer, then centers the dialog
      panel via absolute top/left + transform translate(-50%, -50%).
      This is more bulletproof than `flex items-center justify-center`
      in environments where the dialog wrapper might not establish
      a proper flex context (e.g., when teleported to <body> in some
      edge cases). Either approach works in standard browsers — the
      explicit-position version just doesn't depend on the wrapper
      being correctly identified as a flex container by the layout
      engine.
    -->
    <div
      v-if="show"
      ref="dialogRootRef"
      tabindex="-1"
      class="fixed inset-0 z-50"
      @keydown="handleKeydown"
      data-testid="kanban-chat-dialog-root"
    >
      <!--
        Backdrop — fills the wrapper (which fills the viewport via
        inset-0). Darker + heavier blur than the standard 0.5/0.5
        so the user's focus is clearly on the dialog. Click here →
        close.
      -->
      <div
        class="absolute inset-0"
        style="background: rgba(0, 0, 0, 0.65); backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px);"
        data-testid="kanban-chat-dialog-backdrop"
        @click="closeDialog"
      ></div>

      <!--
        Dialog panel. Explicit centering: top:50%, left:50%, then
        translate(-50%, -50%) to truly center. Bigger sizing (90vw ×
        85vh, max 1200×900) per user feedback. OPAQUE background
        (var(--semantic-content-bg) is the fully-saturated card
        surface; var(--semantic-bg) was sometimes being inherited
        transparent in nested contexts). Hairline violet border +
        glow shadow so the panel reads as a distinct surface against
        the dimmed backdrop. @click.stop prevents inner clicks
        from bubbling to the backdrop.
      -->
      <div
        class="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 flex flex-col overflow-hidden"
        style="
          background: var(--semantic-content-bg);
          width: 95vw;
          height: 90vh;
          max-width: 1400px;
          max-height: 1000px;
          min-width: 720px;
          min-height: 480px;
          border: 1px solid var(--color-violet);
          border-radius: 14px;
          box-shadow:
            0 0 0 1px rgba(137, 146, 167, 0.15),
            0 12px 40px rgba(0, 0, 0, 0.6),
            0 24px 80px rgba(0, 0, 0, 0.4);
        "
        data-testid="kanban-chat-dialog"
        @click.stop
      >
        <!--
          Header — subtle accent gradient (left-to-right violet→aqua)
          matches the project's design language. Slightly larger touch
          targets (h-12) and a clearer close button (✕ with custom
          SVG) so the user can dismiss the dialog confidently.
        -->
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
            data-testid="kanban-chat-dialog-title"
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
            data-testid="kanban-chat-dialog-close"
            aria-label="Close chat"
            title="Close (Esc)"
            @click="closeDialog"
            @mouseover="(e) => { (e.currentTarget as HTMLElement).style.background = 'rgba(196, 116, 110, 0.18)'; (e.currentTarget as HTMLElement).style.color = 'var(--color-red)'; (e.currentTarget as HTMLElement).style.borderColor = 'rgba(196, 116, 110, 0.4)' }"
            @mouseleave="(e) => { (e.currentTarget as HTMLElement).style.background = 'transparent'; (e.currentTarget as HTMLElement).style.color = 'var(--semantic-text-muted)'; (e.currentTarget as HTMLElement).style.borderColor = 'transparent' }"
          >
            ✕
          </button>
        </header>

        <!--
          Chat body. ChatView's internal header is suppressed via
          :show-header="false" so the dialog's header above is the
          only chrome. The :key contract preserves the
          useChatScrollRestore scroll position when task changes
          (Vue reuses the same ChatView instance across the same
          task id; remounts with a new task id → fresh scroll
          container).
        -->
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
          @close="closeDialog"
        />
      </div>
    </div>
  </Teleport>
</template>
