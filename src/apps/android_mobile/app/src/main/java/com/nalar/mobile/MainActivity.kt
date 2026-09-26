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
import com.nalar.mobile.chat.ChatViewModel
import com.nalar.mobile.network.NalarNavGraph
import com.nalar.mobile.recents.HomeViewModel
import com.nalar.mobile.ui.NalarTheme
import com.nalar.mobile.worker.WorkerActivityViewModel
import kotlinx.coroutines.launch

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

                val chatViewModel: ChatViewModel = viewModel(
                    factory = ChatViewModel.factory(application),
                )
                val chatState by chatViewModel.uiState.collectAsState()

                // Which sessions have a live worker. Its own ViewModel, and its
                // own `workers` subscription, because the chat stream only exists
                // while a chat is open — and the sidebar is on screen precisely
                // when one is not.
                val workerViewModel: WorkerActivityViewModel = viewModel(
                    factory = WorkerActivityViewModel.factory(application),
                )
                val runningSessionIds by workerViewModel.runningSessionIds.collectAsState()

                // One sign-out, three entry points: the sidebar's "Log out", the
                // retry screen's "Sign in", and a 401 from either cache. They are
                // the same action, so they must purge the account-scoped caches
                // the same way — before the cookie goes, or a cached row from the
                // outgoing account can still be painted afterwards.
                val signOut: () -> Unit = {
                    homeViewModel.onSignedOut()
                    chatViewModel.onSignedOut()
                    workerViewModel.onSignedOut()
                    authViewModel.logout()
                }

                // The signed-in account namespaces both caches and gates the
                // worker subscription, whose handshake is a cookie the server
                // answers once and never retries. Reacting to it here (rather
                // than inside a ViewModel's init) means the first paint is
                // already scoped to the right account, and signing out stops
                // the stream and drops the ids.
                LaunchedEffect(authState.userId) {
                    homeViewModel.onUserChanged(authState.userId)
                    chatViewModel.onUserChanged(authState.userId)
                    workerViewModel.onUserChanged(authState.userId)
                }

                // A 401 on any call means the saved cookie is dead; signing out
                // is the only outcome a retry cannot fix.
                LaunchedEffect(homeViewModel, chatViewModel) {
                    launch {
                        homeViewModel.sessionExpired.collect { signOut() }
                    }
                    launch {
                        chatViewModel.sessionExpired.collect { signOut() }
                    }
                }

                NalarNavGraph(
                    authState = authState,
                    onSignIn = authViewModel::login,
                    // The retry screen's whole purpose is to re-check the
                    // session, so it must bypass the /me cache.
                    onRetrySession = { authViewModel.restoreSession(forceRefresh = true) },
                    onUseAnotherAccount = signOut,
                    onLogout = signOut,
                    homeState = homeState,
                    chatState = chatState,
                    onSelectWorkspace = homeViewModel::selectWorkspace,
                    onSelectChat = homeViewModel::selectChat,
                    onLoadMoreChats = homeViewModel::loadMoreChats,
                    onRetryHome = homeViewModel::refresh,
                    onOpenSession = chatViewModel::openSession,
                    onChatDraftChanged = chatViewModel::onDraftChanged,
                    onSendChatMessage = chatViewModel::sendMessage,
                    onStopChatRun = chatViewModel::stopRun,
                    onLoadOlderChatMessages = chatViewModel::loadOlderMessages,
                    onDismissChatError = chatViewModel::clearError,
                    onAnswerChatQuestion = {
                        chatViewModel.answerQuestion(
                            questionId = it.questionId,
                            toolCallId = it.toolCallId,
                            answer = it.answer,
                            skip = it.skip,
                        )
                    },
                    runningSessionIds = runningSessionIds,
                )
            }
        }
    }
}
