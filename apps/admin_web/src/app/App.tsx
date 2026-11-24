import { useMemo } from 'react'
import { RouterProvider } from 'react-router-dom'
import { ConfigErrorPage } from '../features/authentication/AuthPages'
import { createSupabaseGateway } from '../services/supabase/gateway'
import { getSupabase } from '../services/supabase/client'
import { config } from './config'
import { AuthProvider } from './providers/AuthProvider'
import { ToastProvider } from './providers/ToastProvider'
import { createAppRouter } from './router'

export default function App() {
  const router = useMemo(() => createAppRouter(), [])
  const gateway = useMemo(() => (config.supabaseConfigured ? createSupabaseGateway(getSupabase()) : null), [])
  // Never crash on a missing build configuration: say exactly what is missing.
  if (!gateway) return <ConfigErrorPage />
  return (
    <ToastProvider>
      <AuthProvider gateway={gateway} apiBaseUrl={config.apiBaseUrl}>
        <RouterProvider router={router} />
      </AuthProvider>
    </ToastProvider>
  )
}
