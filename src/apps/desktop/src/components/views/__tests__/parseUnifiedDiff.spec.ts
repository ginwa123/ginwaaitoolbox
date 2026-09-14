import { describe, expect, it } from 'vitest'
import { escapeDiffHtml, parseUnifiedDiff } from '../chat_right_sidebar/parseUnifiedDiff'

const SAMPLE = `diff --git a/foo.txt b/foo.txt
index 123..456 100644
--- a/foo.txt
+++ b/foo.txt
@@ -1,3 +1,4 @@
 line1
-old
+new
+added
 line3`

describe('parseUnifiedDiff', () => {
  it('parses hunk header and counts added/removed', () => {
    const out = parseUnifiedDiff(SAMPLE)
    expect(out.added).toBe(2)
    expect(out.removed).toBe(1)
    expect(out.lines.some((l) => l.type === 'hunk')).toBe(true)
  })

  it('tracks line numbers across hunk', () => {
    const out = parseUnifiedDiff(SAMPLE)
    const add = out.lines.find((l) => l.type === 'add')
    const remove = out.lines.find((l) => l.type === 'remove')
    expect(add?.newLineNum).toBeDefined()
    expect(remove?.oldLineNum).toBeDefined()
  })

  it('returns empty lines for empty diff', () => {
    const out = parseUnifiedDiff('')
    expect(out.lines).toEqual([])
    expect(out.added).toBe(0)
    expect(out.removed).toBe(0)
  })

  it('skips git headers before first hunk', () => {
    const out = parseUnifiedDiff('diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n')
    expect(out.lines).toEqual([])
  })

  it('escapes html in diff lines', () => {
    expect(escapeDiffHtml('<b>&')).toBe('&lt;b&gt;&amp;')
    expect(escapeDiffHtml('')).toBe('&nbsp;')
  })
})
