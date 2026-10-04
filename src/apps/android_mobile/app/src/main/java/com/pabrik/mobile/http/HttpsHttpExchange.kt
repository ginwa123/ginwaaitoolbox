package com.pabrik.mobile.http

import com.pabrik.mobile.BuildConfig
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
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
        val connection = openFor(request.url)

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
    private fun HttpURLConnection.readResponseHeaders(): List<HttpHeader> =
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

        /**
         * Opens [url], enforcing HTTPS unless this build has opted out.
         *
         * Typed as [HttpURLConnection] rather than [HttpsURLConnection] because a
         * debug build can be pointed at a plain-HTTP pabrik on the emulator's
         * host alias, and because every operation this package performs —
         * method, headers, timeouts, streaming, the error stream — lives on the
         * base type anyway. The narrower type bought nothing and made the one
         * layer that actually opens sockets the one layer no local-server test
         * could reach.
         *
         * The HTTPS rule is relocated, not dropped: a non-HTTPS URL is still
         * rejected outright unless `ALLOW_INSECURE_HTTP` is on, and that flag is
         * false in every release build. Kept in one place so the binary
         * exchange, which downloads files, cannot drift from it.
         */
        internal fun openFor(url: String): HttpURLConnection {
            val opened = URL(url).openConnection()
            if (opened is HttpsURLConnection) return opened
            if (!BuildConfig.ALLOW_INSECURE_HTTP) {
                throw IOException("Request did not open an HTTPS connection")
            }
            return opened as? HttpURLConnection
                ?: throw IOException("Request did not open an HTTP connection")
        }
    }
}
