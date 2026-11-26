import { createContext, useContext } from 'react'
import type { StoredPreferences } from '../../types/api'

export type Preferences = StoredPreferences & { currency: 'INR' }

export interface PreferencesContextValue {
  preferences: Preferences
  /** Applies the change at once, remembers it on this device and saves it to the account. Resolves true when the account was updated. */
  update: (patch: Partial<StoredPreferences>) => Promise<boolean>
}

export const PreferencesContext = createContext<PreferencesContextValue | null>(null)

export function usePreferences(): PreferencesContextValue {
  const v = useContext(PreferencesContext)
  if (!v) throw new Error('usePreferences must be used inside <PreferencesProvider>')
  return v
}
