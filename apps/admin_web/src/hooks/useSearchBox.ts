import { useEffect, useState } from 'react'
import { useDebounce } from './useDebounce'

/** Text box state that writes to the URL filter only after the user pauses typing. */
export function useSearchBox(current: string, commit: (v: string) => void): [string, (v: string) => void] {
  const [text, setText] = useState(current)
  const debounced = useDebounce(text)
  useEffect(() => { if (debounced !== current) commit(debounced) }, [debounced]) // eslint-disable-line react-hooks/exhaustive-deps
  return [text, setText]
}
