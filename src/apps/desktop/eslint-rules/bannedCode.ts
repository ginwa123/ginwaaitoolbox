/**
 * Custom ESLint rules for the patterns this repo bans — the Vue/TS analogue
 * of React's `useEffect` ban ("You Might Not Need an Effect", react.dev).
 *
 * These live as a LOCAL plugin rather than in `.oxlintrc.json` because the
 * rule that matters here is an AST question, not a regex one: "is this
 * `watch()` callback only assigning derived state?" That is not expressible
 * as `no-restricted-syntax` selectors, and a regex attempt was measured
 * against this corpus at 40% recall WITH false positives — it flags
 * `watch(() => props.x, () => load())`, which is the legitimate `useEffect`
 * equivalent and the dominant idiom here (46 of 103 real call sites). Zero
 * false positives is the entire value of the rule, so it has to walk the tree.
 *
 * TIERING. A ban that turns CI red on day one gets deleted. Every rule here
 * is severity `error`, because ESLint's `--suppress-rule` records ONLY
 * error-severity violations — a `warn` baseline is silently written as `{}`
 * and the ratchet never engages. So the tiering is by SUPPRESSION instead:
 *
 *   no baseline needed — zero occurrences; new code fails immediately.
 *   baselined         — pre-existing debt pinned by the counts in
 *                       `eslint-suppressions.json`, so it can only shrink.
 *
 * Regenerate the baseline with `pnpm run lint:banned-baseline` AFTER fixing
 * debt, never to silence a new violation. Full rationale, the React→Vue
 * mapping table, and what is deliberately NOT banned: see
 * `docs/vue-ts-banned-code.md`.
 */
import type { Rule } from 'eslint'

/**
 * Structural node type. Deliberately minimal: every ESTree node satisfies it,
 * but ESTree nodes do NOT satisfy a type with an index signature, so extra
 * properties are read through `prop()` instead of `node.foo`.
 */
type Node = { type: string }

/** Read an untyped property off an AST node. */
function prop(node: Node | null | undefined, key: string): unknown {
  if (!node) return undefined
  return (node as unknown as Record<string, unknown>)[key]
}

/** Narrow an unknown value to a node, or null. */
function asNode(value: unknown): Node | null {
  if (!value || typeof value !== 'object') return null
  const type = (value as { type?: unknown }).type
  return typeof type === 'string' ? (value as Node) : null
}

/**
 * Members pure enough that calling one does not make a watcher a
 * side-effect watcher. Derived-state watchers legitimately compute with them
 * (`navItems.value = list.map(...)`), so treating any call as "impure" would
 * make the rule useless.
 */
const PURE_MEMBERS = new Set([
  'join',
  'map',
  'filter',
  'slice',
  'trim',
  'trimStart',
  'trimEnd',
  'toString',
  'padStart',
  'padEnd',
  'replace',
  'split',
  'concat',
  'flat',
  'flatMap',
  'includes',
  'toFixed',
  'sort',
  'reverse',
  'find',
  'findIndex',
  'findLast',
  'some',
  'every',
  'reduce',
  'keys',
  'values',
  'entries',
  'get',
  'has',
  'size',
])

/** Vue reactivity helpers that only re-wrap a value — still pure. */
const PURE_FUNCTIONS = new Set(['toRaw', 'unref', 'Number', 'String', 'Boolean'])

/**
 * Depth-limited walk. Deep enough for real watcher bodies, bounded so a
 * pathological AST cannot stall the lint run. Returns true if `visit`
 * short-circuited.
 */
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

function isPureCall(node: Node): boolean {
  const callee = asNode(prop(node, 'callee'))
  if (!callee) return false
  if (callee.type === 'Identifier') return PURE_FUNCTIONS.has(prop(callee, 'name') as string)
  if (callee.type === 'MemberExpression') {
    const property = asNode(prop(callee, 'property'))
    return (
      typeof prop(property, 'name') === 'string' &&
      PURE_MEMBERS.has(prop(property, 'name') as string)
    )
  }
  return false
}

/** `foo.value` as an assignment target, for ANY operator. */
function isRefWrite(node: Node): boolean {
  if (node.type !== 'AssignmentExpression') return false
  const left = asNode(prop(node, 'left'))
  if (left?.type !== 'MemberExpression') return false
  const property = asNode(prop(left, 'property'))
  return prop(property, 'name') === 'value'
}

/**
 * `foo.value = <expr>` — the pure derived-state shape.
 *
 * Plain `=` only. `+=` is an accumulator: it depends on the value's own
 * history, so `computed()` cannot express it. A body that ONLY accumulates is
 * still reported by the statement walk (via `isRefWrite`), because an
 * accumulator hidden in a watcher is usually an event counter that belongs in
 * the handler that caused it — but it is not claimed to be "derived state".
 */
function isRefAssignment(node: Node): boolean {
  return prop(node, 'operator') === '=' && isRefWrite(node)
}

/** Unwrap `foo?.bar()` / `(x)()` so the callee name is reachable. */
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

/** Every statement in `list` is a `.value =` write, allowing if/else guards. */
/** Statement list of a branch: a block yields its body, a bare stmt yields itself. */
function branchStatements(branch: unknown): unknown[] | null {
  const node = asNode(branch)
  if (!node) return null
  if (node.type === 'BlockStatement') return prop(node, 'body') as unknown[]
  return [branch]
}

/**
 * Every statement in `list` is a `.value` write.
 *
 * `if` guards are transparent: a body that only assigns INSIDE a guard is
 * still derived state (`if (newVal) { inputText.value = newVal }` —
 * FileInput.vue:230). A guard with no `else` must therefore pass, not fail:
 * treating the absent `alternate` as a violation silently dropped 11 of the
 * 26 real sites, which is the kind of regression that makes a rule look
 * enforced while quietly enforcing nothing.
 */
function everyStatementIsRefWrite(list: unknown): boolean {
  if (!Array.isArray(list)) return false
  return list.every((stmt) => {
    const node = asNode(stmt)
    if (!node) return false
    if (node.type === 'ExpressionStatement') {
      return isRefWrite(asNode(prop(node, 'expression')) ?? { type: '' })
    }
    if (node.type === 'IfStatement') {
      const consequent = branchStatements(prop(node, 'consequent'))
      const alternate = branchStatements(prop(node, 'alternate'))
      if (consequent === null || !everyStatementIsRefWrite(consequent)) return false
      return alternate === null || everyStatementIsRefWrite(alternate)
    }
    if (node.type === 'BlockStatement') return everyStatementIsRefWrite(prop(node, 'body'))
    if (node.type === 'ReturnStatement') {
      const arg = prop(node, 'argument')
      return arg === null || arg === undefined || isRefWrite(asNode(arg) ?? { type: '' })
    }
    return false
  })
}

/**
 * `watch()` whose callback body contains no impure call AND whose every
 * statement is a `.value` assignment. That combination is the Vue spelling
 * of React's banned `useEffect(() => setState(derived), [dep])`.
 */
export const noDerivedStateWatch: Rule.RuleModule = {
  meta: {
    type: 'problem',
    docs: {
      description:
        'Disallow watch() callbacks that only assign derived state — use computed() instead.',
    },
    schema: [],
    messages: {
      derivedStateWatch:
        'This watch() only assigns state computable from its source. That is the banned `useEffect(() => setState(derived), [dep])` shape: it adds a render hop, can fire twice on a rapid change, and needs no cleanup. Use `computed()` (or `toRef()` when the prop IS the value). If the body also performs a real side effect (DOM, fetch, store action, emit), move that call out and keep the assignment — then this rule stops firing.',
    },
  },
  create(context) {
    function report(node: Node): void {
      context.report({ node: node as never, messageId: 'derivedStateWatch' })
    }

    return {
      CallExpression(node) {
        const call = node as unknown as Node
        if (calleeName(asNode(prop(call, 'callee'))) !== 'watch') return

        const args = prop(call, 'arguments')
        if (!Array.isArray(args)) return
        const callback = asNode(args[1])
        if (!callback) return
        if (callback.type !== 'ArrowFunctionExpression' && callback.type !== 'FunctionExpression')
          return

        const body = asNode(prop(callback, 'body'))
        if (!body) return

        // `watch(a, v => (b.value = v))` — concise body is always an assignment.
        if (body.type === 'AssignmentExpression') {
          if (isRefAssignment(body)) report(call)
          return
        }
        if (body.type !== 'BlockStatement') return

        const statements = prop(body, 'body')
        // An empty body is dead code, not derived state — that deserves its
        // own message, and `every` would otherwise call it a pass.
        if (!Array.isArray(statements) || statements.length === 0) return

        // The discriminator: ANY call in the body means this watcher does
        // something observable, which is exactly what an effect is for.
        let hasImpureCall = false
        walk(body, (n) => {
          if (n.type === 'CallExpression' && !isPureCall(n)) {
            hasImpureCall = true
            return true
          }
          if (n.type === 'NewExpression') {
            hasImpureCall = true
            return true
          }
          return undefined
        })
        if (hasImpureCall) return

        if (everyStatementIsRefWrite(statements)) report(call)
      },
    }
  },
}
