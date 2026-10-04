# Functional UI tests — native Android

Real-data, isolated-in-`/tmp`, end-to-end coverage for the **Android client**.
Boots a real `pabrik` binary against an isolated tmpdir `HOME`, seeds real
`llm_history` rows into that instance's own `agent.db`, builds the debug APK
against it, and drives the real `MainActivity` on a real emulator.

It is the phone's counterpart to `tests/functional_ui/` (which does the same for
the web app with Playwright). What differs is the client, so this suite needs
**no Vite, no pnpm and no Playwright** — its only Python dependency is pytest —
and it **does** need an emulator.

## What it covers, and what it does not

The 1019 unit tests on the JVM decide what a renderer should do with a shape,
and build that shape by hand in Kotlin. The 154 instrumented tests drive real
Compose on a device, but also hand the composable hand-built data. So
"*a real server wrote this row and the phone drew it*" was the one cell with
nobody in it. Ten scenarios fill it:

| scenario | what it proves reached the tree |
|---|---|
| `empty` | the empty state, for a session with no rows |
| `exchange` | a user turn and a reply |
| `multiturn` | eight turns; the tail renders and is scrolled to |
| `toolcalls` | an unanswered call renders the collapsed group summary |
| `toolresult` | a `bash` result renders its card |
| `markdown` | a fenced block is recognised as code |
| `images` | a user turn's attachments render |
| `reasoning` | a thinking trace folds behind its own block |
| `html` | a **real** document payload splits into prose *and* a `WebView` frame |
| `presentfiles` | a `present_files` result renders its card (see the gap below) |

Not covered, deliberately: the sidebar/recents list (it is scoped to a
`workspace_id` and seeded sessions have none, so the server fails closed), live
streaming (the harness's stub LLM points at a dead port), and the composer's
send path (needs a real turn to mean anything).

**Known gap.** `presentfiles` asserts the card chrome, not the card's expanded
body, where the file rows live. Expanding needs the card's own toggle and
clicking `tool_card_chevron` does not reach it — the clickable is an ancestor.
The rows are the only path through `HttpsBinaryExchange`, so this is worth
closing: find the node carrying the click action.

## Isolation

Inherited whole from `tests/functional/harness.py`: `HOME` is shadowed to a
`pabrik-func-*` tmpdir before the binary starts, every delete goes through
`is_safe_tmp` (the single source of truth), and teardown rmtree's only
`harness.temp_dir`. The developer's real `$HOME` is never read or written.

Two dimensions are new here:

1. **On-device state** — an instrumentation run is one app process against one
   data directory, so `ClearAppStateRule` wipes the session cookie, the saved
   position and the four Room caches around every test. The saved position is the
   one that matters: the nav graph resumes it on launch, so a leftover one lands
   a test somewhere other than the deep link it asked for.
2. **The app's host is a build-time value** — the APK is built with
   `-PpabrikBaseUrl=http://10.0.2.2:<port>`, and `ALLOW_INSECURE_HTTP` (false in
   release) is what lets the debug variant speak plain HTTP to it.

## Running

The suite needs an **emulator**, not a phone: the APK is built to reach the host
at `10.0.2.2`, which is the emulator's alias for the host machine's loopback
interface.

```bash
# 1. an emulator must be running
$ANDROID_HOME/emulator/emulator -avd Medium_Phone -no-window -no-audio -no-snapshot &

# 2. build the binary the harness boots
zig build install:linux

# 3. run the suite
export JAVA_HOME=/path/to/jdk17          # AGP 8.7.3 rejects a newer JDK
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_SERIAL=emulator-5554      # tells Gradle which device
export PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64
export PYTHONPATH=tests/functional:tests/functional_ui:tests/functional_android

.venv-func/bin/python -m pytest tests/functional_android/ -q -rs
```

`JAVA_HOME` and `ANDROID_SERIAL` are not optional. JDK 17 because AGP aborts on
anything newer with a bare version number and no stack trace; the serial because
a phone alongside the emulator cannot reach the host alias, and the run would
otherwise land on whichever device adb listed first.

Cost: one Gradle build + install + ten scenarios, about 35 s warm.

## Adding a scenario

Four edits, and `drift_test.py` fails until they agree:

1. `scenarios.py` — add the name to `SCENARIOS` and its row count to `ROWS`.
2. `seed_scenarios.py` — add the seeder to `SEEDERS` (it is checked against
   `ROWS` as it runs).
3. `FunctionalScenario.kt` — add the session id and every message id you will
   assert on. Ids are `"<session>_<nnnn>"`, zero-padded, because the phone orders
   the transcript by `id`.
4. `ChatFunctionalTest.kt` — add a `@Test` named after the scenario key, open
   its session, and `assertPresent(...)` the tag you expect.

If a tag is missing, the failure lists every tag that *was* rendered, which is
what distinguishes "the renderer chose a different node for this shape" from
"the renderer did not draw it" — the two need opposite fixes.
