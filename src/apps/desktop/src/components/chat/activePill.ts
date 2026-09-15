/** Pure helper: which rail pill is active for a given visible range. No DOM. */

export interface PillIndex {
  groupIndex: number
}

/**
 * Whether a message group deserves a rail pill. Real user turns only:
 * background completions are `role=user` on the wire but render as
 * left-aligned tool cards (never the blue bubble), and compaction
 * envelopes are system artifacts — neither is a user turn to jump to.
 */
export function isPillGroup(role: string, isBgOnly: boolean, isCompaction: boolean): boolean {
  return role === 'user' && !isBgOnly && !isCompaction
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
