import { createContext, useContext } from 'react'
import type { Services } from '../../services/api/services'
import type { AuthGateway } from '../../services/supabase/gateway'
import type { Me } from '../../types/api'

/** loading   - restoring the session / asking the backend who this is
 *  signedOut - no session
 *  admin     - the BACKEND confirmed role=admin and status=active for this token
 *  denied    - signed in, but the backend says this account is not an authorised administrator */
export type AuthStatus = 'loading' | 'signedOut' | 'admin' | 'denied'

export interface AuthContextValue {
  status: AuthStatus
  me: Me | null
  notice: string | null
  services: Services
  signIn: (email: string, password: string) => Promise<void>
  signOut: () => Promise<void>
  clearNotice: () => void
  gateway: AuthGateway
  setMe: (me: Me) => void
}

export const AuthContext = createContext<AuthContextValue | null>(null)

export function useAuth(): AuthContextValue {
  const v = useContext(AuthContext)
  if (!v) throw new Error('useAuth must be used inside <AuthProvider>')
  return v
}

export function useServices(): Services {
  return useAuth().services
}
