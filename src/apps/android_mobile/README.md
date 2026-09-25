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
Submitting valid preview credentials opens `MobileHomeScreen`, whose left
navigation drawer contains only a workspace selector and the selected
workspace's recent chat list. Workspace changes scope the list immediately and
choosing a chat updates the active selection and closes the modal drawer.

The mobile app still does not declare the Internet permission or claim to
authenticate against a server. The sidebar currently uses injected preview data;
its callbacks are the integration seams for a future authenticated API client.
