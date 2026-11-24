export type ApiErrorKind = 'network' | 'timeout' | 'unauthorized' | 'forbidden' | 'not_found' | 'conflict' | 'validation' | 'server' | 'unknown'

export interface ErrorDetail {
  field?: string
  message?: string
}

/** Every failure from the backend in one shape. `code` is the backend's machine-readable code; `message` is safe to show. */
export class ApiError extends Error {
  readonly kind: ApiErrorKind
  readonly status?: number
  readonly code?: string
  readonly details: ErrorDetail[]
  constructor(kind: ApiErrorKind, message: string, opts: { status?: number; code?: string; details?: ErrorDetail[] } = {}) {
    super(message)
    this.name = 'ApiError'
    this.kind = kind
    this.status = opts.status
    this.code = opts.code
    this.details = opts.details ?? []
  }
  get isNetwork(): boolean {
    return this.kind === 'network' || this.kind === 'timeout'
  }
}

export function errorMessage(e: unknown): string {
  if (e instanceof ApiError) return e.message
  return 'Something went wrong. Please try again.'
}

export type Query = Record<string, string | number | boolean | null | undefined>

export interface ApiClientOptions {
  baseUrl: string
  getToken: () => Promise<string | null>
  /** Force a token refresh (after a 401). Resolve null if the session cannot be refreshed. */
  refreshToken?: () => Promise<string | null>
  onSessionExpired?: () => void
  onForbidden?: () => void
  timeoutMs?: number
  fetchImpl?: typeof fetch
}

export interface ApiClient {
  get<T>(path: string, query?: Query): Promise<T>
  post<T>(path: string, body?: unknown): Promise<T>
  put<T>(path: string, body?: unknown): Promise<T>
  patch<T>(path: string, body?: unknown): Promise<T>
  delete<T>(path: string): Promise<T>
}

function kindFor(status: number): ApiErrorKind {
  if (status === 401) return 'unauthorized'
  if (status === 403) return 'forbidden'
  if (status === 404) return 'not_found'
  if (status === 409) return 'conflict'
  if (status === 400 || status === 422) return 'validation'
  if (status >= 500) return 'server'
  return 'unknown'
}

export function buildUrl(baseUrl: string, path: string, query?: Query): string {
  const params = new URLSearchParams()
  for (const [k, v] of Object.entries(query ?? {})) {
    if (v === undefined || v === null || v === '') continue // optional filters never reach the URL
    params.set(k, String(v))
  }
  const qs = params.toString()
  return `${baseUrl}${path}${qs ? `?${qs}` : ''}`
}

async function toApiError(res: Response): Promise<ApiError> {
  let code: string | undefined
  let message: string | undefined
  let details: ErrorDetail[] = []
  try {
    const data = (await res.json()) as { error?: { code?: string; message?: string; details?: ErrorDetail[] } }
    code = data.error?.code
    message = data.error?.message
    details = Array.isArray(data.error?.details) ? data.error.details : []
  } catch {
    /* non-JSON error body: fall through to a generic message */
  }
  const kind = kindFor(res.status)
  const fallback = kind === 'server' ? 'Something went wrong on our side. Please try again.' : 'The request could not be completed.'
  return new ApiError(kind, message ?? fallback, { status: res.status, code, details })
}

/** The ONLY place that talks HTTP. Attaches the Supabase access token as a Bearer token, refreshes it once on a 401, applies a timeout and
 *  converts every failure to [ApiError]. Authorisation itself is always decided by the backend. */
export function createApiClient(opts: ApiClientOptions): ApiClient {
  const doFetch = opts.fetchImpl ?? ((...a: Parameters<typeof fetch>) => fetch(...a))
  const timeoutMs = opts.timeoutMs ?? 20_000

  async function once(method: string, path: string, query: Query | undefined, body: unknown, token: string | null): Promise<Response> {
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), timeoutMs)
    try {
      const headers: Record<string, string> = { Accept: 'application/json' }
      if (token) headers.Authorization = `Bearer ${token}`
      if (body !== undefined) headers['Content-Type'] = 'application/json'
      return await doFetch(buildUrl(opts.baseUrl, path, query), { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: ctrl.signal })
    } catch (e) {
      if (e instanceof DOMException && e.name === 'AbortError') throw new ApiError('timeout', 'The server took too long to respond. Please try again.')
      throw new ApiError('network', 'Cannot reach the server. Check your connection and try again.')
    } finally {
      clearTimeout(timer)
    }
  }

  async function request<T>(method: string, path: string, query?: Query, body?: unknown): Promise<T> {
    let res = await once(method, path, query, body, await opts.getToken())
    if (res.status === 401 && opts.refreshToken) {
      const fresh = await opts.refreshToken()
      if (fresh) res = await once(method, path, query, body, fresh)
    }
    if (!res.ok) {
      const err = await toApiError(res)
      if (err.kind === 'unauthorized') opts.onSessionExpired?.()
      if (err.kind === 'forbidden' && (err.code === 'permission_denied' || err.code?.startsWith('account_'))) opts.onForbidden?.()
      throw err
    }
    if (res.status === 204) return undefined as T
    return (await res.json()) as T
  }

  return {
    get: (path, query) => request('GET', path, query),
    post: (path, body) => request('POST', path, undefined, body),
    put: (path, body) => request('PUT', path, undefined, body),
    patch: (path, body) => request('PATCH', path, undefined, body),
    delete: (path) => request('DELETE', path),
  }
}
