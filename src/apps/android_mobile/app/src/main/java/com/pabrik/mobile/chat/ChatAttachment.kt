package com.pabrik.mobile.chat

import java.util.Base64

/**
 * One image the reader has attached to the turn they are composing.
 *
 * The bytes are already encoded, because that is the only shape the backend
 * accepts. `image_urls` is a pipe-joined list of
 * `data:image/<mime>;base64,<payload>` strings — the web builds the same thing
 * client-side with `FileReader.readAsDataURL` and there is no upload endpoint
 * to post to, so a mobile client that wants images has to make the same
 * choice. See `src/http_handlers/image_urls_validation.zig` for the server
 * half of the contract.
 *
 * Held as a data URL rather than a `content://` URI on purpose: a content URI
 * is a grant the picker hands to *this* process, and the same turn is still
 * being composed when the reader rotates the phone or the process is
 * recreated. The bytes are the only thing that survives both.
 */
data class ChatAttachment(
    val id: String,
    val mimeType: String,
    /** Size of the *encoded payload*, which is what the cap is measured in. */
    val byteCount: Int,
    val dataUrl: String,
) {
    /**
     * The base64 payload on its own, for a thumbnail that wants pixels rather
     * than a data URL.
     *
     * Everything the server sends back is already a data URL, so this is the
     * one place the two representations meet: a reader who attaches an image
     * and scrolls up to the turn they just sent must see the same bytes twice,
     * decoded the same way.
     */
    val base64: String get() = dataUrl.substringAfter(";base64,", dataUrl)
}

/**
 * The rules a picked image has to satisfy, and the arithmetic behind them.
 *
 * Deliberately free of Android: the caps, the mime mapping and the encoding
 * are the part that has to be right, and none of them need a `Bitmap` to be
 * tested — so they are all in a plain JVM test rather than behind a device.
 * The decode is the only piece that needs one, and it is
 * [PickedImageReader]'s problem.
 */
object ChatAttachments {
    /**
     * The server's own cap, on the *joined* `image_urls` string.
     *
     * `MAX_IMAGE_URLS_BYTES` in `image_urls_validation.zig`. Enforced here
     * rather than left to a 413 because the server's rejection names no file:
     * a reader who attached four photos has to be told which of them was
     * refused and why, before they press send.
     */
    const val MAX_TOTAL_BYTES: Int = 10 * 1024 * 1024

    /**
     * Longest edge, in pixels, of a downscaled attachment.
     *
     * A modern phone photo is 4000px on the long edge and 3-8 MB, and base64
     * inflates by a third on top of that, so an untouched photo blows the cap
     * on its own. 1280px is the size a model actually reads an image at — the
     * tokens spent on a screenshot are decided by how much text is legible in
     * it, not by how many pixels the phone happened to capture — and it
     * downscales to a few hundred kilobytes, which is what leaves room for the
     * second and third image.
     */
    const val MAX_EDGE_PX: Int = 1280

    /**
     * JPEG quality for the re-encode.
     *
     * 82 is the point where text in a screenshot is still crisp and the file
     * has roughly halved twice over. It is a floor, not a target: the loop in
     * [PickedImageReader] walks it down for an image that is still over budget.
     */
    const val JPEG_QUALITY: Int = 82

    /**
     * How many images one turn may carry.
     *
     * Four is what the composer shows without horizontal scrolling eating the
     * text field, and it is far past the point where a model stops reading
     * image three and starts pricing it. A hard cap is a control: without one
     * the only way to add a fifth image is to remove one of the first four.
     */
    const val MAX_COUNT: Int = 4

    /** The data URL for encoded bytes. The shape `image_urls` is defined as. */
    fun dataUrl(mimeType: String, bytes: ByteArray): String =
        "data:$mimeType;base64," + Base64.getEncoder().encodeToString(bytes)

    /** The joined `image_urls` value, in one place so the separator lives once. */
    fun dataUrls(attachments: List<ChatAttachment>): List<String> =
        attachments.map { it.dataUrl }

    /** What [MAX_TOTAL_BYTES] is measured against. */
    fun totalBytes(attachments: List<ChatAttachment>): Int =
        attachments.sumOf { it.byteCount }

    /** True when one more image of [byteCount] bytes still fits on this turn. */
    fun fitsBudget(attachments: List<ChatAttachment>, byteCount: Int): Boolean =
        attachments.size < MAX_COUNT && totalBytes(attachments) + byteCount <= MAX_TOTAL_BYTES

    /**
     * Why an attachment was refused, or `null` when it was not.
     *
     * Two distinct answers on purpose. "Too many" and "too big" are different
     * problems with different answers — remove a picture, or send fewer of
     * them — and one message for both would tell the reader to do something
     * that does not help.
     */
    fun rejection(attachments: List<ChatAttachment>, byteCount: Int): String? = when {
        attachments.size >= MAX_COUNT ->
            "Up to $MAX_COUNT images per message. Remove one to attach another."

        totalBytes(attachments) + byteCount > MAX_TOTAL_BYTES ->
            "Images are limited to ${MAX_TOTAL_BYTES / (1024 * 1024)} MB per message. " +
                "Remove one to make room."

        else -> null
    }

    /**
     * The payload length [dataUrl] will produce for [bytes] — the number the
     * cap is actually checked against.
     *
     * Base64 emits four characters for every three bytes, rounded up, so this
     * is not `bytes.size` and must not be approximated by it: a photo that is
     * 200 KB raw is 267 KB on the wire, and a cap checked on the raw size
     * accepts a payload the server then rejects.
     */
    fun encodedLength(bytes: Int): Int = 4 * ((bytes + 2) / 3)

    /**
     * A content type to store the bytes as.
     *
     * Everything becomes JPEG. The server validates the *prefix*, so a PNG is
     * allowed — but a screenshot with a flat background compresses better as
     * PNG and would come back re-encoded as JPEG anyway on the next pass, so
     * the honest thing is to normalise once, here, and let the reader see the
     * same result whichever file they picked. The alternative, keeping PNG for
     * screenshots, buys a slightly better screenshot and a much worse photo.
     */
    const val STORED_MIME: String = "image/jpeg"
}
