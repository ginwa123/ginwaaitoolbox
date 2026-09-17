/**
 * Source-contract tests for the 2026-09-09 chatview user-pill work:
 * cursor-pagination fixes + pill-rail wiring in ChatView.vue.
 *
 * Background: the loadMore branch of loadChatHistory never advanced
 * `messageCursor`/`hasMoreMessages` (assignments lived only in the
 * initial-load branch), so every 2nd+ loadMore re-sent the same cursor
 * and re-prepended the same page forever. No dedupe existed, and
 * PAGE_SIZE=1000 defeated pagination.
 *
 * ChatView is a 4000-line SFC (hard to mount — see
 * ChatView.hiddenMessages.spec.ts). These tests lock the SOURCE-LEVEL
 * invariants so a refactor that reverts any fix is caught immediately.
 */
import { describe, it, expect } from 'vitest'

const readChatViewSource = async (): Promise<string> => {
  const fs = await import('node:fs/promises')
  const path = await import('node:path')
  const chatviewPath = path.resolve(__dirname, '..', 'components', 'views', 'ChatView.vue')
  return fs.readFile(chatviewPath, 'utf8')
}

describe('pagination — cursor advances on loadMore', () => {
  it('advances messageCursor + hasMoreMessages on the initial load AND on every prepend', async () => {
    const source = await readChatViewSource()
    // Initial load: cursor + exhaustion flag come straight from the REST page.
    expect(source.match(/messageCursor\.value = data\.next_cursor/g) ?? []).toHaveLength(1)
    expect(source.match(/hasMoreMessages\.value = data\.has_more/g) ?? []).toHaveLength(1)
    // Every prepend (scroll-back, buffered prefetch, manual button) is routed
    // through `commitOlderPage`, which advances the cursor from the COMMITTED
    // page. Without this the 2nd+ page re-sends the same cursor and
    // re-prepends the same messages forever. Task_1789505423062_0 moved this
    // out of `loadChatHistory`'s old `loadMore` branch — assert it survives in
    // its new home rather than at the old location.
    const commitBody = source.slice(
      source.indexOf('const commitOlderPage = async ('),
      source.indexOf('const evaluateOlderPrefetch = '),
    )
    expect(commitBody.length).toBeGreaterThan(0)
    expect(commitBody).toContain('messageCursor.value = page.nextCursor')
    expect(commitBody).toContain('hasMoreMessages.value = page.hasMore')
  })

  it('dedupes prepended pages by id', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/new Set\(messages\.value\.map\(\(m\) => m\.id\)\)/)
    expect(source).toMatch(/\.filter\(\(m\) => !seenIds\.has\(m\.id\)\)/)
  })

  it('uses a bigger page size (not 1000, not 100)', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/const PAGE_SIZE = 500\b/)
    expect(source).not.toMatch(/const PAGE_SIZE = 1000/)
    expect(source).not.toMatch(/const PAGE_SIZE = 100\b/)
  })
})

describe('user-pill rail wiring', () => {
  it('imports and renders UserPillRail with pills + active index + jump handler', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/import UserPillRail.*from '\.\.\/chat\/UserPillRail\.vue'/)
    expect(source).toMatch(/<UserPillRail/)
    expect(source).toMatch(/v-if="userPills\.length >= 2"/)
    expect(source).toMatch(/:active-group-index="activePillGroupIndex"/)
    expect(source).toMatch(/@jump="jumpToUserGroup"/)
  })

  it('userPills covers user groups only and skips compaction envelopes', async () => {
    const source = await readChatViewSource()
    const block = source.match(/const userPills = computed\(\(\): UserPill\[\] => \{[\s\S]*?\n\}\)/)
    expect(block).not.toBeNull()
    expect(block![0]).toContain("g.role !== 'user'")
    expect(block![0]).toContain('isCompactionMessage')
    expect(block![0]).toContain('groupKey(g)')
  })

  it('group root carries a stable data-group-key for the flash query', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/:data-group-key="groupKey\(group\)"/)
  })

  it('jump marks programmatic, scrolls to the resolved item, and flashes', async () => {
    const source = await readChatViewSource()
    const fn = source.match(/const jumpToUserGroup = [\s\S]*?\n\}/)
    expect(fn).not.toBeNull()
    expect(fn![0]).toContain('scrollLogger.markProgrammatic()')
    expect(fn![0]).toContain('scrollToItem(target')
    expect(fn![0]).toContain('pill-jump-flash')
    // Index resolved by stable key at click time (SSE may shift positions).
    expect(fn![0]).toContain('findIndex((g) => groupKey(g) === key)')
  })
})
