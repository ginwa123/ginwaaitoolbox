package com.nalar.mobile.recents

import org.junit.Assert.assertEquals
import org.junit.Test

class RecentsModelsTest {
    @Test
    fun recentChatsForWorkspaceFiltersAndSortsNewestFirst() {
        val chats = listOf(
            ChatSummary("chat-old", "workspace-a", "Old", 100L),
            ChatSummary("chat-b", "workspace-b", "Other workspace", 500L),
            ChatSummary("chat-a", "workspace-a", "New", 300L),
        )

        val result = recentChatsForWorkspace(chats, "workspace-a")

        assertEquals(listOf("chat-a", "chat-old"), result.map { it.id })
    }

    @Test
    fun recentChatsForWorkspaceUsesIdAsStableTieBreaker() {
        val chats = listOf(
            ChatSummary("chat-b", "workspace-a", "Second", 300L),
            ChatSummary("chat-a", "workspace-a", "First", 300L),
        )

        val result = recentChatsForWorkspace(chats, "workspace-a")

        assertEquals(listOf("chat-a", "chat-b"), result.map { it.id })
    }

    @Test
    fun blankChatTitleFallsBackToNewChat() {
        val chat = ChatSummary("chat-1", "workspace-a", "   ", 300L)

        assertEquals("New Chat", chat.displayTitle)
    }

    @Test
    fun formatRelativeTimeUsesCompactRecentLabels() {
        val now = 10_000_000_000L

        assertEquals("now", formatRelativeTime(now - 30_000L, now))
        assertEquals("5m", formatRelativeTime(now - 5L * 60_000L, now))
        assertEquals("2h", formatRelativeTime(now - 2L * 60L * 60_000L, now))
        assertEquals("3d", formatRelativeTime(now - 3L * 24L * 60L * 60_000L, now))
        assertEquals("1w", formatRelativeTime(now - 7L * 24L * 60L * 60_000L, now))
        assertEquals("2mo", formatRelativeTime(now - 60L * 24L * 60L * 60_000L, now))
        assertEquals("1y", formatRelativeTime(now - 365L * 24L * 60L * 60_000L, now))
    }

    @Test
    fun accessibilityTimeLabelsSpellOutUnits() {
        val now = 10_000_000_000L

        assertEquals(
            "updated just now",
            formatRelativeTimeForAccessibility(now - 30_000L, now),
        )
        assertEquals(
            "updated 1 hour ago",
            formatRelativeTimeForAccessibility(now - 60L * 60_000L, now),
        )
        assertEquals(
            "updated 2 days ago",
            formatRelativeTimeForAccessibility(now - 2L * 24L * 60L * 60_000L, now),
        )
    }
}
