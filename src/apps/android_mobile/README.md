# Nalar Android

A native Android client for Nalar, written in Kotlin with Jetpack Compose. The
first milestone is intentionally focused: it presents a polished, dark-only
sign-in screen and keeps the authentication boundary ready for the next
iteration. It does not embed the web app and does not start or manage a Nalar
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

`LoginScreen` owns the form state and validates email/password input locally.
The `onSignIn` callback is the integration seam for the future
`POST /api/auth/login` client. This milestone does not declare the Internet
permission or claim to authenticate against a server; it is a native UI
preview until that client is added.
