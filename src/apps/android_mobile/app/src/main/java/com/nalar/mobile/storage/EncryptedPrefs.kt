package com.nalar.mobile.storage

import android.content.Context
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
 * SharedPreferences with every value sealed under AES-GCM through the Android
 * Keystore.
 *
 * Extracted because there are now two consumers — the session cookie and the
 * sidebar cache — and a second copy of this crypto is a second copy to keep in
 * sync. Each store gets its OWN key alias: a suspected credential leak and a
 * suspected cache leak are different investigations, and rotating one must not
 * invalidate the other.
 *
 * Fail-silent throughout. A broken store degrades to a cache miss or a failed
 * read, never to an exception on the caller's critical path.
 */
class EncryptedPrefs(
    context: Context,
    preferencesName: String,
    private val keyAlias: String,
) {
    private val preferences by lazy {
        context.applicationContext.getSharedPreferences(
            preferencesName,
            Context.MODE_PRIVATE,
        )
    }

    fun get(key: String): String? = try {
        val payload = preferences.getString(key, null) ?: return null
        decrypt(payload).takeIf { it.isNotBlank() }
    } catch (_: Exception) {
        // An entry written under a different Keystore key (a restore to a new
        // device, or a key invalidated by lock-screen changes) is unreadable.
        // Drop it and report a miss rather than wedging the caller.
        runCatching { preferences.edit().remove(key).commit() }
        null
    }

    fun put(key: String, value: String) {
        try {
            preferences.edit().putString(key, encrypt(value)).commit()
        } catch (_: Exception) {
            // Quota or an unavailable Keystore. The live fetch still works; only
            // the next launch's instant paint is lost.
        }
    }

    fun remove(key: String) {
        runCatching { preferences.edit().remove(key).commit() }
    }

    /** Used on sign-out: a pending `apply` must not outlive the purge. */
    fun clear() {
        runCatching { preferences.edit().clear().commit() }
    }

    private fun encrypt(plainText: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val encrypted = cipher.doFinal(plainText.toByteArray(StandardCharsets.UTF_8))
        return listOf(
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
            Base64.encodeToString(encrypted, Base64.NO_WRAP),
        ).joinToString(PAYLOAD_SEPARATOR)
    }

    private fun decrypt(payload: String): String {
        val parts = payload.split(PAYLOAD_SEPARATOR, limit = 2)
        require(parts.size == 2) { "Malformed encrypted payload" }

        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val encrypted = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(encrypted), StandardCharsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
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

    companion object {
        const val PREFERENCES_NAME = "nalar_auth"
        const val PAYLOAD_KEY = "session_cookie"
        const val KEY_ALIAS = "nalar_session_key_v1"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val PAYLOAD_SEPARATOR = ":"
    }
}
