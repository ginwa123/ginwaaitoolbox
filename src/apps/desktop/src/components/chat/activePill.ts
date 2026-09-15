/** Pure helper: which rail pill is active for a given visible range. No DOM. */

export interface PillIndex {
  groupIndex: number
}

/**
 * Returns the groupIndex of the last pill at or above the topmost
 * visible item (`rangeStart`), or null when no pill is above the
 * viewport (user hasn't scrolled to their first message yet).
 * `pills` must be sorted ascending by groupIndex (as ChatView builds them).
 */
export function pickActivePillIndex(
  pills: readonly PillIndex[],
  rangeStart: number,
): number | null {
  let active: number | null = null
  for (const pill of pills) {
    if (pill.groupIndex <= rangeStart) active = pill.groupIndex
    else break
  }
  return active
}
