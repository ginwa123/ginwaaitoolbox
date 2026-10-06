/**
 * `watch(...)` — all forms, blanket ban.
 *
 * This rule prohibits reacting to change entirely: every `watch()` call is
 * reported, no matter its source shape (ref, getter, array) or its options
 * (`deep`, `immediate`). It sits alongside the targeted rules
 * (`no-watch-effect`, `no-watch-array-source`, `no-derived-state-watch`,
 * `no-watch-feedback-loop`), which keep their precise messages for the
 * shapes they recognise — this one is the backstop that catches the rest,
 * including the legitimate-looking single-source side-effect watcher
 * (`watch(() => props.id, () => load())`, `watch(() => route.query?.detail,
 * ...)`).
 *
 * CONSEQUENCE STATED PLAINLY. Vue offers no alternative primitive for
 * signals that originate outside the component: router navigation
 * (Back/Forward), SSE reconnects, `document.title`, scroll restoration.
 * Those cannot move "into the event handler that caused the change"
 * because there is no handler — the browser chrome is the event source.
 * Banning `watch()` outright therefore freezes the current set of
 * reactions: the ~189 existing sites are pinned as baseline debt (see
 * `eslint-suppressions.json`), and any NEW reaction to an external signal
 * has no sanctioned spelling. Do not work around this rule with a getter
 * that hides the dependency or a polling loop — bring the case to review
 * so the exemption (or the new primitive) is a deliberate decision, not
 * an accident.
 *
 * SCOPE. Call-only: `watch(...)`, `Vue.watch(...)`, optional-call forms.
 * The `import { watch }` itself is left alone — an unused import is already
 * an error via `noUnusedLocals`, and flagging it here would double-report
 * every baselined file.
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

export const noWatch: Rule.RuleModule = {
  meta: {
    type: 'problem',
    docs: {
      description:
        'Disallow watch() in any form — do not react to change outside the causing handler.',
    },
    schema: [],
    messages: {
      noWatch:
        'New watch() calls are banned: reacting to change must live in the event handler that caused the change. If the signal originates outside the component (router, SSE, browser chrome) there is currently no sanctioned primitive — do not add the watcher, bring the case to review instead. (Pre-existing sites are pinned as baseline debt; this fires only on new ones.)',
    },
  },
  create(context) {
    const report = (node: Node): void => {
      context.report({ node: node as never, messageId: 'noWatch' })
    }

    return {
      CallExpression(node) {
        const call = node as unknown as Node
        if (calleeName(asNode(prop(call, 'callee'))) === 'watch') report(call)
      },
    }
  },
}
