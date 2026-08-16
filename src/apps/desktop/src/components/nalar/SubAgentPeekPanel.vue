<script setup lang="ts">
/**
 * SubAgentPeekPanel — right-side slide-over panel for watching a
 * sub-agent's progress without leaving the parent chat.
 *
 * The component is pure presentational — it renders refs passed in
 * via props (messages / status / errorMessage / totalTokens from
 * `useSubAgentPeek`). It owns no SSE or fetch lifecycle.
 *
 * CRITICAL: per the user's "reuse tool output components" requirement,
 * when rendering a tool message (role='tool'), the panel parses the
 * standard `<tool>...</tool>` envelope (see helpers/unwrapToolOutput.ts)
 * and dispatches to the SAME tool output components used by the parent
 * chat (ReadFile, TextReplace, Bash, SpawnSubAgent, …). See the
 * `renderToolMessage()` function — the v-if chain mirrors
 * `ChatView.vue:2124-2232` so a peek'd sub-agent's tool output looks
 * identical to the one in the parent chat.
 */
import { computed, nextTick, ref, watch } from 'vue'
import { tryUnwrapToolOutput, type UnwrappedToolOutput } from '../../helpers/unwrapToolOutput'
import type { Message } from '../../api'

// Reuse the existing tool output components — same set the parent
// ChatView uses, so the peek visually matches the main chat.
import ReadFile from '../tool_outputs/ReadFile.vue'
import WriteFile from '../tool_outputs/WriteFile.vue'
import UpdateActivity from '../preview/UpdateActivity.vue'
import Search from '../tool_outputs/Search.vue'
import Glob from '../preview/Glob.vue'
import TextReplace from '../tool_outputs/TextReplace.vue'
import Bash from '../preview/Bash.vue'
import ShellTool from '../preview/ShellTool.vue'
import GetSkill from '../preview/GetSkill.vue'
import ViewSkill from '../tool_outputs/ViewSkill.vue'
import ListSkills from '../tool_outputs/ListSkills.vue'
import AddSkill from '../tool_outputs/AddSkill.vue'
import EditSkill from '../tool_outputs/EditSkill.vue'
import RemoveSkill from '../tool_outputs/RemoveSkill.vue'
import RemoveFile from '../tool_outputs/RemoveFile.vue'
import SpawnSubAgent from '../tool_outputs/SpawnSubAgent.vue'
import NalarBrowser from '../tool_outputs/NalarBrowser.vue'
import SetGitWorktree from '../tool_outputs/SetGitWorktree.vue'
import ReadCompactedMessages from '../tool_outputs/ReadCompactedMessages.vue'
import KanbanMove from '../tool_outputs/KanbanMove.vue'
import KanbanList from '../tool_outputs/KanbanList.vue'
import SaveMemory from '../tool_outputs/SaveMemory.vue'
import LoadMemory from '../tool_outputs/LoadMemory.vue'

type PeekStatus = 'idle' | 'loading' | 'streaming' | 'complete' | 'error'

const props = defineProps<{
  sessionId: string
  agentName: string
  instruction: string
  status: PeekStatus
  errorMessage: string | null
  messages: Message[]
  totalTokens?: number
}>()

const emit = defineEmits<{
  close: []
  openFull: [sessionId: string]
  reload: []
}>()

// ── Derived display values ────────────────────────────────────────────

const instructionPreview = computed(() => {
  const max = 200
  return props.instruction.length > max
    ? props.instruction.slice(0, max) + '…'
    : props.instruction
})

const statusLabel = computed(() => {
  switch (props.status) {
    case 'idle': return 'Idle'
    case 'loading': return 'Loading…'
    case 'streaming': return 'Streaming…'
    case 'complete': return 'Complete'
    case 'error': return 'Error'
  }
  return ''
})

const statusClass = computed(() => {
  switch (props.status) {
    case 'streaming': return 'peek-status-streaming'
    case 'complete': return 'peek-status-complete'
    case 'error': return 'peek-status-error'
    default: return 'peek-status-idle'
  }
})

// ── Per-message render helpers ────────────────────────────────────────

/**
 * Strip the `<tool>...</tool>` envelope from a tool message's content,
 * returning the inner `<data>` body (or null if the envelope is
 * malformed). Mirrors ChatView's `innerToolData()` helper.
 */
function innerToolData(msg: Message): string | null {
  const unwrapped: UnwrappedToolOutput | null = tryUnwrapToolOutput(msg.content)
  if (unwrapped === null) return null
  return unwrapped.data
}

/**
 * Get the JSON-string parameters for a tool message, mirroring
 * ChatView's `getParametersForMessage()`. Returns `'{}'` for
 * malformed envelopes.
 */
function getParametersForMessage(msg: Message): string {
  const unwrapped = tryUnwrapToolOutput(msg.content)
  return unwrapped?.parameters ?? '{}'
}

/**
 * Try to identify which tool output component should render a given
 * tool message. Returns `{ component: toolName, toolCallId: ... }`
 * for the first match in the dispatch chain, or `null` if no known
 * component handles this tool. Chain mirrors ChatView.vue:2124-2232.
 */
function isLastAssistant(idx: number): boolean {
  // True if this is the last assistant message in the array AND no
  // message after it has a finish_reason we recognise. Used to add
  // the streaming-cursor class on the most-recent in-progress bubble.
  for (let i = props.messages.length - 1; i >= 0; i--) {
    if (props.messages[i]!.role === 'assistant') {
      return i === idx
    }
  }
  return false
}

// ── Auto-scroll to the bottom on new content ──────────────────────────

const scrollRef = ref<HTMLElement | null>(null)

watch(
  () => props.messages.map((m) => m.content?.length ?? 0).join(','),
  async () => {
    await nextTick()
    if (scrollRef.value) {
      scrollRef.value.scrollTop = scrollRef.value.scrollHeight
    }
  },
)
</script>

<template>
  <Teleport to="body">
    <div
      class="peek-overlay"
      data-testid="peek-panel"
      role="dialog"
      aria-label="Sub-agent progress"
      @keydown.esc="emit('close')"
    >
      <!-- Backdrop — click to close -->
      <div class="peek-backdrop" @click="emit('close')"></div>

      <!-- Panel -->
      <div class="peek-panel">
        <!-- Header -->
        <header class="peek-header">
          <div class="peek-header-left">
            <div class="peek-header-label-line">
              <span class="peek-kind">Sub-agent</span>
              <span class="peek-agent-name" :title="agentName">{{ agentName }}</span>
              <span
                class="peek-status"
                :class="statusClass"
                data-testid="peek-status"
              >
                <span v-if="status === 'streaming'" class="peek-status-dot"></span>
                {{ statusLabel }}
              </span>
            </div>
            <p
              class="peek-instruction"
              data-testid="peek-instruction"
              :title="instruction"
            >
              {{ instructionPreview }}
            </p>
          </div>
          <button
            class="peek-open-full"
            data-testid="peek-open-full"
            :title="`Open ${sessionId} in main chat view`"
            @click="emit('openFull', sessionId)"
          >
            Open full
          </button>
          <button
            class="peek-close"
            data-testid="peek-close"
            title="Close (ESC)"
            @click="emit('close')"
          >
            ✕
          </button>
        </header>

        <!-- Error banner -->
        <div
          v-if="status === 'error' && errorMessage"
          class="peek-error-banner"
          data-testid="peek-error-banner"
        >
          <span class="peek-error-message">{{ errorMessage }}</span>
          <button
            class="peek-error-retry"
            data-testid="peek-error-retry"
            @click="emit('reload')"
          >
            Retry
          </button>
        </div>

        <!-- Empty state -->
        <div
          v-if="messages.length === 0 && status !== 'loading' && status !== 'error'"
          class="peek-empty"
        >
          <em>No messages yet.</em>
        </div>

        <!-- Message list -->
        <div
          ref="scrollRef"
          class="peek-messages"
          data-testid="peek-messages-scroll"
        >
          <template v-for="(msg, idx) in messages" :key="msg.id ?? `${idx}`">
            <!-- ── User message ── -->
            <div
              v-if="msg.role === 'user'"
              class="peek-msg peek-msg-user"
              data-testid="peek-msg-user"
            >
              <div class="peek-msg-label">user</div>
              <pre class="peek-msg-content">{{ msg.content }}</pre>
            </div>

            <!-- ── Assistant message ── -->
            <div
              v-else-if="msg.role === 'assistant'"
              class="peek-msg peek-msg-assistant"
              :class="{
                streaming: status === 'streaming' && isLastAssistant(idx),
              }"
              data-testid="peek-msg-assistant"
            >
              <div class="peek-msg-label">assistant</div>
              <pre class="peek-msg-content">{{ msg.content }}</pre>
            </div>

            <!-- ── Tool message — dispatch to existing components ── -->
            <div
              v-else-if="msg.role === 'tool'"
              class="peek-msg peek-msg-tool"
              data-testid="peek-msg-tool"
              :data-tool-name="msg.tool_name"
            >
              <ReadFile
                v-if="msg.tool_name === 'read_file'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <WriteFile
                v-else-if="msg.tool_name === 'write_file'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <UpdateActivity
                v-else-if="msg.tool_name === 'update_activity'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <Search
                v-else-if="msg.tool_name === 'search'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <Glob
                v-else-if="msg.tool_name === 'glob'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <TextReplace
                v-else-if="msg.tool_name === 'text_replace'"
                :content="innerToolData(msg) ?? msg.content"
                :diffview-before="msg.diffview_before"
                :diffview-after="msg.diffview_after"
              />
              <ShellTool
                v-else-if="msg.tool_name === 'bash' || msg.tool_name === 'pwsh' || msg.tool_name === 'run_command'"
                :tool-name="msg.tool_name === 'pwsh' ? 'pwsh' : 'bash'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <GetSkill
                v-else-if="msg.tool_name === 'get_skill'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <ViewSkill
                v-else-if="msg.tool_name === 'view_skill'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <ListSkills
                v-else-if="msg.tool_name === 'list_skills'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <AddSkill
                v-else-if="msg.tool_name === 'add_skill'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <EditSkill
                v-else-if="msg.tool_name === 'edit_skill'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <RemoveSkill
                v-else-if="msg.tool_name === 'remove_skill'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <RemoveFile
                v-else-if="msg.tool_name === 'remove_file'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <SpawnSubAgent
                v-else-if="msg.tool_name === 'spawn_sub_agent'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <NalarBrowser
                v-else-if="msg.tool_name === 'nalar_browser'"
                :content="innerToolData(msg) ?? msg.content"
                :parameters="getParametersForMessage(msg)"
              />
              <SetGitWorktree
                v-else-if="msg.tool_name === 'set_git_worktree'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <ReadCompactedMessages
                v-else-if="msg.tool_name === 'read_compacted_messages'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <KanbanMove
                v-else-if="msg.tool_name === 'kanban_move_task'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <KanbanList
                v-else-if="msg.tool_name === 'kanban_list'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <SaveMemory
                v-else-if="msg.tool_name === 'save_memory'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <LoadMemory
                v-else-if="msg.tool_name === 'load_memory'"
                :content="innerToolData(msg) ?? msg.content"
              />
              <!-- Fallback: unknown tool name — generic <pre> bubble. -->
              <div v-else class="peek-tool-fallback">
                <div class="peek-msg-label">
                  {{ msg.tool_name ?? 'tool' }}
                </div>
                <pre class="peek-msg-content">{{ msg.content }}</pre>
              </div>
            </div>
          </template>
        </div>

        <!-- Footer -->
        <footer class="peek-footer">
          <span class="peek-footer-session" :title="sessionId">
            session: {{ sessionId }}
          </span>
          <span v-if="(totalTokens ?? 0) > 0" class="peek-footer-tokens">
            {{ (totalTokens ?? 0).toLocaleString() }} tokens
          </span>
        </footer>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
/* The panel uses CSS vars from the app's theme — no hardcoded
 * colors beyond a few translucent tints for the pulse animation.
 * Positioning: fixed inset-0 + flex justify-end so the panel slides
 * in from the right; backdrop click closes (matches the close ✕ and
 * ESC).
 */
.peek-overlay {
  position: fixed;
  inset: 0;
  z-index: 50;
  display: flex;
  justify-content: flex-end;
}
.peek-backdrop {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.5);
}
.peek-panel {
  position: relative;
  width: 460px;
  max-width: 90%;
  height: 100%;
  background: var(--semantic-card-bg);
  border-left: 1px solid var(--color-border);
  box-shadow: -10px 0 30px rgba(0, 0, 0, 0.5);
  display: flex;
  flex-direction: column;
  font-size: 12px;
}

.peek-header {
  padding: 12px 16px;
  border-bottom: 1px solid var(--color-border);
  display: flex;
  align-items: center;
  gap: 8px;
}
.peek-header-left { flex: 1; min-width: 0; }
.peek-header-label-line {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
}
.peek-kind {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--semantic-text-muted);
  font-weight: 600;
}
.peek-agent-name {
  font-weight: 600;
  color: var(--semantic-text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 180px;
}
.peek-status {
  font-size: 11px;
  white-space: nowrap;
  display: inline-flex;
  align-items: center;
  gap: 4px;
}
.peek-status-streaming { color: var(--color-violet); }
.peek-status-complete  { color: var(--color-green); }
.peek-status-error     { color: var(--color-red); }
.peek-status-idle      { color: var(--semantic-text-muted); }
.peek-status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--color-violet);
  animation: peek-pulse 1.5s ease-in-out infinite;
}
@keyframes peek-pulse {
  0%, 100% { opacity: 1; transform: scale(1); }
  50%      { opacity: 0.5; transform: scale(1.4); }
}
.peek-instruction {
  font-size: 11px;
  color: var(--semantic-text-muted);
  margin-top: 2px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  margin: 0;
}
.peek-open-full {
  font-size: 11px;
  padding: 4px 8px;
  border-radius: 4px;
  background: var(--semantic-content-bg);
  border: 1px solid var(--color-border);
  color: var(--semantic-text);
  cursor: pointer;
  white-space: nowrap;
}
.peek-open-full:hover {
  background: rgba(139, 92, 246, 0.1);
  border-color: var(--color-violet);
}
.peek-close {
  width: 28px;
  height: 28px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 4px;
  color: var(--semantic-text-muted);
  cursor: pointer;
  border: 1px solid transparent;
  background: transparent;
  font-size: 14px;
}
.peek-close:hover {
  color: var(--semantic-text);
  border-color: var(--color-border);
}

.peek-error-banner {
  padding: 8px 12px;
  background: rgba(239, 68, 68, 0.1);
  border-bottom: 1px solid rgba(239, 68, 68, 0.3);
  color: var(--color-red);
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 11px;
}
.peek-error-message { flex: 1; overflow: hidden; text-overflow: ellipsis; }
.peek-error-retry {
  font-size: 10px;
  padding: 2px 6px;
  border-radius: 3px;
  border: 1px solid rgba(239, 68, 68, 0.3);
  background: transparent;
  color: var(--color-red);
  cursor: pointer;
}
.peek-error-retry:hover { background: rgba(239, 68, 68, 0.1); }

.peek-empty {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--semantic-text-muted);
  font-size: 12px;
}

.peek-messages {
  flex: 1;
  overflow-y: auto;
  padding: 12px 16px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.peek-msg {
  border-radius: 6px;
  padding: 8px 10px;
  font-size: 11px;
  line-height: 1.5;
}
.peek-msg-label {
  font-size: 9px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  font-weight: 600;
  margin-bottom: 4px;
  opacity: 0.7;
}
.peek-msg-content {
  white-space: pre-wrap;
  font-family: -apple-system, BlinkMacSystemFont, sans-serif;
  word-break: break-word;
  margin: 0;
}

.peek-msg-user {
  background: var(--semantic-content-bg);
  border: 1px solid var(--color-border);
}
.peek-msg-user .peek-msg-label { color: var(--semantic-text-muted); }

.peek-msg-assistant {
  background: rgba(139, 92, 246, 0.05);
  border: 1px solid rgba(139, 92, 246, 0.2);
}
.peek-msg-assistant .peek-msg-label { color: var(--color-violet); }
.peek-msg-assistant.streaming .peek-msg-content::after {
  content: '▍';
  color: var(--color-violet);
  margin-left: 2px;
  animation: peek-blink 1s steps(2, start) infinite;
}
@keyframes peek-blink {
  to { opacity: 0; }
}

.peek-msg-tool {
  /* The tool output components bring their own styling — leave
   * the wrapper minimal.
   */
}
.peek-tool-fallback {
  background: rgba(63, 63, 70, 0.3);
  border: 1px solid var(--color-border);
  border-radius: 6px;
  padding: 8px 10px;
  font-size: 11px;
}
.peek-tool-fallback .peek-msg-label { color: var(--semantic-text-dim); }
.peek-tool-fallback .peek-msg-content {
  font-family: ui-monospace, monospace;
  font-size: 10px;
}

.peek-footer {
  padding: 8px 16px;
  border-top: 1px solid var(--color-border);
  font-size: 11px;
  color: var(--semantic-text-muted);
  display: flex;
  align-items: center;
  gap: 12px;
}
.peek-footer-session {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  flex: 1;
  min-width: 0;
}
.peek-footer-tokens {
  margin-left: auto;
  color: var(--color-violet);
  white-space: nowrap;
}
</style>
