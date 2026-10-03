/**
 * A `watch()` that writes back into the value it watches — the feedback loop.
 *
 * This is the failure mode React's "You Might Not Need an Effect" is really
 * about, and the one a pure derived-state check misses. In React the same
 * shape is the classic
 *
 *     useEffect(() => { setCount(count + 1) }, [count])   // rerenders forever
 *
 * and in Vue it is just as reachable:
 *
 *     watch(items, (v) => { items.value = [...v, next] })  // retriggers itself
 *     watch(props.row, (v) => { props.row.busy = true })   // mutates the source
 *
 * Vue's reactivity is not a loop-breaker here: a watcher fires whenever a
 * dependency it READS changes, so writing to that same dependency schedules
 * another run. It converges only when the assignment happens to produce an
 * identical value. That is why the surviving code in this repo carries
 * hand-written guards that read like apologetics —
 * `KanbanTaskDetail.vue:735` says outright "no infinite loop — re-assigning
 * selectedColumnId to its current value is a no-op", which is a loop that
 * only terminates by accident.
 *
 * WHY THIS IS A SEPARATE RULE FROM `no-derived-state-watch`:
 * that rule requires the callback to contain no call at all, so it
 * deliberately allows a mixed body (`watch(a, (v) => { a.value = f(v); save() })`).
 * Exactly those mixed bodies are where a self-write hides — the save() call
 * makes the watcher "a legitimate side effect" while the assignment still
 * feeds itself. A rule that only looked at pure bodies would miss it.
 *
 * The fix is to stop mirroring: derive with `computed()`, or move the write
 * into the handler that caused the change.
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

function walk(node: Node | null | undefined, visit: (n: Node) => void, depth = 0): void {
  if (!node || depth > 60) return
  visit(node)
  const record = node as unknown as Record<string, unknown>
  for (const key of Object.keys(record)) {
    if (key === 'parent') continue
    const child = record[key]
    if (Array.isArray(child)) {
      for (const item of child) walk(asNode(item), visit, depth + 1)
    } else {
      walk(asNode(child), visit, depth + 1)
    }
  }
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

/**
 * Root binding of an expression: `a.b.c` → `a`, `x` → `x`, `42` → null.
 * A write to any property of a watched binding retriggers it, so the root
 * is what matters, not the leaf.
 */
function rootName(node: Node | null): string | null {
  let cur = node
  while (cur) {
    if (cur.type === 'ThisExpression') return 'this'
    if (cur.type === 'Identifier') return prop(cur, 'name') as string
    if (cur.type === 'MemberExpression' || cur.type === 'ChainExpression') {
      cur =
        cur.type === 'ChainExpression'
          ? asNode(prop(cur, 'expression'))
          : asNode(prop(cur, 'object'))
      continue
    }
    if (
      cur.type === 'CallExpression' ||
      cur.type === 'AwaitExpression' ||
      cur.type === 'TSNonNullExpression'
    ) {
      cur = asNode(prop(cur, cur.type === 'CallExpression' ? 'callee' : 'expression'))
      continue
    }
    return null
  }
  return null
}

/**
 * Roots that are NOT the watcher's own reactive state.
 *
 * `document.title = name` in `useDocumentTitle.ts` looks like an assignment
 * but writes the browser tab, not a ref — it cannot retrigger anything.
 * Globals (`document`, `window`, `localStorage`, `console`, `location`) and
 * `this` are likewise outside the reactivity graph. Treating them as watched
 * dependencies is what made the first draft of this rule report 4 of the 6
 * real sites as false positives.
 */
const EXTERNAL_ROOTS = new Set([
  'document',
  'window',
  'globalThis',
  'console',
  'localStorage',
  'sessionStorage',
  'location',
  'history',
  'navigator',
  'performance',
  'fetch',
  'this',
])

/**
 * Vue helpers whose ARGUMENT is a reactive dependency.
 *
 * `watch(toRef(props.x), …)` watches `props`, not a global `toRef`, so these
 * are the only callables that are traversed into.
 */
const REACTIVITY_HELPERS = new Set([
  'toRef',
  'toRefs',
  'reactive',
  'computed',
  'ref',
  'shallowRef',
  'toValue',
])

/**
 * Roots the source expression READS as reactive dependencies.
 *
 * Hand-rolled recursion rather than the generic `walk`, because here the
 * visitor must be able to STOP descending. `walk` always recurses, so the
 * early returns below would have been no-ops — and the symptom was exactly
 * that: in `() => props.isStopping` the property name `isStopping` leaked in
 * as a "dependency", inventing a feedback loop that does not exist.
 *
 * So: `() => props.isStopping` reads `props`, NOT `isStopping`;
 *     `() => ({ kind: vm.value.kind })` reads `vm`, NOT `kind`.
 */
function readRoots(node: Node | null, into: Set<string>, depth = 0): void {
  if (!node || depth > 40) return
  switch (node.type) {
    case 'Identifier': {
      const name = prop(node, 'name') as string
      if (!EXTERNAL_ROOTS.has(name)) into.add(name)
      return
    }
    case 'MemberExpression': {
      // `foo.bar` reads `foo`. `foo` is the only reactive binding involved;
      // a computed key (`foo[bar]`) additionally reads `bar`.
      readRoots(asNode(prop(node, 'object')), into, depth + 1)
      if (prop(node, 'computed') === true)
        readRoots(asNode(prop(node, 'property')), into, depth + 1)
      return
    }
    case 'CallExpression': {
      // A callee is a function, not a dependency — except the reactivity
      // helpers, whose argument genuinely is one (`toRef(props.x)`).
      const callee = asNode(prop(node, 'callee'))
      if (callee?.type === 'Identifier' && REACTIVITY_HELPERS.has(prop(callee, 'name') as string)) {
        readRoots(callee, into, depth + 1)
      }
      const args = prop(node, 'arguments')
      if (Array.isArray(args)) for (const a of args) readRoots(asNode(a), into, depth + 1)
      return
    }
    case 'AssignmentExpression': {
      // The left side is a write, not a read.
      readRoots(asNode(prop(node, 'right')), into, depth + 1)
      return
    }
    case 'ArrowFunctionExpression':
    case 'FunctionExpression': {
      // A nested function's locals are not dependencies of this watcher.
      return
    }
    case 'Property': {
      // An object key is a string, not a reactive read. The VALUE still is.
      readRoots(asNode(prop(node, 'value')), into, depth + 1)
      return
    }
    default: {
      // Anything else (object/array literals, conditionals, …): recurse into
      // every child value.
      const record = node as unknown as Record<string, unknown>
      for (const key of Object.keys(record)) {
        if (key === 'parent' || key === 'type' || key === 'loc' || key === 'range') continue
        const child = record[key]
        if (Array.isArray(child)) {
          for (const item of child) readRoots(asNode(item), into, depth + 1)
        } else {
          readRoots(asNode(child), into, depth + 1)
        }
      }
    }
  }
}

export const noWatchFeedbackLoop: Rule.RuleModule = {
  meta: {
    type: 'problem',
    docs: {
      description:
        'Disallow watch() callbacks that write back into the value they watch — the self-retriggering feedback loop.',
    },
    schema: [],
    messages: {
      feedbackLoop:
        'This watch() writes to {{target}}, which it also watches. Vue re-runs a watcher whenever a dependency it READS changes, so writing back to that same dependency schedules another run — the loop only ends when the write happens to produce an identical value, which makes the termination accidental rather than designed ({{detail}}). Stop mirroring: use `computed()` to derive the value, or move the write into the handler that caused the change.',
    },
  },
  create(context) {
    function report(node: Node, messageId: string, target: string, detail: string): void {
      context.report({ node: node as never, messageId, data: { target, detail } })
    }

    return {
      CallExpression(node) {
        const call = node as unknown as Node
        if (calleeName(asNode(prop(call, 'callee'))) !== 'watch') return

        const args = prop(call, 'arguments')
        if (!Array.isArray(args)) return
        const source = asNode(args[0])
        const callback = asNode(args[1])
        const options = asNode(args[2])
        if (!source || !callback) return
        if (callback.type !== 'ArrowFunctionExpression' && callback.type !== 'FunctionExpression')
          return

        // What the source reads. A bare `watch(foo, …)` reads the binding `foo`;
        // a getter `watch(() => foo.bar, …)` reads everything its body reads.
        const sourceRoots = new Set<string>()
        if (source.type === 'ArrowFunctionExpression') {
          readRoots(asNode(prop(source, 'body')), sourceRoots)
        } else {
          // `watch(items, …)` reads the binding `items`; `watch(items.value, …)`
          // reads `items` too — the root is what matters.
          readRoots(source, sourceRoots)
        }

        // Bindings the callback may write THROUGH to the watched value.
        //
        // Two levels, because they are different shapes:
        //   `watch(a, (v) => { v.x = 1 })`          — the value itself
        //   `watch(a, (v) => { v.forEach(i => i.x = 1) })` — an element of it,
        //                                               reached via a nested param
        // Only the second is a loop for a `deep` watcher (without `deep` a
        // nested mutation does not notify, so it is a one-shot write).
        const paramNames = new Set<string>()
        const collectParams = (node: Node | null): void => {
          if (!node) return
          const params = prop(node, 'params')
          if (Array.isArray(params)) {
            for (const p of params) {
              const name = prop(asNode(p), 'name')
              if (typeof name === 'string') paramNames.add(name)
            }
          }
        }
        collectParams(callback)
        walk(asNode(prop(callback, 'body')), (n) => {
          if (n.type === 'ArrowFunctionExpression' || n.type === 'FunctionExpression')
            collectParams(n)
        })
        for (const name of sourceRoots) paramNames.delete(name)

        const deep = /deep\s*:\s*true/.test(
          options ? context.sourceCode.getText(options as never) : '',
        )
        // Only writes to REACTIVE state can retrigger a watcher. `document.title =`
        // and `localStorage.setItem` are side effects, not feedback.
        const assignedRoots: string[] = []
        walk(asNode(prop(callback, 'body')), (n) => {
          if (n.type === 'AssignmentExpression' || n.type === 'UpdateExpression') {
            const left =
              n.type === 'AssignmentExpression'
                ? asNode(prop(n, 'left'))
                : asNode(prop(n, 'argument'))
            const root = rootName(left)
            if (root && !EXTERNAL_ROOTS.has(root)) assignedRoots.push(root)
          }
        })
        if (assignedRoots.length === 0) return

        // (a) A direct write to a binding the source reads.
        const selfWrite = assignedRoots.find((root) => sourceRoots.has(root))
        if (selfWrite) {
          report(
            call,
            'feedbackLoop',
            selfWrite,
            deep
              ? 'direct self-assignment, and the watcher is `deep: true`'
              : 'direct self-assignment',
          )
          return
        }

        // (b) Mutating the new value in place — writes through to the source.
        //
        // Only meaningful for a `deep` watcher: without `deep`, a nested
        // mutation does not notify, so `watch(a, (v) => { v.x = 1 })` is a
        // one-shot write, not a loop. Flagging the non-deep case produced 4
        // false positives on the first pass (FileInput.vue:159,
        // LlmConfigModal.vue:67, useDocumentTitle.ts:23 and
        // VirtualScroller.vue:631 — all of which write to a DIFFERENT ref).
        if (deep) {
          const paramWrite = assignedRoots.find((root) => paramNames.has(root))
          if (paramWrite) {
            report(call, 'feedbackLoop', paramWrite, 'the callback mutates the value it was handed')
          }
        }
      },
    }
  },
}
