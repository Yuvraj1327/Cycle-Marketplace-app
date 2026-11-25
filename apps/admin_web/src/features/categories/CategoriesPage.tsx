import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth, useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ConfirmDialog, Modal, StatusBadge } from '../../components/common/ui'
import { CheckField, ImageField, SelectField, TextAreaField, TextField } from '../../components/forms/fields'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { errorMessage } from '../../services/api/client'
import type { Category, CategoryInput, ProductType, ServiceCategory } from '../../types/api'
import { imagePath } from '../../utils/images'
import { KIND_LABELS } from '../../utils/options'

type Variant = 'product' | 'service'
type Row = Category | ServiceCategory

const isProduct = (r: Row): r is Category => 'kind' in r
const dependents = (r: Row) => (isProduct(r) ? (r.product_count ?? 0) : (r.service_count ?? 0) + (r.booking_count ?? 0))

interface Draft { name: string; kind: ProductType; description: string; sort_order: string; is_active: boolean }

function validate(d: Draft): Partial<Record<keyof Draft, string>> {
  const e: Partial<Record<keyof Draft, string>> = {}
  if (d.name.trim().length < 2) e.name = 'Enter a name of at least 2 characters.'
  else if (d.name.trim().length > 100) e.name = 'The name can have at most 100 characters.'
  if (d.description.length > 1000) e.description = 'The description can have at most 1000 characters.'
  if (!/^-?\d+$/.test(d.sort_order.trim())) e.sort_order = 'Enter a whole number.'
  return e
}

function CategoryForm({ variant, initial, existing, onClose, onSaved }: { variant: Variant; initial: Row | null; existing: Row[]; onClose: () => void; onSaved: () => void }) {
  const s = useServices()
  const { gateway } = useAuth()
  const toast = useToast()
  const [d, setD] = useState<Draft>({ name: initial?.name ?? '', kind: isProduct(initial ?? ({} as Row)) ? (initial as Category).kind : 'new_cycle', description: initial?.description ?? '', sort_order: String(initial?.sort_order ?? 0), is_active: initial?.is_active ?? true })
  const [file, setFile] = useState<File | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [touched, setTouched] = useState(false)
  const errors = validate(d)
  const duplicate = existing.some((c) => c.id !== initial?.id && c.name.trim().toLowerCase() === d.name.trim().toLowerCase() && (!isProduct(c) || (c as Category).kind === d.kind))
  if (duplicate) errors.name = 'A category with this name already exists.'

  async function save() {
    setTouched(true)
    if (Object.keys(errors).length) return
    setBusy(true)
    setError(null)
    try {
      const body: CategoryInput = { name: d.name.trim(), description: d.description.trim() || null, sort_order: Number(d.sort_order), is_active: d.is_active }
      if (file) {
        const path = imagePath(variant === 'product' ? 'categories' : 'service-categories', file)
        await gateway.uploadImage('banners', path, file)
        body.image_path = path
      }
      const api = variant === 'product' ? s.categories : s.serviceCategories
      if (initial) await api.update(initial.id, body)
      else await api.create(variant === 'product' ? { ...body, kind: d.kind } : body)
      toast.success(initial ? 'Category saved.' : 'Category created.')
      onSaved()
      onClose()
    } catch (e) {
      setError(errorMessage(e))
      setBusy(false)
    }
  }

  return (
    <Modal title={initial ? `Edit ${initial.name}` : variant === 'product' ? 'New product category' : 'New service category'} onClose={busy ? () => undefined : onClose}
      footer={<><Button onClick={onClose} disabled={busy}>Cancel</Button><Button variant="primary" busy={busy} onClick={() => void save()}>Save</Button></>}>
      <TextField label="Name" required value={d.name} maxLength={100} onChange={(v) => setD({ ...d, name: v })} error={touched || d.name ? errors.name : null} />
      {variant === 'product' && (
        <SelectField label="Type" required value={d.kind} disabled={!!initial} onChange={(v) => setD({ ...d, kind: v })}
          help={initial ? 'The type cannot be changed once a category exists.' : 'Decides which customer section the category appears in.'}
          options={(Object.entries(KIND_LABELS) as [ProductType, string][]).map(([value, label]) => ({ value, label }))} />
      )}
      <TextAreaField label="Description" value={d.description} maxLength={1000} onChange={(v) => setD({ ...d, description: v })} error={errors.description} />
      <TextField label="Sort order" required inputMode="numeric" value={d.sort_order} onChange={(v) => setD({ ...d, sort_order: v })} error={touched ? errors.sort_order : null} help="Lower numbers are shown first." />
      <ImageField label="Image" file={file} onFile={setFile} currentUrl={initial?.image_url} help="Optional. JPEG, PNG or WebP, up to 5 MB. Uploaded to the platform's public image storage." />
      <CheckField label="Active" checked={d.is_active} onChange={(v) => setD({ ...d, is_active: v })} help="Inactive categories are hidden from customers; their products and history are kept." />
      {error && <p className="form-error" role="alert">{error}</p>}
    </Modal>
  )
}

export function CategoriesPage({ variant }: { variant: Variant }) {
  const s = useServices()
  const toast = useToast()
  const product = variant === 'product'
  const title = product ? 'Product categories' : 'Service categories'
  const list = useAsync<Row[]>(() => (product ? s.categories.list() : s.serviceCategories.list()), [variant])
  const [editing, setEditing] = useState<Row | 'new' | null>(null)
  const [toggle, setToggle] = useState<Row | null>(null)
  const [removing, setRemoving] = useState<Row | null>(null)
  const api = product ? s.categories : s.serviceCategories

  const columns: Column<Row>[] = [
    { key: 'img', header: '', render: (c) => (c.image_url ? <img className="thumb" src={c.image_url} alt="" /> : <span className="thumb" aria-hidden="true" />) },
    { key: 'name', header: 'Name', render: (c) => <><strong>{c.name}</strong><div className="muted small">{c.description ?? ''}</div></> },
    ...(product ? [{ key: 'kind', header: 'Type', render: (c: Row) => KIND_LABELS[(c as Category).kind] ?? (c as Category).kind } as Column<Row>] : []),
    { key: 'sort', header: 'Order', align: 'right', render: (c) => c.sort_order },
    { key: 'count', header: product ? 'Products' : 'Services', align: 'right', render: (c) => (product ? (c as Category).product_count : (c as ServiceCategory).service_count) ?? 0 },
    ...(!product ? [{ key: 'bk', header: 'Bookings', align: 'right', render: (c: Row) => (c as ServiceCategory).booking_count ?? 0 } as Column<Row>] : []),
    { key: 'st', header: 'Status', render: (c) => <StatusBadge status={c.is_active ? 'active' : 'inactive'} /> },
    { key: 'act', header: 'Actions', align: 'right', render: (c) => (
      <span className="row-actions">
        <Link className="btn btn-secondary btn-sm" to={product ? `/products?category_id=${c.id}` : `/services?category_id=${c.id}`}>{product ? 'View products' : 'View services'}</Link>
        <Button size="sm" onClick={() => setEditing(c)}>Edit</Button>
        <Button size="sm" onClick={() => setToggle(c)}>{c.is_active ? 'Deactivate' : 'Activate'}</Button>
        <Button size="sm" disabled={dependents(c) > 0} title={dependents(c) > 0 ? 'In use: deactivate it instead of deleting' : undefined} onClick={() => setRemoving(c)}>Delete</Button>
      </span>) },
  ]

  return (
    <>
      <PageHeader title={title} subtitle={product ? 'The categories customers browse the marketplace by.' : 'The kinds of servicing vendors can offer.'}
        crumbs={[{ label: 'Overview', to: '/' }, { label: title }]} actions={<Button variant="primary" onClick={() => setEditing('new')}>New category</Button>} />
      <Card>
        <DataTable caption={title} columns={columns} rows={list.data} rowKey={(c) => c.id} loading={list.loading} error={list.error} onRetry={list.reload}
          emptyTitle="No categories yet" emptyMessage="Create the first category." />
      </Card>
      <p className="muted small">A category that still has {product ? 'products or sub-categories' : 'services or bookings'} cannot be deleted; deactivate it instead and nothing is lost.</p>
      {editing && <CategoryForm variant={variant} initial={editing === 'new' ? null : editing} existing={list.data ?? []} onClose={() => setEditing(null)} onSaved={list.reload} />}
      {toggle && (
        <ConfirmDialog title={toggle.is_active ? `Deactivate ${toggle.name}?` : `Activate ${toggle.name}?`} confirmLabel={toggle.is_active ? 'Deactivate' : 'Activate'} danger={toggle.is_active}
          message={toggle.is_active ? 'Customers will no longer see this category. Existing records are kept.' : 'Customers will see this category again.'}
          onConfirm={async () => { await api.update(toggle.id, { is_active: !toggle.is_active }); toast.success(toggle.is_active ? 'Category deactivated.' : 'Category activated.'); list.reload() }} onClose={() => setToggle(null)} />
      )}
      {removing && (
        <ConfirmDialog title={`Delete ${removing.name}?`} confirmLabel="Delete" danger message="This permanently removes the category. The backend refuses if anything still uses it."
          onConfirm={async () => { await api.remove(removing.id); toast.success('Category deleted.'); list.reload() }} onClose={() => setRemoving(null)} />
      )}
    </>
  )
}

/** Route entry points (a lazily loaded route needs a component without props). */
export const ProductCategoriesPage = () => <CategoriesPage variant="product" />
export const ServiceCategoriesPage = () => <CategoriesPage variant="service" />
