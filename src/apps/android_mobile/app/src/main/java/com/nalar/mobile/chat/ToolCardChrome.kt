package com.nalar.mobile.chat

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nalar.mobile.ui.NalarAccentSoft
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarCard
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarError
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText

/**
 * The chrome every tool card shares: the violet tool name, the truncated
 * primary field, the right-hand meta, the status glyph and the disclosure
 * chevron.
 *
 * Modelled on the web's `_shared/ToolCardHeader.vue`, with the two affordances
 * it carries dropped rather than reimplemented: copy-to-clipboard (a phone has
 * no hover, so a hover-revealed button is a button nobody finds — long-press to
 * select is the platform idiom) and open-in-code-editor (this app has no
 * editor).
 */
@Composable
fun ToolCardHeader(
    toolName: String,
    primary: String?,
    rightMeta: String?,
    success: Boolean,
    running: Boolean,
    expanded: Boolean,
    expandable: Boolean = true,
    modifier: Modifier = Modifier,
    onToggle: () -> Unit = {},
) {
    val statusColor by animateColorAsState(
        targetValue = when {
            running -> Color(0xFFD8B96A)
            success -> Color(0xFF87A987)
            else -> NalarError
        },
        label = "tool-card-status",
    )

    Row(
        modifier = modifier
            .fillMaxWidth()
            .then(
                if (expandable) {
                    Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .clickable(onClick = onToggle)
                } else {
                    Modifier
                },
            )
            .padding(horizontal = 6.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = toolName,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = NalarAccentSoft,
            maxLines = 1,
            modifier = Modifier.testTag("tool_card_name"),
        )

        if (primary != null) {
            Text(
                text = "  $primary",
                style = MaterialTheme.typography.labelSmall,
                color = NalarAccentSoft,
                maxLines = 1,
                // One line, ellipsised. A path on a 360dp-wide phone is already
                // wider than the card, and a header that wraps doubles the height
                // of every card in a forty-step run.
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .weight(1f)
                    .testTag("tool_card_primary"),
            )
        } else {
            Spacer(Modifier.weight(1f))
        }

        if (rightMeta != null) {
            Text(
                text = rightMeta,
                style = MaterialTheme.typography.labelSmall,
                color = NalarMuted,
                maxLines = 1,
            )
        }

        if (running) {
            Text(
                text = "running…",
                style = MaterialTheme.typography.labelSmall,
                color = statusColor,
                maxLines = 1,
                modifier = Modifier
                    .padding(start = 6.dp)
                    .testTag("tool_card_running"),
            )
        }

        Text(
            // A tick, a cross or a dash. The dash is "not known yet" rather
            // than "failed" — drawing a cross on a placeholder makes an
            // in-flight tool look broken.
            text = when {
                running -> "·"
                success -> "✓"
                else -> "✗"
            },
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold,
            color = statusColor,
            modifier = Modifier
                .padding(start = 6.dp)
                .testTag("tool_card_status"),
        )

        if (expandable) {
            Icon(
                imageVector = if (expanded) {
                    Icons.Filled.KeyboardArrowDown
                } else {
                    Icons.AutoMirrored.Filled.KeyboardArrowRight
                },
                contentDescription = if (expanded) "Collapse" else "Expand",
                tint = NalarMuted,
                modifier = Modifier
                    .padding(start = 2.dp)
                    .size(16.dp)
                    .testTag("tool_card_chevron"),
            )
        }
    }
}

/**
 * The `Arguments` disclosure every card carries.
 *
 * Mirrors `_shared/ToolParameters.vue`, including the guard that hides the
 * section entirely for a tool that took no arguments — the header is already
 * saying what the tool did, and an empty `{}` under it is noise repeated once
 * per tool call.
 */
@Composable
fun ToolParametersBlock(
    parametersJson: String,
    modifier: Modifier = Modifier,
    exclude: Set<String> = emptySet(),
) {
    val filtered = remember(parametersJson, exclude) {
        filterParameters(parametersJson, exclude)
    }
    if (filtered.isBlank()) return

    var expanded by remember { mutableStateOf(false) }
    val pretty = remember(filtered) { JsonPretty.pretty(filtered) }

    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(6.dp))
                .clickable { expanded = !expanded }
                .padding(horizontal = 6.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = if (expanded) {
                    Icons.Filled.KeyboardArrowDown
                } else {
                    Icons.AutoMirrored.Filled.KeyboardArrowRight
                },
                contentDescription = null,
                tint = NalarDim,
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = "Arguments",
                style = MaterialTheme.typography.labelSmall,
                color = NalarDim,
                modifier = Modifier.testTag("tool_parameters_toggle"),
            )
        }
        if (expanded) {
            MonospaceBlock(
                text = pretty,
                modifier = Modifier
                    .padding(horizontal = 6.dp)
                    .padding(bottom = 6.dp)
                    .testTag("tool_parameters_body"),
            )
        }
    }
}

/**
 * Drops keys the card already visualises, so a diff card does not repeat the
 * whole edited file as raw JSON underneath the diff of it.
 *
 * Applies only when the parameters parse as an object; anything else is passed
 * through untouched, which is the same rule the web applies.
 */
internal fun filterParameters(parametersJson: String, exclude: Set<String>): String {
    val trimmed = parametersJson.trim()
    if (trimmed.isEmpty() || exclude.isEmpty()) return trimmed
    if (trimmed == "{}") return ""
    return try {
        val params = org.json.JSONObject(trimmed)
        if (params.length() == 0) return ""
        exclude.forEach { key -> params.remove(key) }
        if (params.length() == 0) "" else params.toString()
    } catch (_: Exception) {
        trimmed
    }
}

/**
 * A monospace, horizontally scrollable, whitespace-preserving text block.
 *
 * The horizontal scroll is not decoration: a build log has 200-column lines and
 * a `whiteSpace = PreWrap` alone reflows them into a paragraph, which turns a
 * stack trace into an unreadable smear.
 */
@Composable
fun MonospaceBlock(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = NalarText,
) {
    val scroll = rememberScrollState()
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(4.dp))
            .background(NalarCard)
            .horizontalScroll(scroll)
            .padding(horizontal = 8.dp, vertical = 6.dp),
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = color,
            softWrap = false,
        )
    }
}

/** A label above a section, e.g. `stdout`. */
@Composable
internal fun ToolSectionLabel(
    text: String,
    meta: String? = null,
    color: Color = NalarDim,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(NalarCard)
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            color = color,
            fontWeight = FontWeight.Medium,
        )
        if (meta != null) {
            Text(
                text = "  $meta",
                style = MaterialTheme.typography.labelSmall,
                color = NalarDim,
            )
        }
    }
}

/** The red `Error:` row every card shows instead of its payload. */
@Composable
internal fun ToolErrorRow(
    message: String,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 6.dp),
    ) {
        Text(
            text = "Error:",
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = NalarError,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = message,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarError,
            modifier = Modifier
                .weight(1f)
                .testTag("tool_card_error"),
        )
    }
}

/** A hairline between sections, matching the web's `border-t` on the body. */
@Composable
internal fun ToolDivider(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(NalarBorder),
    )
}

/** A two-column `key: value` row, for payloads with no better shape. */
@Composable
internal fun ToolKeyValue(
    key: String,
    value: String,
    modifier: Modifier = Modifier,
    valueColor: Color = NalarText,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 2.dp),
    ) {
        Text(
            text = key,
            style = MaterialTheme.typography.labelSmall,
            color = NalarDim,
            modifier = Modifier.width(96.dp),
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall,
            color = valueColor,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** A one-line bullet in a list body. */
@Composable
internal fun ToolBullet(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = NalarText,
    strikeThrough: Boolean = false,
) {
    Text(
        text = "• $text",
        style = MaterialTheme.typography.bodySmall,
        color = color,
        textDecoration = if (strikeThrough) TextDecoration.LineThrough else null,
        modifier = modifier.padding(horizontal = 8.dp, vertical = 1.dp),
    )
}

/** The frame a card body sits in, so the body has its own inset. */
@Composable
internal fun ToolBody(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = Color.Transparent,
        contentColor = NalarText,
    ) {
        Column(
            modifier = Modifier.padding(top = 2.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            content()
        }
    }
}
