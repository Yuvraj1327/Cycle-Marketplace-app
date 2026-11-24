import { useState } from 'react'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { AccountActions } from '../../components/common/AccountActions'
import { Button, ConfirmDialog } from '../../components/common/ui'
import type { VendorListItem } from '../../types/api'
import { decisionsFor, type Decision } from './decisions'

const COPY: Record<Decision, { label: string; title: (n: string) => string; message: string; danger: boolean; reason?: { label: string; required: boolean }; done: string }> = {
  approve: { label: 'Approve', title: (n) => `Approve ${n}?`, danger: false, done: 'Vendor approved',
    message: 'The vendor can immediately list products and services, receive orders and bookings, and is notified of the approval.',
    reason: { label: 'Note kept with the decision (optional)', required: false } },
  reject: { label: 'Reject', title: (n) => `Reject ${n}?`, danger: true, done: 'Application rejected',
    message: 'The vendor cannot operate. They are notified and shown your reason; they can correct the application and you can review it again.',
    reason: { label: 'Reason shown to the vendor', required: true } },
  suspend: { label: 'Suspend', title: (n) => `Suspend ${n}?`, danger: true, done: 'Vendor suspended',
    message: 'The vendor is blocked from every business operation immediately. Their products, orders, bookings and history are kept.',
    reason: { label: 'Reason shown to the vendor', required: true } },
  reinstate: { label: 'Reinstate', title: (n) => `Reinstate ${n}?`, danger: false, done: 'Vendor reinstated',
    message: 'The vendor can operate again.', reason: { label: 'Note kept with the decision (optional)', required: false } },
}

export function VendorDecisionButtons({ vendor, onChanged, size = 'md' }: { vendor: Pick<VendorListItem, 'id' | 'business_name' | 'verification_status' | 'account_status'>; onChanged: () => void; size?: 'md' | 'sm' }) {
  const s = useServices()
  const toast = useToast()
  const [open, setOpen] = useState<Decision | null>(null)

  async function run(d: Decision, reason: string) {
    // the UI changes only after the backend answers successfully (errors are thrown to the dialog and shown there)
    if (d === 'approve') await s.vendors.approve(vendor.id, reason || undefined)
    else if (d === 'reject') await s.vendors.reject(vendor.id, reason)
    else if (d === 'suspend') await s.vendors.suspend(vendor.id, reason)
    else await s.vendors.reinstate(vendor.id, reason || undefined)
    toast.success(COPY[d].done)
    onChanged()
  }

  return (
    <>
      {decisionsFor(vendor.verification_status).map((d) => (
        <Button key={d} size={size} variant={d === 'approve' || d === 'reinstate' ? 'primary' : 'secondary'} onClick={() => setOpen(d)}>{COPY[d].label}{d === 'approve' && vendor.verification_status === 'rejected' ? ' after review' : ''}</Button>
      ))}
      <AccountActions size={size} current={vendor.account_status} who={vendor.business_name} apply={async (st, reason) => {
        await s.vendors.setAccountStatus(vendor.id, st, reason)
        toast.success(`Vendor account ${st === 'active' ? 'activated' : st === 'inactive' ? 'deactivated' : 'restricted'}`)
        onChanged()
      }} />
      {open && (
        <ConfirmDialog
          title={COPY[open].title(vendor.business_name)}
          message={COPY[open].message}
          confirmLabel={COPY[open].label}
          danger={COPY[open].danger}
          reasonLabel={COPY[open].reason?.label}
          reasonRequired={COPY[open].reason?.required}
          onConfirm={(reason) => run(open, reason)}
          onClose={() => setOpen(null)}
        />
      )}
    </>
  )
}
