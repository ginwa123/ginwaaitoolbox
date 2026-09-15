/**
 * Static contract: ChatView opens sidebar files in the in-app code
 * browser (which also updates the app URL to view=code-editor).
 *
 * The center diff's Open button emits `open {path, line?}` straight
 * to ChatView (mounted in the main column, not through the shell),
 * which calls the injected `openInCodeEditor` with the chat's
 * effectiveCwd.
 * Full ChatView mount is too heavy for a unit test, so this spec
 * greps the template source, following the repo's static-contract
 * pattern (cf. ChatView.prSidebar.spec.ts).
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const chatViewSrc = readFileSync(resolve(__dirname, '../ChatView.vue'), 'utf8')

describe('ChatView sidebar open-file wiring', () => {
  it('handles open-file via the injected code-browser opener', () => {
    expect(chatViewSrc).toMatch(
      /function onChatSidebarOpenFile\(payload: \{ path: string; line\?: number \}\)/,
    )
    expect(chatViewSrc).toMatch(/const openInEditor = useInjectOpenInCodeEditor\(\)/)
    expect(chatViewSrc).toMatch(
      /void openInEditor\(\{ filePath: payload\.path, cwd: effectiveCwd\.value, line: payload\.line \}\)/,
    )
  })

  it('subscribes to the center diff open emit', () => {
    expect(chatViewSrc).toMatch(/@open="onChatSidebarOpenFile"/)
  })
})
