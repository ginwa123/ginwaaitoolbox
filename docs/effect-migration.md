# Effect-TS in the desktop frontend

This is the working guide for adopting [Effect](https://effect.website) in
`src/apps/desktop`. It is not a tutorial; it records the decisions that are
already made so the next slice does not re-litigate them, and it is the
pattern to copy.

The first slice — `src/sync/` — is done. Everything below is written against
code you can read.

## Versions

| Package  | Version           | Why                                                                              |
| -------- | ----------------- | -------------------------------------------------------------------------------- |
| `effect` | `3.22.2` (pinned) | Latest **stable**. Effect 4 is RC-only; do not adopt it for production work yet. |

Two things people will reach for that we deliberately do **not** use:

- **`@effect/atom-vue` / `@effect-rx/*`.** The official Vue bindings ship only
  for Effect 4 RC. There is no stable Vue binding yet, so the seam to Vue is
  `src/sync/runtime.ts` (below). Revisit when Effect 4 lands.
- **`@effect/vitest`.** Its latest release peers `vitest ^3`, and this repo is
  on `vitest 4.1.4`. Effect is an ordinary runtime library — plain `vitest`
  plus `Effect.runPromise` / `Effect.runPromise(Effect.exit(...))` is all the
  test integration it provides, so we skip the incompatible dependency.

### 3.x API traps hit while writing this slice

Worth knowing before you copy anything:

- **`Context.Service` does not exist in 3.22.2.** It is an Effect 4 rename of
  `Context.Tag`. Use `Context.Tag` here; migrating later is mechanical.
- Tagged errors come from `Data.TaggedError('TagName')<Fields>` — capital `T`.
  There is no `Data.taggedError`.
- `Cause.failureOption(cause)` returns an `Option`, not the error. Use
  `Cause.squash(cause)` to get the failure itself.
- `Effect.provide` has **no memoMap overload** in 3.22.2. `Layer.sync` builds a
  fresh instance per `Effect.provide`, so a `Layer`-injected long-lived
  resource is rebuilt on every call. Inject stateful services as values (see
  "Injecting the store" below) and reserve `Layer` for whole-program
  composition.
- `Effect.gen` takes a generator function, and a generator's `this` is its own.
  Capture the receiver outside (`const engine = this`) and add the scoped
  `oxlint-disable-next-line` — destructuring `this` compiles and lints, but
  silently unbinds prototype methods, so they run with `this === undefined`.

## The shape of a slice

```
SyncError.ts       tagged errors — the reason a failure has a shape
SyncTypes.ts       pure domain types
SyncStore.ts       Context.Tag service + shape + in-memory implementation
IndexedDbStore.ts  the production Layer + its factory
SyncEngine.ts      orchestration; every method returns Effect<A, SyncError>
*EngineDb.ts       per-domain children; wrap the network call in Effect.tryPromise
runtime.ts         the Vue seam (see below)
```

### Typed errors, not bare catches

Before, every failure in `sync/` funnelled into `catch {}` and a fallback
value. A backend outage, a corrupt IndexedDB file and a legitimately empty
result all reached the UI as the same value, so `loadDelta` returning `null`
meant either "no new sessions" or "we could not check".

```ts
// src/sync/SyncError.ts
export class SyncStorageError extends Data.TaggedError("SyncStorageError")<{
  readonly op: string;
  readonly store: string;
  readonly reason: string;
}> {}

export class SyncRemoteError extends Data.TaggedError("SyncRemoteError")<{
  readonly op: string;
  readonly reason: string;
}> {}

export type SyncError = SyncStorageError | SyncRemoteError;
```

Keep the tags coarse. Two is right here because that is the distinction the
UI acts on: a local-cache problem is retried differently from a network
problem, and neither of them is a "no rows" answer.

### Keep the degradation policy, express it in the type

The old code was not wrong to swallow — a local-first cache must never break
the render. What was wrong was swallowing _silently_ and _untyped_. The port
splits the operations by what they promise:

- **Best-effort** (`putLocal`, `removeLocal`, `setCursor`, `clear`) keep an
  error channel of `never`. They catch with `Effect.catchAll` and log, so the
  contract is still "cannot fail" but a degraded cache is diagnosable.
- **Everything a caller might reason about** (`primeFromCache`, `getCursor`,
  `loadOlderFromCache`, `loadDelta`) returns `Effect<A, SyncError>`, and the
  decision to degrade moves to the call site.

`syncOnMount` is the clearest example — its contract is unchanged (it never
fails) but it now reports why:

```ts
const res = await Effect.runPromise(eng.syncOnMount("s1", 50));
if (res.error) {
  // now answerable: backend down, or IndexedDB closed, or a malformed payload
}
```

### Injecting the store

`SyncStore` is a real `Context.Tag`, and `IndexedDbStoreLive` /
`memorySyncStoreLayer` are real Layers — usable for a whole program:

```ts
const program = Effect.gen(function* () {
  const store = yield* SyncStore;
  return yield* store.getAll<Row>("sessions", "all", 30);
});
await Effect.runPromise(Effect.provide(program, memorySyncStoreLayer));
```

But the **engine takes the store as a value**, not a Layer. Two reasons, both
learned the hard way:

1. `Layer.sync` rebuilds per `Effect.provide`, so a Layer-injected engine would
   rebuild its IndexedDB connection and memory mirror on every operation.
2. Sharing one store instance across engines changes _which rows an engine can
   see_. Consolidating the three engines onto one connection looks like a free
   win and is tempting, but it broke four unrelated specs and needs its own
   coverage. It is a follow-up, not a drive-by.

So each engine keeps its own store — the pre-port isolation — and specs inject
`makeMemorySyncStore()` explicitly. That is also why every engine spec passes
its own store: a shared module-level store leaks state between tests.

### The Vue seam

`<script setup>` callers are ordinary script blocks. `src/sync/runtime.ts`
encodes the "degrade but say why" policy once so call sites stay one-liners:

```ts
// value, degrade to null (the old `catch { return null }` shape)
const delta = await runSyncEffect(
  sessionEngineDb.loadDelta(ctx, 30),
  "sessions.loadDelta",
);

// value, degrade to a non-null empty (rows, cursors)
const cached = await runSyncEffectOr(
  engine.primeFromCache(sid, 100),
  [],
  "messages.primeFromCache",
);

// side effect, cannot fail
await runSyncVoid(engine.putLocal(sid, rows), "messages.putLocal");
```

The `op` label shows up in a dev-mode warning. Drop these helpers in favour
of a bare `Effect.runPromise` only when you are willing to let a failed cache
read reject into a component.

Note for future slices: `Effect.runPromise` adds microtask hops, so a spec
that waits a fixed `await nextTick()` × 2 to settle an async mount may need
`flushPromises()` instead. That is a test-timing artifact, not a behaviour
change — but assert on settled state, not tick counts.

## Suggested order for the remaining slices

Ordered by value ÷ blast radius. Blast radius is production call sites.

| #   | Target                                 | Call sites    | Why it is next                                                                                                                                                                                                                                                           |
| --- | -------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | `stores/notifications.ts`              | 12 / 7 files  | The only store with a self-owning `setTimeout` that **leaks** (no cleanup, no store dispose). 33 LOC; each auto-dismiss becomes a scoped fiber.                                                                                                                          |
| 2   | `stores/loading.ts`                    | 3             | Only genuine concurrency in the repo; `startApi`/`finishApi` is already a `RefCount` shape. Keep the method names so `api/index.ts` is untouched.                                                                                                                        |
| 3   | `composables/useSubAgentPeek.ts`       | 4 files       | First composable slice. `watch(sessionId)` → `Stream.switchMap`, and it fixes a real leak: `openSse()` overwrites `offLlm` and orphans the previous subscription.                                                                                                        |
| 4   | `stores/kanbanSse.ts` + `designSse.ts` | 1 each        | Exactly one production call site each (`AppLayout.vue`). Best place to introduce `Stream` + `Effect.forkScoped` for a store-owned `Scope`.                                                                                                                               |
| 5   | `helpers/sseClient.ts`                 | —             | 1582 LOC, hand-rolled reconnect state machine with full-jitter backoff and `pauseWhenHidden`. **Already dependency-injected.** It is its own project; a rewrite here regresses invisibly.                                                                                |
| —   | `stores/workspaces.ts`                 | 23 / 21 files | ~130 public members. Last, not first.                                                                                                                                                                                                                                    |
| —   | `api/index.ts`                         | ~200 files    | 5636 LOC, 168 functions, and two specs assert on its **source text**, so splitting it breaks them by design. `apiFetch` also interleaves three side effects (toast, loading bar, 401 redirect) with the transport; separating those is the win, and it needs its own PR. |

## Rules for the next slice

- One boundary at a time. A slice is a _subsystem_, not a pattern applied
  everywhere.
- Do not change degradation behaviour while adding types. If a behaviour change
  is unavoidable, do it in its own commit so it can be reviewed separately.
- If a spec starts failing on _timing_ rather than on a value, make the spec
  wait for settled state instead of relaxing the assertion.
- Record the pre-change test baseline (files **and** test count) before you
  start. This repo has pre-existing failures; you need to know which are yours.
