<script setup lang="ts">
import { ref, watch, onMounted, onUnmounted, nextTick, computed, inject, type Ref } from 'vue'
import { marked } from 'marked'
import * as api from '../../api'
import { useChatScrollRestore } from '../../composables/useChatScrollRestore'
import { getThinkingTags, isThinkingTags, stripThinkingTags, isHtmlTags, VirtualScroller } from '@/helpers'
import {
  buildScrollContext,
  createScrollLogger,
  isAutoStickActive,
  AUTO_STICK_GATE_MS,
  BOTTOM_THRESHOLD,
  TOP_THRESHOLD,
  type ScrollLogger,
} from '@/helpers'
import FileInput from '../file/FileInput.vue'
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
import FolderExplorer from '../file/FolderExplorer.vue'
import { useSseBus } from '../../helpers/sseBus'
import { tryUnwrapToolOutput, type UnwrappedToolOutput } from '@/helpers/unwrapToolOutput'
import {
  applyProgressEvent,
  clearProgressFor,
  type SubAgentProgressEvent,
  type SubAgentProgressMap,
} from '../../helpers/subagentProgress'
import DiffView from '../tool_outputs/_shared/DiffView.vue'
import ReadFile from '../tool_outputs/ReadFile.vue'
import WriteFile from '../tool_outputs/WriteFile.vue'
import UpdateActivity from '../preview/UpdateActivity.vue'
import Search from '../tool_outputs/Search.vue'
import Glob from '../preview/Glob.vue'
import TextReplace from '../tool_outputs/TextReplace.vue'
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- used in <template> as <Bash> (~line 2507); typescript-eslint doesn't always see template usages via the Vue parser
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
import GenerateImage from '../tool_outputs/GenerateImage.vue'
import SetGitWorktree from '../tool_outputs/SetGitWorktree.vue'
import ReadCompactedMessages from '../tool_outputs/ReadCompactedMessages.vue'
import KanbanMove from '../tool_outputs/KanbanMove.vue'
import KanbanList from '../tool_outputs/KanbanList.vue'
import ListDirectory from '../tool_outputs/ListDirectory.vue'
import SaveMemory from '../tool_outputs/SaveMemory.vue'
import LoadMemory from '../tool_outputs/LoadMemory.vue'
import UpdatePlan from '../tool_outputs/UpdatePlan.vue'
import GetPlan from '../tool_outputs/GetPlan.vue'
import ShowPreview from '../tool_outputs/ShowPreview.vue'
import SearchHistory from '../tool_outputs/SearchHistory.vue'
import PreviewSidePanel from '../preview/PreviewSidePanel.vue'
import SubAgentPeekPanel from '../nalar/SubAgentPeekPanel.vue'
import { usePreviewDisplayMode } from '@/composables/usePreviewDisplayMode'
import { useNavigationStore } from '../../stores/navigation'
import { useSubAgentPeek } from '../../composables/useSubAgentPeek'
import { useInjectOpenInCodeEditor } from '@/composables/useCodeEditor'
import { useRouter } from 'vue-router'
import CompactionCard from '../preview/CompactionCard.vue'
import SkillsPopup from '../preview/SkillsPopup.vue'
import ImagePreview from '../preview/ImagePreview.vue'
import WorktreeMenu from '../workspace/WorktreeMenu.vue'
import CreatePrDialog from '../dialogs/CreatePrDialog.vue'
import CreateWorktreeDialog from '../dialogs/CreateWorktreeDialog.vue'
import { parseSpawnSubAgentArgs } from '../../helpers/parseSpawnSubAgentArgs'
import type { SubAgentArgs } from '../../helpers/parseSpawnSubAgentArgs'

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
  /**
   * JSON-stringified tool input arguments (e.g. for `show_preview`:
   * `{content_type, content, title, language, caption}`). Populated
   * by the same `tryUnwrapToolOutput` pipeline that fills
   * `unwrappedByMessageId`. Used by `PreviewSidePanel` to render
   * rich previews without re-fetching.
   */
  parameters?: string,
  is_input?: boolean,
  is_output?: boolean,
  /**
   * 2026-08-23 hidden-messages fix — thinking models' chain-of-thought
   * returned by the LLM and stored in `llm_history.reasoning_content`.
   * Populated by loadChatHistory (REST) and the SSE `full` handler.
   * Rendered as a collapsible section in the assistant bubble; also
   * keeps reasoning-only turns alive in filteredMessages.
   */
  reasoning_content?: string,
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
    const container = virtualScrollerRef.value?.containerRef
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
  // eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
  diffviewBefore?: string,
  // eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
  diffviewAfter?: string,
  // eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
  finish_reason?: string,
  // eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
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

      // Collapsed-bubble summary for the inline tool pill in ChatView.
      // Mirrors the structured ListDirectory.vue card so users see the
      // same info (path + entry count) whether they look at the
      // collapsed bubble or the expanded body. The wire shape is
      // `<directory_listing path="..." count="N">...</directory_listing>`
      // (see src/modules/agent/tools/list_directory.zig).
      if (tool_name === 'list_directory') {
        const errorMatch = content.match(/<error>([\s\S]*?)<\/error>/)
        if (errorMatch) {
          return `<span class="tool-inline">${tool_name} → ${escapeHtml(errorMatch[1]?.trim() || 'error')}</span>`
        }
        const pathMatch = content.match(/<directory_listing\s[^>]*\bpath="([^"]+)"/)
        const countMatch = content.match(/<directory_listing\s[^>]*\bcount="(\d+)"/)
        const dirPath = pathMatch?.[1] ?? 'unknown'
        const dirCount = countMatch?.[1] ?? '0'
        const plural = dirCount === '1' ? 'entry' : 'entries'
        return `<span class="tool-inline">${tool_name} → ${escapeHtml(dirPath)} (${dirCount} ${plural})</span>`
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

      if (tool_name === 'update_plan') {
        // Collapsed-bubble summary for the inline tool pill in ChatView.
        // Mirrors the structured UpdatePlan.vue card so users see "wrote
        // N bytes" whether they look at the collapsed bubble or expand
        // the structured card. We approximate the byte count from the
        // envelope's `<updated_at>` timestamp + the presence of
        // `<session_id>` — the raw `content` argument isn't the LLM's
        // input, so we can't show the exact byte count without
        // threading the tool-call params through; the byte count from
        // the plan body would require re-unwrapping, so we settle for
        // a length-derived estimate from the inner envelope.
        const updateError = content.match(/<error>([\s\S]*?)<\/error>/)
        if (updateError && updateError[1]) {
          return `<span class="tool-inline">${tool_name} → ${escapeHtml(updateError[1].trim()) || 'error'}</span>`
        }
        // Estimate byte count from the inner envelope length as a
        // rough "how big was this plan write" signal. We pull the
        // inner envelope (stripping both <tool> and <update_plan>
        // wrappers) so the number reflects the actual content, not
        // the XML envelope chrome.
        const innerPlanMatch = content.match(/<update_plan>([\s\S]*?)<\/update_plan>/)
        const innerBytes = innerPlanMatch?.[1]?.length ?? 0
        return `<span class="tool-inline">${tool_name} → wrote ${innerBytes}b of plan</span>`
      }

      if (tool_name === 'get_plan') {
        // Collapsed-bubble summary for the inline tool pill in ChatView.
        // Mirrors the structured GetPlan.vue card so users see "fetched
        // current plan · N items" whether they look at the collapsed
        // bubble or expand the structured card.
        const getError = content.match(/<error>([\s\S]*?)<\/error>/)
        if (getError && getError[1]) {
          return `<span class="tool-inline">${tool_name} → ${escapeHtml(getError[1].trim()) || 'error'}</span>`
        }
        // No-plan sentinel: <get_plan><empty/></get_plan>
        if (/<empty\s*\/?>/.test(content)) {
          return `<span class="tool-inline">${tool_name} → no plan set</span>`
        }
        // Count `- [ ]` / `- [x]` items in the CDATA-wrapped body for
        // the "N items" hint. We strip the CDATA wrappers first so we
        // only match checklist markers, not any literal `[ ]` text
        // inside non-checklist prose.
        const cdataMatch = content.match(/<!\[CDATA\[([\s\S]*?)\]\]>/)
        const cdata = cdataMatch?.[1] ?? ''
        const itemMatches = cdata.match(/^- \[(x| )\]\s+/gim)
        const itemCount = itemMatches?.length ?? 0
        const itemLabel = itemCount === 1 ? 'item' : 'items'
        return `<span class="tool-inline">${tool_name} → fetched current plan${itemCount > 0 ? ` · ${itemCount} ${itemLabel}` : ''}</span>`
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

// ─── <html> wrapper-tag rendering (2026-08-23 html-tag-support) ────────────
// When the LLM wraps raw HTML in <html>...</html>, the chat UI renders
// each block as a live sandboxed iframe (null origin — the security
// boundary; inner scripts can't touch parent DOM/cookies). Mirrors the
// proven PreviewContentRenderer.vue pattern (sandbox="allow-scripts").

interface HtmlSegment {
  /** Text before this html block (markdown-rendered inline). */
  before: string
  /** Inner payload of the <html>...</html> block (goes into srcdoc). */
  html: string
}

/** True when the message contains at least one closed <html> block. */
const msgHasHtml = (content: string | undefined): boolean => {
  if (!content) return false
  return isHtmlTags(content) || /<html>[\s\S]*?<\/html>/i.test(content)
}

/**
 * Split a message into segments: for each closed <html>...</html> block,
 * one segment carrying (a) the markdown text preceding it and (b) the
 * block's inner HTML. Trailing text after the last block is attached to
 * a final segment with html=''. Unclosed tags mid-stream match nothing
 * and fall through to the legacy v-html path (raw text until close).
 */
const extractHtmlBlocks = (content: string): HtmlSegment[] => {
  const segments: HtmlSegment[] = []
  const regex = /<html>([\s\S]*?)<\/html>/gi
  let lastIndex = 0
  let match: RegExpExecArray | null
  while ((match = regex.exec(content)) !== null) {
    const before = content.slice(lastIndex, match.index)
    const inner = match[1] ?? ''
    if (before.trim() || segments.length === 0) {
      segments.push({ before: before.trim(), html: inner })
    } else {
      // Consecutive blocks: attach empty `before` to keep pairing.
      segments.push({ before: '', html: inner })
    }
    lastIndex = regex.lastIndex
  }
  const tail = content.slice(lastIndex).trim()
  if (tail || segments.length === 0) {
    segments.push({ before: tail, html: '' })
  }
  return segments
}

/**
 * Build the srcdoc document for an html block. Full documents pass
 * through verbatim; fragments get wrapped in a minimal shell with sane
 * defaults (margin, system font, white background).
 */
const buildHtmlSrcdoc = (block: string): string => {
  const trimmed = block.trim()
  if (/<!doctype html|<html[\s>]/i.test(trimmed)) {
    return trimmed
  }
  return (
    '<!DOCTYPE html><html><head><meta charset="utf-8">' +
    '<style>body{margin:8px;font-family:system-ui,sans-serif;background:#fff;color:#111}</style>' +
    '</head><body>' +
    trimmed +
    '</body></html>'
  )
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

// ── Sub-agent peek ────────────────────────────────────────────────
// Owns the slide-over panel for watching a single sub-agent's
// progress. The composable is only mounted when `peekPanel` is
// non-null (lazy) so we don't open SSE channels speculatively.
//
// Two flows reach the panel:
//   1. 👁 click on a <SpawnSubAgent> row  →  SpawnSubAgent emits
//      `peek`  →  ChatView calls `nav.openPeek(payload)`. The
//      composable mounts on the next render.
//   2. "Open full" in the panel  →  panel emits `openFull(sid)`
//      →  ChatView closes the peek + navigates the URL to switch
//      the main chat view to the sub-agent's session.
const nav = useNavigationStore()
const router = useRouter()

// Lazy: only call useSubAgentPeek when a panel is open (otherwise
// the composable's onMounted would fire a fetch unconditionally).
const peek = computed(() => {
  const payload = nav.peekPanel
  if (!payload) return null
  return useSubAgentPeek({
    sessionId: payload.sessionId,
    agentName: payload.agentName,
    instruction: payload.instruction,
  })
})

/**
 * Handler for the panel's `openFull` event — closes the peek and
 * navigates to the sub-agent's own chat view in the main panel.
 */
function onPeekOpenFull(sessionId: string) {
  nav.closePeek()
  router.replace({ path: '/app', query: { view: 'chat', session: sessionId } })
}

// SSE connection. Both the `llm` and `queue` channels now flow
// through the global `sseBus` (opened once by App.vue). The bus's
// single global SseClient carries ALL 5 channels (including bare
// 'llm' and bare 'queue'). Listeners here filter by
// `event.session_id === sid` on the JS side — defense-in-depth
// against backend routing regressions. The same listener filter
// would also be needed in a future multi-tab scenario where
// multiple ChatViews share one EventSource.
const isStreaming = ref(false)
const streamingContent = ref('')

// Queue state
const queuedMessages = ref<api.QueuedMessage[]>([])

// Scroll refs
// We declare an explicit interface for the VirtualScroller instance because
// `InstanceType<typeof VirtualScroller>` doesn't resolve cleanly for a generic
// Vue SFC component (the compiler infers a function signature that doesn't
// satisfy Vue's component-ref constructor constraint).
//
// Note: `containerRef` and the `isX`/`effectiveX` refs are AUTO-UNWRAPPED
// by `defineExpose` — the exposed property is the ref's `.value`, not
// the ref object. The existing `handleVirtualScroll` reads
// `.containerRef.value` (double-unwrapped, which returns undefined);
// it falls back to the event `target` so the bug is invisible. The
// scroll-restore composable reads `.containerRef` directly.
interface VirtualScrollerExposed {
  scrollToIndex: (index: number, behavior?: ScrollBehavior) => void
  scrollToTop: (behavior?: ScrollBehavior) => void
  scrollToBottom: (behavior?: ScrollBehavior) => void
  scrollToPosition: (scrollTop: number, behavior?: ScrollBehavior) => void
  scrollToItem: (index: number, behavior?: ScrollBehavior) => void
  beginPreserve: (newItemsCount: number) => void
  endPreserve: () => Promise<void>
  preserveScrollPosition: () => Promise<void>
  containerRef: HTMLElement | null
  isPreservingScroll: boolean
  effectiveLoadMoreThreshold: number
}
const virtualScrollerRef = ref<VirtualScrollerExposed | null>(null)

// Persist chat scroll position per-task across mount/unmount. The
// composable attaches its own scroll/scrollend listeners to the
// VirtualScroller's container ref (via the computed `scrollerContainerRef`
// below) and flushes pending writes on unmount. The storage key is
// `chat-scroll-<taskId>` — same identity as the session id per the
// project's task.id == session.id convention (migration 052).
//
// Note: `virtualScrollerRef.value.containerRef` is the HTMLElement
// directly (NOT a ref object), because `defineExpose` in
// VirtualScroller.vue auto-unwraps refs. The existing code in
// `handleVirtualScroll` reads `.containerRef.value` (double-unwrapped),
// which silently returns undefined — the code falls back to the
// event `target` so the bug is invisible. Don't copy that pattern.
const scrollerContainerRef = computed<HTMLElement | null>(
  () => virtualScrollerRef.value?.containerRef ?? null,
)
const chatScrollStorageKey = computed(() => `chat-scroll-${sessionId.value || props.chatId}`)
const chatScrollRestore = useChatScrollRestore(scrollerContainerRef, chatScrollStorageKey)

// Guard flag for the messages-length watcher's auto-stick. During
// the initial load, the loadChatHistory branch handles the scroll
// explicitly (either restore a saved position via scrollToPosition
// or land at the bottom via scrollToBottom). Without this guard,
// the watcher would yank the user back to the bottom immediately
// after the restore — defeating the feature.
let isInitialLoad = false

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
  const container = virtualScrollerRef.value?.containerRef
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
  const container = virtualScrollerRef.value?.containerRef
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

// Preview side panel: derived list + UI state. The panel subscribes to
// every tool message whose `tool_name === 'show_preview'`. It defaults
// to COLLAPSED (renders as a small `w-8` tab on the right edge) so the
// chat view stays focused on messages — auto-opening the panel every
// time the assistant produces a `show_preview` was disruptive and hid
// the chat. The user explicitly opens it either by:
//
//   1. Clicking the collapsed tab (which expands it via the
//      `v-model:collapsed` binding), or
//   2. Clicking a `show_preview` tool message bubble in the chat
//      (handled by `openPreviewForMessage` below, which both
//      un-collapses and sets `previewToShowId` to jump to that tab).
//
// The user can dismiss the panel entirely with the ✕ button (sets
// `previewPanelDismissed = true`, mounts the panel). The wrapper has its
// own `v-if="previews.length > 0"` so the panel disappears when the
// filtered list is empty.
const showPreviewMessages = computed(() =>
  messages.value.filter((m) => m.tool_name === 'show_preview' && m.is_output === true)
)
const previewPanelCollapsed = ref(true)
const previewPanelDismissed = ref(false)
// When the user clicks a `show_preview` message bubble in the chat,
// this gets set to the bubble's `msg.id`. The PreviewSidePanel
// uses this to jump to that preview's tab. We DO NOT auto-clear
// it on next-render — keeping it set lets the user click the
// same bubble repeatedly and reliably re-jump the panel to it.
// It's cleared by ChatView's `watch(() => props.chatId)` reset
// (avoids stale focus id from the previous chat dictating the
// new chat's panel tab).
const previewToShowId = ref<string | null>(null)

// ─── Display mode (user-controlled sidebar/inline toggle, 2026-08-06) ──
//
// The user picks between two rendering modes for `show_preview` outputs
// via the PreviewSidePanel header toggle (when the panel is visible)
// or the ChatView restore button (when in inline mode + panel hidden).
// Default: 'side' (matches existing behaviour).
//
// When the mode is 'inline':
//   - We hide the side panel by setting `previewPanelDismissed = true`.
//     The user's existing dismiss preference is preserved so we can
//     restore it when they switch back to 'side'.
//   - ShowPreview cards render rich content directly inside the chat
//     bubble (see ShowPreview.vue).
//
// When the mode is 'side':
//   - The side panel's visibility follows the user's normal
//     collapsed/dismissed state. We do NOT auto-show the panel just
//     because they flipped to 'side' — if they had explicitly
//     dismissed it before, it stays dismissed until they click the
//     toggle or restore button.
const { isInline, setMode } = usePreviewDisplayMode()
const previewPanelWasDismissedBeforeInline = ref(false) // remember user intent

watch(isInline, (nowInline) => {
  if (nowInline) {
    // Switching INTO inline mode: remember whether the user had
    // explicitly dismissed the panel, then dismiss it for the
    // duration of inline mode.
    previewPanelWasDismissedBeforeInline.value = previewPanelDismissed.value
    previewPanelDismissed.value = true
  } else {
    // Switching back to side mode: restore the user's previous
    // dismiss preference. If they had explicitly dismissed before,
    // leave it dismissed; otherwise the panel becomes visible again.
    previewPanelDismissed.value = previewPanelWasDismissedBeforeInline.value
  }
}, { immediate: true })

// Click handler for `show_preview` message bubbles in the chat.
// The bubble is rendered *collapsed* (no expand toggle — that would
// make the user click twice: once to expand, once to view). Instead,
// the click directly opens the right-side preview panel, jumping to
// the preview that corresponds to the clicked message id. This is
// the ONLY path that un-collapses the panel automatically; new
// previews arriving in the chat do NOT auto-open it (see comment
// block above).
const openPreviewForMessage = (msgId: string) => {
  previewPanelCollapsed.value = false
  previewPanelDismissed.value = false
  previewToShowId.value = msgId
}

watch(
  () => props.chatId,
  () => {
    // Switching chats clears `previewToShowId` so a stale focus id from
    // the previous chat doesn't dictate the new chat's panel tab. We
    // intentionally do NOT touch `previewPanelCollapsed` or
    // `previewPanelDismissed` here — the user's expanded/collapsed
    // preference persists across chats (consistent with the
    // "auto-open is opt-in, via the click handler" policy).
    previewToShowId.value = null
  },
)
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
const sessionCwd = ref('')
// Bound git worktree path (empty string when no worktree is bound).
// Updated by loadChatHistory() from the API response and by the
// sessions SSE stream when the LLM calls set_git_worktree.
const gitWorktreeCwd = ref('')
// The cwd we run git status against. Prefers the worktree when set
// (so the branch display reflects the worktree's branch, not the
// session's original cwd). Falls back to the session's original cwd.
const effectiveCwd = computed(() => gitWorktreeCwd.value || sessionCwd.value)
const maxTotalTokens = ref(0)
const maxCapacityTotalTokens = ref(200000)

// ─── Profile selection ────────────────────────────────────────────────────────
// Per-session model selection. The chip in the status bar shows the EFFECTIVE
// profile (per-session `selected_profile_model` → `config.active_profile` →
// top-level default) and lets the user pick a profile from the list in
// NalarConfig. Per-session selection is persisted via PUT
// /api/llm/session/:id and forwarded to the next LLM call via POST
// /api/llm/session. The chip mirrors the backend cascade in
// `workflow.zig::resolveProfileField` so the user sees the same name that's
// actually applied.
const availableProfiles = ref<Array<{ name: string; model: string; base_url: string }>>([])
const selectedProfile = ref<string | null>(null)
/// User-chosen default profile from NalarSettings → Profiles → "Set active".
/// `null` when no profile is marked active (or no profiles configured). The
/// chatview shows this as the chip's effective selection when no per-session
/// override is set. See plan docs/superpowers/plans/2026-08-06-chatview-profile-cascade-display.md.
const activeProfile = ref<string | null>(null)
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
    // `active_profile` is the user-chosen default from NalarSettings. Empty
    // string → null (matches the backend's PUT coercion in
    // `nalar_config_put.zig`).
    const raw = (config as { active_profile?: string | null }).active_profile
    activeProfile.value = raw && raw.length > 0 ? raw : null
  } catch (err) {
    console.error('Failed to load profiles:', err)
    availableProfiles.value = []
    activeProfile.value = null
  }
}

/// Effective profile the chip / picker reflect — mirrors the backend cascade
/// in `workflow.zig::resolveProfileField`. `selectedProfile` wins; if the
/// user has not picked one for this session, `activeProfile` (the
/// NalarSettings "Set active" default) applies; otherwise the chip shows
/// "Default" and the backend uses the top-level config.
///
/// NOTE: we use `||` (not `??`) so an empty string from the session's
/// `selected_profile_model` falls through to the active profile. `??` only
/// catches `null` / `undefined`, but the per-session value arrives as `""`
/// (empty string) when the user never picked one — see
/// `api.getSession.selectedProfile` which returns the raw string. Falling
/// through `||` makes the empty-string case match the cascade.
const effectiveProfile = computed<string | null>(() => {
  const sel = selectedProfile.value
  if (sel && sel.length > 0) return sel
  return activeProfile.value
})

/// Tooltip text reflecting what the backend will actually use. Distinguishes
/// "explicit per-session choice" from "defaulted to active profile" so the
/// user understands the cascade.
const profileChipTooltip = computed(() => {
  const sel = selectedProfile.value
  if (sel && sel.length > 0) return `Using profile: ${sel}`
  if (activeProfile.value) return `Using active profile: ${activeProfile.value}`
  return 'Using default (top-level config)'
})

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
  const path = gitWorktreeCwd.value || sessionCwd.value
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
  // Uses sessionCwd.value (the session's ORIGINAL cwd) so the LLM's context
  // matches the session it was started from.
  if (!sessionId.value) return
  try {
    await api.sendChatMessage(
      sessionId.value,
      'Please call set_git_worktree with clear=true to remove the current worktree binding.',
      sessionCwd.value,
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
  if (!sessionCwd.value) {
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
      sessionCwd.value,
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

// Track which tool items are expanded.
//
// 2026-08-23 auto-collapse fix — keys are STABLE per-message ids, NOT
// positional `${groupIndex}-${idx}` pairs. Positional keys broke the
// moment any SSE event mutated `messages`: messageGroups recomputes,
// group/message indices shift (a new assistant row inserts a group
// before the tool rows; dedupe/hidden-row filtering changes counts),
// and every stored key silently started pointing at a DIFFERENT card.
// The user's manually-expanded card lost its key → collapsed itself;
// worse, an unrelated card could render pre-expanded. Message ids are
// stable across re-computation (DB nanos from REST history, or the
// synthetic-but-consistent ids minted by the SSE handler), so
// expansion survives any number of live updates.
const expandedToolIds = ref<Set<string>>(new Set())

// 2026-08-23 spawn-subagent-live-progress: per-tool_call_id map of
// sub-agent progress rows. Fed by role="subagent_progress" SSE events
// on the existing `llm` bus channel (no new event_type). The map
// entry is cleared once the parent's final <results> tool result
// arrives so the parsed-envelope view takes over rendering.
const subAgentProgressMap = ref<SubAgentProgressMap>({})

// Image preview state
const previewImageUrl = ref<string | null>(null)

const openImagePreview = (url: string) => {
  previewImageUrl.value = url
}

const closeImagePreview = () => {
  previewImageUrl.value = null
}

// Toggle expanded state for a tool item. Keyed by the message's stable
// id (see expandedToolIds above) — never by position, which shifts on
// every SSE-driven recompute of messageGroups.
const toggleToolExpanded = (msgId: string) => {
  const newSet = new Set(expandedToolIds.value)
  if (newSet.has(msgId)) {
    newSet.delete(msgId)
  } else {
    newSet.add(msgId)
  }
  expandedToolIds.value = newSet
}

// Stable expand-state key for a tool message. Falls back through:
//   1. msg.id (DB nanos id or SSE-minted synthetic id — always present)
//   2. tool_call_id (stable across the whole turn)
//   3. positional `${groupIndex}-${idx}` — last resort for legacy rows
//      with no id at all; better than nothing, same behaviour as before.
const toolExpandKey = (msg: Message, groupIndex: number, idx: number): string => {
  return msg.id || msg.tool_call_id || `pos-${groupIndex}-${idx}`
}

// Code-editor wiring for the fallback `<DiffView>` rendered for tools that
// don't have a dedicated component (e.g. legacy tools). When the user clicks
// a line number in the fallback diff we forward to the in-app editor — but
// only when we know the target file path. We don't have a stable path here
// (the fallback is rendered for any tool with diffview_*), so we silently
// no-op when the path is missing. Most tools with diff content now route
// through the dedicated `<TextReplace>` component (which knows the path);
// this fallback is for legacy/edge cases.
const fallbackOpenInEditor = useInjectOpenInCodeEditor()
const handleFallbackJumpToLine = (line: number) => {
  // No-op: we don't have a target file path in the fallback context.
  // The click affordance still works (hover/cursor change), but won't
  // open the editor. Hook retained for future enhancement when we add a
  // generic tool→path lookup.
  void fallbackOpenInEditor
  void line
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

// Filter out empty messages for display (check stripped content).
//
// 2026-08-23 hidden-messages fix — three exemptions ADDED to the
// original "drop if stripThinkingTags(content) is empty" rule:
//
//   1. `image_urls` populated → KEEP. A user message with attached
//      images but no text (content='') was permanently invisible:
//      it was dropped HERE, before hasBubbleContent's image check
//      (line ~1289) could ever see it. The images exist; show them.
//
//   2. `role === 'tool'` → KEEP. Tool result rows are rendered by
//      structured components (ReadFile, Bash, ...) that parse their
//      own envelope from content — several tools legitimately carry
//      whitespace-only or empty raw content while still rendering a
//      meaningful card. Dropping them here broke the tool sequence.
//
//   3. `reasoning_content` present → KEEP. Thinking models can emit
//      reasoning with an empty final text body; the message is not
//      empty, and the assistant bubble now renders a collapsible
//      reasoning section for it (see template, assistant branch).
const filteredMessages = computed(() =>
  messages.value.filter((m) => {
    // Always keep tool_calls messages even if content is only thinking tags
    if (m.finish_reason === 'tool_calls') return true
    // 2026-08-23: image-only user messages must survive the filter —
    // hasBubbleContent renders their images downstream.
    if ((m.image_urls?.length ?? 0) > 0) return true
    // 2026-08-23: tool results render via dedicated components; never
    // drop them on empty stripped content.
    if (m.role === 'tool') return true
    // 2026-08-23: thinking-only assistant turns (reasoning_content set,
    // final text empty) still have visible content once the reasoning
    // section renders.
    if (m.role === 'assistant' && m.reasoning_content && m.reasoning_content.trim() !== '') {
      return true
    }
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

  // 2026-08-23 blank-block fix — drop groups with nothing renderable
  // BEFORE the VirtualScroller ever sees them. The previous approach
  // (v-if inside the slot) left empty groups in the items array, where
  // their height stayed at the scroller's 200px ESTIMATE forever
  // (measureItems only measures rendered children). The estimated total
  // then far exceeded the real content height, and scrollToBottom —
  // which trusts the estimate — landed the visible window PAST all real
  // items: a fully blank chat. Filtering here keeps the scroller's item
  // list in sync with what actually renders; hasBubbleContent in the
  // template remains as defense-in-depth.
  return groups.filter((g, i) => hasBubbleContent(g, i))
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
// assistant turn that triggered tool calls BUT the tool outputs are NOT shown
// anywhere in the transcript. When tool outputs ARE shown (same group is tool,
// next group is tool, OR a later non-adjacent tool row carries a matching
// tool_call_id) we return null — the structured tool card already conveys
// what was called.
//
// 2026-08-23 stray-TOOLS-pill fix — the previous adjacency check
// (`messageGroups[i+1]?.role === 'tool'`) flashed a pill during the
// live-SSE window between the assistant tool_calls row arriving and
// the tool result row arriving. Worse, it could persist wrongly if
// the tool group was later collapsed / dropped / merged by
// filteredMessages or hasBubbleContent. Now we walk the WHOLE
// transcript for matching tool_call_ids — robust against ordering,
// merging, and live SSE interleaving.
const groupToolNames = computed((): (string | null)[] => {
  // Pre-collect every tool_call_id that has a matching tool row in the
  // transcript. The id set is the single source of truth for "is this
  // tool call already represented by a structured card?".
  const renderedToolCallIds = new Set<string>()
  for (const g of messageGroups.value) {
    if (g.role !== 'tool') continue
    for (const m of g.messages) {
      if (m.tool_call_id) renderedToolCallIds.add(m.tool_call_id)
    }
  }

  return messageGroups.value.map((group, i) => {
    if (group.role !== 'assistant') return null

    // Same-group tool rows (rare but possible when an assistant message
    // carries tool_calls_json AND a tool result) → no pill needed.
    const nextGroup = messageGroups.value[i + 1]
    if (nextGroup?.role === 'tool') {
      return null
    }

    // Look for any message in this assistant group whose tool_calls_json
    // either already has a matching tool row OR yields parseable names.
    for (const msg of group.messages) {
      if (msg.tool_calls_json?.trim()) {
        try {
          const parsed = JSON.parse(msg.tool_calls_json)
          // tool_calls_json IS the array directly: [{id, type, function: {name}}]
          if (Array.isArray(parsed) && parsed.length > 0) {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
            const names = parsed.map((tc: any) => tc.function?.name || tc.name || 'unknown')

            // If EVERY tool call in this group already has a rendered
            // tool row somewhere in the transcript, the structured cards
            // are the source of truth — suppress the pill entirely.
            // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; tool_calls_json shape is intentionally opaque.
            const allRendered = parsed.every((tc: any) => {
              const id = tc?.id
              return typeof id === 'string' && renderedToolCallIds.has(id)
            })
            if (allRendered) return null

            return names.join(', ')
          }
        } catch {}
      }

      // finish_reason set but tool_calls_json missing/unparseable.
      // Only show the "..." pill when the tool call is NOT yet
      // represented by a rendered tool row (otherwise the live SSE
      // window between tool_calls and tool_result would flash a stray
      // pill that immediately gets replaced by a structured card).
      if (msg.finish_reason === 'tool_calls') {
        // We can't match by id here (tool_calls_json is missing), so
        // fall back to the adjacency heuristic: if a tool group
        // appears ANYWHERE in the transcript after this group, the
        // tool call was rendered → no pill.
        let hasLaterTool = false
        for (let j = i + 1; j < messageGroups.value.length; j++) {
          if (messageGroups.value[j]?.role === 'tool') {
            hasLaterTool = true
            break
          }
        }
        if (hasLaterTool) return null
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
//
// 2026-08-23 hidden-messages fix — the user branch previously checked
// ONLY group.messages[0]; with consecutive user messages (queue-drain
// bursts) the 2nd+ messages were invisible even when non-empty. Now
// ANY message in the group having images, visible text, or reasoning
// keeps the bubble alive.
const hasBubbleContent = (group: MessageGroup, groupIndex: number): boolean => {
  if (group.role === 'user') {
    return group.messages.some(
      (m) =>
        (m.image_urls?.length ?? 0) > 0 ||
        hasVisibleContent(m) ||
        !!(m.reasoning_content && m.reasoning_content.trim() !== ''),
    )
  }
  if (group.role === 'tool') {
    return group.messages.length > 0
  }
  if (group.role === 'assistant') {
    const hasToolHeader = groupToolNames.value[groupIndex] !== null
    const hasReasoning = group.messages.some(
      (m) => m.reasoning_content && m.reasoning_content.trim() !== '',
    )
    return hasToolHeader || hasReasoning || group.messages.some(hasVisibleContent)
  }
  return false
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
      sessionCwd.value = data.cwd
    }

    if (!loadMore && data.git_worktree_cwd !== undefined) {
      gitWorktreeCwd.value = data.git_worktree_cwd
    }

    // 2026-08-07-profile-persist-read — load the persisted profile
    // selection from the messages endpoint response. The watch on
    // sessionId.value (below) ALSO reads it from getSession() (which
    // calls the same endpoint), but the watch is `immediate: false`
    // and races with loadChatHistory on initial mount. Reading it here
    // is the authoritative source: whichever finishes first, the value
    // is the same. The watch's later update will agree and not clobber.
    if (!loadMore && data.selected_profile_model !== undefined) {
      selectedProfile.value = data.selected_profile_model || null
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
      is_input: msg.is_input,
      is_output: msg.is_output,
      // 2026-08-23 hidden-messages fix — carry the thinking model's
      // reasoning through to the renderer. The backend REST endpoint
      // already returns it (http_response.zig SessionMessage).
      reasoning_content: msg.reasoning_content || undefined,
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
      const containerBefore = virtualScrollerRef.value?.containerRef
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
      const containerAfter = virtualScrollerRef.value?.containerRef
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
      // Initial load path. Set isInitialLoad BEFORE the messages
      // assignment so the messages-length watcher's sync callback
      // sees the flag and skips its own scrollToBottom (which would
      // yank the user back to the bottom right after we restore a
      // saved position).
      isInitialLoad = true
      try {
        messages.value = newMessages.slice().reverse()
        messageCursor.value = data.next_cursor
        hasMoreMessages.value = data.has_more

        const initialContainer = virtualScrollerRef.value?.containerRef
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

        // Try to restore the user's previous scroll position (set by
        // useChatScrollRestore when they last closed this task). If
        // no saved position exists OR the saved position is "near
        // bottom" (within BOTTOM_THRESHOLD_PX of max), restore()
        // returns null and we fall through to the existing
        // scrollToBottom behavior. This is the chat-specific
        // counterpart of the kanban composable's restore-on-mount
        // path.
        const savedScrollTop = chatScrollRestore.restore()
        if (savedScrollTop !== null) {
          scrollLogger.markProgrammatic()
          virtualScrollerRef.value?.scrollToPosition(savedScrollTop, 'auto')
          scrollLogger.info({
            ...initialCtx,
            caller: 'loadChatHistory',
            reason: 'scroll-position-restored',
            extra: { savedScrollTop, trigger: 'initial-load' },
          })
        } else {
          scrollToBottom(true, 'initial-load')
        }

        setupCodeBlockCopyButtons()
      } finally {
        isInitialLoad = false
      }
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
  if (virtualScrollerRef.value?.isPreservingScroll) return
  if (virtualScrollerRef.value) {
    if (force || isAtBottom.value) {
      const container = virtualScrollerRef.value.containerRef
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
  const container = virtualScrollerRef.value?.containerRef
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
  const effectiveThreshold = virtualScrollerRef.value?.effectiveLoadMoreThreshold ?? 200
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
  const container = virtualScrollerRef.value?.containerRef
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
  // (`virtualScrollerRef.value?.containerRef`) is null during
  // mount/remount races (chat switch, initial mount before Vue
  // binds the template ref, v-if toggle), but the target is
  // always live. See the `scroll` emit JSDoc in
  // VirtualScroller.vue for the full rationale.
  //
  // The ref chain is kept as a defensive fallback for any future
  // caller that doesn't supply a target (none today).
  const container = target ?? virtualScrollerRef.value?.containerRef
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

// Bus listener unsubscribes. Declared at script-setup scope so they
// persist across `connectSse`/`disconnectSse` calls (re-declaring them
// inside the function would reset them to null on every mount, losing
// the unsubscribe). Initialized to null; set by `connectSse`, cleared
// by `disconnectSse`. Same pattern as the existing `sseScrollPending`
// flag below.
let offLlm: (() => void) | null = null
let offQueue: (() => void) | null = null

const connectSse = () => {
  console.log('[connectSse] Connecting SSE via sseBus for session:', sessionId.value)
  const sid = sessionId.value
  if (!sid) return

  // Defensive: if a previous connectSse didn't clean up (e.g. mid-mount
  // session change), tear down before re-registering. The bus's single
  // global EventSource is already open (App.vue opens it once), so we
  // only need to manage our listener subscriptions here.
  disconnectSse()

  streamingContent.value = ''

  const bus = useSseBus()
  // Subscribe FIRST so we don't miss any bus events that arrive between
  // registration and the next tick. The `event.session_id !== sid` filter
  // is defense-in-depth — the bus's single global EventSource carries
  // ALL sessions' llm/queue events (no per-session routing), and the
  // listener-side filter scopes each ChatView to its own sid.
  offLlm = bus.on('llm', (event: api.SseEvent) => {
    if (event.session_id !== sid) return

    console.log('[SSE ChatView] Received event:', event)

    // 2026-08-23 spawn-subagent-live-progress: route sub-agent
    // progress events into the per-tool_call_id map and STOP here.
    // Touching `messages.value` would pollute the chat transcript
    // (these rows are ephemeral, NOT persisted) and would also
    // toggle the dedupe gate above. The progress map is the
    // SINGLE consumer for role="subagent_progress".
    if ((event as SubAgentProgressEvent).role === 'subagent_progress') {
      subAgentProgressMap.value = applyProgressEvent(
        subAgentProgressMap.value,
        event as SubAgentProgressEvent,
      )
      return
    }

    if (event.type === 'connected' && event.session_id) {
      console.log('SSE connected, session:', event.session_id)
      return
    }

    // 2026-08-23 llm-chunk-streaming: gate on the three event types
    // ChatView actually handles — `chunk` (append delta), `chunk_final`
    // (token-stream-end marker that updates maxTotalTokens), and `full`
    // (replace streaming-* row with canonical DB row). Other types
    // (`reasoning_chunk`, `tool_call_delta`, `connected`) are handled
    // by their own dedicated branches above.
    if (event.type !== 'chunk' && event.type !== 'chunk_final' && event.type !== 'full') {
      return
    }


    if (event.type === 'chunk' && event.content) {
      // 2026-08-23 llm-chunk-streaming: the backend sends RAW DELTAS
      // (choices[0].delta.content per provider SSE), so APPEND here —
      // the old `=` replace left only the last fragment visible.
      streamingContent.value += event.content
      updateStreamingMessage()
      return
    }

    // 2026-08-23 llm-chunk-streaming: in-stream final marker emitted by
    // workflow.zig right before the canonical llm_full row. Carries
    // usage + signals "token stream over" so the typing indicator can
    // stop early. Do NOT push a message here — the full event that
    // follows replaces the streaming-* row with the canonical DB row.
    if (event.type === 'chunk_final') {
      if (event.total_tokens) {
        maxTotalTokens.value = event.total_tokens
      }
      return
    }

    // 2026-08-23 hidden-messages fix — the gate previously required
    // `event.content` to be truthy, which silently DROPPED every `full`
    // event whose content was empty: tool-result rows (role='tool',
    // empty raw content — the card renders from tool_name + envelope),
    // image-only user echoes, and thinking-only assistant turns. All
    // of those are renderable now (filteredMessages exemptions +
    // reasoning section), so accept any event that has a finish_reason
    // and at least ONE renderable field.
    const hasRenderableFullPayload =
      !!(
        event.content ||
        event.reasoning_content ||
        event.tool_call_id ||
        event.tool_name ||
        (event.image_url && event.image_url.length > 0)
      )
    if (event.type === 'full' && event.finish_reason && hasRenderableFullPayload) {
      messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))

      const role =
        (event.role as 'user' | 'assistant' | 'system' | 'tool') ||
        (event.tool_call_id ? 'tool' : 'assistant')

      // 2026-08-23 TOOLS-pill-spam fix — the backend re-emits an SSE for
      // EVERY tool completion via getLatestMessage(), which (backend bug
      // B1, see handle_tool.zig) often returns the ASSISTANT tool_calls
      // row instead of the completed tool placeholder. The frontend then
      // receives several role=assistant events with tool_calls_json per
      // turn; each became a new assistant group and groupToolNames
      // rendered a "TOOLS" pill for each — pill spam between tool rows.
      // Dedupe: skip any event that duplicates an existing message on
      // role + content + tool_call_id. Genuine repeats from the server
      // (same DB row re-emitted) collapse to one; distinct rows differ
      // in tool_call_id and still render.
      const dup = messages.value.find((m) => {
        if (m.role !== role) return false
        if ((m.tool_call_id ?? '') !== (event.tool_call_id ?? '')) return false
        return m.content === (event.content || '')
      })
      if (
        dup &&
        // 2026-08-23: the optimistic-user dedupe that lived here is
        // gone — handleFileInputSubmit no longer pushes a local
        // placeholder. User echoes arrive fresh with a stable DB id;
        // a same-content repeat (server re-emit) collapses to one
        // message via the dedupe above.
        role !== 'user'
      ) {
        console.log('[SSE ChatView] duplicate full event skipped', {
          role,
          tool_call_id: event.tool_call_id,
          content_len: (event.content || '').length,
        })
        return
      }

      messages.value.push({
        id: event.id || `assistant-${Date.now()}`,
        role: role,
        content: event.content || '',
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
        is_input: event.is_input,
        is_output: event.is_output,
        // 2026-08-23 hidden-messages fix — carry reasoning through so
        // thinking-only turns render their collapsible section.
        reasoning_content: event.reasoning_content || undefined
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

      // 2026-08-23 spawn-subagent-live-progress: when the FINAL
      // spawn_sub_agent tool result row lands, drop the
      // corresponding live-progress entry so the parsed-envelope
      // view (which lives in `content`) takes over rendering
      // immediately. Without this, the map's running rows would
      // sit invisibly under the now-populated <results> envelope
      // (the component precedence logic hides them, but the map
      // memory leaks across renders).
      if (
        role === 'tool' &&
        event.tool_name === 'spawn_sub_agent' &&
        event.tool_call_id &&
        subAgentProgressMap.value[event.tool_call_id]
      ) {
        subAgentProgressMap.value = clearProgressFor(
          subAgentProgressMap.value,
          event.tool_call_id,
        )
      }

      if (event.total_tokens) {
        maxTotalTokens.value = event.total_tokens
      }

      return
    }

    // 2026-08-23 hidden-messages fix — reasoning chunks used to be
    // console.log-only. Accumulate them onto the streaming assistant
    // message so the collapsible reasoning section renders live while
    // a thinking model works (before any final content arrives).
    if (event.reasoning_content && !event.content) {
      console.log('Reasoning:', event.reasoning_content)
      const existingMsg = messages.value.find(
        (m) => m.role === 'assistant' && m.id.startsWith('streaming-'),
      )
      if (existingMsg) {
        existingMsg.reasoning_content = (existingMsg.reasoning_content || '') + event.reasoning_content
      } else {
        messages.value.push({
          id: `streaming-${Date.now()}`,
          role: 'assistant',
          content: '',
          timestamp: new Date(),
          reasoning_content: event.reasoning_content,
        })
      }
    }
  })
  offQueue = bus.on('queue', (event: api.QueueMessageEvent) => {
    if (event.session_id !== sid) return
    console.log('[QueueMessages SSE] Received event:', event)
    if (event.action === 'queued') {
      queuedMessages.value.push({
        id: event.id ?? `q-${Date.now()}`,
        message: event.message,
      })
    } else if (event.action === 'deleted') {
      queuedMessages.value = queuedMessages.value.filter((m) => m.id !== event.id)
    }
  })
  // Set isStreaming LAST so external observers (tests, UI) can poll
  // it as a "listeners are wired up" signal — flipping it before
  // would race with test assertions that fire events into the bus
  // expecting the listener to be registered.
  isStreaming.value = true
}

const disconnectSse = () => {
  if (offLlm) {
    offLlm()
    offLlm = null
  }
  if (offQueue) {
    offQueue()
    offQueue = null
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
    sessionCwd.value = props.cwd
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
    if (isInitialLoad) return // initial-load branch handled scroll explicitly
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

  const currentSessionId = sessionId.value

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

  // 2026-08-23 auto-collapse fix — NO optimistic local push.
  // Previously the user's own message was pushed to `messages` with a
  // synthetic `optimistic-user-*` id, then replaced when the backend's
  // queue-drain re-emitted it via SSE `full`. Two problems:
  //   (a) the local push sat at the END of the array, while the
  //       server's canonical row carried the correct DB id and
  //       chronological position — the optimistic was visible only
  //       briefly before the dedupe swapped them;
  //   (b) every push shifted `messageGroups`, which — combined with
  //       positional expand keys — silently re-keyed tool cards the
  //       user had just expanded (see expandedToolIds comment).
  // Now we let the SSE echo deliver the canonical row. The user sees
  // a brief gap (server round-trip) but the rendered card carries the
  // real DB id from the start, with stable expansion semantics.

  try {
    await api.sendChatMessage(
      currentSessionId,
      userMessage,
      sessionCwd.value,
      imageUrls,
      selectedProfile.value ?? undefined,
    )
  } catch (err) {
    console.error('Failed to send message:', err)
    // No local bubble to roll back — just surface an inline error so
    // the user knows the send failed. The server log has the truth.
    messages.value.push({
      id: `error-${Date.now()}`,
      role: 'assistant',
      content: 'Sorry, I encountered an error sending your message. Please try again.',
      timestamp: new Date(),
    })
  }
}

// ─── Stop session ──────────────────────────────────────────────────────────
//
// The FileInput component renders a Stop button (visible only when
// `isLLMProcessing === true`) that emits `stop-session`. We translate
// that into a `POST /api/llm/session/<sid>/stop` which flips the
// worker's `cancelled` flag. The workflow breaks at the next iteration
// boundary, deletes the worker, and the SSE `worker deleted` event
// removes the session from `processingState`. The button's
// `v-if="isLLMProcessing"` auto-hides when that event lands.
//
// We deliberately do NOT optimistically flip `isLLMProcessing`
// locally — the SSE event races with the API response and could
// cause a flicker (button hides → re-shows → hides). FileInput owns
// its own `isStopping` flag for the spinner; `processingState` is the
// source of truth.
const handleStopSession = async () => {
  if (!sessionId.value) return
  try {
    await api.stopSession(sessionId.value)
  } catch (err) {
    console.error('Failed to stop session:', err)
  }
}
 

// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
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
      <div ref="messagesWrapperRef" class="relative flex-1 min-h-0 flex flex-col mb-4">
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

        <!-- Virtualized Message List.
             2026-08-23 fast-scroll responsiveness tuning:
             - default-item-height 200 -> 64: real rows are ~40-80px
               (one-line tool cards, short paragraphs). The old 200px
               estimate made top/bottom spacers 2.5-5x too tall, so a
               fast fling landed the estimated visible window deep inside
               spacer territory; content only appeared after measureItems
               caught up (~3s of blank). A closer estimate keeps the
               window near the real content from the first frame.
             - buffer 20 -> 30: cheap insurance for fast scrolls — more
               pre-rendered rows above/below means the viewport is
               already populated when the fling stops. -->
        <VirtualScroller
          v-if="isLoading || messageGroups.length > 0"
          ref="virtualScrollerRef"
          :items="messageGroups"
          :total-count="0"
          :buffer="30"
          :default-item-height="64"
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
                class="flex"
                :class="group.role === 'user' ? 'flex-row-reverse' : 'flex-row'"
              >
                <!-- Bubble / paragraph container.
                     2026-08-23 paragraph-mode: the AI (assistant) side no
                     longer renders as a chat bubble. The container keeps
                     the bubble chrome (padding, rounded corners, card bg,
                     border) ONLY for user groups; assistant + tool groups
                     render as transparent, borderless paragraphs that flow
                     with the page background — like a document, not a
                     messenger.
                     NOTE: empty groups are already filtered out of
                     messageGroups (see the computed) — this v-if is only
                     defense-in-depth. Do NOT move it to the slot root:
                     an unrendered group keeps its 200px height ESTIMATE
                     in the VirtualScroller forever, which desyncs the
                     estimated scroll model from the real DOM and blanks
                     the whole chat on scrollToBottom. -->
                <div
                  class="min-w-0"
                  :class="group.role === 'user' ? 'max-w-[90%]' : 'max-w-full'"
                >
                  <div
                    v-if="hasBubbleContent(group, groupIndex)"
                    class="text-sm leading-relaxed"
                    role="button"
                    tabindex="0"
                    :class="
                      group.role === 'user'
                        ? 'px-4 py-2.5 rounded-2xl whitespace-pre-wrap break-words'
                        : 'markdown-content'
                    "
                    :style="
                      group.role === 'user'
                        ? 'background-color: var(--color-blue-1); color: var(--semantic-text); border-bottom-right-radius: 6px;'
                        : 'color: var(--semantic-text);'
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
                      <!-- 2026-08-23 hidden-messages fix — v-for over ALL
                           messages in the group. The old template rendered
                           only group.messages[0], so consecutive user
                           messages (queue-drain bursts, rapid sends) beyond
                           the first were invisible: their text AND attached
                           images never appeared. Each message renders its
                           own images + text; empty-text messages with
                           images render images only. -->
                      <template v-else>
                        <template
                          v-for="(userMsg, userMsgIdx) in group.messages"
                          :key="userMsg.id || `u-${userMsgIdx}`"
                        >
                          <div
                            v-if="
                              userMsg.image_urls && userMsg.image_urls.length > 0
                            "
                            class="mb-2"
                          >
                            <div class="flex flex-wrap gap-2">
                              <div
                                v-for="(imgUrl, imgIdx) in userMsg.image_urls"
                                :key="imgIdx"
                                class="chat-attached-image-thumb"
                                @click="openImagePreview(imgUrl)"
                              >
                                <img
                                  :src="imgUrl"
                                  alt="Attached image"
                                  class="chat-attached-image-img"
                                />
                              </div>
                            </div>
                          </div>
                          <span v-if="userMsg.content">{{ userMsg.content }}</span>
                        </template>
                      </template>
                    </template>

                    <!-- ── Tool ── -->
                    <template v-else-if="group.role === 'tool'">
                      <div class="tool-sequence">
                        <div
                          v-for="(msg, idx) in group.messages"
                          :key="msg.id || msg.tool_call_id || `t-${groupIndex}-${idx}`"
                          class="tool-item"
                          :class="idx < group.messages.length - 1 ? 'tool-item-border' : ''"
                        >
                          <ReadFile
                            v-if="msg.tool_name === 'read_file'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :cwd="sessionCwd"
                          />
                          <WriteFile
                            v-else-if="msg.tool_name === 'write_file'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :cwd="sessionCwd"
                          />
                          <UpdateActivity
                            v-else-if="msg.tool_name === 'update_activity'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <Search
                            v-else-if="msg.tool_name === 'search'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :cwd="sessionCwd"
                          />
                          <SearchHistory
                            v-else-if="msg.tool_name === 'search_history'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <Glob
                            v-else-if="msg.tool_name === 'glob'"
                            :content="innerToolData(msg)"
                            :cwd="sessionCwd"
                          />
                          <TextReplace
                            v-else-if="msg.tool_name === 'text_replace'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :diffview-before="msg.diffview_before"
                            :diffview-after="msg.diffview_after"
                            :cwd="sessionCwd"
                          />
                          <ShellTool
                            v-else-if="msg.tool_name === 'bash' || msg.tool_name === 'pwsh' || msg.tool_name === 'run_command'"
                            :tool-name="msg.tool_name === 'pwsh' ? 'pwsh' : 'bash'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <GetSkill
                            v-else-if="msg.tool_name === 'get_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <ViewSkill
                            v-else-if="msg.tool_name === 'view_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <ListSkills
                            v-else-if="msg.tool_name === 'list_skills'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <AddSkill
                            v-else-if="msg.tool_name === 'add_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <EditSkill
                            v-else-if="msg.tool_name === 'edit_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <RemoveSkill
                            v-else-if="msg.tool_name === 'remove_skill'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <RemoveFile
                            v-else-if="msg.tool_name === 'remove_file'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :cwd="sessionCwd"
                          />
                          <SpawnSubAgent
                            v-else-if="msg.tool_name === 'spawn_sub_agent'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :sub-agent-args="findSubAgentArgsForToolGroup(msg.tool_call_id, messageGroups, groupIndex)"
                            :progress="msg.tool_call_id ? subAgentProgressMap[msg.tool_call_id] : null"
                            @peek="nav.openPeek($event)"
                          />
                          <NalarBrowser
                            v-else-if="msg.tool_name === 'nalar_browser'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <SetGitWorktree
                            v-else-if="msg.tool_name === 'set_git_worktree'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <ReadCompactedMessages
                            v-else-if="msg.tool_name === 'read_compacted_messages'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <KanbanMove
                            v-else-if="msg.tool_name === 'kanban_move_task'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <KanbanList
                            v-else-if="msg.tool_name === 'kanban_list'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <ListDirectory
                            v-else-if="msg.tool_name === 'list_directory'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                            :cwd="sessionCwd"
                          />
                          <SaveMemory
                            v-else-if="msg.tool_name === 'save_memory'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <LoadMemory
                            v-else-if="msg.tool_name === 'load_memory'"
                            :content="innerToolData(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <!--
                            `update_plan` + `get_plan` (Task 8 — optional UI).
                            These render the agent's per-session task plan as
                            a checklist card. Both components parse the
                            inner envelope themselves and extract the plan
                            body from the canonical `<plan><![CDATA[...]]></plan>`
                            block — no `parameters` prop threading needed.
                            Self-contained (no `expanded` from the dispatcher
                            — local toggle is enough for an optional UI).
                          -->
                          <UpdatePlan
                            v-else-if="msg.tool_name === 'update_plan'"
                            :message="msg"
                          />
                          <GetPlan
                            v-else-if="msg.tool_name === 'get_plan'"
                            :message="msg"
                          />
                          <!--
                            `show_preview` is intentionally NOT
                            expandable like the other tool outputs.
                            The whole point of the side panel is to
                            keep the chat bubble minimal (status,
                            preview id, content_type, length) and let
                            the user inspect the rich content in the
                            right-side panel. A click on the bubble
                            here does THREE things:
                              1. Opens / un-dismisses the panel.
                              2. Un-collapses the panel.
                              3. Jumps the panel to the matching
                                 preview tab via the `focusId` prop.
                            We delegate the visual rendering to
                            `<ShowPreview>` (which parses the XML
                            envelope into a header line matching the
                            rest of the tool cards); the click handler
                            just calls `openPreviewForMessage` to
                            focus the matching tab in the side panel.
                          -->
                          <ShowPreview
                            v-else-if="msg.tool_name === 'show_preview'"
                            :content="innerToolData(msg)"
                            :message-id="msg.id"
                            :parameters="getParametersForMessage(msg)"
                            @open="openPreviewForMessage($event)"
                          />
                          <!--
                            `generate_image` is expandable (not side-panel
                            based like `show_preview`). The card shows the
                            prompt + model + size + saved file paths; the
                            agent's NEXT tool call is `show_preview` with
                            `path=<image.path>` which actually renders the
                            image inline. This component is informational
                            metadata only.
                          -->
                          <GenerateImage
                            v-else-if="msg.tool_name === 'generate_image'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                          />
                          <div v-else class="tool-expandable">
                            <button
                              class="tool-summary"
                              @click="toggleToolExpanded(toolExpandKey(msg, groupIndex, idx))"
                              :style="[
                                'cursor: pointer; padding: 2px 4px; border-radius: 4px; transition: background-color 0.15s; text-align: left; width: 100%; border: none; background: transparent; font: inherit; color: inherit;',
                                expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))
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
                              v-if="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
                              class="tool-full-content"
                            >
                              <!--
                                Render the diff whenever the tool emitted
                                diffview_before/after, even if one is empty.
                                The outer v-if handles the expand/collapse
                                toggle. Empty-before or empty-after still
                                renders the diff frame so the user sees the
                                "all deleted" / "new file" case clearly.
                              -->
                              <DiffView
                                v-if="msg.diffview_before !== undefined || msg.diffview_after !== undefined"
                                :before="msg.diffview_before ?? ''"
                                :after="msg.diffview_after ?? ''"
                                :file-path="msg.tool_name"
                                @jump-to-line="handleFallbackJumpToLine"
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
                          <!-- <html> blocks render as live sandboxed iframes
                               (null origin = security boundary); any text
                               outside the tags still renders as markdown.
                               Legacy messages take the v-else path unchanged. -->
                          <template v-if="msg.role === 'assistant' && msgHasHtml(msg.content)">
                            <template v-for="(seg, sIdx) in extractHtmlBlocks(msg.content || '')" :key="sIdx">
                              <!-- eslint-disable-next-line vue/no-v-html -->
                              <span
                                v-if="seg.before"
                                v-html="marked.parse(seg.before, { async: false })"
                              ></span>
                              <iframe
                                v-if="seg.html"
                                class="chat-html-frame"
                                sandbox="allow-scripts"
                                :srcdoc="buildHtmlSrcdoc(seg.html)"
                              ></iframe>
                            </template>
                          </template>
                          <span
                            v-else
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
                      <!-- 2026-08-23 hidden-messages fix — collapsible
                           reasoning section for thinking models. Previously
                           reasoning_content was console.log-only, so a
                           thinking-only turn (empty final text) looked like
                           the agent said nothing. Default-collapsed so long
                           chains-of-thought don't push content off-screen;
                           click to expand. -->
                      <div
                        v-for="(msg, rIdx) in group.messages.filter(
                          (m) => m.reasoning_content && m.reasoning_content.trim() !== '',
                        )"
                        :key="`reasoning-${rIdx}`"
                        class="mt-3"
                      >
                        <details class="assistant-reasoning">
                          <summary
                            class="cursor-pointer select-none text-xs font-medium opacity-70 hover:opacity-100"
                            :style="{ color: 'var(--semantic-text-dim)' }"
                          >
                            💭 Reasoning
                          </summary>
                          <div
                            class="mt-1 whitespace-pre-wrap text-xs leading-relaxed opacity-80 border-l-2 pl-3"
                            :style="{
                              color: 'var(--semantic-text-dim)',
                              'border-color': 'var(--color-border)',
                            }"
                            >{{ msg.reasoning_content }}</div
                          >
                        </details>
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
            :cwd="sessionCwd"
            :queuedMessages="queuedMessages"
            :isLoading="isLoading"
            :isLLMProcessing="isLLMProcessing"
            @submit="handleFileInputSubmit"
            @files-selected="handleFileInputSubmit"
            @stop-session="handleStopSession"
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
                :title="profileChipTooltip"
              >
                <span>🤖</span>
                <span>{{ effectiveProfile ?? 'Default' }}</span>
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
                  data-testid="profile-picker-default"
                >
                  <span>Default (top-level config)</span>
                  <span v-if="!selectedProfile && !activeProfile">✓</span>
                </button>
                <button
                  v-for="p in availableProfiles"
                  :key="p.name"
                  @click="selectProfile(p.name)"
                  class="w-full text-left px-3 py-2 text-xs hover:opacity-80"
                  style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
                  :data-testid="`profile-picker-${p.name}`"
                >
                  <div class="flex items-center justify-between">
                    <span class="font-medium">
                      {{ p.name }}
                      <span
                        v-if="activeProfile === p.name"
                        class="text-[10px] ml-1 px-1 py-0.5 rounded"
                        :style="{ backgroundColor: 'var(--color-violet)', color: '#181616' }"
                        data-testid="profile-picker-active-badge"
                      >(active)</span>
                    </span>
                    <span v-if="effectiveProfile === p.name">✓</span>
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
          </div>
        </div>
      </div>
    </div>

    <!-- Skills Popup Modal -->
    <SkillsPopup
      :show="showSkillsPopup"
      :skills="sessionSkills"
      :session-cwd="sessionCwd"
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

    <!-- Sub-agent peek panel — slide-over from the right.
         Renders only when navigationStore.peekPanel is set;
         teardown happens when ChatView unmounts (route change
         away from this chat). -->
    <SubAgentPeekPanel
      v-if="nav.peekPanel && peek"
      :session-id="nav.peekPanel.sessionId"
      :agent-name="nav.peekPanel.agentName"
      :instruction="nav.peekPanel.instruction"
      :status="peek.status.value"
      :error-message="peek.errorMessage.value"
      :messages="peek.messages.value"
      :total-tokens="peek.totalTokens.value"
      @close="nav.closePeek()"
      @open-full="onPeekOpenFull"
      @reload="peek.reload"
    />
    <!--
      Preview side panel: renders every `show_preview` tool result
      for this chat in a right-side vertical column. Lives inside
      the outer `flex h-full w-full` wrapper as a sibling of both
      the main chat column (above) and `SubAgentPeekPanel` (also
      here). The panel manages its own width via `w-8` (collapsed
      tab) / inline `style.width = localWidth + 'px'` (expanded,
      persisted to localStorage as `nalar-preview-panel-width`)
      — adding `flex-1` would let it grow and crowd out the messages.
      The `v-if="!previewPanelDismissed"` stays mounted only until
      the user clicks ✕. The panel DEFAULTS to collapsed (renders as
      a tab) and stays that way until the user clicks the tab to
      expand or clicks a `show_preview` bubble in the chat — we
      deliberately do NOT auto-open on new preview arrivals.
    -->
    <PreviewSidePanel
      v-if="!previewPanelDismissed"
      :previews="showPreviewMessages"
      :focus-id="previewToShowId"
      v-model:collapsed="previewPanelCollapsed"
      @dismiss="previewPanelDismissed = true"
    />

    <!--
      Restore button — floating top-right of the chat area, only
      visible when:
        1. Display mode is 'inline' (side panel is hidden), AND
        2. There is at least one `show_preview` message in this chat.
      Click → flips mode back to 'side', which re-shows the panel
      (via the watch above). Mirrors the "back to sidebar" affordance
      users expect when content renders inline. Sits next to the
      chat so it's discoverable without scrolling.
    -->
    <button
      v-if="isInline && showPreviewMessages.length > 0"
      type="button"
      class="absolute top-2 right-2 z-20 px-2 py-1 rounded-md text-xs font-mono border border-[var(--color-border)] bg-[var(--semantic-card-bg)] text-[var(--semantic-text)] cursor-pointer shadow-sm hover:border-[var(--color-violet)]/40 hover:text-[var(--color-violet)] transition-colors flex items-center gap-1"
      data-testid="restore-preview-panel-button"
      title="Open preview side panel"
      @click="setMode('side')"
    >
      <span aria-hidden="true">📋</span>
      <span>Open preview panel</span>
    </button>
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
  /* 2026-08-23 paragraph-mode margin pass — the old 0.25rem gap was
     sized for boxed cards that carried their own visual separation.
     De-bubbled rows are flat, so they need explicit rhythm to read as
     distinct steps instead of one dense wall. */
  gap: 0.625rem;
}

:deep(.tool-item) {
  padding: 0.125rem 0;
}

:deep(.tool-item-border) {
  border-bottom: none;
  padding-bottom: 0;
}

:deep(.tool-item-border:last-child) {
  border-bottom: none;
  padding-bottom: 0;
}

/* 2026-08-23 paragraph-mode margin pass — spacing AROUND the tool
   sequence so it breathes against surrounding prose:
   - gap above the first tool row (was flush against the assistant text)
   - gap below the last tool row (was flush against the next group) */
:deep(.tool-sequence) {
  margin-top: 0.375rem;
  margin-bottom: 0.375rem;
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

/* ─── Assistant paragraph mode (2026-08-23) ──────────────────────────────
   The AI side no longer renders as a chat bubble — assistant groups are
   transparent, borderless paragraphs that flow with the page background.
   These rules give the un-bubbled content document-like rhythm:
   - .assistant-messages: vertical spacing between consecutive assistant
     groups (the old bubble's py-2.5 padding provided this separation).
   - .assistant-item + .assistant-item + .assistant-item: a small gap
     between adjacent messages inside one group.
   2026-08-23 margin pass: bumped both up — flat paragraphs need more
   explicit rhythm than boxed bubbles did. */
.assistant-messages {
  margin-bottom: 0.375rem;
}

.assistant-item + .assistant-item {
  margin-top: 0.625rem;
}

/* ─── <html> wrapper-tag sandboxed iframe (2026-08-23 html-tag-support) ──
   Live HTML blocks from the LLM render inside a null-origin iframe
   (sandbox="allow-scripts", no allow-same-origin). White background so
   arbitrary LLM pages read as "a page", rounded to match chat cards. */
.chat-html-frame {
  display: block;
  width: 100%;
  min-height: 120px;
  border: 1px solid var(--color-border, #ddd);
  border-radius: 8px;
  background: #fff;
}

/* ─── Tool-output cards, de-bubbled (2026-08-23) ────────────────────────
   All 24 tool_output components used to carry an identical Tailwind card
   frame (`rounded-md border border-[--color-border] bg-[--semantic-card-bg]`)
   — a boxed bubble per tool row. In paragraph mode that reads as heavy
   chrome stacked under un-bubbled prose. The frame is now ONE shared
   class, `.chat-tool-card`, defined here once:
     - transparent background (page shows through)
     - no full box border; a subtle 2px left rule marks the row instead
     - gentle hover tint so rows stay discoverable as expandable
   Error/warning variants still work: components bind
   `border-red-500/50` / `border-orange-500/50` via :class, which now
   recolors the left rule (border-left-color) instead of drawing a box.
   Scoped deep selector: the components are children of ChatView's tree. */
:deep(.chat-tool-card) {
  background-color: transparent;
  border: none;
  border-left: 2px solid var(--color-border);
  border-radius: 0;
  overflow: visible;
  transition: background-color 0.15s ease, border-left-color 0.15s ease;
}

:deep(.chat-tool-card:hover) {
  background-color: color-mix(in srgb, var(--color-violet) 4%, transparent);
  border-left-color: var(--color-violet);
}

/* Attached image thumbnail — small fixed-size preview matching
   FileInput.vue's FilePreview (80×80px, rounded, object-fit:cover).
   Click opens the full-screen ImagePreview via openImagePreview(). */
.chat-attached-image-thumb {
  width: 80px;
  height: 80px;
  border-radius: 8px;
  overflow: hidden;
  border: 1px solid var(--color-border);
  background-color: var(--semantic-sidebar-bg);
  cursor: pointer;
}

.chat-attached-image-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.chat-attached-image-thumb:hover .chat-attached-image-img {
  opacity: 0.9;
}
</style>
