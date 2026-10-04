/**
 * `watchEffect` — Vue's closest literal analogue of `useEffect`.
 *
 * `watch(a, cb)` names its dependencies, so a reader can see what re-runs the
 * callback. `watchEffect(cb)` tracks them implicitly: every reactive value the
 * body READS becomes a dependency, and a dependency added six months later by
 * an innocent refactor silently changes when the effect re-runs. That is why
 * React's own guidance is that an effect is usually not the primitive you
 * want — and why `watchEffect` is the one form of `watch` banned outright.
 *
 * Use `watch` with an explicit source, or `computed` when nothing outside the
 * component needs to happen.
 *
 * At zero occurrences in this repo, so it ships at `error` with no baseline:
 * the cost of the ban is zero and the value of enforcing it is total.
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

/** Catch `watchEffect(...)`, `Vue.watchEffect(...)` and the optional-call form. */
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

export const noWatchEffect: Rule.RuleModule = {
  meta: {
    type: 'problem',
    docs: {
      description:
        'Disallow watchEffect() — its implicit dependency tracking hides when the effect re-runs.',
    },
    schema: [],
    messages: {
      watchEffect:
        'watchEffect() tracks its dependencies implicitly: any reactive value the body reads becomes a trigger, so a later refactor can silently change when this re-runs. This is the Vue spelling of the useEffect anti-pattern. Use `watch(source, cb)` with an explicit source, or `computed()` if nothing outside the component needs to happen.',
    },
  },
  create(context) {
    const report = (node: Node): void => {
      context.report({ node: node as never, messageId: 'watchEffect' })
    }

    return {
      CallExpression(node) {
        const call = node as unknown as Node
        if (calleeName(asNode(prop(call, 'callee'))) === 'watchEffect') report(call)
      },
      ImportDeclaration(node) {
        const decl = node as unknown as Node
        const specifiers = prop(decl, 'specifiers')
        if (!Array.isArray(specifiers)) return
        // Banning the call but allowing the import would leave a one-line dodge.
        if (
          specifiers.some(
            (s) => prop(asNode(prop(asNode(s), 'imported')), 'name') === 'watchEffect',
          )
        ) {
          report(decl)
        }
      },
    }
  },
}
