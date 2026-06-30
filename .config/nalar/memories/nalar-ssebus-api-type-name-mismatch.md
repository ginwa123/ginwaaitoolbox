# nalar — `unify-frontend-sse` plan: `KanbanEvent`/`LlmChunkEvent` type-name mismatch

The unify-frontend-sse plan (`docs/superpowers/plans/2026-06-30-unify-frontend-sse.md`,
Chunk 1, lines 184-190) imports two type names from `../api` that **do not exist**
in `src/apps/desktop/src/api/index.ts`:

- **`KanbanEvent`** — actual exports are `KanbanColumnEvent` and `KanbanTaskEvent`
  (defined at `api/index.ts:1562` and `:1572`).
- **`LlmChunkEvent`** — actual export is `SseEvent` (defined at `api/index.ts:720`).

Following the plan verbatim produces a hard TypeScript compile error and a
failing `bun run build`. The plan code is otherwise correct (the rest of
the `SseEventMap` shape — `worker`, `session`, `queue` — matches real exports).

## The fix (applied in commit `3effe06c`, branch `worktree/unify-frontend-sse`)

Map the `SseEventMap` keys to the real exported names:

```ts
import type {
  WorkerEvent,
  SessionEvent,
  KanbanColumnEvent,  // plan: KanbanEvent
  KanbanTaskEvent,    // plan: KanbanEvent (continued)
  SseEvent,           // plan: LlmChunkEvent
  QueueMessageEvent,
} from '../api'

type SseEventMap = {
  worker: WorkerEvent
  session: SessionEvent
  kanban: KanbanColumnEvent | KanbanTaskEvent  // union of the two Kanban events
  llm: SseEvent
  queue: QueueMessageEvent
}
```

The `SseEvent` type (formerly `LlmChunkEvent` in plan-speak) is the type
that the existing `createUnifiedSseConnection` factory's `llm.onEvent`
receives — same name in plan and in code, just different spec/code label.

## When this bites

- Any future chunk of the unify-frontend-sse plan (Chunks 2-10) that
  references `KanbanEvent` or `LlmChunkEvent` will hit the same compile error.
  The Chunks 2+ plan code may have been updated to use the real names, but
  if not, this same import-block fix is needed.
- Other plan files that import types from `../api` should be checked
  against the actual exports in `api/index.ts` (use `rg "^export (interface|type)"`).
- The plan review process should `bun run build` the plan's example code
  before merging — the `vue-tsc` step would have caught the bad imports
  in seconds. The `bunx vitest run` step alone does NOT catch it (TypeScript
  type errors only surface during the full `vue-tsc --build` pass, per
  project memory `desktop-typescript-bun-build-as-typecheck.md`).

## How to verify

```bash
cd src/apps/desktop
timeout 240 bun run build 2>&1 | grep -iE "error|fail"
# Expected: 0 lines (no TS errors, no missing-type errors).
```

If the import block of any plan chunk references `KanbanEvent` or
`LlmChunkEvent`, swap to the real names before applying the plan code.
