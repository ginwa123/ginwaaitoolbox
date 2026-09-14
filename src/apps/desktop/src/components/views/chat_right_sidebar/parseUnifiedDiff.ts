export interface ParsedDiffLine {
  type: 'add' | 'remove' | 'context' | 'header' | 'hunk' | 'empty'
  content: string
  oldLineNum?: number
  newLineNum?: number
  lineIndex: number
}

export interface ParsedDiff {
  lines: ParsedDiffLine[]
  added: number
  removed: number
}

function tryParseInt(s: string): number | null {
  const n = parseInt(s, 10)
  return isNaN(n) ? null : n
}

// Pure extraction of GitFileViewer.vue parseUnifiedDiff logic so the
// ChatView-embedded sidebar and the legacy fullscreen viewer share one
// parser. No Vue reactivity here — takes a string, returns data.
export function parseUnifiedDiff(diffText: string): ParsedDiff {
  const lines = diffText.split('\n')
  const parsed: ParsedDiffLine[] = []

  let added = 0
  let removed = 0
  let lineIndex = 0

  let oldLine = 0
  let newLine = 0
  let inHunk = false

  for (const line of lines) {
    if (line.startsWith('diff --git') || line.startsWith('index ')) {
      continue
    }

    const hunkMatch = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)?$/)
    if (hunkMatch) {
      inHunk = true
      oldLine = tryParseInt(hunkMatch[1] ?? '') ?? 1
      newLine = tryParseInt(hunkMatch[2] ?? '') ?? 1

      parsed.push({
        type: 'hunk',
        content: line,
        lineIndex: lineIndex++,
      })
      continue
    }

    if (!inHunk) {
      if (line.startsWith('---') || line.startsWith('+++')) {
        continue
      }
      continue
    }

    if (line.length === 0) {
      parsed.push({
        type: 'empty',
        content: '',
        oldLineNum: oldLine,
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      continue
    }

    const firstChar = line[0]

    if (firstChar === '+') {
      parsed.push({
        type: 'add',
        content: line.substring(1),
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      added++
      newLine++
    } else if (firstChar === '-') {
      parsed.push({
        type: 'remove',
        content: line.substring(1),
        oldLineNum: oldLine,
        lineIndex: lineIndex++,
      })
      removed++
      oldLine++
    } else if (firstChar === ' ') {
      parsed.push({
        type: 'context',
        content: line.substring(1),
        oldLineNum: oldLine,
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      oldLine++
      newLine++
    } else {
      parsed.push({
        type: 'context',
        content: line,
        oldLineNum: oldLine,
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      oldLine++
      newLine++
    }
  }

  return { lines: parsed, added, removed }
}

export function escapeDiffHtml(line: string): string {
  if (!line) return '&nbsp;'
  return line.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
