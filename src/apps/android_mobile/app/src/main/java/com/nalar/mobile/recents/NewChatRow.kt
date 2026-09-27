package com.nalar.mobile.recents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarText

/**
 * The drawer's top-level "New Chat" row.
 *
 * Unlike [com.nalar.mobile.projects.CreateTaskUi.CreateTaskRow] — which adds a
 * chat to one *specific* project and therefore leaves the drawer open so the
 * reader can see the new row appear there — this one is a navigation action: it
 * creates a chat in the workspace's default project and opens it, so the
 * drawer closes with it (D13). Two identical-looking `+` buttons doing opposite
 * things would be unreadable, hence the pencil glyph rather than a plus.
 *
 * **Placement is load-bearing.** This row lives in the `Column` above the
 * `LazyColumn`, NOT inside it. `chatRegionEndIndex` is index arithmetic that
 * assumes a fixed number of rows sit above the chats inside the list (see
 * `RecentsSidebar.kt`), and one extra row inside the list would shift every
 * chat index — making the full-page fetch arm a screen early, with no error and
 * no layout test that can see it. `ChatRegionEndIndexTest` guards this.
 *
 * [isBusy] is the app-wide create guard, not a per-project one: one create at a
 * time is the correct semantic, and a second "New Chat" row from one tap is
 * exactly what that guard exists to prevent.
 */
@Composable
internal fun NewChatRow(
    isBusy: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        // The affordance half of the invariant; HomeViewModel is the other.
        enabled = !isBusy,
        modifier = modifier
            .fillMaxWidth()
            .testTag("sidebar_new_chat")
            .semantics {
                role = Role.Button
                contentDescription = "Start a new chat"
            },
        shape = RoundedCornerShape(10.dp),
        color = Color.Transparent,
        contentColor = NalarText,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (isBusy) {
                CircularProgressIndicator(
                    modifier = Modifier
                        .testTag("sidebar_new_chat_busy")
                        .semantics { contentDescription = "Starting a new chat" },
                    color = NalarAccent,
                    strokeWidth = 2.dp,
                )
            } else {
                androidx.compose.material3.Icon(
                    imageVector = Icons.Filled.Edit,
                    // The a11y name is on the Surface above, so this is hidden
                    // from the semantics tree to avoid a doubled announcement.
                    contentDescription = null,
                    tint = NalarAccent,
                    modifier = Modifier.testTag("sidebar_new_chat_icon"),
                )
            }
            Text(
                text = "New Chat",
                style = androidx.compose.material3.MaterialTheme.typography.labelLarge,
                color = NalarText,
            )
        }
    }
}
