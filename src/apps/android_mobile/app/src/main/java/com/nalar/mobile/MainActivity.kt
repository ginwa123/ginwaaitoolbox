package com.nalar.mobile

import android.graphics.Color as AndroidColor
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import com.nalar.mobile.login.LoginScreen
import com.nalar.mobile.recents.PreviewChats
import com.nalar.mobile.recents.PreviewWorkspaces
import com.nalar.mobile.shell.MobileHomeScreen
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
                var showWorkspacePreview by rememberSaveable {
                    mutableStateOf(false)
                }

                if (showWorkspacePreview) {
                    MobileHomeScreen(
                        workspaces = PreviewWorkspaces,
                        chats = PreviewChats,
                    )
                } else {
                    LoginScreen(
                        onSignIn = { showWorkspacePreview = true },
                    )
                }
            }
        }
    }
}
