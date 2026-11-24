import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiError } from '../services/api/client'

export interface AsyncState<T> {
  data: T | null
  error: ApiError | Error | null
  loading: boolean
  reload: () => void
}

/** Runs `fn` on mount and whenever `deps` change; late responses from an older run are ignored. */
export function useAsync<T>(fn: () => Promise<T>, deps: unknown[]): AsyncState<T> {
  const [data, setData] = useState<T | null>(null)
  const [error, setError] = useState<ApiError | Error | null>(null)
  const [loading, setLoading] = useState(true)
  const run = useRef(0)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    const id = ++run.current
    setLoading(true)
    setError(null)
    fn().then(
      (d) => {
        if (id === run.current) {
          setData(d)
          setLoading(false)
        }
      },
      (e: unknown) => {
        if (id === run.current) {
          setError(e instanceof Error ? e : new Error('Unknown error'))
          setLoading(false)
        }
      },
    )
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick])

  const reload = useCallback(() => setTick((t) => t + 1), [])
  return { data, error, loading, reload }
}
