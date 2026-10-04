package com.pabrik.mobile.auth

import com.pabrik.mobile.BuildConfig
import com.pabrik.mobile.server.ServerUrl

/**
 * Endpoints and the one value that is not a constant of the API: the host.
 *
 * [BASE_URL] is a **getter**, and that is the whole reason the app can be
 * pointed at another server. It is a getter rather than a `val` holding
 * [BuildConfig.API_BASE_URL] because every transport in this app takes the host
 * as a `() -> String` and calls it per request — a `val` evaluated once at
 * construction would still be a snapshot, just a later one.
 *
 * Where it comes from has two layers, and the order matters:
 *
 *  1. [ServerUrl.value] — what the reader chose, persisted, surviving process
 *     death. The self-hoster's own deployment.
 *  2. [BuildConfig.API_BASE_URL] — the host the build shipped with, which is
 *     also the answer before `MainActivity` has installed the store and before
 *     anyone has typed anything. It remains the build-time seam the functional
 *     UI suite drives with `-PpabrikBaseUrl`.
 *
 * The reader only gets offered layer 1; layer 2 is what "Use the default server"
 * goes back to, which is why it is kept as its own name and not folded into the
 * getter.
 */
object AuthConfig {
    /** The host every request is sent to, right now. */
    val BASE_URL: String get() = ServerUrl.value

    /** The host this build shipped with, and what "reset" returns to. */
    val BUILD_DEFAULT_BASE_URL: String = BuildConfig.API_BASE_URL

    const val LOGIN_PATH = "/api/auth/login"
    const val LOGOUT_PATH = "/api/auth/logout"
    const val ME_PATH = "/api/auth/me"
    const val SESSION_COOKIE_NAME = "pabrik_session"
}
