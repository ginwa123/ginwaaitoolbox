package com.nalar.mobile.network

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarAqua
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarBackgroundRaised
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarError
import com.nalar.mobile.ui.NalarField
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText
import com.nalar.mobile.ui.NalarTheme

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NetworkInspectorScreen(
    onBack: () -> Unit,
    onOpenRecord: (Long) -> Unit,
    modifier: Modifier = Modifier,
    store: NetworkLogStore = NetworkLogStore.default,
    nowEpochMillis: () -> Long = System::currentTimeMillis,
) {
    val entries by store.entries.collectAsStateWithLifecycle()
    val isRecording by store.isRecording.collectAsStateWithLifecycle()

    var filter by rememberSaveable { mutableStateOf(NetworkEntryFilter.All) }
    var query by rememberSaveable { mutableStateOf("") }
    val visibleEntries = filterNetworkEntries(entries, filter, query)
    val summary = summarizeNetworkEntries(entries)

    Scaffold(
        modifier = modifier
            .fillMaxSize()
            .testTag("network_inspector"),
        containerColor = NalarBackground,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            text = "Network",
                            style = MaterialTheme.typography.titleMedium,
                            color = NalarText,
                        )
                        Text(
                            text = if (isRecording) "Recording" else "Paused",
                            style = MaterialTheme.typography.labelMedium,
                            color = if (isRecording) NalarAqua else NalarDim,
                        )
                    }
                },
                navigationIcon = {
                    IconButton(
                        onClick = onBack,
                        modifier = Modifier.testTag("network_back"),
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                            tint = NalarText,
                        )
                    }
                },
                actions = {
                    IconButton(
                        onClick = { store.setRecording(!isRecording) },
                        modifier = Modifier.testTag("network_toggle_recording"),
                    ) {
                        Icon(
                            imageVector = if (isRecording) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = if (isRecording) "Pause recording" else "Resume recording",
                            tint = NalarText,
                        )
                    }
                    IconButton(
                        onClick = { store.clear() },
                        modifier = Modifier.testTag("network_clear"),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.DeleteSweep,
                            contentDescription = "Clear captured requests",
                            tint = NalarText,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = NalarBackground,
                    navigationIconContentColor = NalarText,
                    titleContentColor = NalarText,
                    actionIconContentColor = NalarText,
                ),
            )
        },
    ) { contentPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(contentPadding),
        ) {
            SummaryStrip(summary = summary)

            FilterRow(
                selected = filter,
                onSelected = { next -> filter = next },
            )

            OutlinedTextField(
                value = query,
                onValueChange = { next -> query = next },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .testTag("network_search"),
                placeholder = { Text("Filter by path, method, status") },
                leadingIcon = {
                    Icon(
                        imageVector = Icons.Filled.Search,
                        contentDescription = null,
                        tint = NalarDim,
                    )
                },
                singleLine = true,
                shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = NalarText,
                    unfocusedTextColor = NalarText,
                    focusedBorderColor = NalarAccent,
                    unfocusedBorderColor = NalarBorder,
                    focusedContainerColor = NalarField,
                    unfocusedContainerColor = NalarField,
                    cursorColor = NalarAccent,
                ),
            )

            Spacer(Modifier.height(12.dp))

            if (visibleEntries.isEmpty()) {
                NetworkEmptyState(
                    hasRecords = entries.isNotEmpty(),
                    modifier = Modifier.weight(1f),
                )
            } else {
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .testTag("network_list"),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(
                        items = visibleEntries,
                        key = { entry -> entry.id },
                    ) { entry ->
                        NetworkRecordRow(
                            entry = entry,
                            nowEpochMillis = nowEpochMillis(),
                            onClick = { onOpenRecord(entry.id) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SummaryStrip(summary: NetworkSummary) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .testTag("network_summary"),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        SummaryMetric(value = summary.requestCount.toString(), label = "requests")
        SummaryMetric(value = summary.failedCount.toString(), label = "failed")
        SummaryMetric(value = formatBytes(summary.totalBytes), label = "transferred")
        SummaryMetric(value = formatDuration(summary.slowestMillis), label = "slowest")
    }
}

@Composable
private fun SummaryMetric(value: String, label: String) {
    Column {
        Text(
            text = value,
            style = MaterialTheme.typography.titleMedium,
            color = NalarText,
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = NalarDim,
        )
    }
}

@Composable
private fun FilterRow(
    selected: NetworkEntryFilter,
    onSelected: (NetworkEntryFilter) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        NetworkEntryFilter.entries.forEach { option ->
            val label = when (option) {
                NetworkEntryFilter.All -> "All"
                NetworkEntryFilter.Mutations -> "Mutations"
                NetworkEntryFilter.Failed -> "Failed"
            }
            FilterChip(
                selected = option == selected,
                onClick = { onSelected(option) },
                label = { Text(label) },
                modifier = Modifier.testTag("network_filter_${option.name.lowercase()}"),
                shape = RoundedCornerShape(12.dp),
                colors = FilterChipDefaults.filterChipColors(
                    containerColor = NalarBackgroundRaised,
                    labelColor = NalarMuted,
                    selectedContainerColor = NalarAccent.copy(alpha = 0.22f),
                    selectedLabelColor = NalarText,
                ),
                border = FilterChipDefaults.filterChipBorder(
                    enabled = true,
                    selected = option == selected,
                    borderColor = NalarBorder,
                    selectedBorderColor = NalarAccent.copy(alpha = 0.5f),
                ),
            )
        }
    }
}

@Composable
private fun NetworkRecordRow(
    entry: NetworkLogEntry,
    nowEpochMillis: Long,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("network_row_${entry.id}"),
        shape = RoundedCornerShape(14.dp),
        color = NalarBackgroundRaised,
        contentColor = NalarText,
        border = BorderStroke(1.dp, NalarBorder),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    MethodBadge(method = entry.method)
                    Text(
                        text = entry.displayPath,
                        style = MaterialTheme.typography.bodyLarge,
                        color = NalarText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Text(
                    text = buildString {
                        append(entry.label)
                        append(" · ")
                        append(entry.host)
                        append(" · ")
                        append(formatRecordAge(entry.startedAtEpochMillis, nowEpochMillis))
                    },
                    style = MaterialTheme.typography.labelMedium,
                    color = NalarDim,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Spacer(Modifier.width(12.dp))

            Column(
                horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Text(
                    text = entry.statusLabel,
                    style = MaterialTheme.typography.titleMedium,
                    color = statusColorOf(entry),
                )
                Text(
                    text = buildString {
                        append(formatDuration(entry.durationMillis))
                        append(" · ")
                        append(formatBytes(entry.totalBytes))
                    },
                    style = MaterialTheme.typography.labelMedium,
                    color = NalarDim,
                )
            }
        }
    }
}

@Composable
internal fun MethodBadge(method: String, modifier: Modifier = Modifier) {
    val normalized = method.uppercase()
    Box(
        modifier = modifier
            .background(methodColorOf(normalized), RoundedCornerShape(6.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(
            text = normalized,
            style = MaterialTheme.typography.labelMedium,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            color = NalarBackground,
        )
    }
}

internal fun methodColorOf(method: String): Color = when (method.uppercase()) {
    "GET" -> NalarAqua
    "POST" -> NalarAccent
    "PUT", "PATCH" -> NalarMuted
    "DELETE" -> NalarError
    else -> NalarDim
}

internal fun statusColorOf(entry: NetworkLogEntry): Color = when (statusClassOf(entry)) {
    NetworkStatusClass.Success -> NalarAqua
    NetworkStatusClass.Redirect -> NalarAccent
    NetworkStatusClass.ClientError -> NalarError
    NetworkStatusClass.ServerError -> NalarError
    NetworkStatusClass.Failure -> NalarError
}

@Composable
private fun NetworkEmptyState(
    hasRecords: Boolean,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp)
            .testTag("network_empty"),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                text = if (hasRecords) "No matching requests" else "No requests captured yet",
                modifier = Modifier.semantics { heading() },
                style = MaterialTheme.typography.titleMedium,
                color = NalarMuted,
            )
            Text(
                text = if (hasRecords) {
                    "Adjust the filter or the search text."
                } else {
                    "Every call the app makes appears here, including the sign-in POST."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = NalarDim,
            )
        }
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun NetworkInspectorPreview() {
    NalarTheme {
        NetworkInspectorScreen(
            onBack = {},
            onOpenRecord = {},
            store = NetworkLogStore.default,
        )
    }
}
