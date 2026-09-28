package com.nalar.mobile

import android.graphics.Color as AndroidColor
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import com.nalar.mobile.auth.AuthViewModel
import com.nalar.mobile.auth.SessionCookieStore
import com.nalar.mobile.chat.ChatUiState
import com.nalar.mobile.chat.ChatViewModel
import com.nalar.mobile.chat.SseBus
import com.nalar.mobile.chat.SseBusHolder
import com.nalar.mobile.network.NalarNavGraph
import com.nalar.mobile.recents.HomeViewModel
import com.nalar.mobile.storage.PrefsLastPositionStore
import com.nalar.mobile.ui.NalarTheme
import com.nalar.mobile.worker.WorkerActivityViewModel
import kotlinx.coroutines.flow.StateFlow
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

                // One store for the process. The ViewModel writes the position
                // the user just moved to; the nav graph reads it back to decide
                // what a relaunch should reopen. Two instances would be two views
                // of the same two preference keys.
                val positionStore = remember { PrefsLastPositionStore(application) }

                val homeViewModel: HomeViewModel = viewModel(
                    factory = HomeViewModel.factory(application, positionStore),
                )
                val homeState by homeViewModel.uiState.collectAsState()

                val chatViewModel: ChatViewModel = viewModel(
                    factory = ChatViewModel.factory(application),
                )
                // Handed over as the flow, not sampled into a value or a
                // `() -> ChatUiState` provider. A provider looked equivalent and
                // subscribed nothing — `StateFlow.value` is not a snapshot read —
                // so the chat route only ever repainted when some *other*
                // collected state changed, and typing was the one interaction
                // with nothing else changing behind it. The graph's chat
                // destination collects this, so a draft keystroke recomposes the
                // transcript and leaves the drawer and the `NavHost` alone.
                val chatState: StateFlow<ChatUiState> = chatViewModel.uiState

                // Which sessions have a live worker. Its own ViewModel, and its
                // own `workers` subscription, because the chat stream only exists
                // while a chat is open — and the sidebar is on screen precisely
                // when one is not.
                val workerViewModel: WorkerActivityViewModel = viewModel(
                    factory = WorkerActivityViewModel.factory(application),
                )
                val runningSessionIds by workerViewModel.runningSessionIds.collectAsState()

                // The app's ONE event connection, opened here and nowhere else.
                //
                // The root owns it for the same reason the web app's root does:
                // a socket opened per screen is a socket torn down per
                // navigation, and two ViewModels with two sockets of opposite
                // lifetimes can never agree about what is running. Both
                // subscribers below are handed this one.
                val sseBus: SseBus = remember(application) {
                    SseBusHolder.get(SessionCookieStore(application))
                }

                // One sign-out, three entry points: the sidebar's "Log out", the
                // retry screen's "Sign in", and a 401 from either cache. They are
                // the same action, so they must purge the account-scoped caches
                // the same way — before the cookie goes, or a cached row from the
                // outgoing account can still be painted afterwards.
                val signOut: () -> Unit = {
                    homeViewModel.onSignedOut()
                    chatViewModel.onSignedOut()
                    workerViewModel.onSignedOut()
                    sseBus.close()
                    authViewModel.logout()
                }

                // The signed-in account namespaces both caches AND owns the
                // socket, whose handshake is a cookie the server answers once and
                // never retries. Reacting to it here (rather than inside a
                // ViewModel's init) means the first paint is already scoped to
                // the right account.
                //
                // Gating `open()` on a non-null user is load-bearing: the pump
                // treats a non-2xx handshake as terminal and returns instead of
                // retrying, so a socket opened before the cookie exists burns
                // its one handshake and then reports nothing for the life of the
                // process — which reads as "no worker has ever run".
                LaunchedEffect(authState.userId) {
                    homeViewModel.onUserChanged(authState.userId)
                    chatViewModel.onUserChanged(authState.userId)
                    workerViewModel.onUserChanged(authState.userId)
                    if (authState.userId.isNullOrBlank()) sseBus.close() else sseBus.open()
                }

                // The workers socket is open for the whole process, so a run
                // that ended while the app was backgrounded produced a
                // `worker_deleted` this process never dispatched — and because
                // the socket never dropped, no reconnect is coming to correct
                // it. Coming back to the app is exactly when that stale set is
                // most visible, so re-read the list on the way in. The periodic
                // beat inside the ViewModel covers the same gap while the app is
                // in use; this covers the moment the user looks at it.
                val lifecycleOwner = LocalLifecycleOwner.current
                DisposableEffect(lifecycleOwner, authState.userId) {
                    val observer = LifecycleEventObserver { _, event ->
                        if (event == Lifecycle.Event.ON_START) {
                            workerViewModel.onForeground()
                        }
                    }
                    lifecycleOwner.lifecycle.addObserver(observer)
                    onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
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
                    positionStore = positionStore,
                    onSelectWorkspace = homeViewModel::selectWorkspace,
                    onSelectChat = homeViewModel::selectChat,
                    onLoadMoreChats = homeViewModel::loadMoreChats,
                    onToggleProjectsSection = homeViewModel::toggleProjectsSection,
                    onToggleProjectExpanded = homeViewModel::toggleProjectExpanded,
                    onEnsureProjectChatsLoaded = homeViewModel::ensureProjectChatsLoaded,
                    onLoadMoreProjectChats = homeViewModel::loadMoreProjectChats,
                    onRetryProjects = homeViewModel::retryProjects,
                    // The create's only ViewModel-facing half. The graph owns
                    // the sheet and the navigation; the ViewModel owns the POST
                    // and the row it paints.
                    onCreateTask = { workspaceId, itemId, request ->
                        // The workspace the row carries is the one the drawer's
                        // copy may be blank on (a project read from cache), and
                        // the endpoint is nested under it, so a blank here is a
                        // 404 rather than a defaulted success.
                        if (workspaceId.isNotBlank()) {
                            homeViewModel.createTask(itemId, request)
                        }
                    },
                    // The drawer's top-level "New Chat". No project id and no
                    // request: HomeViewModel resolves the workspace's default
                    // project itself (Migration 094) and builds the Standard
                    // Chat, so the graph and this activity neither have to know
                    // which project that is.
                    onNewChat = homeViewModel::newChat,
                    createdChats = homeViewModel.createdChat,
                    onDismissTaskCreateError = homeViewModel::dismissTaskCreateError,
                    onToggleRecentsSection = homeViewModel::toggleRecentsSection,
                    onRetryHome = homeViewModel::refresh,
                    onOpenSession = chatViewModel::openSession,
                    onChatDraftChanged = chatViewModel::onDraftChanged,
                    onSendChatMessage = chatViewModel::sendMessage,
                    onStopChatRun = chatViewModel::stopRun,
                    onRefreshChatQueue = chatViewModel::refreshQueuedMessages,
                    onUseQueuedChatMessage = chatViewModel::useQueuedMessage,
                    onSelectChatModel = chatViewModel::selectProfile,
                    onAttachChatImage = chatViewModel::attachImage,
                    onRemoveChatAttachment = chatViewModel::removeAttachment,
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
