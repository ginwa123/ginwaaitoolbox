package com.nalar.mobile.recents

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Where the drawer says the chat list ends.
 *
 * The whole rule in one line, and the reason it is not written inline in
 * `SidebarBody`: the Recents header is a row in the drawer's single list, so it
 * shifts every chat index by one, and the paging trigger counts indices. A
 * layout test cannot catch a one-row shift — proving it would need a viewport
 * measured to the row, and the moment the row's padding changes such a test
 * stops testing anything while still going green.
 */
class ChatRegionEndIndexTest {

    @Test
    fun theHeaderIsCountedSoTheEndSitsPastTheLastChat() {
        // Header at 0, chats at 1..10, footer at 11. Answering 10 would arm the
        // trigger a row early, which fires a page while the reader is still
        // scrolling towards the bottom of the one they are reading.
        assertEquals(11, chatRegionEndIndex(visibleChatCount = 10, recentsExpanded = true))
    }

    @Test
    fun aSingleChatStillEndsPastItself() {
        assertEquals(2, chatRegionEndIndex(visibleChatCount = 1, recentsExpanded = true))
    }

    @Test
    fun anOpenListCountsTheRowBetweenItsLastChatAndItsFooter() {
        // The "Show fewer" row is a row in the list, drawn only once the reader
        // opens the whole thing. Forgetting it arms the trigger a row early for
        // exactly the readers who opened the list — the ones paging matters to.
        assertEquals(
            32,
            chatRegionEndIndex(
                visibleChatCount = 30,
                recentsExpanded = true,
                rowsAfterChats = 1,
            ),
        )
    }

    @Test
    fun anEmptyChatListHasNoRegionToPage() {
        // Nothing to page, and a number here would let the trigger arm on the
        // Projects header below — paging a workspace's chats from a scroll
        // through its projects.
        assertNull(chatRegionEndIndex(visibleChatCount = 0, recentsExpanded = true))
    }

    @Test
    fun aFoldedSectionHasNoRegionToPage() {
        // The reader hid these rows a moment ago. Paging them now would fetch a
        // page they cannot see and did not ask for.
        assertNull(chatRegionEndIndex(visibleChatCount = 10, recentsExpanded = false))
    }
}
