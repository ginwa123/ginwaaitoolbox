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

An emulator or device is required for instrumentation tests:

```bash
./gradlew connectedDebugAndroidTest
```

Android Studio can open `src/apps/android_mobile` as a standalone project.
Install an Android SDK containing platform 35 and build tools when using a fresh
machine.

## Continuous integration

Pull requests run the JVM unit tests in the `android-unit-test` job of
`.github/workflows/ci.yml`. That suite is the 74 tests across the eight files
in `app/src/test`, and it needs no emulator: they are plain JVM tests with no
Robolectric and no Android framework classes. The job installs platform 35 and
build tools, runs `testDebugUnitTest`, and uploads the HTML report and the raw
JUnit XML as an artifact, so a failure is readable in the run summary instead
of only as a red check.

Two details are worth knowing before you reproduce that run by hand:

- **JDK 17 is required, and the failure mode is unhelpful.** Android Gradle
  Plugin 8.7.3 rejects a newer JDK and aborts with a bare version number and
  no stack trace — a machine defaulting to JDK 27 prints `27` under
  "What went wrong". Check `java -version` first, or point `JAVA_HOME` at a
  JDK 17 installation.
- **`testDebugUnitTest`, not `test`.** The aggregate `test` task also runs
  `testReleaseUnitTest`, which compiles and executes the same tests a second
  time for the release variant. CI uses the debug task to keep runs short.

The instrumented tests in `app/src/androidTest` are not part of that job. They
need a booted emulator, so they stay a local-only step:

```bash
./gradlew connectedDebugAndroidTest
```

## Current behavior

The Android app authenticates against `https://agent.ginwa.site` through
`POST /api/auth/login`. A successful sign-in stores the `nalar_session` cookie
encrypted with an Android Keystore AES-GCM key. On startup the app verifies that
cookie with `GET /api/auth/me`; a 401 clears it and returns to the login screen.
Network and credential errors are shown in the login form, and the submit
button is disabled while a request is in flight.

The authenticated home shell still uses injected workspace/chat preview data.
Its workspace selector and recent-chat callbacks are the integration seams for
the next API-backed milestone. The app declares `INTERNET` but explicitly
rejects cleartext traffic, so the auth client only accepts HTTPS endpoints.
A transient startup verification failure offers retry and account-switch
recovery without deleting the saved cookie.

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

### Deep links

The inspector and its record detail are navigation routes, so they survive
process death and system Back. `nalar://network` opens the list and
`nalar://network/record/{id}` opens one captured record.
