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
    val errorMessage: String? = null,
)

class AuthViewModel(application: Application) : AndroidViewModel(application) {
    private val client = AuthClient(
        sessionStore = SessionCookieStore(application),
        // Recording wraps the real transport so the inspector shows the same
        // bytes the auth flow sent, including a rejected sign-in.
        httpTransport = RecordingAuthTransport(HttpsAuthTransport(AuthConfig.BASE_URL)),
    )
    private val _uiState = MutableStateFlow(AuthUiState())
    val uiState: StateFlow<AuthUiState> = _uiState.asStateFlow()
    private var restoreJob: Job? = null

    init {
        restoreSession()
    }

    fun restoreSession() {
        restoreJob?.cancel()
        restoreJob = viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                client.restoreSession()
            }
            _uiState.value = when (result) {
                is AuthResult.Authenticated,
                AuthResult.AuthDisabled,
                -> AuthUiState(phase = SessionPhase.Authenticated)
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
                is AuthResult.Authenticated,
                AuthResult.AuthDisabled,
                -> AuthUiState(phase = SessionPhase.Authenticated)
                is AuthResult.Rejected -> AuthUiState(
                    phase = SessionPhase.NeedsLogin,
                    errorMessage = result.message,
                )
                is AuthResult.Unavailable -> AuthUiState(
                    phase = SessionPhase.NeedsLogin,
                    errorMessage = result.message,
                )
                AuthResult.NoSession -> AuthUiState(
                    phase = SessionPhase.NeedsLogin,
                    errorMessage = "Sign-in did not complete. Try again.",
                )
            }
        }
    }

    fun useAnotherAccount() {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                client.logout()
            }
            _uiState.value = when (result) {
                is AuthResult.Unavailable -> AuthUiState(
                    phase = SessionPhase.NeedsLogin,
                    errorMessage = result.message,
                )
                else -> AuthUiState(phase = SessionPhase.NeedsLogin)
            }
        }
    }
}
