package com.nalar.mobile.auth

import org.json.JSONObject
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import javax.net.ssl.HttpsURLConnection

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
}

class HttpsAuthTransport(baseUrl: String) : AuthTransport {
    private val normalizedBaseUrl = baseUrl.trimEnd('/')

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

    private fun request(
        method: String,
        path: String,
        body: String?,
        headers: Map<String, String>,
    ): AuthHttpResponse {
        val connection = (URL("$normalizedBaseUrl$path").openConnection() as? HttpsURLConnection)
            ?: throw IOException("Nalar API did not return an HTTPS connection")

        return try {
            connection.requestMethod = method
            connection.connectTimeout = NETWORK_TIMEOUT_MILLIS
            connection.readTimeout = NETWORK_TIMEOUT_MILLIS
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("Accept", "application/json")
            headers.forEach(connection::setRequestProperty)

            if (body != null) {
                val bodyBytes = body.toByteArray(StandardCharsets.UTF_8)
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(bodyBytes.size)
                connection.outputStream.use { it.write(bodyBytes) }
            }

            val statusCode = connection.responseCode
            val responseStream = if (statusCode in 200..299) {
                connection.inputStream
            } else {
                connection.errorStream
            }
            AuthHttpResponse(
                statusCode = statusCode,
                body = responseStream.readText(),
                setCookieHeaders = connection.cookieHeaders(),
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun HttpsURLConnection.cookieHeaders(): List<String> =
        getHeaderFields()
            .entries
            .filter { it.key?.equals("Set-Cookie", ignoreCase = true) == true }
            .flatMap { it.value.orEmpty() }

    private fun InputStream?.readText(): String =
        this?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }.orEmpty()

    private companion object {
        const val NETWORK_TIMEOUT_MILLIS = 15_000
    }
}

class AuthClient(
    private val sessionStore: SessionStore,
    baseUrl: String = AuthConfig.BASE_URL,
    httpTransport: AuthTransport? = null,
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
            AuthResult.Authenticated(user)
        } catch (_: Exception) {
            runCatching { sessionStore.clear() }
            AuthResult.Unavailable("Signed in, but this device could not save the session.")
        }
    }

    fun restoreSession(): AuthResult {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return AuthResult.Unavailable(SESSION_ERROR_MESSAGE)
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
            return clearSessionOrUnavailable()
        }
        if (response.statusCode !in 200..299) {
            return AuthResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        val me = parseMe(response.body)
            ?: return AuthResult.Unavailable(SESSION_ERROR_MESSAGE)
        if (!me.authEnabled) {
            return AuthResult.AuthDisabled
        }
        if (me.authenticated && me.user != null) {
            return AuthResult.Authenticated(me.user)
        }
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
