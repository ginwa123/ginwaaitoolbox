<script setup lang="ts">
import { ref, watch, onMounted, onUnmounted, nextTick, computed, inject, type Ref } from 'vue'
import { marked } from 'marked'
import * as api from '../api'
import { getThinkingTags, isThinkingTags, stripThinkingTags, VirtualScroller } from '@/helpers'
import {
  buildScrollContext,
  createScrollLogger,
  isAutoStickActive,
  AUTO_STICK_GATE_MS,
  BOTTOM_THRESHOLD,
  TOP_THRESHOLD,
  type ScrollLogger,
} from '@/helpers'
import FileInput from './FileInput.vue'
import SseStatusBadge from './SseStatusBadge.vue'
import FolderExplorer from './FolderExplorer.vue'
import { tryUnwrapToolOutput, type UnwrappedToolOutput } from '@/helpers/unwrapToolOutput'
import DiffView from './tool_outputs/DiffView.vue'
import ReadFile from './tool_outputs/ReadFile.vue'
import WriteFile from './tool_outputs/WriteFile.vue'
import UpdateActivity from './UpdateActivity.vue'
import Search from './tool_outputs/Search.vue'
import Glob from './Glob.vue'
import TextReplace from './tool_outputs/TextReplace.vue'
import Bash from './Bash.vue'
import GetSkill from './GetSkill.vue'
import ViewSkill from './tool_outputs/ViewSkill.vue'
import ListSkills from './tool_outputs/ListSkills.vue'
import AddSkill from './tool_outputs/AddSkill.vue'
import EditSkill from './tool_outputs/EditSkill.vue'
import RemoveSkill from './tool_outputs/RemoveSkill.vue'
import RemoveFile from './tool_outputs/RemoveFile.vue'
import SpawnSubAgent from './tool_outputs/SpawnSubAgent.vue'
import NalarBrowser from './tool_outputs/NalarBrowser.vue'
import SetGitWorktree from './tool_outputs/SetGitWorktree.vue'
import ReadCompactedMessages from './tool_outputs/ReadCompactedMessages.vue'
import KanbanMove from './tool_outputs/KanbanMove.vue'
import KanbanList from './tool_outputs/KanbanList.vue'
import CompactionCard from './CompactionCard.vue'
import SkillsPopup from './SkillsPopup.vue'
import ImagePreview from './ImagePreview.vue'
import WorktreeMenu from './WorktreeMenu.vue'
import CreatePrDialog from './CreatePrDialog.vue'
import CreateWorktreeDialog from './CreateWorktreeDialog.vue'
import { parseSpawnSubAgentArgs } from '../helpers/parseSpawnSubAgentArgs'
import type { SubAgentArgs } from '../helpers/parseSpawnSubAgentArgs'

const props = defineProps<{
  chatId: string
  chatName: string
  type?: 'chat' | 'task'
  cwd?: string
  /**
   * When true, render the compact header bar (chat name + ✕ close
   * button) above the messages. The host (AppLayout) sets this to
   * true in the 3-column layout (sidebar | kanban | chatview) so
   * the user can identify + close the chat without leaving the
   * kanban. In the full-width standalone chat layout (the
   * `/app?view=chat` route) the prop is left false, preserving the
   * original "no header" experience where the chat fills the
   * viewport edge-to-edge.
   *
   * Defaults to `false` so older call sites that don't supply it
   * still compile — see the nalar-frontend-task-literal-typing-rule
   * memory for the broader pattern.
   */
  showHeader?: boolean
}>()

const emit = defineEmits<{
  'update-chat-id': [oldId: string, newId: string]
  /**
   * Emitted when the user clicks the ✕ close button in the chat
   * header. The host (AppLayout) handles this by clearing the
   * active task and (optionally) navigating back to the kanban /
   * workspace view. The ChatView itself does NOT call router
   * directly — it just announces "user wants me gone" — so the
   * layout composition (e.g. sidebar | kanban | chatview) stays
   * the host's concern.
   */
  close: []
}>()

// Check if session is pending (needs creation on first message)
const isPendingSession = computed(() => props.chatId.startsWith('pending-'))

interface Message {
  id: string
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  timestamp: Date
  tool_name?: string
  diffview_before?: string
  diffview_after?: string
  image_urls?: string[]
  tool_calls_json?: string
  finish_reason?: string
  tool_call_id?: string
}

// Escape HTML to prevent XSS
const escapeHtml = (text: string): string => {
  const div = document.createElement('div')
  div.textContent = text
  return div.innerHTML
}

// Copy code content to clipboard
const copyCodeContent = async (codeContent: string) => {
  try {
    await navigator.clipboard.writeText(codeContent)
  } catch (err) {
    console.error('Failed to copy code:', err)
  }
}

// Setup copy buttons on code blocks after render
const setupCodeBlockCopyButtons = () => {
  nextTick(() => {
    const container = virtualScrollerRef.value?.containerRef.value
    if (!container) return
    const codeBlocks = container.querySelectorAll('.markdown-content pre')
    codeBlocks.forEach((block) => {
      if (block.querySelector('.code-copy-btn')) return
      const code = block.querySelector('code')
      if (!code) return
      const content = code.textContent || ''
      const btn = document.createElement('button')
      btn.className = 'code-copy-btn'
      btn.innerHTML = '📋'
      btn.title = 'Copy code'
      btn.style.cssText =
        'position: absolute; top: 8px; right: 8px; padding: 4px 8px; font-size: 12px; cursor: pointer; border: none; background: rgba(255,255,255,0.1); border-radius: 4px; opacity: 0.7; transition: opacity 0.2s;'
      btn.onmouseover = () => (btn.style.opacity = '1')
      btn.onmouseout = () => (btn.style.opacity = '0.7')
      btn.onclick = (e) => {
        e.stopPropagation()
        copyCodeContent(content)
      }
      ;(block as HTMLElement).style.position = 'relative'
      block.appendChild(btn)
    })
  })
}

// Render markdown content to HTML
const renderResponse = (
  content: string,
  role: string,
  tool_name: string | undefined,
  diffviewBefore?: string,
  diffviewAfter?: string,
  finish_reason?: string,
  tool_calls_json?: string,
): string => {
  content = content.trim()
  if (!content) return ''
  try {
    if (role === 'assistant') {
      if (isThinkingTags(content)) {
        return getThinkingTags(content)
      }
      const cleanContent = stripThinkingTags(content)
      return marked.parse(cleanContent, { async: false }) as string
    }

    if (role === 'tool') {
      if (tool_name === 'read_file') {
        const mathPath = content.match(/<path>(.*?)<\/path>/)
        const path = mathPath ? mathPath[1] : null
        const errorArr = content.match(/<error>(.*?)<\/error>/)
        if (errorArr) {
          const errorQuery = errorArr[0]
          return `<span class="tool-inline">${tool_name} → ${path} ${errorQuery}</span>`
        }
        return `<span class="tool-inline">${tool_name} → ${path}</span>`
      }

      if (tool_name === 'search') {
        const fileMatch = content.match(/<file path="([^"]+)" total="(\d+)" count="(\d+)">/)
        if (fileMatch) {
          const matchCount = fileMatch[3]
          return `<span class="tool-inline">search → ${matchCount} matches</span>`
        }
        const warningMatch = content.match(/<warning>(.*?)<\/warning>/)
        if (warningMatch) {
          return `<span class="tool-inline">search → ${warningMatch[1]}</span>`
        }
        const errorMatch = content.match(/<error>(.*?)<\/error>/)
        return `<span class="tool-inline">search → ${errorMatch?.[1] || 'unknown'}</span>`
      }

      if (tool_name === 'glob') {
        const patternMatch = content.match(/pattern="([^"]+)"/)
        const totalMatch = content.match(/total="(\d+)"/)
        const returnedMatch = content.match(/returned="(\d+)"/)
        const warningMatch = content.match(/<warning>(.*?)<\/warning>/)
        if (warningMatch) {
          return `<span class="tool-inline">glob → ${warningMatch[1]}</span>`
        }
        const pattern = patternMatch ? patternMatch[1] : 'unknown'
        const total = totalMatch ? totalMatch[1] : '0'
        const returned = returnedMatch ? returnedMatch[1] : total
        const resultsText = total !== '0' ? ` (${returned} files)` : ''
        return `<span class="tool-inline">glob → "${pattern}"${resultsText}</span>`
      }

      if (tool_name === 'web_search') {
        const mathQuery = content.match(/<query>(.*?)<\/query>/) || content.match(/"(.*?)"/)
        const query = mathQuery ? mathQuery[1] : null
        return `<span class="tool-inline">${tool_name} → "${query || 'unknown'}"</span>`
      }

      if (tool_name === 'mcp_context7_query-docs' || tool_name === 'context7') {
        const mathQuery = content.match(/<query>(.*?)<\/query>/)
        const query = mathQuery ? mathQuery[1] : null
        return `<span class="tool-inline">${tool_name} → "${query || 'unknown'}"</span>`
      }

      if (
        tool_name === 'list_skills' ||
        tool_name === 'get_skill' ||
        tool_name === 'add_skill' ||
        tool_name === 'edit_skill' ||
        tool_name === 'view_skill'
      ) {
        return `<span class="tool-inline">${tool_name}</span>`
      }

      if (tool_name === 'set_git_worktree') {
        // SET success: <created>true</created><path>...</path>
        const pathMatch = content.match(/<path>([\s\S]*?)<\/path>/)
        if (pathMatch) {
          return `<span class="tool-inline">${tool_name} → ${escapeHtml(pathMatch[1]?.trim() || '')}</span>`
        }
        // CLEAR success: <cleared>true</cleared>
        if (/<cleared>\s*true\s*<\/cleared>/.test(content)) {
          return `<span class="tool-inline">${tool_name} → cleared</span>`
        }
        // Error: <created>false</created><error>...</error>
        const errMatch = content.match(/<error>([\s\S]*?)<\/error>/)
        return `<span class="tool-inline">${tool_name} → ${escapeHtml(errMatch?.[1]?.trim() || 'error')}</span>`
      }

      if (tool_name === 'read_compacted_messages') {
        // Collapsed-bubble summary for the inline tool pill in ChatView.
        // Mirrors the structured ReadCompactedMessages.vue card so users
        // see the same info (mode + count + session) whether they look
        // at the collapsed bubble or the expanded body.
        const errorMatch = content.match(/<error>([\s\S]*?)<\/error>/)
        if (errorMatch) {
          return `<span class="tool-inline">${tool_name} → ${escapeHtml(errorMatch[1]?.trim() || 'error')}</span>`
        }
        const modeMatch = content.match(/<read_compacted_messages\s+mode="([^"]+)"/)
        const countMatch = content.match(/<count>(\d+)<\/count>/)
        const sessionMatch = content.match(/<session_id>([\s\S]*?)<\/session_id>/)
        const mode = modeMatch?.[1] ?? 'index'
        const count = countMatch?.[1] ?? '?'
        const session = sessionMatch?.[1]?.trim() ?? ''
        return `<span class="tool-inline">${tool_name} → ${escapeHtml(mode)} mode · ${count} ${count === '1' ? 'message' : 'messages'}${session ? ' · ' + escapeHtml(session) : ''}</span>`
      }

      if (tool_name === 'nalar_browser') {
        // Use the same action-aware summariser the standalone component uses,
        // so the collapsed preview ("nalar_browser · open_page · Example Domain")
        // matches what the user will see in the expanded body.
        const nalarUnwrapped = tryUnwrapToolOutput(content)
        if (nalarUnwrapped === null) {
          return `<span class="tool-inline">${tool_name} → ${escapeHtml(content)}</span>`
        }
        const a = nalarUnwrapped.parameters
        let action = 'unknown'
        try {
          const parsed = JSON.parse(a)
          if (parsed && typeof parsed === 'object' && typeof parsed.action === 'string') {
            action = parsed.action
          }
        } catch {
          /* fall through */
        }
        const label = (() => {
          if (nalarUnwrapped.error) return nalarUnwrapped.error
          switch (action) {
            case 'launch':
              return nalarUnwrapped.data?.match(/<browser_id>([\s\S]*?)<\/browser_id>/)?.[1] ?? action
            case 'open_page':
              return (
                nalarUnwrapped.data?.match(/<title>([\s\S]*?)<\/title>/)?.[1] ??
                nalarUnwrapped.data?.match(/<url>([\s\S]*?)<\/url>/)?.[1] ??
                action
              )
            case 'snapshot':
              return (
                (() => {
                  const tree = nalarUnwrapped.data?.match(/<tree>([\s\S]*?)<\/tree>/)?.[1]
                  if (!tree) return action
                  try {
                    const arr = JSON.parse(tree)
                    return Array.isArray(arr)
                      ? `snapshot · ${arr.length} element${arr.length !== 1 ? 's' : ''}`
                      : action
                  } catch {
                    return action
                  }
                })()
              )
            case 'click':
            case 'fill':
            case 'press':
            case 'close_page':
            case 'close_browser':
              return action
            default:
              return action
          }
        })()
        return `<span class="tool-inline">${tool_name} · ${escapeHtml(action)} · ${escapeHtml(label)}</span>`
      }
      if (tool_name === 'spawn_sub_agent') {
        const agentMatches = content.match(/<agent name="([^"]*)" success="([^"]*)">/g)
        const agentCount = agentMatches ? agentMatches.length : 0
        const summaryMatch = content.match(/<summary succeeded="(\d+)" failed="(\d+)" \/>/)
        const succeeded = summaryMatch ? summaryMatch[1] : '0'
        const failed = summaryMatch ? summaryMatch[2] : '0'
        return `<span class="tool-inline">${tool_name} → ${agentCount} agents (${succeeded} succeeded, ${failed} failed)</span>`
      }

      // Fallback: render a concise summary from the <tool> envelope.
      // If the content doesn't match the envelope (legacy), fall back to
      // the raw text (existing behavior).
      const unwrapped = tryUnwrapToolOutput(content)
      if (unwrapped === null) {
        return `<span class="tool-inline">${tool_name || 'tool'} → ${escapeHtml(content)}</span>`
      }
      const statusIcon = unwrapped.success ? '✓' : '✗'
      const statusClass = unwrapped.success ? 'tool-inline-success' : 'tool-inline-error'
      const preview = unwrapped.success
        ? unwrapped.data?.slice(0, 80) ?? ''
        : unwrapped.error ?? 'unknown error'
      return `<span class="tool-inline">${tool_name || unwrapped.name} → <span class="${statusClass}">${statusIcon}</span> ${escapeHtml(preview)}${preview.length >= 80 ? '…' : ''}</span>`
    }

    return escapeHtml(content)
  } catch {
    return escapeHtml(content)
  }
}

// Detect a compaction summary message — a user-role message whose
// content is the `<compact_messages>` envelope written by
// `compactMessageInMemoryNew` (workflow.zig). Used by the user bubble
// to render the envelope as a structured `CompactionCard` instead of
// a wall of escaped XML.
//
// Detection is content-prefix based (rather than a dedicated DB field)
// because the existing API doesn't carry a `is_compaction` flag. A user
// who literally types "<compact_messages>" into chat would also match,
// but that's vanishingly unlikely; the compactor writes this exact
// prefix and no other message does.
const isCompactionMessage = (msg: { role: string; content: string } | undefined): boolean => {
  if (!msg) return false
  if (msg.role !== 'user') return false
  return msg.content.trimStart().startsWith('<compact_messages>')
}

// Session ID extracted from props on mount
const sessionId = ref('')

// Inject processingState from App.vue (driven by SSE - always up-to-date)
const processingState = inject<Ref<Record<string, boolean>>>('processingState', ref({}))

// LLM processing state - derived reactively from App.vue's processingState
const isLLMProcessing = computed(() => !!processingState.value[sessionId.value])

// Pagination state
const messageCursor = ref<string | null>(null)
const PAGE_SIZE = 1000

// SSE connection. Both streams are now `api.SseClient` (the
// shared auto-reconnecting wrapper) instead of raw `EventSource`.
// The previous versions had NO reconnect logic — a single network
// blip during a long chat would kill the stream silently until
// the user reloaded. The new behaviour: exponential backoff
// (1s → 30s), visibility-aware pause, and `online` fast-path
// — all in `helpers/sseClient.ts`.
const eventSource = ref<api.SseClient | null>(null)
const queueEventSource = ref<api.SseClient | null>(null)
const isStreaming = ref(false)
const streamingContent = ref('')

// Queue state
const queuedMessages = ref<api.QueuedMessage[]>([])

// Scroll refs
// We declare an explicit interface for the VirtualScroller instance because
// `InstanceType<typeof VirtualScroller>` doesn't resolve cleanly for a generic
// Vue SFC component (the compiler infers a function signature that doesn't
// satisfy Vue's component-ref constructor constraint).
interface VirtualScrollerExposed {
  scrollToIndex: (index: number, behavior?: ScrollBehavior) => void
  scrollToTop: (behavior?: ScrollBehavior) => void
  scrollToBottom: (behavior?: ScrollBehavior) => void
  scrollToItem: (index: number, behavior?: ScrollBehavior) => void
  beginPreserve: (newItemsCount: number) => void
  endPreserve: () => Promise<void>
  preserveScrollPosition: () => Promise<void>
  containerRef: { value: HTMLElement | null }
  isPreservingScroll: { value: boolean }
  effectiveLoadMoreThreshold: { value: number }
}
const virtualScrollerRef = ref<VirtualScrollerExposed | null>(null)

// Ref to the outer flex wrapper around the VirtualScroller. The logger
// reads this so it can report "did the layout chain reach the
// scroller's parent?" — without it, a 0×0 VirtualScroller could mean
// either "the wrapper isn't sized" (layout bug higher up) or "the
// wrapper is sized but the scroller isn't" (the `flex flex-col` bug
// the recent fix addressed). The two cases need different fixes; the
// logger needs the wrapper's dimensions to tell them apart.
const messagesWrapperRef = ref<HTMLElement | null>(null)

// Timestamp (ms since epoch) of the most recent auto-stick assignment.
// Set at every site that programmatically writes `container.scrollTop`
// to keep the chat pinned to the bottom — the SSE chunk handler, the
// messages-length watcher, the SSE `full` event handler, and
// `onSpacersResized`. `handleLoadMore` consults this (via
// `isAutoStickActive`) to decide whether a prepend right now would
// fight an active stick. See `helpers/autoStickGate.ts` for the
// gating math.
//
// Starts at 0, which the gate treats as "never fired" — so the very
// first `loadMore` after mount isn't blocked.
const lastAutoStickAt = ref(0)

// MutationObserver that watches the VirtualScroller's spacer elements
// (the top/bottom spacer divs whose `style.height` is driven by
// `visibleRange.topSpacer` / `visibleRange.bottomSpacer`). Whenever
// spacers resize — which happens asynchronously after VirtualScroller
// measures real item heights (~50-100ms after mount, and again whenever
// new items scroll into view) — we re-stick to the bottom IF the user
// was at the bottom. This is "stick-to-bottom" behavior and naturally
// handles both the initial-load measurement drift and the chain-reaction
// where measuring one batch of items reveals more items that get measured
// too. Once the user scrolls up, isAtBottom flips to false and we stop
// fighting them.
let spacerRafId: number | null = null
let lastObservedScrollHeight = 0
let spacerObserver: MutationObserver | null = null

const onSpacersResized = () => {
  spacerRafId = null
  const container = virtualScrollerRef.value?.containerRef.value
  if (!container) return
  const newScrollHeight = container.scrollHeight
  // Only re-stick if the scrollHeight actually changed (a measurement
  // update). Style mutations from other causes (none in current
  // VirtualScroller, but defensive) won't trigger a re-scroll.
  if (newScrollHeight === lastObservedScrollHeight) return
  const delta = newScrollHeight - lastObservedScrollHeight
  lastObservedScrollHeight = newScrollHeight
  // Build a context with the *pre-stick* geometry (scrollTop before
  // we touch it), so the log answers "what was the world like when
  // this re-stick fired?".
  const ctx = buildScrollContext(container, {
    chatId: sessionId.value || props.chatId,
    messages: messages.value.length,
    isAtBottom: isAtBottom.value,
    virtualScrollerRef,
    wrapperRef: messagesWrapperRef,
  })
  if (!isAtBottom.value) {
    scrollLogger.debug({
      ...ctx,
      caller: 'onSpacersResized',
      origin: 'programmatic',
      extra: { delta, lastObservedScrollHeight: newScrollHeight, skipped: 'user-scrolled-up' },
    })
    scrollLogger.info({
      ...ctx,
      caller: 'onSpacersResized',
      reason: 'spacer-resize-skip',
      extra: { delta, lastObservedScrollHeight: newScrollHeight },
    })
    return
  }
  // We are going to assign scrollTop. Mark the next scroll event as
  // programmatic BEFORE the assignment so the browser-fired scroll
  // reads origin='programmatic' in handleVirtualScroll. This is the
  // critical bit: without it, a stick-to-bottom action looks identical
  // to a user scroll in the logs.
  scrollLogger.markProgrammatic()
  // Record the auto-stick timestamp so the loadMore gate knows the
  // stick is actively engaged right now (not just that the LLM is
  // busy — those are different things, see autoStickGate.ts).
  lastAutoStickAt.value = Date.now()
  // Native clamp: `scrollTop = scrollHeight` gets clamped to
  // `scrollHeight - clientHeight` by the browser, so we always land at
  // the true bottom even if VirtualScroller's cached `containerHeight`
  // ref is stale.
  container.scrollTop = container.scrollHeight
  scrollLogger.info({
    ...ctx,
    caller: 'onSpacersResized',
    reason: 'spacer-resize-stick',
    extra: { delta, lastObservedScrollHeight: newScrollHeight },
  })
}

const setupSpacerObserver = () => {
  const container = virtualScrollerRef.value?.containerRef.value
  if (!container) return
  lastObservedScrollHeight = container.scrollHeight
  spacerObserver = new MutationObserver(() => {
    if (spacerRafId !== null) cancelAnimationFrame(spacerRafId)
    spacerRafId = requestAnimationFrame(onSpacersResized)
  })
  // Observe the container's direct children only (the two spacers and
  // the content wrapper). `subtree: false` keeps us from observing every
  // message bubble's internal style changes, which would be very chatty.
  // `attributeFilter: ['style']` is the only thing that actually fires
  // for spacer resize — childList/characterData don't happen for spacers.
  spacerObserver.observe(container, {
    attributes: true,
    attributeFilter: ['style'],
  })
}

const teardownSpacerObserver = () => {
  if (spacerRafId !== null) {
    cancelAnimationFrame(spacerRafId)
    spacerRafId = null
  }
  spacerObserver?.disconnect()
  spacerObserver = null
}

// State
const messages = ref<Message[]>([])
const isLoading = ref(false)
const isLoadingMore = ref(false)
const error = ref<string | null>(null)
const hasMoreMessages = ref(true)
const isAtBottom = ref(true)
// Whether the VirtualScroller's container is currently scrollable
// (`scrollHeight > clientHeight`). When the container IS scrollable,
// the user can scroll to the top to trigger loadMore via the
// VirtualScroller's `@load-more` event — so the "Load more messages"
// button hides and avoids UI clutter. When the container is NOT
// scrollable (the common short-chat case in the screenshot in
// docs/plans/2026-06-04-chat-lazy-load-button.md), the user has no
// scroll-driven path, so the button is the only way to reach older
// messages.
//
// Updated by the VirtualScroller via the `@scrollability-change`
// event (not read through the template ref). The event pattern is
// used because component-instance proxies do not establish reactive
// dependencies on inner ref values when accessed through
// `childRef.value.someRef.value` — a parent `computed` reading
// that chain would not re-evaluate when the child's value changes.
// With the event, this is a plain `ref<boolean>` that the template
// can react to via standard Vue reactivity. Defaults to `false` so
// the initial-render 0×0 flicker shows the affordance; the
// VirtualScroller's watch with `immediate: true` fires the event
// synchronously during setup, overwriting this default with the
// real value before the first render.
const scrollerIsScrollable = ref(false)
const cwd = ref('')
// Bound git worktree path (empty string when no worktree is bound).
// Updated by loadChatHistory() from the API response and by the
// sessions SSE stream when the LLM calls set_git_worktree.
const gitWorktreeCwd = ref('')
// The cwd we run git status against. Prefers the worktree when set
// (so the branch display reflects the worktree's branch, not the
// session's original cwd). Falls back to the session's original cwd.
const effectiveCwd = computed(() => gitWorktreeCwd.value || cwd.value)
const maxTotalTokens = ref(0)
const maxCapacityTotalTokens = ref(200000)

// ─── Profile selection ────────────────────────────────────────────────────────
// Per-session model selection. The chip in the status bar shows the current
// selection (Default = no profile set) and lets the user pick a profile from
// the list in NalarConfig. Selected via PUT /api/llm/session/:id and passed
// to the next LLM call via POST /api/llm/session.
const availableProfiles = ref<Array<{ name: string; model: string; base_url: string }>>([])
const selectedProfile = ref<string | null>(null)
const showProfilePicker = ref(false)
const isUpdatingProfile = ref(false)
const profilePickerRef = ref<HTMLElement | null>(null)

const loadProfiles = async () => {
  try {
    const config = await api.getNalarConfig()
    const profiles = (config.profiles ?? {}) as Record<
      string,
      { model?: string; base_url?: string }
    >
    availableProfiles.value = Object.entries(profiles).map(([name, p]) => ({
      name,
      model: p.model ?? '',
      base_url: p.base_url ?? '',
    }))
  } catch (err) {
    console.error('Failed to load profiles:', err)
    availableProfiles.value = []
  }
}

const selectProfile = async (name: string | null) => {
  if (isUpdatingProfile.value) return
  isUpdatingProfile.value = true
  try {
    const sid = sessionId.value
    if (sid) {
      await api.updateSession(sid, { selectedProfile: name })
    }
    selectedProfile.value = name
  } catch (err) {
    console.error('Failed to update profile:', err)
  } finally {
    isUpdatingProfile.value = false
    showProfilePicker.value = false
  }
}

const closeOnOutsideClick = (e: MouseEvent) => {
  if (profilePickerRef.value && !profilePickerRef.value.contains(e.target as Node)) {
    showProfilePicker.value = false
  }
}

// ─── Worktree dropdown + PR dialog ────────────────────────────────────────────
// The chat status bar's git branch indicator becomes a clickable button
// when a worktree is bound (`gitWorktreeCwd` is non-empty). Clicking
// opens a small dropdown (WorktreeMenu) with three actions: Create a
// PR, View in folder, Clear worktree. Create a PR opens the
// CreatePrDialog modal; Clear worktree asks the LLM to call
// `set_git_worktree(clear=true)` (LLM-mediated so the cleanup
// re-uses the existing tool path — see plan design decision #5).
const showWorktreeMenu = ref(false)
const worktreeMenuRef = ref<HTMLElement | null>(null)
const showCreatePrDialog = ref(false)
const showCreateWorktreeDialog = ref(false)

const onWorktreeMenuCreatePr = () => {
  showCreatePrDialog.value = true
}

const onWorktreeMenuCreateWorktree = () => {
  showCreateWorktreeDialog.value = true
}

const onWorktreeMenuViewFolder = () => {
  // Open the worktree path (or session cwd if no worktree) in the
  // system file manager. Implementation: use the existing
  // /api/system/folder?path=<worktree> to confirm the directory is
  // accessible, then emit a window event that the right-sidebar file
  // explorer subscribes to. For v1, the simplest implementation is
  // to copy the path to the clipboard and show a toast — see
  // ChatsList.vue for the clipboard pattern.
  const path = gitWorktreeCwd.value || cwd.value
  navigator.clipboard.writeText(path)
  // TODO: open a folder-explorer modal in a follow-up
}

const onWorktreeMenuRefresh = () => {
  // Re-fetch git status from the backend so the chip shows the latest
  // state immediately (instead of waiting for the next poll tick).
  checkGitStatus()
}

const onWorktreeMenuClear = async () => {
  // Send a system message to the LLM asking it to clear the worktree.
  // The LLM calls set_git_worktree(clear=true), which removes the
  // directory and clears the binding. The SSE event updates the UI.
  // Uses cwd.value (the session's ORIGINAL cwd) so the LLM's context
  // matches the session it was started from.
  if (!sessionId.value) return
  try {
    await api.sendChatMessage(
      sessionId.value,
      'Please call set_git_worktree with clear=true to remove the current worktree binding.',
      cwd.value,
      [],
      selectedProfile.value ?? undefined,
    )
  } catch (err) {
    console.error('Failed to send clear-worktree message:', err)
  }
}

const onPrCreated = (url: string) => {
  showCreatePrDialog.value = false
  // Show a brief toast (use the existing notification pattern)
  // For v1, just open the PR URL in a new tab
  window.open(url, '_blank')
}

const onPrError = (message: string) => {
  console.error('PR creation failed:', message)
  // Show a toast with the error
  // For v1, just log — the dialog stays open with the form intact
}

const onCreateWorktree = async (path: string) => {
  if (!sessionId.value) return
  if (!cwd.value) {
    console.error('Create worktree: no session cwd available')
    showCreateWorktreeDialog.value = false
    return
  }
  // The dialog passes the user's absolute path verbatim. The LLM calls
  // set_git_worktree(path=<path>) which validates (must be absolute, no
  // .., basename matches [A-Za-z0-9._-]{1,100}) and runs git worktree
  // add. The branch is auto-derived as worktree/<basename(path)>.
  const message = `Please call set_git_worktree with path=${path} to create a new worktree for me.`
  try {
    await api.sendChatMessage(
      sessionId.value,
      message,
      cwd.value,
      [],
      selectedProfile.value ?? undefined,
    )
  } catch (err) {
    console.error('Failed to send create-worktree message:', err)
  }
  showCreateWorktreeDialog.value = false
}

// ─── Scroll logger ────────────────────────────────────────────────────────────
//
// A dedicated logger for the scroll subsystem. Bound to the active chat
// so every line is tagged with chatId. Recreated when sessionId changes
// so the log context is never stale. See helpers/scrollLogger.ts for
// what fields every line carries and why.
let scrollLogger: ScrollLogger = createScrollLogger(props.chatId)
const refreshScrollLogger = () => {
  scrollLogger = createScrollLogger(sessionId.value || props.chatId)
}

// Session skills state
const sessionSkills = ref<api.SkillInfo[]>([])
const showSkillsPopup = ref(false)

// Track which tool items are expanded (by index)
const expandedToolIds = ref<Set<string>>(new Set())

// Image preview state
const previewImageUrl = ref<string | null>(null)

const openImagePreview = (url: string) => {
  previewImageUrl.value = url
}

const closeImagePreview = () => {
  previewImageUrl.value = null
}

// Toggle expanded state for a tool item
const toggleToolExpanded = (groupIndex: number, msgIndex: number) => {
  const key = `${groupIndex}-${msgIndex}`
  const newSet = new Set(expandedToolIds.value)
  if (newSet.has(key)) {
    newSet.delete(key)
  } else {
    newSet.add(key)
  }
  expandedToolIds.value = newSet
}

// Git status state
const gitStatus = ref<api.GitStatus | null>(null)
let gitStatusPollInterval: ReturnType<typeof setInterval> | null = null

const checkGitStatus = async () => {
  if (!effectiveCwd.value) {
    gitStatus.value = null
    return
  }
  try {
    const status = await api.getGitStatus(effectiveCwd.value)
    gitStatus.value = status
  } catch (err) {
    console.error('Failed to check git status:', err)
    gitStatus.value = null
  }
}

const startGitStatusPoll = () => {
  checkGitStatus()
  if (gitStatusPollInterval) clearInterval(gitStatusPollInterval)
  gitStatusPollInterval = setInterval(checkGitStatus, 30000)
}

const stopGitStatusPoll = () => {
  if (gitStatusPollInterval) {
    clearInterval(gitStatusPollInterval)
    gitStatusPollInterval = null
  }
}

// Filter out empty messages for display (check stripped content)
const filteredMessages = computed(() =>
  messages.value.filter((m) => {
    // Always keep tool_calls messages even if content is only thinking tags
    if (m.finish_reason === 'tool_calls') return true
    const stripped = stripThinkingTags(m.content)
    return stripped && stripped.trim() !== ''
  }),
)

// Group consecutive messages of the same role together for cleaner display
interface MessageGroup {
  role: 'user' | 'assistant' | 'tool'
  messages: Message[]
  timestamp: Date
}

const messageGroups = computed((): MessageGroup[] => {
  const groups: MessageGroup[] = []

  for (const msg of filteredMessages.value) {
    const lastGroup = groups[groups.length - 1]

    if (lastGroup && lastGroup.role === msg.role) {
      lastGroup.messages.push(msg)
      if (msg.timestamp > lastGroup.timestamp) {
        lastGroup.timestamp = msg.timestamp
      }
    } else {
      groups.push({
        role: msg.role as 'user' | 'assistant' | 'tool',
        messages: [msg],
        timestamp: msg.timestamp,
      })
    }
  }

  return groups
})

// Per-message envelope unwrap lookup. Keyed by message id; value is the
// parsed envelope or null if the content is not a <tool> envelope (legacy
// or non-tool content). Computed once when messages change so the
// template can do a cheap O(1) lookup per tool component.
const unwrappedByMessageId = computed((): Map<string, UnwrappedToolOutput | null> => {
  const map = new Map<string, UnwrappedToolOutput | null>()
  for (const m of messages.value) {
    if (m.role !== 'tool') {
      map.set(m.id, null)
      continue
    }
    map.set(m.id, tryUnwrapToolOutput(m.content))
  }
  return map
})

// Helper used in the template: get the inner data to pass to a
// tool-specific component. Returns the original content if the
// envelope didn't parse (legacy fallback) or if there was an error
// (the error message is shown via the envelope, not via the inner
// component's own error path).
const innerToolData = (m: Message): string => {
  const unwrapped = unwrappedByMessageId.value.get(m.id)
  if (unwrapped === null || unwrapped === undefined) return m.content // legacy
  return unwrapped.data ?? m.content // error case: fall back to full content
}

// Helper used in the template: get the JSON-string tool-call arguments
// for a tool message. Falls back to '{}' for legacy messages that
// don't carry the envelope.
const getParametersForMessage = (m: Message): string => {
  return unwrappedByMessageId.value.get(m.id)?.parameters ?? '{}'
}

// ─── FIX: Compute tool call names per assistant group ─────────────────────────
// For each group index, returns the tool names string if the group is an
// assistant turn that triggered tool calls BUT the tool outputs are NOT shown.
// When tool outputs ARE shown (next group is tool), we return null.
const groupToolNames = computed((): (string | null)[] => {
  return messageGroups.value.map((group, i) => {
    if (group.role !== 'assistant') return null

    // If next group is a tool group, tool outputs ARE shown → don't show header
    const nextGroup = messageGroups.value[i + 1]
    if (nextGroup?.role === 'tool') {
      return null
    }

    // No next tool group — check if this assistant message triggered tools
    // Fallback: parse tool_calls_json from any message in this group
    for (const msg of group.messages) {
      if (msg.tool_calls_json?.trim()) {
        try {
          const parsed = JSON.parse(msg.tool_calls_json)
          // tool_calls_json IS the array directly: [{id, type, function: {name}}]
          if (Array.isArray(parsed) && parsed.length > 0) {
            return parsed.map((tc: any) => tc.function?.name || tc.name || 'unknown').join(', ')
          }
        } catch {}
      }

      // finish_reason set but tool_calls_json missing/unparseable
      if (msg.finish_reason === 'tool_calls') {
        return '...'
      }
    }

    return null
  })
})

// ─── Inherited Context: thread sub_agents args from assistant message to tool
// result. The tool result message carries a tool_call_id; we walk backwards
// through messageGroups to find the assistant message whose tool_calls_json
// contains a call with that id, then extract the sub_agents array via
// parseSpawnSubAgentArgs. Returns null when no match is found, which the
// SpawnSubAgent component treats as "no inherited_context badge".
function findSubAgentArgsForToolGroup(
  toolCallId: string | undefined,
  groups: MessageGroup[],
  currentGroupIndex: number,
): SubAgentArgs[] | null {
  if (!toolCallId) return null
  // Walk backwards from the current group
  for (let i = currentGroupIndex - 1; i >= 0; i--) {
    const g = groups[i]
    if (!g) continue
    if (g.role !== 'assistant') continue
    for (const msg of g.messages) {
      if (!msg.tool_calls_json) continue
      const args = parseSpawnSubAgentArgs(msg.tool_calls_json, toolCallId)
      if (args) return args
    }
  }
  return null
}

// ─── Bubble Visibility ────────────────────────────────────────────────────────
// Check if a message has visible text content (i.e. content that survives
// stripThinkingTags and is non-empty after trim). An assistant message saved
// with finish_reason='tool_calls' often has raw content that is *only*
// `<thinking>...</thinking>` tags — the raw string is non-empty, but
// renderResponse() strips those tags and renders an empty string, producing
// a visible-but-empty bubble. The bubble check must match what the renderer
// actually shows, not the raw column.
const hasVisibleContent = (m: Message): boolean => {
  const stripped = stripThinkingTags(m.content || '')
  return stripped.trim().length > 0
}

// Check if a message group has any visible content for its bubble.
// Hides empty bubbles (e.g., a user message with no text and no images,
// or an assistant message with no content and no tool-call header).
const hasBubbleContent = (group: MessageGroup, groupIndex: number): boolean => {
  if (group.role === 'user') {
    const first = group.messages[0]
    const hasImages = (first?.image_urls?.length ?? 0) > 0
    return hasImages || (first ? hasVisibleContent(first) : false)
  }
  if (group.role === 'tool') {
    return group.messages.length > 0
  }
  if (group.role === 'assistant') {
    const hasToolHeader = groupToolNames.value[groupIndex] !== null
    return hasToolHeader || group.messages.some(hasVisibleContent)
  }
  return true
}

// ─── Chat History ────────────────────────────────────────────────────────────

const loadChatHistory = async (loadMore = false) => {
  if (!sessionId.value || isPendingSession.value) return

  if (loadMore) {
    isLoadingMore.value = true
  } else {
    isLoading.value = true
    messageCursor.value = null
  }
  error.value = null

  try {
    const data = await api.getChatHistory(
      sessionId.value,
      PAGE_SIZE,
      messageCursor.value ?? undefined,
    )

    if (!loadMore && data.cwd) {
      cwd.value = data.cwd
    }

    if (!loadMore && data.git_worktree_cwd !== undefined) {
      gitWorktreeCwd.value = data.git_worktree_cwd
    }

    if (!loadMore) {
      if (data.max_total_tokens !== undefined) {
        maxTotalTokens.value = data.max_total_tokens
      }
      if (data.max_capacity_total_tokens !== undefined) {
        maxCapacityTotalTokens.value = data.max_capacity_total_tokens
      }
      sessionSkills.value = data.skills || []
    }

    const newMessages = (data.messages || []).map((msg) => ({
      id: msg.id || `msg-${msg.created_at}`,
      role: msg.role as 'user' | 'assistant' | 'system' | 'tool',
      content: msg.content,
      timestamp: new Date((msg.created_at || 0) * 1000),
      tool_name: msg.tool_name,
      diffview_before: msg.diffview_before,
      diffview_after: msg.diffview_after,
      image_urls: msg.image_url ? msg.image_url.split('|') : undefined,
      finish_reason: msg.finish_reason,
      tool_calls_json: msg.tool_calls_json,
      tool_call_id: msg.tool_call_id,
    }))

    if (loadMore) {
      // Tear down the spacer MutationObserver for the duration of the
      // preserve. The user is scrolling *up* to load older history
      // (not at the bottom), so the stick-to-bottom behavior is
      // useless here — and its onSpacersResized callback firing on
      // every spacer resize during the forceRender/measure/anchor
      // dance is what was causing the visible flicker. Detaching it
      // eliminates that work entirely for this window.
      teardownSpacerObserver()

      // Preserve scroll position when prepending new (older) messages at the top.
      // beginPreserve must be called BEFORE mutating the array so the anchor
      // element's offsetTop is captured while it's still in the DOM.
      const newCount = newMessages.length
      const containerBefore = virtualScrollerRef.value?.containerRef.value
      const beforeCtx = buildScrollContext(containerBefore, {
        chatId: sessionId.value || props.chatId,
        messages: messages.value.length,
        isAtBottom: isAtBottom.value,
        virtualScrollerRef,
        wrapperRef: messagesWrapperRef,
      })
      scrollLogger.info({
        ...beforeCtx,
        caller: 'loadChatHistory',
        reason: 'load-more-preserve-start',
        extra: { prepending: newCount },
      })
      virtualScrollerRef.value?.beginPreserve(newCount)
      messages.value = [...newMessages.slice().reverse(), ...messages.value]
      await nextTick()
      // The VirtualScroller's internal scrollTop restoration may fire
      // a scroll event. Mark it programmatic so the next
      // handleVirtualScroll knows.
      scrollLogger.markProgrammatic()
      await virtualScrollerRef.value?.endPreserve()
      const containerAfter = virtualScrollerRef.value?.containerRef.value
      const afterCtx = buildScrollContext(containerAfter, {
        chatId: sessionId.value || props.chatId,
        messages: messages.value.length,
        isAtBottom: isAtBottom.value,
        virtualScrollerRef,
        wrapperRef: messagesWrapperRef,
      })
      // The interesting deltas: did scrollTop actually return to its
      // pre-preserve position? did scrollHeight grow by ~the new
      // messages? did the user-visible position jump (deltaAnchor ≠ 0)?
      const scrollTopDelta = afterCtx.scrollTop - beforeCtx.scrollTop
      const scrollHeightDelta = afterCtx.scrollHeight - beforeCtx.scrollHeight
      scrollLogger.info({
        ...afterCtx,
        caller: 'loadChatHistory',
        reason: 'load-more-preserve-end',
        extra: {
          prepending: newCount,
          scrollTopDelta,
          scrollHeightDelta,
          restoredOk: Math.abs(scrollTopDelta) < 2,
        },
      })

      // Re-attach the observer. setupSpacerObserver also re-initializes
      // `lastObservedScrollHeight` from the current `scrollHeight`, so
      // the next spacer resize is compared against the post-preserve
      // state — not the stale pre-preserve value, which would have made
      // the very first post-preserve spacer resize look like a
      // "measurement update" and re-trigger the stick path.
      setupSpacerObserver()
    } else {
      messages.value = newMessages.slice().reverse()
    }

    messageCursor.value = data.next_cursor
    hasMoreMessages.value = data.has_more

    if (!loadMore) {
      const initialContainer = virtualScrollerRef.value?.containerRef.value
      const initialCtx = buildScrollContext(initialContainer, {
        chatId: sessionId.value || props.chatId,
        messages: messages.value.length,
        isAtBottom: isAtBottom.value,
        virtualScrollerRef,
        wrapperRef: messagesWrapperRef,
      })
      scrollLogger.info({
        ...initialCtx,
        caller: 'loadChatHistory',
        reason: 'scroll-to-bottom-forced',
        extra: { trigger: 'initial-load' },
      })
      await nextTick()
      // Wait one paint frame so the browser has actually laid out the
      // VirtualScroller items (nextTick alone only waits for Vue's DOM
      // update, not for layout/paint). After this, the MutationObserver
      // set up in onMounted takes over: whenever spacers resize (from
      // measurement updates) it'll re-stick to the bottom as long as the
      // user hasn't scrolled up.
      await new Promise<void>((r) => requestAnimationFrame(() => r()))
      scrollToBottom(true, 'initial-load')
      setupCodeBlockCopyButtons()
    }
  } catch (err) {
    console.error('Failed to load chat history:', err)
    error.value = 'Failed to load messages'
    if (!loadMore) messages.value = []
  } finally {
    isLoading.value = false
    isLoadingMore.value = false
  }
}

// ─── Scroll ──────────────────────────────────────────────────────────────────

const scrollToBottom = async (force = false, trigger: string = 'unspecified') => {
  await nextTick()
  // Defense: during `beginPreserve`/`endPreserve`, the VirtualScroller
  // is adjusting `scrollTop` itself to keep the user's view stable
  // while older messages are prepended. An external `scrollToBottom`
  // here fights that adjustment and produces visible jitter. The
  // preserve window is short (<100ms typically) so suppressing is
  // safe — the next SSE chunk will trigger a fresh scrollToBottom.
  if (virtualScrollerRef.value?.isPreservingScroll?.value) return
  if (virtualScrollerRef.value) {
    if (force || isAtBottom.value) {
      const container = virtualScrollerRef.value.containerRef.value
      const ctx = buildScrollContext(container, {
        chatId: sessionId.value || props.chatId,
        messages: messages.value.length,
        isAtBottom: isAtBottom.value,
        virtualScrollerRef,
        wrapperRef: messagesWrapperRef,
      })
      // Mark before the assignment so the resulting scroll event reads
      // origin='programmatic' in handleVirtualScroll.
      scrollLogger.markProgrammatic()
      if (force) {
        scrollLogger.info({
          ...ctx,
          caller: 'scrollToBottom',
          reason: 'scroll-to-bottom-forced',
          extra: { trigger },
        })
      } else {
        scrollLogger.info({
          ...ctx,
          caller: 'scrollToBottom',
          reason: 'scroll-to-bottom-conditional',
          extra: { trigger, isAtBottom: isAtBottom.value },
        })
      }
      virtualScrollerRef.value.scrollToBottom('auto')
    }
  }
}

// Triggered by VirtualScroller when the user scrolls within `loadMoreThreshold`
// of the top (because `loadMoreAtTop` is true). Auto-paginates older messages.
const handleLoadMore = () => {
  // Build the context once, up front, so every guard log carries
  // the same scroller/wrapper/geometry state. The container may
  // be null (the VirtualScroller was just unmounted, or the ref
  // never bound) — `buildScrollContext` handles that.
  const container = virtualScrollerRef.value?.containerRef.value
  const ctx = buildScrollContext(container, {
    chatId: sessionId.value || props.chatId,
    messages: messages.value.length,
    isAtBottom: isAtBottom.value,
    virtualScrollerRef,
    wrapperRef: messagesWrapperRef,
  })

  // Each guard is its own `if` (not chained with `||`) so we can
  // log exactly which one blocked. Order matters: the auto-stick
  // gate is first because it's the most common cause of "I
  // scrolled to the top during streaming and nothing loaded".
  //
  // Gate suppression (not blanket suppression): the previous
  // guard `isLLMProcessing && isAtBottom` blocked loadMore for
  // the ENTIRE duration of the stream, which made pagination
  // impossible while a long response was streaming. The new
  // guard is timestamp-based: only suppress if the auto-stick
  // actually fired recently (within AUTO_STICK_GATE_MS). That
  // way:
  //   - Active stream (chunks every <100ms)
  //     → gate is fresh → suppress (no jitter from prepend
  //       fighting the next chunk's stick).
  //   - Slow model, paused stream, or user scrolled up
  //     → gate goes stale → allow loadMore.
  // See `helpers/autoStickGate.ts` for the gating math.
  const now = Date.now()
  const sinceLastAutoStickMs = lastAutoStickAt.value === 0 ? -1 : now - lastAutoStickAt.value
  if (isAutoStickActive(lastAutoStickAt.value, now, isAtBottom.value)) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleLoadMore',
      reason: 'load-more-suppressed',
      extra: {
        guard: 'auto-stick-active',
        source: 'ChatView',
        sinceLastAutoStickMs,
        gateMs: AUTO_STICK_GATE_MS,
        isLLMProcessing: isLLMProcessing.value,
        isAtBottom: isAtBottom.value,
      },
    })
    return
  }
  if (!hasMoreMessages.value) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleLoadMore',
      reason: 'load-more-suppressed',
      extra: { guard: 'no-more-messages', source: 'ChatView' },
    })
    return
  }
  if (isLoadingMore.value) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleLoadMore',
      reason: 'load-more-suppressed',
      extra: { guard: 'already-loading', source: 'ChatView' },
    })
    return
  }
  if (messages.value.length === 0) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleLoadMore',
      reason: 'load-more-suppressed',
      extra: { guard: 'no-messages', source: 'ChatView' },
    })
    return
  }

  // All guards passed — log the threshold reached and fetch.
  // The extra includes the LLM/scroll state so the log line
  // answers "was this a streaming-time loadMore?" in one glance.
  const effectiveThreshold = virtualScrollerRef.value?.effectiveLoadMoreThreshold.value ?? 200
  scrollLogger.info({
    ...ctx,
    caller: 'handleLoadMore',
    reason: 'load-more-threshold-reached',
    extra: {
      hasMore: hasMoreMessages.value,
      loadMoreThreshold: 200, // absolute floor, mirrors the prop on <VirtualScroller>
      loadMoreThresholdRatio: 0.5, // mirrors the prop on <VirtualScroller>
      effectiveLoadMoreThreshold: effectiveThreshold, // max(floor, containerHeight * ratio)
      isLLMProcessing: isLLMProcessing.value,
      isAtBottom: isAtBottom.value,
    },
  })
  loadChatHistory(true)
}

// Triggered by VirtualScroller when one of ITS internal guards
// prevented `loadMore` from being emitted — i.e. the user WAS
// within the load edge but the scroller still chose not to emit
// (because `isPreservingScroll`, `!hasMore`, `!isScrollable`, or
// `items.length === 0`). This is the "scroller-side" companion to
// `handleLoadMore`'s guard logging — together they cover every
// reason lazy load might not have fired.
//
// The `source: 'VirtualScroller'` field in `extra` distinguishes
// these from ChatView-side suppressions when you're grepping.
const handleLoadMoreSuppressed = (guard: string) => {
  const container = virtualScrollerRef.value?.containerRef.value
  const ctx = buildScrollContext(container, {
    chatId: sessionId.value || props.chatId,
    messages: messages.value.length,
    isAtBottom: isAtBottom.value,
    virtualScrollerRef,
    wrapperRef: messagesWrapperRef,
  })
  scrollLogger.info({
    ...ctx,
    caller: 'handleLoadMoreSuppressed',
    reason: 'load-more-suppressed',
    extra: { guard, source: 'VirtualScroller' },
  })
}

// Track isAtBottom from the VirtualScroller's scroll event so we can decide
// whether to auto-scroll on new messages and when to show the "scroll to
// bottom" button.
//
// `previousIsAtTop` is a module-scope (not ref) because it only feeds
// the logger — nothing else needs to react to it. Storing the
// "did we just reach the top" transition is what powers the
// `reached-top` / `left-top` log lines, which are the answer to
// "user scrolled to the top of the chat — why didn't lazy load
// fire?" If the `reached-top` line is followed by silence (no
// `load-more-threshold-reached` and no `load-more-suppressed`),
// the loadMore event was never fired in the first place.
let previousIsAtTop = false
// Module-scope state for the additional handleVirtualScroll logs
// below. Like `previousIsAtTop`, these are pure diagnostics —
// nothing else reads them. Using plain `let` (not ref) avoids any
// reactive work; the values exist only to feed the logger.
//
// Sentinel `-1` for the numeric "previous" values signals "no
// prior event yet" so the delta-based logs (`direction-change`,
// `content-resized`) can skip their first call. The
// `first-scroll` info log captures that initial state explicitly,
// so the missing deltas on call #1 don't look like a bug.
let previousScrollTop = -1
let previousScrollHeight = -1
let previousDirection: 'up' | 'down' | null = null

const handleVirtualScroll = (scrollTop: number, direction: 'up' | 'down', target: HTMLElement) => {
  // Prefer the event target — it's the actual DOM element that
  // dispatched the scroll event, so the browser guarantees it
  // exists for the lifetime of this handler. The ref chain
  // (`virtualScrollerRef.value?.containerRef.value`) is null during
  // mount/remount races (chat switch, initial mount before Vue
  // binds the template ref, v-if toggle), but the target is
  // always live. See the `scroll` emit JSDoc in
  // VirtualScroller.vue for the full rationale.
  //
  // The ref chain is kept as a defensive fallback for any future
  // caller that doesn't supply a target (none today).
  const container = target ?? virtualScrollerRef.value?.containerRef.value
  if (!container) {
    // Tripwire — with the target in hand this branch should be
    // unreachable. If it ever fires, the VirtualScroller stopped
    // passing the target through the emit (regression on the
    // fix in VirtualScroller.vue `onScroll`).
    console.warn('[scroll] handleVirtualScroll: no container (target and ref chain both null)', {
      reportedScrollTop: scrollTop,
      reportedDirection: direction,
    })
    return
  }

  // The container is the source of truth for geometry — the
  // `scrollTop` parameter is the VirtualScroller's reported value
  // and may lag by a frame. We log the param for cross-validation
  // but use the container's value everywhere else.
  const { scrollHeight, clientHeight } = container
  const actualScrollTop = container.scrollTop
  const scrollTopMatches = Math.abs(scrollTop - actualScrollTop) < 1
  const distanceFromBottom = scrollHeight - actualScrollTop - clientHeight
  const distanceFromTop = Math.max(0, actualScrollTop)
  const newIsAtBottom = distanceFromBottom < BOTTOM_THRESHOLD
  const newIsAtTop = distanceFromTop < TOP_THRESHOLD
  const previousIsAtBottom = isAtBottom.value
  // Deltas: how much scrollTop moved since the last event, and how
  // much scrollHeight grew (or shrank — e.g. an image unmounted).
  // Both are 0 on the first event. The `>= 0` guard on the
  // previous-sentinel -1 is what makes the first call a no-op
  // for delta-based logs.
  const deltaTop = previousScrollTop >= 0 ? actualScrollTop - previousScrollTop : 0
  const deltaHeight = previousScrollHeight >= 0 ? scrollHeight - previousScrollHeight : 0
  const directionChanged = previousDirection !== null && previousDirection !== direction
  const contentGrew = deltaHeight > 0
  // "Lazy-load zone" is the VirtualScroller's `loadMoreThreshold`
  // (200px) — wider than the 10px `reached-top` log. A user
  // entering the zone hasn't reached the top yet, but lazy load
  // is about to consider firing. This is the WARN-equivalent
  // info: "user is heading toward the top — expect a
  // `load-more-*` line soon".
  const isInLazyLoadZone = distanceFromTop < 200 && !newIsAtTop
  const isFirstScroll = previousScrollTop === -1
  const ctx = buildScrollContext(container, {
    chatId: sessionId.value || props.chatId,
    messages: messages.value.length,
    isAtBottom: newIsAtBottom,
    virtualScrollerRef,
    wrapperRef: messagesWrapperRef,
  })
  // Per-frame sample: throttled to ~5 Hz in the logger, with a
  // trailing-edge flush so the final position is never lost. In dev
  // you'll see ~5 lines/sec while scrolling. In production it's silent.
  scrollLogger.debug({ ...ctx, caller: 'handleVirtualScroll' })
  // ── First-scroll info ───────────────────────────────────────────────
  //
  // Captures the chat's initial state on the very first scroll
  // event. Without this, "delta=0" lines for the first few events
  // look like a bug in the delta math. Also surfaces whether the
  // VirtualScroller's reported `scrollTop` matches the container's
  // (they should agree to within 1px; a >1px mismatch is a stale
  // param bug, not a cosmetic issue).
  if (isFirstScroll) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleVirtualScroll',
      reason: 'first-scroll',
      extra: {
        reportedScrollTop: scrollTop,
        reportedDirection: direction,
        actualScrollTop,
        scrollTopMatches,
        distanceFromTop,
        distanceFromBottom,
      },
    })
  }
  // ── Direction-change info ───────────────────────────────────────────
  //
  // The user reversed scroll direction (e.g. was scrolling up to
  // read history, then back down). This is the "why did the chat
  // jump to the bottom when I was scrolling up?" signal — if a
  // `reached-bottom` log follows a `direction-change` with
  // `direction: 'up'`, the auto-stick fired in the middle of an
  // upward gesture. If you see this in the logs and the next state
  // transition is `left-bottom` (not `reached-bottom`), the user's
  // direction reversal was respected correctly.
  if (directionChanged) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleVirtualScroll',
      reason: 'direction-change',
      extra: {
        previousDirection,
        direction,
        deltaTop,
        distanceFromTop,
        distanceFromBottom,
      },
    })
  }
  // ── Content-resized info ────────────────────────────────────────────
  //
  // `scrollHeight` changed between two scroll events. Causes:
  //   - New message appended (SSE chunk, messages-length watcher)
  //   - Image finished loading / unmounted
  //   - VirtualScroller measured or relayouted items
  //   - User toggled message-grouping, attachments, or code fold
  // Combined with the next state-transition log, this answers
  // "did content grow while I was scrolled up reading?" — if so,
  // the user's reading position may no longer reference the same
  // message it did a moment ago. Negative `deltaHeight` (content
  // shrank) is logged too — that's a code-fold collapse or
  // optimistic message rollback.
  if (contentGrew) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleVirtualScroll',
      reason: 'content-resized',
      extra: {
        deltaHeight,
        previousScrollHeight,
        scrollHeight,
        direction,
        distanceFromTop,
        distanceFromBottom,
      },
    })
  }
  // ── Lazy-load-zone info ─────────────────────────────────────────────
  //
  // The user is within `loadMoreThreshold` (200px) of the top
  // but hasn't reached the 10px `reached-top` threshold yet.
  // The VirtualScroller's onScroll debounce is probably about to
  // fire `loadMore`. If you see this line followed by silence
  // (no `load-more-threshold-reached` and no
  // `load-more-suppressed`), the debounce was reset by another
  // scroll event before it could fire.
  if (isInLazyLoadZone) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleVirtualScroll',
      reason: 'lazy-load-zone',
      extra: {
        distanceFromTop,
        threshold: 200,
        direction,
        deltaTop,
      },
    })
  }
  // ── State transitions are loud ─────────────────────────────────────
  //
  // This is the most useful line in the whole logger. "User was
  // at bottom, scrolled up 200px" vs "Auto-stick fired,
  // isAtBottom is true again" are the two events that answer
  // every "why did the chat jump?" question.
  if (newIsAtBottom !== previousIsAtBottom) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleVirtualScroll',
      reason: newIsAtBottom ? 'reached-bottom' : 'left-bottom',
      extra: {
        previousIsAtBottom,
        distanceFromBottom,
        threshold: BOTTOM_THRESHOLD,
        direction,
        deltaTop,
      },
    })
  }
  // ── Top edge transitions ─────────────────────────────────────────────
  //
  // Mirrors the bottom-edge logging above. The two edges behave
  // symmetrically: the user can be 200px from the top and have
  // `loadMore` fire (the lazy-load threshold), but the
  // `reached-top` state-transition log only fires at <10px — the
  // same `BOTTOM_THRESHOLD` analog (`TOP_THRESHOLD`). A user who's
  // at the top of the chat is by definition within lazy-load range,
  // so the `reached-top` line should ALWAYS be followed by either:
  //   - `load-more-threshold-reached` (the loadMore fired)
  //   - `load-more-suppressed`  (a guard blocked it)
  // If you see `reached-top` with neither of those, the loadMore
  // event was lost (e.g. the VirtualScroller's onScroll debounce
  // was reset by a new scroll event, or the handler returned
  // before debounce fired).
  if (newIsAtTop !== previousIsAtTop) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleVirtualScroll',
      reason: newIsAtTop ? 'reached-top' : 'left-top',
      extra: {
        previousIsAtTop,
        distanceFromTop,
        threshold: TOP_THRESHOLD,
        direction,
        deltaTop,
      },
    })
    previousIsAtTop = newIsAtTop
  }
  // Tight 10px threshold: a chat message is typically 50-100px tall, so
  // reading the last message puts you well outside this window. This
  // prevents SSE chunks, the messages-length watcher, and the spacer
  // MutationObserver from yanking the user back to the bottom while
  // they're reading history.
  //
  // The initial chat load is unaffected — it uses `scrollToBottom(true)`
  // (force=true), which always scrolls regardless of this flag. So
  // opening a session still lands at the bottom, but once the user
  // scrolls up even a few pixels, the auto-scroll disengages.
  isAtBottom.value = newIsAtBottom
  // Persist the current state for the next call's deltas. Done
  // AFTER the logs so the `first-scroll` log captures the raw
  // initial state (with -1 sentinels making the deltas explicit).
  previousScrollTop = actualScrollTop
  previousScrollHeight = scrollHeight
  previousDirection = direction
}

// ─── SSE ─────────────────────────────────────────────────────────────────────

const isAlreadyConnectedSSE = ref(false)
const connectSse = async () => {
  console.log('[connectSse] Connecting SSE for session:', sessionId.value)
  if (!sessionId.value) return

  if (isAlreadyConnectedSSE.value == false) disconnectSse()

  isStreaming.value = true
  streamingContent.value = ''

  eventSource.value = await api.createSseConnection(
    sessionId.value,
    (event: api.SseEvent) => {
      console.log('[SSE ChatView] Received event:', event)

      if (event.type === 'connected' && event.session_id) {
        console.log('SSE connected, session:', event.session_id)
        return
      }

      if (event.type !== 'chunk' && event.type !== 'full') {
        return
      }


      if (event.type === 'chunk' && event.content) {
        streamingContent.value = event.content
        updateStreamingMessage()
        return
      }

      if (event.type === 'full' && event.finish_reason && event.content) {
        messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))

        const role =
          (event.role as 'user' | 'assistant' | 'system' | 'tool') ||
          (event.tool_call_id ? 'tool' : 'assistant')

        messages.value.push({
          id: event.id || `assistant-${Date.now()}`,
          role: role,
          content: event.content,
          timestamp: new Date(),
          tool_name: event.tool_name,
          diffview_before: event.diffview_before,
          diffview_after: event.diffview_after,
          // Match the loadChatHistory REST path (line 824): split the
          // pipe-separated image_url string the backend sends. Undefined
          // for messages without images keeps the v-if="image_urls?.length"
          // check in the template clean.
          image_urls: event.image_url ? event.image_url.split('|') : undefined,
          finish_reason: event.finish_reason,
          tool_call_id: event.tool_call_id,
        })
        streamingContent.value = ''
        isStreaming.value = false
        scrollLogger.markProgrammatic()
        // One more auto-stick fires (scrollToBottom below) for the
        // final, post-stream assistant message. Mark the timestamp so
        // the loadMore gate sees the stick as still active during the
        // tail of the message-complete render frame. After ~500ms
        // (AUTO_STICK_GATE_MS) the gate lifts and the user can
        // scroll-up-and-prepend as normal.
        lastAutoStickAt.value = Date.now()
        nextTick(() => scrollToBottom(false, 'sse-message-complete'))
        setupCodeBlockCopyButtons()

        if (event.total_tokens) {
          maxTotalTokens.value = event.total_tokens
        }

        return
      }

      if (event.reasoning_content && !event.content) {
        console.log('Reasoning:', event.reasoning_content)
      }
    },
    (err) => {
      console.error('SSE error:', err)
      isStreaming.value = false
      streamingContent.value = ''
    },
    () => {
      console.log('SSE connected')
      isAlreadyConnectedSSE.value = true
    },
  )

  queueEventSource.value = await api.createQueueMessagesSseConnection(
    sessionId.value,
    (event: api.QueueMessageEvent) => {
      console.log('[QueueMessages SSE] Received event:', event)
      if (event.action === 'queued') {
        queuedMessages.value.push({
          id: event.id ?? `q-${Date.now()}`,
          message: event.message,
        })
      } else if (event.action === 'deleted') {
        queuedMessages.value = queuedMessages.value.filter((m) => m.message !== event.message)
      }
    },
    (err) => {
      console.error('QueueMessages SSE error:', err)
    },
    () => {
      console.log('QueueMessages SSE connected')
    },
  )
}

const disconnectSse = () => {
  if (eventSource.value) {
    eventSource.value.close()
    eventSource.value = null
  }
  if (queueEventSource.value) {
    queueEventSource.value.close()
    queueEventSource.value = null
  }
  isStreaming.value = false
  streamingContent.value = ''
  messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))
}

// Coalesce flag for SSE-driven `scrollToBottom` calls. SSE chunks
// can fire 20+ times/sec, but we only need one scrollToBottom per
// animation frame. Without this, the console floods with
// `scroll-to-bottom-conditional` lines and we do redundant geometry
// reads. The user reads content, not scroll position — one frame
// (16ms) of lag is imperceptible.
//
// Declared at script-setup scope so the flag persists across calls
// to `updateStreamingMessage` (re-declaring it inside the function
// would reset it every time, defeating the coalesce).
let sseScrollPending = false

const updateStreamingMessage = () => {
  console.log('[updateStreamingMessage] streamingContent:', streamingContent.value)
  // Every SSE chunk drives an auto-stick via scrollToBottom below
  // (coalesced to one-per-frame). Mark the timestamp NOW, before the
  // rAF coalesce, so the gate reflects the chunk that just arrived
  // — not the rAF callback that runs up to 16ms later. With chunks
  // firing 20+/sec this keeps the gate always-fresh during active
  // streaming; with a slow model the timestamp goes stale between
  // chunks and the user can loadMore.
  lastAutoStickAt.value = Date.now()
  const existingMsg = messages.value.find(
    (m) => m.role === 'assistant' && m.id.startsWith('streaming-'),
  )
  if (existingMsg) {
    existingMsg.content = streamingContent.value
  } else {
    messages.value.push({
      id: `streaming-${Date.now()}`,
      role: 'assistant',
      content: streamingContent.value,
      timestamp: new Date(),
    })
  }
  const stripped = stripThinkingTags(streamingContent.value)
  if (stripped && stripped.trim() !== '') {
    // Coalesce: SSE chunks can fire 20+ times/sec, but we only need
    // one scrollToBottom per animation frame. Without this, the
    // console floods with `scroll-to-bottom-conditional` lines and
    // we do redundant geometry reads. The user reads content, not
    // scroll position — one frame (16ms) of lag is imperceptible.
    if (!sseScrollPending) {
      sseScrollPending = true
      requestAnimationFrame(() => {
        sseScrollPending = false
        scrollLogger.markProgrammatic()
        scrollToBottom(false, 'sse-chunk')
      })
    }
  }
  nextTick(() => setupCodeBlockCopyButtons())
}

// ─── Init ──────────────────────────────────────────────────────────────────────

onMounted(async () => {
  sessionId.value = props.chatId.replace(/^chat-/, '')

  if (props.cwd) {
    cwd.value = props.cwd
  }

  if (sessionId.value) {
    // Set up the spacer MutationObserver BEFORE loadChatHistory so we
    // catch the very first measurement-driven spacer resize. The
    // VirtualScroller's child component mounts before us (child before
    // parent in Vue 3), so its containerRef is already populated.
    setupSpacerObserver()

    await loadChatHistory()
    connectSse()
    startGitStatusPoll()

    try {
      const result = await api.getQueuedMessages(sessionId.value)
      queuedMessages.value = result.messages
    } catch (err) {
      console.error('Failed to get queued messages:', err)
    }
  }
})

onUnmounted(() => {
  teardownSpacerObserver()
  disconnectSse()
  stopGitStatusPoll()
  document.removeEventListener('click', closeOnOutsideClick)
})

// Load available profiles (called once on mount)
loadProfiles()
document.addEventListener('click', closeOnOutsideClick)

// When the session changes, load the current selection from the backend
watch(
  () => sessionId.value,
  async (newId) => {
    if (!newId) {
      selectedProfile.value = null
      return
    }
    try {
      const session = await api.getSession(newId)
      selectedProfile.value = session?.selectedProfile ?? null
    } catch (err) {
      console.error('Failed to load session profile:', err)
      selectedProfile.value = null
    }
  },
  { immediate: false },
)

watch(
  () => messages.value.length,
  () => {
    scrollLogger.markProgrammatic()
    // Any push to `messages` triggers an auto-stick (scrollToBottom
    // below). Mark the timestamp synchronously so the loadMore gate
    // sees the stick as active during the same render frame the
    // message landed in. Catches user-message sends, tool results,
    // pagination prepends (handled separately by endPreserve, but
    // the watcher also fires), and the streaming message's first
    // push before updateStreamingMessage's own mark takes over.
    lastAutoStickAt.value = Date.now()
    nextTick(() => scrollToBottom(false, 'messages-length'))
  },
)

watch(
  () => effectiveCwd.value,
  (newCwd) => {
    if (newCwd) {
      checkGitStatus()
    } else {
      gitStatus.value = null
    }
  },
)

// Refresh the scroll logger whenever the active chat changes so the
// chatId tag in every line stays accurate. Runs on initial mount too
// (sessionId is set in onMounted but the watch is registered before).
watch(
  () => sessionId.value,
  () => refreshScrollLogger(),
)

// ─── Send Message ─────────────────────────────────────────────────────────────

const handleFileInputSubmit = async (userMessage: string, files?: File[]) => {
  await nextTick()
  scrollToBottom(true, 'send-message')

  let currentSessionId = sessionId.value

  let imageUrls: string[] = []
  if (files && files.length > 0) {
    const fileToBase64 = (file: File): Promise<string> => {
      return new Promise((resolve, reject) => {
        const reader = new FileReader()
        reader.onload = () => resolve(reader.result as string)
        reader.onerror = reject
        reader.readAsDataURL(file)
      })
    }
    imageUrls = await Promise.all(files.map((f) => fileToBase64(f)))
  }

  try {
    await api.sendChatMessage(
      currentSessionId,
      userMessage,
      cwd.value,
      imageUrls,
      selectedProfile.value ?? undefined,
    )
  } catch (err) {
    console.error('Failed to send message:', err)
    messages.value.push({
      id: `error-${Date.now()}`,
      role: 'assistant',
      content: 'Sorry, I encountered an error. Please try again.',
      timestamp: new Date(),
    })
  }
}

const formatTime = (date: Date) => {
  if (!date || isNaN(date.getTime())) return ''
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

// ─── Compact ──────────────────────────────────────────────────────────────────

const isCompacting = ref(false)
const compactError = ref<string | null>(null)

const compactSession = async () => {
  if (!sessionId.value || isCompacting.value) return

  isCompacting.value = true
  compactError.value = null

  try {
    const result = await api.compactSession(sessionId.value)
    if (result.success) {
      await loadChatHistory()
    } else {
      compactError.value = result.message || 'Failed to compact'
    }
  } catch (err) {
    console.error('Failed to compact session:', err)
    compactError.value = 'Failed to compact session'
  } finally {
    isCompacting.value = false
  }
}
</script>

<template>
  <div class="flex h-full w-full">
    <!-- Main Chat Content -->
    <div class="flex flex-col h-full flex-1 min-w-0">
      <!--
        Chat header. Rendered only when the parent passed the
        `showHeader` prop (the kanban 3-column layout sets it; the
        full-width standalone chat layout leaves it false so the
        existing "no header" experience is preserved). When shown,
        it includes the chat name (so the user can see which task
        they're chatting with when the kanban + chat are side by
        side) and a ✕ button that emits `close` to the host. The
        host (AppLayout) handles the actual navigation / state
        cleanup so the ChatView stays decoupled from router + store
        concerns.
      -->
      <header
        v-if="showHeader"
        class="h-11 flex items-center gap-2 px-3 shrink-0"
        style="
          background-color: var(--semantic-sidebar-bg);
          border-bottom: 1px solid var(--color-border);
        "
        :data-chat-header="chatId"
      >
        <span
          class="text-sm font-semibold truncate flex-1"
          style="color: var(--semantic-text);"
          :data-testid="`chat-header-name-${chatId}`"
        >
          {{ chatName }}
        </span>
        <button
          type="button"
          class="shrink-0 w-7 h-7 rounded flex items-center justify-center text-lg hover:opacity-70 transition-opacity"
          style="color: var(--semantic-text-dim);"
          title="Close chat (return to kanban)"
          aria-label="Close chat"
          :data-testid="`chat-header-close-${chatId}`"
          @click="emit('close')"
        >
          ✕
        </button>
      </header>
      <!-- Messages (Virtual Scroll) -->
      <!--
        The wrapper MUST be a flex container (`flex flex-col`) so the
        VirtualScroller's own `flex: 1 1 0` (defined in helpers/
        VirtualScroller.vue) can resolve to a real height. Without
        `flex` here, the wrapper is a regular block element — the
        VirtualScroller's `flex: 1 1 0` does nothing, the scroller
        collapses to 0×0, the messages overflow out of the wrapper,
        and the last bubbles overlap the FileInput below. This is the
        "no scroll, bubbles overlap input" bug.
      -->
      <div ref="messagesWrapperRef" class="relative flex-1 min-h-0 flex flex-col">
        <!-- Loading More indicator (floats above the scroller during pagination) -->
        <!-- temporary disable -->
        <!-- <div -->
        <!--   v-if="isLoadingMore" -->
        <!--   class="absolute top-0 left-0 right-0 flex justify-center py-2 z-10 pointer-events-none" -->
        <!-- > -->
        <!--   <div -->
        <!--     class="flex items-center gap-2 px-4 py-2 rounded-full shadow-sm" -->
        <!--     style="background-color: var(--semantic-card-bg)" -->
        <!--   > -->
        <!--     <div -->
        <!--       class="w-4 h-4 border-2 rounded-full animate-spin" -->
        <!--       style="border-color: var(--color-violet); border-top-color: transparent" -->
        <!--     ></div> -->
        <!--     <span class="text-sm" style="color: var(--semantic-text-dim)">Loading more...</span> -->
        <!--   </div> -->
        <!-- </div> -->

        <!-- Empty State -->
        <div
          v-if="!isLoading && messageGroups.length === 0"
          class="flex flex-col items-center justify-center h-full px-4"
        >
          <div
            class="w-16 h-16 rounded-2xl mb-4 flex items-center justify-center text-3xl"
            style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue))"
          >
            💬
          </div>
          <h3 class="text-lg font-medium mb-2" style="color: var(--semantic-text)">
            How can I help you?
          </h3>
          <p class="text-sm text-center" style="color: var(--semantic-text-dim)">
            Start a conversation by typing a message below
          </p>
        </div>

        <!--
          Load more messages button.

          Why this exists: the <VirtualScroller> below only emits @load-more
          when the user scrolls within `loadMoreThreshold` of the top of a
          *scrollable* container. When the loaded messages fit in the
          viewport (a common case for short tool/result chats, see the
          screenshot in docs/plans/2026-06-04-chat-lazy-load-button.md),
          the container is not scrollable, the scroll event never fires,
          and the user has no way to reach older messages.

          This button bypasses the scroll trigger and calls
          `loadChatHistory(true)` directly. It is hidden while a
          pagination is already in flight (`isLoadingMore`) so we don't
          show two spinners, hidden when the initial empty state is
          rendered (`messageGroups.length === 0`), and hidden when the
          container IS scrollable (`!scrollerIsScrollable` is false) —
          in that case the user can scroll to the top to load more, and
          showing the button would be UI clutter.

          Position: sibling of <VirtualScroller> inside the
          `messagesWrapperRef` flex container. The wrapper is
          `position: relative` (see line 1395) and a `flex flex-col`
          layout; this button is the first child so it sits above the
          scroller and is not subject to virtualization or the
          `beginPreserve`/`endPreserve` scroll-restoration dance.
        -->
        <div
          v-if="
            hasMoreMessages && !isLoadingMore && messageGroups.length > 0 && !scrollerIsScrollable
          "
          class="flex justify-center pt-2 pb-1"
          data-testid="load-more-messages"
        >
          <button
            @click="loadChatHistory(true)"
            class="flex items-center gap-2 px-4 py-1.5 rounded-full text-xs transition-all duration-200 hover:scale-105"
            style="
              background-color: var(--semantic-card-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            :title="`Load ${PAGE_SIZE} older messages`"
          >
            <span>↑</span>
            <span>Load more messages</span>
          </button>
        </div>

        <!-- Virtualized Message List -->
        <VirtualScroller
          v-if="isLoading || messageGroups.length > 0"
          ref="virtualScrollerRef"
          :items="messageGroups"
          :total-count="0"
          :buffer="20"
          :default-item-height="200"
          :load-more-threshold="200"
          :load-more-threshold-ratio="0.5"
          :load-more-at-top="true"
          @load-more="handleLoadMore"
          @load-more-suppressed="handleLoadMoreSuppressed"
          @scroll="handleVirtualScroll"
          @scrollability-change="scrollerIsScrollable = $event"
        >
          <template #default="{ item: group, index: groupIndex }">
            <div class="px-4 max-w-4xl mx-auto" :class="groupIndex === 0 ? 'pt-6' : ''">
              <div
                class="flex gap-3 pb-4"
                :class="group.role === 'user' ? 'flex-row-reverse' : 'flex-row'"
              >
                <!-- Bubble -->
                <div class="max-w-[90%] min-w-0">
                  <div
                    v-if="hasBubbleContent(group, groupIndex)"
                    class="px-4 py-2.5 rounded-2xl text-sm leading-relaxed"
                    role="button"
                    tabindex="0"
                    :class="
                      group.role === 'user' ? 'whitespace-pre-wrap break-words' : 'markdown-content'
                    "
                    :style="
                      group.role === 'user'
                        ? 'background-color: var(--color-blue-1); color: var(--semantic-text); border-bottom-right-radius: 6px;'
                        : 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border-bottom-left-radius: 6px; border: 1px solid var(--color-border);'
                    "
                  >
                    <!-- ── User ── -->
                    <template v-if="group.role === 'user'">
                      <!-- Compaction envelope: render as a structured card
                           instead of a wall of escaped XML. -->
                      <CompactionCard
                        v-if="isCompactionMessage(group.messages[0])"
                        :content="group.messages[0]!.content"
                      />
                      <template v-else>
                        <div
                          v-if="
                            group.messages[0]?.image_urls && group.messages[0]!.image_urls!.length > 0
                          "
                          class="mb-2"
                        >
                          <div class="flex flex-wrap gap-2">
                            <img
                              v-for="(imgUrl, imgIdx) in group.messages[0]!.image_urls"
                              :key="imgIdx"
                              :src="imgUrl"
                              alt="Attached image"
                              class="max-w-full rounded-lg max-h-64 cursor-pointer hover:opacity-90"
                              @click="openImagePreview(imgUrl)"
                            />
                          </div>
                        </div>
                        {{ group.messages[0]!.content }}
                      </template>
                    </template>

                    <!-- ── Tool ── -->
                    <template v-else-if="group.role === 'tool'">
                      <div class="tool-sequence">
                        <div
                          v-for="(msg, idx) in group.messages"
                          :key="idx"
                          class="tool-item"
                          :class="idx < group.messages.length - 1 ? 'tool-item-border' : ''"
                        >
                          <ReadFile
                            v-if="msg.tool_name === 'read_file'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                            :cwd="cwd"
                          />
                          <WriteFile
                            v-else-if="msg.tool_name === 'write_file'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                            :cwd="cwd"
                          />
                          <UpdateActivity
                            v-else-if="msg.tool_name === 'update_activity'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <Search
                            v-else-if="msg.tool_name === 'search'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                            :cwd="cwd"
                          />
                          <Glob
                            v-else-if="msg.tool_name === 'glob'"
                            :content="innerToolData(msg)"
                            :cwd="cwd"
                          />
                          <TextReplace
                            v-else-if="msg.tool_name === 'text_replace'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                            :diffview-before="msg.diffview_before"
                            :diffview-after="msg.diffview_after"
                            :cwd="cwd"
                          />
                          <Bash
                            v-else-if="msg.tool_name === 'bash' || msg.tool_name === 'run_command'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <GetSkill
                            v-else-if="msg.tool_name === 'get_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <ViewSkill
                            v-else-if="msg.tool_name === 'view_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <ListSkills
                            v-else-if="msg.tool_name === 'list_skills'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <AddSkill
                            v-else-if="msg.tool_name === 'add_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <EditSkill
                            v-else-if="msg.tool_name === 'edit_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <RemoveSkill
                            v-else-if="msg.tool_name === 'remove_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <RemoveFile
                            v-else-if="msg.tool_name === 'remove_file'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                            :cwd="cwd"
                          />
                          <SpawnSubAgent
                            v-else-if="msg.tool_name === 'spawn_sub_agent'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                            :sub-agent-args="findSubAgentArgsForToolGroup(msg.tool_call_id, messageGroups, groupIndex)"
                          />
                          <NalarBrowser
                            v-else-if="msg.tool_name === 'nalar_browser'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <SetGitWorktree
                            v-else-if="msg.tool_name === 'set_git_worktree'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <ReadCompactedMessages
                            v-else-if="msg.tool_name === 'read_compacted_messages'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <KanbanMove
                            v-else-if="msg.tool_name === 'kanban_move_task'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <KanbanList
                            v-else-if="msg.tool_name === 'kanban_list'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <div v-else class="tool-expandable">
                            <button
                              class="tool-summary"
                              @click="toggleToolExpanded(groupIndex, idx)"
                              :style="[
                                'cursor: pointer; padding: 2px 4px; border-radius: 4px; transition: background-color 0.15s; text-align: left; width: 100%; border: none; background: transparent; font: inherit; color: inherit;',
                                expandedToolIds.has(`${groupIndex}-${idx}`)
                                  ? 'border-bottom: 1px dashed var(--color-border);'
                                  : '',
                              ]"
                            >
                              <span
                                v-html="
                                  renderResponse(
                                    msg.content,
                                    msg.role,
                                    msg.tool_name,
                                    msg.diffview_before,
                                    msg.diffview_after,
                                    msg.finish_reason,
                                    msg.tool_calls_json,
                                  )
                                "
                              ></span>
                            </button>
                            <div
                              v-if="expandedToolIds.has(`${groupIndex}-${idx}`)"
                              class="tool-full-content"
                            >
                              <DiffView
                                v-if="msg.diffview_before && msg.diffview_after"
                                :before="msg.diffview_before"
                                :after="msg.diffview_after"
                              />
                            </div>
                          </div>
                        </div>
                      </div>
                    </template>

                    <!-- ── Assistant ── -->
                    <template v-else-if="group.role === 'assistant'">
                      <!-- Show tool_calls header only when tool outputs are NOT shown -->
                      <div v-if="groupToolNames[groupIndex] !== null">
                        <div class="tool-calls-summary">
                          <span class="tool-calls-badge">
                            <svg
                              xmlns="http://www.w3.org/2000/svg"
                              class="w-3.5 h-3.5"
                              viewBox="0 0 24 24"
                              fill="none"
                              stroke="currentColor"
                              stroke-width="2"
                              stroke-linecap="round"
                              stroke-linejoin="round"
                            >
                              <path
                                d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"
                              />
                            </svg>
                            <span class="font-medium">tools</span>
                          </span>
                          <div class="tool-names-list">
                            <span
                              v-for="(toolName, tIdx) in (groupToolNames[groupIndex] || '').split(
                                ',',
                              )"
                              :key="tIdx"
                              class="tool-name-chip"
                              >{{ toolName.trim() }}</span
                            >
                          </div>
                        </div>
                      </div>
                      <!-- Hide the messages block when every message in the group
                           is empty after stripping thinking tags — this happens
                           on tool_calls-only assistant turns. The tool header
                           (if any) is shown above; we don't want an empty
                           padded area below it. -->
                      <div v-if="group.messages.some(hasVisibleContent)" class="assistant-messages">
                        <div v-for="(msg, idx) in group.messages" :key="idx" class="assistant-item">
                          <!-- eslint-disable-next-line vue/no-v-html -->
                          <span
                            v-html="
                              renderResponse(
                                msg.content,
                                msg.role,
                                msg.tool_name,
                                msg.diffview_before,
                                msg.diffview_after,
                                msg.finish_reason,
                                msg.tool_calls_json,
                              )
                            "
                          ></span>
                        </div>
                      </div>
                    </template>
                  </div>
                  <!-- Timestamp is hidden along with the bubble. The bubble
                       uses v-if="hasBubbleContent(...)" above; if the
                       bubble is hidden, the timestamp would otherwise
                       appear orphaned (this was the "timestamps with no
                       bubble" visual artifact between tool calls). -->
                  <!-- <div -->
                  <!--   v-if="hasBubbleContent(group, groupIndex)" -->
                  <!--   class="text-xs mt-1 px-1" -->
                  <!--   :class="group.role === 'user' ? 'text-right' : 'text-left'" -->
                  <!--   style="color: var(--semantic-text-dim)" -->
                  <!-- > -->
                  <!--   {{ formatTime(group.timestamp) }} -->
                  <!-- </div> -->
                </div>
              </div>
            </div>
          </template>
        </VirtualScroller>
      </div>

      <!-- Scroll to bottom button -->
      <Transition name="fade">
        <button
          v-if="!isAtBottom && messageGroups.length > 0"
          @click="scrollToBottom(true, 'user-button-click')"
          class="absolute bottom-24 right-8 p-3 rounded-full shadow-lg transition-all duration-200 hover:scale-105"
          style="background-color: var(--color-violet); color: var(--color-bg)"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-5 h-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M19 14l-7 7m0 0l-7-7m7 7V3"
            />
          </svg>
        </button>
      </Transition>

      <!-- Input -->
      <div
        class="p-4"
        style="
          border-top: 1px solid var(--color-border);
          background-color: var(--semantic-sidebar-bg);
        "
      >
        <div class="max-w-4xl mx-auto">
          <FileInput
            :cwd="cwd"
            :queuedMessages="queuedMessages"
            :isLoading="isLoading"
            :isLLMProcessing="isLLMProcessing"
            @submit="handleFileInputSubmit"
            @files-selected="handleFileInputSubmit"
          />
          <!-- Status bar -->
          <div class="flex items-center gap-2 mt-3">
            <!-- Compact button -->
            <button
              @click="compactSession"
              :disabled="isCompacting || isLoading || isLLMProcessing || !sessionId"
              class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-200"
              :class="
                isCompacting || isLoading || isLLMProcessing || !sessionId
                  ? 'opacity-50 cursor-not-allowed'
                  : 'hover:scale-105'
              "
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              :title="isCompacting ? 'Compacting...' : 'Compact conversation history'"
            >
              <span
                v-if="isCompacting"
                class="w-3.5 h-3.5 border-2 rounded-full animate-spin"
                style="border-color: var(--color-violet); border-top-color: transparent"
              ></span>
              <span v-else>🗜️</span>
              <span>{{ isCompacting ? 'Compacting...' : 'Compact' }}</span>
            </button>

            <!-- Model/Profile selector -->
            <div ref="profilePickerRef" class="relative">
              <button
                @click.stop="showProfilePicker = !showProfilePicker"
                :disabled="isUpdatingProfile || !sessionId"
                class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-200"
                :class="
                  isUpdatingProfile || !sessionId
                    ? 'opacity-50 cursor-not-allowed'
                    : 'hover:scale-105'
                "
                style="
                  background-color: var(--semantic-card-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                "
                :title="
                  selectedProfile
                    ? `Using profile: ${selectedProfile}`
                    : 'Using default (top-level config)'
                "
              >
                <span>🤖</span>
                <span>{{ selectedProfile ?? 'Default' }}</span>
                <span class="text-[10px]">▾</span>
              </button>
              <div
                v-if="showProfilePicker"
                class="absolute bottom-full mb-2 left-0 min-w-[240px] rounded-lg shadow-lg z-20 overflow-hidden"
                style="
                  background-color: var(--semantic-card-bg);
                  border: 1px solid var(--color-border);
                "
              >
                <button
                  @click="selectProfile(null)"
                  class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center justify-between"
                  style="color: var(--semantic-text)"
                >
                  <span>Default (top-level config)</span>
                  <span v-if="!selectedProfile">✓</span>
                </button>
                <button
                  v-for="p in availableProfiles"
                  :key="p.name"
                  @click="selectProfile(p.name)"
                  class="w-full text-left px-3 py-2 text-xs hover:opacity-80"
                  style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
                >
                  <div class="flex items-center justify-between">
                    <span class="font-medium">{{ p.name }}</span>
                    <span v-if="selectedProfile === p.name">✓</span>
                  </div>
                  <div class="text-[10px] mt-0.5" style="color: var(--semantic-text-muted)">
                    {{ p.model }} · {{ p.base_url }}
                  </div>
                </button>
                <div
                  v-if="availableProfiles.length === 0"
                  class="px-3 py-2 text-xs"
                  style="color: var(--semantic-text-muted)"
                >
                  No profiles configured. Add one in Settings.
                </div>
              </div>
            </div>
            <!-- Token usage display -->
            <div
              v-if="maxTotalTokens > 0 || maxCapacityTotalTokens > 0"
              class="flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
              "
            >
              <span style="color: var(--semantic-text-dim)">Tokens:</span>
              <span style="color: var(--semantic-text)">{{ maxTotalTokens.toLocaleString() }}</span>
              <span v-if="maxCapacityTotalTokens > 0" style="color: var(--semantic-text-dim)"
                >/ {{ maxCapacityTotalTokens.toLocaleString() }}</span
              >
              <div
                v-if="maxCapacityTotalTokens > 0"
                class="w-16 h-2 rounded-full overflow-hidden"
                style="background-color: var(--color-border)"
              >
                <div
                  class="h-full rounded-full transition-all duration-300"
                  :style="{
                    width: Math.min(100, (maxTotalTokens / maxCapacityTotalTokens) * 100) + '%',
                    backgroundColor:
                      maxTotalTokens / maxCapacityTotalTokens > 0.8
                        ? 'var(--color-red)'
                        : maxTotalTokens / maxCapacityTotalTokens > 0.6
                          ? 'var(--color-orange)'
                          : 'var(--color-violet)',
                  }"
                ></div>
              </div>
            </div>
            <!-- Git status indicator — always clickable; opens a dropdown
                 menu with context-appropriate actions (worktree-bound vs.
                 no-worktree). -->
            <div ref="worktreeMenuRef" class="relative">
              <button
                v-if="gitStatus && gitStatus.is_git_repo"
                @click.stop="showWorktreeMenu = !showWorktreeMenu"
                data-testid="worktree-status-button"
                class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs transition-all duration-200 cursor-pointer hover:scale-105"
                style="
                  background-color: var(--semantic-card-bg);
                  border: 1px solid var(--color-border);
                "
                :title="
                  gitWorktreeCwd
                    ? `Worktree: ${gitWorktreeCwd}\n${gitStatus.status === 'clean' ? 'Working tree clean' : 'Working tree has changes'}`
                    : (gitStatus.status === 'clean' ? 'Working tree clean' : 'Working tree has changes')
                "
              >
                <span>🌿</span>
                <span style="color: var(--semantic-text)">{{ gitStatus.branch || 'main' }}</span>
                <span v-if="!gitStatus.is_clean" style="color: var(--color-orange)">●</span>
                <span v-else style="color: var(--color-green)">✓</span>
                <span class="text-[10px]">▾</span>
              </button>
              <WorktreeMenu
                v-if="showWorktreeMenu"
                :has-worktree="!!gitWorktreeCwd"
                :branch="gitStatus?.branch || 'detached'"
                :status="gitStatus?.status"
                @create-pr="onWorktreeMenuCreatePr"
                @create-worktree="onWorktreeMenuCreateWorktree"
                @view-folder="onWorktreeMenuViewFolder"
                @clear="onWorktreeMenuClear"
                @refresh="onWorktreeMenuRefresh"
                @close="showWorktreeMenu = false"
              />
            </div>
            <!-- Session skills display -->
            <button
              v-if="sessionSkills && sessionSkills.length > 0"
              @click="showSkillsPopup = true"
              class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs transition-all duration-200 hover:scale-105"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                cursor: pointer;
              "
              :title="'Loaded skills: ' + sessionSkills.map((s) => s.skill_name).join(', ')"
            >
              <span>🧠</span>
              <span style="color: var(--semantic-text)">{{ sessionSkills.length }}</span>
              <span style="color: var(--semantic-text-dim)"
                >skill{{ sessionSkills.length !== 1 ? 's' : '' }}</span
              >
            </button>

            <!--
              SSE connection indicator for the chat stream. Hidden
              when the stream is healthy (the common case); a small
              pill appears when reconnecting so the user knows their
              chat is recovering instead of silently dying. Driven by
              the SseClient's onStateChange API — see
              components/SseStatusBadge.vue and helpers/sseClient.ts.
            -->
            <SseStatusBadge :client="eventSource" />
          </div>
        </div>
      </div>
    </div>

    <!-- Skills Popup Modal -->
    <SkillsPopup
      :show="showSkillsPopup"
      :skills="sessionSkills"
      :session-cwd="cwd"
      @close="showSkillsPopup = false"
      @skill-click="
        (skill) => {
          console.log('Skill clicked:', skill)
          showSkillsPopup = false
        }
      "
    />

    <!-- Image Preview Popup -->
    <ImagePreview :src="previewImageUrl ?? ''" @close="closeImagePreview" />

    <!--
      Create-PR modal. Mounted when the user picks "Create a PR" from
      the WorktreeMenu. The dialog pre-fills from getGitWorktreeInfo,
      submits to /api/git/pr, and emits pr-created (URL) or error.
    -->
    <CreatePrDialog
      v-if="showCreatePrDialog"
      :worktree-path="gitWorktreeCwd"
      @pr-created="onPrCreated"
      @error="onPrError"
      @close="showCreatePrDialog = false"
    />
    <CreateWorktreeDialog
      v-if="showCreateWorktreeDialog"
      :initial-cwd="cwd"
      @create="onCreateWorktree"
      @close="showCreateWorktreeDialog = false"
    />
  </div>
</template>

<style scoped>
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.2s ease;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

:deep(.tool-output) {
  padding: 0.5rem 0.75rem;
  border-radius: 0.375rem;
  margin: 0.25rem 0;
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: 0.8125rem;
  line-height: 1.5;
}

:deep(.tool-stdout) {
  background-color: rgba(59, 130, 246, 0.1);
  border-left: 3px solid #3b82f6;
  color: var(--semantic-text);
}

:deep(.tool-stderr) {
  background-color: rgba(245, 158, 11, 0.1);
  border-left: 3px solid #f59e0b;
  color: var(--semantic-text);
}

:deep(.tool-success) {
  background-color: rgba(34, 197, 94, 0.1);
  border-left: 3px solid #22c55e;
  color: var(--semantic-text);
}

:deep(.tool-error) {
  background-color: rgba(239, 68, 68, 0.1);
  border-left: 3px solid #ef4444;
  color: var(--semantic-text);
}

:deep(.tool-tag) {
  font-weight: 600;
  margin-right: 0.5rem;
}

:deep(.file-path) {
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: 0.8125rem;
  padding: 0.25rem 0.5rem;
  background-color: rgba(139, 92, 246, 0.1);
  border-radius: 0.25rem;
  margin: 0.125rem 0;
  color: var(--semantic-text);
}

:deep(.search-file) {
  font-weight: 600;
  font-size: 0.875rem;
  color: var(--color-violet);
  margin-top: 0.5rem;
}

:deep(.search-line) {
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: 0.8125rem;
  padding: 0.125rem 0.5rem;
}

:deep(.line-num) {
  color: var(--semantic-text-dim);
  user-select: none;
  margin-right: 1rem;
  min-width: 3rem;
  display: inline-block;
}

:deep(.line-content) {
  white-space: pre-wrap;
  word-break: break-all;
}

:deep(.file-content) {
  margin-top: 0.25rem;
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: 0.8125rem;
  line-height: 1.5;
  background-color: rgba(0, 0, 0, 0.04);
  border-radius: 0.375rem;
  padding: 0.5rem 0;
  overflow-x: hidden;
}

:deep(.tool-sequence) {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

:deep(.tool-item) {
  padding: 0.25rem 0;
}

:deep(.tool-item-border) {
  border-bottom: 1px dashed var(--color-border);
  padding-bottom: 0.5rem;
}

:deep(.tool-item-border:last-child) {
  border-bottom: none;
  padding-bottom: 0;
}

/* Tool calls summary - shown only when tool outputs are NOT displayed */
:deep(.tool-calls-summary) {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.5rem;
  padding: 0.5rem 0.75rem;
  margin-bottom: 0.5rem;
  background-color: var(--color-bg-p1);
  border: 1px solid var(--color-border);
  border-radius: 0.5rem;
  border-left: 3px solid var(--color-violet);
}

:deep(.tool-calls-badge) {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  color: var(--color-violet);
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  font-family: var(--font-mono);
}

:deep(.tool-names-list) {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
}

:deep(.tool-name-chip) {
  display: inline-flex;
  align-items: center;
  padding: 0.125rem 0.5rem;
  background-color: var(--color-bg-p2);
  border: 1px solid var(--color-border-light);
  border-radius: 9999px;
  font-size: 0.75rem;
  font-family: var(--font-mono);
  color: var(--color-aqua);
}

:deep(.tool-inline) {
  font-size: 0.8rem;
  color: var(--color-violet);
  font-family: monospace;
}

:deep(.tool-inline-result) {
  font-size: 0.8rem;
  color: var(--semantic-text-dim);
  font-family: monospace;
}

:deep(.tool-inline-success) {
  color: var(--color-green);
  font-weight: 600;
}

:deep(.tool-inline-error) {
  color: var(--color-red);
  font-weight: 600;
}

:deep(.markdown-content pre) {
  overflow-x: auto;
}

:deep(.markdown-content pre:hover .code-copy-btn) {
  opacity: 1;
}
</style>
