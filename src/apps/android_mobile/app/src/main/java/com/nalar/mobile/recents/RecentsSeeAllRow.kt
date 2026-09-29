package com.nalar.mobile.recents

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarDim

/**
 * The row under the Recents preview that reveals the rest of the chats — and,
 * once revealed, puts them away again.
 *
 * One row that toggles rather than two, because the drawer is a *narrow*
 * column: a permanent "See all" above a permanent "Show fewer" is a second
 * control in a space that has just been shortened, and two of them disagree
 * the moment the reader taps the wrong one. The label always names what the tap
 * will do, so the row is never a question.
 *
 * It also *replaces* the paging footer in the capped view — see
 * [recentsShowsChatFooter] — because with rows held back there is no end of the
 * list to report and nothing to scroll.
 *
 * [hiddenChatCount] is what the reader gains, not the total: "See 25 more chats"
 * is a number they can decide against, where "See all chats" against a header
 * already reading 30 is the same information said twice.
 */
@Composable
internal fun RecentsSeeAllRow(
    hiddenChatCount: Int,
    showingAll: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val label = when {
        showingAll -> "Show fewer"
        hiddenChatCount == 1 -> "See 1 more chat"
        else -> "See $hiddenChatCount more chats"
    }

    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .testTag("recents_see_all")
            .semantics {
                role = Role.Button
                contentDescription = if (showingAll) {
                    "Show only the most recent chats"
                } else {
                    "Show $hiddenChatCount more chats"
                }
                stateDescription = if (showingAll) "All chats shown" else "Showing a preview"
            },
        // Transparent: the rows it belongs to are plain text on the drawer's own
        // background, and a filled row here would read as a selected chat — a
        // control dressed as the thing it controls.
        shape = RoundedCornerShape(10.dp),
        color = Color.Transparent,
        contentColor = NalarAccent,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelLarge,
                color = NalarAccent,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = if (showingAll) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                // The a11y name is on the Surface above, so this is hidden from
                // the semantics tree to avoid a doubled announcement.
                contentDescription = null,
                tint = NalarDim,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}
