package com.nalar.mobile.network

import com.nalar.mobile.auth.AuthConfig
import com.nalar.mobile.auth.AuthHttpResponse
import com.nalar.mobile.auth.AuthTransport
import com.nalar.mobile.http.HttpHeader
import com.nalar.mobile.http.HttpsHttpExchange
import java.io.IOException

/**
 * Wraps the auth transport so every call the app makes shows up in the network
 * inspector. The captured request mirrors what [HttpsHttpExchange] actually put
 * on the wire, including the `Accept` default, so a replayed record is honest.
 */
class RecordingAuthTransport(
    private val delegate: AuthTransport,
    private val store: NetworkLogStore = NetworkLogStore.default,
    private val baseUrl: String = AuthConfig.BASE_URL,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val nanoTime: () -> Long = System::nanoTime,
) : AuthTransport {

    override fun post(
        path: String,
        body: String,
        headers: Map<String, String>,
    ): AuthHttpResponse = capture("POST", path, body, headers) {
        delegate.post(path = path, body = body, headers = headers)
    }

    override fun get(
        path: String,
        headers: Map<String, String>,
    ): AuthHttpResponse = capture("GET", path, null, headers) {
        delegate.get(path = path, headers = headers)
    }

    override fun put(
        path: String,
        body: String,
        headers: Map<String, String>,
    ): AuthHttpResponse = capture("PUT", path, body, headers) {
        delegate.put(path = path, body = body, headers = headers)
    }

    private fun capture(
        method: String,
        path: String,
        body: String?,
        headers: Map<String, String>,
        call: () -> AuthHttpResponse,
    ): AuthHttpResponse {
        val requestHeaders = listOf(
            HttpHeader(HttpsHttpExchange.ACCEPT_HEADER, HttpsHttpExchange.DEFAULT_ACCEPT),
        ) + headers.map { (name, value) -> HttpHeader(name, value) }
        val url = baseUrl.trimEnd('/') + path
        val startedAt = nowMillis()
        val startedNanos = nanoTime()

        val clippedRequest = clipBody(body)

        return try {
            val response = call()
            val duration = elapsedMillisSince(startedNanos)
            val clippedResponse = clipBody(response.body)
            store.record { id ->
                NetworkLogEntry(
                    id = id,
                    label = labelForExchange(method, path),
                    method = method,
                    url = url,
                    requestHeaders = requestHeaders,
                    requestBody = clippedRequest.first,
                    requestBodyBytes = body?.length ?: 0,
                    requestBodyTruncated = clippedRequest.second,
                    statusCode = response.statusCode,
                    responseHeaders = response.headers,
                    responseBody = clippedResponse.first,
                    responseBodyBytes = response.body?.length ?: 0,
                    responseBodyTruncated = clippedResponse.second,
                    startedAtEpochMillis = startedAt,
                    durationMillis = duration,
                )
            }
            response
        } catch (error: Exception) {
            store.record { id ->
                NetworkLogEntry(
                    id = id,
                    label = labelForExchange(method, path),
                    method = method,
                    url = url,
                    requestHeaders = requestHeaders,
                    requestBody = clippedRequest.first,
                    requestBodyBytes = body?.length ?: 0,
                    requestBodyTruncated = clippedRequest.second,
                    statusCode = null,
                    responseHeaders = emptyList(),
                    responseBody = null,
                    responseBodyBytes = 0,
                    errorMessage = error.describeForInspector(),
                    startedAtEpochMillis = startedAt,
                    durationMillis = elapsedMillisSince(startedNanos),
                )
            }
            throw error
        }
    }

    private fun elapsedMillisSince(startedNanos: Long): Long =
        ((nanoTime() - startedNanos) / 1_000_000L).coerceAtLeast(0L)
}

internal fun Throwable.describeForInspector(): String {
    val detail = message?.takeIf { text -> text.isNotBlank() } ?: this::class.java.simpleName
    return if (this is IOException) detail else "$detail (${this::class.java.simpleName})"
}
