/**
 * `catch` that turns a failure into a value the caller cannot distinguish
 * from a legitimate answer.
 *
 * This is the shape the repo's AGENTS.md rule ("No try/catch in the desktop
 * app; use Effect-TS") was written about, but writing it down did not make it
 * hold: 441 production `catch` blocks survived and 242 of them emitted no
 * diagnostic at all. PR #719 is the canonical bug — `getChatHistory` returned
 * `messages: []` on transport failure AND on a real empty session, so
 * `error` stayed null and the UI rendered "How can I help you?" for a
 * session full of messages.
 *
 * The rule fires only on the mechanical core of that bug, which keeps it
 * honest rather than a blanket "no catch":
 *
 *   1. the `catch` body ASSIGNS a fallback that reads as "nothing there"
 *      (`null`, `undefined`, `[]`, `{}`, `''`, `false`), and
 *   2. it emits NO diagnostic — no `console.*`, no `throw`, no write to any
 *      binding whose name says it is an error (`error`, `loadError`, …).
 *
 * So the benign cases stay legal: a best-effort parse whose comment explains
 * the fallback, a `catch` that logs and returns `null`, or one that surfaces
 * into a rendered ref. What is banned is condition 1 AND 2 together — the
 * failure that disappears.
 */
import type { Rule } from 'eslint'

/** Values that are indistinguishable from "the operation found nothing". */
const FALLBACK_LITERALS = new Set([
  'null',
  'undefined',
  'false',
  'true',
  '0',
  "''",
  '``',
  '[]',
  '{}',
])

/** Binding names that carry a failure to a rendered ref. */
const ERROR_NAME = /error|err\b|failure|failed/i

type Node = { type: string }

function prop(node: Node | null | undefined, key: string): unknown {
  if (!node) return undefined
  return (node as unknown as Record<string, unknown>)[key]
}

function asNode(value: unknown): Node | null {
  if (!value || typeof value !== 'object') return null
  return typeof (value as { type?: unknown }).type === 'string' ? (value as Node) : null
}

function walk(
  node: Node | null | undefined,
  visit: (n: Node) => boolean | void,
  depth = 0,
): boolean {
  if (!node || depth > 60) return false
  if (visit(node) === true) return true
  const record = node as unknown as Record<string, unknown>
  for (const key of Object.keys(record)) {
    if (key === 'parent') continue
    const child = record[key]
    if (Array.isArray(child)) {
      for (const item of child) {
        if (walk(asNode(item), visit, depth + 1)) return true
      }
    } else {
      if (walk(asNode(child), visit, depth + 1)) return true
    }
  }
  return false
}

export const noSilentFallbackCatch: Rule.RuleModule = {
  meta: {
    type: 'problem',
    docs: {
      description:
        'Disallow catch blocks that return an empty-looking fallback with no diagnostic — a swallowed failure is indistinguishable from success.',
    },
    schema: [],
    messages: {
      silentFallback:
        'This catch turns a failure into {{value}}, which the caller cannot tell apart from a legitimate empty result. PR #719 is this exact bug: the error ref stayed null, so the "How can I help you?" empty state rendered for a session full of messages. Either surface the reason — log it, or assign it to an error ref that the template actually renders — or, if the fallback really is correct here, say so in a comment naming why the failure cannot reach the user.',
    },
  },
  create(context) {
    const source =
      context.sourceCode ?? (context as never as { getSourceCode(): never }).getSourceCode()

    return {
      CatchClause(node) {
        const clause = node as unknown as Node
        const body = asNode(prop(clause, 'body'))
        if (!body) return
        const statements = prop(body, 'body')
        if (!Array.isArray(statements)) return

        /**
         * A comment inside the block IS the sanctioned escape.
         *
         * AGENTS.md: "Reserve try/catch for the genuinely exceptional … Even
         * there, say a comment why the failure cannot be handled by the type."
         * A catch block whose only content is a comment explaining the
         * fallback ("quota exceeded — the live fetch still works") is the
         * documented pattern, not a violation; flagging it would train people
         * to delete the rule rather than obey it. A comment that does not
         * explain anything is still caught by review — lint cannot read prose,
         * and pretending otherwise would make the rule untrustworthy.
         */
        const hasComment =
          typeof source.getCommentsInside === 'function' &&
          source.getCommentsInside(body as never).length > 0

        if (statements.length === 0) {
          if (!hasComment) {
            context.report({
              node: clause as never,
              messageId: 'silentFallback',
              data: { value: 'nothing at all' },
            })
          }
          return
        }

        let foundFallback: string | null = null
        let hasDiagnostic = false

        walk(body, (n) => {
          // A `throw` keeps the failure in the channel — not a swallow.
          if (n.type === 'ThrowStatement') {
            hasDiagnostic = true
            return true
          }
          if (n.type === 'CallExpression') {
            const callee = asNode(prop(n, 'callee'))
            if (callee?.type === 'MemberExpression') {
              const property = prop(asNode(prop(callee, 'property')), 'name')
              const objectName = prop(asNode(prop(callee, 'object')), 'name')
              const objectIsLogger =
                objectName === 'console' ||
                (typeof objectName === 'string' && ERROR_NAME.test(objectName))
              const methodIsDiagnostic =
                property === 'error' ||
                property === 'warn' ||
                property === 'log' ||
                property === 'info' ||
                property === 'exception'
              if (objectIsLogger && methodIsDiagnostic) hasDiagnostic = true
            }
          }
          // `error.value = e`, `loadError.value = …` — the error reaches the UI.
          if (n.type === 'AssignmentExpression') {
            const left = asNode(prop(n, 'left'))
            const leftName =
              left?.type === 'MemberExpression'
                ? [
                    prop(asNode(prop(left, 'object')), 'name'),
                    prop(asNode(prop(left, 'property')), 'name'),
                  ]
                : []
            if (leftName.some((n2) => typeof n2 === 'string' && ERROR_NAME.test(n2)))
              hasDiagnostic = true
          }
          if (!foundFallback && n.type === 'AssignmentExpression') {
            const text = renderLiteral(asNode(prop(n, 'right')))
            if (text && FALLBACK_LITERALS.has(text)) foundFallback = text
          }
          if (!foundFallback && n.type === 'ReturnStatement') {
            const text = renderLiteral(asNode(prop(n, 'argument')))
            if (text && FALLBACK_LITERALS.has(text)) foundFallback = text
          }
          return undefined
        })

        if (foundFallback && !hasDiagnostic) {
          context.report({
            node: clause as never,
            messageId: 'silentFallback',
            data: { value: foundFallback },
          })
        }
      },
    }
  },
}

/** Exact source text, so only a literal `[]` matches and `makeFallback()` does not. */
function renderLiteral(node: Node | null): string | null {
  if (!node) return null
  if (node.type === 'ArrayExpression') {
    const elements = prop(node, 'elements')
    return Array.isArray(elements) && elements.length === 0 ? '[]' : null
  }
  if (node.type === 'ObjectExpression') {
    const properties = prop(node, 'properties')
    return Array.isArray(properties) && properties.length === 0 ? '{}' : null
  }
  if (node.type === 'Literal' || node.type === 'TemplateLiteral') {
    const raw = prop(node, 'raw')
    return typeof raw === 'string' ? raw : String(prop(node, 'value'))
  }
  if (node.type === 'Identifier') return prop(node, 'name') as string
  if (node.type === 'UnaryExpression') return String(prop(node, 'value'))
  return null
}
