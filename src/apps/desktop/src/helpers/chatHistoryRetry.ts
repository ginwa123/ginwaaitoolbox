/**
 * Retry policy for the INITIAL transcript fetch in ChatView.
 *
 * Why this exists: the chatview used to abort a slow `/messages` round-trip
 * on `apiFetch`'s 15 s default and — because `getChatHistory` swallowed the
 * failure into an empty transcript — render the empty state ("How can I help
 * you?") for a session that is full of messages. Two things had to change:
 * the failure must reach the caller, and the caller must WAIT rather than
 * surrender. This module owns the "how long do we wait" half.
 *
 * The composer is already disabled by `isInitializing` for the duration, so a
 * long wait costs the user nothing but a skeleton — which is exactly the
 * honest representation of "we asked the server and it hasn't answered yet".
 */

/**
 * Per-attempt budget. Deliberately far above `apiFetch`'s 15 s default:
 * the transcript page is `PAGE_SIZE = 1000` rows and routinely carries
 * base64 `image_urls` plus tool JSON, for which the constant's own comment
 * warns about "slow TTFB". Not `0` (unbounded) — a genuinely hung backend
 * would then park the skeleton forever, which is the failure mode the
 * default timeout exists to prevent.
 */
export const INITIAL_HISTORY_TIMEOUT_MS = 45_000

/**
 * Delay BEFORE each attempt, in order. The first entry is `0` — the initial
 * load must not wait. Each later entry is the backoff after that attempt
 * failed, so the full schedule is 4 attempts spanning ~7.75 s of waiting plus
 * however long each attempt itself takes.
 */
export const INITIAL_HISTORY_RETRY_DELAYS_MS: readonly number[] = [0, 750, 2000, 5000]

const defaultSleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms))

export interface RetryAttemptInfo {
  /** 1-based index of the attempt that just failed. */
  attempt: number
  /** How long we waited before the next attempt. */
  delayMs: number
  /** The rejection from the attempt that just failed. */
  error: unknown
}

/**
 * Run `attempt` until it resolves, waiting `delaysMs[attempt]` before each
 * try. Rejects with the LAST error once the schedule is exhausted — the
 * caller decides what an exhausted schedule means (for ChatView: the inline
 * error state plus its Retry button, never "this session is empty").
 *
 * `sleep` and `onRetry` are injectable so the policy can be unit-tested
 * without real timers.
 */
export async function fetchInitialHistoryWithRetry<T>(
  attempt: () => Promise<T>,
  options: {
    delaysMs?: readonly number[]
    sleep?: (ms: number) => Promise<void>
    onRetry?: (info: RetryAttemptInfo) => void
  } = {},
): Promise<T> {
  const delaysMs = options.delaysMs ?? INITIAL_HISTORY_RETRY_DELAYS_MS
  const sleep = options.sleep ?? defaultSleep
  const total = Math.max(1, delaysMs.length)
  let lastError: unknown = undefined

  for (let i = 0; i < total; i++) {
    const delayMs = delaysMs[i] ?? 0
    if (i > 0) {
      if (delayMs > 0) await sleep(delayMs)
      options.onRetry?.({ attempt: i, delayMs, error: lastError })
    }
    try {
      return await attempt()
    } catch (error) {
      lastError = error
    }
  }
  throw lastError
}
