package com.nalar.mobile

import android.graphics.Color as AndroidColor
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.viewmodel.compose.viewModel
import com.nalar.mobile.auth.AuthViewModel
import com.nalar.mobile.network.NalarNavGraph
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
                val viewModel: AuthViewModel = viewModel()
                val uiState by viewModel.uiState.collectAsState()

                NalarNavGraph(
                    authState = uiState,
                    onSignIn = viewModel::login,
                    onRetrySession = viewModel::restoreSession,
                    onUseAnotherAccount = viewModel::useAnotherAccount,
                )
            }
        }
    }
}
