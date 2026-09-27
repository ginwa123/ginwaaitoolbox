package com.nalar.mobile.auth

import com.nalar.mobile.BuildConfig

/**
 * Endpoints and the one value that is not a constant of the API: the host.
 *
 * [BASE_URL] comes from the build rather than from a literal here, because the
 * host is the only part of the client that differs between a shipped app and a
 * test run — and it has to be decided at *build* time, not at runtime. The app
 * resolves every ViewModel during `MainActivity`'s first composition, and an
 * instrumented test rule launches that Activity before any `@Before` runs, so
 * there is no point at which a test could assign a host and have it observed.
 * See `app/build.gradle.kts` for the per-variant values.
 */
object AuthConfig {
    val BASE_URL: String = BuildConfig.API_BASE_URL

    const val LOGIN_PATH = "/api/auth/login"
    const val LOGOUT_PATH = "/api/auth/logout"
    const val ME_PATH = "/api/auth/me"
    const val SESSION_COOKIE_NAME = "nalar_session"
}
