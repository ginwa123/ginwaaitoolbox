package com.pabrik.mobile.network

import com.pabrik.mobile.http.HttpHeader
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkRedactionTest {
    @Test
    fun credentialHeadersAreMaskedAndOrdinaryOnesAreNot() {
        val headers = listOf(
            HttpHeader("Content-Type", "application/json"),
            HttpHeader("Authorization", "Bearer token-123"),
            HttpHeader("Cookie", "pabrik_session=abc"),
            HttpHeader("Set-Cookie", "pabrik_session=abc; HttpOnly"),
            HttpHeader("X-Api-Key", "key-9"),
        )

        val redacted = redactHeaders(headers)

        assertEquals("application/json", redacted[0].value)
        assertEquals(RedactedPlaceholder, redacted[1].value)
        assertEquals(RedactedPlaceholder, redacted[2].value)
        assertEquals(RedactedPlaceholder, redacted[3].value)
        assertEquals(RedactedPlaceholder, redacted[4].value)
    }

    @Test
    fun headerNameMatchingIgnoresCaseAndSurroundingSpace() {
        assertTrue(isSensitiveHeaderName("cookie"))
        assertTrue(isSensitiveHeaderName("  Set-Cookie  "))
        assertFalse(isSensitiveHeaderName("Content-Type"))
        assertFalse(isSensitiveHeaderName("X-Request-Id"))
    }

    @Test
    fun jsonPasswordIsMaskedButTheRestOfTheBodySurvives() {
        val body = """{"email":"person@example.com","password":"hunter2","role":"admin"}"""

        val redacted = redactBody(body)

        assertFalse(redacted!!.contains("hunter2"))
        assertTrue(redacted.contains("person@example.com"))
        assertTrue(redacted.contains("admin"))
        assertTrue(redacted.contains("\"password\""))
    }

    @Test
    fun nestedVendorTokenNamesAreMasked() {
        val body = """{"user":{"id":"u1"},"stripe_signature":"sig-1","idempotency_key":"k-1"}"""

        val redacted = redactBody(body)

        assertFalse(redacted!!.contains("sig-1"))
        assertTrue(redacted.contains(RedactedPlaceholder))
        assertTrue(redacted.contains("idempotency_key"))
    }

    @Test
    fun formEncodedCredentialsAreMasked() {
        val body = "grant_type=refresh_token&refresh_token=rt-42&scope=read"

        val redacted = redactBody(body)

        assertFalse(redacted!!.contains("rt-42"))
        assertTrue(redacted.contains("grant_type=refresh_token"))
        assertTrue(redacted.contains("scope=read"))
    }

    @Test
    fun nonStringSecretValuesAreMasked() {
        val redacted = redactBody("""{"pin":1234,"attempts":2}""")

        assertFalse(redacted!!.contains("1234"))
        assertTrue(redacted.contains("attempts"))
    }

    @Test
    fun queryStringSecretsAreMaskedButRoutingParamsAreNot() {
        val url = "https://agent.ginwa.site/api/auth/callback?token=secret-token&workspace_id=w-1"

        val redacted = redactUrl(url)

        assertFalse(redacted.contains("secret-token"))
        assertTrue(redacted.contains("workspace_id=w-1"))
    }

    @Test
    fun urlWithoutQueryIsUnchanged() {
        val url = "https://agent.ginwa.site/api/auth/me"

        assertEquals(url, redactUrl(url))
    }

    @Test
    fun redactedBodiesStayParseableSoTheInspectorKeepsWorking() {
        val body = """{"user":{"id":"u1","email":"a@b.c","name":"A"},"authenticated":true}"""

        val redacted = redactBody(body)

        assertTrue(redacted!!.contains("\"user\""))
        assertTrue(redacted.contains("\"authenticated\""))
    }

    @Test
    fun nullAndEmptyBodiesPassThrough() {
        assertEquals(null, redactBody(null))
        assertEquals("", redactBody(""))
    }

    @Test
    fun suffixMatchingCatchesVendorSpellingsWithoutSwallowingRoutingKeys() {
        assertTrue(isSensitiveFieldName("imap_password"))
        assertTrue(isSensitiveFieldName("service-account-token"))
        assertTrue(isSensitiveFieldName("aws_secret_access_key"))
        assertFalse(isSensitiveFieldName("idempotency_key"))
        assertFalse(isSensitiveFieldName("partition_key"))
        assertFalse(isSensitiveFieldName("email"))
    }

    @Test
    fun containsSecretFieldDetectsJsonAndFormPayloads() {
        assertTrue(containsSecretField("""{"password":"x"}"""))
        assertTrue(containsSecretField("access_token=abc"))
        assertFalse(containsSecretField("""{"email":"a@b.c","page":2}"""))
        assertFalse(containsSecretField(null))
    }
}
