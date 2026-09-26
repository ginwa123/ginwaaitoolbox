package com.nalar.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The one part of [ExternalFileOpener] that is a pure function, and the part
 * that matters: a presented file's `label` is a string the model chose, and it
 * is about to become a filename under the app's cache directory.
 */
class ExternalFileOpenerTest {

    /**
     * The traversal case. A label of `../../databases/nalar` is a perfectly
     * legal string for a model to emit, and unsanitised it would write outside
     * the cache directory — over the app's own database — from a card the
     * reader only tapped "Open" on.
     */
    @Test
    fun `a traversal label cannot escape the cache directory`() {
        val cleaned = ExternalFileOpener.sanitize("../../databases/nalar")
        assertFalse(cleaned.contains(".."))
        assertFalse(cleaned.contains('/'))
        assertFalse(cleaned.contains('\\'))
    }

    @Test
    fun `an absolute path label is flattened to its last segment`() {
        val cleaned = ExternalFileOpener.sanitize("/etc/shadow")
        assertFalse(cleaned.contains('/'))
        assertTrue(cleaned.endsWith("shadow"))
    }

    /**
     * The extension survives, because a file with none confuses a few file
     * managers even when the mime is what actually routes the intent.
     */
    @Test
    fun `the extension is kept`() {
        assertTrue(ExternalFileOpener.sanitize("report.final.pdf").endsWith(".pdf"))
        assertTrue(ExternalFileOpener.sanitize("v1+2 notes.md").endsWith(".md"))
    }

    @Test
    fun `ordinary characters pass through untouched`() {
        assertEquals("report-2026_final.pdf", ExternalFileOpener.sanitize("report-2026_final.pdf"))
    }

    /** Spaces are legal in a filename and common in a presented one. */
    @Test
    fun `a space becomes an underscore rather than a separator`() {
        assertEquals("my_notes.md", ExternalFileOpener.sanitize("my notes.md"))
    }

    /** An all-punctuation label must not collapse to a path of nothing. */
    @Test
    fun `a label with nothing usable in it still produces a name`() {
        assertEquals("file", ExternalFileOpener.sanitize("///"))
        assertEquals("file", ExternalFileOpener.sanitize("   "))
        assertEquals("file", ExternalFileOpener.sanitize(""))
    }

    @Test
    fun `a long name is capped`() {
        val cleaned = ExternalFileOpener.sanitize("a".repeat(500) + ".pdf")
        assertTrue("got ${cleaned.length} chars", cleaned.length <= 80)
        assertTrue(cleaned.endsWith(".pdf"))
    }
}
