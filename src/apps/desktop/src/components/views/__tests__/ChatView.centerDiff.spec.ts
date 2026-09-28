/**
 * Static contract: ChatView swaps its main column to a full-height
 * diff when a sidebar file is clicked (center-stage design — no
 * dialog, no overlay sidebar).
 *
 * Panel row clicks bubble `show-diff {path, staged, lines, added,
 * removed, error?}`: panel → shell → ChatView, which stores the
 * payload in `centerDiff` and renders `SidebarDiffView` in place of
 * messages+composer (v-show preserves their state underneath). Back
 * clears; a changed cwd drops the stale diff; retry re-fetches via
 * the shell's `reloadDiff`. Full ChatView mount is too heavy for a
 * unit test, so this spec greps the template source, following the
 * repo's static-contract pattern (cf. ChatView.prSidebar.spec.ts).
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const chatViewSrc = readFileSync(resolve(__dirname, '../ChatView.vue'), 'utf8')

describe('ChatView center-stage diff', () => {
  it('holds the selection and swaps on show-diff', () => {
    expect(chatViewSrc).toMatch(/const centerDiff = ref<DiffSelection \| null>\(null\)/)
    expect(chatViewSrc).toMatch(/function onChatSidebarShowDiff\(selection: DiffSelection\)/)
    expect(chatViewSrc).toMatch(/@show-diff="onChatSidebarShowDiff"/)
  })

  it('renders the center diff with back/open/retry/review wiring', () => {
    expect(chatViewSrc).toMatch(/data-testid="chat-center-diff"/)
    expect(chatViewSrc).toMatch(/@click="onCenterDiffBack"/)
    expect(chatViewSrc).toMatch(/@retry="onCenterDiffRetry"/)
    expect(chatViewSrc).toMatch(/@submit-review="onChatSidebarSubmitReview"/)
    expect(chatViewSrc).toMatch(/@comment-saved="onChatSidebarCommentSaved"/)
    expect(chatViewSrc).toMatch(/function onCenterDiffRetry\(\)/)
    expect(chatViewSrc).toMatch(/function onChatSidebarCommentSaved\(/)
  })

  it('persists review comments instead of sending them to the LLM', () => {
    const start = chatViewSrc.indexOf('function onChatSidebarSubmitReview')
    expect(start).toBeGreaterThan(-1)
    const end = chatViewSrc.indexOf('\n}\n', start)
    expect(end).toBeGreaterThan(start)
    expect(chatViewSrc.slice(start, end)).not.toMatch(/sendChatMessage/)
    const savedStart = chatViewSrc.indexOf('function onChatSidebarCommentSaved')
    expect(savedStart).toBeGreaterThan(-1)
    const savedEnd = chatViewSrc.indexOf('\n}\n', savedStart)
    expect(chatViewSrc.slice(savedStart, savedEnd)).not.toMatch(/sendChatMessage/)
    expect(chatViewSrc).toMatch(/savedReviewComments/)
    expect(chatViewSrc).toMatch(/diff-review-comments/)
  })

  it('hides messages+composer while a center stage shows (state preserved)', () => {
    // One gate for BOTH center stages (stacked diff + code viewer) so the
    // composer can never float over either one.
    expect(chatViewSrc).toMatch(/v-show="!showCenterStage"\s+ref="messagesWrapperRef"/)
    expect(chatViewSrc).toMatch(/v-if="!hideInput"\s+v-show="!showCenterStage"/)
    expect(chatViewSrc).toMatch(
      /const showCenterStage = computed\(\(\) => showCenterDiff\.value \|\| showCodeViewer\.value\)/,
    )
  })

  it('drops stale diffs on cwd change', () => {
    expect(chatViewSrc).toMatch(/\(\) => effectiveCwd\.value,/)
    expect(chatViewSrc).toMatch(/centerDiff\.value = null/)
    expect(chatViewSrc).toMatch(/centerFiles\.value = \[\]/)
  })
})
