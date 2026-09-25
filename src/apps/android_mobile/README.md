# Nalar Android

A native Android client for Nalar, written in Kotlin with Jetpack Compose. The
current milestone includes real HTTPS sign-in against `agent.ginwa.site`,
encrypted session restoration, and a left drawer with workspace-scoped recent
chats. It does not embed the web app and does not start or manage a Nalar
server.

## Stack

- Kotlin 2.0.21
- Jetpack Compose Material 3
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
