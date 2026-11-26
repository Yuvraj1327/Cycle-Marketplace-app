import { cleanup, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { PREFS_KEY } from '../../utils/theme'
import { baseRoutes, err, fakeGateway, me, renderApp } from '../../test/utils'

const open = (routes: ReturnType<typeof baseRoutes> = baseRoutes(), gateway = fakeGateway({ token: 'tok' })) => ({ ...renderApp({ path: '/profile', gateway, routes }), gateway })
const put = (extra: Record<string, unknown> = {}) => ({ 'PUT /profiles/me': (c: { body: unknown }) => ({ body: { ...me().profile, ...extra, ...(c.body as object) } }) })

beforeEach(() => { localStorage.clear(); delete document.documentElement.dataset.theme })
afterEach(() => { cleanup(); localStorage.clear() })

describe('account settings: profile', () => {
  it('shows the account (name, e-mail, role) and states that the role cannot be changed here', async () => {
    open()
    expect(await screen.findByRole('heading', { name: 'Account Settings' })).toBeInTheDocument()
    for (const title of ['Profile', 'Appearance', 'Security', 'Basic preferences']) expect(screen.getByRole('heading', { name: title })).toBeInTheDocument()
    expect(screen.getByDisplayValue('Root Admin')).toBeInTheDocument()
    expect(screen.getByText('Administrator')).toBeInTheDocument()
    expect(screen.getByText(/cannot be changed from this page/)).toBeInTheDocument()
    expect(screen.getByDisplayValue('root@example.com')).toBeDisabled()
  })

  it('updates only name and phone (never role, status or e-mail)', async () => {
    const { backend } = open({ ...baseRoutes(), ...put() })
    const name = await screen.findByLabelText('Full name')
    await userEvent.clear(name)
    await userEvent.type(name, 'Priya Admin')
    await userEvent.type(screen.getByLabelText('Phone'), '+919811122233')
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }))
    expect(await screen.findByText('Profile updated')).toBeInTheDocument()
    const call = backend.calls.find((c) => c.method === 'PUT')!
    expect(call.body).toEqual({ full_name: 'Priya Admin', phone: '+919811122233' })
  })

  it('validates the phone locally and shows backend errors', async () => {
    const { backend } = open({ ...baseRoutes(), 'PUT /profiles/me': err(422, 'validation_error', 'The request data is invalid.') })
    await userEvent.type(await screen.findByLabelText('Phone'), 'abc')
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }))
    expect(await screen.findByText(/7–15 digits/)).toBeInTheDocument()
    expect(backend.count('PUT', '/profiles/me')).toBe(0)
    await userEvent.clear(screen.getByLabelText('Phone'))
    await userEvent.type(screen.getByLabelText('Phone'), '+919811122233')
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }))
    expect(await screen.findByText('The request data is invalid.')).toBeInTheDocument()
  })

  it('profile picture: validated, uploaded to the own folder of the avatars bucket, then only the path is sent to FastAPI', async () => {
    const { backend, gateway } = open({ ...baseRoutes(), ...put() })
    const input = await screen.findByLabelText('Profile picture file')
    await userEvent.upload(input, new File(['x'], 'doc.pdf', { type: 'application/pdf' }), { applyAccept: false })
    expect(await screen.findByText('Choose a JPEG, PNG or WebP image.')).toBeInTheDocument()
    expect(gateway.uploads).toHaveLength(0)
    await userEvent.upload(input, new File(['png-bytes'], 'me.png', { type: 'image/png' }))
    expect(await screen.findByText('Profile picture updated')).toBeInTheDocument()
    expect(gateway.uploads).toHaveLength(1)
    expect(gateway.uploads[0]).toMatchObject({ bucket: 'avatars', type: 'image/png' })
    expect(gateway.uploads[0]!.path).toMatch(/^u-1\/avatar-\d+\.png$/)
    expect(backend.calls.find((c) => c.method === 'PUT')!.body).toEqual({ avatar_path: gateway.uploads[0]!.path })
  })

  it('shows an upload failure and does not touch the profile', async () => {
    const gateway = fakeGateway({ token: 'tok' })
    gateway.failUpload = 'You are not allowed to upload images.'
    const { backend } = open(baseRoutes(), gateway)
    await userEvent.upload(await screen.findByLabelText('Profile picture file'), new File(['x'], 'me.png', { type: 'image/png' }))
    expect(await screen.findByText('You are not allowed to upload images.')).toBeInTheDocument()
    expect(backend.count('PUT', '/profiles/me')).toBe(0)
  })
})

describe('account settings: security', () => {
  it('password change: client-side checks first, then the supported Supabase flow', async () => {
    const { gateway } = open()
    const cur = await screen.findByLabelText('Current password')
    await userEvent.click(screen.getByRole('button', { name: 'Update password' }))
    expect(await screen.findByText('Enter your current password.')).toBeInTheDocument()
    await userEvent.type(cur, 'OldSecret123')
    await userEvent.type(screen.getByLabelText('New password'), 'short')
    await userEvent.click(screen.getByRole('button', { name: 'Update password' }))
    expect(await screen.findByText(/at least 8 characters/)).toBeInTheDocument()
    await userEvent.clear(screen.getByLabelText('New password'))
    await userEvent.type(screen.getByLabelText('New password'), 'NewSecret123')
    await userEvent.type(screen.getByLabelText('Confirm new password'), 'Different123')
    await userEvent.click(screen.getByRole('button', { name: 'Update password' }))
    expect(await screen.findByText(/do not match/)).toBeInTheDocument()
    expect(gateway.changed).toHaveLength(0)
    await userEvent.clear(screen.getByLabelText('Confirm new password'))
    await userEvent.type(screen.getByLabelText('Confirm new password'), 'NewSecret123')
    await userEvent.click(screen.getByRole('button', { name: 'Update password' }))
    await waitFor(() => expect(gateway.changed).toEqual([{ current: 'OldSecret123', next: 'NewSecret123' }]))
    expect(await screen.findByText('Password changed')).toBeInTheDocument()
  })

  it('the Change password button in the profile card jumps to the password form', async () => {
    open()
    await userEvent.click(await screen.findByRole('button', { name: 'Change password' }))
    expect(screen.getByLabelText('Current password')).toHaveFocus()
  })

  it('logout asks for confirmation, then signs out', async () => {
    const { gateway } = open()
    await userEvent.click(await screen.findByRole('button', { name: 'Logout' }))
    expect(gateway.signOutCalls).toBe(0)
    await userEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Log out' }))
    await waitFor(() => expect(gateway.signOutCalls).toBe(1))
  })
})

describe('account settings: appearance (theme persistence)', () => {
  it('offers light, dark and system default; choosing one applies it at once, remembers it and saves it to the account', async () => {
    const { backend } = open({ ...baseRoutes(), ...put() })
    const group = await screen.findByRole('group', { name: /Choose how the admin console looks/ })
    expect(within(group).getAllByRole('radio').map((r) => (r as HTMLInputElement).value)).toEqual(['light', 'dark', 'system'])
    expect(within(group).getByRole('radio', { name: /Light/ })).toBeChecked()
    expect(document.documentElement.dataset.theme).toBe('light')

    await userEvent.click(within(group).getByRole('radio', { name: /Dark/ }))
    expect(await screen.findByText('Theme saved')).toBeInTheDocument()
    expect(document.documentElement.dataset.theme).toBe('dark')
    expect(JSON.parse(localStorage.getItem(PREFS_KEY)!).theme).toBe('dark')
    expect(backend.calls.filter((c) => c.method === 'PUT').map((c) => c.body)).toEqual([{ preferences: { theme: 'dark' } }])

    await userEvent.click(within(group).getByRole('radio', { name: /System default/ }))
    await waitFor(() => expect(JSON.parse(localStorage.getItem(PREFS_KEY)!).theme).toBe('system'))
    expect(backend.calls.filter((c) => c.method === 'PUT').at(-1)!.body).toEqual({ preferences: { theme: 'system' } })
  })

  it('the saved theme survives a reload: it is restored from this device before the account answers', async () => {
    localStorage.setItem(PREFS_KEY, JSON.stringify({ theme: 'dark' }))
    open()
    expect(await screen.findByRole('radio', { name: /Dark/ })).toBeChecked()
    expect(document.documentElement.dataset.theme).toBe('dark')
  })

  it('the theme saved on the account wins on a new device', async () => {
    const routes = { ...baseRoutes(), 'GET /auth/me': { body: { ...me(), profile: { ...me().profile, preferences: { theme: 'dark', timezone: 'UTC', date_format: 'YYYY-MM-DD' } } } } }
    open(routes)
    await screen.findByRole('radio', { name: /Dark/ })
    await waitFor(() => expect(screen.getByRole('radio', { name: /Dark/ })).toBeChecked())
    expect(document.documentElement.dataset.theme).toBe('dark')
    expect(JSON.parse(localStorage.getItem(PREFS_KEY)!)).toMatchObject({ theme: 'dark', timezone: 'UTC' })
  })

  it('when the account cannot be updated the theme still applies and the administrator is told it is saved on this device only', async () => {
    open({ ...baseRoutes(), 'PUT /profiles/me': err(500, 'internal_error', 'boom') })
    await userEvent.click(await screen.findByRole('radio', { name: /Dark/ }))
    expect(await screen.findByText(/Saved on this device only/)).toBeInTheDocument()
    expect(document.documentElement.dataset.theme).toBe('dark')
    expect(JSON.parse(localStorage.getItem(PREFS_KEY)!).theme).toBe('dark')
  })
})

describe('account settings: basic preferences', () => {
  it('currency is fixed to INR; time zone and date format are saved to the account and change how dates read', async () => {
    const { backend } = open({ ...baseRoutes(), ...put() })
    expect(await screen.findByLabelText('Currency')).toBeDisabled()
    expect(screen.getByLabelText('Currency')).toHaveValue('Indian Rupee (INR, ₹)')
    expect(screen.getByRole('button', { name: 'Save preferences' })).toBeDisabled()

    await userEvent.selectOptions(screen.getByLabelText('Time zone'), 'UTC')
    await userEvent.selectOptions(screen.getByLabelText('Date format'), 'YYYY-MM-DD')
    await userEvent.click(screen.getByRole('button', { name: 'Save preferences' }))
    expect(await screen.findByText('Preferences saved')).toBeInTheDocument()
    expect(backend.calls.find((c) => c.method === 'PUT')!.body).toEqual({ preferences: { timezone: 'UTC', date_format: 'YYYY-MM-DD' } })
    expect(JSON.parse(localStorage.getItem(PREFS_KEY)!)).toMatchObject({ timezone: 'UTC', date_format: 'YYYY-MM-DD' })
  })
})
