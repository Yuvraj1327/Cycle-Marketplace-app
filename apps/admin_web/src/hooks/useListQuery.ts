import { useCallback } from 'react'
import { useSearchParams } from 'react-router-dom'

/** List filters live in the URL (shareable, survive refresh/back). Changing any filter returns to page 1. */
export function useListQuery<K extends string>(keys: readonly K[]) {
  const [sp, setSp] = useSearchParams()
  const values = Object.fromEntries(keys.map((k) => [k, sp.get(k) ?? ''])) as Record<K, string>
  const page = Math.max(1, Number(sp.get('page')) || 1)
  const set = useCallback((patch: Partial<Record<K, string>>) => {
    setSp((prev) => {
      const n = new URLSearchParams(prev)
      for (const [k, v] of Object.entries(patch) as [string, string][]) {
        if (v) n.set(k, v)
        else n.delete(k)
      }
      n.delete('page')
      return n
    }, { replace: true })
  }, [setSp])
  const setPage = useCallback((p: number) => setSp((prev) => {
    const n = new URLSearchParams(prev)
    if (p > 1) n.set('page', String(p))
    else n.delete('page')
    return n
  }, { replace: true }), [setSp])
  return { values, page, set, setPage }
}
