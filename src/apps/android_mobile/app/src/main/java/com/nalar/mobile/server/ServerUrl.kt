package com.nalar.mobile.server

import com.nalar.mobile.BuildConfig
import java.net.URI
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The result of being told which server to talk to.
 *
 * One type for both jobs it does, because they are the same job: [normalizeBaseUrl]
 * reports whether a typed address is usable, and [ServerUrl.update] reports
 * whether it was adopted. A rejected address is the *same* sentence in both
 * cases — the one the reader sees under the field is the one the transport
 * would have refused with, so a value that survives the dialog is a value that
 * can open a socket.
 */
sealed interface ServerChange {
    /** [baseUrl] is normalized, and is what the app will use from now on. */
    data class Applied(val baseUrl: String) : ServerChange

    /** [reason] is a sentence to show a person, not a code to log. */
    data class Rejected(val reason: String) : ServerChange
}

/**
 * The hosts a build may open a **plain HTTP** socket to, and the only ones.
 *
 * The debug allowance is not "HTTP is fine locally" — it is the three addresses
 * `src/debug/res/xml/network_security_config.xml` grants cleartext to, and it
 * is a set rather than a flag so this cannot drift into a general one. The
 * platform refuses cleartext to every other host, and it refuses it at connect
 * time with an error the reader cannot act on, so a store that accepted
 * `http://server.lan` would let someone fill in a setting that can never work.
 * `ServerUrlContractTest` holds the two lists together.
 *
 * Empty in release. That is the invariant the whole file exists to protect, and
 * it is why this is a `val` computed from `BuildConfig` rather than something
 * the user can talk the app into.
 */
internal val LOOPBACK_HOSTS: Set<String> = setOf("10.0.2.2", "localhost", "127.0.0.1")

/** "Does this already say what it is talking to?" — RFC 3986's scheme grammar. */
private val SCHEME_PATTERN = Regex("^[a-zA-Z][a-zA-Z0-9+.\\-]*://")

internal val CLEAR_TEXT_HOSTS: Set<String> =
    if (BuildConfig.ALLOW_INSECURE_HTTP) LOOPBACK_HOSTS else emptySet()

/**
 * `10.0.2.2` is the emulator's own alias for the host's loopback interface,
 * which is the address a `127.0.0.1`-bound server is reachable on from inside
 * the emulator. The other two are the same machine seen the way a JVM test on
 * the host sees it.
 */
/**
 * Turns something typed into the server field into the URL the client will use.
 *
 * A scheme is optional, because a self-hoster typing `nalar.example.com` has
 * done nothing wrong and should not have to know that "https://" is implied —
 * and the safe reading of an absent scheme is the secure one. Everything past
 * that is a rule, and each rule is checked in an order where the message names
 * the thing that is actually wrong, because a person typing a hostname needs to
 * be told which of the seven things they did they did.
 *
 * The result is a URL safe to concatenate a `/api/...` path onto: no trailing
 * slash, no query, no fragment, lowercase scheme and host, and any path
 * preserved for the self-hosters who put nalar behind a reverse proxy at
 * `https://example.com/nalar`.
 */
internal fun normalizeBaseUrl(raw: String): ServerChange {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) {
        return ServerChange.Rejected("Enter your server address.")
    }

    // A bare `example.com` is the common case; only reach for a parser once
    // there is a scheme to parse.
    val candidate = if (SCHEME_PATTERN.containsMatchIn(trimmed)) trimmed else "https://$trimmed"

    val uri = try {
        URI(candidate)
    } catch (_: Exception) {
        return ServerChange.Rejected("That is not a server address.")
    }

    val scheme = uri.scheme?.lowercase()
    if (scheme != "http" && scheme != "https") {
        // These two strings are the transport's own rule, quoted here so the
        // sentence under the field and the exception out of `HttpsAuthTransport`
        // are the same one. `InsecureHttpExchangeTest` asserts on it.
        return ServerChange.Rejected(
            if (BuildConfig.ALLOW_INSECURE_HTTP) {
                "Nalar API must use HTTP or HTTPS."
            } else {
                "Nalar API must use HTTPS."
            },
        )
    }

    // `java.net.URI` refuses a host it cannot parse (an underscore, a stray
    // space) by reporting a null host rather than by failing, so this reads as
    // the generic "no domain" rather than as a parse failure above it.
    val host = uri.host?.lowercase()
        ?: return ServerChange.Rejected("Include the domain, for example nalar.example.com.")

    // Credentials in a URL are a phishing shape: the reader sees the host and
    // not the `user:pass@` in front of it, and a server the app is pointed at
    // by a string someone else typed must never carry one.
    if (!uri.userInfo.isNullOrEmpty()) {
        return ServerChange.Rejected("Remove the username and password from the address.")
    }
    if (!uri.query.isNullOrEmpty() || !uri.fragment.isNullOrEmpty()) {
        return ServerChange.Rejected("A server address cannot have a ?query or #fragment.")
    }

    if (scheme == "http" && host !in CLEAR_TEXT_HOSTS) {
        return ServerChange.Rejected(
            if (CLEAR_TEXT_HOSTS.isEmpty()) {
                "This build connects over HTTPS only."
            } else {
                "Plain HTTP is only allowed for a server on this device's host (${CLEAR_TEXT_HOSTS.joinToString()})."
            },
        )
    }

    val port = if (uri.port != -1) ":${uri.port}" else ""
    val path = (uri.rawPath ?: "").trimEnd('/')
    return ServerChange.Applied("$scheme://$host$port$path")
}

/**
 * The transport's half of the rule: a host, or an exception naming why not.
 *
 * Same [normalizeBaseUrl], same sentences, run at a different moment. The store
 * asks it when a person presses Save so they can be told; a transport asks it
 * on the request path so that a value which reached a socket some other way —
 * a value restored from an old install, a debug build's `-PnalarBaseUrl` — is
 * still refused rather than obeyed.
 *
 * Throwing is correct here precisely because it is a *programming* error when a
 * caller gets here, and every caller is inside a `try` that already turns an
 * `Exception` into "could not reach the server". It is not a path a value a
 * person typed can take: [ServerUrl.update] will not have adopted one.
 */
internal fun requireUsableBaseUrl(baseUrl: String): String = when (
    val parsed = normalizeBaseUrl(baseUrl)
) {
    is ServerChange.Applied -> parsed.baseUrl
    is ServerChange.Rejected -> throw IllegalArgumentException(parsed.reason)
}

/**
 * The server this process talks to.
 *
 * A holder rather than a constructor argument, because the app resolves all four
 * of its ViewModels during the first composition of `MainActivity` and each one
 * builds its transport there. A base URL that had to be handed to them would
 * either be captured for the life of the process or need the whole graph torn
 * down; a holder the transports *read per request* is picked up by the next
 * call, which is what makes "point the app at another server" a setting rather
 * than a restart.
 *
 * Until [install] runs, this reports [BuildConfig.API_BASE_URL] — the build's
 * own default, which is also the answer before anyone has typed anything.
 */
object ServerUrl {
    private val _current = MutableStateFlow(BuildConfig.API_BASE_URL)

    /** The base URL as a flow, for UI that has to redraw when it changes. */
    val current: StateFlow<String> = _current.asStateFlow()

    /**
     * The base URL every transport reads right now.
     *
     * This is what `AuthConfig.BASE_URL` returns, and the reason a `val` there
     * can be live at all.
     */
    val value: String get() = _current.value

    private var store: BaseUrlStore? = null

    /**
     * Binds this holder to storage, adopting anything already saved.
     *
     * Idempotent, and safe to call from a test to rebind it — the same trade the
     * web app's `__resetSseBus()` makes, for the same reason: a module-level
     * singleton is the right production shape and a test hazard.
     *
     * A stored value that no longer normalizes is **dropped, not obeyed**. The
     * build it was written under may have been more permissive than this one
     * (the reverse of a downgrade is an upgrade, and an old debug-only host must
     * not survive into a release), the file may be corrupt, or the user may
     * have typed it on a device that could reach a host this one cannot. Falling
     * back to the build default is the only outcome that is correct in all
     * three.
     */
    fun install(store: BaseUrlStore) {
        this.store = store
        val stored = store.read() ?: return run {
            _current.value = BuildConfig.API_BASE_URL
        }
        when (val parsed = normalizeBaseUrl(stored)) {
            is ServerChange.Applied -> _current.value = parsed.baseUrl
            is ServerChange.Rejected -> {
                store.clear()
                _current.value = BuildConfig.API_BASE_URL
            }
        }
    }

    /**
     * Adopts [raw] and persists it.
     *
     * A rejection changes nothing — not the in-memory value and not the file —
     * so a value that cannot be used cannot survive a failed attempt at using
     * it either.
     */
    fun update(raw: String): ServerChange {
        val parsed = normalizeBaseUrl(raw)
        if (parsed is ServerChange.Rejected) return parsed

        val baseUrl = (parsed as ServerChange.Applied).baseUrl
        if (store?.write(baseUrl) == false) {
            return ServerChange.Rejected("This device could not save the server address.")
        }
        _current.value = baseUrl
        return parsed
    }

    /**
     * Back to the host this build shipped with, and forgets the saved one.
     *
     * The escape hatch for someone who pointed the app at a typo and cannot
     * work out how to type their own domain again.
     */
    fun resetToBuildDefault(): ServerChange {
        store?.clear()
        _current.value = BuildConfig.API_BASE_URL
        return ServerChange.Applied(_current.value)
    }

    /** Unbinds storage and returns to the build default. Tests only. */
    internal fun reset() {
        store = null
        _current.value = BuildConfig.API_BASE_URL
    }
}
