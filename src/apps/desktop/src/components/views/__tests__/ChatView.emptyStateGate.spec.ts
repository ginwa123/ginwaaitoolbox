/**
 * Static contract: the chatview's EMPTY STATE may only render on a
 * server-confirmed empty transcript.
 *
 * Bug (screenshot: a session with a full transcript showing
 * "How can I help you? / Start a conversation by typing a message below",
 * reported as "if server is slow, keep await, don't show a like this"):
 *
 *  1. `apiFetch` aborts every request at 15 s. The transcript page is
 *     `PAGE_SIZE = 1000` rows and the constant's own comment warns about
 *     "slow TTFB with base64 image_urls" — so a slow backend trips the abort.
 *  2. `getChatHistory` swallowed every failure into
 *     `{ messages: [], ... }`. An aborted fetch therefore reached
 *     `loadChatHistory` as a SUCCESSFUL EMPTY transcript.
 *  3. The empty state was gated on "no groups and not loading" — a state that
 *     an unavailable backend also produces. ChatView's `catch` (and the
 *     `chat-load-error` block + Retry it feeds) was unreachable, because the
 *     throwing function it wrapped never threw.
 *
 * Full ChatView mount is too heavy for a unit test, so this spec greps the
 * source, following the repo's static-contract pattern (cf.
 * ChatView.worktreeSidebar.spec.ts).
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const chatViewSrc = readFileSync(resolve(__dirname, '../ChatView.vue'), 'utf8')
const apiSrc = readFileSync(resolve(__dirname, '../../../api/index.ts'), 'utf8')

describe('ChatView empty state is gated on a server-confirmed empty transcript', () => {
  it('the empty state template requires historyConfirmed', () => {
    // The exact expression, whitespace-tolerantly — prettier wraps this
    // `v-if` across several lines, so a single-line regex would silently stop
    // matching and let a broken file pass.
    expect(chatViewSrc).toMatch(
      /v-if="[\s\S]{0,120}?historyConfirmed\s*&&\s*!isInitializing\s*&&\s*!isLoading\s*&&\s*!error\s*&&\s*messageGroups\.length === 0[\s\S]{0,20}?"/,
    )
  })

  it('historyConfirmed starts false and is only set on a successful load', () => {
    expect(chatViewSrc).toMatch(/const historyConfirmed = ref\(false\)/)
    // Cleared at the start of every load ("not known yet")…
    expect(chatViewSrc).toMatch(/historyConfirmed\.value = false\n/)
    // …and set on the two success exits: cached mount and network commit.
    expect(chatViewSrc.match(/historyConfirmed\.value = true/g)).toHaveLength(2)
  })

  it('the transcript is fetched with the throwing variant, not the swallowing one', () => {
    // `getChatHistory` returning `[]` on failure IS the bug; the initial load
    // must use `fetchChatHistory`, which rejects. Scoped to
    // `runHistoryLoadAttempt` — `fetchOlderPage` legitimately keeps the
    // swallowing variant (a failed speculative page must not block the
    // foreground scroll-back path).
    const attemptBody = chatViewSrc.slice(
      chatViewSrc.indexOf('const runHistoryLoadAttempt = async () =>'),
      chatViewSrc.indexOf('const loadChatHistory = async () =>'),
    )
    expect(attemptBody).toMatch(/api\.fetchChatHistory\(\s*sessionId\.value,/)
    expect(attemptBody).not.toMatch(/api\.getChatHistory\(/)
    // ...with a budget above apiFetch's 15 s default.
    expect(attemptBody).toMatch(/INITIAL_HISTORY_TIMEOUT_MS/)
  })

  it('the initial load is wrapped in the retry schedule, with isLoading held across attempts', () => {
    expect(chatViewSrc).toMatch(/await fetchInitialHistoryWithRetry\(runHistoryLoadAttempt/)
    // The attempt body is a separate function so the retry re-runs the whole
    // thing (cache-prime included) rather than a half-applied load.
    expect(chatViewSrc).toMatch(/const runHistoryLoadAttempt = async \(\) =>/)
    // isLoading is set true in the wrapper and cleared only in ITS finally —
    // never between attempts, so the skeleton never flickers out mid-wait.
    expect(chatViewSrc).toMatch(
      /await fetchInitialHistoryWithRetry\(runHistoryLoadAttempt,[\s\S]*?finally \{\s*\n\s*isLoading\.value = false/,
    )
  })

  it('a fully-failed load lands in the error state, not the empty state', () => {
    expect(chatViewSrc).toMatch(/error\.value = 'Failed to load messages'/)
    // The catch that consumes the exhausted retry schedule.
    expect(
      chatViewSrc.match(
        /await fetchInitialHistoryWithRetry\(runHistoryLoadAttempt, \{[\s\S]*?\} catch \(err\) \{/,
      ),
    ).not.toBeNull()
  })
})

describe('getChatHistory keeps its best-effort contract; fetchChatHistory does not', () => {
  it('fetchChatHistory has no catch — a failure propagates to the caller', () => {
    // The whole point of the function is that it does NOT hand back an empty
    // transcript on failure, so it must contain no swallowing catch at all
    // (oxlint's no-useless-catch is what forced this shape; keep it).
    const body = apiSrc.slice(
      apiSrc.indexOf('export async function fetchChatHistory('),
      apiSrc.indexOf('export async function getChatHistory('),
    )
    expect(body).toMatch(/const data = await apiFetch<any>\(/)
    expect(body).not.toMatch(/\bcatch\b/)
    expect(body).not.toMatch(/messages: \[\]/)
  })

  it('getChatHistory still swallows — AppLayout cwd fallback + worktree refresh depend on it', () => {
    // Pinned by sseSkills.spec.ts too; reverting this reintroduces a silent
    // failure for the three best-effort metadata callers.
    expect(apiSrc).toMatch(
      /export async function getChatHistory\([\s\S]*?return await fetchChatHistory\(sessionId, limit, cursor, direction\)\s*\n\s*\} catch \(error\) \{/,
    )
  })
})
