import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { createApiClient, ApiError } from '../../services/api/client'
import { createServices } from '../../services/api/services'
import { type AuthGateway } from '../../services/supabase/gateway'
import type { Me } from '../../types/api'
import { AuthContext, type AuthContextValue, type AuthStatus } from './authContext'

interface Props {
  gateway: AuthGateway
  apiBaseUrl: string
  children: ReactNode
  /** tests can inject a pre-built API client */
  fetchImpl?: typeof fetch
}

export function AuthProvider({ gateway, apiBaseUrl, children, fetchImpl }: Props) {
  const [status, setStatus] = useState<AuthStatus>('loading')
  const [me, setMe] = useState<Me | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const statusRef = useRef<AuthStatus>('loading')
  const loadingMe = useRef(false)

  const apply = useCallback((s: AuthStatus, m: Me | null, n?: string | null) => {
    statusRef.current = s
    setStatus(s)
    setMe(m)
    if (n !== undefined) setNotice(n)
  }, [])

  const services = useMemo(() => {
    const api = createApiClient({
      baseUrl: `${apiBaseUrl}/api/v1`,
      getToken: () => gateway.getAccessToken(),
      refreshToken: () => gateway.refresh(),
      fetchImpl,
      onSessionExpired: () => {
        if (statusRef.current === 'admin') {
          void gateway.signOut()
          apply('signedOut', null, 'Your session has expired. Please sign in again.')
        }
      },
      // the backend revoked this admin's rights (role/status changed) while the page was open
      onForbidden: () => {
        if (statusRef.current === 'admin') apply('denied', null)
      },
    })
    return createServices(api)
  }, [gateway, apiBaseUrl, fetchImpl, apply])

  /** Ask FastAPI who this token belongs to. Nothing in the browser (local storage, token claims) decides authorisation. */
  const verify = useCallback(async () => {
    if (loadingMe.current) return
    loadingMe.current = true
    try {
      const who = await services.auth.me()
      if (who.role === 'admin' && who.status === 'active') {
        apply('admin', who, null)
      } else {
        await gateway.signOut()
        apply('signedOut', null, who.role !== 'admin'
          ? 'This account is not an administrator. The admin console is only for platform administrators.'
          : `This administrator account is ${who.status}. Contact another administrator.`)
      }
    } catch (e) {
      if (e instanceof ApiError && e.kind === 'forbidden') {
        await gateway.signOut()
        apply('signedOut', null, e.message)
      } else if (e instanceof ApiError && e.kind === 'unauthorized') {
        await gateway.signOut()
        apply('signedOut', null, 'Your session has expired. Please sign in again.')
      } else {
        // backend unreachable: keep the session but do not grant access
        apply('signedOut', null, 'Cannot reach the server to verify your account. Check your connection and sign in again.')
      }
    } finally {
      loadingMe.current = false
    }
  }, [services, gateway, apply])

  useEffect(() => {
    let alive = true
    void (async () => {
      const token = await gateway.getAccessToken()
      if (!alive) return
      if (token) await verify()
      else apply('signedOut', null)
    })()
    const off = gateway.onChange((signedIn) => {
      if (!signedIn && statusRef.current !== 'signedOut') apply('signedOut', null)
    })
    return () => {
      alive = false
      off()
    }
  }, [gateway, verify, apply])

  const signIn = useCallback(async (email: string, password: string) => {
    setNotice(null)
    await gateway.signIn(email, password) // throws AuthFailure on wrong credentials
    apply('loading', null)
    await verify()
  }, [gateway, verify, apply])

  const signOut = useCallback(async () => {
    try {
      await services.auth.logout()
    } catch {
      /* signing out locally must always work, even offline or with an expired token */
    }
    await gateway.signOut()
    apply('signedOut', null, null)
  }, [services, gateway, apply])

  const value = useMemo<AuthContextValue>(() => ({
    status, me, notice, services, signIn, signOut, gateway, clearNotice: () => setNotice(null), setMe: (m) => setMe(m),
  }), [status, me, notice, services, signIn, signOut, gateway])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

