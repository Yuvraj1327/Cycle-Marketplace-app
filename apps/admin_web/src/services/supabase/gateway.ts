import type { SupabaseClient } from '@supabase/supabase-js'

export class AuthFailure extends Error {}

/** What the app needs from the identity provider. Supabase Auth is the real implementation; tests use a fake. Passwords go straight to
 *  Supabase: they are never stored by the app and never sent to FastAPI. */
export interface AuthGateway {
  /** Current access token (Supabase refreshes it automatically before expiry), or null when signed out. */
  getAccessToken(): Promise<string | null>
  refresh(): Promise<string | null>
  /** Fires on sign-in / sign-out / session loss. */
  onChange(cb: (signedIn: boolean) => void): () => void
  signIn(email: string, password: string): Promise<void>
  signOut(): Promise<void>
  sendPasswordReset(email: string): Promise<void>
  /** Verifies the current password with Supabase first, then sets the new one through the supported Supabase flow. */
  changePassword(email: string, current: string, next: string): Promise<void>
}

function friendly(message: string): string {
  const m = message.toLowerCase()
  if (m.includes('invalid login')) return 'Incorrect e-mail or password.'
  if (m.includes('email not confirmed')) return 'Please confirm your e-mail address first.'
  if (m.includes('rate limit') || m.includes('too many')) return 'Too many attempts. Please wait a minute and try again.'
  if (m.includes('password') && m.includes('character')) return message
  if (m.includes('same password') || m.includes('different from the old')) return 'Choose a password different from the current one.'
  return message
}

export function createSupabaseGateway(client: SupabaseClient): AuthGateway {
  return {
    async getAccessToken() {
      const { data } = await client.auth.getSession()
      return data.session?.access_token ?? null
    },
    async refresh() {
      const { data, error } = await client.auth.refreshSession()
      return error ? null : (data.session?.access_token ?? null)
    },
    onChange(cb) {
      const { data } = client.auth.onAuthStateChange((_event, session) => cb(session !== null))
      return () => data.subscription.unsubscribe()
    },
    async signIn(email, password) {
      const { error } = await client.auth.signInWithPassword({ email: email.trim(), password })
      if (error) throw new AuthFailure(friendly(error.message))
    },
    async signOut() {
      await client.auth.signOut()
    },
    async sendPasswordReset(email) {
      const { error } = await client.auth.resetPasswordForEmail(email.trim(), { redirectTo: `${window.location.origin}/login` })
      if (error) throw new AuthFailure(friendly(error.message))
    },
    async changePassword(email, current, next) {
      const check = await client.auth.signInWithPassword({ email, password: current })
      if (check.error) throw new AuthFailure('The current password is incorrect.')
      const { error } = await client.auth.updateUser({ password: next })
      if (error) throw new AuthFailure(friendly(error.message))
    },
  }
}
