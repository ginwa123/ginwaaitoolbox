package com.pabrik.mobile.testing

import com.pabrik.mobile.storage.SealingCipher
import java.util.Base64

/**
 * A cipher that is obviously not encryption, so a test can tell "this value
 * went through the cipher" from "this value was passed through" without
 * claiming to have tested AES-GCM.
 *
 * The real one is `com.pabrik.mobile.storage.KeystoreSealingCipher`, and it
 * cannot run on the JVM: AndroidKeyStore has no shadow that will produce a real
 * key. These tests therefore assert the property that actually matters for the
 * schema — the column is not stored verbatim — and leave the crypto to the
 * JDK's.
 *
 * It also decodes strictly. A value it did not write raises, and `open` turns
 * that into null, which is exactly the "unreadable row" path the caches have to
 * survive when a Keystore alias is retired.
 */
object Base64CacheCipher : SealingCipher {
    override fun seal(plainText: String): String =
        Base64.getEncoder().encodeToString(plainText.toByteArray(Charsets.UTF_8))

    override fun open(sealed: String): String? = try {
        String(Base64.getDecoder().decode(sealed), Charsets.UTF_8)
    } catch (_: IllegalArgumentException) {
        null
    }
}
