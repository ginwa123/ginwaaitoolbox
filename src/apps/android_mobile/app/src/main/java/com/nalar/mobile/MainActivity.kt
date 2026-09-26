package com.nalar.mobile

import android.graphics.Color as AndroidColor
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.viewmodel.compose.viewModel
import com.nalar.mobile.auth.AuthViewModel
import com.nalar.mobile.network.NalarNavGraph
import com.nalar.mobile.recents.HomeViewModel
import com.nalar.mobile.ui.NalarTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(AndroidColor.rgb(24, 22, 22)),
        )
        setContent {
            NalarTheme {
                val application = application
                val authViewModel: AuthViewModel = viewModel()
                val authState by authViewModel.uiState.collectAsState()

                val homeViewModel: HomeViewModel = viewModel(
                    factory = HomeViewModel.factory(application),
                )
                val homeState by homeViewModel.uiState.collectAsState()

                // The signed-in account namespaces the sidebar cache. Reacting
                // to it here (rather than inside the ViewModel's init) means the
                // first paint is already scoped to the right account.
                LaunchedEffect(authState.userId) {
                    homeViewModel.onUserChanged(authState.userId)
                }

                // A 401 on any sidebar call means the saved cookie is dead;
                // signing out is the only outcome a retry cannot fix.
                LaunchedEffect(homeViewModel) {
                    homeViewModel.sessionExpired.collect {
                        authViewModel.useAnotherAccount()
                    }
                }

                NalarNavGraph(
                    authState = authState,
                    onSignIn = authViewModel::login,
                    onRetrySession = authViewModel::restoreSession,
                    onUseAnotherAccount = {
                        // Purge before the cookie goes, so no cached row from the
                        // outgoing account can be painted after it.
                        homeViewModel.onSignedOut()
                        authViewModel.useAnotherAccount()
                    },
                    homeState = homeState,
                    onSelectWorkspace = homeViewModel::selectWorkspace,
                    onSelectChat = homeViewModel::selectChat,
                    onRetryHome = homeViewModel::refresh,
                )
            }
        }
    }
}
