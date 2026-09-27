/**
 * Query-string contract for the three skills HTTP calls.
 *
 * The skills store moved from the filesystem to a `skills` table keyed on
 * (is_global, cwd, name), so `cwd` is no longer optional information: a
 * local delete without it is unresolvable and the backend answers 400.
 * That makes the query string — not the resolved body — the thing worth
 * pinning, which is what these tests assert.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

import { deleteSkill, getSkillDetail, getSkills, ApiError } from '@/api/index'

const CWD = '/work/my repo'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

type FetchCall = [input: string, init: RequestInit]

function callOf(fetchSpy: ReturnType<typeof vi.fn>, index = 0): FetchCall {
  return fetchSpy.mock.calls[index] as FetchCall
}

function requestedUrl(call: FetchCall): URL {
  return new URL(call[0], 'http://localhost')
}

function fetchMock(): ReturnType<typeof vi.fn> {
  return vi.fn(async () => jsonResponse({}))
}

describe('skills query strings', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('deleteSkill threads cwd into the query string', async () => {
    const fetchSpy = fetchMock()
    vi.stubGlobal('fetch', fetchSpy)
    await deleteSkill('my-skill', { is_global: false, cwd: CWD })

    const call = callOf(fetchSpy)
    const url = requestedUrl(call)
    expect(url.pathname).toBe('/api/skills')
    expect(url.searchParams.get('name')).toBe('my-skill')
    expect(url.searchParams.get('is_global')).toBe('false')
    // The literal `cwd=` the backend parses — URLSearchParams percent-
    // encodes the slashes, so assert on the query string too.
    expect(url.search).toContain('cwd=')
    expect(url.searchParams.get('cwd')).toBe(CWD)
    expect(call[1]).toMatchObject({ method: 'DELETE' })
  })

  it('deleteSkill omits cwd when the caller has none, so the backend 400s', async () => {
    const fetchSpy = fetchMock()
    vi.stubGlobal('fetch', fetchSpy)
    await deleteSkill('my-skill', { is_global: false })

    const url = requestedUrl(callOf(fetchSpy))
    expect(url.search).not.toContain('cwd=')
    expect(url.searchParams.get('is_global')).toBe('false')
  })

  it('getSkills passes cwd, and omits the query entirely without it', async () => {
    const fetchSpy = fetchMock()
    vi.stubGlobal('fetch', fetchSpy)
    await getSkills(CWD)
    expect(requestedUrl(callOf(fetchSpy)).searchParams.get('cwd')).toBe(CWD)

    await getSkills()
    expect(requestedUrl(callOf(fetchSpy, 1)).search).toBe('')
  })

  it('getSkillDetail passes cwd and encodes the skill name', async () => {
    const fetchSpy = fetchMock()
    vi.stubGlobal('fetch', fetchSpy)
    await getSkillDetail('my skill', CWD)

    const url = requestedUrl(callOf(fetchSpy))
    expect(url.pathname).toBe('/api/skills/my%20skill')
    expect(url.searchParams.get('cwd')).toBe(CWD)
  })

  it('a local delete with no cwd rejects with the reason in the error body', async () => {
    // apiFetch throws on non-2xx, so `error_message` never reaches
    // SkillDetail.vue as a resolved field — it lives in ApiError.body,
    // which is why the component parses the body before showing it.
    const message = 'cwd query parameter is required for local skill deletion'
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        jsonResponse(
          { success: false, skill_name: 'my-skill', deleted_from: null, error_message: message },
          400,
        ),
      ),
    )

    const err = await deleteSkill('my-skill', { is_global: false }).catch((e: unknown) => e)
    expect(err).toBeInstanceOf(ApiError)
    expect((err as ApiError).status).toBe(400)
    expect(JSON.parse((err as ApiError).body).error_message).toBe(message)
  })
})
