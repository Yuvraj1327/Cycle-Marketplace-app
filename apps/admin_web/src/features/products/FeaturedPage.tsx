import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ConfirmDialog, Modal, Pagination, SearchInput } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import { useSearchBox } from '../../hooks/useSearchBox'
import type { AdminProduct } from '../../types/api'
import { money } from '../../utils/format'
import { KIND_LABELS } from '../../utils/options'

const LIMIT = 20

function Picker({ onClose, onFeatured }: { onClose: () => void; onFeatured: () => void }) {
  const s = useServices()
  const toast = useToast()
  const [q, setQ] = useState('')
  const [busy, setBusy] = useState<string | null>(null)
  const list = useAsync(() => s.products.list({ moderation_status: 'approved', is_featured: false, q, limit: 10 }), [q])
  async function feature(p: AdminProduct) {
    setBusy(p.id)
    try {
      await s.products.setFeatured(p.id, true)
      toast.success(`${p.name} is now featured.`)
      onFeatured()
      list.reload()
    } catch (e) {
      toast.error(e instanceof Error ? e.message : 'Could not feature this product.')
    } finally {
      setBusy(null)
    }
  }
  return (
    <Modal title="Add a featured product" onClose={onClose} wide footer={<Button onClick={onClose}>Done</Button>}>
      <p className="muted small">Only approved, active listings are offered here, and the backend refuses anything else.</p>
      <SearchInput value={q} onChange={setQ} placeholder="Search eligible products" />
      <DataTable caption="Eligible products" rows={list.data?.items ?? null} rowKey={(p) => p.id} loading={list.loading} error={list.error} onRetry={list.reload} emptyTitle="No eligible product" emptyMessage="Every approved, active product is already featured, or none matches."
        columns={[
          { key: 'n', header: 'Product', render: (p) => <><strong>{p.name}</strong><div className="muted small">{p.vendor?.business_name}</div></> },
          { key: 'p', header: 'Price', align: 'right', render: (p) => money(p.price) },
          { key: 'a', header: '', align: 'right', render: (p) => <Button size="sm" variant="primary" busy={busy === p.id} onClick={() => void feature(p)}>Feature</Button> },
        ]} />
    </Modal>
  )
}

export function FeaturedPage() {
  const s = useServices()
  const toast = useToast()
  const { values, page, set, setPage } = useListQuery(['q'] as const)
  const [text, setText] = useSearchBox(values.q, (q) => set({ q }))
  const [adding, setAdding] = useState(false)
  const [removing, setRemoving] = useState<AdminProduct | null>(null)
  const list = useAsync(() => s.products.list({ is_featured: true, q: values.q, page, limit: LIMIT }), [values.q, page])

  const columns: Column<AdminProduct>[] = [
    { key: 'img', header: '', render: (p) => (p.primary_image_url ? <img className="thumb" src={p.primary_image_url} alt="" /> : <span className="thumb" aria-hidden="true" />) },
    { key: 'n', header: 'Product', render: (p) => <><Link to={`/products/${p.id}`}><strong>{p.name}</strong></Link><div className="muted small">{[p.brand, p.model].filter(Boolean).join(' · ')}</div></> },
    { key: 'c', header: 'Category', render: (p) => <>{p.category?.name ?? '—'}<div className="muted small">{KIND_LABELS[p.product_type]}</div></> },
    { key: 'v', header: 'Vendor', render: (p) => p.vendor?.business_name ?? '—' },
    { key: 'pr', header: 'Price', align: 'right', render: (p) => money(p.price) },
    { key: 'a', header: '', align: 'right', render: (p) => <Button size="sm" onClick={() => setRemoving(p)}>Remove from featured</Button> },
  ]

  return (
    <>
      <PageHeader title="Featured products" subtitle="Products shown in the customer app's featured section." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Featured products' }]}
        actions={<Button variant="primary" onClick={() => setAdding(true)}>Add featured product</Button>} />
      <p className="note">Only approved, active listings can be featured; deactivating or rejecting a listing removes it from this list. The backend has no manual ordering for featured products, so the customer app orders them by its own rules.</p>
      <Card>
        <div className="toolbar"><SearchInput value={text} onChange={setText} placeholder="Search featured products" /></div>
        <DataTable caption="Featured products" columns={columns} rows={list.data?.items ?? null} rowKey={(p) => p.id} loading={list.loading} error={list.error} onRetry={list.reload}
          emptyTitle="No featured products" emptyMessage="Use “Add featured product” to select approved listings." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
      {adding && <Picker onClose={() => setAdding(false)} onFeatured={list.reload} />}
      {removing && (
        <ConfirmDialog title="Remove from featured?" message={`"${removing.name}" stays listed but is no longer featured.`} confirmLabel="Remove"
          onConfirm={async () => { await s.products.setFeatured(removing.id, false); toast.success('Removed from featured.'); list.reload() }} onClose={() => setRemoving(null)} />
      )}
    </>
  )
}
