import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { audit, banner, category, product } from '../../test/factories'
import { baseRoutes, err, fakeGateway, page, renderApp, vendor } from '../../test/utils'

const common = () => ({ ...baseRoutes(), 'GET /admin/categories': { body: [category(1), category(2, { name: 'Spare Parts', kind: 'spare_part' })] }, 'GET /admin/vendors': { body: page([vendor(1, { business_name: 'Alpha Cycles', verification_status: 'approved' })]) } })
const open = (routes: Record<string, never>, path: string) => renderApp({ path, gateway: fakeGateway({ token: 'tok' }), routes: { ...common(), ...routes } as never })
const rowOf = async (name: string) => (await screen.findByText(name)).closest('tr') as HTMLElement

describe('product list', () => {
  const list = () => ({ 'GET /admin/products': { body: page([product(1, { name: 'Trail Blazer' }), product(2, { name: 'Disc Brake Set', approval_status: 'approved', product_type: 'spare_part', category: { id: 'cat-2', name: 'Spare Parts', slug: 'sp', kind: 'spare_part' }, stock_quantity: 0, in_stock: false, is_featured: true })]) } })

  it('shows every column the admin needs and only the actions that make sense for each state', async () => {
    open(list() as never, '/products')
    const pending = await rowOf('Trail Blazer')
    expect(within(pending).getByText('Hero · M1')).toBeInTheDocument()
    expect(within(pending).getByText('New Cycles')).toBeInTheDocument()
    expect(within(pending).getByText('Alpha Cycles')).toBeInTheDocument()
    expect(within(pending).getByText('₹12,001')).toBeInTheDocument()
    expect(within(pending).getByText('New')).toBeInTheDocument()
    expect(within(pending).getByText('In stock')).toBeInTheDocument()
    expect(within(pending).getByText('Pending')).toBeInTheDocument()
    expect(within(pending).getByRole('button', { name: 'Approve' })).toBeInTheDocument()
    expect(within(pending).getByRole('button', { name: 'Reject' })).toBeInTheDocument()
    expect(within(pending).getByRole('button', { name: 'Deactivate' })).toBeInTheDocument()
    const approved = await rowOf('Disc Brake Set')
    expect(within(approved).getByText('Out of stock')).toBeInTheDocument()
    expect(within(approved).getByText('Spare parts')).toBeInTheDocument()
    expect(within(approved).queryByRole('button', { name: 'Approve' })).not.toBeInTheDocument()
  })

  it('every filter, the status tabs and the sort order are sent to the backend', async () => {
    const { backend } = open(list() as never, '/products')
    await screen.findByText('Trail Blazer')
    await userEvent.click(screen.getByRole('tab', { name: 'Pending' }))
    await waitFor(() => expect(backend.calls.at(-1)!.query.get('moderation_status')).toBe('pending'))
    await userEvent.selectOptions(screen.getByLabelText('Category'), 'cat-2')
    await userEvent.selectOptions(await screen.findByLabelText('Vendor'), 'v-1')
    await userEvent.selectOptions(screen.getByLabelText('Condition'), 'used')
    await userEvent.selectOptions(screen.getByLabelText('Availability'), 'false')
    await userEvent.selectOptions(screen.getByLabelText('Sort'), 'price_high_to_low')
    await userEvent.type(screen.getByPlaceholderText(/Search name/), 'trail')
    await waitFor(() => {
      const q = backend.calls.filter((c) => c.path === '/admin/products').at(-1)!.query
      expect([q.get('category_id'), q.get('vendor_id'), q.get('condition'), q.get('in_stock'), q.get('sort'), q.get('q'), q.get('moderation_status')]).toEqual(['cat-2', 'v-1', 'used', 'false', 'price_high_to_low', 'trail', 'pending'])
    })
  })

  it('approving asks first, sends one admin request and refreshes only after the backend answers', async () => {
    let status = 'pending'
    const { backend } = open({ 'GET /admin/products': () => ({ body: page([product(1, { name: 'Trail Blazer', approval_status: status })]) }), 'PATCH /admin/products/p-1/approval': () => { status = 'approved'; return { body: product(1, { approval_status: 'approved' }) } } } as never, '/products')
    const row = await rowOf('Trail Blazer')
    await userEvent.click(within(row).getByRole('button', { name: 'Approve' }))
    const dialog = await screen.findByRole('dialog')
    expect(backend.count('PATCH', '/admin/products/p-1/approval')).toBe(0)
    await userEvent.click(within(dialog).getByRole('button', { name: 'Approve' }))
    await waitFor(() => expect(backend.count('PATCH', '/admin/products/p-1/approval')).toBe(1))
    expect(backend.calls.find((c) => c.method === 'PATCH')!.body).toEqual({ approval_status: 'approved' })
    expect(backend.calls.find((c) => c.method === 'PATCH')!.auth).toBe('Bearer tok')
    await waitFor(() => expect(within(row.parentElement!.querySelector('tr')!).getByText('Approved')).toBeInTheDocument())
  })

  it('rejecting needs a reason, sends it as the review note, and a backend refusal keeps the dialog open', async () => {
    const { backend } = open({ 'GET /admin/products': { body: page([product(1, { name: 'Trail Blazer' })]) }, 'PATCH /admin/products/p-1/approval': err(422, 'review_notes_required', 'Give the vendor a reason when rejecting a listing.') } as never, '/products')
    await userEvent.click(within(await rowOf('Trail Blazer')).getByRole('button', { name: 'Reject' }))
    const dialog = await screen.findByRole('dialog')
    const confirm = within(dialog).getByRole('button', { name: 'Reject' })
    expect(confirm).toBeDisabled()
    await userEvent.type(within(dialog).getByRole('textbox'), 'Photos are unclear')
    await userEvent.click(confirm)
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('Give the vendor a reason')
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(backend.calls.find((c) => c.method === 'PATCH')!.body).toEqual({ approval_status: 'rejected', review_notes: 'Photos are unclear' })
  })
})

describe('product details', () => {
  it('shows the full listing, the vendor, images, specifications and moderation history, and explains that content is the vendor\'s', async () => {
    open({ 'GET /admin/products/p-1': { body: product(1, { name: 'Trail Blazer', review_notes: 'Looks fine', is_featured: false }) }, 'GET /admin/audit-log': { body: page([audit()]) } } as never, '/products/p-1')
    expect(await screen.findByRole('heading', { name: 'Trail Blazer' })).toBeInTheDocument()
    expect(screen.getByText('A solid commuter.')).toBeInTheDocument()
    expect(screen.getByText('Frame')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Alpha Cycles' })).toHaveAttribute('href', '/vendors/v-1')
    expect(screen.getByAltText('Trail Blazer')).toHaveAttribute('src', 'https://img.test/p1.jpg')
    expect(screen.getByText('Looks fine')).toBeInTheDocument()
    expect(await screen.findByText('Product approval changed')).toBeInTheDocument()
    expect(screen.getByText(/belongs to the vendor and is not edited here/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Feature' })).toBeDisabled()         // pending listings cannot be featured
  })

  it('a missing product shows a clear message', async () => {
    open({ 'GET /admin/products/p-9': err(404, 'not_found', 'Product not found.'), 'GET /admin/audit-log': { body: page([]) } } as never, '/products/p-9')
    expect(await screen.findByText('Product not found')).toBeInTheDocument()
  })
})

describe('featured products', () => {
  it('lists featured products and removes one only after confirmation and a backend answer', async () => {
    const { backend } = open({ 'GET /admin/products': { body: page([product(1, { name: 'Trail Blazer', approval_status: 'approved', is_featured: true })]) }, 'PATCH /admin/products/p-1/featured': { body: product(1) } } as never, '/featured-products')
    expect(backend.calls.find((c) => c.path === '/admin/products')).toBeUndefined()
    await screen.findByText('Trail Blazer')
    expect(backend.calls.find((c) => c.path === '/admin/products')!.query.get('is_featured')).toBe('true')
    await userEvent.click(screen.getByRole('button', { name: 'Remove from featured' }))
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Remove' }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PATCH')!.body).toEqual({ is_featured: false }))
  })

  it('offers only approved, unfeatured products to add, and the backend decides', async () => {
    const { backend } = open({
      'GET /admin/products': (c: { query: URLSearchParams }) => ({ body: page(c.query.get('is_featured') === 'true' ? [] : [product(5, { name: 'Eligible Bike', approval_status: 'approved' })]) }),
      'PATCH /admin/products/p-5/featured': err(409, 'not_publicly_visible', 'Only approved, active listings can be featured.'),
    } as never, '/featured-products')
    await userEvent.click(await screen.findByRole('button', { name: 'Add featured product' }))
    await screen.findByText('Eligible Bike')
    const picker = backend.calls.filter((c) => c.path === '/admin/products').at(-1)!.query
    expect([picker.get('moderation_status'), picker.get('is_featured')]).toEqual(['approved', 'false'])
    await userEvent.click(screen.getByRole('button', { name: 'Feature' }))
    expect(await screen.findByText('Only approved, active listings can be featured.')).toBeInTheDocument()
  })
})

describe('product categories', () => {
  const cats = () => ({ 'GET /admin/categories': { body: [category(1, { name: 'New Cycles', product_count: 3 }), category(2, { name: 'Spare Parts', kind: 'spare_part', product_count: 0, is_active: false })] } })

  it('lists categories with counts and blocks deleting one that still has products', async () => {
    open(cats() as never, '/categories')
    const used = await rowOf('New Cycles')
    expect(within(used).getByRole('link', { name: 'View products' })).toHaveAttribute('href', '/products?category_id=cat-1')
    expect(within(used).getByRole('button', { name: 'Delete' })).toBeDisabled()
    const unused = await rowOf('Spare Parts')
    expect(within(unused).getByText('Inactive')).toBeInTheDocument()
    expect(within(unused).getByRole('button', { name: 'Delete' })).toBeEnabled()
    expect(within(unused).getByRole('button', { name: 'Activate' })).toBeInTheDocument()
  })

  it('validates the form before anything is sent and refuses a duplicate name', async () => {
    const { backend } = open({ ...cats(), 'POST /admin/categories': { body: category(9) } } as never, '/categories')
    await screen.findByText('New Cycles')
    await userEvent.click(screen.getByRole('button', { name: 'New category' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(within(dialog).getByText('Enter a name of at least 2 characters.')).toBeInTheDocument()
    await userEvent.type(within(dialog).getByLabelText(/Name/), 'new cycles')
    expect(within(dialog).getByText('A category with this name already exists.')).toBeInTheDocument()
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(backend.count('POST', '/admin/categories')).toBe(0)
  })

  it('creates a category with the chosen type and an uploaded image (path registered after the upload)', async () => {
    const { backend, gateway } = open({ ...cats(), 'POST /admin/categories': { body: category(9) } } as never, '/categories')
    await screen.findByText('New Cycles')
    await userEvent.click(screen.getByRole('button', { name: 'New category' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByLabelText(/Name/), 'Accessories Plus')
    await userEvent.selectOptions(within(dialog).getByLabelText(/Type/), 'accessory')
    await userEvent.upload(within(dialog).getByLabelText('Image'), new File(['x'], 'cover.png', { type: 'image/png' }))
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(backend.count('POST', '/admin/categories')).toBe(1))
    expect(gateway.uploads).toHaveLength(1)
    expect(gateway.uploads[0]).toMatchObject({ bucket: 'banners', type: 'image/png' })
    expect(gateway.uploads[0].path).toMatch(/^categories\/[\w-]+\.png$/)
    const body = backend.calls.find((c) => c.method === 'POST')!.body as Record<string, unknown>
    expect(body).toMatchObject({ name: 'Accessories Plus', kind: 'accessory', is_active: true, sort_order: 0, image_path: gateway.uploads[0].path })
  })

  it('rejects a non-image and an oversized image in the browser: nothing is uploaded', async () => {
    const user = userEvent.setup({ applyAccept: false })
    const { gateway } = open(cats() as never, '/categories')
    await screen.findByText('New Cycles')
    await user.click(screen.getByRole('button', { name: 'New category' }))
    const dialog = await screen.findByRole('dialog')
    await user.upload(within(dialog).getByLabelText('Image'), new File(['x'], 'notes.txt', { type: 'text/plain' }))
    expect(within(dialog).getByText('Choose a JPEG, PNG or WebP image.')).toBeInTheDocument()
    const big = new File(['x'], 'big.jpg', { type: 'image/jpeg' })
    Object.defineProperty(big, 'size', { value: 6 * 1024 * 1024 })
    await user.upload(within(dialog).getByLabelText('Image'), big)
    expect(within(dialog).getByText('The image is larger than 5 MB.')).toBeInTheDocument()
    expect(gateway.uploads).toHaveLength(0)
  })

  it('deactivating and deleting go through confirmation; the backend\'s refusal is shown', async () => {
    const { backend } = open({ ...cats(), 'PUT /admin/categories/cat-1': { body: category(1) }, 'DELETE /admin/categories/cat-2': err(409, 'conflict', 'This category is still in use.') } as never, '/categories')
    await userEvent.click(within(await rowOf('New Cycles')).getByRole('button', { name: 'Deactivate' }))
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Deactivate' }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PUT')!.body).toEqual({ is_active: false }))
    await userEvent.click(within(await rowOf('Spare Parts')).getByRole('button', { name: 'Delete' }))
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Delete' }))
    expect(await screen.findByText('This category is still in use.')).toBeInTheDocument()
  })
})

describe('banners', () => {
  const two = () => ({ 'GET /admin/banners': { body: [banner(2, { title: 'Second', sort_order: 2 }), banner(1, { title: 'First', sort_order: 1, action_type: 'url', action_value: 'https://shop.test/sale' })] } })

  it('lists banners in display order with their schedule and status', async () => {
    open(two() as never, '/banners')
    const first = await rowOf('First')
    expect(first.compareDocumentPosition((await rowOf('Second')))).toBe(Node.DOCUMENT_POSITION_FOLLOWING)
    expect(within(first).getByAltText('First banner')).toBeInTheDocument()
    expect(within(first).getByText(/Immediately/)).toBeInTheDocument()
    expect(within(first).getByText('Active')).toBeInTheDocument()
  })

  it('a new banner needs an image, an https link when it opens a web page, and uploads before it is registered', async () => {
    const { backend, gateway } = open({ ...two(), 'POST /admin/banners': { body: banner(3) } } as never, '/banners')
    await screen.findByText('First')
    await userEvent.click(screen.getByRole('button', { name: 'New banner' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByLabelText(/Title/), 'Monsoon sale')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(within(dialog).getByText('Choose a banner image.')).toBeInTheDocument()
    expect(backend.count('POST', '/admin/banners')).toBe(0)
    await userEvent.upload(within(dialog).getByLabelText(/Banner image/), new File(['x'], 'b.jpg', { type: 'image/jpeg' }))
    await userEvent.selectOptions(within(dialog).getByLabelText('When tapped'), 'url')
    await userEvent.type(within(dialog).getByLabelText(/Link/), 'http://insecure.test')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(within(dialog).getByText('Enter a link starting with https://')).toBeInTheDocument()
    expect(gateway.uploads).toHaveLength(0)
    await userEvent.clear(within(dialog).getByLabelText(/Link/))
    await userEvent.type(within(dialog).getByLabelText(/Link/), 'https://shop.test/monsoon')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(backend.count('POST', '/admin/banners')).toBe(1))
    expect(gateway.uploads[0].path).toMatch(/^banners\/[\w-]+\.jpg$/)
    expect(backend.calls.find((c) => c.method === 'POST')!.body).toMatchObject({ title: 'Monsoon sale', action_type: 'url', action_value: 'https://shop.test/monsoon', image_path: gateway.uploads[0].path, is_active: true })
  })

  it('an upload failure stops the save and shows the reason; nothing is registered', async () => {
    const { backend, gateway } = open({ ...two(), 'POST /admin/banners': { body: banner(3) } } as never, '/banners')
    gateway.failUpload = 'The image could not be uploaded: bucket not found'
    await screen.findByText('First')
    await userEvent.click(screen.getByRole('button', { name: 'New banner' }))
    const dialog = await screen.findByRole('dialog')
    await userEvent.type(within(dialog).getByLabelText(/Title/), 'Sale')
    await userEvent.upload(within(dialog).getByLabelText(/Banner image/), new File(['x'], 'b.jpg', { type: 'image/jpeg' }))
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('bucket not found')
    expect(backend.count('POST', '/admin/banners')).toBe(0)
  })

  it('moving a banner swaps the display order with its neighbour in two backend updates', async () => {
    const { backend } = open({ ...two(), 'PUT /admin/banners/:id': { body: banner(1) } } as never, '/banners')
    await screen.findByText('First')
    await userEvent.click(screen.getByRole('button', { name: 'Move First down' }))
    await waitFor(() => expect(backend.calls.filter((c) => c.method === 'PUT')).toHaveLength(2))
    const puts = backend.calls.filter((c) => c.method === 'PUT')
    expect(puts.map((c) => [c.path, c.body])).toEqual([['/admin/banners/b-1', { sort_order: 2 }], ['/admin/banners/b-2', { sort_order: 1 }]])
    expect(screen.getByRole('button', { name: 'Move First up' })).toBeDisabled()
  })

  it('previews, deactivates and removes after confirmation', async () => {
    const { backend } = open({ ...two(), 'PUT /admin/banners/b-1': { body: banner(1) }, 'DELETE /admin/banners/b-2': { status: 204 } } as never, '/banners')
    await userEvent.click(within(await rowOf('First')).getByRole('button', { name: 'Preview' }))
    expect(within(await screen.findByRole('dialog')).getByAltText('First banner preview')).toBeInTheDocument()
    await userEvent.click(within(screen.getByRole('dialog')).getAllByRole('button', { name: 'Close' }).at(-1)!)
    await userEvent.click(within(await rowOf('First')).getByRole('button', { name: 'Deactivate' }))
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Deactivate' }))
    await waitFor(() => expect(backend.calls.find((c) => c.method === 'PUT')!.body).toEqual({ is_active: false }))
    await userEvent.click(within(await rowOf('Second')).getByRole('button', { name: 'Remove' }))
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Remove' }))
    await waitFor(() => expect(backend.count('DELETE', '/admin/banners/b-2')).toBe(1))
  })
})
