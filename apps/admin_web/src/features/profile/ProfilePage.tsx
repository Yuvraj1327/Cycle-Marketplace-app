import { useRef, useState, type ChangeEvent, type FormEvent } from 'react'
import { useAuth } from '../../app/providers/authContext'
import { usePreferences } from '../../app/providers/preferencesContext'
import { AuthFailure } from '../../services/supabase/gateway'
import { useToast } from '../../app/providers/toastContext'
import { Avatar } from '../../components/common/Avatar'
import { Button, Card, ConfirmDialog, StatusBadge } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { errorMessage } from '../../services/api/client'
import type { StoredPreferences } from '../../types/api'
import { IMAGE_TYPES, validateImage } from '../../utils/images'
import { DATE_FORMATS, DEFAULT_TIMEZONE } from '../../utils/format'
import { THEME_CHOICES, type ThemeChoice } from '../../utils/theme'

const PHONE = /^\+?[0-9]{7,15}$/

const THEME_LABEL: Record<ThemeChoice, { label: string; hint: string }> = {
  light: { label: 'Light', hint: 'Bright background' },
  dark: { label: 'Dark', hint: 'Easier on the eyes at night' },
  system: { label: 'System default', hint: 'Follows your device setting' },
}

const TIME_ZONES: { value: string; label: string }[] = [
  { value: 'Asia/Kolkata', label: 'India (IST, UTC+05:30)' },
  { value: 'Asia/Dubai', label: 'Dubai (GST, UTC+04:00)' },
  { value: 'Asia/Kathmandu', label: 'Kathmandu (NPT, UTC+05:45)' },
  { value: 'Asia/Dhaka', label: 'Dhaka (BST, UTC+06:00)' },
  { value: 'Asia/Colombo', label: 'Colombo (UTC+05:30)' },
  { value: 'Asia/Singapore', label: 'Singapore (SGT, UTC+08:00)' },
  { value: 'Australia/Sydney', label: 'Sydney (AEST/AEDT)' },
  { value: 'Europe/London', label: 'London (GMT/BST)' },
  { value: 'Europe/Berlin', label: 'Central Europe (CET/CEST)' },
  { value: 'America/New_York', label: 'New York (ET)' },
  { value: 'America/Los_Angeles', label: 'Los Angeles (PT)' },
  { value: 'UTC', label: 'UTC' },
]

const DATE_EXAMPLE: Record<StoredPreferences['date_format'], string> = {
  'D MMM YYYY': '27 Mar 2026', 'DD/MM/YYYY': '27/03/2026', 'MM/DD/YYYY': '03/27/2026', 'YYYY-MM-DD': '2026-03-27',
}

// ------------------------------------------------------------------ profile
function ProfileSection() {
  const { me, services, gateway, setMe } = useAuth()
  const toast = useToast()
  const picker = useRef<HTMLInputElement>(null)
  const [name, setName] = useState(me?.profile.full_name ?? '')
  const [phone, setPhone] = useState(me?.profile.phone ?? '')
  const [busy, setBusy] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [photoError, setPhotoError] = useState<string | null>(null)
  if (!me) return null
  const dirty = name.trim() !== (me.profile.full_name ?? '') || phone.trim() !== (me.profile.phone ?? '')

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

  async function choosePhoto(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    e.target.value = '' // lets the same file be picked again
    if (!file || !me) return
    const problem = validateImage(file)
    if (problem) return setPhotoError(problem)
    setUploading(true)
    setPhotoError(null)
    try {
      // the image goes to the administrator's own folder of the private `avatars` bucket; FastAPI only learns the path (and checks it is theirs)
      const path = `${me.id}/avatar-${Date.now()}.${IMAGE_TYPES[file.type] ?? 'jpg'}`
      await gateway.uploadImage('avatars', path, file)
      const updated = await services.profile.update({ avatar_path: path })
      setMe({ ...me, profile: updated })
      toast.success('Profile picture updated')
    } catch (err) {
      setPhotoError(err instanceof AuthFailure ? err.message : errorMessage(err))
    } finally {
      setUploading(false)
    }
  }

  return (
    <Card title="Profile">
      <div className="photo-row">
        <Avatar path={me.profile.avatar_path} name={me.profile.full_name} email={me.email} large />
        <div>
          <input ref={picker} type="file" accept={Object.keys(IMAGE_TYPES).join(',')} onChange={(e) => void choosePhoto(e)} hidden aria-label="Profile picture file" />
          <Button onClick={() => picker.current?.click()} busy={uploading}>Update profile picture</Button>
          <p className="muted small">JPEG, PNG or WebP, up to 5 MB.</p>
          {photoError && <p className="form-error" role="alert">{photoError}</p>}
        </div>
      </div>
      <form onSubmit={(e) => void submit(e)} noValidate>
        {error && <div className="banner banner-error" role="alert">{error}</div>}
        <label className="field"><span>Full name</span><input value={name} onChange={(e) => setName(e.target.value)} maxLength={120} /></label>
        <label className="field"><span>Phone</span><input value={phone} onChange={(e) => setPhone(e.target.value)} inputMode="tel" placeholder="+919876543210" /></label>
        <label className="field"><span>E-mail</span><input value={me.email ?? ''} disabled aria-describedby="email-help" /><small id="email-help" className="muted">Your sign-in e-mail cannot be changed here.</small></label>
        <div className="field"><span>Account role</span><div><StatusBadge status={me.role} label="Administrator" /></div><small className="muted">Your role is set by the platform team and cannot be changed from this page.</small></div>
        <div className="form-actions">
          <Button type="submit" variant="primary" busy={busy} disabled={!dirty}>Save changes</Button>
          <Button onClick={() => document.getElementById('current-password')?.focus()}>Change password</Button>
        </div>
      </form>
    </Card>
  )
}

// ------------------------------------------------------------------ appearance
function AppearanceSection() {
  const { preferences, update } = usePreferences()
  const toast = useToast()
  async function choose(theme: ThemeChoice) {
    if (theme === preferences.theme) return
    if (await update({ theme })) toast.success('Theme saved')
  }
  return (
    <Card title="Appearance">
      <fieldset className="theme-choices">
        <legend className="muted small">Choose how the admin console looks. Your choice is saved to your account and remembered on this device.</legend>
        {THEME_CHOICES.map((t) => (
          <label key={t} className={`theme-choice ${preferences.theme === t ? 'selected' : ''}`}>
            <input type="radio" name="theme" value={t} checked={preferences.theme === t} onChange={() => void choose(t)} />
            <span><strong>{THEME_LABEL[t].label}</strong><small className="muted">{THEME_LABEL[t].hint}</small></span>
          </label>
        ))}
      </fieldset>
    </Card>
  )
}

// ------------------------------------------------------------------ security
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
      <label className="field"><span>Current password</span><input id="current-password" type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} /></label>
      <label className="field"><span>New password</span><input type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} /></label>
      <label className="field"><span>Confirm new password</span><input type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} /></label>
      <Button type="submit" variant="primary" busy={busy}>Update password</Button>
      <p className="muted small">Passwords are handled by the sign-in provider (Supabase Auth); the admin console never stores them.</p>
    </form>
  )
}

function SecuritySection() {
  const { signOut } = useAuth()
  const [confirmOut, setConfirmOut] = useState(false)
  return (
    <Card title="Security">
      <h3 className="sub-title">Change password</h3>
      <PasswordForm />
      <div className="logout-row">
        <div><h3 className="sub-title">Log out</h3><p className="muted small">End this session on this device.</p></div>
        <Button variant="danger" onClick={() => setConfirmOut(true)}>Logout</Button>
      </div>
      {confirmOut && <ConfirmDialog title="Log out?" message="You will need to sign in again to use the admin console." confirmLabel="Log out" onConfirm={() => signOut()} onClose={() => setConfirmOut(false)} />}
    </Card>
  )
}

// ------------------------------------------------------------------ basic preferences
function PreferencesSection() {
  const { preferences, update } = usePreferences()
  const toast = useToast()
  const [timezone, setTimezone] = useState(preferences.timezone)
  const [dateFormat, setDateFormat] = useState(preferences.date_format)
  const [busy, setBusy] = useState(false)
  const dirty = timezone !== preferences.timezone || dateFormat !== preferences.date_format
  const zones = TIME_ZONES.some((z) => z.value === timezone) ? TIME_ZONES : [{ value: timezone, label: timezone }, ...TIME_ZONES]

  async function save(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    try {
      if (await update({ timezone, date_format: dateFormat })) toast.success('Preferences saved')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card title="Basic preferences">
      <form onSubmit={(e) => void save(e)}>
        <div className="field"><label htmlFor="pref-currency">Currency</label><input id="pref-currency" value="Indian Rupee (INR, ₹)" disabled aria-describedby="currency-help" /><small id="currency-help" className="muted">All amounts on the platform are in Indian rupees.</small></div>
        <div className="field"><label htmlFor="pref-timezone">Time zone</label>
          <select id="pref-timezone" value={timezone} onChange={(e) => setTimezone(e.target.value)} aria-describedby="timezone-help">
            {zones.map((z) => <option key={z.value} value={z.value}>{z.label}</option>)}
          </select>
          <small id="timezone-help" className="muted">Dates and times are shown in this zone. The platform default is {DEFAULT_TIMEZONE}.</small>
        </div>
        <div className="field"><label htmlFor="pref-date-format">Date format</label>
          <select id="pref-date-format" value={dateFormat} onChange={(e) => setDateFormat(e.target.value as StoredPreferences['date_format'])}>
            {DATE_FORMATS.map((f) => <option key={f} value={f}>{f} ({DATE_EXAMPLE[f]})</option>)}
          </select>
        </div>
        <Button type="submit" variant="primary" busy={busy} disabled={!dirty}>Save preferences</Button>
      </form>
    </Card>
  )
}

export function ProfilePage() {
  const { me } = useAuth()
  const { preferences } = usePreferences()
  if (!me) return null
  return (
    <>
      <PageHeader title="Account Settings" crumbs={[{ label: 'Overview', to: '/' }, { label: 'Account Settings' }]} />
      <div className="settings-stack">
        <ProfileSection />
        <AppearanceSection />
        <SecuritySection />
        <PreferencesSection key={`${preferences.timezone}|${preferences.date_format}`} />
      </div>
    </>
  )
}
