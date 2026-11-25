import { useServices } from '../app/providers/authContext'
import type { Setting } from '../types/api'
import { useAsync } from './useAsync'

/** All platform settings from the backend, with a lookup by key. */
export function useSettings() {
  const s = useServices()
  const state = useAsync(() => s.settings.list(), [])
  const get = (key: string): Setting | undefined => state.data?.find((x) => x.key === key)
  return { state, get }
}
