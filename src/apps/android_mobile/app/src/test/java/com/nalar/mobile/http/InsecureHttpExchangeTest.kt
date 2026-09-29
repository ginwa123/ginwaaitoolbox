package com.nalar.mobile.http

import com.nalar.mobile.BuildConfig
import com.nalar.mobile.auth.HttpsAuthTransport
import java.io.BufferedReader
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import javax.net.ssl.HttpsURLConnection
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The debug build's one deliberate hole, driven against a real socket.
 *
 * A shipped nalar client is HTTPS-only, and that is enforced in two places: the
 * `require` in `HttpsAuthTransport`'s constructor, and the `as? HttpsURLConnection`
 * casts in the two exchanges. Both were unconditional, which meant an emulator
 * could not reach a nalar running on the machine hosting it — and a test that
 * cannot reach a server cannot test what the server sent.
 *
 * So the checks were widened behind `BuildConfig.ALLOW_INSECURE_HTTP`. Widening
 * a security check is the kind of change that is easy to make and easy to
 * over-make, so each half is pinned here separately, and the halves fail
 * differently:
 *
 *  * the constructor guard is asserted by *constructing* — it used to throw from
 *    a ViewModel factory, so its failure mode was a crash on launch rather than
 *    a failed request;
 *  * the exchange is driven against a throwaway `ServerSocket` on 127.0.0.1,
 *    because the JSON and binary paths are separate classes and only one of them
 *    was previously reachable from a local server.
 *
 * The socket is a real one on a real loopback port, the same shape
 * `HttpChatEventStreamSocketTest` uses — a stub `openConnection` would prove the
 * cast changed and nothing about bytes.
 */
class InsecureHttpExchangeTest {

    private lateinit var server: ServerSocket
    private val accepted = CopyOnWriteArrayList<Socket>()

    /**
     * The request lines the stub was actually handed.
     *
     * The stub answers 200 to anything, so a doubled slash in the path — the
     * whole point of the normalisation-order test — is invisible in the status
     * code. The bytes the client wrote are the only place it shows up.
     */
    private val requestLines = CopyOnWriteArrayList<String>()

    @Before
    fun startServer() {
        server = ServerSocket(0)
        Thread {
            while (!server.isClosed) {
                val socket = try {
                    server.accept()
                } catch (_: Exception) {
                    return@Thread
                }
                accepted += socket
                Thread {
                    try {
                        // Read the request head so the client's write completes.
                        // Never read past the blank line: there is no body here.
                        val reader: BufferedReader = socket.getInputStream().bufferedReader()
                        var line = reader.readLine()
                        if (line != null) requestLines += line
                        while (line != null && line.isNotEmpty()) line = reader.readLine()
                        val body = """{"ok":true}"""
                        val head = buildString {
                            append("HTTP/1.1 200 OK\r\n")
                            append("Content-Type: application/json\r\n")
                            append("Content-Length: ${body.toByteArray().size}\r\n")
                            append("Connection: close\r\n\r\n")
                        }
                        socket.getOutputStream().write((head + body).toByteArray())
                        socket.getOutputStream().flush()
                        // Close, so the body is bounded twice over: the client
                        // can stop at Content-Length and EOF is unambiguous. A
                        // server that leaves the socket open makes a
                        // Content-Length bug read as a hung suite.
                        socket.close()
                    } catch (_: Exception) {
                        // The client hung up; nothing to do.
                    }
                }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }.start()
    }

    @After
    fun stopServer() {
        runCatching { accepted.forEach { it.close() } }
        runCatching { server.close() }
    }

    private fun baseUrl() = "http://127.0.0.1:${server.localPort}"

    // ─── the guard, on the request path ────────────────────────────────────
    //
    // These three moved from "constructing it is the assertion" to "the request
    // is the assertion". The host is a person-typed setting now, resolved per
    // request, so the scheme rule has to be enforced where the value is used:
    // an `IllegalArgumentException` out of a constructor would crash the app on
    // launch for a value the person set, with no way to reach the screen that
    // would fix it.

    /** Fails the first request to [url], and returns what refused it. */
    private fun refusalFor(url: String): IllegalArgumentException =
        assertThrows(
            "$url must be refused",
            IllegalArgumentException::class.java,
        ) {
            HttpsAuthTransport { url }.get(path = "/api/auth/me", headers = emptyMap())
        }

    @Test
    fun `the debug build accepts a plain-http base url`() {
        assertTrue(
            "this test only means something where the seam is armed",
            BuildConfig.ALLOW_INSECURE_HTTP,
        )

        // 127.0.0.1 is one of the three hosts the debug
        // `network_security_config.xml` grants cleartext to, so the request goes
        // out over plain HTTP and the scheme rule stays out of it.
        val response = HttpsAuthTransport { baseUrl() }
            .get(path = "/api/auth/me", headers = emptyMap())

        // A round trip, not a construction: the scheme rule now lives on the
        // request path, so the only proof that it let this through is a server
        // answering.
        assertEquals(200, response.statusCode)
    }

    @Test
    fun `a scheme that is neither http nor https is still refused`() {
        val thrown = refusalFor("ftp://127.0.0.1:${server.localPort}")

        assertTrue(
            "the failure has to name the rule it broke, not just 'invalid': ${thrown.message}",
            thrown.message.orEmpty().contains("HTTP or HTTPS"),
        )
    }

    @Test
    fun `a trailing slash does not change the decision`() {
        // The normalisation happens before the guard, so this pins the order:
        // a guard that ran first would accept `http://x/` and then build
        // `http://x//api/...` URLs. The stub answers 200 to anything, so the
        // request line is where a doubled slash would actually show up.
        HttpsAuthTransport { "${baseUrl()}/" }
            .get(path = "/api/auth/me", headers = emptyMap())

        assertTrue(
            "a doubled slash reached the server: $requestLines",
            requestLines.any { it == "GET /api/auth/me HTTP/1.1" },
        )
    }

    // ─── the two exchanges ─────────────────────────────────────────────────

    @Test
    fun `a plain-http request round-trips through the json exchange`() {
        val response = HttpsHttpExchange().execute(
            HttpRequestSpec(method = "GET", url = "${baseUrl()}/api/auth/me"),
        )

        assertEquals(200, response.statusCode)
        assertTrue("body was ${response.body}", response.body.orEmpty().contains("\"ok\":true"))
        assertEquals(1, accepted.size)
    }

    @Test
    fun `a plain-http request round-trips through the binary exchange`() {
        // The file path is a separate class with its own copy of the decision,
        // and it is the one that downloads bytes rather than JSON — so it gets
        // its own round trip rather than trusting the JSON path to imply it.
        val response = HttpsBinaryExchange().execute(
            HttpRequestSpec(method = "GET", url = "${baseUrl()}/api/files/download?path=/a.txt"),
        )

        assertEquals(200, response.statusCode)
        assertTrue(
            "content type was '${response.contentType}'",
            response.contentType.startsWith("application/json"),
        )
        assertTrue(String(response.body), String(response.body).contains("\"ok\":true"))
    }

    // ─── the part that must not have changed ───────────────────────────────

    @Test
    fun `an https url still opens a tls connection`() {
        // The relaxation must not have replaced the TLS path with a plain one.
        // `openConnection` does not connect, so this needs no network.
        val opened = HttpsHttpExchange.openFor("https://agent.ginwa.site/api/auth/me")

        assertTrue(
            "https must still yield a TLS connection, got ${opened::class.java.name}",
            opened is HttpsURLConnection,
        )
    }
}
