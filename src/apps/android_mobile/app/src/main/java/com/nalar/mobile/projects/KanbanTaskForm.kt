package com.nalar.mobile.projects

/**
 * One column of a kanban board, as `GET .../kanban/columns` returns it.
 *
 * Only the three fields the create form has any use for. The wire also carries
 * `workspace_item_id`, `description` and `created_at`, and dropping them here is
 * deliberate: a form that cannot render a description is better than one that
 * carries a field it never draws and that then drifts from the server's shape.
 */
data class KanbanColumn(
    val id: String,
    val name: String,
    val position: Int,
) {
    /**
     * What the picker chip reads.
     *
     * The server's `name` is nullable, so a column created through the API
     * without one arrives as `""`. A blank chip is invisible and untappable,
     * so it gets the same wording the web's own column renderer falls back to
     * rather than an empty string.
     */
    val displayName: String
        get() = name.trim().ifEmpty { "Untitled column" }
}

/**
 * Everything the "New task" form collects, in one value.
 *
 * A single data class rather than a dozen `remember { mutableStateOf }` because
 * the submit path reads all of it at once and the tests read it without a
 * device: [buildKanbanTaskCreateMessage], [canSubmitKanbanTask] and
 * [ProjectsApi.createTaskBody] are all functions over this, so "the web's rules"
 * are assertions on a value rather than on a screen.
 *
 * Defaults are the *server's* defaults, not the web's last-tapped ones: an
 * untouched form here posts exactly what the web posts when the reader changes
 * nothing.
 */
data class KanbanTaskForm(
    val name: String = "",
    val description: String = "",
    /** Empty = "let the server auto-assign", which is what it does today. */
    val columnId: String = "",
    val tags: List<String> = emptyList(),
    /** Migration 070 — per-task cwd. Empty is the "no override" sentinel. */
    val cwd: String = "",
    val unattended: Boolean = false,
    /** Empty = "Default (top-level config)", which the server resolves. */
    val profile: String = "",
    /**
     * Whether the agent starts on the new card.
     *
     * The web's split button: the left half creates *and runs*, the caret menu
     * creates only. Both post to the same endpoint with a different `mode`.
     */
    val runAgent: Boolean = false,
    val useGitWorktree: Boolean = false,
    val worktreePath: String = "",
    val worktreeBaseBranch: String = "",
    /** Base64 data URLs, `||`-joined on the wire. See [ChatAttachment]. */
    val imageUrls: List<String> = emptyList(),
)

/**
 * Whether the form carries enough to create a card.
 *
 * A name and nothing else — the reverse of the memory form next door. A card
 * with no body is a perfectly good card: the board is where work is *planned*,
 * and a description is the prompt for a run nobody has asked for yet. The
 * server would accept an empty description too; this only stops an untitled
 * card reaching it.
 */
fun canSubmitKanbanTask(form: KanbanTaskForm): Boolean = form.name.isNotBlank()

/**
 * The `queue_message` the agent's first turn sees, for
 * `mode=create_and_run`.
 *
 * A line-for-line mirror of the web's `buildTaskCreateMessage`
 * (`src/apps/desktop/src/components/kanban/buildTaskCreateMessage.ts`), because
 * the two are not two formats — they are one format read by two clients, and an
 * agent that parses `Task :` but not `Task:` has no way to say so. The exact
 * contract, as documented there:
 *
 * ```
 * Task : <name>
 * Description: <description>   omitted when blank
 *                              blank line +
 * #Notes UseGitWorktree         only when the toggle is on
 * Path: <worktreePath>          only when on AND the path is non-empty
 * Base: <baseBranch>            only when on AND the ref is non-empty
 * ```
 *
 * [form.name] is trimmed because a card's name is trimmed everywhere else in
 * this app ([ProjectsApi.createTaskBody]) and a queue message that disagrees
 * with the card it came from is a confusing thing to debug from a board.
 */
fun buildKanbanTaskCreateMessage(form: KanbanTaskForm): String {
    val lines = mutableListOf("Task : ${form.name.trim()}")
    val description = form.description.trim()
    if (description.isNotEmpty()) {
        lines += "Description: $description"
    }
    if (form.useGitWorktree) {
        lines += ""
        lines += "#Notes UseGitWorktree"
        val path = form.worktreePath.trim()
        if (path.isNotEmpty()) {
            lines += "Path: $path"
        }
        val base = form.worktreeBaseBranch.trim()
        if (base.isNotEmpty()) {
            lines += "Base: $base"
        }
    }
    return lines.joinToString("\n")
}

/**
 * The server's own tag rules, applied before the POST.
 *
 * Mirrors `tags_validation.zig` (`validateAndNormalizeTags`) rather than
 * inventing a friendlier set: letters, digits, underscores and hyphens, at
 * most 50 characters, and case-insensitively unique. A tag this refuses is a
 * tag the server would have refused with a 400 and no field to point at, so the
 * check buys a same-screen answer instead of a round trip to be told what was
 * already obvious.
 */
object KanbanTags {
    /** `TAG_MAX_LENGTH` in `tags_validation.zig`. */
    const val MAX_LENGTH: Int = 50

    /**
     * The characters a tag may hold, as the server defines them.
     *
     * A `Char::isLetterOrDigit` would be the obvious spelling and would be
     * *wrong*: Kotlin counts every Unicode letter, and `é` is a letter here and
     * is rejected by the server's `[a-zA-Z0-9_-]`. Anything the phone accepts
     * and the server refuses is a create that fails with no field named.
     */
    private fun isAllowed(c: Char): Boolean =
        c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '_' || c == '-'

    /**
     * One cleaned tag, or null when there is nothing to add.
     *
     * A draft is trimmed and then checked, so `"  bug  "` becomes `"bug"` and
     * `"  ,  "` becomes nothing at all rather than a chip the server rejects.
     */
    fun sanitize(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.length > MAX_LENGTH) return null
        if (!trimmed.all { isAllowed(it) }) return null
        return trimmed
    }

    /**
     * Add [raw] to [tags] unless it is a duplicate.
     *
     * Case-insensitive, preserving the first spelling — the server's rule, and
     * the only one that makes `Bug` and `bug` a single chip rather than two
     * chips that collapse into one on the server.
     */
    fun add(tags: List<String>, raw: String): List<String> {
        val clean = sanitize(raw) ?: return tags
        if (tags.any { it.equals(clean, ignoreCase = true) }) return tags
        return tags + clean
    }

    /**
     * Split a field's contents on commas and add every complete tag.
     *
     * The web's chip input commits on Enter *or* comma, so typing
     * `"a, b,c"` and pressing Enter is three tags; this returns them plus the
     * empty remainder so the caller can clear the field.
     */
    fun commitDraft(tags: List<String>, draft: String): List<String> {
        var next = tags
        for (part in draft.split(',')) {
            next = add(next, part)
        }
        return next
    }

    /**
     * Drop a tag the server would not have accepted.
     *
     * Called on whatever the field held at submit time, so a tag typed and
     * never committed with Enter still reaches the card — the same belt-and-
     * suspenders the web gets from `commitDraft()` on the Save button's
     * mousedown.
     */
    fun normalize(tags: List<String>): List<String> {
        var next = emptyList<String>()
        for (tag in tags) {
            next = add(next, tag)
        }
        return next
    }
}

/**
 * The worktree paths this app proposes, and the slug that names one.
 *
 * Mirrors the web's `WORKTREE_DIR_SUFFIX` + `slugifyWorktreeName`
 * (`KanbanTaskDetail.vue:331-365`), because the agent's `set_git_worktree`
 * tool creates the directory and the two clients proposing different roots
 * would leave a reader unable to find half their worktrees.
 */
object KanbanWorktree {
    /** `$HOME`-relative; joined onto the server's home by [defaultPath]. */
    const val DIR_SUFFIX: String = ".config/nalar/.worktrees"

    /** Longest slug the web produces, so a name change here is a visible diff. */
    private const val MAX_SLUG_LENGTH: Int = 50

    /**
     * A filesystem-safe stem for [taskName].
     *
     * `ship the drawer` → `ship-the-drawer`, and a name that is nothing but
     * punctuation → `task`, because an empty directory name is not a path.
     */
    fun slugify(taskName: String): String {
        val slug = buildString {
            var lastWasDash = true // Leading dashes are stripped below anyway.
            for (c in taskName.trim().lowercase()) {
                if (c in 'a'..'z' || c in '0'..'9') {
                    append(c)
                    lastWasDash = false
                } else if (!lastWasDash) {
                    append('-')
                    lastWasDash = true
                }
            }
        }.trim('-')
        return slug.take(MAX_SLUG_LENGTH).ifEmpty { "task" }
    }

    /**
     * The prefill the web writes into the path field when the toggle flips on.
     *
     * [serverHome] is the **server's** home (`GET /api/system/folder`), not the
     * phone's: the agent runs wherever the backend runs, so the phone's own
     * `$HOME` would propose a path that does not exist on the machine that has
     * to create it. When it is still unknown — the fetch is in flight, or the
     * backend is down — this falls back to the same `~`-prefixed display the
     * web falls back to, and the field says the path must be absolute.
     */
    fun defaultPath(serverHome: String, taskName: String, nowMillis: Long): String {
        val home = serverHome.trim().trimEnd('/')
        val root = if (home.isEmpty()) "~/$DIR_SUFFIX" else "$home/$DIR_SUFFIX"
        return "$root/${slugify(taskName)}-$nowMillis"
    }
}
