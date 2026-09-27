package com.nalar.mobile.chat

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarError
import com.nalar.mobile.ui.NalarField
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText

/**
 * The chat's composer, built as the card the web's is: one bordered rounded
 * surface holding the text, the paperclip and the stop control on the first
 * row, a divider, and the turn's facts on the second.
 *
 * ### What is a control here and what is not
 *
 * The web's footer row is five dropdowns. A phone has four of those wired to
 * nothing, and a dropdown that opens an empty menu is worse than no dropdown —
 * it teaches the reader that the footer is decoration. So the footer's facts
 * (the model, the working directory) are rendered as *text*, and the only
 * thing in the row that is a button is the one that genuinely does something:
 * the chevron that expands a truncated `cwd` to the whole path.
 *
 * The chevron is drawn only when there is a `cwd` to expand. A permanently
 * mounted expander is a control that lies about whether anything is hidden.
 *
 * ### The stop control lives here, not in the app bar
 *
 * It replaced the top-bar stop, so there is exactly one answer to "can I stop
 * this run". Two of them disagreeing — one present, one gone, during a
 * reconnect — is the same lie told twice, and a reader who has learned to
 * distrust the composer distrusts the send button too.
 *
 * ### Why `BasicTextField` and not `TextField`
 *
 * `TextField` draws its own container and indicator, and there is no way to
 * remove both without leaving a rounded grey block inside a rounded bordered
 * card — two frames for one input. The card is the frame here, so the field
 * draws text and a cursor and nothing else.
 */
@Composable
internal fun ChatComposer(
    draft: String,
    attachments: List<ChatAttachment>,
    isSending: Boolean,
    isAttaching: Boolean,
    isWorking: Boolean,
    model: String,
    cwd: String,
    onDraftChanged: (String) -> Unit,
    onAttach: () -> Unit,
    onRemoveAttachment: (String) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // Remembered so the lambdas are current without re-composing the field on
    // every parent recomposition, which is what a plain capture would cost on
    // a streaming turn.
    val onDraft by rememberUpdatedState(onDraftChanged)
    val onAttachNow by rememberUpdatedState(onAttach)
    val onRemoveNow by rememberUpdatedState(onRemoveAttachment)
    val onSendNow by rememberUpdatedState(onSend)
    val onStopNow by rememberUpdatedState(onStop)

    val canSend = (draft.isNotBlank() || attachments.isNotEmpty()) && !isSending

    Column(
        modifier = modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            // Above the keyboard, not behind it. `adjustResize` is declared in
            // the manifest, but on API 30+ that no longer resizes the window —
            // the IME overlap arrives as an inset instead, so this is the line
            // that keeps the composer reachable while the reader types.
            .imePadding()
            .background(NalarBackground)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = NalarBackground,
            border = BorderStroke(1.dp, NalarBorder),
            modifier = Modifier.testTag("chat_composer"),
        ) {
            Column(modifier = Modifier.padding(start = 14.dp, end = 8.dp, top = 4.dp, bottom = 4.dp)) {
                AttachmentStrip(
                    attachments = attachments,
                    isAttaching = isAttaching,
                    onRemove = onRemoveNow,
                )

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Bottom,
                ) {
                    BasicTextField(
                        value = draft,
                        onValueChange = onDraft,
                        modifier = Modifier
                            .weight(1f)
                            .heightIn(min = 44.dp)
                            .padding(vertical = 10.dp)
                            .testTag("chat_composer_input"),
                        textStyle = MaterialTheme.typography.bodyMedium.copy(color = NalarText),
                        cursorBrush = SolidColor(NalarText),
                        maxLines = 5,
                        // A phone keyboard's action key would be a *newline*
                        // here, matching the web's textarea. The send button is
                        // the send; a keyboard that sends on Enter is a
                        // surprise on a device where Enter is also how you
                        // finish a sentence.
                        decorationBox = { inner ->
                            Box(modifier = Modifier.fillMaxWidth()) {
                                if (draft.isEmpty()) {
                                    Text(
                                        text = "Message",
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = NalarDim,
                                    )
                                }
                                inner()
                            }
                        },
                    )

                    Spacer(Modifier.width(4.dp))

                    IconButton(
                        onClick = onAttachNow,
                        // A decode is in flight, or there is no room left.
                        // Both states refuse the tap, and the reason is on the
                        // control rather than in a toast.
                        enabled = !isAttaching && attachments.size < ChatAttachments.MAX_COUNT,
                        modifier = Modifier
                            .size(40.dp)
                            .testTag("chat_attach"),
                    ) {
                        if (isAttaching) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                color = NalarDim,
                                strokeWidth = 2.dp,
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Filled.AttachFile,
                                contentDescription = "Attach an image",
                                tint = if (attachments.size < ChatAttachments.MAX_COUNT) {
                                    NalarMuted
                                } else {
                                    NalarDim
                                },
                            )
                        }
                    }

                    Spacer(Modifier.width(2.dp))

                    // One slot, two controls. The stop replaces the send rather
                    // than sitting beside it, so the row never offers both
                    // "start a turn" and "end a turn" at once.
                    if (isWorking) {
                        IconButton(
                            onClick = onStopNow,
                            modifier = Modifier
                                .size(40.dp)
                                .testTag("chat_stop"),
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Stop,
                                contentDescription = "Stop the run",
                                tint = NalarError,
                            )
                        }
                    } else {
                        // The circle is decoration; the tag is on the control
                        // inside it. A `testTag` on the `Surface` describes a
                        // container that has no enabled state of its own, so
                        // every assertion about whether send is available was
                        // reading a node that could never answer.
                        Surface(
                            modifier = Modifier.size(36.dp),
                            color = if (canSend) NalarAccent else NalarField,
                            shape = CircleShape,
                        ) {
                            IconButton(
                                onClick = onSendNow,
                                enabled = canSend,
                                modifier = Modifier
                                    .fillMaxSize()
                                    .testTag("chat_send"),
                            ) {
                                Icon(
                                    imageVector = Icons.Filled.ArrowUpward,
                                    contentDescription = "Send message",
                                    tint = if (canSend) NalarBackground else NalarDim,
                                )
                            }
                        }
                    }
                }

                HorizontalDivider(
                    thickness = 1.dp,
                    color = NalarBorder.copy(alpha = 0.7f),
                )

                ComposerFooter(model = model, cwd = cwd)
            }
        }
    }
}

/**
 * The attached images, as removable thumbnails.
 *
 * Laid out above the text rather than inline with it, because the text field
 * is a fixed height and a chip row beside it would steal width from the only
 * thing on this card the reader came here to use.
 *
 * The row scrolls horizontally rather than wrapping: a wrapped second line
 * pushes the send button down as each image is added, so the target the reader
 * is aiming at moves *while* they are aiming at it.
 */
@Composable
private fun AttachmentStrip(
    attachments: List<ChatAttachment>,
    isAttaching: Boolean,
    onRemove: (String) -> Unit,
) {
    if (attachments.isEmpty() && !isAttaching) return

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(top = 8.dp, bottom = 2.dp)
            .testTag("chat_attachments_strip"),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        attachments.forEach { attachment ->
            AttachmentThumbnail(
                attachment = attachment,
                onRemove = { onRemove(attachment.id) },
            )
        }
    }
}

/**
 * One thumbnail with a remove button on its corner.
 *
 * The image is decoded from the same base64 the turn will send, rather than
 * from a separate cached copy of the file: the reader's check that they picked
 * the right screenshot is a check of the bytes that are about to go, and a
 * thumbnail of a *different* copy is a thumbnail that can lie.
 *
 * A decode that fails renders as a labelled placeholder rather than an empty
 * box — a 56dp hole in the strip reads as a broken layout, and "image" at
 * least tells the reader the attachment is still there to be removed.
 */
@Composable
private fun AttachmentThumbnail(
    attachment: ChatAttachment,
    onRemove: () -> Unit,
) {
    Box(modifier = Modifier.size(56.dp).testTag("chat_attachment_${attachment.id}")) {
        val bitmap = remember(attachment.dataUrl) { attachment.thumbnail() }
        if (bitmap != null) {
            Image(
                bitmap = bitmap,
                contentDescription = "Attached image",
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(56.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(NalarField),
            )
        } else {
            Box(
                modifier = Modifier
                    .size(56.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(NalarField),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "image",
                    style = MaterialTheme.typography.labelSmall,
                    color = NalarDim,
                )
            }
        }

        Surface(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(2.dp)
                .size(20.dp)
                .clip(CircleShape),
            color = NalarBackground,
            shape = CircleShape,
        ) {
            IconButton(
                onClick = onRemove,
                modifier = Modifier
                    .size(20.dp)
                    .testTag("chat_attachment_remove_${attachment.id}"),
            ) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = "Remove image",
                    tint = NalarMuted,
                    modifier = Modifier.size(12.dp),
                )
            }
        }
    }
}

/**
 * The turn's facts, under a divider.
 *
 * Read-only by design — see [ChatComposer]. Every value here is a fact the
 * ViewModel already holds, and rendering it as text is the honest version of
 * the web's dropdown for a client that has nothing to change it to.
 */
@Composable
private fun ComposerFooter(model: String, cwd: String) {
    // Nothing to expand means no expander: a chevron that toggles one line
    // when both lines are already visible is a control that does nothing.
    val canExpand = cwd.isNotBlank()
    var expanded by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(36.dp)
            .padding(start = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (model.isNotBlank()) {
            FooterFact(label = "Model", value = model, tag = "chat_footer_model")
            Spacer(Modifier.width(12.dp))
        }
        if (canExpand) {
            FooterFact(
                label = "Cwd",
                value = cwd,
                // Collapsed is the *short* form with a leading ellipsis, which
                // is what a phone-width row can afford; expanded shows the
                // path from the root, because the part a reader needs is
                // usually the leaf and never the home directory.
                maxLines = if (expanded) 3 else 1,
                tag = "chat_footer_cwd",
            )
        }

        Spacer(Modifier.weight(1f))

        if (canExpand) {
            IconButton(
                onClick = { expanded = !expanded },
                modifier = Modifier
                    .size(32.dp)
                    .testTag("chat_footer_expand")
                    .semantics {
                        contentDescription = if (expanded) "Hide the working directory" else "Show the working directory"
                    },
            ) {
                Icon(
                    imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = null,
                    tint = NalarDim,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

/**
 * One labelled fact in the footer.
 *
 * The label is a fixed-width prefix rather than a trailing dim suffix, so two
 * facts on one row start their values at the same x — the alternative is two
 * values that begin wherever their labels happened to end, which reads as
 * misalignment on a row this short.
 */
@Composable
private fun FooterFact(
    label: String,
    value: String,
    maxLines: Int = 1,
    tag: String,
) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.testTag(tag)) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = NalarDim,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.width(4.dp))
        Text(
            text = value,
            style = MaterialTheme.typography.labelSmall,
            color = NalarMuted,
            maxLines = maxLines,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
