/**
 * Static contract: ChatView feeds the session's attached-PR binding
 * into the right sidebar so the panel flips to PR-changes mode.
 *
 * The binding (sessions.pr_url + pr_provider, set_pull_request tool)
 * arrives via getChatHistory — at mount (loadChatHistory) and on
 * re-sync (refreshWorktreeBinding, also fired by set_pull_request
 * SSE completions). Full ChatView mount is too heavy for a unit
 * test, so this spec greps the template source, following the
 * repo's static-contract pattern (cf. ChatView.worktreeSidebar.spec.ts).
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const chatViewSrc = readFileSync(resolve(__dirname, '../ChatView.vue'), 'utf8')

describe('ChatView PR sidebar wiring', () => {
  it('holds the attached-PR binding in refs', () => {
    expect(chatViewSrc).toMatch(/const chatPrUrl = ref\(''\)/)
    expect(chatViewSrc).toMatch(/const chatPrProvider = ref\(''\)/)
  })

  it('loads the binding at mount and re-syncs on refresh', () => {
    expect(chatViewSrc).toMatch(/if \(data\.pr_url !== undefined\)/)
    expect(chatViewSrc).toMatch(/chatPrUrl\.value = data\.pr_url \?\? ''/)
    expect(chatViewSrc).toMatch(/chatPrProvider\.value = data\.pr_provider \?\? ''/)
  })

  it('re-syncs on set_pull_request SSE completions', () => {
    expect(chatViewSrc).toMatch(/toolName === 'set_pull_request'/)
  })

  it('passes the binding to the sidebar', () => {
    expect(chatViewSrc).toMatch(/:pr-url="chatPrUrl"/)
    expect(chatViewSrc).toMatch(/:pr-provider="chatPrProvider"/)
  })
})
