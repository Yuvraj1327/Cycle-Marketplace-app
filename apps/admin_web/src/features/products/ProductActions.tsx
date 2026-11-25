import { useState } from 'react'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, ConfirmDialog } from '../../components/common/ui'
import type { AdminProduct } from '../../types/api'

type Action = 'approve' | 'reject' | 'deactivate' | 'activate' | 'feature' | 'unfeature'

/** Moderation buttons for one listing. Every action is confirmed, sent to FastAPI (admin-only) and applied in the UI only after the backend answers.
 *  Admins never edit the vendor's listing content; they decide whether it is visible. */
export function ProductActions({ product, onChanged, size = 'md', showFeatured = false }: { product: AdminProduct; onChanged: (p: AdminProduct) => void; size?: 'sm' | 'md'; showFeatured?: boolean }) {
  const s = useServices()
  const toast = useToast()
  const [action, setAction] = useState<Action | null>(null)
  const live = product.is_active && product.approval_status === 'approved'

  const run = async (a: Action, reason: string) => {
    const updated = a === 'approve' ? await s.products.approve(product.id)
      : a === 'reject' ? await s.products.reject(product.id, reason)
      : a === 'deactivate' ? await s.products.setActive(product.id, false)
      : a === 'activate' ? await s.products.setActive(product.id, true)
      : await s.products.setFeatured(product.id, a === 'feature')
    toast.success({ approve: 'Listing approved.', reject: 'Listing rejected. The vendor can see your note.', deactivate: 'Listing deactivated.', activate: 'Listing activated.', feature: 'Product is now featured.', unfeature: 'Product removed from featured.' }[a])
    onChanged(updated)
  }

  const copy: Record<Action, { title: string; message: string; label: string; danger?: boolean; reason?: boolean }> = {
    approve: { title: 'Approve this listing?', message: `"${product.name}" becomes visible to customers${product.is_active ? '' : ' once it is activated'}.`, label: 'Approve' },
    reject: { title: 'Reject this listing?', message: `"${product.name}" is hidden from customers. The vendor sees your note.`, label: 'Reject', danger: true, reason: true },
    deactivate: { title: 'Deactivate this listing?', message: `"${product.name}" is hidden from customers and removed from featured. Past orders are not changed.`, label: 'Deactivate', danger: true },
    activate: { title: 'Activate this listing?', message: `"${product.name}" can be shown to customers again (it must also be approved).`, label: 'Activate' },
    feature: { title: 'Feature this product?', message: `"${product.name}" will appear in the featured section.`, label: 'Feature' },
    unfeature: { title: 'Remove from featured?', message: `"${product.name}" stays listed but is no longer featured.`, label: 'Remove' },
  }

  return (
    <span className="row-actions" onClick={(e) => e.stopPropagation()}>
      {product.approval_status !== 'approved' && <Button size={size} variant="primary" onClick={() => setAction('approve')}>{product.approval_status === 'rejected' ? 'Approve after review' : 'Approve'}</Button>}
      {product.approval_status !== 'rejected' && <Button size={size} onClick={() => setAction('reject')}>Reject</Button>}
      {product.is_active ? <Button size={size} onClick={() => setAction('deactivate')}>Deactivate</Button> : <Button size={size} onClick={() => setAction('activate')}>Activate</Button>}
      {showFeatured && (product.is_featured
        ? <Button size={size} onClick={() => setAction('unfeature')}>Remove from featured</Button>
        : <Button size={size} disabled={!live} title={live ? undefined : 'Only approved, active listings can be featured'} onClick={() => setAction('feature')}>Feature</Button>)}
      {action && (
        <ConfirmDialog title={copy[action].title} message={copy[action].message} confirmLabel={copy[action].label} danger={copy[action].danger}
          reasonLabel={copy[action].reason ? 'Reason shown to the vendor' : undefined} reasonRequired={copy[action].reason}
          onConfirm={(reason) => run(action, reason)} onClose={() => setAction(null)} />
      )}
    </span>
  )
}
