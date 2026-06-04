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

/**
 * Diagnostic snapshot of the VirtualScroller **component** (not the inner
 * container). This is the next layer out from `containerInfo` — it tells
 * you whether the ref binding itself is even valid.
 *
 * The most common reason a chat appears to "flicker" with `NO-CONTAINER`
 * is that `virtualScrollerRef.value` is null (component unmounted, key
 * changed, ref not yet bound). Reading `containerInfo` alone can't
 * distinguish that from "container is mounted but 0×0" — the two bugs
 * need completely different fixes.
 *
 *   refNull=true              → the component ref was never populated
 *                                (unmounted, wrong element bound, or
 *                                the call originated from a stale
 *                                component instance after a key change)
 *   containerRefNull=true     → the component is mounted but its inner
 *                                `containerRef` is still null (the
 *                                template ref hasn't fired yet — race
 *                                between onMounted of parent vs child)
 *   hasScrollToBottom=false   → the component is missing the expected
 *                                exposed method (probably unmounted
 *                                mid-flight)
 *   exposedKeys               → what keys ARE on the component
 *                                instance. Useful when "the ref isn't
 *                                null but it doesn't have the methods
 *                                I expect" — points to a wrong cast
 *                                or a build that didn't include the
 *                                latest `defineExpose`.
 */
export interface ScrollerState {
  refNull: boolean
  containerRefNull: boolean
  hasScrollToBottom: boolean
  hasContainerRef: boolean
  containerClientHeight: number
  containerOffsetHeight: number
  exposedKeys: string[]
}

/**
 * Diagnostic snapshot of the **outer flex wrapper** that contains the
 * VirtualScroller. This is the layer ABOVE the scroller, so it answers
 * "did the layout chain even reach the scroller's parent?".
 *
 * When `containerInfo.null` AND `wrapperState.offsetHeight === 0`, you
 * know the layout chain is broken higher up (the parent flex container
 * isn't sized). When `wrapperState.offsetHeight > 0` but the scroller
 * is 0×0, the layout chain reaches the wrapper but the scroller itself
 * isn't getting a height (the `flex flex-col` requirement from the
 * ChatView fix).
 *
 * `display` and `flexDirection` are only populated when dimensions are
 * weird (≥ 0) — `getComputedStyle` forces a style recalc which is
 * expensive at 60 Hz, so we only pay for it on the suspicious path.
 */
export interface WrapperState {
  refNull: boolean
  offsetHeight: number
  clientHeight: number
  offsetParent: string | null
  display?: string
  flexDirection?: string
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
  /**
   * Which function in ChatView produced this log line, e.g.
   * `'loadChatHistory'`, `'updateStreamingMessage'`,
   * `'watcher:messages-length'`, `'onSpacersResized'`. Set by the
   * call site (the logger can't infer it without a stack trace on
   * every call, which is too expensive).
   *
   * Without this, multiple `NO-CONTAINER` lines from different call
   * sites look identical and you can't tell whether the bug is in
   * the initial-load path, the SSE chunk path, the loadMore path,
   * or the watcher. With it, a `grep caller=updateStreamingMessage`
   * immediately isolates the streaming-path bug.
   */
  caller?: string
  /**
   * Diagnostic snapshot of the VirtualScroller **component** (see
   * `ScrollerState` doc). Tells you whether the ref binding is
   * even valid — the most common reason for `containerInfo.null`
   * is that the component is unmounted and the ref is null, which
   * is a completely different bug from "container exists but 0×0".
   */
  scrollerState?: ScrollerState
  /**
   * Diagnostic snapshot of the outer flex wrapper (see
   * `WrapperState` doc). Tells you whether the layout chain
   * reached the scroller's parent. Crucial for distinguishing
   * "wrapper is sized but scroller isn't" from "wrapper itself
   * is 0 high" — the two cases need different fixes.
   */
  wrapperState?: WrapperState
  /**
   * Short stack trace captured ONLY when the container is null or
   * on warn/error. The single most useful field for "where did
   * this come from?" — points directly to the line in ChatView
   * that called the logger with a stale ref.
   */
  stack?: string
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
  debug: (
    ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & { origin?: ScrollOrigin; caller?: string },
  ) => void
  /** State change / lifecycle event. Always logged. */
  info: (
    ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & {
      reason: ScrollReason
      origin?: ScrollOrigin
      caller?: string
    },
  ) => void
  /** Warning — something unexpected but recoverable. */
  warn: (
    ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & {
      reason: ScrollReason
      origin?: ScrollOrigin
      caller?: string
    },
  ) => void
  /** Error — scroll subsystem failed. */
  error: (
    ctx: Omit<ScrollContext, 'chatId' | 'reason' | 'origin'> & {
      reason: ScrollReason
      origin?: ScrollOrigin
      caller?: string
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

  // ── Caller / scroller / wrapper metadata in the tag ───────────────────
  //
  // The most useful single line you can get when something goes wrong
  // is "which function called me, was the scroller ref valid, and was
  // the wrapper sized". Without these you have to dig through the
  // context object; with them, a single DevTools scan tells the story.
  //
  //   caller=X         — the function name (e.g. 'loadChatHistory')
  //   scroller=Y       — 'ok' | 'ref-null' | 'container-null'
  //   wrapper=Z        — 'h=N' | 'ref-null' | 'd=flex,h=0' (when weird)
  //
  // Each is optional — we render what's available.
  if (ctx.caller) {
    tag += ` caller=${ctx.caller}`
  }
  if (ctx.scrollerState) {
    if (ctx.scrollerState.refNull) {
      tag += ' scroller=ref-null'
    } else if (ctx.scrollerState.containerRefNull) {
      tag += ' scroller=container-null'
    } else {
      tag += ` scroller=ok(h=${ctx.scrollerState.containerClientHeight})`
    }
  }
  if (ctx.wrapperState) {
    if (ctx.wrapperState.refNull) {
      tag += ' wrapper=ref-null'
    } else if (ctx.wrapperState.offsetHeight === 0) {
      tag += ` wrapper=h=0(d=${ctx.wrapperState.display ?? '?'},flex=${ctx.wrapperState.flexDirection ?? '?'})`
    } else {
      tag += ` wrapper=h=${ctx.wrapperState.offsetHeight}`
    }
  }

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

  // ── Lazy stack capture for hard-to-debug cases ─────────────────────────
  //
  // `new Error().stack` is expensive (allocates an Error + walks the
  // stack), so we only do it when the log line is actually hard to
  // diagnose from the other fields:
  //
  //   - container is null (the "no idea where this came from" case)
  //   - level is warn or error (something went wrong)
  //
  // Normal info/debug lines skip this entirely. The stack is stripped
  // to the first 5 frames so it stays scannable.
  if (!ctx.stack && (ctx.containerInfo.null || level === 'warn' || level === 'error')) {
    try {
      const err = new Error()
      const raw = err.stack ?? ''
      // Drop frames that are inside this file (the logger itself) —
      // the caller is what we want.
      const frames = raw
        .split('\n')
        .filter((line) => !line.includes('scrollLogger.ts'))
        .slice(0, 5)
        .join('\n')
      if (frames) ctx.stack = frames
    } catch {
      // stack capture is best-effort; never let it break logging
    }
  }

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
 * Build the diagnostic `ScrollerState` block for a VirtualScroller
 * component ref. Reads the component instance to determine whether
 * the ref is even populated, whether the inner container is
 * populated, and which exposed methods exist.
 *
 * Accepts the full ref object (`.value` style) so we can distinguish
 * "ref object exists but `.value` is null" from "ref object itself
 * is missing". Both are passed as `{ value: unknown }` shapes.
 */
const buildScrollerState = (scrollerRef: { value: unknown } | null | undefined): ScrollerState => {
  if (!scrollerRef) {
    return {
      refNull: true,
      containerRefNull: true,
      hasScrollToBottom: false,
      hasContainerRef: false,
      containerClientHeight: 0,
      containerOffsetHeight: 0,
      exposedKeys: [],
    }
  }
  const scroller = scrollerRef.value as Record<string, unknown> | null
  if (!scroller) {
    return {
      refNull: true,
      containerRefNull: true,
      hasScrollToBottom: false,
      hasContainerRef: false,
      containerClientHeight: 0,
      containerOffsetHeight: 0,
      exposedKeys: [],
    }
  }
  const containerRef = scroller.containerRef as { value: unknown } | undefined
  const hasContainerRef = !!containerRef
  const container = (containerRef?.value ?? null) as HTMLElement | null
  return {
    refNull: false,
    containerRefNull: !container,
    hasScrollToBottom: typeof scroller.scrollToBottom === 'function',
    hasContainerRef,
    containerClientHeight: container?.clientHeight ?? 0,
    containerOffsetHeight: container?.offsetHeight ?? 0,
    exposedKeys: Object.keys(scroller).sort(),
  }
}

/**
 * Build the diagnostic `WrapperState` block for the outer flex
 * wrapper. Tells you whether the layout chain reached the
 * scroller's parent. Like `buildContainerInfo`, only pays the
 * `getComputedStyle` cost when dimensions are weird.
 */
const buildWrapperState = (wrapperRef: { value: unknown } | null | undefined): WrapperState => {
  if (!wrapperRef) {
    return { refNull: true, offsetHeight: 0, clientHeight: 0, offsetParent: null }
  }
  const wrapper = wrapperRef.value as HTMLElement | null
  if (!wrapper) {
    return { refNull: true, offsetHeight: 0, clientHeight: 0, offsetParent: null }
  }
  const info: WrapperState = {
    refNull: false,
    offsetHeight: wrapper.offsetHeight,
    clientHeight: wrapper.clientHeight,
    offsetParent: wrapper.offsetParent ? wrapper.offsetParent.tagName : null,
  }
  // getComputedStyle forces a style recalc — only do it when
  // dimensions are suspicious, same logic as buildContainerInfo.
  if (wrapper.offsetHeight === 0 || wrapper.clientHeight === 0) {
    const style = getComputedStyle(wrapper)
    info.display = style.display
    info.flexDirection = style.flexDirection
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
  fallback: Pick<ScrollContext, 'chatId' | 'messages' | 'isAtBottom'> & {
    /**
     * The VirtualScroller ref from ChatView. Optional — when omitted,
     * `scrollerState` is not populated. Pass the full ref object
     * (`virtualScrollerRef`), NOT `virtualScrollerRef.value` — the
     * logger inspects both the ref and the component instance.
     */
    virtualScrollerRef?: { value: unknown } | null
    /**
     * The outer flex wrapper ref from ChatView. Optional — when
     * omitted, `wrapperState` is not populated.
     */
    wrapperRef?: { value: unknown } | null
  },
  partial: Partial<Pick<ScrollContext, 'origin' | 'reason' | 'extra' | 'caller'>> = {},
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
    caller: partial.caller,
    containerInfo: buildContainerInfo(container),
    scrollerState: buildScrollerState(fallback.virtualScrollerRef),
    wrapperState: buildWrapperState(fallback.wrapperRef),
  }
}
