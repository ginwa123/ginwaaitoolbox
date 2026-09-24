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

export interface PrInfo {
  status: string
  prUrl: string
  mergeable: string
  merge_state: string
}

interface CacheEntry {
  status: string
  prUrl: string
  mergeable: string
  merge_state: string
  at: number
}

/** CONFLICTING (or DIRTY) means the PR cannot merge until conflicts resolve. */
export function isPrConflictValue(mergeable: string, merge_state: string): boolean {
  if ((mergeable || '').toUpperCase() === 'CONFLICTING') return true
  if ((merge_state || '').toUpperCase() === 'DIRTY') return true
  return false
}

const cache = new Map<string, CacheEntry>()
const inflight = new Map<string, Promise<PrInfo>>()

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

const EMPTY_INFO: PrInfo = { status: '', prUrl: '', mergeable: '', merge_state: '' }

async function fetchWithRetry(cwd: string, branch: string): Promise<PrInfo> {
  let lastErr: unknown = null
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) await sleep(RETRY_DELAYS_MS[attempt - 1] ?? 1000)
    try {
      const data = await getPrStatus(cwd, branch)
      return {
        status: (data.status || data.state || '').toLowerCase(),
        prUrl: data.pr_url || '',
        mergeable: (data.mergeable || '').toUpperCase(),
        merge_state: (data.merge_state || '').toUpperCase(),
      }
    } catch (err) {
      lastErr = err
      if (!isRetryable(err)) break
    }
  }
  console.warn(`[pr-status] giving up on branch "${branch}":`, lastErr)
  return { ...EMPTY_INFO }
}

/**
 * PR status + URL for a repo + branch. Never rejects — unknown
 * (no cwd/branch, no PR, `gh` missing, fetch failing) resolves to
 * `{ status: '', prUrl: '' }`.
 */
export function fetchPrInfoCached(cwd: string, branch: string): Promise<PrInfo> {
  if (!cwd || !branch) return Promise.resolve({ ...EMPTY_INFO })
  const k = cacheKey(cwd, branch)
  const hit = cache.get(k)
  if (hit && Date.now() - hit.at < TTL_MS)
    return Promise.resolve({
      status: hit.status,
      prUrl: hit.prUrl,
      mergeable: hit.mergeable,
      merge_state: hit.merge_state,
    })
  const ongoing = inflight.get(k)
  if (ongoing) return ongoing
  const p = fetchWithRetry(cwd, branch).then(
    (info) => {
      cache.set(k, {
        status: info.status,
        prUrl: info.prUrl,
        mergeable: info.mergeable,
        merge_state: info.merge_state,
        at: Date.now(),
      })
      inflight.delete(k)
      return info
    },
    () => {
      // Defensive: fetchWithRetry never rejects, but never leak the
      // in-flight slot if that invariant ever breaks.
      inflight.delete(k)
      return { ...EMPTY_INFO }
    },
  )
  inflight.set(k, p)
  return p
}

/**
 * Lowercase PR status (`open` | `merged` | `closed`) for a repo + branch,
 * or `''` when unknown (no cwd/branch, no PR, `gh` missing, or the fetch
 * kept failing). Never rejects.
 */
export function fetchPrStatusCached(cwd: string, branch: string): Promise<string> {
  return fetchPrInfoCached(cwd, branch).then((info) => info.status)
}

/**
 * Full cached PR status including the mergeable flag, so card/row badges
 * can surface a conflict hint without an extra `gh` call. Never rejects.
 */
export function fetchPrStatusFullCached(cwd: string, branch: string): Promise<PrInfo> {
  return fetchPrInfoCached(cwd, branch)
}

/**
 * Cached conflict flag for a repo + branch. True only when the PR reports
 * CONFLICTING (or DIRTY) — quiet (false) for mergeable, unknown, or failed
 * fetches. Never rejects.
 */
export function fetchPrConflictCached(cwd: string, branch: string): Promise<boolean> {
  return fetchPrInfoCached(cwd, branch).then((info) =>
    isPrConflictValue(info.mergeable, info.merge_state),
  )
}

/**
 * Repo base (https://github.com/owner/repo) derived from a PR URL
 * (https://github.com/owner/repo/pull/123). Empty string when the
 * URL is not a pull-request URL.
 */
export function repoBaseFromPrUrl(prUrl: string): string {
  if (!prUrl) return ''
  const idx = prUrl.indexOf('/pull/')
  if (idx < 0) return ''
  return prUrl.slice(0, idx)
}

/**
 * Branch page URL (…/tree/<branch>) derived from the PR URL's repo
 * base. Empty string when there is no PR URL to derive the repo from.
 */
export function branchUrlFromPrUrl(prUrl: string, branch: string): string {
  const base = repoBaseFromPrUrl(prUrl)
  if (!base || !branch) return ''
  return `${base}/tree/${encodeURIComponent(branch)}`
}
