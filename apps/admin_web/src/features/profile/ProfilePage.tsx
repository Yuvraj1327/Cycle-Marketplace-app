import { useState, type FormEvent } from 'react'
import { useAuth } from '../../app/providers/authContext'
import { AuthFailure } from '../../services/supabase/gateway'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ConfirmDialog, KeyValue, StatusBadge } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { errorMessage } from '../../services/api/client'
import { dateTime } from '../../utils/format'

const PHONE = /^\+?[0-9]{7,15}$/

function ProfileForm() {
  const { me, services, setMe } = useAuth()
  const toast = useToast()
  const [name, setName] = useState(me?.profile.full_name ?? '')
  const [phone, setPhone] = useState(me?.profile.phone ?? '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const dirty = name.trim() !== (me?.profile.full_name ?? '') || phone.trim() !== (me?.profile.phone ?? '')

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (busy || !me) return
    if (name.trim().length < 1) return setError('Enter your name.')
    if (phone.trim() !== '' && !PHONE.test(phone.trim())) return setError('Enter 7–15 digits, optionally starting with +.')
    setBusy(true)
    setError(null)
    try {
      // only name and phone are sent: role, status and e-mail are not editable here (and the backend would refuse them with 422)
      const body: { full_name?: string; phone?: string } = { full_name: name.trim() }
      if (phone.trim() !== '' && phone.trim() !== (me.profile.phone ?? '')) body.phone = phone.trim()
      const updated = await services.profile.update(body)
      setMe({ ...me, profile: updated })
      toast.success('Profile updated')
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={(e) => void submit(e)} noValidate>
      {error && <div className="banner banner-error" role="alert">{error}</div>}
      <label className="field"><span>Full name</span><input value={name} onChange={(e) => setName(e.target.value)} maxLength={120} /></label>
      <label className="field"><span>Phone</span><input value={phone} onChange={(e) => setPhone(e.target.value)} inputMode="tel" placeholder="+919876543210" /></label>
      <label className="field"><span>E-mail</span><input value={me?.email ?? ''} disabled aria-describedby="email-help" /><small id="email-help" className="muted">Your sign-in e-mail cannot be changed here.</small></label>
      <Button type="submit" variant="primary" busy={busy} disabled={!dirty}>Save changes</Button>
    </form>
  )
}

function PasswordForm() {
  const { me, gateway } = useAuth()
  const toast = useToast()
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (busy || !me?.email) return
    if (current === '') return setError('Enter your current password.')
    if (next.length < 8) return setError('The new password must be at least 8 characters.')
    if (next !== confirm) return setError('The new passwords do not match.')
    if (next === current) return setError('Choose a password different from the current one.')
    setBusy(true)
    setError(null)
    try {
      await gateway.changePassword(me.email, current, next)
      setCurrent('')
      setNext('')
      setConfirm('')
      toast.success('Password changed')
    } catch (err) {
      setError(err instanceof AuthFailure ? err.message : errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={(e) => void submit(e)} noValidate>
      {error && <div className="banner banner-error" role="alert">{error}</div>}
      <label className="field"><span>Current password</span><input type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} /></label>
      <label className="field"><span>New password</span><input type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} /></label>
      <label className="field"><span>Confirm new password</span><input type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} /></label>
      <Button type="submit" variant="primary" busy={busy}>Change password</Button>
      <p className="muted small">Passwords are handled by the sign-in provider (Supabase Auth); the admin console never stores them.</p>
    </form>
  )
}

export function ProfilePage() {
  const { me, signOut } = useAuth()
  const [confirmOut, setConfirmOut] = useState(false)
  if (!me) return null
  return (
    <>
      <PageHeader title="My profile" crumbs={[{ label: 'Overview', to: '/' }, { label: 'Profile' }]} actions={<Button onClick={() => setConfirmOut(true)}>Sign out</Button>} />
      <div className="grid two">
        <Card title="Account">
          <KeyValue rows={[
            ['Name', me.profile.full_name || '—'], ['E-mail', me.email], ['Role', <StatusBadge key="r" status={me.role} label="Administrator" />], ['Account status', <StatusBadge key="s" status={me.status} />],
            ['Member since', dateTime(me.profile.created_at)], ['Session expires', dateTime(me.session.token_expires_at)],
          ]} />
          <p className="muted small">Your role is set by the platform team and cannot be changed from this page.</p>
        </Card>
        <Card title="Edit profile"><ProfileForm /></Card>
        <Card title="Change password"><PasswordForm /></Card>
      </div>
      {confirmOut && <ConfirmDialog title="Sign out?" message="You will need to sign in again to use the admin console." confirmLabel="Sign out" onConfirm={() => signOut()} onClose={() => setConfirmOut(false)} />}
    </>
  )
}
