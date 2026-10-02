package com.nalar.mobile.recents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarMuted

/**
 * The header above a collapsible sidebar section: the word, how many rows it
 * holds, and a chevron that folds the section away.
 *
 * One implementation for both sections because they are the same control with a
 * different noun. A second copy would be a second place to forget the part
 * that matters most — see the background note below — and a second place for
 * the two sections' fold behaviour to drift apart.
 *
 * The background is [NalarBackground] and never transparent. This row is a
 * **sticky** header: the rows below it scroll *under* it, and a transparent
 * header would show a chat title sliding through the word "Recent". Painting
 * the drawer's own colour makes the pin invisible until something goes beneath
 * it, which is the whole point — the reader sees a fixed title, not a floating
 * bar.
 *
 * [itemCount] is the number of rows the section *holds*, not the number it is
 * showing: a folded section still says how much is in it, which is what makes
 * folding a decision rather than a way to lose rows.
 */
@Composable
internal fun SidebarSectionHeader(
    title: String,
    itemCount: Int,
    /** "chats" / "projects" — read out after the number. */
    unit: String,
    expanded: Boolean,
    onClick: () -> Unit,
    testTag: String,
    modifier: Modifier = Modifier,
    /**
     * Whether anything in this section is busy right now.
     *
     * Only the Projects header ever passes it. The web mounts a `SessionSlider`
     * beside the section count for the same reason
     * (`ProjectsList.vue`, `firstProcessingTaskIdInWorkspace`): the header is
     * the one row that is on screen when every project row is folded away, so
     * without it a workspace with work in flight can look completely idle.
     *
     * Defaults false so the Recent header — whose own rows carry their own
     * spinners, and which therefore has nothing extra to say — is unchanged,
     * and so a caller that forgets it renders honestly rather than claiming
     * nothing is running.
     */
    isRunning: Boolean = false,
) {
    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .testTag(testTag)
            .semantics {
                role = Role.Button
                heading()
                contentDescription = buildString {
                    append("$title. $itemCount $unit in this workspace")
                    if (isRunning) append(", agent is working")
                }
                stateDescription = if (expanded) "Expanded" else "Collapsed"
            },
        shape = RoundedCornerShape(10.dp),
        color = NalarBackground,
        contentColor = NalarDim,
    ) {
        // 6dp, not 10dp. This row's own padding sits on top of every gap around
        // it — the spacer above the scroller, the 8dp above the Projects
        // header, and the list's 4dp `spacedBy` — so 10dp here was slack only
        // the *sections* carried while their rows carried 4dp, and the word
        // "Recent" read as a heading a row and a half away from its list.
        Row(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelLarge,
                color = NalarDim,
                modifier = Modifier.weight(1f),
            )
            if (itemCount > 0) {
                Text(
                    text = itemCount.toString(),
                    style = MaterialTheme.typography.labelMedium,
                    color = NalarMuted,
                )
            }
            if (isRunning) {
                CircularProgressIndicator(
                    // Decorative — the section's own description already says
                    // it, and announcing it a second time is worse than not
                    // announcing it.
                    modifier = Modifier
                        .clearAndSetSemantics { }
                        .size(14.dp)
                        .testTag("${testTag}_running"),
                    strokeWidth = 2.dp,
                    color = NalarAccent,
                )
            }
            Icon(
                imageVector = Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = NalarDim,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}
