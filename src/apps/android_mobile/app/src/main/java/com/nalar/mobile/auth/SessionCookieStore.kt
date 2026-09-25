package com.nalar.mobile.auth

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.KeyStoreException
import java.security.ProviderException
import java.security.UnrecoverableKeyException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

interface SessionStore {
    fun read(): String?
    fun save(cookieValue: String)
    fun clear()
}

class SessionCookieStore(context: Context) : SessionStore {
    private val preferences by lazy {
        context.applicationContext.getSharedPreferences(
            PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
    }

    override fun read(): String? {
        return try {
            val encoded = preferences.getString(PAYLOAD_KEY, null) ?: return null
            decrypt(encoded).takeIf { it.isNotBlank() }
        } catch (error: Exception) {
            if (
                error is IOException ||
                error is KeyStoreException ||
                error is ProviderException ||
                error is UnrecoverableKeyException
            ) {
                throw error
            }
            runCatching { clear() }
            null
        }
    }

    override fun save(cookieValue: String) {
        require(cookieValue.isNotBlank()) { "Session cookie must not be empty" }

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val encrypted = cipher.doFinal(cookieValue.toByteArray(StandardCharsets.UTF_8))
        val payload = listOf(
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
            Base64.encodeToString(encrypted, Base64.NO_WRAP),
        ).joinToString(PAYLOAD_SEPARATOR)

        check(preferences.edit().putString(PAYLOAD_KEY, payload).commit()) {
            "Could not persist the encrypted session cookie"
        }
    }

    override fun clear() {
        check(preferences.edit().remove(PAYLOAD_KEY).commit()) {
            "Could not clear the encrypted session cookie"
        }
    }

    private fun decrypt(payload: String): String {
        val parts = payload.split(PAYLOAD_SEPARATOR, limit = 2)
        require(parts.size == 2) { "Malformed session cookie payload" }

        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val encrypted = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(encrypted), StandardCharsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
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
        const val PREFERENCES_NAME = "nalar_auth"
        const val PAYLOAD_KEY = "session_cookie"
        const val KEY_ALIAS = "nalar_session_key_v1"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val PAYLOAD_SEPARATOR = ":"
    }
}
