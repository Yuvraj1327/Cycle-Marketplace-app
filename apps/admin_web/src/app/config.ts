/** Build-time configuration (Vite `VITE_*`). Only PUBLIC values belong here: the Supabase anon key is public by design;
 *  the service-role key and any payment/API secret must never be put in this app (everything prefixed VITE_ is bundled into the browser). */
const env = import.meta.env

export const config = {
  apiBaseUrl: ((env.VITE_API_BASE_URL as string | undefined) ?? 'http://localhost:8000').replace(/\/+$/, ''),
  supabaseUrl: (env.VITE_SUPABASE_URL as string | undefined) ?? '',
  supabaseAnonKey: (env.VITE_SUPABASE_ANON_KEY as string | undefined) ?? '',
  get apiV1(): string {
    return `${this.apiBaseUrl}/api/v1`
  },
  get supabaseConfigured(): boolean {
    return this.supabaseUrl !== '' && this.supabaseAnonKey !== ''
  },
}
