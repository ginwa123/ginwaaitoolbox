/**
 * `watch([a, b], fn)` — the array-source form, Vue's spelling of
 * `useEffect(fn, [a, b])`.
 *
 * A single-source `watch(a, cb)` names the one change that re-runs the
 * callback, so a reader can see cause and effect. An array source re-runs
 * when ANY of its entries changes, without saying which one did — the
 * callback cannot tell "the branch changed" from "the cwd changed", so a
 * later refactor that adds a third entry silently widens when the effect
 * runs. That is the same implicit-dependency hazard React's
 * "You Might Not Need an Effect" warns about, just spelled with an explicit
 * list instead of an implicit closure.
 *
 * Split the watcher instead: one `watch` per source sharing a handler, or
 * move the work into the event handler that caused the change. (The
 * zero-dependency form, `watchEffect`, is banned outright by
 * `no-watch-effect`.)
 *
 * SCOPE. Only a direct array literal as the first argument is reported —
 * `watch([a, b], fn)`. A getter that happens to build an array,
 * `watch(() => [a.value, b.value], fn)`, is a single reactive source and is
 * out of scope here.
 *
 * At three occurrences in this repo, so it ships at `error` with no
 * baseline: the cost of the ban is three small rewrites and the value of
 * enforcing it is total.
 */
import type { Rule } from 'eslint'

type Node = { type: string }

function prop(node: Node | null | undefined, key: string): unknown {
  if (!node) return undefined
  return (node as unknown as Record<string, unknown>)[key]
}

function asNode(value: unknown): Node | null {
  if (!value || typeof value !== 'object') return null
  return typeof (value as { type?: unknown }).type === 'string' ? (value as Node) : null
}

/** Catch `watch(...)`, `Vue.watch(...)` and the optional-call form. */
function calleeName(callee: Node | null): string | null {
  if (!callee) return null
  if (callee.type === 'Identifier') return prop(callee, 'name') as string
  if (callee.type === 'MemberExpression' || callee.type === 'ChainExpression') {
    const inner = callee.type === 'ChainExpression' ? asNode(prop(callee, 'expression')) : callee
    const property = asNode(prop(inner, 'property'))
    return prop(property, 'type') === 'Identifier' ? (prop(property, 'name') as string) : null
  }
  return null
}

export const noWatchArraySource: Rule.RuleModule = {
  meta: {
    type: 'problem',
    docs: {
      description:
        'Disallow watch() with an array source — split into one single-source watcher per dependency.',
    },
    schema: [],
    messages: {
      arraySource:
        'watch([...], fn) re-runs when ANY entry changes without saying which one did. This is the Vue spelling of the useEffect(fn, [a, b]) anti-pattern: a later refactor can silently widen when this re-runs. Split it into one watch() per source sharing a handler, or move the work into the event handler that caused the change.',
    },
  },
  create(context) {
    const report = (node: Node): void => {
      context.report({ node: node as never, messageId: 'arraySource' })
    }

    return {
      CallExpression(node) {
        const call = node as unknown as Node
        if (calleeName(asNode(prop(call, 'callee'))) !== 'watch') return
        const args = prop(call, 'arguments')
        if (!Array.isArray(args)) return
        // Banning the array form but allowing a same-day reintroduction via
        // a variable (`const srcs = [a, b]; watch(srcs, fn)`) would leave a
        // one-line dodge, but resolving bindings is out of scope for this
        // rule — the literal covers the shape in this repo (3/3 sites).
        if (asNode(args[0])?.type === 'ArrayExpression') report(call)
      },
    }
  },
}
