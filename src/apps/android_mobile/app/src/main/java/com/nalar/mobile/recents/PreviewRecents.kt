package com.nalar.mobile.recents

private val previewNow = System.currentTimeMillis()

internal val PreviewWorkspaces = listOf(
    WorkspaceOption(id = "ws_sprint", name = "Sprint bulan Juni"),
    WorkspaceOption(id = "ws_kabelweb", name = "Kabelweb"),
    WorkspaceOption(id = "ws_design", name = "Design"),
)

internal val PreviewChats = listOf(
    ChatSummary(
        id = "chat_android_sidebar",
        workspaceId = "ws_sprint",
        title = "Review the Android sidebar",
        updatedAtEpochMillis = previewNow - 5L * 60_000L,
    ),
    ChatSummary(
        id = "chat_mobile_release",
        workspaceId = "ws_sprint",
        title = "Android release checklist",
        updatedAtEpochMillis = previewNow - 3L * 60L * 60_000L,
    ),
    ChatSummary(
        id = "chat_design_notes",
        workspaceId = "ws_sprint",
        title = "Design notes",
        updatedAtEpochMillis = previewNow - 3L * 24L * 60L * 60_000L,
    ),
    ChatSummary(
        id = "chat_router_regression",
        workspaceId = "ws_kabelweb",
        title = "Router route-order regression",
        updatedAtEpochMillis = previewNow - 12L * 60_000L,
    ),
    ChatSummary(
        id = "chat_sse_filter",
        workspaceId = "ws_kabelweb",
        title = "Session SSE filtering",
        updatedAtEpochMillis = previewNow - 2L * 24L * 60L * 60_000L,
    ),
    ChatSummary(
        id = "chat_chat_feedback",
        workspaceId = "ws_design",
        title = "Chat view feedback",
        updatedAtEpochMillis = previewNow - 4L * 60L * 60_000L,
    ),
)
