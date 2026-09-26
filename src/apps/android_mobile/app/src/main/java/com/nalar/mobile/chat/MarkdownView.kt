package com.nalar.mobile.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nalar.mobile.ui.NalarAccentSoft
import com.nalar.mobile.ui.NalarAqua
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarField
import com.nalar.mobile.ui.NalarText

/** Body copy: the web's `text-sm`, which is `0.875rem`. */
private const val BODY_SIZE = 14

/** `line-height: 1.6` on the web; 22sp on 14sp type is the same ratio. */
private const val BODY_LINE_HEIGHT = 22

/** Inline and fenced code: the web's `0.875em`. */
private const val CODE_SIZE = 12

/**
 * Draws a parsed message.
 *
 * The metrics are the web's `.markdown-content` rules (`style.css`), converted
 * from rem to sp. The mapping is one-to-one on purpose: the answer is the same
 * document on both surfaces, and a heading that is 1.25rem on the web and 19sp
 * on the phone reads as two different documents.
 *
 *   web                        here
 *   ----------------------     ---------------------------------------
 *   h1 1.5rem / 700            20sp SemiBold, hairline rule under
 *   h2 1.25rem / 600           18sp SemiBold, hairline rule under
 *   h3 1.1rem / 600            15sp SemiBold
 *   h4-h6 1rem / 600           14sp SemiBold
 *   body 0.875rem / 1.6        14sp, 22sp line height
 *   code 0.875em               12sp mono, aqua on a raised surface
 *   pre                        raised surface, 1dp border, 8dp radius
 *   table                      12sp, hairline grid, raised header
 *   blockquote                 italic, 3dp rule, 12dp inset
 *
 * The parse is `remember`ed on the source string rather than recomputed per
 * recomposition: a streaming turn re-composes on every appended delta, and a
 * full markdown parse of a growing answer is the expensive half of drawing it.
 */
@Composable
fun MarkdownText(
    source: String,
    color: Color = NalarText,
    modifier: Modifier = Modifier,
) {
    val content = remember(source) { stripContentEnvelope(source) }
    val blocks = remember(content) { Markdown.parse(content) }
    if (blocks.isEmpty()) return

    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag("markdown"),
    ) {
        blocks.forEachIndexed { index, block ->
            MarkdownBlock(block, color, isLast = index == blocks.lastIndex)
        }
    }
}

@Composable
private fun MarkdownBlock(block: MdBlock, color: Color, isLast: Boolean) {
    when (block) {
        is MdBlock.Heading -> Column {
            Spacer(Modifier.height(10.dp))
            Text(
                text = block.spans.toAnnotatedString(color, headingSize(block.level)),
                style = MaterialTheme.typography.bodyMedium,
                fontSize = headingSize(block.level).sp,
                lineHeight = (headingSize(block.level) * 1.4f).sp,
                fontWeight = FontWeight.SemiBold,
                color = color,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("markdown_h${block.level}"),
            )
            // h1 and h2 carry a rule on the web; the rest do not.
            if (block.level <= 2) {
                Spacer(Modifier.height(4.dp))
                HorizontalDivider(color = NalarBorder, thickness = 1.dp)
            }
            Spacer(Modifier.height(4.dp))
        }

        is MdBlock.Paragraph -> Column {
            Spacer(Modifier.height(if (isLast) 0.dp else 8.dp))
            Text(
                text = block.spans.toAnnotatedString(color),
                style = MaterialTheme.typography.bodyMedium,
                fontSize = BODY_SIZE.sp,
                lineHeight = BODY_LINE_HEIGHT.sp,
                color = color,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("markdown_p"),
            )
        }

        is MdBlock.ListBlock -> Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 12.dp, top = 4.dp)
                .testTag("markdown_list"),
        ) {
            block.items.forEachIndexed { index, item ->
                if (index > 0) Spacer(Modifier.height(2.dp))
                Row(modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = if (block.ordered) "${block.start + index}." else "•",
                        style = MaterialTheme.typography.bodyMedium,
                        fontSize = BODY_SIZE.sp,
                        lineHeight = BODY_LINE_HEIGHT.sp,
                        color = NalarDim,
                        modifier = Modifier.width(20.dp),
                    )
                    Text(
                        text = item.toAnnotatedString(color),
                        style = MaterialTheme.typography.bodyMedium,
                        fontSize = BODY_SIZE.sp,
                        lineHeight = BODY_LINE_HEIGHT.sp,
                        color = color,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
            Spacer(Modifier.height(if (isLast) 0.dp else 8.dp))
        }

        is MdBlock.Code -> CodeBlock(block, color)

        is MdBlock.Quote -> QuoteBlock(block, isLast)

        is MdBlock.Table -> TableBlock(block, color, isLast)

        MdBlock.Rule -> Column {
            Spacer(Modifier.height(12.dp))
            HorizontalDivider(color = NalarBorder, thickness = 1.dp)
            Spacer(Modifier.height(12.dp))
        }
    }
}

/**
 * A blockquote.
 *
 * The web's `border-left: 3px` becomes a 3dp bar, which means the bar has to be
 * as tall as the text it marks — hence `IntrinsicSize.Min` on the row, letting
 * the bar `fillMaxHeight` instead of being a fixed-height divider that no longer
 * lines up once the quote wraps to three lines.
 */
@Composable
private fun QuoteBlock(block: MdBlock.Quote, isLast: Boolean) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .padding(top = 4.dp, bottom = if (isLast) 0.dp else 8.dp)
            .testTag("markdown_quote"),
    ) {
        Box(
            modifier = Modifier
                .width(3.dp)
                .fillMaxHeight()
                .clip(RoundedCornerShape(2.dp))
                .background(NalarAccentSoft),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            block.blocks.forEach { child ->
                if (child is MdBlock.Paragraph) {
                    Text(
                        text = child.spans.toAnnotatedString(NalarDim),
                        style = MaterialTheme.typography.bodyMedium,
                        fontSize = BODY_SIZE.sp,
                        lineHeight = BODY_LINE_HEIGHT.sp,
                        fontStyle = FontStyle.Italic,
                        color = NalarDim,
                    )
                } else {
                    MarkdownBlock(child, NalarDim, isLast = true)
                }
            }
        }
    }
}

/**
 * A fenced code block.
 *
 * Scrolls horizontally rather than wrapping, because a wrapped shell command
 * is unreadable — the continuation is indistinguishable from the next line. The
 * web does the same (`overflow-x: auto` on `.markdown-content pre`).
 */
@Composable
private fun CodeBlock(block: MdBlock.Code, color: Color) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 4.dp, bottom = 8.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(NalarField)
            .testTag("markdown_code"),
    ) {
        block.language?.takeIf { it.isNotBlank() }?.let { language ->
            Text(
                text = language,
                style = MaterialTheme.typography.labelSmall,
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
                color = NalarDim,
                modifier = Modifier.padding(start = 12.dp, top = 6.dp),
            )
        }
        Box(modifier = Modifier.horizontalScroll(rememberScrollState())) {
            Text(
                text = block.code,
                style = MaterialTheme.typography.bodySmall,
                fontSize = CODE_SIZE.sp,
                lineHeight = (CODE_SIZE * 1.45f).sp,
                fontFamily = FontFamily.Monospace,
                color = color,
                modifier = Modifier
                    .padding(horizontal = 12.dp, vertical = 10.dp)
                    .testTag("markdown_code_body"),
            )
        }
    }
}

/**
 * A pipe table.
 *
 * A phone is narrow, so the row scrolls rather than squeezing: three columns at
 * a third of a 360dp screen is 120dp of unreadable ellipsis per cell. The header
 * is filled and the cells are hairline-ruled to match
 * `.markdown-content th, td`.
 */
@Composable
private fun TableBlock(block: MdBlock.Table, color: Color, isLast: Boolean) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 4.dp, bottom = if (isLast) 0.dp else 8.dp)
            .testTag("markdown_table"),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
        ) {
            block.header.forEach { cell ->
                TableCell(cell, color, isHeader = true)
            }
        }
        block.rows.forEach { row ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
            ) {
                // Pad a short row out to the header's width rather than letting
                // the last column vanish, which is how a two-cell row under a
                // three-cell header used to render.
                repeat(block.header.size) { column ->
                    TableCell(
                        spans = row.getOrNull(column).orEmpty(),
                        color = color,
                        isHeader = false,
                    )
                }
            }
        }
    }
}

@Composable
private fun TableCell(spans: List<MdSpan>, color: Color, isHeader: Boolean) {
    Text(
        text = spans.toAnnotatedString(color, 12f),
        style = MaterialTheme.typography.labelSmall,
        fontSize = 12.sp,
        lineHeight = 17.sp,
        fontWeight = if (isHeader) FontWeight.SemiBold else FontWeight.Normal,
        color = color,
        modifier = Modifier
            // A fixed width keeps a short cell from collapsing to a few
            // characters once the row is allowed to be wider than the screen.
            .width(112.dp)
            .background(if (isHeader) NalarField else Color.Transparent)
            .padding(horizontal = 8.dp, vertical = 6.dp),
    )
}

private fun headingSize(level: Int): Float = when (level) {
    1 -> 20f
    2 -> 18f
    3 -> 15f
    else -> BODY_SIZE.toFloat()
}

/**
 * Spans → one `AnnotatedString`.
 *
 * Code spans get the mono face and the aqua ink the web gives inline `code`; a
 * link gets the accent colour and an underline, which on a read-only bubble is
 * the only affordance available short of a click handler.
 */
private fun List<MdSpan>.toAnnotatedString(
    color: Color,
    size: Float = BODY_SIZE.toFloat(),
): AnnotatedString =
    buildAnnotatedString {
        this@toAnnotatedString.forEach { span ->
            // A zero-length run would still open a style span, and Compose
            // applies the last style to the text after it — so it is skipped.
            if (span.text.isEmpty()) return@forEach
            pushStyle(
                SpanStyle(
                    color = when {
                        span.code -> NalarAqua
                        span.link != null -> NalarAccentSoft
                        else -> color
                    },
                    fontSize = if (span.code) (size * 0.875f).sp else size.sp,
                    fontFamily = if (span.code) FontFamily.Monospace else null,
                    fontWeight = if (span.bold) FontWeight.SemiBold else null,
                    fontStyle = if (span.italic) FontStyle.Italic else null,
                    textDecoration = when {
                        span.strike -> TextDecoration.LineThrough
                        span.link != null -> TextDecoration.Underline
                        else -> null
                    },
                ),
            )
            append(span.text)
            pop()
        }
    }
