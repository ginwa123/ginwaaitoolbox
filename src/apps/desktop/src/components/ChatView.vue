<script setup lang="ts">
import { ref, watch, onMounted, onUnmounted, nextTick, computed, inject, type Ref } from 'vue'
import { marked } from 'marked'
import * as api from '../api'
import { getThinkingTags, isThinkingTags, stripThinkingTags, VirtualScroller } from '@/helpers'
import {
  buildScrollContext,
  createScrollLogger,
  BOTTOM_THRESHOLD,
  TOP_THRESHOLD,
  type ScrollLogger,
} from '@/helpers'
import FileInput from './FileInput.vue'
import FolderExplorer from './FolderExplorer.vue'
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
import SkillsPopup from './SkillsPopup.vue'

const props = defineProps<{
  chatId: string
  chatName: string
  type?: 'chat' | 'task'
  cwd?: string
}>()

const emit = defineEmits<{
  'update-chat-id': [oldId: string, newId: string]
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

      if (tool_name === 'spawn_sub_agent') {
        const agentMatches = content.match(/<agent name="([^"]*)" success="([^"]*)">/g)
        const agentCount = agentMatches ? agentMatches.length : 0
        const summaryMatch = content.match(/<summary succeeded="(\d+)" failed="(\d+)" \/>/)
        const succeeded = summaryMatch ? summaryMatch[1] : '0'
        const failed = summaryMatch ? summaryMatch[2] : '0'
        return `<span class="tool-inline">${tool_name} → ${agentCount} agents (${succeeded} succeeded, ${failed} failed)</span>`
      }

      return `<span class="tool-inline">${tool_name || 'tool'} → ${escapeHtml(content)}</span>`
    }

    return escapeHtml(content)
  } catch {
    return escapeHtml(content)
  }
}

// Session ID extracted from props on mount
const sessionId = ref('')

// Inject processingState from App.vue (driven by SSE - always up-to-date)
const processingState = inject<Ref<Record<string, boolean>>>('processingState', ref({}))

// LLM processing state - derived reactively from App.vue's processingState
const isLLMProcessing = computed(() => !!processingState.value[sessionId.value])

// Pagination state
const messageCursor = ref<string | null>(null)
const PAGE_SIZE = 40

// SSE connection
const eventSource = ref<EventSource | null>(null)
const queueEventSource = ref<EventSource | null>(null)
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
const cwd = ref('')
const maxTotalTokens = ref(0)
const maxCapacityTotalTokens = ref(200000)

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
  if (!cwd.value) {
    gitStatus.value = null
    return
  }
  try {
    const status = await api.getGitStatus(cwd.value)
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

// ─── Bubble Visibility ────────────────────────────────────────────────────────
// Check if a message group has any visible content for its bubble.
// Hides empty bubbles (e.g., a user message with no text and no images,
// or an assistant message with no content and no tool-call header).
const hasBubbleContent = (group: MessageGroup, groupIndex: number): boolean => {
  if (group.role === 'user') {
    const first = group.messages[0]
    const hasImages = (first?.image_urls?.length ?? 0) > 0
    const hasContent = (first?.content?.trim() ?? '').length > 0
    return hasImages || hasContent
  }
  if (group.role === 'tool') {
    return group.messages.length > 0
  }
  if (group.role === 'assistant') {
    const hasToolHeader = groupToolNames.value[groupIndex] !== null
    const hasContent = group.messages.some((m) => (m.content?.trim() ?? '').length > 0)
    return hasToolHeader || hasContent
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
  // log exactly which one blocked. Order matters: the LLM
  // processing check is first because that's the most common
  // cause of "I scrolled to the top during streaming and nothing
  // loaded" — it's a deliberate UX decision, not a bug.
  if (isLLMProcessing.value) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleLoadMore',
      reason: 'load-more-suppressed',
      extra: { guard: 'isLLMProcessing', source: 'ChatView' },
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
  scrollLogger.info({
    ...ctx,
    caller: 'handleLoadMore',
    reason: 'load-more-threshold-reached',
    extra: {
      hasMore: hasMoreMessages.value,
      loadMoreThreshold: 200, // mirrors the prop on <VirtualScroller>
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

const handleVirtualScroll = (_scrollTop: number, _direction: 'up' | 'down') => {
  const container = virtualScrollerRef.value?.containerRef.value
  if (!container) return
  const { scrollTop, scrollHeight, clientHeight } = container
  const distanceFromBottom = scrollHeight - scrollTop - clientHeight
  const distanceFromTop = Math.max(0, scrollTop)
  const newIsAtBottom = distanceFromBottom < BOTTOM_THRESHOLD
  const newIsAtTop = distanceFromTop < TOP_THRESHOLD
  const previousIsAtBottom = isAtBottom.value
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
  // State transitions are loud: this is the most useful line in the
  // whole logger. "User was at bottom, scrolled up 200px" vs
  // "Auto-stick fired, isAtBottom is true again" are the two events
  // that answer every "why did the chat jump?" question.
  if (newIsAtBottom !== previousIsAtBottom) {
    scrollLogger.info({
      ...ctx,
      caller: 'handleVirtualScroll',
      reason: newIsAtBottom ? 'reached-bottom' : 'left-bottom',
      extra: {
        previousIsAtBottom,
        distanceFromBottom,
        threshold: BOTTOM_THRESHOLD,
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
}

// ─── SSE ─────────────────────────────────────────────────────────────────────

const isAlreadyConnectedSSE = ref(false)
const connectSse = () => {
  console.log('[connectSse] Connecting SSE for session:', sessionId.value)
  if (!sessionId.value) return

  if (isAlreadyConnectedSSE.value == false) disconnectSse()

  isStreaming.value = true
  streamingContent.value = ''

  eventSource.value = api.createSseConnection(
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
          finish_reason: event.finish_reason,
          tool_call_id: event.tool_call_id,
        })
        streamingContent.value = ''
        isStreaming.value = false
        scrollLogger.markProgrammatic()
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

  queueEventSource.value = api.createQueueMessagesSseConnection(
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
})

watch(
  () => messages.value.length,
  () => {
    scrollLogger.markProgrammatic()
    nextTick(() => scrollToBottom(false, 'messages-length'))
  },
)

watch(
  () => cwd.value,
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
    await api.sendChatMessage(currentSessionId, userMessage, cwd.value, imageUrls)
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
        <div
          v-if="isLoadingMore"
          class="absolute top-0 left-0 right-0 flex justify-center py-2 z-10 pointer-events-none"
        >
          <div
            class="flex items-center gap-2 px-4 py-2 rounded-full shadow-sm"
            style="background-color: var(--semantic-card-bg)"
          >
            <div
              class="w-4 h-4 border-2 rounded-full animate-spin"
              style="border-color: var(--color-violet); border-top-color: transparent"
            ></div>
            <span class="text-sm" style="color: var(--semantic-text-dim)">Loading more...</span>
          </div>
        </div>

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

        <!-- Virtualized Message List -->
        <VirtualScroller
          v-else
          ref="virtualScrollerRef"
          :items="messageGroups"
          :total-count="0"
          :buffer="3"
          :default-item-height="200"
          :load-more-threshold="200"
          :load-more-at-top="true"
          @load-more="handleLoadMore"
          @load-more-suppressed="handleLoadMoreSuppressed"
          @scroll="handleVirtualScroll"
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
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                            :cwd="cwd"
                          />
                          <WriteFile
                            v-else-if="msg.tool_name === 'write_file'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                            :cwd="cwd"
                          />
                          <UpdateActivity
                            v-else-if="msg.tool_name === 'update_activity'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <Search
                            v-else-if="msg.tool_name === 'search'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                            :cwd="cwd"
                          />
                          <Glob
                            v-else-if="msg.tool_name === 'glob'"
                            :content="msg.content"
                            :cwd="cwd"
                          />
                          <TextReplace
                            v-else-if="msg.tool_name === 'text_replace'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                            :diffview-before="msg.diffview_before"
                            :diffview-after="msg.diffview_after"
                            :cwd="cwd"
                          />
                          <Bash
                            v-else-if="msg.tool_name === 'bash' || msg.tool_name === 'run_command'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <GetSkill
                            v-else-if="msg.tool_name === 'get_skill'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <ViewSkill
                            v-else-if="msg.tool_name === 'view_skill'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <ListSkills
                            v-else-if="msg.tool_name === 'list_skills'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <AddSkill
                            v-else-if="msg.tool_name === 'add_skill'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <EditSkill
                            v-else-if="msg.tool_name === 'edit_skill'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <RemoveSkill
                            v-else-if="msg.tool_name === 'remove_skill'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
                          <RemoveFile
                            v-else-if="msg.tool_name === 'remove_file'"
                            :content="msg.content"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                            :cwd="cwd"
                          />
                          <SpawnSubAgent
                            v-else-if="msg.tool_name === 'spawn_sub_agent'"
                            :content="msg.content"
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
                      <div v-if="groupToolNames[groupIndex] !== null" >
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
                      <div class="assistant-messages">
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
                  <div
                    class="text-xs mt-1 px-1"
                    :class="group.role === 'user' ? 'text-right' : 'text-left'"
                    style="color: var(--semantic-text-dim)"
                  >
                    {{ formatTime(group.timestamp) }}
                  </div>
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
            <!-- Git status display -->
            <div
              v-if="gitStatus && gitStatus.is_git_repo"
              class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
              "
              :title="
                gitStatus.status === 'clean' ? 'Working tree clean' : 'Working tree has changes'
              "
            >
              <span>🌿</span>
              <span style="color: var(--semantic-text)">{{ gitStatus.branch || 'main' }}</span>
              <span v-if="!gitStatus.is_clean" style="color: var(--color-orange)">●</span>
              <span v-else style="color: var(--color-green)">✓</span>
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
    <Teleport to="body">
      <div v-if="previewImageUrl" class="image-preview-overlay" @click="closeImagePreview">
        <div class="image-preview-content" @click.stop>
          <button type="button" class="image-preview-close" @click="closeImagePreview">
            <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
          <img :src="previewImageUrl" alt="Preview" class="image-preview-img" />
        </div>
      </div>
    </Teleport>
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

:deep(.markdown-content pre) {
  overflow-x: auto;
}

:deep(.markdown-content pre:hover .code-copy-btn) {
  opacity: 1;
}

.image-preview-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background-color: rgba(0, 0, 0, 0.85);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 9999;
  padding: 20px;
}

.image-preview-content {
  position: relative;
  max-width: 90vw;
  max-height: 90vh;
  display: flex;
  flex-direction: column;
  align-items: center;
}

.image-preview-close {
  position: absolute;
  top: -40px;
  right: 0;
  background: none;
  border: none;
  color: white;
  cursor: pointer;
  padding: 8px;
  opacity: 0.7;
  transition: opacity 0.2s;
}

.image-preview-close:hover {
  opacity: 1;
}

.image-preview-img {
  max-width: 100%;
  max-height: calc(90vh - 60px);
  object-fit: contain;
  border-radius: 8px;
}
</style>
