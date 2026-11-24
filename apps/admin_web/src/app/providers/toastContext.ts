import { createContext, useContext } from 'react'

export interface ToastApi {
  success: (m: string) => void
  error: (m: string) => void
  info: (m: string) => void
}

export const ToastContext = createContext<ToastApi | null>(null)

export function useToast(): ToastApi {
  const v = useContext(ToastContext)
  if (!v) throw new Error('useToast must be used inside <ToastProvider>')
  return v
}
