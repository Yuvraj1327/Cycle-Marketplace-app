import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { announcement, notificationRecord } from '../../test/factories'
import { baseRoutes, err, fakeGateway, page, renderApp, vendor, customer } from '../../test/utils'

const composer = async () => (await screen.findByRole('heading', { name: 'New announcement' })).closest('section') as HTMLElement
const push = (over: Record<string, unknown> = {}) => ({ 'GET /admin/push/status': { body: { configured: false, provider: null, dispatcher_enabled: false, by_status: {}, active_devices: {}, oldest_pending: null, recent_failures: [], ...over } } })
const open = (routes: Record<string, unknown>, path: string) => renderApp({ path, gateway: fakeGateway({ token: 'tok' }), routes: { ...baseRoutes(), ...push(), ...routes } as never })

describe('announcements', () => {
  const history = () => ({ 'GET /admin/announcements': { body: page([announcement(1, { title: 'Festive sale', type: 'promotion', recipient_count: 120, delivered: 120, read: 45 })]) } })

  it('shows history with recipients, in-app delivery and read counts, and who sent it', async () => {
    open(history(), '/announcements')
    const row = (await screen.findByText('Festive sale')).closest('tr') as HTMLElement
    expect(within(row).getByText('Promotion')).toBeInTheDocument()
    expect(within(row).getByText('Customers')).toBeInTheDocument()
    expect(within(row).getAllByText('120')).toHaveLength(2)
    expect(within(row).getByText('45')).toBeInTheDocument()
    expect(within(row).getByText('7')).toBeInTheDocument()                                   // devices reached by push
    expect(within(row).getByText('Root Admin')).toBeInTheDocument()
    expect(within(row).getByRole('link', { name: 'Recipients' })).toHaveAttribute('href', '/notifications?announcement_id=an-1')
  })

  it('validates, asks for confirmation naming the audience, then sends the real payload', async () => {
    const { backend } = open({ ...history(), 'POST /admin/announcements': { body: announcement(2, { recipient_count: 7 }) } }, '/announcements')
    await screen.findByText('Festive sale')
    await userEvent.click(screen.getByRole('button', { name: 'Review and send' }))
    expect(screen.getByText('Enter a title of at least 3 characters.')).toBeInTheDocument()
    expect(screen.getByText('Enter a message of at least 3 characters.')).toBeInTheDocument()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await userEvent.type(screen.getByLabelText(/Title/), 'New spare parts')
    await userEvent.type(screen.getByLabelText(/Message/), 'Brake sets are back in stock.')
    const form = await composer()
    await userEvent.selectOptions(within(form).getByLabelText('Type'), 'promotion')
    await userEvent.selectOptions(within(form).getByLabelText('Audience'), 'vendors')
    await userEvent.click(screen.getByRole('button', { name: 'Review and send' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByText(/every active vendor/)).toBeInTheDocument()
    expect(backend.count('POST', '/admin/announcements')).toBe(0)
    await userEvent.click(within(dialog).getByRole('button', { name: 'Send' }))
    await waitFor(() => expect(backend.count('POST', '/admin/announcements')).toBe(1))
    expect(backend.calls.find((c) => c.method === 'POST')!.body).toEqual({ title: 'New spare parts', message: 'Brake sets are back in stock.', type: 'promotion', audience: 'vendors' })
    expect(await screen.findByText(/Sent to 7 recipients as an in-app notification/)).toBeInTheDocument()
    expect(screen.getByLabelText(/Title/)).toHaveValue('')                                  // the form resets only after the backend confirmed
  })

  it('says push depends on the server configuration and does not claim delivery', async () => {
    open(history(), '/announcements')
    expect(await screen.findByText(/when push is configured on the server/)).toBeInTheDocument()
  })

  it('a specific audience needs at least one chosen recipient, found by search among real customers and vendors', async () => {
    const { backend } = open({ ...history(), 'GET /admin/customers': { body: page([customer(1, { full_name: 'Asha Rao' })]) }, 'GET /admin/vendors': { body: page([vendor(1, { business_name: 'Alpha Cycles', user_id: 'vu-1', verification_status: 'approved' })]) },
      'POST /admin/announcements': { body: announcement(3, { recipient_count: 2, audience: 'specific' }) } }, '/announcements')
    await screen.findByText('Festive sale')
    await userEvent.selectOptions(within(await composer()).getByLabelText('Audience'), 'specific')
    await userEvent.type(screen.getByLabelText(/Title/), 'Personal note')
    await userEvent.type(screen.getByLabelText(/Message/), 'Thanks for your business.')
    await userEvent.click(screen.getByRole('button', { name: 'Review and send' }))
    expect(screen.getByText('Choose at least one recipient.')).toBeInTheDocument()
    await userEvent.type(screen.getByLabelText(/Recipients/), 'as')
    const matches = await screen.findByRole('list', { name: 'Matching people' })
    await waitFor(() => expect(within(matches).getByText(/Asha Rao/)).toBeInTheDocument())
    for (const add of within(matches).getAllByRole('button', { name: 'Add' })) await userEvent.click(add)
    expect(screen.getByRole('button', { name: 'Remove Asha Rao' })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Review and send' }))
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Send' }))
    await waitFor(() => expect(backend.count('POST', '/admin/announcements')).toBe(1))
    expect(backend.calls.find((c) => c.method === 'POST')!.body).toEqual({ title: 'Personal note', message: 'Thanks for your business.', type: 'announcement', audience: 'specific', user_ids: ['c-1', 'vu-1'] })
  })

  it('shows the backend\'s refusal (nobody to notify) and keeps what was typed', async () => {
    open({ ...history(), 'POST /admin/announcements': err(409, 'no_recipients', 'There is nobody to send this to: no active accounts match the chosen audience.') }, '/announcements')
    await screen.findByText('Festive sale')
    await userEvent.type(screen.getByLabelText(/Title/), 'Hello all')
    await userEvent.type(screen.getByLabelText(/Message/), 'A short message.')
    await userEvent.click(screen.getByRole('button', { name: 'Review and send' }))
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Send' }))
    expect(await screen.findByText(/nobody to send this to/)).toBeInTheDocument()
    expect(screen.getByLabelText(/Title/)).toHaveValue('Hello all')
  })
})

describe('notification records', () => {
  it('lists order, payment, offer and announcement notifications with recipient, read state and the in-app channel', async () => {
    const { backend } = open({ 'GET /admin/notifications': { body: page([notificationRecord(1), notificationRecord(2, { type: 'announcement', title: 'Festive sale', related_type: null, related_id: null, announcement_id: 'an-1', is_read: true, recipient_role: 'vendor', recipient_name: 'Vendor One' })]) } }, '/notifications')
    const order = (await screen.findByText('Order confirmed')).closest('tr') as HTMLElement
    expect(within(order).getByText('Asha Rao')).toBeInTheDocument()
    expect(within(order).getByText('Unread')).toBeInTheDocument()
    expect(within(order).getByText('Order', { selector: 'td:nth-child(4)' })).toBeInTheDocument()
    expect(within(order).getByText('In-app')).toBeInTheDocument()
    const ann = (await screen.findByText('Festive sale')).closest('tr') as HTMLElement
    expect(within(ann).getByText('Vendor One')).toBeInTheDocument()
    expect(within(ann).getByText('Read')).toBeInTheDocument()
    expect(screen.getByText(/does not prove the phone displayed it/)).toBeInTheDocument()
    expect(within(order).getByText('Push sent')).toBeInTheDocument()
    await userEvent.selectOptions(screen.getByLabelText('Type'), 'payment')
    await userEvent.type(screen.getByPlaceholderText(/Search recipient/), 'asha')
    await waitFor(() => { const q = backend.calls.filter((c) => c.path === '/admin/notifications').at(-1)!.query; expect([q.get('type'), q.get('q')]).toEqual(['payment', 'asha']) })
  })

  it('can be narrowed to one announcement\'s recipients', async () => {
    const { backend } = open({ 'GET /admin/notifications': { body: page([notificationRecord(1)]) } }, '/notifications?announcement_id=an-1')
    await screen.findByText('Order confirmed')
    expect(backend.calls.find((c) => c.path === '/admin/notifications')!.query.get('announcement_id')).toBe('an-1')
    expect(screen.getByText(/Showing one announcement's recipients/)).toBeInTheDocument()
  })

  it('shows an empty state', async () => {
    open({ 'GET /admin/notifications': { body: page([]) } }, '/notifications')
    expect(await screen.findByText('No notifications found')).toBeInTheDocument()
  })
})

describe('push delivery card', () => {
  it('without Firebase credentials it says so plainly and sending does nothing', async () => {
    const { backend } = open({ 'GET /admin/notifications': { body: page([]) }, 'POST /admin/push/dispatch': { body: { configured: false, claimed: 0, sent: 0, retry: 0, failed: 0, skipped: 0 } } }, '/notifications')
    expect(await screen.findByText(/not configured/)).toBeInTheDocument()
    expect(screen.getByText(/nothing is sent to phones until the server has the Firebase service account/)).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Send pending now' }))
    expect(await screen.findByText('Push is not configured on the server, so nothing was sent.')).toBeInTheDocument()
    expect(backend.count('POST', '/admin/push/dispatch')).toBe(1)
  })

  it('when configured it shows devices, outcomes and recent failures (no tokens), and reports the real dispatch result', async () => {
    open({ ...push({ configured: true, provider: 'fcm', dispatcher_enabled: true, by_status: { sent: 12, pending: 2, failed: 1, skipped: 5 }, active_devices: { customer: 9, vendor: 3 },
      recent_failures: [{ id: 'n1', title: 'Order placed', push_error: 'FCM unavailable', push_attempts: 5, created_at: '2026-03-10T10:00:00Z' }] }),
      'GET /admin/notifications': { body: page([]) }, 'POST /admin/push/dispatch': { body: { configured: true, claimed: 3, sent: 2, retry: 1, failed: 0, skipped: 0 } } }, '/notifications')
    expect(await screen.findByText(/background sender is running/)).toBeInTheDocument()
    expect(screen.getByText(/customers:/).textContent).toMatch(/customers: 9, vendors: 3/)
    expect(screen.getByText('FCM unavailable', { exact: false })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Send pending now' }))
    expect(await screen.findByText('Push cycle done: 2 sent, 1 to retry, 0 failed, 0 skipped.')).toBeInTheDocument()
  })
})
