/**
 * Regression guard for the banned-code rules.
 *
 * A lint rule that silently stops matching is worse than no rule — it looks
 * enforced and enforces nothing. So this spec pins BOTH directions:
 *
 *   - `forbids` — each ban actually fires on code shaped like the bug.
 *   - `allows`  — each ban stays silent on the legitimate forms that are
 *     common in this repo. This half is the one that matters most: a rule
 *     with false positives gets deleted, and deleting it takes the ban with
 *     it. Every `allows` case below is a shape that really exists in
 *     `src/` — the side-effect `watch(() => props.x, () => load())` idiom
 *     alone is ~46 of the 103 real call sites.
 *
 * Run with the repo's normal suite: `pnpm run test`.
 */
import { describe, expect, it } from 'vitest'
import { Linter } from 'eslint'
import tsParser from '@typescript-eslint/parser'
import plugin from '../../eslint-rules/index'

const linter = new Linter()

function lint(code: string): string[] {
  const messages = linter.verify(
    code,
    {
      files: ['**/*.ts'],
      languageOptions: {
        // The same parser the app lints with, so a rule that only works under
        // one parser cannot pass here and fail in `pnpm run lint:check`.
        parser: tsParser as never,
        parserOptions: { ecmaVersion: 2022, sourceType: 'module' },
      },
      plugins: { local: plugin as never },
      rules: {
        'local/no-watch-effect': 'error',
        'local/no-derived-state-watch': 'error',
        'local/no-silent-fallback-catch': 'error',
      },
    },
    // The filename is REQUIRED: a flat config's `files` array is a matching
    // filter, so without a path to match against the block is silently
    // skipped and every rule reports nothing. That failure mode is invisible
    // — the linter returns [] and the assertions below would pass vacuously.
    'probe.ts',
  )
  return messages.map((m) => m.ruleId as string)
}

describe('local/no-derived-state-watch', () => {
  it('flags a watch that only assigns a value computed from its source', () => {
    // The Vue spelling of `useEffect(() => setState(derived), [dep])`.
    expect(lint(`const b = ref(0); watch(() => a.n, (v) => { b.value = v * 2 })`)).toEqual([
      'local/no-derived-state-watch',
    ])
  })

  it('flags prop-mirroring, the most mechanical form of the bug', () => {
    // 10 real sites of this shape exist today (FileInput.vue:159,
    // TextReplace.vue:34, McpServerModal.vue:63, …).
    expect(
      lint(`watch(() => props.expanded, (next) => { isExpanded.value = next ?? false })`),
    ).toEqual(['local/no-derived-state-watch'])
  })

  it('flags the concise arrow body form', () => {
    expect(lint(`watch(a, (v) => (b.value = v))`)).toEqual(['local/no-derived-state-watch'])
  })

  it('allows a watch whose body calls a function — that is a side effect', () => {
    // The dominant idiom in this repo: `watch(() => props.x, () => load())`.
    expect(lint(`watch(() => props.id, () => { void load() })`)).toEqual([])
  })

  it('allows a watch that assigns AND fetches', () => {
    // Mixed bodies are the legitimate refactor target: pull the side effect
    // in, and the rule stops firing. That is what the message tells you.
    expect(lint(`watch(id, async (v) => { rows.value = await fetchRows(v) })`)).toEqual([])
  })

  it('allows a watch that stores to a pinia store, not a ref', () => {
    expect(lint(`watch(dir, (v) => { navigationStore.setDir(v) })`)).toEqual([])
  })

  it('allows an accumulator mixed with a real side effect', () => {
    // SseStatusBadge.vue:54 does `attempt.value += 1` alongside a diagnostic.
    // `+=` is not expressible as computed(), and the body touches the
    // outside world, so neither half of the rule applies. Flagging it would
    // be a false positive against the rule's own contract.
    expect(
      lint(`watch(bus.state, (s) => { if (s === 'up') { attempt.value += 1 }
        console.warn('reconnect', attempt.value) })`),
    ).toEqual([])
  })

  it('allows an empty watcher body (dead code, not derived state)', () => {
    // AgentView.vue:165 has one. It deserves a different message, not this one.
    expect(lint(`watch(() => props.tools, () => { /* re-render */ })`)).toEqual([])
  })

  it('allows a watch with a const declaration before the assignment', () => {
    // A local means the body computes something non-trivial.
    expect(
      lint(`watch(() => raw, (r) => { const next = r === 'rows' ? 'rows' : 'columns'
        if (next !== layout.value) layout.value = next })`),
    ).toEqual([])
  })
})

describe('local/no-watch-effect', () => {
  it('flags a watchEffect() call', () => {
    expect(lint(`watchEffect(() => { r.value = a.n })`)).toEqual(['local/no-watch-effect'])
  })

  it('flags importing watchEffect at all', () => {
    // Banning the call but allowing the import would leave a one-line dodge.
    expect(lint(`import { watchEffect } from 'vue'`)).toEqual(['local/no-watch-effect'])
  })

  it('flags the namespaced form', () => {
    expect(lint(`Vue.watchEffect(() => {})`)).toEqual(['local/no-watch-effect'])
  })

  it('allows watch(), which names its dependencies explicitly', () => {
    expect(lint(`watch(a, () => { load() })`)).toEqual([])
  })
})

describe('local/no-silent-fallback-catch', () => {
  it('flags a catch that returns [] with no diagnostic', () => {
    // This is PR #719: an outage and an empty session reached the UI as the
    // same value, so the error UI was dead code.
    expect(lint(`try { await load() } catch { return [] }`)).toEqual([
      'local/no-silent-fallback-catch',
    ])
  })

  it('flags an empty catch body with no comment', () => {
    expect(lint(`try { go() } catch {}`)).toEqual(['local/no-silent-fallback-catch'])
  })

  it('flags assigning a fallback ref with no diagnostic', () => {
    expect(lint(`try { go() } catch { items.value = [] }`)).toEqual([
      'local/no-silent-fallback-catch',
    ])
  })

  it('allows a catch that logs', () => {
    expect(lint(`try { await load() } catch (e) { console.error('load', e); return [] }`)).toEqual(
      [],
    )
  })

  it('allows a catch that surfaces into a rendered error ref', () => {
    // The sanctioned fix for the empty-vs-unavailable confusion.
    expect(lint(`try { go() } catch (e) { error.value = String(e); return [] }`)).toEqual([])
  })

  it('allows an empty catch whose comment explains the fallback', () => {
    // AGENTS.md sanctions this explicitly ("say a comment why"). authMe.ts
    // and designHistory.ts both use it. Flagging it would train people to
    // delete the rule instead of obey it.
    expect(
      lint(`try { localStorage.getItem('k') } catch {
        // private mode / quota — the live fetch below still works.
      }`),
    ).toEqual([])
  })

  it('allows a catch that rethrows', () => {
    expect(lint(`try { go() } catch (e) { throw e }`)).toEqual([])
  })

  it('allows a catch with a real fallback that is not "nothing there"', () => {
    // `return false` from a predicate is a decision, not an erasure.
    expect(lint(`try { return hasItems() } catch { return false }`)).toEqual([
      'local/no-silent-fallback-catch',
    ])
  })
})

describe('the rules compose without false positives on real shapes', () => {
  it('a realistic component using computed + side-effect watch + logged catch is clean', () => {
    const code = `
      import { ref, watch, computed } from 'vue'
      export function useRows(props) {
        const rows = ref([])
        const error = ref(null)
        const busy = ref(false)
        const count = computed(() => rows.value.length)

        watch(() => props.id, async (id) => {
          busy.value = true
          error.value = null
          try {
            rows.value = await fetchRows(id)
          } catch (e) {
            console.error('fetchRows', e)
            error.value = 'Failed to load rows'
          } finally {
            busy.value = false
          }
        })
        return { rows, error, busy, count }
      }
    `
    expect(lint(code)).toEqual([])
  })
})
