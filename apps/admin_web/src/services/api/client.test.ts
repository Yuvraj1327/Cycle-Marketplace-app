import { describe, expect, it, vi } from 'vitest'
import { ApiError, buildUrl, createApiClient } from './client'

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

function client(fetchImpl: typeof fetch, extra: Partial<Parameters<typeof createApiClient>[0]> = {}) {
  return createApiClient({ baseUrl: 'http://x/api/v1', getToken: async () => 'tok-1', fetchImpl, ...extra })
}

const fail = (p: Promise<unknown>) => p.then(() => { throw new Error('expected the request to fail') }, (e: unknown) => e as ApiError)

describe('api client', () => {
  it('builds URLs without empty filters', () => {
    expect(buildUrl('http://x', '/a', { q: '', page: 2, status: undefined, in_stock: false, n: null })).toBe('http://x/a?page=2&in_stock=false')
    expect(buildUrl('http://x', '/a')).toBe('http://x/a')
  })

  it('sends the Bearer token and JSON bodies', async () => {
    const f = vi.fn(async () => json(200, { ok: 1 }))
    await client(f as unknown as typeof fetch).post('/p', { a: 1 })
    const [url, init] = f.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toBe('http://x/api/v1/p')
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer tok-1')
    expect((init.headers as Record<string, string>)['Content-Type']).toBe('application/json')
    expect(init.body).toBe('{"a":1}')
  })

  it('maps the backend error envelope, including validation details', async () => {
    const f = async () => json(422, { error: { code: 'validation_error', message: 'The request data is invalid.', details: [{ field: 'reason', message: 'too short' }] } })
    const e = await fail(client(f as unknown as typeof fetch).get('/x'))
    expect(e).toBeInstanceOf(ApiError)
    expect(e).toMatchObject({ kind: 'validation', status: 422, code: 'validation_error', message: 'The request data is invalid.' })
    expect(e.details[0].field).toBe('reason')
  })

  it.each([[403, 'forbidden'], [404, 'not_found'], [409, 'conflict'], [503, 'server']])('status %i → %s', async (status, kind) => {
    const e = await fail(client((async () => json(status, {})) as unknown as typeof fetch).get('/x'))
    expect(e.kind).toBe(kind)
  })

  it('a non-JSON error body still gives a friendly message', async () => {
    const e = await fail(client((async () => new Response('<html>boom</html>', { status: 500 })) as unknown as typeof fetch).get('/x'))
    expect(e.message).toContain('Something went wrong')
  })

  it('401 → refreshes the token once → retries with the new token', async () => {
    let token = 'old'
    const f = vi.fn(async (_u: unknown, init?: RequestInit) => (((init?.headers ?? {}) as Record<string, string>).Authorization === 'Bearer new' ? json(200, { ok: true }) : json(401, { error: { code: 'token_expired', message: 'expired' } })))
    const c = client(f as unknown as typeof fetch, { getToken: async () => token, refreshToken: async () => (token = 'new') })
    expect(await c.get('/x')).toEqual({ ok: true })
    expect(f).toHaveBeenCalledTimes(2)
  })

  it('still 401 after a refresh → session-expired callback, no retry loop', async () => {
    const f = vi.fn(async () => json(401, { error: { code: 'invalid_token', message: 'no' } }))
    const expired = vi.fn()
    await expect(client(f as unknown as typeof fetch, { refreshToken: async () => 'again', onSessionExpired: expired }).get('/x')).rejects.toMatchObject({ kind: 'unauthorized' })
    expect(f).toHaveBeenCalledTimes(2)
    expect(expired).toHaveBeenCalledTimes(1)
  })

  it('a failed refresh signs out without retrying', async () => {
    const f = vi.fn(async () => json(401, {}))
    const expired = vi.fn()
    await expect(client(f as unknown as typeof fetch, { refreshToken: async () => null, onSessionExpired: expired }).get('/x')).rejects.toBeInstanceOf(ApiError)
    expect(f).toHaveBeenCalledTimes(1)
    expect(expired).toHaveBeenCalledTimes(1)
  })

  it('reports permission loss (403 permission_denied) to the app', async () => {
    const onForbidden = vi.fn()
    await client((async () => json(403, { error: { code: 'permission_denied', message: 'no' } })) as unknown as typeof fetch, { onForbidden }).get('/x').catch(() => undefined)
    expect(onForbidden).toHaveBeenCalled()
  })

  it('network failure and timeout become friendly errors', async () => {
    const down = (async () => { throw new TypeError('Failed to fetch') }) as unknown as typeof fetch
    await expect(client(down).get('/x')).rejects.toMatchObject({ kind: 'network', isNetwork: true })
    const hang = ((_u: unknown, init?: RequestInit) => new Promise((_r, rej) => init?.signal?.addEventListener('abort', () => rej(new DOMException('aborted', 'AbortError'))))) as unknown as typeof fetch
    await expect(client(hang, { timeoutMs: 20 }).get('/x')).rejects.toMatchObject({ kind: 'timeout' })
  })

  it('204 responses resolve to undefined', async () => {
    expect(await client((async () => new Response(null, { status: 204 })) as unknown as typeof fetch).delete('/x')).toBeUndefined()
  })
})
