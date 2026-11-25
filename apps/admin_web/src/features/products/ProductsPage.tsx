import { Link, useNavigate } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { Button, Card, Pagination, SearchInput, SelectFilter, StatusBadge } from '../../components/common/ui'
import { Tabs } from '../../components/common/filters'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import { useSearchBox } from '../../hooks/useSearchBox'
import type { AdminProduct } from '../../types/api'
import { dateOnly, humanize, money } from '../../utils/format'
import { KIND_LABELS } from '../../utils/options'
import { ProductActions } from './ProductActions'

const LIMIT = 20
const SORTS = [{ value: 'newest', label: 'Newest first' }, { value: 'oldest', label: 'Oldest first' }, { value: 'name', label: 'Name A–Z' }, { value: 'price_low_to_high', label: 'Price: low to high' }, { value: 'price_high_to_low', label: 'Price: high to low' }]

export function ProductsPage() {
  const s = useServices()
  const nav = useNavigate()
  const { values, page, set, setPage } = useListQuery(['q', 'moderation_status', 'category_id', 'vendor_id', 'condition', 'in_stock', 'sort'] as const)
  const [text, setText] = useSearchBox(values.q, (q) => set({ q }))
  const cats = useAsync(() => s.categories.list(), [])
  const vendors = useAsync(() => s.vendors.list({ verification_status: 'approved', limit: 100 }), [])
  const sort = values.sort || 'newest'
  const list = useAsync(() => s.products.list({ q: values.q, moderation_status: values.moderation_status, category_id: values.category_id, vendor_id: values.vendor_id, condition: values.condition, in_stock: values.in_stock, sort, page, limit: LIMIT }),
    [values.q, values.moderation_status, values.category_id, values.vendor_id, values.condition, values.in_stock, sort, page])

  const columns: Column<AdminProduct>[] = [
    { key: 'img', header: '', render: (p) => (p.primary_image_url ? <img className="thumb" src={p.primary_image_url} alt="" /> : <span className="thumb" aria-hidden="true" />) },
    { key: 'name', header: 'Product', render: (p) => <><Link to={`/products/${p.id}`} onClick={(e) => e.stopPropagation()}><strong>{p.name}</strong></Link><div className="muted small">{[p.brand, p.model].filter(Boolean).join(' · ') || '—'}</div></> },
    { key: 'cat', header: 'Category', render: (p) => <>{p.category?.name ?? '—'}<div className="muted small">{KIND_LABELS[p.product_type] ?? humanize(p.product_type)}</div></> },
    { key: 'vendor', header: 'Vendor', render: (p) => p.vendor?.business_name ?? '—' },
    { key: 'price', header: 'Price', align: 'right', render: (p) => money(p.price) },
    { key: 'cond', header: 'Condition', render: (p) => humanize(p.condition) },
    { key: 'stock', header: 'Stock', render: (p) => <>{p.stock_quantity} <StatusBadge status={p.in_stock ? 'active' : 'inactive'} label={p.in_stock ? 'In stock' : 'Out of stock'} /></> },
    { key: 'listing', header: 'Listing', render: (p) => <StatusBadge status={p.is_active ? 'active' : 'inactive'} /> },
    { key: 'appr', header: 'Approval', render: (p) => <StatusBadge status={p.approval_status} /> },
    { key: 'date', header: 'Created', render: (p) => dateOnly(p.created_at) },
    { key: 'act', header: 'Actions', align: 'right', render: (p) => (
      <span className="row-actions" onClick={(e) => e.stopPropagation()}>
        <Button size="sm" onClick={() => nav(`/products/${p.id}`)}>View</Button>
        <ProductActions product={p} size="sm" onChanged={list.reload} />
      </span>) },
  ]

  return (
    <>
      <PageHeader title="Products" subtitle="Review and moderate every vendor listing." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Products' }]} actions={<Button onClick={list.reload}>Refresh</Button>} />
      <Tabs label="Listing status" value={values.moderation_status} onChange={(v) => set({ moderation_status: v })}
        tabs={[{ value: '', label: 'All' }, { value: 'pending', label: 'Pending' }, { value: 'approved', label: 'Approved' }, { value: 'rejected', label: 'Rejected' }, { value: 'inactive', label: 'Inactive' }]} />
      <Card>
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search name, brand, model, category" />
          <SelectFilter label="Category" value={values.category_id} onChange={(v) => set({ category_id: v })}
            options={[{ value: '', label: 'All categories' }, ...(cats.data ?? []).map((c) => ({ value: c.id, label: `${c.name} (${KIND_LABELS[c.kind] ?? c.kind})` }))]} />
          <SelectFilter label="Vendor" value={values.vendor_id} onChange={(v) => set({ vendor_id: v })}
            options={[{ value: '', label: 'All vendors' }, ...(vendors.data?.items ?? []).map((v) => ({ value: v.id, label: v.business_name }))]} />
          <SelectFilter label="Condition" value={values.condition} onChange={(v) => set({ condition: v })} options={[{ value: '', label: 'All' }, { value: 'new', label: 'New' }, { value: 'used', label: 'Used' }]} />
          <SelectFilter label="Availability" value={values.in_stock} onChange={(v) => set({ in_stock: v })} options={[{ value: '', label: 'All' }, { value: 'true', label: 'In stock' }, { value: 'false', label: 'Out of stock' }]} />
          <SelectFilter label="Sort" value={sort} onChange={(v) => set({ sort: v === 'newest' ? '' : v })} options={SORTS} />
        </div>
        <DataTable caption="Products" columns={columns} rows={list.data?.items ?? null} rowKey={(p) => p.id} loading={list.loading} error={list.error} onRetry={list.reload}
          onRowClick={(p) => nav(`/products/${p.id}`)} emptyTitle="No products found" emptyMessage="Try changing the search or filters." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
    </>
  )
}
