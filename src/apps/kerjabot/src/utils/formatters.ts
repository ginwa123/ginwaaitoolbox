/**
 * Pure formatting utility functions
 * Functional programming approach with no side effects
 */

/** Format timestamp to relative time */
export const formatRelativeTime = (date: Date): string => {
  const now = new Date();
  const diff = now.getTime() - date.getTime();
  const seconds = Math.floor(diff / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  if (seconds < 60) return 'just now';
  if (minutes < 60) return `${minutes}m ago`;
  if (hours < 24) return `${hours}h ago`;
  if (days < 7) return `${days}d ago`;
  return formatDate(date);
};

/** Format date to locale string */
export const formatDate = (date: Date): string => {
  return date.toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    year: date.getFullYear() !== new Date().getFullYear() ? 'numeric' : undefined,
  });
};

/** Format date with time */
export const formatDateTime = (date: Date): string => {
  return date.toLocaleString('en-US', {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
};

/** Format duration in milliseconds to human readable */
export const formatDuration = (ms: number): string => {
  if (ms < 1000) return `${ms}ms`;
  const seconds = Math.floor(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = seconds % 60;
  return `${minutes}m ${remainingSeconds}s`;
};

/** Format token count with commas */
export const formatTokenCount = (count: number): string => {
  return count.toLocaleString('en-US');
};

/** Format file size */
export const formatFileSize = (bytes: number): string => {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(1))} ${sizes[i]}`;
};

/** Truncate text with ellipsis */
export const truncateText = (text: string, maxLength: number): string => {
  if (text.length <= maxLength) return text;
  return text.substring(0, maxLength - 3) + '...';
};

/** Format code block for display */
export const formatCodeBlock = (code: string, language?: string): string => {
  return language ? `${language}\n${code}` : code;
};

/** Format agent name for display */
export const formatAgentName = (name: string): string => {
  return name
    .split(' ')
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase())
    .join(' ');
};

/** Format message preview */
export const formatMessagePreview = (content: string, maxLength = 100): string => {
  // Remove code blocks and extra whitespace
  const cleaned = content
    .replace(/```[\s\S]*?```/g, '[code]')
    .replace(/\s+/g, ' ')
    .trim();
  return truncateText(cleaned, maxLength);
};

/** Format tool name for display */
export const formatToolName = (name: string): string => {
  return name
    .split('_')
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');
};
