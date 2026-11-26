import { useState, type FormEvent } from 'react'
import { Link, Navigate, Outlet, useLocation } from 'react-router-dom'
import { useAuth } from '../../app/providers/authContext'
import { AuthFailure } from '../../services/supabase/gateway'
import { Button, PageLoading } from '../../components/common/ui'
import { errorMessage } from '../../services/api/client'
import logo from '../../assets/admin-logo.png'
import { APP_NAME } from '../../app/config'

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/

function AuthShell({ title, subtitle, children }: { title: string; subtitle: string; children: React.ReactNode }) {
  return (
    <div className="auth-wrap">
      <div className="auth-card">
        <div className="brand brand-lg">
          <img className="brand-logo" src={logo} alt="" width="55" height="60" />
          <span><strong>{APP_NAME}</strong><small>Admin console</small></span>
        </div>
        <h1>{title}</h1>
        <p className="muted">{subtitle}</p>
        {children}
      </div>
    </div>
  )
}

export function LoginPage() {
  const { status, notice, signIn, clearNotice } = useAuth()
  const loc = useLocation()
  const from = (loc.state as { from?: string } | null)?.from ?? '/'
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [show, setShow] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [touched, setTouched] = useState(false)

  if (status === 'admin') return <Navigate to={from} replace />

  const emailError = touched && !EMAIL.test(email.trim()) ? 'Enter a valid e-mail address.' : null
  const passError = touched && password === '' ? 'Enter your password.' : null

  async function submit(e: FormEvent) {
    e.preventDefault()
    setTouched(true)
    if (busy || !EMAIL.test(email.trim()) || password === '') return
    setBusy(true)
    setError(null)
    clearNotice()
    try {
      await signIn(email, password)
    } catch (err) {
      setError(err instanceof AuthFailure ? err.message : errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthShell title="Sign in" subtitle="Administrators only. Accounts are provisioned by the platform team: there is no public registration.">
      {notice && <div className="banner banner-warn" role="alert">{notice}</div>}
      {error && <div className="banner banner-error" role="alert">{error}</div>}
      <form onSubmit={(e) => void submit(e)} noValidate>
        <label className="field">
          <span>E-mail</span>
          <input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} aria-invalid={!!emailError} aria-describedby={emailError ? 'e-err' : undefined} />
          {emailError && <small id="e-err" className="field-error">{emailError}</small>}
        </label>
        <label className="field">
          <span>Password</span>
          <span className="input-group">
            <input type={show ? 'text' : 'password'} autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} aria-invalid={!!passError} aria-describedby={passError ? 'p-err' : undefined} />
            <button type="button" className="input-addon" aria-label={show ? 'Hide password' : 'Show password'} aria-pressed={show} onClick={() => setShow((s) => !s)}>{show ? 'Hide' : 'Show'}</button>
          </span>
          {passError && <small id="p-err" className="field-error">{passError}</small>}
        </label>
        <Button type="submit" variant="primary" busy={busy} className="btn-block">Sign in</Button>
      </form>
      <p className="auth-links"><Link to="/forgot-password">Forgot your password?</Link></p>
    </AuthShell>
  )
}

export function ForgotPasswordPage() {
  const { gateway } = useAuth()
  const [email, setEmail] = useState('')
  const [busy, setBusy] = useState(false)
  const [sent, setSent] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (busy) return
    if (!EMAIL.test(email.trim())) return setError('Enter a valid e-mail address.')
    setBusy(true)
    setError(null)
    try {
      await gateway.sendPasswordReset(email)
      setSent(true)
    } catch (err) {
      setError(err instanceof AuthFailure ? err.message : errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthShell title="Reset your password" subtitle="We will e-mail you a link to choose a new password.">
      {sent && <div className="banner banner-ok" role="status">If an account exists for that e-mail, a reset link is on its way.</div>}
      {error && <div className="banner banner-error" role="alert">{error}</div>}
      <form onSubmit={(e) => void submit(e)} noValidate>
        <label className="field"><span>E-mail</span><input type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="username" /></label>
        <Button type="submit" variant="primary" busy={busy} className="btn-block">Send reset link</Button>
      </form>
      <p className="auth-links"><Link to="/login">Back to sign in</Link></p>
    </AuthShell>
  )
}

export function AccessDeniedPage() {
  const { signOut } = useAuth()
  const [busy, setBusy] = useState(false)
  return (
    <AuthShell title="Access denied" subtitle="This account is not authorised to use the admin console.">
      <div className="banner banner-error" role="alert">The platform did not confirm administrator rights for your account. If you believe this is a mistake, contact a platform administrator.</div>
      <Button variant="primary" busy={busy} className="btn-block" onClick={() => { setBusy(true); void signOut() }}>Sign out</Button>
    </AuthShell>
  )
}

export function ConfigErrorPage() {
  return (
    <AuthShell title="App not configured" subtitle="This build has no Supabase configuration.">
      <div className="banner banner-warn" role="alert">Set <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_ANON_KEY</code> (and <code>VITE_API_BASE_URL</code>) and rebuild. See <code>.env.example</code>.</div>
    </AuthShell>
  )
}

/** Gate for every private page. The decision comes from the backend (`/auth/me`), never from anything stored in the browser. */
export function ProtectedRoute() {
  const { status } = useAuth()
  const loc = useLocation()
  if (status === 'loading') return <PageLoading label="Checking your session…" />
  if (status === 'denied') return <AccessDeniedPage />
  if (status === 'signedOut') return <Navigate to="/login" replace state={{ from: loc.pathname + loc.search }} />
  return <Outlet />
}
