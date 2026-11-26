/** Light / dark / system appearance. The choice is kept in localStorage (so it is applied before the first paint, see index.html) and, for a signed-in
 *  administrator, on the account through FastAPI. The resolved theme is written to <html data-theme="light|dark">; the style sheet does the rest. */
export type ThemeChoice = 'light' | 'dark' | 'system'

export const PREFS_KEY = 'cm-admin-preferences'
export const THEME_CHOICES: ThemeChoice[] = ['light', 'dark', 'system']

export const isThemeChoice = (v: unknown): v is ThemeChoice => typeof v === 'string' && (THEME_CHOICES as string[]).includes(v)

export function resolveTheme(choice: ThemeChoice): 'light' | 'dark' {
  if (choice !== 'system') return choice
  return typeof window !== 'undefined' && window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

export function applyTheme(choice: ThemeChoice): void {
  const resolved = resolveTheme(choice)
  const root = document.documentElement
  root.dataset.theme = resolved
  root.style.colorScheme = resolved
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', resolved === 'dark' ? '#0b1624' : '#0f4c81')
}

/** Reads the saved preferences; storage can be unavailable (private window, blocked cookies), in which case nothing is returned. */
export function loadStoredPreferences(): Record<string, unknown> {
  try {
    const v: unknown = JSON.parse(localStorage.getItem(PREFS_KEY) ?? '{}')
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {}
  } catch {
    return {}
  }
}

export function storePreferences(prefs: Record<string, unknown>): void {
  try { localStorage.setItem(PREFS_KEY, JSON.stringify(prefs)) } catch { /* the preference simply is not remembered on this device */ }
}

/** While "system" is chosen, follow the operating system when it switches between light and dark. */
export function watchSystemTheme(current: () => ThemeChoice): () => void {
  const mq = window.matchMedia?.('(prefers-color-scheme: dark)')
  if (!mq) return () => undefined
  const on = () => { if (current() === 'system') applyTheme('system') }
  mq.addEventListener('change', on)
  return () => mq.removeEventListener('change', on)
}
