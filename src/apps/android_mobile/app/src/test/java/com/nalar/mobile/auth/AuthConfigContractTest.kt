package com.nalar.mobile.auth

import com.nalar.mobile.BuildConfig
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The one invariant the base-URL seam must not break: **release never relaxes**.
 *
 * The debug variant can be pointed at a plain-HTTP nalar on the machine hosting
 * the emulator, which is what makes the functional UI suite possible. That is a
 * deliberate hole, and a hole is only safe if something refuses to let it widen.
 * Three separate things have to stay true, and they fail independently:
 *
 *  1. `ALLOW_INSECURE_HTTP` is `false` in the release build type.
 *  2. No release source set ships a cleartext allowance, so the platform refusal
 *     in the main manifest cannot be lifted by a file nobody looks at.
 *  3. The debug allowance itself stays scoped to the three loopback addresses
 *     it was written for, rather than drifting to `base-config`.
 *
 * (1) is asserted against the build script and (2)/(3) against the files
 * themselves, because a value in a build script cannot be read off a test —
 * the unit tests only ever run under the debug variant, so `BuildConfig` here
 * can prove the debug side and nothing about release. That is the same split
 * `ToolCardFrameTest` uses for a frame that only exists in a draw lambda, and
 * the same reason: Compose can report a rendered pixel, not a policy.
 */
class AuthConfigContractTest {

    @Test
    fun `BASE_URL comes from the build, not from a literal in this package`() {
        // The seam, not the value. `AuthConfig.BASE_URL` was a `const val` with
        // the production host inline; if that ever comes back while the
        // BuildConfig field stays, the debug variant would silently stop
        // honouring `-PnalarBaseUrl` and every instrumented test would talk to
        // production — which would look like a network failure, not a wiring
        // failure.
        assertEquals(BuildConfig.API_BASE_URL, AuthConfig.BASE_URL)
        assertTrue(
            "AuthConfig.kt still hardcodes a host: ${authConfigSource().take(200)}",
            !authConfigSource().contains("agent.ginwa.site"),
        )
    }

    @Test
    fun `the base url is an absolute http url`() {
        val url = AuthConfig.BASE_URL
        assertTrue("blank base url", url.isNotBlank())
        assertTrue(
            "base url must be absolute and http(s), got: $url",
            url.startsWith("http://") || url.startsWith("https://"),
        )
    }

    @Test
    fun `this variant is debug and has the insecure allowance on`() {
        // `testDebugUnitTest` is the only unit-test task this project runs, so
        // asserting the variant pins the meaning of the next assertion: the
        // allowance being on here is the debug build's business, and
        // `releaseKeepsTheAllowanceOff` is what stops it being everyone's.
        assertEquals("debug", BuildConfig.BUILD_TYPE)
        assertTrue(
            "debug must allow the local-server seam the functional UI suite needs",
            BuildConfig.ALLOW_INSECURE_HTTP,
        )
    }

    @Test
    fun `release keeps the allowance off`() {
        val release = block(buildScript(), "release")

        assertTrue(
            "the release build type must declare ALLOW_INSECURE_HTTP = false:\n$release",
            release.contains("ALLOW_INSECURE_HTTP\", \"false\""),
        )
        // The *interpolation*, not the identifier: the release block's own
        // comment names the debug value in prose to explain why it is absent,
        // and a check on the bare word would fail on its own explanation.
        assertTrue(
            "release must wire the production url",
            release.contains("\$productionBaseUrl"),
        )
        assertTrue(
            "release must not wire the debug base url",
            !release.contains("\$debugBaseUrl"),
        )
    }

    @Test
    fun `only the debug build type turns the allowance on`() {
        val script = buildScript()
        val occurrences = Regex(Regex.escape("ALLOW_INSECURE_HTTP\", \"true\"")).findAll(script).count()

        assertTrue(
            "exactly one build type may enable plain HTTP; found $occurrences",
            occurrences == 1,
        )
        assertTrue(
            "the allowance is enabled outside the debug block",
            block(script, "debug").contains("ALLOW_INSECURE_HTTP\", \"true\""),
        )
    }

    @Test
    fun `no release source set ships a cleartext allowance`() {
        // A network security config in `src/release` would lift the manifest's
        // cleartext refusal in the one build that must never have it lifted.
        for (relative in RELEASE_SOURCES) {
            assertTrue(
                "$relative must not exist — release stays HTTPS-only",
                resolve(relative) == null,
            )
        }
    }

    @Test
    fun `the debug cleartext allowance is scoped to the loopback hosts`() {
        val xml = readOrFail(
            "src/debug/res/xml/network_security_config.xml",
            "app/src/debug/res/xml/network_security_config.xml",
        )

        assertTrue(
            "cleartext must stay refused by default:\n$xml",
            xml.contains("""<base-config cleartextTrafficPermitted="false""""),
        )
        assertTrue(
            "a domain-config must be the only thing that permits cleartext:\n$xml",
            xml.contains("""<domain-config cleartextTrafficPermitted="true">"""),
        )
        for (host in LOOPBACK_HOSTS) {
            assertTrue("$host must be permitted for the emulator to reach the host", xml.contains(">$host<"))
        }

        // The count is the guard. A fourth domain slipping in is how a debug
        // allowance quietly becomes a general one.
        val domains = Regex("<domain[^>]*>([^<]+)</domain>").findAll(xml).map { it.groupValues[1] }.toList()
        assertEquals(LOOPBACK_HOSTS, domains)
    }

    // ─── source access ─────────────────────────────────────────────────────

    private fun buildScript(): String = readOrFail("build.gradle.kts", "app/build.gradle.kts")

    private fun authConfigSource(): String = readOrFail(
        "src/main/java/com/nalar/mobile/auth/AuthConfig.kt",
        "app/src/main/java/com/nalar/mobile/auth/AuthConfig.kt",
    )

    private fun readOrFail(vararg relativePaths: String): String =
        relativePaths.map(::File).firstOrNull(File::isFile)?.readText()
            ?: error("none of ${relativePaths.toList()} reachable from ${File(".").absolutePath}")

    /** The file, or null when it genuinely does not exist where it would matter. */
    private fun resolve(relative: String): File? = File(relative).takeIf(File::isFile)

    /**
     * The text inside `name { ... }`, by brace depth.
     *
     * A regex cannot do this — the blocks nest — and the build script is small
     * and brace-balanced, so counting depth from the opening brace is both
     * simpler and exact. Comments in this file contain no braces, which is what
     * makes the naive scan safe here.
     */
    private fun block(source: String, name: String): String {
        val needle = "$name {"
        assertEquals(
            "`$needle` should appear exactly once in the build script",
            1,
            Regex(Regex.escape(needle)).findAll(source).count(),
        )
        val open = source.indexOf(needle) + needle.length - 1
        var depth = 0
        for (i in open until source.length) {
            when (source[i]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return source.substring(open + 1, i)
                }
            }
        }
        error("unbalanced braces after `$needle`")
    }

    private companion object {
        val LOOPBACK_HOSTS = listOf("10.0.2.2", "localhost", "127.0.0.1")

        /** Paths that must not exist, tried against both plausible working dirs. */
        val RELEASE_SOURCES = listOf(
            "src/release/AndroidManifest.xml",
            "src/release/res/xml/network_security_config.xml",
        )
    }
}
