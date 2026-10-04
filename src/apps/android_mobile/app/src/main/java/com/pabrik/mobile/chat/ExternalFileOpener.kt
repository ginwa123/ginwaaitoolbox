package com.pabrik.mobile.chat

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File

/**
 * Hands a presented file to whatever app on the phone can actually view it.
 *
 * The download endpoint is cookie-authenticated, so `ACTION_VIEW` on the URL
 * itself is useless: Chrome has no `pabrik_session` cookie and answers 401. The
 * bytes are therefore fetched with the reader's own session (the same
 * [FileClient] the inline preview uses), written to the app's cache, and the
 * *local* copy is what gets opened. The file lives under `cacheDir`, which the
 * system may reclaim on its own, so nothing here is a promise of permanence.
 *
 * `FileProvider` is what makes that legal: a `file://` URI has thrown
 * `FileUriExposedException` on every API level since 24, and a content URI is
 * the only thing a viewer app will accept. The grant is per-intent and read-only.
 */
class ExternalFileOpener(
    private val context: Context,
    private val fileClient: FileClient,
) {
    /**
     * Open [path] in a viewer app.
     *
     * Returns `null` on success, or a sentence worth putting on the card. It
     * blocks on the network, so call it off the main thread.
     */
    fun open(
        sessionId: String,
        path: String,
        displayName: String,
        mime: String,
    ): String? {
        val bytes = when (val result = fileClient.fetch(sessionId, path)) {
            is FileFetchResult.Loaded -> result.bytes
            is FileFetchResult.SignedOut -> return "Sign in again to open this file."
            is FileFetchResult.Rejected -> return result.message
            is FileFetchResult.Unavailable -> return result.message
        }

        val cached = try {
            writeToCache(bytes, displayName)
        } catch (_: Exception) {
            return "There was no room on the phone to save this file."
        }

        val viewerMime = PresentFiles.viewerMime(path = cached.name, mime = mime)
        val uri = try {
            FileProvider.getUriForFile(context, authority(context), cached)
        } catch (_: Exception) {
            return "This file could not be shared with another app."
        }

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, viewerMime)
            // A viewer with no path back would strand the reader in another app
            // with no way to know what they opened.
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        return try {
            context.startActivity(intent)
            null
        } catch (_: ActivityNotFoundException) {
            "No app on this phone can open a ${viewerMime.substringBefore('/')} file."
        } catch (_: Exception) {
            "This file could not be opened."
        }
    }

    /**
     * The FileProvider authority, derived rather than hardcoded so a
     * `applicationId` suffix in a build flavour cannot produce a manifest
     * that disagrees with the code.
     */
    private fun authority(context: Context): String = "${context.packageName}.$PROVIDER_SUFFIX"

    private fun writeToCache(bytes: ByteArray, displayName: String): File {
        val directory = File(context.cacheDir, CACHE_DIR)
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw IllegalStateException("Could not create the preview cache directory")
        }
        // A presented `label` is whatever the model wrote, so it cannot go into
        // a path unsanitised: `../../databases/pabrik` is a legal label string
        // and would write outside the cache.
        val safeName = sanitize(displayName)
        val target = File(directory, safeName)
        target.outputStream().use { it.write(bytes) }
        return target
    }

    // Not private: `sanitize` is the one pure, load-bearing piece of this
    // class and its test has to reach it without a Context.
    internal companion object {
        private const val CACHE_DIR = "presented"
        private const val PROVIDER_SUFFIX = "fileprovider"
        private const val MAX_NAME_CHARS = 80
        private const val ALLOWED_PUNCTUATION = "._-"

        /**
         * Reduce a presented label to something safe to join onto a cache path.
         *
         * In the companion rather than on the instance because it is the one
         * piece of this class that is pure, and a `Context`-bound
         * instrumented test is the wrong tool for a string function — see
         * `ExternalFileOpenerTest`, which pins the traversal case on the JVM.
         *
         * Every character outside `[A-Za-z0-9._-]` becomes `_`, so no separator
         * survives and the result can only ever be one path segment.
         */
        internal fun sanitize(name: String): String {
            val cleaned = name.trim().ifEmpty { "file" }.map { character ->
                if (character.isLetterOrDigit() || character in ALLOWED_PUNCTUATION) character else '_'
            }.joinToString("").trim('_', '.')
            if (cleaned.isEmpty()) return "file"

            // Cap the *stem*, not the whole name. A plain `take(80)` on a long
            // label cuts the extension off the end, which is the one part of
            // the name that has to survive — a viewer app that gets a URI with
            // no extension shows the file with the wrong icon, and a file
            // manager that sorts by type files it under "no extension".
            val dot = cleaned.lastIndexOf('.')
            if (dot <= 0) return cleaned.take(MAX_NAME_CHARS)
            val stem = cleaned.substring(0, dot)
            val extension = cleaned.substring(dot)
            if (extension.length >= MAX_NAME_CHARS) return "file"
            return stem.take(MAX_NAME_CHARS - extension.length) + extension
        }
    }
}
