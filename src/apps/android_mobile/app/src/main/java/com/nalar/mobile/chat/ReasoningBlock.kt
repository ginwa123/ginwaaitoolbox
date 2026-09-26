package com.nalar.mobile.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarDim

/**
 * The header a collapsed reasoning block is drawn behind.
 *
 * "Thought", not "Reasoning", because that is what the web's `<summary>` says
 * (`ChatView.vue`, the `.assistant-reasoning` block) and the two clients are
 * deliberately kept word-for-word in step — a label the reader has to relearn
 * per platform is a label they will not bother to open.
 */
const val REASONING_LABEL = "Thought"

/** Leading rule marking the reasoning body, the web's `border-l-2`. */
private val reasoningRuleWidth = 2.dp

/**
 * Does this turn draw a reasoning block at all?
 *
 * An assistant turn only, mirroring the web, whose `.assistant-reasoning`
 * `<details>` sits in the assistant branch of the group template and nowhere
 * else. The reader's own bubble never gets one: they did not think anything,
 * and a "Thought" toggle over a question they just typed would be a control
 * that cannot do anything.
 */
fun showsReasoning(message: ChatMessage): Boolean =
    !message.isUser && message.reasoningContent.isNotBlank()

/**
 * The key this turn's reasoning block is filed under in [ToolExpansion].
 *
 * Namespaced, and it has to be. A tool card is filed under its own
 * `ToolCardModel.id`, which is the message id verbatim — so a bare `message.id`
 * here would mean that opening the reasoning on a turn also opened that turn's
 * tool card, and closing it closed both. The same trap the tool-call summary
 * header sidesteps with its `tool-calls-` prefix.
 */
fun reasoningKey(id: String): String = "reasoning-$id"

/**
 * The model chain of thought, folded away until the reader asks for it.
 *
 * The web's `<details class="assistant-reasoning">` (`ChatView.vue`), and the
 * two agree on the part that matters: **collapsed by default**, because a
 * thinking model emits reasoning for every turn and a run of them expanded
 * pushes the answer the reader actually came for off the bottom of the screen.
 * The fold is also the only affordance that makes reasoning skimmable at all —
 * rendered flat, as it was here, a long trace is a wall of monospace with no
 * way past it.
 *
 * The state is [ToolExpansion]'s rather than a local `remember`, for the same
 * reason the tool cards hoist theirs above the `LazyColumn`: this composable is
 * re-created every time the row is scrolled out of the viewport and back, so a
 * locally-remembered `expanded` would silently re-fold the moment the reader
 * scrolled away and back.
 */
@Composable
fun ReasoningBlock(
    message: ChatMessage,
    expansion: ToolExpansion,
    modifier: Modifier = Modifier,
) {
    if (!showsReasoning(message)) return
    val key = reasoningKey(message.id)
    val expanded = expansion.isExpanded(key)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag("chat_reasoning_${message.id}"),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expansion.toggle(key) }
                .testTag("chat_reasoning_header_${message.id}"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = REASONING_LABEL,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = NalarDim,
            )
            Spacer(Modifier.width(6.dp))
            Icon(
                imageVector = if (expanded) {
                    Icons.Filled.KeyboardArrowDown
                } else {
                    Icons.AutoMirrored.Filled.KeyboardArrowRight
                },
                contentDescription = if (expanded) "Collapse" else "Expand",
                tint = NalarDim,
                modifier = Modifier.testTag("chat_reasoning_chevron_${message.id}"),
            )
        }

        if (expanded) {
            Spacer(Modifier.height(4.dp))
            Text(
                text = message.reasoningContent,
                style = MaterialTheme.typography.bodySmall,
                color = NalarDim,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier
                    // The web's `border-l-2 pl-3` on the reasoning body. It is
                    // what keeps a screenful of trace visually separate from the
                    // answer underneath it without boxing either one.
                    .drawBehind {
                        drawRect(
                            color = NalarBorder,
                            size = Size(reasoningRuleWidth.toPx(), size.height),
                        )
                    }
                    .padding(start = 10.dp)
                    .testTag("chat_reasoning_body_${message.id}"),
            )
        }
    }
}
