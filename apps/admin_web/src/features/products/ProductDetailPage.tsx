import { Link, useParams } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { Card, EmptyState, ErrorState, KeyValue, PageLoading, StatusBadge } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { useAsync } from '../../hooks/useAsync'
import { ApiError } from '../../services/api/client'
import type { AdminProduct } from '../../types/api'
import { dateTime, humanize, money } from '../../utils/format'
import { AuditTrail } from '../common/AuditTrail'
import { KIND_LABELS } from '../../utils/options'
import { ProductActions } from './ProductActions'

export function ProductDetailPage() {
  const { id = '' } = useParams()
  const s = useServices()
  const product = useAsync(() => s.products.get(id), [id])
  const history = useAsync(() => s.products.history(id), [id])

  if (product.loading && !product.data) return <PageLoading />
  if (product.error && !product.data) {
    const missing = product.error instanceof ApiError && product.error.kind === 'not_found'
    return missing ? <Card><EmptyState title="Product not found" message="It may have been removed." action={<Link to="/products">Back to products</Link>} /></Card> : <ErrorState error={product.error} onRetry={product.reload} />
  }
  const p = product.data as AdminProduct
  const refresh = () => { product.reload(); history.reload() }
  const v = p.vendor_admin

  return (
    <>
      <PageHeader title={p.name} subtitle={[p.brand, p.model].filter(Boolean).join(' · ')} crumbs={[{ label: 'Overview', to: '/' }, { label: 'Products', to: '/products' }, { label: p.name }]}
        actions={<ProductActions product={p} showFeatured onChanged={refresh} />} />
      <p className="note">Listing content (name, price, photos, stock) belongs to the vendor and is not edited here. Administrators decide whether a listing is approved, active and featured; past orders keep the price and details they were placed with.</p>
      <div className="grid two">
        <Card title="Listing">
          <KeyValue rows={[
            ['Approval', <StatusBadge key="a" status={p.approval_status} />],
            ['Listing', <StatusBadge key="l" status={p.is_active ? 'active' : 'inactive'} />],
            ['Featured', p.is_featured ? 'Yes' : 'No'],
            ['Review note to vendor', p.review_notes ?? '—'],
            ['Reviewed', p.reviewed_at ? dateTime(p.reviewed_at) : '—'],
            ['Created', dateTime(p.created_at)],
            ['Updated', dateTime(p.updated_at)],
          ]} />
        </Card>
        <Card title="Price and inventory">
          <KeyValue rows={[
            ['Price', money(p.price)],
            ['Condition', humanize(p.condition)],
            ['Type', KIND_LABELS[p.product_type] ?? humanize(p.product_type)],
            ['Category', p.category?.name ?? '—'],
            ['Stock quantity', p.stock_quantity],
            ['Availability', <StatusBadge key="s" status={p.in_stock ? 'active' : 'inactive'} label={p.in_stock ? 'In stock' : 'Out of stock'} />],
          ]} />
        </Card>
      </div>
      <div className="grid two">
        <Card title="Vendor">
          {v ? <KeyValue rows={[
            ['Business', <Link key="b" to={`/vendors/${v.id}`}>{v.business_name}</Link>],
            ['Verification', <StatusBadge key="v" status={v.verification_status} />],
            ['Location', [v.city, v.state].filter(Boolean).join(', ') || '—'],
            ['Phone', v.contact_phone ?? '—'],
            ['E-mail', v.contact_email ?? '—'],
          ]} /> : <p className="muted">Vendor details are unavailable.</p>}
        </Card>
        <Card title="Description and specifications">
          <p>{p.description || <span className="muted">No description.</span>}</p>
          {Object.keys(p.specifications ?? {}).length > 0 && <KeyValue rows={Object.entries(p.specifications).map(([k, val]) => [humanize(k), String(val)])} />}
        </Card>
      </div>
      <Card title={`Images (${p.images.length})`}>
        {p.images.length === 0 ? <p className="muted">The vendor has not uploaded any image.</p> : (
          <div className="gallery">{p.images.map((im) => <figure key={im.id} style={{ margin: 0 }}><img src={im.url} alt={im.alt_text ?? p.name} />{im.is_primary && <figcaption className="muted small">Primary image</figcaption>}</figure>)}</div>
        )}
      </Card>
      <Card title="Moderation history"><AuditTrail state={history} empty="No moderation action has been recorded yet." /></Card>
    </>
  )
}
