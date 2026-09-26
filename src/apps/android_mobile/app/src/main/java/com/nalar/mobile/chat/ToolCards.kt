package com.nalar.mobile.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.unit.dp
import com.nalar.mobile.ui.NalarAccentSoft
import com.nalar.mobile.ui.NalarAqua
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarCard
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarError
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText
import org.json.JSONArray
import java.util.Locale

/**
 * A tool row, rendered.
 *
 * The dispatch is a `when` over [ToolCardModel.kind] rather than a chain of
 * `v-else-if` equivalents: a new tool is one new branch here and one new
 * [ToolKind], and an unhandled tool cannot fall through to nothing because
 * [ToolKind.Raw] catches it explicitly.
 */
@Composable
fun ToolCardView(
    model: ToolCardModel,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    onAnswer: (QuestionAnswer) -> Unit = {},
) {
    // A card with neither a body nor any arguments has nothing to reveal, so
    // its header is a label rather than a button. A *placeholder* row is in
    // exactly that state — `data: null` on a success — and its arguments are
    // the only thing it has to say, so "no body" must never be read as "no
    // arguments".
    val hasArguments = model.parametersJson.isNotBlank()
    val hasBody = model.body !is ToolBody.Empty
    val expandable = hasBody || hasArguments

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(6.dp))
            // The web's "paragraph mode": no box, just a left rule that colours
            // on error. A dozen boxed cards in a row read as a wall.
            .border(1.dp, CardBorderColor(model), RoundedCornerShape(6.dp))
            .testTag("tool_card_${model.kind.name.lowercase(Locale.ROOT)}"),
    ) {
        ToolCardHeader(
            toolName = model.label,
            primary = model.primary,
            rightMeta = model.rightMeta,
            success = model.success,
            running = model.pending,
            expanded = expanded,
            expandable = expandable,
            onToggle = onToggle,
        )

        if (expanded && hasBody) {
            ToolDivider()
            ToolBody {
                val error = model.errorText
                if (error != null) {
                    ToolErrorRow(message = error)
                } else {
                    ToolBodyFor(model, onAnswer)
                }
            }
        }

        // Outside the `hasBody` block on purpose: a running tool's arguments
        // live here and nowhere else, because its body is empty by definition.
        if (expanded && hasArguments) {
            ToolParametersBlock(
                parametersJson = model.parametersJson,
                exclude = model.excludedParameters,
            )
        }
    }
}

/** The left rule recolours on failure, exactly as the web's card border does. */
@Composable
private fun CardBorderColor(model: ToolCardModel): Color = when {
    model.pending -> NalarDim
    model.success -> NalarBorder
    else -> Color(0xFF6B3A38)
}

@Composable
private fun ToolBodyFor(model: ToolCardModel, onAnswer: (QuestionAnswer) -> Unit) {
    when (val body = model.body) {
        is ToolBody.ReadFile -> ReadFileBody(body)
        is ToolBody.WriteFile -> WriteFileBody(body)
        is ToolBody.Shell -> ShellBody(body)
        is ToolBody.Search -> SearchBody(body)
        is ToolBody.Glob -> GlobBody(body)
        is ToolBody.ListDirectory -> ListDirectoryBody(body)
        is ToolBody.Diff -> DiffBody(body)
        is ToolBody.Plan -> PlanBody(body)
        is ToolBody.Question -> QuestionCard(body, model.toolCallId, onAnswer)
        is ToolBody.SubAgentSpawn -> SubAgentSpawnBody(body)
        is ToolBody.SubAgentCatalog -> SubAgentCatalogBody(body)
        is ToolBody.MemorySave -> MemorySaveBody(body)
        is ToolBody.MemoryLoad -> MemoryLoadBody(body)
        is ToolBody.MemoryList -> MemoryListBody(body)
        is ToolBody.SkillList -> SkillListBody(body)
        is ToolBody.SkillUse -> SkillUseBody(body)
        is ToolBody.SkillMutation -> SkillMutationBody(body)
        is ToolBody.KanbanMove -> KanbanMoveBody(body)
        is ToolBody.KanbanList -> KanbanListBody(body)
        is ToolBody.PresentFiles -> PresentFilesBody(body)
        is ToolBody.GenerateImage -> GenerateImageBody(body)
        is ToolBody.Worktree -> WorktreeBody(body)
        is ToolBody.SessionReader -> SessionReaderBody(body)
        is ToolBody.ProgressiveTool -> ProgressiveBody(body)
        is ToolBody.Mcp -> MonospaceBlock(text = body.text)
        is ToolBody.Raw -> MonospaceBlock(text = body.text, color = NalarMuted)
        ToolBody.Empty -> Unit
    }
}

@Composable
private fun ReadFileBody(body: ToolBody.ReadFile) {
    val lines = body.lines
    if (lines.isEmpty()) {
        Text(
            text = "(empty)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 6.dp)
                .testTag("read_file_empty"),
        )
        return
    }
    val first = body.firstLineNumber
    val scroll = rememberScrollState()
    // `read_file` reads the whole file with no cap on the wire, and one `Row`
    // plus two `Text`s per line is three composables per line — a 5,000-line
    // file is 15,000 composables inside a single `LazyColumn` item, which
    // defeats the virtualization the whole transcript is built on. Beyond the
    // cap the reader is told what it is not seeing and can ask for the rest.
    var showAll by remember(body.path) { mutableStateOf(false) }
    val visible = if (showAll) lines else lines.take(MAX_RENDERED_FILE_LINES)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(NalarCard)
            .horizontalScroll(scroll)
            .padding(vertical = 4.dp)
            .testTag("read_file_body"),
    ) {
        visible.forEachIndexed { index, line ->
            Row {
                Text(
                    text = (first + index).toString(),
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = NalarDim,
                    modifier = Modifier
                        .width(44.dp)
                        .padding(end = 8.dp),
                )
                Text(
                    // A blank line still needs a glyph, or the row collapses to
                    // zero height and the gutter stops lining up with the text.
                    text = line.ifEmpty { " " },
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = NalarText,
                    softWrap = false,
                )
            }
        }
        if (visible.size < lines.size) {
            Text(
                text = "… ${lines.size - visible.size} more lines — tap to show them",
                style = MaterialTheme.typography.labelSmall,
                color = NalarDim,
                modifier = Modifier
                    .padding(horizontal = 8.dp, vertical = 4.dp)
                    .clickable { showAll = true }
                    .testTag("read_file_show_more"),
            )
        }
    }
}

/** How many lines of a read result are composed before the card offers more. */
private const val MAX_RENDERED_FILE_LINES = 500

@Composable
private fun WriteFileBody(body: ToolBody.WriteFile) {
    if (body.path.isBlank()) return
    ToolKeyValue(key = "wrote", value = body.path)
}

@Composable
private fun ShellBody(body: ToolBody.Shell) {
    if (body.stdout.isNotEmpty()) {
        ToolSectionLabel(
            text = "stdout",
            meta = "${body.stdoutLines}L",
            color = NalarAccentSoft,
        )
        MonospaceBlock(
            text = body.stdout,
            modifier = Modifier.testTag("shell_stdout"),
        )
    }
    if (body.hasStderr) {
        ToolSectionLabel(
            text = "stderr",
            meta = "${body.stderrLines}L",
            color = NalarError,
        )
        MonospaceBlock(
            text = body.stderr,
            color = NalarError,
            modifier = Modifier.testTag("shell_stderr"),
        )
    }
    if (body.stdout.isEmpty() && !body.hasStderr) {
        Text(
            text = if (body.timedOut) "(timed out)" else "(no output)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun SearchBody(body: ToolBody.Search) {
    if (body.warning != null) {
        ToolKeyValue(key = "warning", value = body.warning, valueColor = NalarMuted)
    }
    if (body.truncatedHint != null) {
        ToolKeyValue(key = "truncated", value = body.truncatedHint, valueColor = NalarMuted)
    }
    if (body.files.isEmpty()) {
        Text(
            text = "(no matches)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
        return
    }
    body.files.forEach { file ->
        Column(modifier = Modifier.padding(top = 4.dp)) {
            Text(
                text = file.path,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                color = NalarAccentSoft,
                modifier = Modifier.padding(horizontal = 8.dp),
            )
            file.matches.forEach { match ->
                Row(modifier = Modifier.padding(horizontal = 8.dp, vertical = 1.dp)) {
                    Text(
                        text = match.line.toString().padStart(5),
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = FontFamily.Monospace,
                        color = NalarDim,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = match.text.trimEnd(),
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        color = NalarText,
                        softWrap = false,
                    )
                }
            }
        }
    }
}

@Composable
private fun GlobBody(body: ToolBody.Glob) {
    if (body.warning != null) {
        ToolKeyValue(key = "warning", value = body.warning, valueColor = NalarMuted)
    }
    if (body.files.isEmpty()) {
        Text(
            text = "(no matches)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
        return
    }
    body.files.forEach { path ->
        Text(
            text = path,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarText,
            softWrap = false,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 1.dp)
                .testTag("glob_path"),
        )
    }
    if ((body.truncated ?: 0) > 0 || body.truncatedBySize) {
        Text(
            text = "+${body.truncated ?: 0} more dropped",
            style = MaterialTheme.typography.labelSmall,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
        )
    }
}

@Composable
private fun ListDirectoryBody(body: ToolBody.ListDirectory) {
    if (body.entries.isEmpty()) {
        Text(
            text = "(empty)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
        return
    }
    body.entries.forEach { entry ->
        Text(
            text = buildString {
                append(if (entry.isDirectory) "📁 " else "  ")
                append(entry.name)
                if (entry.isSymlink) append(" →")
            },
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = if (entry.isDirectory) NalarAccentSoft else NalarText,
            softWrap = false,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 1.dp)
                .testTag("dir_entry"),
        )
    }
}

@Composable
private fun DiffBody(body: ToolBody.Diff) {
    // `unified` is the backend's own rendering when it supplied one; a client
    // that re-diffs `before`/`after` and disagrees with the server is worse
    // than one that just shows the server's answer.
    if (body.unified.isNotBlank()) {
        MonospaceBlock(text = body.unified)
        return
    }
    DiffView(before = body.before, after = body.after)
}

/**
 * Two-sided diff, in transcript order.
 *
 * A phone cannot show the web's side-by-side split and stay legible, so this is
 * a single column: the line number that moved, the sign, the text. Colour alone
 * would leave it unreadable to a colour-blind reader, which is why each row
 * also carries a `+` / `-` / ` ` marker.
 */
@Composable
fun DiffView(
    before: String,
    after: String,
    modifier: Modifier = Modifier,
) {
    val rows = remember(before, after) { ToolDiff.compute(before, after) }
    if (rows.isEmpty()) {
        Text(
            text = "(no change)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
        return
    }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(NalarCard)
            .padding(vertical = 4.dp)
            .testTag("diff_view"),
    ) {
        rows.forEach { row ->
            val color = when (row.kind) {
                DiffRowKind.Added -> Color(0xFF2F3A2F)
                DiffRowKind.Removed -> Color(0xFF3A2A2A)
                DiffRowKind.Context -> Color.Transparent
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(color),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = (row.beforeLine ?: row.afterLine ?: 0).toString(),
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = NalarDim,
                    modifier = Modifier
                        .width(40.dp)
                        .padding(end = 4.dp),
                )
                Text(
                    text = when (row.kind) {
                        DiffRowKind.Added -> "+"
                        DiffRowKind.Removed -> "-"
                        DiffRowKind.Context -> " "
                    },
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold,
                    color = when (row.kind) {
                        DiffRowKind.Added -> Color(0xFF87A987)
                        DiffRowKind.Removed -> NalarError
                        DiffRowKind.Context -> NalarDim
                    },
                )
                Text(
                    text = row.text.ifEmpty { " " },
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = NalarText,
                    softWrap = false,
                )
            }
        }
    }
}

@Composable
private fun PlanBody(body: ToolBody.Plan) {
    body.updatedAt?.let {
        ToolKeyValue(key = "updated", value = it)
    }
    if (body.empty) {
        Text(
            text = "(no plan yet)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 6.dp)
                .testTag("plan_empty"),
        )
        return
    }
    val lines = body.lines
    if (lines.isEmpty()) return
    Column(
        modifier = Modifier.padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        lines.forEach { line ->
            when (line.kind) {
                ToolBody.ChecklistLine.ChecklistKind.Checked -> ToolBullet(
                    text = "☑  ${line.text}",
                    color = NalarMuted,
                    strikeThrough = true,
                )

                ToolBody.ChecklistLine.ChecklistKind.Unchecked -> ToolBullet(
                    text = "☐  ${line.text}",
                )

                ToolBody.ChecklistLine.ChecklistKind.Text -> Text(
                    text = line.text,
                    style = MaterialTheme.typography.bodySmall,
                    color = NalarText,
                    modifier = Modifier
                        .padding(horizontal = 8.dp, vertical = 1.dp)
                        .testTag("plan_line"),
                )
            }
        }
    }
}

/**
 * One `ask_user` reply, ready to post.
 *
 * A value rather than four loose parameters because it is built in a composable
 * and consumed in a ViewModel two frames away, and a positional `(String, String,
 * Boolean)` at that distance is a swap waiting to happen.
 */
data class QuestionAnswer(
    val questionId: String?,
    val toolCallId: String,
    val answer: String?,
    val skip: Boolean = false,
)

/**
 * A blocking `ask_user` question, rendered with the affordance to answer it.
 *
 * The default-collapsed rule is inverted here, matching the web: every other
 * card is detail supporting a message, but this one *is* the message — the run
 * has ended and nothing happens until the reader answers. A collapsed card the
 * reader has to guess the meaning of is a chat that looks hung.
 */
@Composable
private fun QuestionCard(
    body: ToolBody.Question,
    toolCallId: String,
    onAnswer: (QuestionAnswer) -> Unit,
) {
    var draft by remember(body.questionId) { mutableStateOf("") }
    // Selection is local: nothing is posted until the reader confirms, and
    // `multi_select` turns one answer into several, which is a decision the card
    // owns rather than the wire.
    var selected by remember(body.questionId) { mutableStateOf(emptySet<String>()) }
    val canSubmit = body.isPending && (selected.isNotEmpty() || draft.isNotBlank())

    body.header?.let { ToolKeyValue(key = "header", value = it) }

    Text(
        text = body.question,
        style = MaterialTheme.typography.bodyMedium,
        fontWeight = FontWeight.Medium,
        color = NalarText,
        modifier = Modifier
            .padding(horizontal = 8.dp, vertical = 6.dp)
            .testTag("question_text"),
    )

    if (body.options.isNotEmpty()) {
        body.options.forEach { option ->
            val isSelected = option in selected
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(6.dp))
                    .background(if (isSelected) SELECTED_OPTION else Color.Transparent)
                    .clickable(enabled = body.isPending) {
                        selected = when {
                            !body.multiSelect -> setOf(option)
                            isSelected -> selected - option
                            else -> selected + option
                        }
                    }
                    .padding(horizontal = 8.dp, vertical = 6.dp)
                    .testTag("question_option"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = if (isSelected) "◉" else "○",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (isSelected) NalarAccentSoft else NalarDim,
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = option,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = NalarText,
                    modifier = Modifier.weight(1f),
                )
                if (option == body.recommended) {
                    Text(
                        text = "recommended",
                        style = MaterialTheme.typography.labelSmall,
                        color = NalarAqua,
                    )
                }
            }
        }
    }

    if (body.allowFreeText && body.isPending) {
        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            label = { Text("Your answer") },
            singleLine = false,
            maxLines = 4,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 4.dp)
                .testTag("question_input"),
        )
    }

    if (body.isPending) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "The run is stopped until this is answered.",
                style = MaterialTheme.typography.labelSmall,
                color = BLOCKING,
                modifier = Modifier
                    .weight(1f)
                    .testTag("question_blocked_note"),
            )
            TextButton(
                onClick = { onAnswer(QuestionAnswer(body.questionId, toolCallId, null, skip = true)) },
                modifier = Modifier.testTag("question_skip"),
            ) {
                Text("Skip", color = NalarMuted)
            }
            TextButton(
                onClick = {
                    onAnswer(
                        QuestionAnswer(
                            questionId = body.questionId,
                            toolCallId = toolCallId,
                            answer = encodeAnswer(selected, draft, body.multiSelect),
                        ),
                    )
                },
                enabled = canSubmit,
                modifier = Modifier.testTag("question_send"),
            ) {
                Text("Answer", color = NalarAccentSoft)
            }
        }
    } else {
        // One branch, one answer row. Rendering it in both the input block and
        // the status block drew "answer: sqlite" twice on every settled card.
        ToolKeyValue(
            key = "answer",
            value = body.answer
                ?: when (body.status) {
                    ToolBody.Question.STATUS_SKIPPED -> "skipped"
                    ToolBody.Question.STATUS_ABANDONED -> "abandoned"
                    ToolBody.Question.STATUS_UNAVAILABLE -> "unavailable"
                    else -> "not answered"
                },
            valueColor = if (body.answer != null) NalarAqua else NalarMuted,
        )
    }

    body.instruction?.let {
        Text(
            text = it,
            style = MaterialTheme.typography.labelSmall,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
        )
    }
}

/**
 * The `answer` string the endpoint expects.
 *
 * `validateAnswerShape` (`ask_user_answer.zig`) parses the answer itself as
 * JSON when `multi_select` is set, so a multi-select reply has to be an array
 * of strings. Sending `"postgres, sqlite"` gets a 400, the run stays blocked,
 * and the only way out is Skip — which throws the answer away. Pure, so the
 * wire contract is testable without a device.
 */
internal fun encodeAnswer(
    selected: Set<String>,
    draft: String,
    multiSelect: Boolean,
): String? {
    if (multiSelect) {
        if (selected.isEmpty()) return draft.trim().ifEmpty { null }
        return JSONArray(selected.toList()).toString()
    }
    // A tapped option wins over whatever is in the text field: that is the one
    // the reader just chose, and a question may offer both.
    if (selected.isNotEmpty()) return selected.first()
    return draft.trim().ifEmpty { null }
}

@Composable
private fun SubAgentSpawnBody(body: ToolBody.SubAgentSpawn) {
    body.results.forEach { result ->
        Text(
            text = buildString {
                append(if (result.success) "✓ " else "✗ ")
                append(result.name.ifEmpty { "(unnamed)" })
                result.error?.let { append(" — ").append(it) }
            },
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = if (result.success) NalarText else NalarError,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 2.dp)
                .testTag("sub_agent_result"),
        )
        // The whole point of spawning a sub-agent is its response; a card that
        // only shows the ok/fail line throws away the answer.
        result.response?.takeIf { it.isNotBlank() }?.let { response ->
            MonospaceBlock(
                text = response,
                color = NalarMuted,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
            )
        }
    }
}

@Composable
private fun SubAgentCatalogBody(body: ToolBody.SubAgentCatalog) {
    if (body.profile.isNotBlank()) ToolKeyValue(key = "profile", value = body.profile)
    body.agents.forEach { agent ->
        ToolKeyValue(
            key = agent.name,
            value = listOf(agent.model, agent.thinking)
                .filter { it.isNotBlank() }
                .joinToString(" · "),
        )
    }
}

@Composable
private fun MemorySaveBody(body: ToolBody.MemorySave) {
    if (body.id.isNotBlank()) ToolKeyValue(key = "id", value = body.id)
}

@Composable
private fun MemoryLoadBody(body: ToolBody.MemoryLoad) {
    body.results.forEach { hit ->
        Column(modifier = Modifier.padding(vertical = 3.dp)) {
            Text(
                text = hit.id,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace,
                color = NalarAccentSoft,
                modifier = Modifier.padding(horizontal = 8.dp),
            )
            Text(
                text = hit.snippet,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = NalarText,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 1.dp),
            )
        }
    }
    if (body.results.isEmpty()) {
        Text(
            text = "(no memories matched)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun MemoryListBody(body: ToolBody.MemoryList) {
    if (body.memories.isEmpty()) {
        Text(
            text = "(no memories stored)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
        return
    }
    body.memories.forEach { memory ->
        Text(
            text = buildString {
                append(memory.title.ifEmpty { memory.id })
                if (memory.sizeBytes > 0) {
                    append("  ·  ")
                    append(formatBytes(memory.sizeBytes))
                }
            },
            style = MaterialTheme.typography.bodySmall,
            color = NalarText,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 1.dp)
                .testTag("memory_entry"),
        )
    }
}

@Composable
private fun SkillListBody(body: ToolBody.SkillList) {
    SkillBlock(label = "global", entries = body.global)
    SkillBlock(label = "project", entries = body.local)
}

@Composable
private fun SkillBlock(label: String, entries: List<ToolBody.SkillEntry>) {
    if (entries.isEmpty()) return
    ToolSectionLabel(text = label, meta = entries.size.toString(), color = NalarAccentSoft)
    entries.forEach { entry ->
        Column(modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)) {
            Text(
                text = entry.name,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = NalarText,
            )
            if (entry.description.isNotBlank()) {
                Text(
                    text = entry.description,
                    style = MaterialTheme.typography.labelSmall,
                    color = NalarMuted,
                )
            }
        }
    }
}

@Composable
private fun SkillUseBody(body: ToolBody.SkillUse) {
    if (body.content.isNotBlank()) {
        MonospaceBlock(text = body.content)
    } else if (!body.loaded) {
        Text(
            text = "(the skill body was empty)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun SkillMutationBody(body: ToolBody.SkillMutation) {
    body.path?.let { ToolKeyValue(key = "path", value = it) }
    if (!body.changed) {
        Text(
            text = "(nothing changed)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun KanbanMoveBody(body: ToolBody.KanbanMove) {
    ToolKeyValue(key = "column", value = body.columnName.ifEmpty { "(unknown)" })
    ToolKeyValue(key = "position", value = body.position.toString())
}

@Composable
private fun KanbanListBody(body: ToolBody.KanbanList) {
    if (body.columns.isNotEmpty()) {
        ToolSectionLabel(text = "columns", color = NalarAccentSoft)
        body.columns.forEach { column ->
            ToolKeyValue(key = column.name, value = "${column.taskCount} task(s)")
        }
    }
    if (body.tasks.isNotEmpty()) {
        ToolSectionLabel(text = "tasks", meta = body.tasks.size.toString(), color = NalarAccentSoft)
        body.tasks.forEach { task ->
            Text(
                text = buildString {
                    append("• ")
                    append(task.name)
                    task.columnName?.let { append("  [").append(it).append("]") }
                },
                style = MaterialTheme.typography.bodySmall,
                color = NalarText,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 1.dp),
            )
        }
    }
    if (body.hasMore) {
        Text(
            text = "more tasks exist; narrow the query to see them",
            style = MaterialTheme.typography.labelSmall,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
        )
    }
}

@Composable
private fun PresentFilesBody(body: ToolBody.PresentFiles) {
    body.files.forEach { file ->
        ToolKeyValue(
            key = file.label.ifEmpty { file.path.substringAfterLast('/') },
            value = buildString {
                append(file.path)
                if (file.bytes > 0) {
                    append("  ·  ")
                    append(formatBytes(file.bytes))
                }
            },
        )
    }
    if (body.files.isEmpty()) {
        Text(
            text = "(no files)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = NalarDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun GenerateImageBody(body: ToolBody.GenerateImage) {
    if (body.model.isNotBlank()) ToolKeyValue(key = "model", value = body.model)
    if (body.size.isNotBlank()) ToolKeyValue(key = "size", value = body.size)
    body.images.forEach { image ->
        ToolKeyValue(key = "image ${image.index}", value = image.path)
    }
    body.revisedPrompt?.let { ToolKeyValue(key = "revised", value = it) }
}

@Composable
private fun WorktreeBody(body: ToolBody.Worktree) {
    body.branch?.let { ToolKeyValue(key = "branch", value = it) }
    body.base?.let { ToolKeyValue(key = "base", value = it) }
    body.note?.let { ToolKeyValue(key = "note", value = it, valueColor = NalarMuted) }
}

@Composable
private fun SessionReaderBody(body: ToolBody.SessionReader) {
    when (body.behavior) {
        "list" -> body.sessions.forEach { session ->
            Column(modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)) {
                Text(
                    text = session.name.ifEmpty { session.path },
                    style = MaterialTheme.typography.bodySmall,
                    color = NalarText,
                )
                if (session.description.isNotBlank()) {
                    Text(
                        text = session.description,
                        style = MaterialTheme.typography.labelSmall,
                        color = NalarMuted,
                    )
                }
            }
        }

        "search" -> body.results.forEach { result ->
            Column(modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)) {
                Text(
                    text = result.path,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = NalarAccentSoft,
                )
                result.matches.forEach { match ->
                    Text(
                        text = match.text,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        color = NalarText,
                    )
                }
            }
        }

        // `read` returns whole messages, which the generic renderer shows.
        else -> MonospaceBlock(text = "(${body.count} message(s), ${body.totalCount} total)")
    }
}

@Composable
private fun ProgressiveBody(body: ToolBody.ProgressiveTool) {
    if (body.description.isNotBlank()) {
        Text(
            text = body.description,
            style = MaterialTheme.typography.bodySmall,
            color = NalarMuted,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 4.dp)
                .testTag("progressive_description"),
        )
    }
    body.tools.forEach { tool ->
        Column(modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)) {
            Text(
                text = tool.name,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = NalarText,
            )
            if (tool.description.isNotBlank()) {
                Text(
                    text = tool.description,
                    style = MaterialTheme.typography.labelSmall,
                    color = NalarMuted,
                )
            }
        }
    }
}

/** 1234 → "1.2 KB". Decimal units, because that is what a file manager shows. */
internal fun formatBytes(bytes: Long): String {
    if (bytes < 1000) return "$bytes B"
    val units = listOf("KB", "MB", "GB", "TB")
    var value = bytes.toDouble() / 1000.0
    var index = 0
    while (value >= 1000 && index < units.lastIndex) {
        value /= 1000.0
        index++
    }
    return String.format(Locale.ROOT, "%.1f %s", value, units[index])
}

/**
 * The keys a card already draws, so the Arguments block does not repeat them.
 *
 * `text_replace` is the one that matters: its `old_str`/`new_str` are the whole
 * file's worth of text, and the card is already showing them as a diff.
 */
internal val ToolCardModel.excludedParameters: Set<String>
    get() = when (kind) {
        ToolKind.Diff -> setOf("old_str", "new_str", "before", "after")
        ToolKind.ReadFile -> setOf("content")
        else -> emptySet()
    }

/**
 * The amber the whole client uses for "waiting on something outside the run":
 * a `running…` badge, a pending question's warning, a placeholder card's rule.
 *
 * Named so the three reads of "in flight but not failing" cannot drift apart.
 */
internal val BLOCKING = Color(0xFFD8B96A)

/** A selected option row, against the card's own background. */
private val SELECTED_OPTION = Color(0xFF2C2A33)
