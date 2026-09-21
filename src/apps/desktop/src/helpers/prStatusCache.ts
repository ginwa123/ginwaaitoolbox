/**
 * Shared PR-status fetch for kanban card git-branch badges.
 *
 * Problem: a board mounts ~140 cards at once and every card fired its
 * own `GET /api/git/pr/status` (one `gh pr view` subprocess each).
 * Under that burst, transient failures (timeouts, 429/5xx from the
 * API) were common — and with no retry the badge stayed grey forever.
 *
 * This module collapses the burst:
 *   - in-flight dedupe: simultaneous callers for the same
 *     `cwd::branch` share one request (141 cards → ~30 unique
 *     branches → ~30 requests).
 *   - 60s TTL cache: remounts / "Load more" pages reuse the result
 *     instead of re-hammering `gh`. A merged PR shows its color on
 *     the next fetch after the TTL expires.
 *   - retry with backoff (2 retries): transient failures get a second
 *     chance. 404 (no PR for the branch — e.g. `main`) is
 *     deterministic and is NOT retried.
 *
 * Fail-silent contract is preserved: total failure resolves to `''`
 * and the card keeps its current dim look. Final failures go to
 * `console.warn` (devtools only) so the next grey-icon report comes
 * with evidence instead of silence.
 */
import { ApiError, getPrStatus } from '../api'

const TTL_MS = 60_000
const MAX_RETRIES = 2
const RETRY_DELAYS_MS = [300, 900]

interface CacheEntry {
  status: string
  at: number
}

const cache = new Map<string, CacheEntry>()
const inflight = new Map<string, Promise<string>>()

/** Test-only escape hatch — clears both the TTL cache and in-flight map. */
export function clearPrStatusCache(): void {
  cache.clear()
  inflight.clear()
}

function cacheKey(cwd: string, branch: string): string {
  return `${cwd}::${branch}`
}

/** 404 means "no PR for this branch" — retrying can never help. */
function isRetryable(err: unknown): boolean {
  if (err instanceof ApiError) return err.status !== 404
  // Network abort / timeout / TypeError — transient by definition.
  return true
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms))
}

async function fetchWithRetry(cwd: string, branch: string): Promise<string> {
  let lastErr: unknown = null
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) await sleep(RETRY_DELAYS_MS[attempt - 1] ?? 1000)
    try {
      const data = await getPrStatus(cwd, branch)
      return (data.status || data.state || '').toLowerCase()
    } catch (err) {
      lastErr = err
      if (!isRetryable(err)) break
    }
  }
  console.warn(`[pr-status] giving up on branch "${branch}":`, lastErr)
  return ''
}

/**
 * Lowercase PR status (`open` | `merged` | `closed`) for a repo + branch
 * (or a full PR URL), or `''` when unknown (no ref, branch lookup
 * without a cwd, no PR, `gh` missing, or the fetch kept failing).
 * Never rejects.
 *
 * Full URLs resolve without any local path (the backend skips its repo
 * check in URL mode), so callers may pass an empty cwd for them —
 * branch names still require one.
 */
export function fetchPrStatusCached(cwd: string, branch: string): Promise<string> {
  if (!branch) return Promise.resolve('')
  if (!cwd && !branch.includes('://')) return Promise.resolve('')
  const k = cacheKey(cwd, branch)
  const hit = cache.get(k)
  if (hit && Date.now() - hit.at < TTL_MS) return Promise.resolve(hit.status)
  const ongoing = inflight.get(k)
  if (ongoing) return ongoing
  const p = fetchWithRetry(cwd, branch).then(
    (status) => {
      cache.set(k, { status, at: Date.now() })
      inflight.delete(k)
      return status
    },
    () => {
      // Defensive: fetchWithRetry never rejects, but never leak the
      // in-flight slot if that invariant ever breaks.
      inflight.delete(k)
      return ''
    },
  )
  inflight.set(k, p)
  return p
}
