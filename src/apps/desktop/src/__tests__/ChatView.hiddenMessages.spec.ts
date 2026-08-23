/**
 * Regression tests for the 2026-08-23 "hidden messages" fix.
 *
 * Background: several classes of legitimately-saved messages were
 * invisible in the chatview:
 *
 *   F1. `filteredMessages` dropped ANY message whose
 *       stripThinkingTags(content) was empty — including image-only
 *       user messages (content='' + image_urls) and role='tool' rows
 *       whose cards render from tool_name + envelope, not raw content.
 *
 *   F2. The user-group template rendered ONLY group.messages[0] —
 *       consecutive user messages beyond the first were invisible.
 *
 *   F3. No optimistic push of the user's own message on send — the
 *       bubble appeared only after the SSE echo / history refresh.
 *
 *   B4(frontend). reasoning_content was console.log-only — thinking
 *       models' output never rendered.
 *
 * The runtime paths are wired through Vue reactivity inside a 3500-line
 * SFC (hard to mount in isolation without the full ChatView harness —
 * see ChatView.updatePlan.spec.ts for the heavyweight variant). These
 * tests lock the SOURCE-LEVEL invariants so a refactor that reverts any
 * fix is caught immediately, following the project's source-grep
 * convention (sseIsInputOutput.spec.ts).
 */
import { describe, it, expect } from 'vitest'
import { stripThinkingTags } from '../helpers/stripTags'

const readChatViewSource = async (): Promise<string> => {
  const fs = await import('node:fs/promises')
  const path = await import('node:path')
  const chatviewPath = path.resolve(
    __dirname,
    '..',
    'components',
    'views',
    'ChatView.vue',
  )
  return fs.readFile(chatviewPath, 'utf8')
}

describe('F1 — filteredMessages exemptions (source contract)', () => {
  it('keeps image-only messages (image_urls populated)', async () => {
    const source = await readChatViewSource()
    // The exemption must exist INSIDE the filteredMessages filter body.
    expect(source).toMatch(/if \(\(m\.image_urls\?\.length \?\? 0\) > 0\) return true/)
  })

  it('keeps role=tool messages regardless of stripped content', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/if \(m\.role === 'tool'\) return true/)
  })

  it('keeps assistant messages that carry reasoning_content', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(
      /m\.role === 'assistant' && m\.reasoning_content && m\.reasoning_content\.trim\(\) !== ''/,
    )
  })
})

describe('F2 — user group renders ALL messages (source contract)', () => {
  it('template v-fors over group.messages instead of rendering [0] only', async () => {
    const source = await readChatViewSource()
    // The user branch must iterate every message...
    expect(source).toMatch(
      /v-for="\(userMsg, userMsgIdx\) in group\.messages"/,
    )
    // ...and must NOT render the old [0]-only text interpolation.
    expect(source).not.toMatch(/\{\{ group\.messages\[0\]!\.content \}\}/)
  })

  it('hasBubbleContent checks every user message, not just [0]', async () => {
    const source = await readChatViewSource()
    // The user branch of hasBubbleContent must use .some(...) over all
    // messages (the old code read group.messages[0] directly).
    const userBranch = source.match(
      /if \(group\.role === 'user'\) \{[\s\S]*?\n  \}/,
    )
    expect(userBranch).not.toBeNull()
    expect(userBranch![0]).toContain('group.messages.some(')
    expect(userBranch![0]).not.toContain('group.messages[0]')
  })
})

describe('F3 — optimistic user message push (source contract)', () => {
  it('pushes an optimistic user bubble in handleFileInputSubmit', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/optimistic-user-/)
    expect(source).toMatch(/role: 'user',\s*\n\s*content: userMessage/)
  })

  it('rolls back the optimistic bubble when send fails', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/messages\.value\.filter\(\(m\) => m\.id !== optimisticId\)/)
  })

  it('dedupes the SSE echo against the optimistic bubble', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/m\.id\.startsWith\('optimistic-user-'\)/)
  })
})

describe('B4(frontend) — reasoning_content rendering (source contract)', () => {
  it('maps reasoning_content in the loadChatHistory REST path', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/reasoning_content: msg\.reasoning_content \|\| undefined/)
  })

  it('maps reasoning_content in the SSE full handler', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/reasoning_content: event\.reasoning_content \|\| undefined/)
  })

  it('accepts full events with empty content but renderable fields', async () => {
    const source = await readChatViewSource()
    // The old gate `event.finish_reason && event.content` silently
    // dropped tool-result / image-only / reasoning-only events.
    expect(source).toMatch(/hasRenderableFullPayload/)
    expect(source).not.toMatch(
      /event\.type === 'full' && event\.finish_reason && event\.content\)/,
    )
  })

  it('renders a collapsible reasoning section in the assistant bubble', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/class="assistant-reasoning"/)
    expect(source).toMatch(/💭 Reasoning/)
  })

  it('accumulates reasoning chunks onto the streaming message', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(
      /existingMsg\.reasoning_content = \(existingMsg\.reasoning_content \|\| ''\) \+ event\.reasoning_content/,
    )
  })
})

describe('stripThinkingTags — filter interplay (unit)', () => {
  it('returns empty for whitespace-only content (the drop case)', () => {
    expect(stripThinkingTags('   ').trim()).toBe('')
    expect(stripThinkingTags('').trim()).toBe('')
  })

  it('returns empty for <think>-wrapped content when a sibling tag exists', () => {
    // With a <plain> sibling, the think block is stripped and the
    // plain wrapper unwrapped — leaving the inner text.
    expect(stripThinkingTags('<think>secret</think><plain>hello</plain>')).toBe('hello')
  })

  it('keeps lone <think> content intact (rendered as thinking bubble)', () => {
    // Lone <think> is returned unchanged by design — renderResponse
    // detects it via isThinkingTags and renders the collapsed variant.
    expect(stripThinkingTags('<think>reasoning only</think>')).toBe(
      '<think>reasoning only</think>',
    )
  })
})
