package com.nalar.mobile.auth

import com.nalar.mobile.http.HttpHeader
import com.nalar.mobile.http.HttpRequestSpec
import com.nalar.mobile.http.HttpsHttpExchange
import org.json.JSONObject
import java.net.HttpURLConnection

data class AuthUser(
    val id: String,
    val email: String,
    val name: String,
    val role: String,
)

data class AuthHttpResponse(
    val statusCode: Int,
    val body: String,
    val setCookieHeaders: List<String> = emptyList(),
    /** Full response header list; the network inspector shows it verbatim. */
    val headers: List<HttpHeader> = emptyList(),
)

sealed interface AuthResult {
    data class Authenticated(val user: AuthUser) : AuthResult
    data class Rejected(val message: String) : AuthResult
    data class Unavailable(val message: String) : AuthResult
    data object NoSession : AuthResult
    data object AuthDisabled : AuthResult
}

interface AuthTransport {
    fun post(
        path: String,
        body: String,
        headers: Map<String, String>,
    ): AuthHttpResponse

    fun get(
        path: String,
        headers: Map<String, String>,
    ): AuthHttpResponse

    /**
     * `PUT /api/llm/session/{id}` is how a per-session profile choice is
     * persisted, and the backend has no `POST` alias for it.
     *
     * A default that throws rather than an abstract member: the app has a
     * double-digit number of transport fakes in its tests, each written against
     * a two-method interface, and only the one test that exercises the profile
     * picker needs this verb. Abstracting it makes every one of them a
     * `NotImplementedError` they never call, which is churn with no coverage
     * behind it. A fake that a `put` does reach still fails loudly.
     */
    fun put(
        path: String,
        body: String,
        headers: Map<String, String>,
    ): AuthHttpResponse = throw UnsupportedOperationException(
        "This transport does not implement PUT",
    )
}

class HttpsAuthTransport(baseUrl: String) : AuthTransport {
    private val normalizedBaseUrl = baseUrl.trimEnd('/')
    private val exchange = HttpsHttpExchange(
        connectTimeoutMillis = NETWORK_TIMEOUT_MILLIS,
        readTimeoutMillis = NETWORK_TIMEOUT_MILLIS,
    )

    init {
        require(normalizedBaseUrl.startsWith("https://")) {
            "Nalar API must use HTTPS"
        }
    }

    override fun post(
        path: String,
        body: String,
        headers: Map<String, String>,
    ): AuthHttpResponse = request("POST", path, body, headers)

    override fun get(
        path: String,
        headers: Map<String, String>,
    ): AuthHttpResponse = request("GET", path, null, headers)

    override fun put(
        path: String,
        body: String,
        headers: Map<String, String>,
    ): AuthHttpResponse = request("PUT", path, body, headers)

    private fun request(
        method: String,
        path: String,
        body: String?,
        headers: Map<String, String>,
    ): AuthHttpResponse {
        val response = exchange.execute(
            HttpRequestSpec(
                method = method,
                url = "$normalizedBaseUrl$path",
                headers = headers.map { (name, value) -> HttpHeader(name, value) },
                body = body,
            ),
        )

        return AuthHttpResponse(
            statusCode = response.statusCode,
            body = response.body.orEmpty(),
            setCookieHeaders = response.headerValues("Set-Cookie"),
            headers = response.headers,
        )
    }

    private companion object {
        const val NETWORK_TIMEOUT_MILLIS = 15_000
    }
}

class AuthClient(
    private val sessionStore: SessionStore,
    baseUrl: String = AuthConfig.BASE_URL,
    httpTransport: AuthTransport? = null,
    private val meCache: AuthMeCache? = null,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val transport: AuthTransport = httpTransport ?: HttpsAuthTransport(baseUrl)

    fun login(email: String, password: String): AuthResult {
        val requestBody = JSONObject()
            .put("email", email)
            .put("password", password)
            .toString()

        val response = try {
            transport.post(
                path = AuthConfig.LOGIN_PATH,
                body = requestBody,
                headers = mapOf("Content-Type" to "application/json"),
            )
        } catch (_: Exception) {
            return AuthResult.Unavailable(networkErrorMessage())
        }

        if (response.statusCode !in 200..299) {
            return AuthResult.Rejected(messageForStatus(response.statusCode))
        }

        val sessionCookie = parseSessionCookie(response.setCookieHeaders)
            ?: return AuthResult.Rejected("The server signed in without a session cookie. Try again.")
        val user = parseUser(response.body)
            ?: return AuthResult.Rejected("The server returned an unexpected sign-in response.")

        return try {
            sessionStore.save(sessionCookie)
            // The new cookie fingerprints to a different cache namespace, but
            // clearing also drops the pre-login verdict, which is the one the
            // web calls out specifically.
            meCache?.clear()
            AuthResult.Authenticated(user)
        } catch (_: Exception) {
            runCatching { sessionStore.clear() }
            AuthResult.Unavailable("Signed in, but this device could not save the session.")
        }
    }

    /**
     * Resolves the current session.
     *
     * A fresh (sub-TTL) cache entry answers without a network call at all.
     * [forceRefresh] skips the cache, which is what the "Try again" button on
     * the retry screen needs — the user pressed it precisely to re-check, so
     * replaying a cached answer would make the button inert.
     */
    fun restoreSession(forceRefresh: Boolean = false): AuthResult {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return AuthResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        // No cookie means nothing to attribute a cached identity to; `/me`
        // would answer unauthenticated anyway.
        val fingerprint = sessionCookie?.let { AuthMeCacheCodec.fingerprint(it) }

        if (!forceRefresh && fingerprint != null) {
            val cached = meCache?.read(fingerprint)
            if (cached != null && cached.isFresh(nowMillis(), AuthMeCacheCodec.TTL_MILLIS)) {
                val fromCache = interpretMe(cached.body)
                if (fromCache.isServableFromCache()) return fromCache
                // A cached body we cannot make a decision from is a MISS, not an
                // answer. Falling through here is what stops a corrupt entry from
                // signing the user out.
            }
        }

        val response = try {
            transport.get(
                path = AuthConfig.ME_PATH,
                headers = sessionCookie
                    ?.let { mapOf("Cookie" to cookieHeader(it)) }
                    .orEmpty(),
            )
        } catch (_: Exception) {
            return AuthResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            // The cookie is dead. Anything cached against it is now a lie.
            meCache?.clear()
            return clearSessionOrUnavailable()
        }
        if (response.statusCode !in 200..299) {
            return AuthResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        // Only 2xx is cached: Android's recovery path is a retry button, and a
        // cached error status would make that button do nothing.
        if (fingerprint != null) {
            meCache?.write(fingerprint, response.body, nowMillis())
        }

        return interpretMe(response.body)
    }

    /**
     * The one place a `/me` body becomes an [AuthResult]. The cached and the
     * network path both go through it, so a cached identity cannot be judged by
     * different rules than a live one.
     */
    private fun interpretMe(body: String): AuthResult {
        val me = parseMe(body)
            ?: return AuthResult.Unavailable(SESSION_ERROR_MESSAGE)
        if (!me.authEnabled) {
            return AuthResult.AuthDisabled
        }
        if (me.authenticated && me.user != null) {
            return AuthResult.Authenticated(me.user)
        }
        // A 2xx body that still says "not signed in" — do not leave a cached
        // copy of it behind, or the next launch re-reads the same verdict.
        meCache?.clear()
        return clearSessionOrUnavailable()
    }

    fun logout(): AuthResult {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return AuthResult.Unavailable("Could not read the saved session.")
        }
        if (sessionCookie != null) {
            try {
                transport.post(
                    path = AuthConfig.LOGOUT_PATH,
                    body = "{}",
                    headers = mapOf(
                        "Content-Type" to "application/json",
                        "Cookie" to cookieHeader(sessionCookie),
                    ),
                )
            } catch (_: Exception) {
                // Local logout must still succeed when the server is unreachable.
            }
        }
        // Do this first: once the cookie is gone there is no fingerprint, so
        // the entry would otherwise be orphaned rather than erased.
        meCache?.clear()
        return try {
            sessionStore.clear()
            AuthResult.NoSession
        } catch (_: Exception) {
            AuthResult.Unavailable("Could not clear the saved session.")
        }
    }

    private fun clearSessionOrUnavailable(): AuthResult = try {
        sessionStore.clear()
        AuthResult.NoSession
    } catch (_: Exception) {
        AuthResult.Unavailable(SESSION_ERROR_MESSAGE)
    }

    /**
     * True for the two answers worth replaying from cache: a resolved identity,
     * or auth being off. Anything else — unparseable, or a body that says "not
     * signed in" — must be re-checked against the network rather than acted on.
     */
    private fun AuthResult.isServableFromCache(): Boolean =
        this is AuthResult.Authenticated || this is AuthResult.AuthDisabled

    private fun networkErrorMessage(): String =
        "Could not reach ${AuthConfig.BASE_URL}. Check your connection."

    private fun cookieHeader(sessionCookie: String): String =
        "${AuthConfig.SESSION_COOKIE_NAME}=$sessionCookie"

    private fun messageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_BAD_REQUEST ||
            statusCode == HttpURLConnection.HTTP_UNAUTHORIZED ||
            statusCode == HttpURLConnection.HTTP_FORBIDDEN -> "Invalid email or password."
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> networkErrorMessage()
        statusCode in 500..599 -> "The server could not complete sign in. Try again later."
        else -> "Sign-in failed. Try again."
    }

    private data class AuthMe(
        val authenticated: Boolean,
        val authEnabled: Boolean,
        val user: AuthUser?,
    )

    private fun parseMe(body: String): AuthMe? = try {
        val json = JSONObject(body)
        AuthMe(
            authenticated = json.optBoolean("authenticated", false),
            authEnabled = json.optBoolean("auth_enabled", true),
            user = parseUser(body),
        )
    } catch (_: Exception) {
        null
    }

    private fun parseUser(body: String): AuthUser? {
        return try {
            val user = JSONObject(body).optJSONObject("user") ?: return null
            val email = user.optString("email").trim()
            if (email.isEmpty()) return null
            AuthUser(
                id = user.optString("id"),
                email = email,
                name = user.optString("name").ifBlank { email },
                role = user.optString("role").ifBlank { "member" },
            )
        } catch (_: Exception) {
            null
        }
    }

    private companion object {
        const val SESSION_ERROR_MESSAGE = "Could not verify your saved session. Try signing in again."
    }
}

fun parseSessionCookie(setCookieHeaders: List<String>): String? {
    setCookieHeaders.forEach { header ->
        header.split(';').forEach { part ->
            val nameAndValue = part.trim().split('=', limit = 2)
            if (nameAndValue.size != 2) return@forEach
            if (nameAndValue[0].trim() != AuthConfig.SESSION_COOKIE_NAME) return@forEach
            val value = nameAndValue[1].trim().trim('"')
            if (value.isEmpty()) return@forEach
            return value
        }
    }
    return null
}
