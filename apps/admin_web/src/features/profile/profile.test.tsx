import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { baseRoutes, err, fakeGateway, me, renderApp } from '../../test/utils'

const open = (routes = baseRoutes(), gateway = fakeGateway({ token: 'tok' })) => ({ ...renderApp({ path: '/profile', gateway, routes }), gateway })

describe('admin profile', () => {
  it('shows the account and states that the role cannot be changed here', async () => {
    open()
    expect(await screen.findByRole('heading', { name: 'My profile' })).toBeInTheDocument()
    expect(screen.getAllByText('Root Admin').length).toBeGreaterThan(0)
    expect(screen.getByText('Administrator')).toBeInTheDocument()
    expect(screen.getByText(/cannot be changed from this page/)).toBeInTheDocument()
    expect(screen.getByDisplayValue('root@example.com')).toBeDisabled()
  })

  it('updates only name and phone (never role, status or e-mail)', async () => {
    const { backend } = open({ ...baseRoutes(), 'PUT /profiles/me': (c) => ({ body: { ...me().profile, ...(c.body as object) } }) })
    const name = await screen.findByLabelText('Full name')
    await userEvent.clear(name)
    await userEvent.type(name, 'Priya Admin')
    await userEvent.type(screen.getByLabelText('Phone'), '+919811122233')
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }))
    expect(await screen.findByText('Profile updated')).toBeInTheDocument()
    const put = backend.calls.find((c) => c.method === 'PUT')!
    expect(put.body).toEqual({ full_name: 'Priya Admin', phone: '+919811122233' })
    expect(Object.keys(put.body as object)).not.toContain('role')
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

  it('password change: client-side checks first, then the supported Supabase flow', async () => {
    const { gateway } = open()
    const cur = await screen.findByLabelText('Current password')
    await userEvent.click(screen.getByRole('button', { name: 'Change password' }))
    expect(await screen.findByText('Enter your current password.')).toBeInTheDocument()
    await userEvent.type(cur, 'OldSecret123')
    await userEvent.type(screen.getByLabelText('New password'), 'short')
    await userEvent.click(screen.getByRole('button', { name: 'Change password' }))
    expect(await screen.findByText(/at least 8 characters/)).toBeInTheDocument()
    await userEvent.clear(screen.getByLabelText('New password'))
    await userEvent.type(screen.getByLabelText('New password'), 'NewSecret123')
    await userEvent.type(screen.getByLabelText('Confirm new password'), 'Different123')
    await userEvent.click(screen.getByRole('button', { name: 'Change password' }))
    expect(await screen.findByText(/do not match/)).toBeInTheDocument()
    expect(gateway.changed).toHaveLength(0)
    await userEvent.clear(screen.getByLabelText('Confirm new password'))
    await userEvent.type(screen.getByLabelText('Confirm new password'), 'NewSecret123')
    await userEvent.click(screen.getByRole('button', { name: 'Change password' }))
    await waitFor(() => expect(gateway.changed).toEqual([{ current: 'OldSecret123', next: 'NewSecret123' }]))
    expect(await screen.findByText('Password changed')).toBeInTheDocument()
  })
})
