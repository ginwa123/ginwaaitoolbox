// Format a date string to relative time (e.g., "5m", "2h", "3d", "1w", "6mo", "2y")
export const formatRelativeTime = (dateWillBeRelative: string): string => {
  if (!dateWillBeRelative || dateWillBeRelative.trim() === '') return 'now'

  // Handle SQLite datetime format: "YYYY-MM-DD HH:MM:SS" -> "YYYY-MM-DDTHH:MM:SS"
  const normalizedDate = dateWillBeRelative.replace(' ', 'T')

  // Parse as UTC
  const date = new Date(normalizedDate + 'Z') // Append 'Z' to treat as UTC

  // Check if date is valid
  if (isNaN(date.getTime())) return 'now'

  const now = new Date() // Keep current behavior (local time comparison)
  const diffMs = now.getTime() - date.getTime()
  const diffSec = Math.floor(diffMs / 1000)
  const diffMin = Math.floor(diffSec / 60)
  const diffHour = Math.floor(diffMin / 60)
  const diffDay = Math.floor(diffHour / 24)
  const diffWeek = Math.floor(diffDay / 7)
  const diffMonth = Math.floor(diffDay / 30)
  const diffYear = Math.floor(diffDay / 365)

  if (diffSec < 60) return 'now'
  if (diffMin < 60) return `${diffMin}m`
  if (diffHour < 24) return `${diffHour}h`
  if (diffDay < 7) return `${diffDay}d`
  if (diffMonth < 12) return `${diffWeek}w`
  if (diffYear < 12) return `${diffMonth}mo`
  return `${diffYear}y`
}

