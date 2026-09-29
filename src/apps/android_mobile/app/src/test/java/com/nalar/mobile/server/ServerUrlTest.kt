package com.nalar.mobile.server

import com.nalar.mobile.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rule a person typing a hostname is held to.
 *
 * Every case here is a string somebody would genuinely type, and every message
 * is asserted to *name the thing that is wrong* rather than to exist. A settings
 * field that says "Invalid URL" for a missing scheme, an underscore and a
 * forgotten `https://` alike is a field people give up on, and a self-hoster
 * configuring their own deployment is exactly the person who will hit the edge
 * cases.
 */
class ServerUrlTest {

    private fun applied(raw: String): String {
        val change = normalizeBaseUrl(raw)
        assertTrue(
            "`$raw` should have been accepted, got $change",
            change is ServerChange.Applied,
        )
        return (change as ServerChange.Applied).baseUrl
    }

    private fun rejected(raw: String): String {
        val change = normalizeBaseUrl(raw)
        assertTrue(
            "`$raw` should have been refused, got $change",
            change is ServerChange.Rejected,
        )
        return (change as ServerChange.Rejected).reason
    }

    // ─── the shapes that must work ─────────────────────────────────────────

    @Test
    fun `a bare hostname gets the secure scheme`() {
        // The common case by far. Someone who has just deployed nalar and been
        // handed `nalar.example.com` has done nothing wrong.
        assertEquals("https://nalar.example.com", applied("nalar.example.com"))
    }

    @Test
    fun `surrounding whitespace is not a person typing a host`() {
        assertEquals("https://nalar.example.com", applied("  nalar.example.com  "))
    }

    @Test
    fun `a port is kept, because a self-hoster runs on 8080`() {
        assertEquals("https://nalar.example.com:8080", applied("nalar.example.com:8080"))
        assertEquals(
            "https://nalar.example.com:8443",
            applied("https://nalar.example.com:8443"),
        )
    }

    @Test
    fun `a path prefix is kept, because a reverse proxy puts nalar under one`() {
        assertEquals("https://example.com/nalar", applied("https://example.com/nalar/"))
    }

    @Test
    fun `scheme and host are lowercased so two spellings are one server`() {
        // `https://Nalar.Example.COM` and `https://nalar.example.com` are the
        // same host, and a store that treated them as two would refuse to switch
        // back to the one already in use.
        assertEquals("https://nalar.example.com", applied("HTTPS://Nalar.Example.COM"))
    }

    @Test
    fun `a trailing slash is dropped so a path can be appended`() {
        // The join in every transport is `"$baseUrl$path"`. A trailing slash
        // here is a doubled slash in the URL, which 404s.
        assertEquals("https://nalar.example.com", applied("https://nalar.example.com/"))
        assertEquals("https://nalar.example.com", applied("https://nalar.example.com///"))
    }

    // ─── the shapes that must not ──────────────────────────────────────────

    @Test
    fun `an empty field says so instead of guessing`() {
        assertEquals("Enter your server address.", rejected(""))
        assertEquals("Enter your server address.", rejected("   "))
    }

    @Test
    fun `a scheme this client cannot open names the two it can`() {
        // The same sentence the transport throws with, so the field and the
        // socket never disagree about the rule. `InsecureHttpExchangeTest`
        // asserts the transport's copy contains "HTTP or HTTPS".
        for (raw in listOf("ftp://nalar.example.com", "file:///etc/hosts", "ws://x.example")) {
            assertTrue(
                "`$raw` should name the rule: ${rejected(raw)}",
                rejected(raw).contains("HTTP or HTTPS"),
            )
        }
    }

    @Test
    fun `credentials in the address are refused`() {
        // The reader sees the host in the row above the field and not the
        // `user:pass@` in front of it. This is the shape a link that spoofs a
        // server has, and a value typed by someone else must never be able to
        // carry one.
        assertTrue(
            rejected("https://user:pass@nalar.example.com")
                .contains("username and password"),
        )
    }

    @Test
    fun `a query or fragment is refused, naming which part`() {
        // Both would silently disappear when a path is appended, and the first
        // is the shape of a link that points somewhere other than it looks.
        assertTrue(rejected("https://nalar.example.com?next=/evil").contains("?query"))
        assertTrue(rejected("https://nalar.example.com#x").contains("?query"))
    }

    @Test
    fun `a host the parser cannot read is refused without a stack trace`() {
        // Two different failures, two different sentences. A space is illegal in
        // a URI at all, so `java.net.URI` throws and this is the "not a server
        // address" case; an underscore in a host makes the parser give up on
        // just the authority and report a *null host*, which is the "include the
        // domain" case. Without both, one of the two rules is untested and
        // someone typing `my_server.example` gets told to include a domain they
        // already included.
        assertTrue(rejected("https://not a host").contains("not a server address"))
        assertTrue(rejected("https://exa_mple.com").contains("domain"))
    }

    // ─── the cleartext policy ──────────────────────────────────────────────

    @Test
    fun `cleartext is refused for every host except the ones the debug config permits`() {
        // This is the invariant the whole file exists to protect, and it is
        // asserted in BOTH variants on purpose. The platform permits cleartext
        // to exactly the three loopback addresses in
        // `src/debug/res/xml/network_security_config.xml` and refuses it
        // everywhere else at connect time — so a store that took
        // `http://server.lan` would accept a setting that can never work and
        // report the failure as "could not reach the server".
        if (!BuildConfig.ALLOW_INSECURE_HTTP) {
            for (host in listOf("10.0.2.2", "localhost", "127.0.0.1")) {
                assertTrue(
                    "release must refuse cleartext even to $host",
                    rejected("http://$host:8080").contains("HTTPS only"),
                )
            }
            return
        }

        for (host in listOf("10.0.2.2", "localhost", "127.0.0.1")) {
            assertEquals("http://$host:8080", applied("http://$host:8080"))
        }
        assertTrue(
            "cleartext to a host the platform would refuse must not be accepted",
            rejected("http://nalar.example.com").contains("Plain HTTP"),
        )
    }

    @Test
    fun `the permitted cleartext hosts are the ones the debug config grants`() {
        // The set, not a boolean, and the set is the same three addresses. A
        // fourth host slipping in is how a debug allowance becomes a general
        // one; `ServerUrlContractTest` pins the same list against the XML.
        val expected = if (BuildConfig.ALLOW_INSECURE_HTTP) LOOPBACK_HOSTS else emptySet()
        assertEquals(expected, CLEAR_TEXT_HOSTS)
    }

    // ─── the transport's copy of the same rule ─────────────────────────────

    @Test
    fun `the transport guard returns the normalized url or throws with the sentence`() {
        assertEquals(
            "https://nalar.example.com",
            requireUsableBaseUrl("nalar.example.com/"),
        )

        val thrown = runCatching { requireUsableBaseUrl("ftp://nalar.example.com") }
            .exceptionOrNull()
        assertTrue(
            "the guard must throw rather than return a bad host: $thrown",
            thrown is IllegalArgumentException,
        )
        assertTrue(thrown!!.message.orEmpty().contains("HTTP or HTTPS"))
    }
}
