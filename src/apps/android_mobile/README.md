# Nalar Android

A native Android client for Nalar, written in Kotlin with Jetpack Compose. The
current milestone includes real HTTPS sign-in against `agent.ginwa.site`,
encrypted session restoration, a left drawer with workspace-scoped recent chats,
and an in-app network inspector that captures every request the app makes. It
does not embed the web app and does not start or manage a Nalar server.

## Stack

- Kotlin 2.0.21
- Jetpack Compose Material 3
- Android Navigation Compose
- Room 2.6.1 (the offline caches), with KSP 2.0.21-1.0.28
- Android Gradle Plugin 8.7.3
- Minimum SDK 26, target/compile SDK 35
- JDK 17 (or a newer JDK supported by the pinned Android Gradle Plugin)
- JVM target 17

## Build and test

Use the checked-in Gradle wrapper from this directory:

```bash
cd src/apps/android_mobile
./gradlew test
./gradlew assembleDebug
```

The unit tests include the cache DAO tests, which open a real SQLite file
through Robolectric rather than a mock. Robolectric downloads its Android
runtime jars on the first run, so the first `./gradlew test` on a cold machine
needs network access.

An emulator or device is required for instrumentation tests:

```bash
./gradlew connectedDebugAndroidTest
```

Android Studio can open `src/apps/android_mobile` as a standalone project.
Install an Android SDK containing platform 35 and build tools when using a fresh
machine.

## Current behavior

The Android app authenticates against `https://agent.ginwa.site` through
`POST /api/auth/login`. A successful sign-in stores the `nalar_session` cookie
encrypted with an Android Keystore AES-GCM key. On startup the app verifies that
cookie with `GET /api/auth/me`; a 401 clears it and returns to the login screen.
Network and credential errors are shown in the login form, and the submit
button is disabled while a request is in flight.

The app declares `INTERNET` but explicitly rejects cleartext traffic, so every
client only accepts HTTPS endpoints. A transient startup verification failure
offers retry and account-switch recovery without deleting the saved cookie.

## Drawer

The two taps inside the drawer are not the same kind of gesture, so they do not
do the same thing to the drawer:

- **A chat is a destination.** Tapping a row closes the drawer and pushes
  `chat/{sessionId}`.
- **A workspace is a filter.** Tapping an option in the workspace dropdown
  rescopes the list in place and leaves the drawer **open**, because the point
  of switching workspace is to then pick a chat in it — closing would throw
  away the tap the user was in the middle of. Only the dropdown itself
  dismisses.

The callback that leaves the drawer is named `onOpenChat` rather than the
earlier `onNavigate` for exactly this reason: `onNavigate` invited the second
caller, and a filter has nowhere to navigate to.

## Chat

Tapping a chat in the drawer opens it as its own destination
(`chat/{sessionId}`, deep link `nalar://chat/{sessionId}`), so it survives
process death, works with the system Back button, and can be shared as a link.

The transcript is **live**: it reads `GET /api/llm/session/{id}/messages`,
subscribes to `GET /api/events?channels=llm,sessions,queue`, streams deltas into
a placeholder as they arrive, and replaces the placeholder with the canonical
row when it lands. Sending posts to `POST /api/llm/session`, the same endpoint
that creates a session, which enqueues the turn and returns immediately — so
there is no optimistic bubble and the transcript waits for the server's own copy
of the message. A run in progress when the chat is opened is re-attached from
`GET /api/llm/session/{id}/stream`, because the backend writes a turn to
`llm_history` only once it completes.

### "Is the agent working?" is a separate question from "is a delta arriving?"

A spinner appears beside every chat the backend currently has a worker for —
in the sidebar row and in the chat header — and the two are driven by
different signals, deliberately.

`ChatUiState.isStreaming` is per-*delta*: it goes true on an `llm_chunk` and
false on `chunk_final`. A tool run emits a chunk, finishes the turn, runs a
tool for thirty seconds in silence, and only then emits the next chunk — so
`isStreaming` alone makes one long run look like several separate stalls.
Whether a *worker* is registered is the backend's own answer to "is the agent
working on this session", and it holds across the gaps.

Two sources, because neither alone is right:

- **`GET /api/events?channels=workers`** on its own connection, carrying
  `worker_created` / `worker_updated` / `worker_deleted`. It is a second
  subscription rather than an extra channel on the chat stream because
  `ChatViewModel.openSession` is what starts that one — the sidebar is on
  screen precisely when no chat is open, and a stream that was never opened
  reports "nothing is running" at exactly the moment the user is scanning the
  list for what is running.
- **`GET /api/workers`**, re-read on every (re)connect. The server keeps no
  replay buffer, so a run that started or stopped while the socket was down
  left no event to apply and the list is the only thing that can correct it.
  It *replaces* the set rather than merging, or every run that stopped during
  an outage would stay lit forever.

The set lives in `RunningSessionsStore`, a process-wide singleton rather than
ViewModel state, because the sidebar and the chat are separate routes and are
never composed together. A failed resync leaves the set as it was: a spinner
that clears because the network blipped is the same lie as one that never
lights up.

### The transcript list is virtualized

`ChatView` renders the transcript in a `LazyColumn` — Compose's `RecyclerView` —
so a thousand-turn session costs the same as a ten-turn one. Three details make
that true rather than nominal, and each is covered by a test:

- **Stable keys.** Each list item is keyed by the first message id of its group,
  never by index. An index key re-keys every row above an append, discarding
  per-item state and re-composing the whole list on every streamed delta.
- **`contentType`**, so a run of tool rows reuses one composable instead of
  alternating layouts down the list.
- **Grouping.** Consecutive same-role turns collapse into a single item before
  the list sees them, and groups with nothing renderable are dropped so they
  cannot leave a blank band in the viewport.

A scroll to the top prepends the previous page and re-anchors on the message
the reader was looking at, by key and by the pixel row they had it at.

### The transcript follows the newest turn

Opening a chat lands on its newest turn, and the viewport stays there while a
reply streams in. A reader who has deliberately scrolled back into history is
left alone: following the tail is a courtesy for a reader who is already at the
end, not a claim on where they are.

The rule lives in `ChatScrollPolicy`, a pure function of the state *before* and
*after* a change, with no Compose in it. It is in that shape because every way
this used to break was an interaction between two consecutive states rather than
a property of any one frame:

- **Open.** Keyed on the session, not on the counts. Two chats holding the same
  number of turns move neither count, so an effect that only watched the counts
  did not re-run when the reader switched between them and the new chat opened
  exactly where the old one was parked.
- **Stream.** A delta replaces the newest message in place — same id, same group,
  same number of items, taller by a line. Nothing counted changes, so the effect
  is additionally keyed on a fingerprint of the tail; without it a live answer
  grew steadily out of the bottom of the viewport.
- **Prepend.** A backwards page re-anchors by item *key* and *offset*, never by
  index, and beats the follow flag: the reader asked to read further back, not to
  be thrown to the end.
- **Scroll.** Only an interactive scroll clears the follow flag. A programmatic
  scroll moves the viewport exactly as much as a drag does, and reading the
  settled layout of a chat that has just been opened — index 0, nobody's
  finger on it — as "the reader has left the end" is what used to cancel the
  auto-scroll it was supposed to inform.

The `LaunchedEffect` that performs the scroll is also the only one that may: a
prepend, an append and an open are all answered by the same decision, so they
cannot fight over the scroll position.

### A reader in history can get back to the end

The follow rule is a courtesy, not a claim on where the reader is — which leaves
them in history with no way back to the live tail except dragging for it. A
floating control appears when they are away from the newest turn and takes them
there in one tap.

It is an overlay on the transcript's viewport rather than a row in the list, so
it costs the `LazyColumn` no item, and it composes nothing at all while hidden
— a control that is always on screen is a control that does nothing, and a reader
who has learned to distrust it will not tap it when it matters.

Two things about it are not obvious:

- **It measures pixels, not items.** The obvious rule — "is the last group
  visible?" — answers *yes* for a reader who has scrolled most of the way up a
  single answer taller than the screen, because that answer is the last visible
  item for the whole time it is being read. The control would be missing exactly
  where it is most wanted. Two more shapes the reading has to get right, both of
  which produce a plausible-looking wrong number: a transcript that does not fill
  the viewport parks its last row near the top, so the raw difference is most of
  the screen's height for a reader who has not moved; and the bottom-most
  *visible* row is the row straddling the screen's edge, not the newest turn, so
  its overhang says nothing about how many turns are below it. A `LazyColumn`
  cannot measure a turn it has not composed, so for anything still below the fold
  the reading is `DISTANCE_FAR` rather than a guess.
- **The tap goes through the scroll policy, not straight to `scrollToItem`.** It
  re-arms the follow flag, so the next streamed delta keeps the reader at the
  end rather than finding the flag still `false` and putting them back in
  history. It also drops an in-flight backwards-page anchor: the page is armed
  before its request goes out, and replaying it on arrival would drop the reader
  straight back where they just pressed the button to leave.

The tap lands on the *end* of the newest turn, which the auto-scroll does not do
and must not: auto-scroll aligns the newest turn's top with the viewport's top,
because a streaming answer grows downward in front of the reader who is reading
it from the start. For a button labelled "jump to the newest message" that
leaves the reader where they already were whenever the newest turn is itself
taller than the screen.

Both halves are covered where they can be tested without a device:
`ChatScrollPolicyTest` for the decision and the interactions, and
`ChatScrollGeometryTest` for the distance the decision is made on.

### The transcript is cached

`ChatCache` is the Android mirror of the web's `ChatEngineDb` (IndexedDB
`sync_state` + `messages`): paint the last-known transcript from disk, then fetch
the tail, then write through.

- **Cached rows keep the whole server object** in a `raw` envelope, and are
  rendered by the *same* `ChatApi.toChatMessage` as live rows. Two mappers for
  one endpoint is how a cached mount and a live mount drift apart, and on a phone
  the cached mount is what the user sees first.
- **The sync cursor is the newest `created_at_nano` seen**, not the server's
  `next_cursor`. The backend only sends `next_cursor` when `has_more` is true,
  so persisting it wipes a good cursor to null after every small delta and forces
  a full reload on the next open. The cursor is monotonic and an empty delta
  leaves it alone.
- **Namespaced per user, and per session.** Sign-out only clears the cookie, so
  an unscoped cache would put the previous account's conversation on screen for
  whoever signs in next. An unresolved identity is a cache *miss*, not an
  unscoped read.
- **No TTL**, matching the web. That is only safe because every paint is
  immediately followed by a live fetch, which `ChatViewModel.openSession`
  enforces by having prime and revalidate in one function.

All three caches — this one and the sidebar's and the `/me` one — are backed by
the same Room database; the storage rules are in "The offline caches" below.

## The offline caches

Three things are cached so a cold boot or an offline launch paints real content
instead of a spinner, and all three live in **one Room database**
(`nalar_cache.db`) as five tables:

| Table                  | Holds                                       | Namespaced by          |
| ---------------------- | ------------------------------------------- | ---------------------- |
| `cached_messages`      | transcript rows, whole server object in `raw` | user + session       |
| `chat_cursors`         | the newest `created_at` seen, per session    | user + session         |
| `cached_workspaces`    | the workspace drawer                         | user                   |
| `cached_chat_summaries`| the recents list for one workspace           | user + workspace       |
| `cached_auth_me`       | the last `GET /api/auth/me` response         | cookie fingerprint     |

Each cache keeps its own interface — `ChatCache`, `RecentsCache`, `AuthMeCache`
— and the ViewModels were not touched to make this change. Only the store behind
each interface moved.

### Why this is SQL and not a keyed blob

Every one of these was a hand-built key over a JSON document, and every one of
the ways that can go wrong is now a property of the schema instead of of some
string-formatting convention:

- **Per-user isolation** is a column of the primary key. The old keys were
  `chats::u:<userId>::s:<sessionId>`, so a user id containing the separator
  could address a neighbour's partition. A column has no separators to contain,
  and `DELETE FROM cached_workspaces` is a complete, provable purge on
  sign-out.
- **Order** is a `position` column. A JSON array carried the server's order for
  free; rows do not, and a table with no `ORDER BY` returns rows in whatever
  order SQLite finds cheapest. Without that column the drawer would re-sort
  itself alphabetically the day somebody added an index.
- **Newest-first with a cap** is `ORDER BY sort_key_nanos DESC, message_id DESC
  LIMIT :n`, so "the newest 400 turns" is a `LIMIT`ed index lookup instead of
  parsing every row to sort and then throw most of them away. The `message_id`
  tie-break is what makes a transcript whose timestamps collide paint in the
  same order on every launch.
- **Write-through merge** is `INSERT … ON CONFLICT REPLACE` against the primary
  key, inside a transaction with the retention trim. The file cache had to read
  the whole document, merge in Kotlin and rewrite it under a lock; a kill
  mid-write could leave a half-document that then read as a corrupt transcript
  forever.
- **Replace-not-merge** for a sidebar list is `DELETE` + `INSERT` in one
  transaction, so a chat deleted upstream stays deleted.

The one rule the database cannot express is **retention**: a row store does not
rewrite itself, so a reader who scrolled through a long session would otherwise
leave a row per turn on the device forever. `RoomChatCache` keeps the newest
2 000 rows per session, which is several times the 400-row paint window, so
back-scrolled history survives a restart while a runaway session still stops.

### Encryption at rest, and what it costs

The sidebar's workspace names and chat titles, and the whole cached `/me` body,
are sealed with AES-GCM under an Android Keystore key, under aliases separate
from the session cookie's. Ids, positions and timestamps stay in the clear,
because `ORDER BY position` and `LIMIT` cannot run on ciphertext — they say what
the app knows, not what the user typed. The transcript's `raw` payload is not
sealed at all, for the reason below.

SQLCipher would have covered every column for free, and was rejected: its native
library cannot load on the JVM, so the DAO tests that this move is *for* —
ordering, replace-not-merge, isolation — would all have had to become
instrumentation tests that nobody runs without a device. Per-column sealing keeps
the file a plain SQLite database that Robolectric opens for real, and confines
the untestable part to the ~40 lines of `SealingCipher`. Its key is read from the
Keystore once per process rather than per row, which is what keeps 30 chat
titles from costing 30 Keystore daemon hops on the first frame.

Every cache operation is fail-silent: a full disk, a revoked key, a row written
under a retired alias or a GCM tag that no longer verifies all degrade to a
plain cache miss, and an unopenable row drops its own partition rather than
painting half a sidebar. A broken cache is never the reason the app fails.

### Why the queries run on the main thread

`NalarCacheDatabase` is built with `allowMainThreadQueries()`, which is a
deliberate exception to Room's default and worth being explicit about. The
cache-priming reads are synchronous because the first frame has to carry real
rows: `HomeViewModel` primes the sidebar and `ChatViewModel` the transcript
inside the same call that starts the fetch, so a coroutine hop would put a
spinner over data already on disk. And the call site is not new — the store it
replaced was `EncryptedPrefs`, which did a Keystore AES-GCM decrypt of a blob on
that same main thread. A `LIMIT`ed index-backed point query is cheaper than
what it replaced. Every query is in `ChatCacheDao` / `RecentsCacheDao` /
`AuthMeCacheDao` and each is a point lookup on the primary-key prefix, so the
claim is checkable in one sitting. Writes are unaffected: every caller already
wraps them in `Dispatchers.IO` before reaching a cache.

A schema bump drops the tables rather than migrating them. That is the one
database class where it is the right answer: everything in here is a copy of
something the server still holds, every paint is immediately followed by a live
fetch, and the cost is one empty sidebar and one spinner on the first launch
after an upgrade.

The transcript is not sealed with the Keystore, unlike the sidebar's titles: it
is bulk user content rewritten on every streamed frame, and a Keystore
round-trip per write costs more than the exposure is worth on a device that is
already full-disk-encrypted. The session cookie, which is a *credential*, stays
under the Keystore.

### Reasoning is folded away

A thinking model's chain of thought arrives on the turn as `reasoning_content`
and is drawn by `ReasoningBlock` as a **collapsed "Thought" fold**, above the
answer. It is the web's `<details class="assistant-reasoning">`
(`ChatView.vue`), and the two are kept word-for-word in step on purpose — the
label, the order, and the default. `ChatView`'s instrumented tests cover the
default, both toggle directions, and that two turns' folds are independent.

The default is the load-bearing part. A thinking model emits reasoning for
*every* turn, so a run of them expanded pushes the answer the reader actually
came for off the bottom of the screen, and rendered flat — which is how this
shipped the first time — a long trace is a wall of monospace with nothing to tap
past it.

Two details that are easy to get wrong:

- **The state is `ToolExpansion`'s, not a local `remember`.** The row is
  re-created every time it is scrolled out of the viewport and back, so a
  locally-remembered `expanded` re-folds the moment the reader scrolls away and
  returns. `rememberToolExpansion()` is hoisted above the `LazyColumn` for
  exactly this reason.
- **The key is namespaced, `reasoning-<messageId>`.** A tool card is filed under
  its `ToolCardModel.id`, which is the message id *verbatim*, so a bare id here
  would share one slot with that turn's tool card — opening the reasoning would
  open the card, and closing either closed both.

It is drawn inside the diagnostic rule rather than outside it: a turn that is
both a reasoning turn and a loop diagnostic is still one row, and a rule that
stopped at the answer would leave the fold above it unmarked.

## Recents

The drawer's **Recent** list is paged. It reads 30 rows from
`GET /api/session?workspace_id=…&sort_by=updated_at&direction=desc&limit=30` and
then asks for the next page when the reader reaches the bottom, resuming with the
server's own `next_cursor`. `HomeViewModel.loadMoreChats` owns that; the sidebar
only reports that it is near the end.

Three details of the endpoint are load-bearing, and each is pinned by a test,
because getting any of them wrong produces a list that merely *looks* fine:

- **`next_cursor` is the terminator's decoy.** The backend emits it whenever a
  page is non-empty, *including the last one*, so its presence says nothing
  about there being more. `has_more` is the only signal that ends the scroll.
- **`has_more` means "the page came back full"** (`len == limit`), so a final
  page that happens to be exactly full still reports `true`. `total` is the
  honest full count, so the client uses it as a backstop and skips the extra
  round-trip. When the server sends no `total` at all, `has_more` is trusted
  alone — reading a missing count as "you have them all" would silently
  truncate every list to its first page.
- **Pages can overlap.** A session touched while the reader is between pages
  moves up the ordering, so a page boundary can legitimately hand back a row
  already on screen. `RecentsApi.mergeChatsById` dedupes; without it the
  sidebar grows two tappable rows for one chat.

A page that adds nothing new also ends the scroll. That is the anti-loop guard:
if a server ever stops advancing the cursor, continuing would re-request the
same window forever.

A failed page is *not* an error banner. The rows already on screen are real, so
they stay, the footer spinner stops, and the next scroll retries the same page.

The cursor pages on the *sort field's* column, which the backend had wrong: the
resume key was hard-coded to `created_at` while the ordering and the cursor both
used `updated_at`. With `sort_by=updated_at` — what this list and the web's
`ChatsList` both send — page 2 re-served page 1 and skipped anything created
after the cursor.

## Network inspector

Every HTTP call is recorded and can be inspected in the app, the way a browser's
developer tools show the network tab. Open it from the chart icon in the home
top bar, from the icon in the top-right of the sign-in screen, or by deep link:

```bash
adb shell am start -a android.intent.action.VIEW -d "nalar://network"
```

The list shows the method, path, status, duration, and transferred size for each
call, filterable by mutations or failures and searchable by path, method, host,
or status. Selecting a record opens its request headers and body, its response
headers and body, and the equivalent `curl` command.

### How it is wired

`com.nalar.mobile.http.HttpsHttpExchange` is the only place the app opens a
socket. `HttpsAuthTransport` delegates to it and `RecordingAuthTransport` wraps
that transport, so the captured record is exactly what the auth flow sent rather
than a parallel reimplementation. A new API-backed feature only needs to go
through an `AuthTransport`-style wrapper to appear in the inspector.

The chat's message, send, stop and snapshot calls all go through that transport
and are captured. The SSE stream is the one exception: a long-lived response with
no end of body cannot be read through a request/response transport, and capturing
it would pin a record open for the life of the session.

### Privacy and safety

- The buffer is in memory only and is never written to disk or to logcat, so a
  captured session cookie cannot end up in a backup. It is capped at the most
  recent 200 records, and a single body is clipped at 32 KiB so a large download
  cannot exhaust memory. Both caps are in `NetworkLogStore`.
- Header values such as `Authorization`, `Cookie`, and `Set-Cookie`, and secret
  fields in JSON or form bodies, are masked in the UI. The detail screen offers
  a **Reveal secrets** toggle for records that carry credentials.
- **Copy as cURL** and **Replay** use the real recorded values, because a
  redacted command reproduces nothing. The detail screen warns before you copy a
  command containing live credentials, so treat the clipboard accordingly.
- Replaying a mutating method (`POST`, `PUT`, `PATCH`, `DELETE`) asks for
  confirmation first; a `GET` replays immediately. A replay is captured as a new
  record, so its result lands back in the list.
- Recording is on by default and can be paused from the inspector's top bar.

### Back never dead-ends the app

Every back affordance goes through one function, `goBackToPreviousOrShell`.
It exists because the obvious spelling is a trap: `NavController.popBackStack()`
with no argument is **inclusive**, and `dispatchOnDestinationChanged()` drops any
graph left on top of the queue. At a one-destination depth that single call
leaves the controller with no destination at all and reports `false` while doing
it — and `NavHost` renders *nothing* for an empty back stack, so the window keeps
the theme's background with no way out. System Back cannot cause this (the
library keeps its callback disabled while `destinationCountOnBackStack <= 1`),
which is why only an in-app back button finds it.

So the rule is stated rather than assumed: pop only when a real destination sits
underneath, and otherwise go to the shell. On top of that the graph renders a
recovery screen whenever `visibleEntries` is empty, so any future way into that
state costs one tap instead of a dead window. `NavControllerBackStackTest` drives
a real `NavController` through both paths on a device; `NalarNavGraphBackTest`
keeps the rule and the shape of the fix honest on the JVM, where CI runs it.

### Deep links

The inspector, its record detail and each chat are navigation routes, so they
survive process death and system Back. `nalar://network` opens the list,
`nalar://network/record/{id}` opens one captured record, and
`nalar://chat/{sessionId}` opens a chat directly.
