import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { DATE_FORMATS, DEFAULT_DATE_FORMAT, DEFAULT_TIMEZONE, setDisplayPreferences, type DateFormatId } from '../../utils/format'
import { applyTheme, isThemeChoice, loadStoredPreferences, storePreferences, watchSystemTheme } from '../../utils/theme'
import type { StoredPreferences } from '../../types/api'
import { useAuth } from './authContext'
import { PreferencesContext, type Preferences, type PreferencesContextValue } from './preferencesContext'
import { useToast } from './toastContext'

const DEFAULTS: Preferences = { theme: 'light', currency: 'INR', timezone: DEFAULT_TIMEZONE, date_format: DEFAULT_DATE_FORMAT }

/** Keeps only valid values; anything unknown (an old or edited value) falls back to the default. */
function clean(raw: Record<string, unknown> | undefined | null): Partial<StoredPreferences> {
  const out: Partial<StoredPreferences> = {}
  if (!raw) return out
  if (isThemeChoice(raw.theme)) out.theme = raw.theme
  if (typeof raw.timezone === 'string' && raw.timezone) out.timezone = raw.timezone
  if (typeof raw.date_format === 'string' && (DATE_FORMATS as string[]).includes(raw.date_format)) out.date_format = raw.date_format as DateFormatId
  return out
}

const withDefaults = (p: Partial<StoredPreferences>): Preferences => ({ ...DEFAULTS, ...p })

/** Theme, time zone and date format of the signed-in administrator. Read from this device first (no flash of the wrong theme), then from the account. */
export function PreferencesProvider({ children }: { children: ReactNode }) {
  const { me, services, setMe } = useAuth()
  const toast = useToast()
  const [preferences, setPreferences] = useState<Preferences>(() => withDefaults(clean(loadStoredPreferences())))
  const current = useRef(preferences)

  const commit = useCallback((next: Preferences) => {
    current.current = next
    setPreferences(next)
    const { theme, timezone, date_format } = next
    storePreferences({ theme, timezone, date_format })
  }, [])

  // what the account has saved wins over what this device remembers
  const saved = me?.profile.preferences
  useEffect(() => {
    const fromAccount = clean(saved)
    if (Object.keys(fromAccount).length > 0) commit({ ...current.current, ...fromAccount })
  }, [saved, commit])

  // render-time side effects stay out of React state: the page-wide formatters and the <html> theme follow the preferences
  setDisplayPreferences({ timezone: preferences.timezone, dateFormat: preferences.date_format })
  useEffect(() => { applyTheme(preferences.theme) }, [preferences.theme])
  useEffect(() => watchSystemTheme(() => current.current.theme), [])

  const update = useCallback(async (patch: Partial<StoredPreferences>) => {
    commit({ ...current.current, ...patch })
    if (!me) return false
    try {
      const profile = await services.profile.update({ preferences: patch })
      setMe({ ...me, profile })
      return true
    } catch {
      toast.error('Saved on this device only: the change could not be saved to your account.')
      return false
    }
  }, [commit, me, services, setMe, toast])

  const value = useMemo<PreferencesContextValue>(() => ({ preferences, update }), [preferences, update])
  return <PreferencesContext.Provider value={value}>{children}</PreferencesContext.Provider>
}
