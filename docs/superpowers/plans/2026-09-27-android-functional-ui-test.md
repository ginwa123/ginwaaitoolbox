# Plan — `tests/functional_android/`: real-data, isolated functional UI suite for the native Android client (rev 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-09-27
**Task:** `task_1790541883728_3`
**Kanban card:** *"Is android mobile have test like functional test ui ? that use a real data but in isolated way ?"*
**User's spec (verbatim):** *"we need to build the test functon test ui for android, so write me a plan to implmenet that featuress"*
**Branch / worktree:** `worktree/is-android-mobile-have-test-like-functional-test-u-1790541878652`

**Goal:** Give the native Android client the thing it does not have — an end-to-end functional UI test that boots a **real `nalar` binary against an isolated tmpdir `$HOME`**, seeds **real `llm_history` rows** into that instance's own `agent.db`, points the **debug APK** at it, launches the **real `MainActivity` on a real emulator**, and asserts on the **rendered Compose tree**. Same contract as `tests/functional_ui/`, one layer further out: the desktop suite drives a real browser; this one drives a real phone app.

**Why the gap exists today (verified):** the Android side has 1005 JVM `@Test` (Robolectric/JVM) and 154 instrumented `@Test`, and **not one of them ever opens a socket to a real server.** Every URL in every android test is a hand-typed string (`https://agent.ginwa.site/api/auth/login`); there are **zero** `10.0.2.2` references repo-wide and **zero** `agent.db` references. The three `tests/functional/android_*_contract_test.py` files (27 tests) are the nearest neighbour — real binary, real stub-LLM turn, isolated HOME — but they assert the **wire**, not the app: `android_chat_sse_contract_test.py:6-11` says outright that the Kotlin tests "feed that decoder hand-written strings, so a rename or a re-shape on the server only reaches them as a failure if somebody remembers to update the fixture".

**Architecture:**

1. **New pytest suite `tests/functional_android/`.** Reuses `FunctionalHarness` (`tests/functional/harness.py`) **verbatim** — no new harness. It picks a free port, boots the real `nalar` on `127.0.0.1:<port>` (auth is off by default — the harness never passes `--auth`), sets `stub_llm_profile=True`, then seeds ten scenario sessions with `DbSeed` (`tests/functional_ui/db_seed.py`) into `temp_dir/.config/nalar/agent.db`. **No Vite, no pnpm, no Playwright** — the UI harness's entire node half is irrelevant here.
2. **A build-time base-URL seam.** `app/build.gradle.kts` turns on `buildConfig = true` and adds three fields: `API_BASE_URL` (default `https://agent.ginwa.site`; debug overrides it from a `-PnalarBaseUrl=` Gradle property) and `ALLOW_INSECURE_HTTP` (`true` in debug, **`false` in release**). `AuthConfig.BASE_URL` becomes `BuildConfig.API_BASE_URL`. Every one of the ~10 existing `baseUrl: String = AuthConfig.BASE_URL` default parameters keeps working unchanged.
3. **A debug-only cleartext allowance.** New `app/src/debug/AndroidManifest.xml` + `app/src/debug/res/xml/network_security_config.xml` permit cleartext for exactly `10.0.2.2` and `127.0.0.1`/`localhost`. Release keeps `android:usesCleartextTraffic="false"` and ships no such config.
4. **Three guarded relaxations in `src/main`** so the client can open a plain-HTTP socket *only* when `BuildConfig.ALLOW_INSECURE_HTTP` is true: the HTTPS-only `require` in `HttpsAuthTransport`, and the two `as? HttpsURLConnection` casts in `HttpsHttpExchange` / `HttpsBinaryExchange`. `HttpChatEventStream` needs **nothing** — it is already typed `HttpURLConnection` on purpose (`ChatEventStreamTransport.kt:242-247`).
5. **A new instrumented class** `app/src/androidTest/java/com/nalar/mobile/functional/ChatFunctionalTest.kt` that launches the **real `MainActivity`** (real ViewModels, real network, real nav graph) via a deep-link intent `nalar://chat/<seeded-session>` and asserts on the **existing** `testTag`s. No new production seam beyond the base URL.
6. **Device-state isolation per test.** A `ClearAppStateRule` (`ExternalResource` in a `RuleChain` *outer* of the Compose rule, so it runs before the Activity is launched) clears the auth cookie, the `nalar_position` prefs and `nalar_cache.db`. This is the **first** state reset in the module — recon found exactly one `@Before` across all 17 instrumented files, in `SessionCookieStoreTest.kt`.
7. **pytest drives Gradle as a subprocess.** One `:app:connectedDebugAndroidTest` invocation, filtered to the new class, with `-PnalarBaseUrl=http://10.0.2.2:<port>`. The XML at `app/build/outputs/androidTest-results/connected/debug/TEST-*.xml` is parsed once at module scope; each pytest test asserts its own `<testcase>`. The harness tears down the nalar process and `rmtree`s the tmpdir afterwards.
8. **Fail-soft.** Skip with a specific reason when there is no attached device, no Gradle wrapper, or no JDK 17 — mirroring `default_nalar_bin`'s `pytest.skip` in `tests/functional/conftest.py:61-70`. A developer without an emulator must not see ten red tests.

**Tech Stack:** Python 3.9+ stdlib (`subprocess`, `sqlite3`, `xml.etree.ElementTree`, `pathlib`) + pytest, on top of the existing `FunctionalHarness` / `DbSeed`; Kotlin 2.0.21 + Jetpack Compose Material 3 on `androidx.compose.ui:ui-test-junit4`, `androidx.test.ext:junit:1.3.0`, `androidx.test.espresso:espresso-core:3.7.0`; AGP 8.7.3 + Gradle 8.10.2 `connectedDebugAndroidTest`; the emulator's `10.0.2.2` host-loopback alias; `BuildConfig` (newly enabled); `androidx.test:core-ktx:1.7.0`.

---

## Global Constraints

- **Never touch port 8081.** The always-running dev backend lives there, and the harness already reserves it (`tests/functional/harness.py:144`, `RESERVED_PORTS = (8081,)`). Never hardcode a port: go through `FunctionalHarness.boot()` (random 20000–32000, `harness.py:130-131`).
- **Never `nohup ./zig-out/bin/nalar --port 8080` + curl.** Every new test boots a real binary through the harness against an isolated tmpdir HOME.
- **Never let anything but `FunctionalHarness.teardown()` delete a directory.** No new `rmtree`. Any new code path that deletes must be gated by `is_safe_tmp(path, orig_home)` (`harness.py:166-197`). `DbSeed.__init__` already re-validates (`db_seed.py:127-141`); do not weaken it.
- **The developer's real `$HOME` is never read or written.** The DB goes to `temp_dir / ".config" / "nalar" / "agent.db"` and nowhere else.
- **Release must stay HTTPS-only.** `ALLOW_INSECURE_HTTP` is `false` in the release build type, no `src/release/` manifest claims a cleartext allowance, and the HTTPS-only `require` in `HttpsAuthTransport` **must not be deleted** — only widened behind the flag. This is a security invariant and Task 2 gives it its own contract test.
- **No `// NEW (plan: …)` comments** in any source file. Explain *why* in one plain sentence, or not at all.
- **No `adb` CLI shell-outs from pytest.** The `adb` client on this box cannot complete its handshake with its own server (documented: `Host: version` fails against every server and address family, while the server itself is healthy on plain TCP). Reachability therefore uses the emulator's own `10.0.2.2` alias and Gradle drives adb itself with `ANDROID_ADB_SERVER_PORT=5040`.
- **JDK 17 is mandatory.** AGP 8.7.3 rejects a newer JDK and aborts with a bare version number and no stack trace. Use `JAVA_HOME=/tmp/jdk17` (or `~/.local/jdk17`).
- **`--offline` is forbidden for `connectedDebugAndroidTest`.** The UTP report artifact (`com.android.tools.utp:android-test-plugin-host-additional-test-output`) is not in the warm Gradle cache, so the reporting step fails *after* the tests have run — which reads as a build failure that is not one. `--offline` remains fine for `testDebugUnitTest`.
- **Never run the unfiltered instrumented suite as the gate.** `ChatViewTest` is 14-red on `main` (5 hit Compose 1.7's "Cannot call setContent twice per test!", 2 cannot find `chat_running_spinner`). Always filter with `-Pandroid.testInstrumentationRunnerArguments.class=…` so the new suite's signal is not buried in a known-red baseline.
- **One instrumented class per Gradle invocation is the unit of cost.** A `connectedDebugAndroidTest` run is a build + install + device handshake. Do not add a second invocation "for cleanliness".
- **Cross-platform importability.** The Python suite must stay importable and skip cleanly on macOS/Windows even though the device path is Linux-only in practice: `pathlib` everywhere, no POSIX-only shelling out, no `os.killpg` outside a POSIX guard.
- **Gate commands** (run these, in this order, before opening either PR):
  - `cd src/apps/android_mobile && JAVA_HOME=/tmp/jdk17 ./gradlew :app:testDebugUnitTest --offline`
  - `cd src/apps/android_mobile && JAVA_HOME=/tmp/jdk17 ANDROID_HOME=$HOME/Android/Sdk ./gradlew :app:assembleDebug --offline`
  - `cd src/apps/android_mobile && JAVA_HOME=/tmp/jdk17 ANDROID_HOME=$HOME/Android/Sdk ./gradlew :app:assembleRelease --offline`
  - `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 /tmp/nalar-func-venv/bin/python -m pytest tests/functional/ -q -rs`
  - `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 PYTHONPATH=tests/functional:tests/functional_ui:tests/functional_android .venv-func/bin/python -m pytest tests/functional_android/ -q -rs`

---

## Current State (verified 2026-09-27 via 4 parallel explorers + first-hand checks)

### The reference suite (`tests/functional_ui/`)

| Fact | Evidence |
|---|---|
| Real binary per test, isolated tmpdir HOME | `tests/functional/harness.py:250-259` (`boot`), `:335` (`mkdtemp(prefix="nalar-func-")`) |
| nalar argv is `[bin, "--port", port, *extra_args]` — that is all | `tests/functional/harness.py:412-418` |
| Auth is **off by default** (no `--auth`) → all endpoints open | `src/main.zig:78` (`var auth_enabled = false`), `:143-144` (only `--auth` sets it) |
| Ports: random 20000–32000; 8081 reserved | `harness.py:130-131`, `:138`, `:144` |
| Delete gate | `harness.py:166-197` `is_safe_tmp` — allow-list prefix **and** `"nalar-func-"` substring **and** ≠ real `$HOME` |
| Shared-owner visibility makes seeded rows visible | `src/http_handlers/auth_common.zig:128-133` `ownerVisibilityClause`; doc at `:111-113` — *"the system user sees everything — with `--auth` off there is no identity"* |
| Real DB rows are written directly with `sqlite3` | `tests/functional_ui/db_seed.py:53`, `:161`; safety re-check `:127-141` |
| `DbSeed` public API | `seed_session` `:171`, `seed_user_message` `:223`, `seed_assistant_message` `:271`, `seed_tool_result` `:347`, `seed_system_message` `:400`, `seed_compaction_user_message` `:431` |
| Documented column list | `db_seed.py:38-51` (`llm_history`) and `:52-58` (`sessions`) |
| Precedent for a module-scoped harness | `tests/functional/android_chat_sse_contract_test.py:93-111` shadows the `harness` fixture to `scope="module"` |
| Suite wiring | `pytest.ini:27` `pythonpath = tests/functional tests/functional_ui`; `:32` `testpaths = tests/functional` (so a third suite must be invoked explicitly) |
| Build steps to copy | `build.zig:3067-3068` (`functional-test`), `:3113-3114` (`functional-test-ui`) |

### The Android client (what must change)

| Fact | Evidence |
|---|---|
| `BASE_URL` is a compile-time constant | `app/src/main/java/com/nalar/mobile/auth/AuthConfig.kt:4` — `const val BASE_URL = "https://agent.ginwa.site"` |
| Same constant is the default for every client | `ChatClient.kt:36`, `FileClient.kt:54`, `RecentsClient.kt:26`, `ProjectsClient.kt:22`, `ChatEventStreamTransport.kt:56`, `network/RecordingAuthTransport.kt:18`, `auth/AuthClient.kt:124` |
| **Hard stop #1** — transport refuses non-HTTPS | `auth/AuthClient.kt:71-75` — `require(normalizedBaseUrl.startsWith("https://")) { "Nalar API must use HTTPS" }` |
| **Hard stop #2** — HTTP exchange casts to the TLS subclass | `http/HttpsHttpExchange.kt:19-20` — `openConnection() as? HttpsURLConnection ?: throw IOException("Request did not open an HTTPS connection")` |
| **Hard stop #3** — same cast in the binary exchange | `http/HttpsBinaryExchange.kt:60-61` (identical) |
| **Hard stop #4** — the manifest forbids cleartext | `app/src/main/AndroidManifest.xml:28` — `android:usesCleartextTraffic="false"`; no `networkSecurityConfig` attribute anywhere |
| The SSE pump needs no change | `chat/ChatEventStreamTransport.kt:250` — `openConnection() as HttpURLConnection`, justified at `:242-247` |
| All ViewModels are built in one place | `MainActivity.kt:35` (`viewModel()` for `AuthViewModel`, reflectively `AuthViewModel(application)`), `:44` (`HomeViewModel.factory`), `:49` (`ChatViewModel.factory`), `:66` (`WorkerActivityViewModel.factory`) |
| `NalarNavGraph` takes no ViewModel | `network/NalarNavGraph.kt:208` — pure state-in / callbacks-out; zero `viewModel(` in the file |
| Deep link to a chat already exists | `network/NalarNavGraph.kt:676` — `navDeepLink { uriPattern = "nalar://chat/{sessionId}" }`; manifest filter `AndroidManifest.xml:42-48` |
| Auth-off boot is a designed state | `src/http_handlers/auth_session.zig:38-41` returns `200 {"authenticated":false,"auth_enabled":false}`; the app maps that to `AuthResult.AuthDisabled` → `SessionPhase.Authenticated` with a null `userId` (`auth/AuthViewModel.kt:72`) |
| The wire the chat reads | `chat/ChatApi.kt:49` `GET /api/llm/session/<id>/messages`; `:219` `GET /api/events?channels=llm,sessions,queue`; `:72` `GET /api/config/nalar` |
| No `BuildConfig` is generated today | `app/build.gradle.kts:44-46` — `buildFeatures { compose = true }`, no `buildConfig` |
| No `src/debug/` source set exists | only `src/main`, `src/test`, `src/androidTest` |
| Rich test-tag surface to assert on | `chat_message_list` `ChatView.kt:618`; `chat_group_<role>` `:840`; `chat_tool_calls_<key>` `:858`; `chat_tool_<id>` `:899`; `chat_message_<id>` `:927,:972`; `chat_body_<id>` `:1050`; `chat_reasoning_<id>` `ReasoningBlock.kt:95`; `markdown_code` `MarkdownView.kt:237`; `html_response` `HtmlPreview.kt:76`; `chat_html_frame` `:168`; `tool_card_name` `ToolCardChrome.kt:102`; `shell_stdout` `ToolCards.kt:280`; `present_file_row` `PresentFileCard.kt:167`; `chat_composer_input` `ChatComposer.kt:237`; `chat_send` `:354`; `chat_empty` `ChatView.kt:656` |
| State that a real `MainActivity` reads on frame 1 | Room DB `nalar_cache.db` (`cache/NalarCacheDatabase.kt:73`); `nalar_position` prefs (`storage/LastPositionStore.kt:170`); `nalar_auth` encrypted prefs (`storage/EncryptedPrefs.kt:64`) |
| **No instrumented test resets any of it** | exactly one `@Before` in the whole module — `androidTest/.../auth/SessionCookieStoreTest.kt:19-30` |
| androidTest deps | `app/build.gradle.kts:115-119`; `androidx.test:rules`/`:runner` are transitive only; no orchestrator; `ui-test-manifest` is `debugImplementation` only (`:85`) |
| `InstrumentationRegistry.getArguments()` is used nowhere | zero matches across the module |

### Run mechanics (measured, not guessed)

| Fact | Evidence |
|---|---|
| JVM unit tests | `JAVA_HOME=/tmp/jdk17 ./gradlew :app:testDebugUnitTest --offline` — warm Gradle cache is enough |
| Instrumented tests | `ANDROID_HOME=$HOME/Android/Sdk ANDROID_ADB_SERVER_PORT=5040 JAVA_HOME=/tmp/jdk17 ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=…` — **no `--offline`** |
| Results to parse | `src/apps/android_mobile/app/build/outputs/androidTest-results/connected/debug/TEST-*.xml` |
| One emulator, shared | `127.0.0.1:5555`; AVD `Medium_Phone` (`android-37.2`, `google_apis_playstore_ps16k`, `x86_64`); never launch a second AVD, never kill the 5037/5038 adb servers |
| No emulator in CI today | `.github/workflows/ci.yml` has three `runs-on`s, all self-hosted (`:39`, `:1734`, `:1867`); `rg android .github/workflows/ci.yml` → 0 matches |
| An unmerged PR already owns the hosted-runner decision | branch `worktree/add-a-ci-for-unit-test-android-1790399617955` adds an `android-unit-test` job on `runs-on: ubuntu-24.04`, JDK 17 Temurin, `testDebugUnitTest` only, and says *"The instrumented suite in app/src/androidTest is deliberately NOT wired up here… Track that separately once an emulator image is cached on a runner."* |

---

## Design Decisions (for reviewer)

1. **A real emulator against a real server — not a captured-bytes replay.**
   *Rejected:* a JVM/Robolectric test that replays recorded `nalar` SSE bytes into a local `ServerSocket`, i.e. extend the successful `HttpChatEventStreamSocketTest` pattern (`app/src/test/.../HttpChatEventStreamSocketTest.kt:114`).
   *Why:* that pattern already exists and it cannot see the real ViewModel wiring, the real Room cache, the real SSE subscription, the launch gate, or the `WebView` frame. Worse, it re-introduces exactly the fixture-drift the contract tests were written to kill. The point of this suite is that **nothing is hand-written** between the server and the pixels.
   *Consequence:* this suite needs an emulator, so Phase B adds a JVM fast gate that needs none.

2. **Bake the base URL at build time via `BuildConfig`, do not mutate it at runtime.**
   *Rejected:* flip `AuthConfig.BASE_URL` to a `var` and assign it from the test.
   *Why:* `ActivityScenarioRule` launches the Activity **before** `@Before` runs, and `MainActivity.kt:35-67` resolves all four ViewModels during the first composition — so a runtime flip lands after `HttpsAuthTransport` has already captured the production URL. `viewModel()` also caches into the Activity's `ViewModelStore`, so the ordering hazard is unrecoverable. A build-time constant has no ordering at all.

3. **Plain HTTP with a debug-only cleartext allowance — not TLS with a pinned self-signed cert.**
   *Rejected:* boot nalar with `--tls-selfsigned` (the flag does exist, `src/main.zig:141`) and pin its certificate as a debug trust anchor in `network_security_config.xml`.
   *Why:* the certificate would have to be either committed (a private key in git, even a test-only one) or generated into `src/debug/res/raw/` before every build — which breaks `./gradlew assembleDebug` on a fresh clone. Two loopback hosts behind a debug-only flag is a smaller, more auditable change than a key-management story. It costs three guarded relaxations in `src/main`, all of which are `false` in release.

4. **Launch the real `MainActivity` — not `NalarNavGraph` with inert state.**
   *Rejected:* follow `NalarNavGraphResumeInstrumentedTest.kt:295-333`, which composes the real graph with hand-built state and `{}` callbacks.
   *Why:* `NalarNavGraph` takes state and lambdas, never a ViewModel (`NalarNavGraph.kt:208`), so no assertion there can distinguish "the server sent the rows" from "the test handed them in". Real data through a fake graph proves nothing. The existing pattern stays valuable for what it covers; it is not the basis for this.

5. **Direct DB seeding — not driving `POST /api/llm/session`.**
   *Rejected:* create the conversations over the API, the way `android_chat_sse_contract_test.py:194-205` makes a real turn.
   *Why:* the harness's stub LLM profile points at a **dead port** (`harness.py:1220-1230`, `base_url: "http://127.0.0.1:1"`), so a real turn cannot complete. And the shapes this suite must cover — a tool card, a `<html>` document turn, a reasoning fold, an image attachment, a `present_files` row — are not producible by an error turn. DB seeding is what the desktop suite does, for exactly this reason (`db_seed.py:2-10`).

6. **One module-scoped harness, one Gradle invocation, ten scenarios.**
   *Rejected:* a fresh harness and a fresh Gradle run per scenario.
   *Why:* each `connectedDebugAndroidTest` invocation costs a build + install + device handshake (≈1–2 min here). Ten of them turns a two-minute suite into twenty. Precedent: `android_chat_sse_contract_test.py:93` already shadows the fixture to `scope="module"`. Isolation is preserved by giving each scenario its own `session_id` — they share a database, not a row.

7. **Reach the host from the emulator at `10.0.2.2`, not via `adb reverse`.**
   *Rejected:* `adb reverse tcp:<port> tcp:<port>`.
   *Why:* `adb reverse` needs the adb CLI, which is known-broken on this box, while `10.0.2.2` is the emulator's own alias for the **host loopback interface** — so a server bound to `127.0.0.1` is reachable with no adb command at all. This matters because nalar has no `--host`/`--bind` flag (CLI surface is `--port`, `--static-dir`, `--http2`, `--tls`, `--tls-selfsigned`, `--auth` — `src/main.zig:146-151`) and binds loopback only (`src/main.zig:367`).

8. **Scenario list mirrors `tests/functional_ui/chatview_ui_test.py`'s ten.**
   *Why:* the value of a phone suite is that it renders the same real payloads the web app renders. Sharing the scenario list makes the two suites comparable, and it stops the phone from silently falling behind a renderer the web already handles — which is precisely how the `<html>` document path was missed on Android the first time (README, *"A turn that is a document is drawn, not printed"*).

9. **Ten scenarios ride in **one** instrumented class, not ten.**
   *Rejected:* a class per scenario, mirroring the desktop's file-per-stress-area layout.
   *Why:* Gradle's per-class filter argument takes a list, but every extra class in the run is more Compose-rule lifecycle surface in one instrumentation process for no isolation gain — the isolation that matters (a clean cookie, a clean cache, a clean position) comes from `ClearAppStateRule`, not from the class boundary. Split later if a scenario needs a different rule chain.

---

## Wire Contract

### The seeded tables (what the phone reads)

`llm_history` — languages the Kotlin decoder depends on (`db_seed.py:40-50`, verified against a freshly-migrated DB):

```
id, session_id, model, response_content, tool_calls_json, finish_reason,
usage_json, created_at_nano (DATETIME), role, reasoning_content,
is_feed_to_llm, agent, loop_index, temperature, is_thinking,
parent_session_id, parent_id, prompt_tokens, completion_tokens,
total_tokens, is_input, is_output, tool_name, diffview_before,
diffview_after, image_url (singular TEXT, `||`-delimited for multiple),
tool_call_id, created_iso, is_loading, cache_creation_input_tokens,
cache_read_input_tokens
```

`sessions` — `db_seed.py:52-58`:

```
id, name, status, cwd, workspace_id, created_at, updated_at,
selected_profile_model, git_worktree_cwd, is_auto_retry_until_stop,
last_finish_reason
```

There is **no FK** on `llm_history.session_id` (`db_seed.py:44-47`) — the link is enforced in app code, so ordering of inserts does not matter, but the `sessions` row is seeded anyway so the message route does not 404.

`tool_calls_json` is the OpenAI shape with a **double-encoded** `arguments` (`db_seed.py:311-316`):

```json
[{"id":"call_abc","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]
```

### Why seeded rows are visible with auth off

`src/http_handlers/auth_common.zig:128-133`, verbatim:

```zig
pub fn ownerVisibilityClause(comptime alias: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "(? = '{s}' OR {s}.user_id IS NULL OR {s}.user_id = '' OR {s}.user_id = '{s}' OR {s}.user_id = ?)",
        .{ system_user_id, alias, alias, alias, system_user_id, alias },
    );
}
```

`system_user_id = "user_system"` (`:106`). With `--auth` off the owner is the system user, the first disjunct is true, and the clause is a no-op — stated at `:111-113` and `:121-124`. **This is the single load-bearing assumption of the whole plan and it is now verified from source, not inferred.** Task 0 below re-verifies it over the wire.

### The auth-off boot envelope

`src/http_handlers/auth_session.zig:38-41` — the reason the app never shows a login screen against the harness:

```
GET /api/auth/me  →  200  {"authenticated":false,"auth_enabled":false}
```

`auth/AuthViewModel.kt:72` maps `AuthResult.AuthDisabled` → `AuthUiState(phase = SessionPhase.Authenticated)`, `userId = null`.

### The build-time injection

```
./gradlew :app:connectedDebugAndroidTest \
  -PnalarBaseUrl=http://10.0.2.2:<port> \
  -Pandroid.testInstrumentationRunnerArguments.class=com.nalar.mobile.functional.ChatFunctionalTest
```

`-PnalarBaseUrl` → `buildConfigField("String", "API_BASE_URL", …)` in the **debug** build type only. `-Pandroid.testInstrumentationRunnerArguments.<k>=<v>` → `InstrumentationRegistry.getArguments().getString("<k>")` inside the instrumented test — a mechanism used nowhere in this module today, so it is a new pattern with its first test.

### Deep link (how the test opens a specific chat)

```
nalar://chat/<sessionId>          network/NalarNavGraph.kt:676
```

Registered in the manifest at `AndroidManifest.xml:42-48` (scheme `nalar`, host `chat`) — without that filter the link matches no Activity and silently does nothing (the comment at `:44-46` says exactly this).

### The result envelope pytest parses

`src/apps/android_mobile/app/build/outputs/androidTest-results/connected/debug/TEST-*.xml`:

```xml
<testsuite name="com.nalar.mobile.functional.ChatFunctionalTest"
           tests="10" failures="0" errors="0" skipped="0" time="…">
  <testcase name="rendersRealSeededExchange" classname="…" time="…"/>
  <testcase name="rendersRealSeededToolCard"   classname="…" time="…">
    <failure message="…">…</failure>
  </testcase>
</testsuite>
```

pytest asserts `tests == len(SCENARIOS)`, `failures == 0`, `errors == 0`, then asserts each expected `<testcase name>` is present and failure-free. A missing `<testcase>` is a **fail**, not a skip — a typo'd `-P…class=` must not read as green.

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| MODIFY | `src/apps/android_mobile/app/build.gradle.kts` | `buildConfig = true`; `API_BASE_URL` + `ALLOW_INSECURE_HTTP` fields per build type; debug `API_BASE_URL` from `-PnalarBaseUrl` |
| MODIFY | `src/apps/android_mobile/app/src/main/java/com/nalar/mobile/auth/AuthConfig.kt` | `BASE_URL = BuildConfig.API_BASE_URL`; every other constant untouched |
| MODIFY | `src/apps/android_mobile/app/src/main/java/com/nalar/mobile/auth/AuthClient.kt` | Widen the HTTPS-only `require` behind `BuildConfig.ALLOW_INSECURE_HTTP` |
| MODIFY | `src/apps/android_mobile/app/src/main/java/com/nalar/mobile/http/HttpsHttpExchange.kt` | Fall back to `HttpURLConnection` when the flag is on; configure TLS only when the connection is HTTPS |
| MODIFY | `src/apps/android_mobile/app/src/main/java/com/nalar/mobile/http/HttpsBinaryExchange.kt` | Same fallback for the file-download path |
| NEW | `src/apps/android_mobile/app/src/debug/AndroidManifest.xml` | Add `android:networkSecurityConfig` to the debug `<application>` |
| NEW | `src/apps/android_mobile/app/src/debug/res/xml/network_security_config.xml` | `cleartextTrafficPermitted="true"` for `10.0.2.2` + `localhost` + `127.0.0.1`; base-config stays `false` |
| NEW | `src/apps/android_mobile/app/src/test/java/com/nalar/mobile/auth/AuthConfigContractTest.kt` | Static contract: `BuildConfig.API_BASE_URL` is set; the gradle file keeps `ALLOW_INSECURE_HTTP` false in release; no release source set ships a cleartext allowance |
| NEW | `src/apps/android_mobile/app/src/test/java/com/nalar/mobile/http/InsecureHttpExchangeTest.kt` | With the flag on, an `http://` URL opens and `HttpsAuthTransport` accepts it; a `ftp://` URL is still rejected |
| NEW | `src/apps/android_mobile/app/src/androidTest/java/com/nalar/mobile/functional/ClearAppStateRule.kt` | The module's first per-test reset: cookie, `nalar_position`, `nalar_cache.db` |
| NEW | `src/apps/android_mobile/app/src/androidTest/java/com/nalar/mobile/functional/FunctionalScenario.kt` | The ten `session_id` constants, spelled out (not imported) so drift is loud |
| NEW | `src/apps/android_mobile/app/src/androidTest/java/com/nalar/mobile/functional/ChatFunctionalTest.kt` | The driver + the ten assertions, on the real `MainActivity` |
| NEW | `tests/functional_android/__init__.py` / `requirements.txt` / `README.md` | Suite surface, deps (`pytest` only), and docs |
| NEW | `tests/functional_android/scenarios.py` | `SCENARIOS: dict[str, str]` — the python mirror of `FunctionalScenario`, seeded by the same names |
| NEW | `tests/functional_android/conftest.py` | `android_device` (session), `gradle_env` (session), `android_harness` (module), `instrumented_results` (module) |
| NEW | `tests/functional_android/android_gradle.py` | The Gradle subprocess + JUnit-XML parser; the only place `subprocess` is called |
| NEW | `tests/functional_android/chat_functional_test.py` | Boots the harness, seeds every scenario, runs Gradle once, asserts each `<testcase>` |
| NEW | `tests/functional_android/drift_test.py` | Asserts the Kotlin and Python scenario sets are identical |
| MODIFY | `pytest.ini` | `pythonpath += tests/functional_android`; explain why in the header comment |
| MODIFY | `build.zig` | `zig build functional-test-android` step, modelled on `:3113-3114` |
| MODIFY | `src/apps/android_mobile/README.md` | A *"Functional UI tests"* section: what it boots, how to run it, how to add a scenario |
| Phase B | `app/src/test/java/com/nalar/mobile/functional/ChatRenderFunctionalTest.kt` | Robolectric + real Compose + real decoder, fed by committed real payloads |
| Phase B | `app/src/test/resources/functional/chat/*.json` | Payloads captured from a real `nalar` (generated, committed) |
| Phase B | `tests/functional_android/capture_payloads.py` | The generator that produces the above from a live harness |
| Phase C | `.github/workflows/ci.yml` | `android-instrumented-test` job: hosted runner + KVM emulator + python harness + built `nalar` |

---

## Tasks

**PR boundaries.** Phase A is the deliverable and its own PR (this is the answer to *"functional test ui for android"*). Phase B is a second PR — it is the fast gate that makes the suite's coverage survive a CI box with no device. Phase C is a third PR and **must not start until the `android-unit-test` job (kanban `task_1790399629648_3`) is merged**, because that job owns the hosted-runner decision.

### Phase A — the end-to-end suite (PR 1)

- [ ] **A1. Verify the mechanism over the wire before writing anything else.**
  Add `tests/functional_android/` with only `conftest.py` and a throwaway probe test. It boots the harness, seeds one session with a user + assistant row via `DbSeed`, and asserts over HTTP — no emulator involved:
  - `GET /api/auth/me` → `200` and body `{"authenticated":false,"auth_enabled":false}` (proves auth-off boot).
  - `GET /api/llm/session/<sid>/messages` → `200`, contains both seeded `id`s, and `response_content` round-trips byte-for-byte (proves the shared-owner clause is a no-op and `DbSeed` matches the real schema the app reads).
  - `GET /api/session?sort_by=updated_at&direction=desc&limit=30&workspace_id=` → record what it returns. **Do not assert.** This is reconnaissance for the sidebar question (see Open Questions).
  **If the messages assertion fails, stop and re-plan** — every other task assumes it passes.
  Run: `NALAR_BIN=… PYTHONPATH=tests/functional:tests/functional_ui:tests/functional_android .venv-func/bin/python -m pytest tests/functional_android/ -q -rs`
  **Commit:** `test(functional-android): prove the harness reaches seeded rows over the real wire`

- [ ] **A2. Turn on `BuildConfig` and add the base-URL seam.**
  In `app/build.gradle.kts`: add `buildConfig = true` to `buildFeatures`; `defaultConfig { buildConfigField("String", "API_BASE_URL", "\"https://agent.ginwa.site\"") }`; in `buildTypes.debug` read the property —
  `val debugBaseUrl = (project.findProperty("nalarBaseUrl") as String?) ?: "https://agent.ginwa.site"` — then `buildConfigField("String", "API_BASE_URL", "\"$debugBaseUrl\"")` and `buildConfigField("boolean", "ALLOW_INSECURE_HTTP", "true")`; in `buildTypes.release` set `ALLOW_INSECURE_HTTP` to `"false"` and leave `API_BASE_URL` at the default.
  In `AuthConfig.kt`: `val BASE_URL = BuildConfig.API_BASE_URL`. Leave `LOGIN_PATH`/`LOGOUT_PATH`/`ME_PATH`/`SESSION_COOKIE_NAME` exactly as they are — every one of the ~10 `baseUrl: String = AuthConfig.BASE_URL` defaults must keep compiling untouched.
  **Commit:** `build(android): a BuildConfig base URL the debug variant can point at a local server`

- [ ] **A3. Put the security invariant under a test before widening anything.**
  Add `AuthConfigContractTest.kt` (pure JVM). It must: assert `BuildConfig.API_BASE_URL` is non-blank and, when `nalarBaseUrl` was not supplied, equals `https://agent.ginwa.site`; assert `BuildConfig.ALLOW_INSECURE_HTTP` is `true` in the debug unit-test variant; and — reading `app/build.gradle.kts` as text, the repo's `@embedFile` static-contract habit — assert the `release { … }` block declares `ALLOW_INSECURE_HTTP` as `"false"`, and that no `src/release/` directory exists under `app/src/`.
  Run `JAVA_HOME=/tmp/jdk17 ./gradlew :app:testDebugUnitTest --offline`.
  **Commit:** `test(android): pin the release build to HTTPS-only before relaxing it`

- [ ] **A4. Add the debug-only cleartext allowance.**
  `app/src/debug/AndroidManifest.xml` — an `<application android:networkSecurityConfig="@xml/network_security_config" />` fragment merged in debug only. `app/src/debug/res/xml/network_security_config.xml` — a `<base-config cleartextTrafficPermitted="false">` plus a `<domain-config cleartextTrafficPermitted="true">` listing `10.0.2.2`, `localhost`, `127.0.0.1`. Note in the file's comment that a `networkSecurityConfig` supersedes `usesCleartextTraffic`, which is why the main manifest's `false` needs no edit.
  Verify both ways: `./gradlew :app:assembleDebug` then read `app/build/intermediates/merged_manifests/debug/AndroidManifest.xml` and confirm the attribute is present; `./gradlew :app:assembleRelease` and confirm it is **absent**.
  **Commit:** `build(android): permit cleartext to the two loopback hosts in debug only`

- [ ] **A5. Widen the three HTTPS-only spots behind the flag.**
  `AuthClient.kt:71-75` — `require(normalizedBaseUrl.startsWith("https://") || BuildConfig.ALLOW_INSECURE_HTTP)`, keeping the same message for the release path (add a second message for the insecure case so a misconfigured release says which condition failed).
  `HttpsHttpExchange.kt:19-20` and `HttpsBinaryExchange.kt:60-61` — open the connection as `HttpURLConnection`, then guard the TLS-only configuration: only call `setSSLSocketFactory` / TLS-specific setup when `connection is HttpsURLConnection`. Keep the `IOException` for the truly-unopenable case.
  `InsecureHttpExchangeTest.kt` — with the flag on: an `http://127.0.0.1:<throwaway ServerSocket port>` request round-trips; `HttpsAuthTransport("http://…")` constructs without throwing; `HttpsAuthTransport("ftp://…")` still throws. Reuse the throwaway-`ServerSocket` style already proven in `app/src/test/.../HttpChatEventStreamSocketTest.kt`.
  **Commit:** `feat(android): let the debug client open a plain-HTTP socket to a local server`

- [ ] **A6. The per-test device-state reset.**
  `ClearAppStateRule.kt` — an `ExternalResource` whose `before()` clears, in order: `SessionCookieStore(targetContext).clear()`; `targetContext.getSharedPreferences("nalar_position", MODE_PRIVATE).edit().clear().commit()`; `targetContext.deleteDatabase(NalarCacheDatabase.NAME)`. Read the names from the constants, never re-type the strings (`NalarCacheDatabase.kt:73`, `LastPositionStore.kt:170`).
  Add its own instrumented test: write a cookie + a position + a Room row, apply the rule, assert all three are gone.
  **Commit:** `test(android): the first per-test device-state reset in this module`

- [ ] **A7. The scenario constants, on both sides.**
  `FunctionalScenario.kt` — ten `const val`, one per scenario. `tests/functional_android/scenarios.py` — `SCENARIOS: dict[str, str]` mapping the same names. Put a comment in **both** files saying the values are deliberately duplicated rather than shared, so a drift fails loudly instead of silently skipping — the same reasoning as `CHAT_CHANNELS` in `android_chat_sse_contract_test.py:54`.
  Scenario ids: `sess_fn_empty`, `sess_fn_exchange`, `sess_fn_multiturn`, `sess_fn_toolcalls`, `sess_fn_toolresult`, `sess_fn_markdown`, `sess_fn_images`, `sess_fn_reasoning`, `sess_fn_html`, `sess_fn_presentfiles`.
  **Commit:** `test(android): the ten functional scenario ids and their python mirror`

- [ ] **A8. Seed all ten scenarios from pytest.**
  `tests/functional_android/seed_scenarios.py` — one function per scenario, each taking `(seed: DbSeed, conn, session_id)` and returning nothing. Reuse `DbSeed` as-is; **do not add a seeder** unless a scenario needs a column it cannot reach (if one does, add it to `db_seed.py` so the desktop suite gains it too).
  Scenario → rows:
  1. `empty` — `sessions` only.
  2. `exchange` — user "hi there from the harness" + assistant "hello! this reply came out of the database".
  3. `multiturn` — 8 alternating rows, `baseline_timestamps(interval_seconds=30)` so ordering is unambiguous.
  4. `toolcalls` — assistant with a `bash` call in `tool_calls_json`.
  5. `toolresult` — the assistant tool call + the matching `seed_tool_result(tool_name="bash", content="…stdout…")`.
  6. `markdown` — assistant with `# Heading\n**bold**\n\`code\`\n\`\`\`bash\nls\n\`\`\``.
  7. `images` — user with `image_urls=[TINY_PNG_DATA_URL, TINY_PNG_DATA_URL]`.
  8. `reasoning` — assistant with `is_thinking=True` and a long `reasoning_content`.
  9. `html` — assistant whose content is a real `<html>…</html>` document. **Lift the payload from the project's own real rows**, not from imagination — the desktop repro skill explains why: the model's own wrapper tags and inline styles are what make the repro exact.
  10. `presentfiles` — a tool result named `present_files` carrying a real payload (a source: `tests/functional/agent_present_files_test.py` already drives this shape end to end).
  **Commit:** `test(functional-android): seed the ten real-data scenarios into the harness DB`

- [ ] **A9. The instrumented driver.**
  `ChatFunctionalTest.kt`:
  - Launch: `createAndroidComposeRule<MainActivity>(ActivityScenarioRule(MainActivity::class.java, deepLinkIntent(sid)))`. **Confirm this overload exists** — `androidx.compose.ui.test.junit4.createAndroidComposeRule(ActivityScenarioRule<A>)`. If it does not, use `createEmptyComposeRule()` and launch the Activity yourself with `ActivityScenario.launch(intent)` in `@Before`; both are documented paths and the choice is a 10-minute spike, not a design change.
  - Rule chain: `RuleChain.outerRule(ClearAppStateRule()).around(composeRule)` so the reset runs **before** the Activity launches.
  - Read the base URL override from `InstrumentationRegistry.getArguments()` in a `@Before` **as an assertion**, not as a wire-up: if the argument is missing, fail with a message naming the `-P` flag. The URL itself comes from `BuildConfig`, so a missing argument means the harness is misconfigured, not that the app is.
  - Wait: after launch, `waitUntilAtLeastOneExists(hasTestTag("chat_message_list"), timeoutMillis = 20_000)`; if `launch_gate` is still present after that, fail with "the launch gate never opened" rather than a bare timeout.
  - One `@Test` per scenario, named after the scenario id, each opening its own deep link. Assertions use the tags in the Current State table — e.g. `chat_group_assistant`, `chat_tool_<id>` + `shell_stdout`, `chat_reasoning_<id>`, `markdown_code`, `html_response` + `chat_html_frame`, `present_file_row`, `chat_empty`.
  **Commit:** `test(android): drive the real MainActivity against a real nalar and assert the rendered transcript`

- [ ] **A10. The Gradle runner + XML parser.**
  `tests/functional_android/android_gradle.py`:
  - `run_instrumented(*, port: int, test_class: str, timeout_s: int = 900) -> Path` — builds the argv `["./gradlew", ":app:connectedDebugAndroidTest", "--console=plain", f"-PnalarBaseUrl=http://10.0.2.2:{port}", f"-Pandroid.testInstrumentationRunnerArguments.class={test_class}"]`, cwd `src/apps/android_mobile`, env = `os.environ` + `JAVA_HOME`, `ANDROID_HOME`, `ANDROID_ADB_SERVER_PORT=5040`. **No `--offline`.** Returns the newest `TEST-*.xml` under `app/build/outputs/androidTest-results/connected/debug/`.
  - `parse_suite(path) -> SuiteResult` — `xml.etree.ElementTree`, exposing `tests`, `failures`, `errors`, `skipped` and a `{name: failure_message_or_None}` map.
  - Never shells out to `adb`.
  **Commit:** `test(functional-android): one gradle invocation, one parsed JUnit suite`

- [ ] **A11. The pytest harness wiring.**
  `tests/functional_android/conftest.py`:
  - `android_device` (session) — skip unless a device reports as attached. Probe **through Gradle**, not `adb`: run `./gradlew :app:connectedDebugAndroidTest --dry-run` is not a device probe, so instead probe the emulator socket directly (`socket.create_connection(("127.0.0.1", 5555), 2)`, POSIX) and skip with the message *"no emulator on 127.0.0.1:5555 — start the Medium_Phone AVD or run this suite with a device attached"*.
  - `gradle_env` (session) — skip with a named reason when `src/apps/android_mobile/gradlew` is missing, when no JDK 17 is found (`/tmp/jdk17`, `~/.local/jdk17`, `JAVA_HOME`), or when `$ANDROID_HOME`/`~/Android/Sdk` is absent. Write `src/apps/android_mobile/local.properties` only if it does not already exist, and say so in the skip/first-run log — it is gitignored and a fresh worktree needs it.
  - `android_harness` (**module**) — `FunctionalHarness.boot(nalar_bin, stub_llm_profile=True)` with `try/finally` teardown, exactly like `tests/functional/conftest.py:73-92`.
  - `seeded` (module) — seeds all ten scenarios once into `h.temp_dir / ".config" / "nalar" / "agent.db"`.
  - `instrumented_results` (module) — calls `run_instrumented` once, parses once, returns the `SuiteResult`. If Gradle fails, return the failure with the last 100 log lines attached so the first pytest failure is readable.
  **Commit:** `test(functional-android): fixtures that boot the harness once and run gradle once`

- [ ] **A12. The ten assertions + the drift guard.**
  `chat_functional_test.py` — one `@pytest.mark.parametrize`d test over `SCENARIOS`, each asserting its `<testcase>` exists and has no `<failure>`; plus a suite-level test asserting `tests == len(SCENARIOS)`, `failures == 0`, `errors == 0`, and that `skipped == 0` (a skipped instrumented test is a silent hole, not a pass).
  `drift_test.py` — read `FunctionalScenario.kt` as text, extract the `sess_fn_*` literals, assert the set equals `SCENARIOS.values()`. Fails loudly on a rename on either side.
  Update `pytest.ini`: add `tests/functional_android` to `pythonpath` and extend the header comment, which currently promises exactly two suites.
  **Commit:** `test(functional-android): assert every seeded scenario rendered on the device`

- [ ] **A13. Wire the build step + document it.**
  `build.zig` — a `functional-test-android` step modelled on `:3113-3114`: install `tests/functional_android/requirements.txt` into the same venv, then `python -m pytest tests/functional_android/ -v --tb=short`, depending on `b.getInstallStep()` (the binary the harness boots) and the python probe. It must not install Playwright — this suite needs none of it.
  `src/apps/android_mobile/README.md` — a *"Functional UI tests"* section: what is booted, the isolation guarantee, the two host names, why the base URL is a build-time constant, the JDK-17 requirement, and the exact command. Say plainly that it needs an emulator and that it is therefore **not** part of `android-unit-test`.
  **Commit:** `docs(android): how to run the functional UI suite and what it boots`

- [ ] **A14. Run it and keep the evidence.**
  Run the suite against the running emulator. Paste into the PR body: the pytest summary line, the parsed `tests/failures/errors/skipped` counts, the harness's isolated `temp_dir` path, and the three gate commands from Global Constraints with their results. Then prove the suite can actually fail: temporarily break one assertion (e.g. change a seeded string so the tag no longer matches) and paste the red run. A green suite that cannot go red is not evidence.
  **Commit:** `test(functional-android): the suite passes, and fails when it should`

### Phase B — the fast gate that needs no device (PR 2)

- [ ] **B1.** `tests/functional_android/capture_payloads.py` — boot the harness, seed the same ten scenarios, and write the raw `GET /api/llm/session/<sid>/messages` responses to `src/apps/android_mobile/app/src/test/resources/functional/chat/<scenario>.json`. **Commit these files.** A fixture that is generated but not committed is a fixture nobody has.
- [ ] **B2.** `ChatRenderFunctionalTest.kt` — Robolectric + `createComposeRule` + the real decode path + the real `ChatView`, fed from those JSON resources. This is the layer that catches a renderer regression on every PR, on the `testDebugUnitTest` task the (unmerged) `android-unit-test` job already runs.
- [ ] **B3.** A test asserting the committed payloads still match what the *current* `nalar` produces (boot the harness, re-fetch, diff). Without it the fixtures rot — which is the exact failure the contract tests exist to prevent, and the reason this suite exists in the first place.
  **Commit:** `test(android): render the real captured payloads on the JVM, no emulator required`

### Phase C — CI (PR 3, blocked on `android-unit-test` merging)

- [ ] **C1.** Add an `android-instrumented-test` job. Preconditions, all of them: the `android-unit-test` job is on `main`; the runner is a **GitHub-hosted** `ubuntu-24.04` (the unmerged job's own reasoning: the self-hosted box has neither a verified SDK nor a JDK 17, and its default JDK 27 is rejected by AGP); KVM is available (`/dev/kvm` on hosted Linux runners).
- [ ] **C2.** Boot the emulator in-job — `reactivecircus/android-emulator-runner@v2`, `api-level: 35` to match `compileSdk`, `target: google_apis`, `arch: x86_64`, `script:` running the pytest suite. Cache the system image.
- [ ] **C3.** Build the `nalar` binary on that runner and pass `NALAR_BIN` to the suite. The harness needs a real binary; the Zig toolchain setup already exists in the `functional-test` job and should be copied, not reinvented.
- [ ] **C4.** Report honestly: if the emulator flake rate is non-trivial, land the job as `continue-on-error: true` with a comment saying so and a tracking card — do not let a flaky emulator block merges, and do not silently mark it required either.
  **Commit:** `ci(android): run the functional UI suite on a hosted runner with a KVM emulator`

---

## Verification

- **A1 gate:** the probe test passes and its output shows the seeded message ids coming back from `GET /api/llm/session/<sid>/messages`. If it does not, nothing else in Phase A is built.
- **Security gate (the one that matters most):** `./gradlew :app:assembleRelease` produces a merged manifest with **no** `networkSecurityConfig` and `usesCleartextTraffic="false"`; `:app:assembleDebug` produces one with both. `./gradlew :app:testDebugUnitTest` green, including `AuthConfigContractTest`.
- **No-regression gate:** the full JVM suite (`:app:testDebugUnitTest`) is green — its current baseline is 1005 `@Test` across 71 files. `tests/functional/` (113 files) is green. `tests/functional_ui/` is green.
- **Isolation gate:** after a full functional-android run, `ls $HOME` and `ls $HOME/.config/nalar/` show no new `nalar-func-*` directories and no touched `agent.db` mtime. `tests/functional/harness_safety_test.py` (17 tests) stays green.
- **Refactor / no-silent-skip gate:** the suite must **skip**, not fail, with a named reason when no device is attached, and must **fail** when a device is attached but a `<testcase>` is missing from the XML. Both branches need a demonstration.
- **Determinism gate:** run the instrumented suite twice back to back on the same emulator and get the same result. A suite that only passes on a clean app-data state is not isolated — it is lucky.
- **Drift gate:** `drift_test.py` fails when either side's `sess_fn_*` set is edited. Verify by temporarily renaming one constant.
- **Port gate:** every run's `harness.port` is outside 8080/8081 and inside 20000–32000; the log shows exactly one nalar boot and one teardown per run.

---

## Out of Scope

- **The sidebar / recents scenario.** `RecentsSidebar.kt` does render real rows, but the recents list is scoped: `RecentsApi.chatsPath` always sends `workspace_id` (`RecentsApi.kt:45-60`) and the server fails **closed** on an empty or unknown id (`session_list.zig:4-6`, `:78-81`). Seeding a session alone therefore does not put a row in the drawer; it needs a `workspaces` row plus whatever links a session to it. `DbSeed` has no workspace seeder. That is a real piece of work and a different kind of test — it belongs in a follow-up once A1's reconnaissance answers what `GET /api/session?...&workspace_id=` actually returns for the seeded rows.
- **Live streaming.** The harness's stub LLM points at a dead port, so no real turn can complete. Asserting deltas arrive needs either a fake OpenAI-compatible SSE server (which would be the first of its kind in this repo) or `NALAR_TEST_SSE_EMIT=1` + `POST /api/dev/sse/emit_llm`. Both are a separate plan.
- **The composer's send path end-to-end.** Requires a working LLM turn for the assertion to mean anything; the queue-message behaviour already has 1005 JVM tests around it.
- **Screenshot / golden-file diffing.** The desktop suite's `artifacts/` dir only saves on failure; baselines are a separate feature.
- **An Android equivalent of `tests/functional_ui/artifacts/`.** Useful, cheap, and not needed for the first version — Gradle already keeps the HTML report and the JUnit XML.
- **Moving `ChatViewTest`'s 14 pre-existing failures.** They are a known baseline, not this plan's business, and the plan deliberately filters them out of the run.

## Open Questions for the reviewer

1. **Is the emulator dependency acceptable for a *functional* suite?** Decision 1 says yes and Decision 7 pays for it with an emulator. The alternative — accept the captured-payload JVM suite **as** the functional suite and never launch the real app — is cheaper and is what the repo chose once before (`NalarNavGraphLaunchGateTest` moved from instrumented to Robolectric, README *"The gate is tested on the JVM, not on an emulator"*). This plan does both, with the JVM half in Phase B. Teeing off Phase B instead of Phase A would be a defensible re-scoping; it is a scope decision, not a technical one, so it wants a human.
2. **Should `ALLOW_INSECURE_HTTP` exist in `src/main` at all?** Decision 3 accepts three guarded relaxations in production code so the debug variant can speak HTTP. A stricter reviewer might prefer the TLS + pinned-cert route (which keeps `src/main` pristine at the cost of a test key on disk), or a `src/debug` *variant class* if AGP's duplicate-class rules permit one. This is the plan's biggest taste call.
3. **Phase C's blocker.** Phase C cannot start before `task_1790399629648_3` (`android-unit-test`) merges, because that job decides the hosted-runner question for this repo. Confirm that ordering, or state that the emulator job may introduce its own hosted runner independently.
4. **Ten scenarios, ten `@Test`s, one class.** Decision 9. If reviewers prefer per-scenario classes for a cleaner Gradle report, that is a cheap change — say so before A9 rather than after.
5. **Where should the seeded payloads for scenario 9 (`html`) and 10 (`presentfiles`) come from?** The plan says "lift them from real rows in this project's own `agent.db`". If the reviewer would rather they come from a documented, checked-in fixture so the payload is reviewable in the diff, that changes A8's instructions.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| The `-Pandroid.testInstrumentationRunnerArguments.<k>` plumbing does not reach `createAndroidComposeRule`'s launch (the rule launches before `@Before`) | Medium | The URL is **not** passed that way — it is a `BuildConfig` constant. The instrumentation argument is only a *guard* that the harness set the property. If the guard cannot be read early enough, drop to a plain assertion in the Gradle log instead. |
| `createAndroidComposeRule(ActivityScenarioRule(intent))` overload does not exist | Medium | A9 names the fallback: `createEmptyComposeRule()` + `ActivityScenario.launch(intent)`. Confirmed as a 10-minute spike. |
| The launch gate never opens because `LastPositionStore` retains a stale position from a previous run | Medium | `ClearAppStateRule` (A6) clears it before the Activity is created, and A14's determinism gate runs the suite twice back-to-back. |
| Compose's "Cannot call setContent twice per test!" — the failure already hitting 5 tests in `ChatViewTest` | Medium | One `@Test` per scenario, one `setContent` per test via the rule. If a scenario needs to re-point at a second session, it uses the deep link from a fresh rule application, never a second `setContent`. |
| Gradle drives adb on port 5037 by default and collides with another session's server | Low | `ANDROID_ADB_SERVER_PORT=5040` is set explicitly in `gradle_env` and in the Global Constraints commands. |
| No `--offline` means the Gradle run needs network and can flake | Medium | `--offline` fails *after* the tests pass (missing UTP artifact), which is worse than network dependency. Accept the network, and pin the emulator/test deps in the Gradle cache where possible. |
| The emulator is shared with other agents and a test's app-data reset disturbs someone else's run | Low–Medium | The reset is scoped to `com.nalar.mobile`'s own cookie/prefs/DB. Do not `pm clear` the package globally, and do not install/uninstall the APK outside Gradle. |
| The AVD is `android-37.2` while the app's `compileSdk` is 35 — an API-level mismatch produces a device-only failure | Low | Install/run on API 35 for Phase C; locally, record the AVD's API level in the PR body so a device-only failure is attributable. |
| Adding `buildConfig = true` changes generated sources and breaks an unrelated test | Low | Pure addition — nothing in the module references `BuildConfig` today (`rg BuildConfig` → 0 hits). The full `testDebugUnitTest` run is a gate. |

## Plan saved checklist

- [x] Plan doc written at `docs/superpowers/plans/2026-09-27-android-functional-ui-test.md`
- [x] Every load-bearing fact carries a `path:line` citation verified first-hand (not taken from a sub-agent's summary)
- [x] The riskiest assumption — that `DbSeed`-seeded rows are visible to the app with auth off — is verified from source *and* given its own wire-level probe as the first task
- [ ] **User reviewed before execution** ← human's call; nothing above should be implemented until this is ticked
