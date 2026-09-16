<!--
  AskUser — tool output component for the `ask_user` agent tool.

  The agent calls `ask_user` when a decision is genuinely blocked on the
  human. The call ENDS the turn: the tool returns immediately, the agentic
  loop breaks, and the question waits here until the user answers. Answering
  rewrites this tool's result row in place and starts a new run, so the model
  continues with the answer in context.

  Wire shape — the component parses the inner `<ask_user>…</ask_user>`
  envelope out of `content` (which ChatView passes as the unwrapped `<data>`
  payload, or the whole `<tool>` envelope when the call failed):

    Pending (the card's interactive state):
      <ask_user><status>pending</status><question_id>q_…</question_id>
        <header>Deploy target</header>
        <question>Which environment should I deploy to?</question>
        <allow_free_text>true</allow_free_text>
        <multi_select>false</multi_select>
        <recommended>staging</recommended>
        <options><option>staging</option><option>production</option></options>
        <instruction>…</instruction></ask_user>

    Resolved (written in place by POST …/answer):
      …<status>answered</status><answer>staging</answer><answers_count>1</answers_count>
      …<status>skipped</status>  |  <status>abandoned</status>
      …<status>unavailable</status><reason>no_human</reason>

    Invalid input (never a row):
      <tool><name>ask_user</name>…<success>false</success>
        <error>recommended must exactly match one of the strings in options</error></tool>

  The question's SHAPE travels in the envelope rather than being read from
  the tool row's `<parameters>` block: `wrapToolOutput` converts the arguments
  to XML, so the frontend cannot JSON-parse them back, and the tool row has no
  `tool_calls_json` (that lives on the assistant row). One source means the
  pending card renders identically live and after a page reload.

  Plan: docs/superpowers/plans/2026-09-16-agent-tool-ask-user.md
  Wireframe: docs/wireframes/ask-user-tool.html
-->
<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { tryUnwrapToolOutput } from '../../helpers/unwrapToolOutput'
import { answerAskUser } from '../../api'

interface Props {
  /** Inner `<data>` payload (or the full `<tool>` envelope on failure). */
  content: string
  /** Raw tool-call arguments, for the collapsible Arguments block. */
  parameters?: string
  expanded?: boolean
  /** Needed to POST the answer. */
  sessionId?: string
}

const props = defineProps<Props>()

// ---------------------------------------------------------------------------
// Envelope parsing
// ---------------------------------------------------------------------------

/** Reverse one level of `xmlEscape` from the backend. `&amp;` MUST be last. */
function unescapeOnce(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')
}

function tag(haystack: string, name: string): string | null {
  const open = `<${name}>`
  const close = `</${name}>`
  const start = haystack.indexOf(open)
  if (start === -1) return null
  const valueStart = start + open.length
  const end = haystack.indexOf(close, valueStart)
  if (end === -1) return null
  return unescapeOnce(haystack.slice(valueStart, end))
}

/** All `<option>` children of the `<options>` block, in order. */
function parseOptions(inner: string): string[] {
  const block = tag(inner, 'options')
  if (block === null || block.length === 0) return []
  const out: string[] = []
  const open = '<option>'
  const close = '</option>'
  let cursor = 0
  for (;;) {
    const start = block.indexOf(open, cursor)
    if (start === -1) break
    const valueStart = start + open.length
    const end = block.indexOf(close, valueStart)
    if (end === -1) break
    out.push(block.slice(valueStart, end))
    cursor = end + close.length
  }
  return out
}

type ViewState = 'pending' | 'answered' | 'skipped' | 'abandoned' | 'unavailable' | 'invalid'

interface ParsedEnvelope {
  state: ViewState
  questionId: string
  header: string
  question: string
  options: string[]
  allowFreeText: boolean
  multiSelect: boolean
  recommended: string
  answer: string
  answersCount: number
  error: string
}

const parsed = computed<ParsedEnvelope>(() => {
  const fallback: ParsedEnvelope = {
    state: 'pending',
    questionId: '',
    header: '',
    question: '',
    options: [],
    allowFreeText: true,
    multiSelect: false,
    recommended: '',
    answer: '',
    answersCount: 0,
    error: '',
  }

  const raw = (props.content ?? '').trim()
  if (raw.length === 0) return fallback

  // A failed call arrives as the whole `<tool>` envelope with success=false
  // and no `<data>` (ChatView falls back to the full content).
  if (raw.startsWith('<tool>')) {
    const unwrapped = tryUnwrapToolOutput(raw)
    if (unwrapped && !unwrapped.success) {
      return { ...fallback, state: 'invalid', error: unwrapped.error ?? 'ask_user failed' }
    }
    if (unwrapped?.data) return parseInner(unwrapped.data, fallback)
    // `unwrapToolOutput` throws when the envelope is missing one of
    // name/parameters/success, and ChatView then hands us the RAW envelope.
    // Recover the `<data>` payload by slicing instead of giving up: a card
    // that cannot read its own state renders as a bare "pending" question,
    // which is exactly how a resolved question looked unanswered.
    const data = tag(raw, 'data')
    if (data !== null) return parseInner(data, fallback)
    return fallback
  }

  return parseInner(raw, fallback)
})

function parseInner(inner: string, fallback: ParsedEnvelope): ParsedEnvelope {
  const status = (tag(inner, 'status') ?? '').trim()

  // Unknown / missing status degrades to a readable completed card rather
  // than throwing — a new backend status must never blank the transcript.
  const state: ViewState =
    status === 'pending' ||
    status === 'answered' ||
    status === 'skipped' ||
    status === 'abandoned' ||
    status === 'unavailable'
      ? (status as ViewState)
      : 'invalid'

  const freeTextTag = tag(inner, 'allow_free_text')
  const multiTag = tag(inner, 'multi_select')

  return {
    state,
    questionId: tag(inner, 'question_id') ?? '',
    header: tag(inner, 'header') ?? '',
    question: tag(inner, 'question') ?? '',
    options: parseOptions(inner),
    // Absent means "not specified" → the tool's own defaults.
    allowFreeText: freeTextTag === null ? true : freeTextTag.trim() !== 'false',
    multiSelect: multiTag !== null && multiTag.trim() === 'true',
    recommended: tag(inner, 'recommended') ?? '',
    answer: tag(inner, 'answer') ?? '',
    answersCount: Number.parseInt(tag(inner, 'answers_count') ?? '0', 10) || 0,
    error: tag(inner, 'error') ?? 'ask_user returned an unrecognised status',
  }
}

// ---------------------------------------------------------------------------
// Local interaction state
// ---------------------------------------------------------------------------

const isExpanded = ref(props.expanded ?? false)
const submitting = ref(false)
const sendFailed = ref(false)
/** Set after a successful POST so the card flips even if the SSE frame is missed. */
const locallyResolved = ref<ViewState | null>(null)
const locallyAnswered = ref('')

const selected = ref<string[]>([])
const freeText = ref('')
/** True when the user chose to type instead of picking an option. */
const usingFreeText = ref(false)

const state = computed<ViewState>(() => locallyResolved.value ?? parsed.value.state)
const options = computed(() => parsed.value.options)
const multiSelect = computed(() => parsed.value.multiSelect)

const answers = computed<string[]>(() => {
  if (locallyAnswered.value) return parseAnswers(locallyAnswered.value)
  return parseAnswers(parsed.value.answer)
})

function parseAnswers(raw: string): string[] {
  const trimmed = (raw ?? '').trim()
  if (trimmed.length === 0) return []
  if (trimmed.startsWith('[')) {
    try {
      const arr = JSON.parse(trimmed)
      if (Array.isArray(arr)) return arr.map((v) => String(v))
    } catch {
      /* fall through to the single-value case */
    }
  }
  return [trimmed]
}

/**
 * True when the free-text box is the answer: either the user explicitly chose
 * "Other", or they simply typed something without picking an option. Typing
 * IS answering — requiring a radio click first would silently drop the text.
 */
const answerIsFreeText = computed(
  () => freeText.value.trim().length > 0 && (usingFreeText.value || selected.value.length === 0),
)

/** A pending question needs a valid selection (or text) before Send. */
const canSend = computed(() => {
  if (state.value !== 'pending' || submitting.value) return false
  if (options.value.length === 0) return freeText.value.trim().length > 0
  return selected.value.length > 0 || answerIsFreeText.value
})

function toggleOption(option: string): void {
  if (state.value !== 'pending' || submitting.value) return
  usingFreeText.value = false
  if (multiSelect.value) {
    selected.value = selected.value.includes(option)
      ? selected.value.filter((v) => v !== option)
      : [...selected.value, option]
  } else {
    selected.value = [option]
  }
}

function chooseFreeText(): void {
  usingFreeText.value = true
  selected.value = []
}

/**
 * Answer text is often a sentence or three (an id, a path, a caveat), so the
 * box grows with what is typed instead of staying two lines tall. Capped so a
 * pasted essay cannot push the composer off screen.
 */
const FREETEXT_MAX_PX = 220

function autoGrow(event: Event): void {
  const el = event.target as HTMLTextAreaElement | null
  if (!el) return
  el.style.height = 'auto'
  el.style.height = `${Math.min(el.scrollHeight, FREETEXT_MAX_PX)}px`
}

/** Typing in the box IS choosing free text; also let the box grow. */
function onFreeTextInput(event: Event): void {
  usingFreeText.value = true
  autoGrow(event)
}

/** The exact body the endpoint validates. */
function buildBody(skip: boolean): Record<string, unknown> {
  const body: Record<string, unknown> = {}
  if (parsed.value.questionId) body.question_id = parsed.value.questionId
  if (skip) {
    body.skip = true
    return body
  }
  if (answerIsFreeText.value) {
    body.answer = freeText.value.trim()
  } else if (multiSelect.value) {
    // Multi-select answers are a JSON array of strings on the wire.
    body.answer = JSON.stringify(selected.value)
  } else {
    body.answer = selected.value[0] ?? ''
  }
  return body
}

async function submit(skip: boolean): Promise<void> {
  if (state.value !== 'pending' || submitting.value) return
  if (!skip && !canSend.value) return

  const sessionId = props.sessionId
  if (!sessionId) {
    // Should not happen (ChatView always passes it); fail visibly rather
    // than posting nowhere.
    sendFailed.value = true
    return
  }

  submitting.value = true
  sendFailed.value = false
  const body = buildBody(skip)
  const res = await answerAskUser(sessionId, body)
  submitting.value = false

  if (!res.success) {
    sendFailed.value = true
    return
  }

  // No optimistic swap while the request is in flight, but once it has
  // succeeded the row rewrite is authoritative — flip locally too, so a
  // dropped SSE frame cannot leave a stale interactive card on screen.
  const nextState = (res.status as ViewState) ?? (skip ? 'skipped' : 'answered')
  locallyResolved.value = nextState === 'pending' ? null : nextState
  if (!skip) locallyAnswered.value = String(body.answer ?? '')
}

function onKeydown(event: KeyboardEvent): void {
  if (state.value !== 'pending' || submitting.value) return
  const target = event.target as HTMLElement | null
  // Never steal keys from the textarea the user is typing in.
  if (target && (target.tagName === 'TEXTAREA' || target.tagName === 'INPUT')) return

  if (event.key === 'Enter') {
    event.preventDefault()
    void submit(false)
    return
  }
  if (event.key === 'Escape') {
    event.preventDefault()
    void submit(true)
    return
  }
  const index = Number.parseInt(event.key, 10)
  if (Number.isNaN(index) || index < 1 || index > options.value.length) return
  const option = options.value[index - 1]
  if (option === undefined) return
  event.preventDefault()
  toggleOption(option)
}

// ---------------------------------------------------------------------------
// Presentation
// ---------------------------------------------------------------------------

const waiting = computed(() => state.value === 'pending')

const primary = computed(() => {
  if (parsed.value.header) return parsed.value.header
  const q = parsed.value.question
  if (q.length > 0) return q.length > 60 ? `${q.slice(0, 60)}…` : q
  return 'ask_user'
})

const rightMeta = computed(() => {
  switch (state.value) {
    case 'pending':
      return multiSelect.value && options.value.length > 0
        ? `pick any of ${options.value.length}`
        : null
    case 'answered':
      return answers.value.length > 1 ? `${answers.value.length} answers` : null
    case 'unavailable':
      return 'no human'
    default:
      return null
  }
})

const statusLabel = computed(() => {
  switch (state.value) {
    case 'pending':
      return 'waiting for you'
    case 'answered':
      return 'answered'
    case 'skipped':
      return 'skipped'
    case 'abandoned':
      return 'moved on'
    case 'unavailable':
      return 'no human'
    default:
      return 'invalid'
  }
})

const answerChip = computed(() => answers.value.join(' · '))

onMounted(() => {
  if (waiting.value) {
    window.addEventListener('keydown', onKeydown)
  }
})

watch(waiting, (isWaiting) => {
  if (isWaiting) window.addEventListener('keydown', onKeydown)
  else window.removeEventListener('keydown', onKeydown)
})

onUnmounted(() => {
  window.removeEventListener('keydown', onKeydown)
})

defineExpose({ submit, toggleOption, chooseFreeText, canSend, buildBody })
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-80': state === 'invalid' }"
    data-testid="ask-user-card"
    :data-state="state"
  >
    <ToolCardHeader
      tool-name="ask_user"
      :primary="primary"
      :success="state !== 'invalid'"
      :expanded="isExpanded"
      :expandable="true"
      :right-meta="rightMeta"
      :running="waiting"
      @update:expanded="isExpanded = $event"
    />

    <!-- Collapsed one-liner: the resolved outcome. -->
    <div
      v-if="!isExpanded && state === 'answered'"
      class="px-2 pb-2 font-sans text-xs"
      style="color: var(--semantic-text-dim)"
    >
      ✓ {{ answerChip }}
    </div>

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <!-- Question text (every state) -->
      <div
        v-if="parsed.question"
        class="px-2 py-2 font-sans text-sm"
        style="color: var(--semantic-text)"
      >
        {{ parsed.question }}
      </div>

      <!-- Invalid / failed call -->
      <div v-if="state === 'invalid'" class="px-2 pb-2 font-sans text-xs text-red-500">
        {{ parsed.error }}
      </div>

      <!-- PENDING: the interactive part -->
      <template v-if="state === 'pending'">
        <div v-if="options.length > 0" class="flex flex-col gap-1 px-2 pb-2">
          <button
            v-for="(option, index) in options"
            :key="option"
            type="button"
            class="flex items-start gap-2 rounded-md border px-2 py-1.5 text-left transition-colors"
            :class="
              selected.includes(option)
                ? 'border-[var(--color-violet)] bg-[var(--color-violet)]/10'
                : 'border-[var(--color-border)] hover:border-[var(--color-violet)]/50'
            "
            :disabled="submitting"
            :data-testid="`ask-user-option-${index}`"
            @click="toggleOption(option)"
          >
            <span class="mt-0.5 shrink-0 text-[0.65rem]" style="color: var(--semantic-text-dim)">
              {{ index + 1 }}
            </span>
            <span class="flex-1 font-sans text-[0.8rem]" style="color: var(--semantic-text)">
              {{ option }}
            </span>
            <span
              v-if="option === parsed.recommended"
              class="shrink-0 rounded-full border border-green-500/40 px-1.5 text-[0.6rem] text-green-500"
            >
              recommended
            </span>
          </button>
        </div>

        <div v-if="parsed.allowFreeText" class="px-2 pb-2">
          <label
            class="mb-1 flex items-center gap-2 font-sans text-xs"
            style="color: var(--semantic-text-dim)"
          >
            <input
              type="radio"
              :checked="usingFreeText"
              data-testid="ask-user-other-radio"
              @change="chooseFreeText()"
            />
            Other — type your own answer
          </label>
          <textarea
            v-model="freeText"
            rows="3"
            data-testid="ask-user-freetext"
            class="w-full resize-y rounded-md border bg-transparent px-2 py-1.5 font-sans text-xs leading-relaxed"
            style="
              border-color: var(--color-border);
              color: var(--semantic-text);
              min-height: 4.5rem;
            "
            placeholder="Type your answer…"
            :disabled="submitting"
            @focus="chooseFreeText()"
            @input="onFreeTextInput($event)"
            @keydown.enter.exact.prevent="submit(false)"
          />
        </div>

        <div class="flex items-center gap-2 border-t border-[var(--color-border)] px-2 py-2">
          <button
            type="button"
            class="rounded-md px-3 py-1 font-sans text-xs font-semibold"
            style="background: var(--color-violet); color: var(--color-bg)"
            :disabled="!canSend"
            :class="{ 'cursor-not-allowed opacity-50': !canSend }"
            data-testid="ask-user-send"
            @click="submit(false)"
          >
            <span v-if="submitting">Sending…</span>
            <span v-else-if="multiSelect && selected.length > 1"
              >Send {{ selected.length }} answers</span
            >
            <span v-else>Send answer</span>
          </button>
          <button
            type="button"
            class="rounded-md border px-3 py-1 font-sans text-xs"
            style="border-color: var(--color-border); color: var(--semantic-text-dim)"
            :disabled="submitting"
            data-testid="ask-user-skip"
            @click="submit(true)"
          >
            Skip
          </button>
          <span class="ml-auto text-[0.65rem]" style="color: var(--semantic-text-dim)">
            1–{{ options.length || 1 }} pick · ⏎ send · esc skip
          </span>
        </div>

        <div
          v-if="sendFailed"
          class="px-2 pb-2 font-sans text-xs text-red-500"
          data-testid="ask-user-error"
        >
          Couldn't send your answer — the server is unreachable.
          <button type="button" class="ml-1 underline" @click="submit(false)">Retry</button>
        </div>
      </template>

      <!-- RESOLVED states -->
      <div v-else-if="state === 'answered'" class="px-2 pb-2">
        <span
          class="inline-flex items-center gap-2 rounded-md border border-green-500/30 px-2 py-1 font-sans text-xs text-green-500"
          data-testid="ask-user-answer-chip"
        >
          ✓ {{ answerChip }}
        </span>
      </div>

      <div
        v-else-if="state === 'skipped'"
        class="px-2 pb-2 font-sans text-xs"
        style="color: var(--semantic-text-dim)"
        data-testid="ask-user-skipped"
      >
        You skipped this question — the agent will not guess.
      </div>

      <div
        v-else-if="state === 'abandoned'"
        class="px-2 pb-2 font-sans text-xs"
        style="color: var(--semantic-text-dim)"
        data-testid="ask-user-abandoned"
      >
        You moved on without answering — the agent will not guess.
      </div>

      <div
        v-else-if="state === 'unavailable'"
        class="px-2 pb-2 font-sans text-xs"
        style="color: var(--semantic-text-dim)"
        data-testid="ask-user-unavailable"
      >
        No human was available — the agent decided on its own.
      </div>
    </div>

    <ToolParameters :parameters="props.parameters ?? '{}'" />
  </div>
</template>
