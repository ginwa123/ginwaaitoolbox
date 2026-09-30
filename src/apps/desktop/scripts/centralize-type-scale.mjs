/**
 * One-shot codemod: move every font-size in src/ onto the type scale
 * defined in style.css's @theme block.
 *
 * Two families of source value collapse onto the same ramp:
 *   - hand-rolled arbitrary values (text-[0.65rem], text-[11px], …) that
 *     were four different spellings of one size,
 *   - Tailwind's numeric ladder (text-xs, text-sm, …) renamed by ROLE.
 *
 * The numeric ladder rename is value-identical, so it changes no pixels;
 * the arbitrary-value collapse does change pixels, deliberately, because
 * nine near-duplicate sizes are the thing being reported as untidy.
 *
 * Specs are skipped: they contain regexes that PATTERN-MATCH these
 * classes and must keep describing the old spelling to stay meaningful.
 */
import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import { join, extname } from 'node:path'

const SRC = new URL('../src/', import.meta.url).pathname

/** Arbitrary px/rem -> ramp step. Value-preserving except where noted. */
const ARBITRARY = {
  '0.6rem': 'micro', // 9.6px  -> 10px
  '0.65rem': 'micro', // 10.4px -> 10px
  '9px': 'micro',
  '10px': 'micro',
  '0.7rem': 'meta', // 11.2px -> 11px
  '0.72rem': 'meta', // 11.52px -> 11px
  '11px': 'meta',
  '0.8rem': 'dense', // 12.8px -> 12px
  '12px': 'dense',
  '13px': 'dense', // 13px -> 12px (the one straggler; see the sidebar)
  '14px': 'dense', // not a ramp step; only reachable if one appears
}

/** Tailwind's numeric ladder -> the same step under its role name. */
const NAMED = {
  'text-4xl': 'text-display-lg',
  'text-3xl': 'text-display',
  'text-2xl': 'text-title-lg',
  'text-xl': 'text-title',
  'text-lg': 'text-title-sm',
  'text-base': 'text-lead',
  'text-sm': 'text-body',
  'text-xs': 'text-dense',
}

/** The sidebar's private type tokens -> their step on the shared ramp. */
const SIDEBAR = {
  'text-[var(--sb-fs-section)]': 'text-micro',
  'text-[var(--sb-fs-row)]': 'text-dense',
  'text-[var(--sb-fs-meta)]': 'text-micro',
  'text-[var(--sb-fs-icon)]': 'text-meta',
}

// Longest source first so `text-2xl` is never eaten by `text-xl`.
const literal = [
  ...Object.entries(SIDEBAR),
  ...Object.entries(ARBITRARY).map(([v, step]) => [`text-[${v}]`, `text-${step}`]),
  ...Object.entries(NAMED),
].sort((a, b) => b[0].length - a[0].length)

// The keys contain `[` / `(` (arbitrary values), so they are escaped
// before being used as alternation branches.
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

const literalRe = new RegExp(
  `(?<![\\w-])(${literal.map(([k]) => escapeRe(k)).join('|')})(?![\\w-])`,
  'g'
)

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (['.vue', '.ts'].includes(extname(p)) && !p.endsWith('.spec.ts')) out.push(p)
  }
  return out
}

let files = 0
let edits = 0
for (const file of walk(SRC)) {
  const before = readFileSync(file, 'utf8')
  const after = before.replace(literalRe, (m) => literal.find(([k]) => k === m)?.[1] ?? m)
  if (after === before) continue
  const n = (before.match(literalRe) ?? []).length
  files++
  edits += n
  writeFileSync(file, after)
  console.log(`${n.toString().padStart(3)}  ${file.slice(SRC.length)}`)
}
console.log(`\n${edits} class sites across ${files} files`)
