package com.pabrik.mobile.chat

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import android.util.Log
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Turns what the photo picker handed back into a [ChatAttachment].
 *
 * Takes the picker's **string** rather than a `Uri`, and that is a boundary
 * rather than a convenience. A `content://` URI is a *grant*: it is meaningful
 * only to whatever is about to read the bytes, and it is meaningless after
 * that. Everything above this line — the ViewModel's attach/remove
 * bookkeeping, the budget, the composer's strip — wants "this image" and not
 * "this capability", and a `Uri` in their signatures would put `android.net`
 * in the middle of rules that are really about a 10 MB cap.
 *
 * An interface rather than a constructor argument so the send path can be
 * driven on the JVM with a fake, and so the rule that a *refused* attachment
 * leaves the turn alone is testable without a `Bitmap` anywhere in sight.
 */
fun interface PickedImageReader {
    /**
     * Reads, downscales and encodes one picked image.
     *
     * Returns the attachment, or `null` when the image could not be read at
     * all — a revoked picker grant, a file the provider has since deleted, an
     * unsupported format. Those are the reader's problem to report, not the
     * composer's.
     */
    suspend fun read(source: String): ChatAttachment?
}

/**
 * The real reader: decode → downscale → JPEG → base64.
 *
 * Every step here exists because of the 10 MB cap, and each one is the
 * cheapest way to get under it:
 *
 * 1. **Two-pass decode with `inSampleSize`.** A 12 MP bitmap is 48 MB in RAM,
 *    which on a low-end phone is an `OutOfMemoryError` rather than a large
 *    image. `inSampleSize` makes the decoder skip rows it would only throw
 *    away, so the phone never holds the full-size bitmap at all.
 * 2. **Scale to [ChatAttachments.MAX_EDGE_PX].** 1280px on the long edge is
 *    what a model reads; the rest is pixels nobody looks at.
 * 3. **Re-encode as JPEG at [ChatAttachments.JPEG_QUALITY], walking down if
 *    still over budget.** A PNG screenshot of a text editor is a few hundred KB
 *    as PNG and about the same as JPEG, but a photo is 4 MB as PNG and 200 KB
 *    as JPEG. Re-encoding is what makes the difference.
 *
 * It runs on [ioDispatcher] because a decode plus a re-encode of a 12 MP photo
 * is hundreds of milliseconds of CPU — a main-thread `BitmapFactory` call in a
 * tap handler is a dropped frame the reader feels as the composer stalling.
 */
class BitmapPickedImageReader(
    private val contentResolver: ContentResolver,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : PickedImageReader {

    override suspend fun read(source: String): ChatAttachment? = withContext(ioDispatcher) {
        runCatching {
            // The one place a `content://` string becomes a `Uri`. Everything
            // below works in `Bitmap`s, and the grant is only needed here.
            val uri = Uri.parse(source)
            val bounds = readBounds(uri) ?: return@runCatching null
            // Degenerate dimensions mean a file that is not an image the
            // platform decoder can read; treating that as "no attachment" is
            // better than handing a 0×0 bitmap to the scaler.
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@runCatching null

            val sample = sampleSizeFor(bounds.outWidth, bounds.outHeight)
            val decoded = decodeScaled(uri, sample) ?: return@runCatching null
            // Hoisted out of the `try` so the `finally` beside it can see it: a
            // `val` declared inside the block is not in scope outside it.
            var fitted: Bitmap? = null
            try {
                val scaled = fitToMaxEdge(decoded)
                fitted = scaled
                val bytes = encodeWithinBudget(scaled) ?: return@runCatching null
                ChatAttachment(
                    // Derived from the source, so re-picking the same
                    // photo is a recognisable duplicate rather than a second
                    // copy of the same bytes.
                    id = source.hashCode().toString(),
                    mimeType = ChatAttachments.STORED_MIME,
                    byteCount = bytes.size,
                    dataUrl = ChatAttachments.dataUrl(ChatAttachments.STORED_MIME, bytes),
                )
            } finally {
                // Both the sampled decode and the scale are ours; the gallery
                // copy this came from is not, and a scaled copy holds the same
                // pixels twice.
                fitted?.takeIf { it !== decoded }?.recycle()
                decoded.recycle()
            }
        }.onFailure { error ->
            Log.w(TAG, "Could not read the picked image", error)
        }.getOrNull()
    }

    /** Width and height without decoding pixels — the pass that makes sampling possible. */
    private fun readBounds(uri: Uri): BitmapFactory.Options? {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
        return options
    }

    /**
     * The power of two that puts the decoded bitmap just above the cap.
     *
     * A power of two because that is the only value the decoder can honour —
     * asking for 3 gives you 1 — and deliberately *not* rounded to land under
     * it: `inSampleSize` is a skip count, so the result is always larger than
     * the true fraction, and the exact scale is finished by [fitToMaxEdge].
     */
    private fun sampleSizeFor(width: Int, height: Int): Int {
        var sample = 1
        var longest = maxOf(width, height)
        while (longest / 2 >= ChatAttachments.MAX_EDGE_PX) {
            longest /= 2
            sample *= 2
        }
        return sample
    }

    private fun decodeScaled(uri: Uri, sample: Int): Bitmap? {
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            // The image is about to be re-encoded as JPEG and shrunk further,
            // so keeping the alpha channel would cost 4 bytes per pixel to
            // discard a second later.
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, options)
        }
    }

    /** The exact scale to [ChatAttachments.MAX_EDGE_PX] on the long edge. */
    private fun fitToMaxEdge(source: Bitmap): Bitmap {
        val longest = maxOf(source.width, source.height)
        if (longest <= ChatAttachments.MAX_EDGE_PX) return source
        val ratio = ChatAttachments.MAX_EDGE_PX.toFloat() / longest
        val width = (source.width * ratio).toInt().coerceAtLeast(1)
        val height = (source.height * ratio).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(source, width, height, true)
    }

    /**
     * Encode, and step the quality down if the turn's budget says no.
     *
     * The single highest setting that fits is not always enough — one
     * attachment of a 12 MP photo can still be over budget at any quality —
     * so the fallback is the cap itself: shrink until it fits, and refuse only
     * when even 30% of a 1280px JPEG will not, which in practice means the
     * reader attached something that is not really a photograph.
     */
    private fun encodeWithinBudget(bitmap: Bitmap): ByteArray? {
        var quality = ChatAttachments.JPEG_QUALITY
        while (true) {
            val bytes = compress(bitmap, quality)
            // Half the cap on its own, so a second and third image have room.
            if (bytes.size <= ChatAttachments.MAX_TOTAL_BYTES / 2) return bytes
            if (quality <= MIN_QUALITY) return null
            quality = (quality / 2).coerceAtLeast(MIN_QUALITY)
        }
    }

    private fun compress(bitmap: Bitmap, quality: Int): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
        return out.toByteArray()
    }

    private companion object {
        const val TAG = "ChatAttachments"
        const val MIN_QUALITY = 30
    }
}

/**
 * A thumbnail for an attachment, or `null` when the bytes are not an image.
 *
 * Decoded from the payload the turn will actually send rather than from a
 * second copy of the file: the reader's check that they picked the right
 * screenshot is a check of the bytes that are about to go, and a thumbnail of
 * a different copy is a thumbnail that can lie.
 *
 * On the Android side of the line rather than in `ChatAttachment.kt`, so the
 * policy there stays testable without a `Bitmap` anywhere near it.
 */
fun ChatAttachment.thumbnail(): ImageBitmap? = runCatching {
    val bytes = Base64.decode(base64, Base64.DEFAULT)
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
}.getOrNull()
