package com.nalar.mobile.recents

private const val MILLIS_PER_MINUTE = 60_000L
private const val MILLIS_PER_HOUR = 60L * MILLIS_PER_MINUTE
private const val MILLIS_PER_DAY = 24L * MILLIS_PER_HOUR

data class WorkspaceOption(
    val id: String,
    val name: String,
) {
    val displayName: String
        get() = name.trim().ifEmpty { "Untitled workspace" }
}

/**
 * One recents row, carrying **two** timestamps because the sidebar needs two
 * different questions answered and they do not have the same answer.
 *
 * The desktop sidebar keeps them apart too (`ChatsList.vue` `toNavItem`):
 *
 * - [updatedAtEpochMillis] — the **order** key. The wire's `updated_at`, bumped
 *   by everything, so a session the agent is actively working floats to the top
 *   of Recent. This is the same value the server sorted the page by
 *   (`sort_by=updated_at&direction=desc`), which is what makes paging and
 *   local re-sorting agree.
 * - [lastHumanTouchedAtEpochMillis] — the **label** key. When the human last
 *   saw the chat, falling back to `updated_at` then `created_at`. A row must
 *   not claim "2m" just because the agent is mid-run and keeps touching
 *   `updated_at` — the human has not been there for an hour.
 *
 * Conflating them is not a simplification, it is a bug with a visible
 * symptom: sorted by the label key, a running session sinks below every chat
 * the human touched earlier and can never reach the top of the list.
 */
data class ChatSummary(
    val id: String,
    val workspaceId: String,
    val title: String,
    val updatedAtEpochMillis: Long,
    /**
     * Defaults to the order key so a row built without a human-touch stamp
     * degrades to the desktop's own fallback (`last_human_touched_at ||
     * updated_at`) rather than to "no label at all".
     */
    val lastHumanTouchedAtEpochMillis: Long = updatedAtEpochMillis,
) {
    val displayTitle: String
        get() = title.trim().ifEmpty { "New Chat" }

    /**
     * False when the backend sent no parseable timestamp at all (a legacy
     * session whose `created_at`/`updated_at` are empty strings). The row is
     * still shown, just without a relative label — rendering the epoch instead
     * would claim the chat is decades old. Read from the label key, because
     * the label is the only thing [hasTimestamp] gates.
     */
    val hasTimestamp: Boolean
        get() = lastHumanTouchedAtEpochMillis > 0L
}

/**
 * One page of recents, plus the fields the sidebar's scroll needs to decide
 * whether to ask for another one. See [RecentsApi.parseChatsPage] for why
 * [hasMore] — and not [nextCursor] — is the terminator.
 */
data class ChatsPage(
    val chats: List<ChatSummary>,
    val hasMore: Boolean,
    /** The server's own resume value. Hand it back verbatim; never synthesize. */
    val nextCursor: String?,
    /** Full filtered row count, 0 when the server did not report one. */
    val total: Int,
)

/**
 * Newest-activity first, workspace-scoped.
 *
 * Sorts on the **order** key ([ChatSummary.updatedAtEpochMillis]), never on the
 * human-touch label. That is what puts a session the agent is currently
 * working on at the top of the list, and it is the same order the server
 * paged in (`sort_by=updated_at&direction=desc`) — so appending a later page
 * and re-sorting the merged list cannot reshuffle rows the user already read.
 */
fun recentChatsForWorkspace(
    chats: List<ChatSummary>,
    workspaceId: String,
): List<ChatSummary> = chats
    .asSequence()
    .filter { it.workspaceId == workspaceId }
    .sortedWith(
        compareByDescending<ChatSummary> { it.updatedAtEpochMillis }
            .thenBy { it.id },
    )
    .toList()

fun formatRelativeTime(
    timestampEpochMillis: Long,
    nowEpochMillis: Long,
): String {
    val elapsedMillis = (nowEpochMillis - timestampEpochMillis).coerceAtLeast(0L)
    val minutes = elapsedMillis / MILLIS_PER_MINUTE
    if (minutes < 1L) return "now"

    val hours = minutes / 60L
    if (hours < 1L) return "${minutes}m"

    val days = hours / 24L
    if (days < 1L) return "${hours}h"

    val weeks = days / 7L
    if (weeks < 1L) return "${days}d"

    val months = days / 30L
    if (months < 1L) return "${weeks}w"

    val years = days / 365L
    if (years < 1L) return "${months}mo"

    return "${years}y"
}

fun formatRelativeTimeForAccessibility(
    timestampEpochMillis: Long,
    nowEpochMillis: Long,
): String {
    val elapsedMillis = (nowEpochMillis - timestampEpochMillis).coerceAtLeast(0L)
    val minutes = elapsedMillis / MILLIS_PER_MINUTE
    if (minutes < 1L) return "updated just now"

    val hours = minutes / 60L
    if (hours < 1L) {
        return "updated ${countWithUnit(minutes, "minute")} ago"
    }

    val days = hours / 24L
    if (days < 1L) {
        return "updated ${countWithUnit(hours, "hour")} ago"
    }

    val weeks = days / 7L
    if (weeks < 1L) {
        return "updated ${countWithUnit(days, "day")} ago"
    }

    val months = days / 30L
    if (months < 1L) {
        return "updated ${countWithUnit(weeks, "week")} ago"
    }

    val years = days / 365L
    if (years < 1L) {
        return "updated ${countWithUnit(months, "month")} ago"
    }

    return "updated ${countWithUnit(years, "year")} ago"
}

private fun countWithUnit(count: Long, unit: String): String =
    if (count == 1L) "1 $unit" else "$count ${unit}s"
