package com.pabrik.mobile.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccentSoft
import com.pabrik.mobile.ui.PabrikCard
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

/**
 * Which tool cards the reader has opened.
 *
 * Keyed by message id and never by index: a streamed append shifts every index
 * below it, so an index key silently collapses the cards the user had just
 * opened — and the agentic run this feature exists for is nothing but appends.
 * `rememberSaveable` because a card someone opened should still be open after a
 * rotation.
 */
@Composable
fun rememberToolExpansion(): ToolExpansion =
    rememberSaveable(saver = ToolExpansion.Saver) { ToolExpansion() }

/**
 * An explicit open/closed decision per row.
 *
 * A decision, not a set of open rows, and the distinction is the whole design.
 * A card can *default* to open — `ask_user` does, because the run is blocked on
 * it — and a set of open ids cannot express "this one defaults to open and the
 * reader has now closed it", because absent would have to mean both
 * "inherit the default" and "explicitly closed". Every defaulting card would be
 * impossible to close. So the map holds the reader's overrides and absence means
 * "inherit", which is the only encoding where both directions work.
 */
class ToolExpansion(initial: Map<String, Boolean> = emptyMap()) {
    private var overrides: Map<String, Boolean> by mutableStateOf(initial)

    fun isExpanded(id: String, defaultsToOpen: Boolean = false): Boolean =
        overrides[id] ?: defaultsToOpen

    fun toggle(id: String, defaultsToOpen: Boolean = false) {
        overrides = overrides + (id to !isExpanded(id, defaultsToOpen))
    }

    companion object {
        /**
         * Saves only the *open* ids.
         *
         * Saving every key and restoring them all as `true` reopens every card
         * the reader had shut — and four of the card kinds default to open, so
         * the damage lands on exactly the cards that must not be reopened
         * (a dismissed blocking question). A closed card simply has no entry,
         * which is the same absence that means "inherit the default".
         *
         * The alternative of saving key → boolean needs a `Bundle`-friendly
         * type the Compose `Saver` machinery does not offer for a `Map`, and it
         * would halve the payload for no gain: a `false` entry is always
         * recoverable from the default.
         */
        val Saver = listSaver<ToolExpansion, String>(
            save = { state -> state.overrides.filterValues { it }.keys.toList() },
            restore = { ids -> ToolExpansion(ids.associateWith { true }) },
        )
    }
}

/**
 * The header for tool calls that no card has answered yet.
 *
 * It is a header rather than a row of its own, and that is the whole change:
 * the call and its output are one thing the reader looks at, so this draws at
 * the top of the run it belongs to instead of as a separate list item above
 * it. [groupMessages] decides which calls land here — by the time a call has a
 * result card on screen, it is not in the list, because the card already shows
 * the call's name and arguments and a second line repeating them is the noise.
 *
 * What is left is the live window: a call declared a moment ago whose `tool`
 * row has not landed. Those have nothing else drawing them, so the header is
 * the only thing keeping a running tool call from being invisible.
 */
@Composable
fun ToolCallSummaryRow(
    calls: List<ToolCallEntry>,
    expansion: ToolExpansion,
    id: String,
    modifier: Modifier = Modifier,
) {
    if (calls.isEmpty()) return
    val expanded = expansion.isExpanded(id)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(6.dp))
            .background(PabrikCard)
            .testTag("tool_call_summary"),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expansion.toggle(id) }
                .padding(horizontal = 8.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (calls.size == 1) "1 TOOL" else "${calls.size} TOOLS",
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = PabrikAccentSoft,
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = calls.joinToString(", ") { it.name }.ifBlank { "unknown" },
                style = MaterialTheme.typography.labelSmall,
                color = PabrikMuted,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = if (expanded) {
                    Icons.Filled.KeyboardArrowDown
                } else {
                    Icons.AutoMirrored.Filled.KeyboardArrowRight
                },
                contentDescription = if (expanded) "Collapse" else "Expand",
                tint = PabrikMuted,
                modifier = Modifier.testTag("tool_call_summary_chevron"),
            )
        }

        if (expanded) {
            Column(
                modifier = Modifier.padding(bottom = 4.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                calls.forEach { call ->
                    Column(modifier = Modifier.padding(horizontal = 8.dp)) {
                        Text(
                            text = call.name.ifEmpty { "(unnamed)" },
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                            color = PabrikText,
                        )
                        val arguments = call.summary
                        if (arguments.isNotEmpty()) {
                            Text(
                                text = arguments,
                                style = MaterialTheme.typography.labelSmall,
                                fontFamily = FontFamily.Monospace,
                                color = PabrikDim,
                            )
                        }
                    }
                }
            }
        }
    }
}
