package com.nalar.mobile.auth

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.nalar.mobile.network.RecordingAuthTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class SessionPhase {
    Restoring,
    NeedsLogin,
    NeedsRetry,
    Authenticated,
}

data class AuthUiState(
    val phase: SessionPhase = SessionPhase.Restoring,
    val isAuthenticating: Boolean = false,
    /**
     * A sign-out is in flight. Kept apart from [isAuthenticating] so the
     * sidebar can say "Logging out…" and refuse a second press, and so a slow
     * sign-out is never mistaken for a slow sign-in.
     */
    val isLoggingOut: Boolean = false,
    val errorMessage: String? = null,
    /**
     * The signed-in account, or null when auth is off / no one is signed in.
     * The sidebar cache is namespaced by this: `logout()` leaves the
     * cached rows on disk, so without it the next account would inherit them.
     */
    val userId: String? = null,
    /**
     * False when the server runs without `--auth`. That is a genuinely different
     * state from "signed in with a blank id", and only this one can say whether
     * there is a session worth ending — which is what decides if the sidebar
     * offers "Log out" at all.
     */
    val isAuthEnabled: Boolean = false,
    /** Shown beside the sign-out action so the user knows who they are ending. */
    val userEmail: String? = null,
)

/**
 * The one [AuthResult] -> [AuthUiState] rule.
 *
 * Restore, sign-in and sign-out each produce results from the same sealed type,
 * and they used to be mapped in three places with three slightly different
 * `when`s. A divergence there is invisible in review and expensive in the field:
 * a sign-out that kept the email would paint the next account's name. One
 * function, called by all three, cannot drift.
 *
 * Top level and free of Android so the mapping is a plain JVM test rather than
 * an instrumented one.
 */
internal fun authUiStateFor(result: AuthResult): AuthUiState = when (result) {
    is AuthResult.Authenticated -> AuthUiState(
        phase = SessionPhase.Authenticated,
        userId = result.user.id.takeIf { id -> id.isNotBlank() },
        isAuthEnabled = true,
        userEmail = result.user.email,
    )

    // Authenticated, but nobody to be: the server is running open. No account
    // to attribute a cache to and nothing for a sign-out to end.
    AuthResult.AuthDisabled -> AuthUiState(phase = SessionPhase.Authenticated)

    AuthResult.NoSession -> AuthUiState(phase = SessionPhase.NeedsLogin)

    is AuthResult.Rejected -> AuthUiState(
        phase = SessionPhase.NeedsLogin,
        errorMessage = result.message,
    )

    is AuthResult.Unavailable -> AuthUiState(
        phase = SessionPhase.NeedsRetry,
        errorMessage = result.message,
    )
}

/**
 * The sign-out path's own mapping: the session is being ended, so every outcome
 * lands on the login screen. [AuthResult.Unavailable] here is "the device could
 * not drop its own cookie" — still a failure to sign out, and still something the
 * user has to be told rather than left to discover on the next launch.
 */
internal fun signedOutUiStateFor(result: AuthResult): AuthUiState = when (result) {
    is AuthResult.Unavailable -> AuthUiState(
        phase = SessionPhase.NeedsLogin,
        errorMessage = result.message,
    )

    else -> AuthUiState(phase = SessionPhase.NeedsLogin)
}

class AuthViewModel(application: Application) : AndroidViewModel(application) {
    private val client = AuthClient(
        sessionStore = SessionCookieStore(application),
        // Recording wraps the real transport so the inspector shows the same
        // bytes the auth flow sent, including a rejected sign-in.
        httpTransport = RecordingAuthTransport(HttpsAuthTransport(AuthConfig.BASE_URL)),
        meCache = RoomAuthMeCache(application),
    )
    private val _uiState = MutableStateFlow(AuthUiState())
    val uiState: StateFlow<AuthUiState> = _uiState.asStateFlow()
    private var restoreJob: Job? = null

    init {
        restoreSession()
    }

    fun restoreSession(forceRefresh: Boolean = false) {
        restoreJob?.cancel()
        restoreJob = viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                client.restoreSession(forceRefresh)
            }
            _uiState.value = authUiStateFor(result)
        }
    }

    fun login(email: String, password: String) {
        if (_uiState.value.isAuthenticating) return
        _uiState.update { it.copy(isAuthenticating = true, errorMessage = null) }

        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                client.login(email = email, password = password)
            }
            _uiState.value = when (result) {
                // Sign-in is the one result that is not the same failure as the
                // same failure during a restore: a dropped connection here must
                // offer the form again, not a "Try again" that re-checks the
                // session the user does not have.
                is AuthResult.Unavailable -> AuthUiState(
                    phase = SessionPhase.NeedsLogin,
                    errorMessage = result.message,
                )

                AuthResult.NoSession -> AuthUiState(
                    phase = SessionPhase.NeedsLogin,
                    errorMessage = "Sign-in did not complete. Try again.",
                )

                else -> authUiStateFor(result)
            }
        }
    }

    /**
     * Sign-out.
     *
     * One method for both entry points — the sidebar's "Log out" and the
     * retry screen's "Sign in" — because they end the same session and a second
     * name for it is a second thing that can drift.
     *
     * Re-entrancy guarded: the disabled sidebar button is the visible half of
     * this, and the ViewModel is the half that still holds when the composition
     * is gone. `isLoggingOut` is cleared by the state replacement below, so a
     * finished sign-out does not need its own reset path.
     */
    fun logout() {
        if (_uiState.value.isLoggingOut) return
        _uiState.update { it.copy(isLoggingOut = true) }

        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                client.logout()
            }
            _uiState.value = signedOutUiStateFor(result)
        }
    }
}
