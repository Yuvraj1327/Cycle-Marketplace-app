import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { config } from '../../app/config'

let client: SupabaseClient | null = null

/** The browser-side Supabase client (identity only: sign-in, session, token refresh, password change). All business data goes through FastAPI. */
export function getSupabase(): SupabaseClient {
  if (!config.supabaseConfigured) throw new Error('Supabase is not configured (VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY).')
  client ??= createClient(config.supabaseUrl, config.supabaseAnonKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
  })
  return client
}
