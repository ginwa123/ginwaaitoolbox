/**
 * scrollLogger.ts
 *
 * A focused logger for the ChatView's scroll subsystem.
 *
 * Why this exists: scroll events fire on every pixel of wheel/touch movement —
 * often 60+ times per second — and a single scroll can trigger a cascade of
 * side effects (loadMore → preserve → measure → re-stick). When something
 * goes wrong ("why did the chat jump to the bottom?"), the raw `scrollTop`
 * numbers are useless without context: was this scroll user-driven or
 * programmatic? did `isAtBottom` flip? who called `scrollToBottom`? did
 * loadMore fire?
 *
 * Design:
 *   - Two levels of verbosity:
 *       debug  → per-frame scroll samples. Throttled to ~5 Hz with a
 *                 trailing-edge flush so the final position is never lost.
 *                 Silenced in production.
 *       info   → state transitions (isAtBottom flipped), loadMore triggered,
 *                 scrollToBottom called, scroll-restore deltas. Always logged.
 *       warn/error → ditto, always logged.
 *   - Every line carries a `ScrollContext` snapshot so a single log line
 *     answers "what was the world like at this moment?".
 *   - `origin: 'user' | 'programmatic'` is the most important field:
 *     programmatic scrolls (auto-stick, initial load, SSE chunk arrival)
 *     MUST be distinguishable from user scrolls, otherwise the logs
 *     are just numbers.
 *   - A monotonic `eventId` is stamped on every line so you can group
 *     "user scrolled to top" → "loadMore fired" → "scrollTop restored"
 *     in DevTools by matching ids.
 */

// ─── Types ────────────────────────────────────────────────────────────────────

export type ScrollOrigin = 'user' | 'programmatic'

/**
 * Diagnostic snapshot of the scroll container element. Populated on
 * every log line so a single line can answer "is the container null,
 * is it hidden, is it 0×0 for some other reason?". Without this, a
 * 0×0 reading is just three useless zeros — *which one* failed tells
 * you the bug.
 *
 *   null          → container ref was null (component unmounted, ref
 *                    not populated, or wrong element bound)
 *   offsetHeight  → 0 with offsetParent set means laid out but
 *                    collapsed (e.g. all children display:none, or
 *                    the parent's height chain is broken)
 *   offsetParent  → null means the element is not rendered (display:
 *                    none on the element or any ancestor)
 *   display       → computed `display` value at log time. Captured
 *                    ONLY when dimensions look suspicious, to avoid
 *                    the layout-thrash cost on every scroll event.
 */
export interface ContainerInfo {
  null: boolean
  tag?: string
  className?: string
  display?: string
  visibility?: string
  offsetHeight: number
  offsetParent: string | null
}

export type ScrollReason =
  // Info-level reasons (state transitions / lifecycle events)
  | 'reached-bottom'
  | 'left-bottom'
  | 'load-more-threshold-reached'
  | 'scroll-to-bottom-forced'
  | 'scroll-to-bottom-conditional'
  | 'spacer-resize-stick'
  | 'spacer-resize-skip'
  | 'load-more-preserve-start'
  | 'load-more-preserve-end'
  | 'sse-chunk-arrived'
  | 'messages-length-changed'
  // Debug-level reason (per-frame sample)
  | 'scroll-sample'
  | 'error'

export interface ScrollContext {
  /** Stable id for the chat (props.chatId, may be 'pending-…'). */
  chatId: string
  /** Number of messages currently rendered. */
  messages: number
  /** VirtualScroller container geometry. */
  scrollTop: number
  scrollHeight: number
  clientHeight: number
  /** Derived — saves you from doing the math in your head. */
  distanceFromTop: number
  distanceFromBottom: number
  /** 0 = at top, 1 = at bottom. -1 if content is shorter than viewport. */
  scrollPercent: number
  /** True when within `BOTTOM_THRESHOLD` px of the bottom. */
  isAtBottom: boolean
  /** Was this scroll caused by the user's wheel/touch, or by code? */
  origin: ScrollOrigin
  /** What triggered this log line. */
  reason: ScrollReason
  /**
   * Diagnostic snapshot of the scroll container element. Always
   * present — see `ContainerInfo` for what each field tells you.
   * Without this, a `scrollHeight: 0` reading is just a useless
   * zero; with it, you can see *which* check failed.
   */
  containerInfo: ContainerInfo
  /** Free-form extras (caller, delta, etc.). */
  extra?: Record<string, unknown>
}

// ─── Configuration ────────────────────────────────────────────────────────────

/** Within this many px of the bottom counts as "at the bottom". */
export const BOTTOM_THRESHOLD = 10

/** Debug-level scroll samples are throttled to this interval. */
const DEBUG_THROTTLE_MS = 200

// ─── Programmatic-scroll tracking ─────────────────────────────────────────────
//
// Browsers DO fire a `scroll` event when you assign `container.scrollTop`.
// We can't prevent that, but we CAN mark the next few scroll events as
// "programmatic" so the logger can label them. `markProgrammatic()` bumps
// the counter; `consumeProgrammatic()` returns true exactly once per
// pending mark.
//
// Pattern: `scrollToBottom()` calls `markProgrammatic()` BEFORE assigning
// scrollTop, so the resulting scroll event reads `origin: 'programmatic'`
// even though the browser fires it asynchronously.

let programmaticScrollsRemaining = 0
let programmaticScrollsResetTimer: ReturnType<typeof setTimeout> | null = null

/** Call this BEFORE a programmatic `scrollTop` assignment. */
export const markProgrammatic = (): void => {
  programmaticScrollsRemaining += 1
  // Safety net: if the scroll event never fires (e.g., scrollTop didn't
  // actually change because we were already there), don't leak the mark.
  if (programmaticScrollsResetTimer) clearTimeout(programmaticScrollsResetTimer)
  programmaticScrollsResetTimer = setTimeout(() => {
    programmaticScrollsRemaining = 0
  }, 100)
}

/** Returns true once per pending programmatic mark, then decrements. */
export const consumeProgrammatic = (): boolean => {
  if (programmaticScrollsRemaining > 0) {
    programmaticScrollsRemaining -= 1
    return true
  }
  return false
}

// ─── Throttled debug queue ────────────────────────────────────────────────────
//
// Per-frame scroll samples are coalesced: we keep only the most recent
// context, and flush it 200ms after the last scroll event. This gives
// you 5 samples/sec instead of 60, with the final position always
// represented (trailing-edge flush).

let pendingDebugContext: ScrollContext | null = null
let pendingDebugTimer: ReturnType<typeof setTimeout> | null = null

const flushPendingDebug = (): void => {
  pendingDebugTimer = null
  if (!pendingDebugContext) return
  const ctx = pendingDebugContext
  pendingDebugContext = null
  // debug() would re-throttle; emit directly via emit().
  emit(ctx, 'debug')
}

// ─── Logger factory ───────────────────────────────────────────────────────────

export interface ScrollLogger {
  /**
   * Throttled per-frame sample. Safe to call on every scroll event.
   * `origin` is optional: omit it to let the logger resolve from the
   * `markProgrammatic` counter, or pass an explicit value to override.
   */
  debug: (ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & { origin?: ScrollOrigin }) => void
  /** State change / lifecycle event. Always logged. */
  info: (
    ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & {
      reason: ScrollReason
      origin?: ScrollOrigin
    },
  ) => void
  /** Warning — something unexpected but recoverable. */
  warn: (
    ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & {
      reason: ScrollReason
      origin?: ScrollOrigin
    },
  ) => void
  /** Error — scroll subsystem failed. */
  error: (
    ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & {
      reason: ScrollReason
      origin?: ScrollOrigin
    },
  ) => void
  /**
   * Mark the next scroll event(s) as programmatic. Call BEFORE any
   * `container.scrollTop = …` assignment. `count` defaults to 1 because
   * each assignment usually produces exactly one scroll event.
   */
  markProgrammatic: (count?: number) => void
}

/**
 * Create a scroll logger bound to a chat id.
 *
 * @param chatId  The chat session id (used to correlate logs across
 *                components and to label every line).
 */
export const createScrollLogger = (chatId: string): ScrollLogger => {
  // Auto-derive the context fields the caller usually can't be bothered
  // to pass. We re-read the container on every call because the geometry
  // changes constantly — caching it would defeat the purpose.
  //
  // `origin` resolution rule (called per-event):
  //   1. If the caller explicitly passed `origin`, use it (they know
  //      better — e.g. `onSpacersResized` knows the upcoming scroll
  //      is programmatic even before `markProgrammatic` is consumed).
  //   2. Else, if a `markProgrammatic` is pending, consume it and
  //      label the event as programmatic.
  //   3. Else, default to 'user'.
  const resolveOrigin = (explicit?: ScrollOrigin): ScrollOrigin => {
    if (explicit) return explicit
    if (consumeProgrammatic()) return 'programmatic'
    return 'user'
  }

  const buildContext = (
    partial: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & { origin?: ScrollOrigin },
    reason: ScrollReason,
  ): ScrollContext => {
    const {
      scrollTop,
      scrollHeight,
      clientHeight,
      messages,
      isAtBottom,
      extra,
      containerInfo,
    } = partial
    const distanceFromTop = Math.max(0, scrollTop)
    const distanceFromBottom = Math.max(0, scrollHeight - scrollTop - clientHeight)
    const scrollable = scrollHeight - clientHeight
    const scrollPercent = scrollable > 0 ? Math.min(1, Math.max(0, scrollTop / scrollable)) : -1
    return {
      chatId,
      messages,
      scrollTop,
      scrollHeight,
      clientHeight,
      distanceFromTop,
      distanceFromBottom,
      scrollPercent,
      isAtBottom,
      origin: resolveOrigin(partial.origin),
      reason,
      containerInfo,
      extra,
    }
  }

  return {
    debug(partial) {
      const ctx = buildContext(partial, 'scroll-sample')
      pendingDebugContext = ctx
      if (pendingDebugTimer) return // already scheduled
      pendingDebugTimer = setTimeout(flushPendingDebug, DEBUG_THROTTLE_MS)
    },
    info(partial) {
      const ctx = buildContext(partial, partial.reason)
      emit(ctx, 'info')
    },
    warn(partial) {
      const ctx = buildContext(partial, partial.reason)
      emit(ctx, 'warn')
    },
    error(partial) {
      const ctx = buildContext(partial, partial.reason)
      emit(ctx, 'error')
    },
    markProgrammatic(count = 1) {
      programmaticScrollsRemaining += count
    },
  }
}

// ─── Emit ─────────────────────────────────────────────────────────────────────
//
// Single console.* call site so the formatting is consistent and the
// production gate is in one place.

let eventCounter = 0

const emit = (ctx: ScrollContext, level: 'debug' | 'info' | 'warn' | 'error'): void => {
  // Production gate: silence per-frame debug spam. Errors/warns always
  // log because they signal real problems.
  if (level === 'debug' && !import.meta.env.DEV) return

  eventCounter += 1
  let tag = `[scroll#${eventCounter} chat=${ctx.chatId} ${level.toUpperCase()}]`
  // Diagnostic markers for suspicious container states. These tell
  // you *which* check failed in a single glance — without them, a
  // `scrollHeight: 0` reading is just a useless zero.
  if (ctx.containerInfo.null) {
    tag += ' ⚠NO-CONTAINER'
  } else if (ctx.scrollHeight === 0 && ctx.clientHeight === 0) {
    tag += ` ⚠ZERO-SIZE(${ctx.containerInfo.tag ?? '?'} d=${ctx.containerInfo.display ?? '?'} oH=${ctx.containerInfo.offsetHeight})`
  } else if (ctx.scrollHeight === 0) {
    tag += ` ⚠ZERO-SCROLL-HEIGHT(${ctx.containerInfo.tag ?? '?'} ch=${ctx.clientHeight} d=${ctx.containerInfo.display ?? '?'})`
  } else if (ctx.clientHeight === 0) {
    tag += ` ⚠ZERO-CLIENT-HEIGHT(${ctx.containerInfo.tag ?? '?'} sh=${ctx.scrollHeight})`
  }
  const originMark = ctx.origin === 'programmatic' ? '⚙️' : '👆'
  const isAtBottomMark = ctx.isAtBottom ? '⤵' : '↑'
  // The "short" label is misleading when the container is 0×0 (which
  // is the whole point of the markers above). Show a more specific
  // label so the headline alone tells the story.
  const positionLabel =
    ctx.containerInfo.null
      ? 'no-container'
      : ctx.scrollHeight === 0
        ? 'zero-sh'
        : ctx.scrollPercent === -1
          ? 'short'
          : (ctx.scrollPercent * 100).toFixed(1) + '%'
  const line1 =
    `${tag} ${originMark} ${isAtBottomMark} ${ctx.reason} ` +
    `top=${ctx.scrollTop.toFixed(0)} ` +
    `bottom=${ctx.distanceFromBottom.toFixed(0)}px ` +
    `(${positionLabel}) ` +
    `msgs=${ctx.messages}`

  // Two-line format: first line is the headline (scannable in DevTools'
  // log group), second line is the full context object (collapsible).
  if (level === 'error') {
    console.error(line1, ctx)
  } else if (level === 'warn') {
    console.warn(line1, ctx)
  } else {
    // info and debug both use console.log with the object so the user
    // can click to expand.
    console.log(line1, ctx)
  }
}

// ─── Helpers exported for callers ─────────────────────────────────────────────

/**
 * Build the diagnostic `ContainerInfo` block for a container element.
 *
 * We deliberately AVOID calling `getComputedStyle` on every scroll
 * event — it forces a style recalculation, which is expensive at
 * 60 Hz. We only compute it when the dimensions look suspicious
 * (`scrollHeight === 0 || clientHeight === 0`), which is the only
 * time the diagnostic is useful anyway.
 */
const buildContainerInfo = (container: HTMLElement | null | undefined): ContainerInfo => {
  if (!container) return { null: true, offsetHeight: 0, offsetParent: null }
  const scrollHeight = container.scrollHeight
  const clientHeight = container.clientHeight
  const info: ContainerInfo = {
    null: false,
    tag: container.tagName,
    className: container.className,
    offsetHeight: container.offsetHeight,
    offsetParent: container.offsetParent ? container.offsetParent.tagName : null,
  }
  // Only pay the getComputedStyle cost when dimensions are weird.
  if (scrollHeight === 0 || clientHeight === 0) {
    const style = getComputedStyle(container)
    info.display = style.display
    info.visibility = style.visibility
  }
  return info
}

/**
 * Build a context object from a container element + the caller's
 * snapshot of state. Use this inside event handlers so the field
 * computation is centralized.
 *
 * Important: this function does NOT include `origin` in the returned
 * object. That's deliberate — the `ScrollLogger` methods own origin
 * resolution (`resolveOrigin` consults the `markProgrammatic` counter
 * + the caller's explicit override). If we returned `origin: 'user'`
 * here, callers who spread `...ctx` into `scrollLogger.info({...})`
 * would clobber the logger's resolution and every programmatic
 * scroll would log as `user`. The previous version of this function
 * had exactly that bug; this is the fix.
 */
export const buildScrollContext = (
  container: HTMLElement | null | undefined,
  fallback: Pick<ScrollContext, 'chatId' | 'messages' | 'isAtBottom'>,
  partial: Partial<Pick<ScrollContext, 'origin' | 'reason' | 'extra'>> = {},
): Omit<ScrollContext, 'reason' | 'origin'> & { reason?: ScrollReason; origin?: ScrollOrigin } => {
  const scrollTop = container?.scrollTop ?? 0
  const scrollHeight = container?.scrollHeight ?? 0
  const clientHeight = container?.clientHeight ?? 0
  return {
    chatId: fallback.chatId,
    messages: fallback.messages,
    isAtBottom: fallback.isAtBottom,
    scrollTop,
    scrollHeight,
    clientHeight,
    distanceFromTop: Math.max(0, scrollTop),
    distanceFromBottom: Math.max(0, scrollHeight - scrollTop - clientHeight),
    scrollPercent:
      scrollHeight - clientHeight > 0
        ? Math.min(1, Math.max(0, scrollTop / (scrollHeight - clientHeight)))
        : -1,
    // `origin` is intentionally omitted — see the doc comment above.
    // Callers that explicitly want to override (rare) can still pass
    // it via `partial.origin`, and `ScrollLogger` will honor it.
    reason: partial.reason,
    extra: partial.extra,
    containerInfo: buildContainerInfo(container),
  }
}
