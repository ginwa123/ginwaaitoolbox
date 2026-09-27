# The Android app keeps tracking the agent — it just can't tell when the run ended

## The report

> "when i open chat session android, its keep working ?" →
> "the reality is ai agent is not running, but my android mobile say its running"

Two claims, one of which turns out to be false.

## Claim 1 — "it keeps working" — TRUE

`WorkerActivityViewModel` is created once in `MainActivity.setContent` with the
plain `viewModel()` overload (`MainActivity.kt:66`), so it binds to the
**Activity's** `ViewModelStore`, not to a nav back-stack entry. Navigating
between the shell, a chat and a project never tears it down, and
`WorkerActivityViewModel.onCleared()` only runs when the Activity's store is
cleared.

That is deliberate, and the two surfaces that need the data are never on screen
together: the sidebar lives on the shell route, the chat header on the chat
route, and one replaces the other. A run started anywhere — another screen, a
scheduler, a sub-agent — stays tracked for the whole session. The answer to the
original question is therefore *yes, and by design*.

## Claim 2 — "it says it's running when it isn't" — TRUE, and it is not one bug

`isChatWorking = isRunning || isStreaming` (`chat/ChatScreen.kt:72`) merges two
independent truths, and **either one lying is enough** to light the spinner, the
"Working…" label and the Stop button:

| | truth | owner | cleared by |
|---|---|---|---|
| A | `RunningSessionsStore.runningSessionIds` | `WorkerActivityViewModel` | a `worker_deleted` frame, or `GET /api/workers` |
| B | `ChatUiState.isStreaming` | `ChatViewModel` | `chunk_final` / `llm_full` / `is_error` / a successful `stopRun` |

### A1 — the backend reports a stopped run as running (root cause)

`POST /api/llm/session/:session/stop` does not stop a run by deleting anything.
It sets a flag (`src/http_handlers/session_stop.zig:30` →
`llm_history.cancelSession`, `UPDATE worker SET cancelled = 1`) because the loop
reads it back to break out (`workflow.zig:916-923`).

The row therefore *survives* the stop, and `GET /api/workers` does not filter on
it — `src/http_handlers/worker_list.zig:45-57` selects every row and then
hardcodes the answer for each one:

```zig
.status = "running",
.is_running = true,
```

Row presence is the whole signal, and `src/models/worker.zig:24-26` already
promises the opposite behaviour in a doc comment that no code implements:

> "Cancelled rows are filtered out of 'Active Workers' listings but kept for
> post-mortem debugging."

So a stopped run keeps its spinner until the loop's `defer deleteWorker` runs
(`workflow.zig:712`), or — if the process is dead and the loop will never run
again — until the once-a-minute `cleanup_stale_worker` cron reaps a row idle for
600 s. On the phone that is a spinner the user cannot clear.

### A2 — a new run after a stop is born cancelled

`updateWorker`'s conflict clause never resets the flag
(`src/agentic_loop/update_worker.zig:63-68`):

```zig
\\ON CONFLICT(id) DO UPDATE SET
\\    session_id = excluded.session_id,
...
```

So the re-run upserts the row, `isWorkerCancelled` still reads `1`, and the loop
breaks on its first iteration check. **The user asked for a new turn and the
agent does nothing** — which is the "the reality is ai agent is not running"
half of the report, and it lands on the *same session* that A1 keeps marked as
running.

### A3 — a missed `worker_deleted` is permanent

The running set has exactly one reconciliation point: `handleState` resyncs
when the stream returns to `Live` (`WorkerActivityViewModel.kt:113-115`). There
is no timer and no lifecycle hook. A `worker_deleted` missed while the phone was
backgrounded — the socket stayed up, the app was not running the collector — is
never corrected, because the socket never drops and `Live` never re-fires.

The desktop has the same hole, and worse: `App.vue:56-72`'s
`fetchInitialWorkers` is called from exactly one place, a `watch` on
`bus.state === 'open'` (`App.vue:131-137`). No poll, no focus handler, no
`onResync` subscription.

### B1 — a terminal stream failure never clears `isStreaming`

`chat/ChatViewModel.kt:885-887`:

```kotlin
is ChatStreamState.Failed -> _uiState.update {
    it.copy(isLive = false, errorMessage = state.message)
}
```

`Failed` is terminal — the pump returns rather than retrying
(`ChatEventStreamTransport.kt:141-153`), so neither `chunk_final` nor `llm_full`
will ever arrive for the turn in flight. The flag stays `true` forever and
`isChatWorking` keeps the Stop button on screen.

## What is NOT the cause

Recorded so nobody re-chases them:

* **Stale cache on cold start.** There is no `is_running` column in any Room
  entity (`cache/CacheEntities.kt`) and nothing running-related in
  `EncryptedPrefs`. `RunningSessionsStore` starts empty. Cold start can only
  *under*-report.
* **Tearing the stream down on navigation.** It is activity-scoped
  (`MainActivity.kt:66`); no events are lost to a route change.
* **The `>50` worker truncation** (`worker/WorkerApi.kt:28`). Real, but it drops
  the tail of the list, i.e. it turns spinners *off* — the wrong direction.
* **An unknown worker action.** `RunningSessionsStore.apply` treats
  non-`deleted` as running (`RunningSessionsStore.kt:42-53`), which matches
  `App.vue:31-48` exactly. `worker_unknown` lights the spinner on both clients;
  it is parity, not drift.
* **`isSending`.** Always cleared in every `ChatResult` branch and not an input
  to `isChatWorking`.

## The method

Three changes, in dependency order. A1 and A2 are the fix; A3 and B1 stop the
same class of lie from coming back through a different door.

### 1. `GET /api/workers` must not report a cancelled row as running

`src/http_handlers/worker_list.zig` — add `AND w.cancelled = 0` to every query
variant. The flag is the *only* record that the user asked for this run to stop,
and reading it is what the model's own doc comment already specifies.

Deliberately **not** "delete the row at stop time": `isWorkerCancelled` returns
`false` for a missing row (`is_worker_cancelled.zig:25-28`), so deleting it
would silently break cancellation.

Also deliberately **not** a staleness predicate in the read path: the cron
already reaps rows idle for 600 s *and* broadcasts the `worker_deleted`, so a
stale row self-heals within a minute of the phone being awake. A second,
different staleness rule in the list could only hide a live-but-quiet worker.

### 2. A new run must clear the stop

`src/agentic_loop/update_worker.zig` — add `cancelled = 0` to the
`ON CONFLICT(id) DO UPDATE SET` clause, and name `cancelled` explicitly in the
`INSERT` so the upsert is not relying on the column default.

Ordering is already safe: `touchCheckpointWorkers` runs *before* the `while
(true)` loop (`workflow.zig:777`) and again at the top of every iteration
(`workflow.zig:819`), and the `isWorkerCancelled` check is at
`workflow.zig:916` — so the flag is already 0 by the time it is read.

### 3a. The phone must be able to correct itself

`worker/WorkerActivityViewModel.kt`:

* a **periodic resync** on a fixed interval, in addition to the `Live`-triggered
  one, so a missed frame is repaired within one interval instead of never;
* a **foreground resync** (`onForeground()`), wired from the Activity's
  `ON_START`, because coming back to the app is exactly when a stale set is
  most visible and least trustworthy;
* `onCleared()` must `store.clear()` — `stop()` already does, and the store is a
  process-wide singleton, so a destroyed Activity currently leaves its last set
  published for the replacement Activity's first frame;
* `onUserChanged` must restart on a **different** non-blank account, not just on
  a null one, for the same reason: the ids are not account-scoped.

The periodic tick is injected as a `Flow<Unit>` (`resyncTicks`) so a JVM test
can pass `emptyFlow()` — an `advanceUntilIdle`-driven test would otherwise spin
forever on a self-rescheduling `delay()`.

### 3b. A terminal stream failure must clear `isStreaming`

`chat/ChatViewModel.kt` — `ChatStreamState.Failed` also sets
`isStreaming = false`, on the same grounds `handleStreamEvent`'s `Failed` branch
already uses ("a diagnostic frame is not a run in progress, so it must clear the
flag too — otherwise the header claims the agent is still working after it has
given up").

## Not in scope, and why

`applyPage` does not clear a stale `streaming_*` placeholder after a reconnect
refetch, so a turn that completed while the socket was down keeps `isStreaming`
true (`ChatViewModel.kt:441-467` vs `:1000-1006`). That is a real third liar,
but `applyPage` cannot tell "this turn finished" from "this turn is live and the
server has not written it yet" — the backend writes `llm_history` only at turn
completion. Guessing wrong here shows "not running" *during* a live run, which
is the worse lie: it tells a user the agent stopped when it did not, and the
Stop button disappears while the agent keeps spending tokens.

Cross-checking against truth A is the right fix, and it is a separate change
because `ChatViewModel` and `RunningSessionsStore` are owned by two independent
ViewModels today.

## Tests that landed

`zig build test` — **3675 run, 3667 passed, 8 skipped, 0 failed.**

* `src/agentic_loop/update_worker.zig` — 3 new: a re-run clears the flag the
  previous stop left; the INSERT names `cancelled` (proven against a
  `NOT NULL` column with *no* default, so it cannot pass by accident); and the
  reset did not cost the `last_activity_nano` heart-beat that keeps a long run
  alive against `cleanup_stale_worker`.
* `src/http_handlers/worker_list.zig` — 6 new, all against in-memory SQLite: a
  cancelled row is absent, the `session_id` filter still composes, a real owner
  sees neither their own cancelled row nor another owner's live one, every
  returned row still hardcodes `status`/`is_running` (the Kotlin parser's
  premise), `limit` caps the list, and a missing table raises `QueryFailed`
  rather than answering with an empty list.
* `src/root.zig` — both files registered in the `test { }` block. Their inline
  tests existed but `zig build test` never discovered them; the
  `schedulers/cleanup_stale_worker.zig` comment describes the same workaround.
* `app/src/test/.../worker/WorkerActivityViewModelTest.kt` — 8 new, 15 kept: the
  periodic beat repairs a set on a socket that never dropped; no beat means no
  extra requests; `onForeground()` bypasses the throttle; `onForeground()` before
  sign-in is a no-op; `onCleared()` drops the singleton's set; an A→B account
  switch restarts and clears; repeating one account does not resubscribe; the
  beat dies with the cookie.
  The `model()` helper passes `emptyFlow()` for the tick, because the production
  default is a self-rescheduling `delay()` that `advanceUntilIdle` never settles
  against.
* `app/src/test/.../chat/ChatViewModelStreamStateTest.kt` — new file, 3: a
  terminal `Failed` clears `isStreaming` and `isChatWorking` with it; an
  `is_error` frame clears it the same way; a `Reconnecting` transition does not.

`./gradlew testDebugUnitTest` — **979 tests, 0 failed, 0 skipped.**
(JDK 17 from `~/.gradle/jdks`; the system JDK 27 makes the bundled Kotlin
compiler throw `IllegalArgumentException: 27` on startup.)

`tests/functional/android_workers_contract_test.py` — docstring only, recording
that "presence" now means "presence of a row that is not cancelled" and why the
filter cannot be re-derived from the wire against the stub LLM.
