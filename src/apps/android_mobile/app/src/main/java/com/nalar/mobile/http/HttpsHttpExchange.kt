package com.nalar.mobile.http

import java.io.IOException
import java.io.InputStream
import java.net.URL
import java.nio.charset.StandardCharsets
import javax.net.ssl.HttpsURLConnection

/**
 * The app's single HTTPS call site. Auth, the network inspector, and replay all go
 * through here, so what the inspector shows is exactly what the auth client sent —
 * a second implementation would drift and make the captured record a lie.
 */
class HttpsHttpExchange(
    private val connectTimeoutMillis: Int = DEFAULT_TIMEOUT_MILLIS,
    private val readTimeoutMillis: Int = DEFAULT_TIMEOUT_MILLIS,
) : HttpExchange {
    override fun execute(request: HttpRequestSpec): HttpResponseSpec {
        val connection = (URL(request.url).openConnection() as? HttpsURLConnection)
            ?: throw IOException("Request did not open an HTTPS connection")

        try {
            connection.requestMethod = request.method
            connection.connectTimeout = connectTimeoutMillis
            connection.readTimeout = readTimeoutMillis
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty(ACCEPT_HEADER, DEFAULT_ACCEPT)
            request.headers.forEach { header ->
                connection.setRequestProperty(header.name, header.value)
            }

            if (request.body != null) {
                val bodyBytes = request.body.toByteArray(StandardCharsets.UTF_8)
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

            return HttpResponseSpec(
                statusCode = statusCode,
                headers = connection.readResponseHeaders(),
                body = responseStream.readUtf8OrEmpty(),
            )
        } finally {
            connection.disconnect()
        }
    }

    /** `getHeaderFields()` keys the status line under a null name; drop it so only real headers survive. */
    private fun HttpsURLConnection.readResponseHeaders(): List<HttpHeader> =
        headerFields.entries.flatMap { (name, values) ->
            if (name == null) {
                emptyList()
            } else {
                values.orEmpty().map { value -> HttpHeader(name, value) }
            }
        }

    private fun InputStream?.readUtf8OrEmpty(): String =
        this?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() } ?: ""

    companion object {
        const val DEFAULT_TIMEOUT_MILLIS = 15_000
        const val ACCEPT_HEADER = "Accept"
        const val DEFAULT_ACCEPT = "application/json"
    }
}
