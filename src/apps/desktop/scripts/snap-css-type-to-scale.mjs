/**
 * One-shot codemod: snap every remaining raw `font-size` in app chrome
 * onto the 10-step role scale in style.css's @theme block.
 *
 * PR #721 migrated the Tailwind CLASS sites (text-xs -> text-dense, …).
 * It did not touch `font-size:` declarations inside a `.vue` <style>
 * block, or `font-size:` in an inline style="" attribute. Those two are
 * the whole gap this script closes.
 *
 * Safety model — the one thing that makes this risky is that a
 * `font-size:` can be DATA rather than CSS. A file preview renders the
 * bytes of an HTML file, a diff viewer renders a patch, a design
 * element carries the user's own markup. Rewriting those changes what
 * the user sees of THEIR content, which is not ours to restyle.
 *
 * So a line is only rewritten when it is lexically inside a <style>
 * element, or is an inline style="" attribute on real template markup.
 * Everything else is left alone and reported as skipped.
 *
 * Every substitution is keyed by SELECTOR, not line number, so the map
 * below reads as the design decision it is, and survives an unrelated
 * edit shifting the file underneath it.
 */
import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import { join, extname, relative } from 'node:path'

const SRC = new URL('../src/', import.meta.url).pathname

/**
 * The value -> step map, in px for the reader's benefit.
 *
 * 1rem === 16px holds exactly here: there is no html/:root/body
 * font-size anywhere in the app, so every rem below is a clean multiple.
 */
const DEFAULT_MAP = {
  // Below the bottom of the ladder. 8 and 9px are not "a small step" —
  // they are under micro, and two sibling components disagree about the
  // same glyph (8px in the row, 10px in the card). micro is the floor.
  '8px': 'micro',
  '9px': 'micro',
  '10px': 'micro',
  '11px': 'meta',
  '12px': 'dense',
  '13px': 'dense', // the 13px hole — spelled 13px/12.8/13.6/0.8125rem
  '14px': 'body',
  '16px': 'lead',
  '18px': 'title-sm',
  '20px': 'title',
  '24px': 'title-lg',
  '0.6rem': 'micro', //  9.6px
  '0.65rem': 'micro', // 10.4px
  '0.7rem': 'meta', //   11.2px
  '0.75rem': 'dense', //  12px
  '0.8rem': 'dense', //   12.8px
  '0.8125rem': 'dense', // 13px, hand-converted and off the ladder
  '0.85rem': 'meta', //  13.6px
  '0.875rem': 'body', //  14px
  '0.9rem': 'body', //    14.4px
  '1rem': 'lead', //      16px
  '1.1rem': 'title-sm', // 17.6px
  '1.25rem': 'title', //  20px
}

/**
 * Judgment calls: a value whose nearest step is NOT its role's step.
 * Nearest-pixel would pick meta (11) for .gl-copy at 13.6px, but this is
 * a clickable button in a row whose text is meta — matching the row
 * beats halving a control the user aims at.
 */
const OVERRIDES = {
  'components/preview/Glob.vue': {
    // One header row, three sizes, none of them equal. The card title is
    // the anchor at dense; everything supporting it is micro; the caret
    // and the copy button are glyphs in a meta row, which is meta's
    // documented role.
    '.gl-summary': 'micro',
    '.gl-offset': 'micro',
    '.gl-warning-text': 'micro',
    '.gl-error-text': 'micro',
    '.gl-toggle': 'meta',
    '.gl-file-path': 'meta',
    '.gl-copy': 'meta',
  },
  'components/tool_outputs/AskUser.vue': {
    // A heading in a card whose body is dense, so body is the step above
    // it — not the 14.4px it had, and not dense.
    '.ask-user-question :deep(h6)': 'body',
  },
}

const changed = []
const skipped = []

function stepFor(file, selector, value) {
  const override = OVERRIDES[file]?.[selector]
  if (override) return override
  return DEFAULT_MAP[value] ?? null
}

function walk(dir) {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry === '__tests__') continue
    // Specs pattern-match the very class names this script rewrites, and
    // fixtures embed HTML strings carrying font-size on purpose.
    if (entry.includes('.spec.')) continue

    const full = join(dir, entry)
    if (statSync(full).isDirectory()) {
      walk(full)
      continue
    }
    if (extname(entry) !== '.vue' && extname(entry) !== '.css') continue
    process(full, readFileSync(full, 'utf8'))
  }
}

function process(file, text) {
  const rel = relative(SRC, file)
  const lines = text.split('\n')

  // Track which line ranges are inside a real <style> element, and which
  // CSS selector each declaration belongs to. Both are needed to keep the
  // override map addressable and to tell CSS from string data.
  let inStyle = false
  let inScript = false
  let selector = ''
  let touched = false

  // A block tag must be ALONE on its line, not merely appear on it. Two
  // real examples of why the looser match is a trap:
  //   WorkspaceItemTaskCard.vue:591  a comment reading "…the pulse keyframe
  //     lives in the scoped <style> block" flipped inStyle on and never
  //     off, silently skipping 300 lines including two font-size sites.
  //   KanbanView.vue:1641            a comment reading "<script setup>. Do
  //     NOT remove ref=…" does the same to inScript.
  // Requiring the tag to be the entire line also means the balance guard
  // below can trust the flag, so an unclosed block is reported, not hidden.
  const blockTag = (tag, closing) =>
    new RegExp(`^\\s*${closing ? '</' : '<'}${tag}\\b[^>]*>\\s*$`)
  const opensBlock = (tag) => blockTag(tag, false)
  const closesBlock = (tag) => blockTag(tag, true)

  const out = lines.map((line, i) => {
    if (opensBlock('style').test(line)) inStyle = true
    if (closesBlock('style').test(line)) {
      inStyle = false
      selector = ''
    }
    if (opensBlock('script').test(line)) inScript = true
    if (closesBlock('script').test(line)) inScript = false

    // A bare selector line: remember it so the next declaration can be
    // attributed. Handles `.a {`, `:deep(.b) {` and the second half of a
    // multi-line selector list like `.a,\n.b {`.
    const asSelector = /^\s*([.#:][^{]*?)\{\s*$/.exec(line)
    if (asSelector) {
      selector = asSelector[1].trim()
      return line
    }

    // --- inline style="" on real template markup -----------------------
    // These carry a font-size mid-line, so the whole-line rule below
    // never sees them. They are app chrome, but only when the attribute
    // sits in the TEMPLATE: the same `style="font-size:14px"` inside a
    // JS string is the default body of a design element the user then
    // edits, and rewriting it would edit their content.
    if (!inStyle && !inScript) {
      const inline = /style="([^"]*)"/.exec(line)
      if (inline) {
        const value = /font-size:\s*([0-9.]+(?:px|rem))/.exec(inline[1])?.[1]
        if (value) {
          const step = stepFor(rel, selector, value)
          if (step) {
            touched = true
            const next = inline[1].replace(
              /font-size:\s*[0-9.]+(?:px|rem)/,
              `font-size: var(--text-${step})`,
            )
            changed.push(`${rel}:${i + 1}  (inline style attr)  ${value} -> var(--text-${step})`)
            return line.replace(inline[0], `style="${next}"`)
          }
        }
      }
    }

    const m = /^(\s*font-size:\s*)([0-9.]+(?:px|rem))\s*(;?\s*)$/.exec(line)
    if (!m) return line

    // Not in a <style> block: only an inline style="" on real markup is
    // app chrome. Anything else is a string of HTML we are displaying.
    if (!inStyle) {
      skipped.push(`${rel}:${i + 1}  not CSS — left alone: ${line.trim().slice(0, 60)}`)
      return line
    }

    const [, lead, value] = m
    const step = stepFor(rel, selector, value)
    if (!step) {
      skipped.push(`${rel}:${i + 1}  ${value} has no step — left alone`)
      return line
    }

    touched = true
    changed.push(
      `${rel}:${i + 1}  ${selector || '(no selector)'}  ${value} -> var(--text-${step})`,
    )
    return `${lead}var(--text-${step})${m[3]}`
  })

  // A file that ends mid-<style> or mid-<script> means the block tracker
  // lost sync, and everything after that point was scanned under the wrong
  // rules — silently. Fail loudly instead: a half-scanned file is a worse
  // outcome than no scan, because it looks like a clean bill of health.
  if (inStyle || inScript) {
    throw new Error(
      `${rel}: ended with inStyle=${inStyle} inScript=${inScript}. ` +
        `A <style>/<script> block did not balance, so part of this file was ` +
        `scanned under the wrong rules. Refusing to write.`,
    )
  }

  if (touched) writeFileSync(file, out.join('\n'))
}

walk(SRC)

console.log(`\n=== CHANGED (${changed.length}) ===`)
for (const c of changed) console.log('  ' + c)
console.log(`\n=== SKIPPED (${skipped.length}) — data, not chrome ===`)
for (const s of skipped) console.log('  ' + s)
