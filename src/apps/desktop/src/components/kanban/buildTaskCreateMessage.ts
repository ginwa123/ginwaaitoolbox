/**
 * Build the `create_and_run` user message.
 *
 * Format contract:
 *   Task : <name>
 *   Description: <description>   <- omitted when empty/whitespace
 *                                  <- blank line +
 *   #Notes UseGitWorktree         <- only when useGitWorktree is true
 *
 * Pure function — no Vue, no store, trivially unit-testable. The
 * caller (KanbanView.handleCreateTaskSave) passes the already-trimmed
 * task name; the description is trimmed here so whitespace-only
 * input degrades to the name-only form.
 */
export function buildTaskCreateMessage(
  name: string,
  description: string,
  useGitWorktree: boolean,
): string {
  const lines: string[] = [`Task : ${name}`]
  const desc = description.trim()
  if (desc !== '') {
    lines.push(`Description: ${desc}`)
  }
  if (useGitWorktree) {
    lines.push('', '#Notes UseGitWorktree')
  }
  return lines.join('\n')
}
