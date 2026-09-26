package com.nalar.mobile.storage

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * AES-GCM under a key held by the Android Keystore, so the key material never
 * exists in the app's process address space.
 *
 * It lives here, in `storage`, rather than next to either of its two callers —
 * the session cookie and the Room cache — because the second copy of this
 * crypto *is* a second copy to keep in sync, and a change to the payload format
 * has to land in both or it silently invalidates whatever one was missed.
 * Each caller still gets its own key alias, so a suspected credential leak and
 * a suspected cache leak stay separate investigations that can be rotated
 * separately.
 *
 * ### Why the key is memoized
 *
 * [EncryptedPrefs] re-reads the key from the Keystore on every call. That is
 * fine for a preferences file, where a value is a few hundred bytes and a read
 * happens once per screen. A sidebar read opens 30 chat titles, so a Keystore
 * round trip per row would put ~30 daemon hops on the main thread of the first
 * frame — more than the single blob decrypt it replaced. The key is fetched
 * once per process; the [Cipher] is still built per operation, because
 * `Cipher` is not safe to share.
 *
 * ### Fail-silent
 *
 * Both operations return null rather than throwing. A key invalidated by a
 * lock-screen change, a restore onto a new device, a truncated payload, or a
 * hardware keystore that refuses to open must degrade the caller to a miss and
 * a skipped write. A broken store is never the reason the app fails. GCM's
 * authentication tag is what makes "wrong key" a failure rather than a silently
 * wrong answer.
 */
interface SealingCipher {
    /** Null when the value could not be sealed; the caller should not store it. */
    fun seal(plainText: String): String?

    /** Null when the value is not one this cipher wrote. */
    fun open(sealed: String): String?
}

class KeystoreSealingCipher(private val keyAlias: String) : SealingCipher {

    @Volatile
    private var key: SecretKey? = null

    override fun seal(plainText: String): String? = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(plainText.toByteArray(StandardCharsets.UTF_8))
        listOf(
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
            Base64.encodeToString(encrypted, Base64.NO_WRAP),
        ).joinToString(PAYLOAD_SEPARATOR)
    } catch (_: Exception) {
        null
    }

    override fun open(sealed: String): String? = try {
        val parts = sealed.split(PAYLOAD_SEPARATOR, limit = 2)
        if (parts.size != SEALED_PARTS) {
            null
        } else {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                key(),
                GCMParameterSpec(GCM_TAG_LENGTH_BITS, Base64.decode(parts[0], Base64.NO_WRAP)),
            )
            String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), StandardCharsets.UTF_8)
        }
    } catch (_: Exception) {
        null
    }

    private fun key(): SecretKey = key ?: synchronized(this) {
        key ?: loadOrCreateKey().also { key = it }
    }

    private fun loadOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = keyStore.getKey(keyAlias, null) as? SecretKey
        if (existing != null) return existing

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val PAYLOAD_SEPARATOR = ":"
        const val SEALED_PARTS = 2
        const val GCM_TAG_LENGTH_BITS = 128
    }
}
