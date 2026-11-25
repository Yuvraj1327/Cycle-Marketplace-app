import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { Button, Card, ConfirmDialog, KeyValue, Modal, Pagination, SearchInput, SelectFilter, StatusBadge } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useListQuery } from '../../hooks/useListQuery'
import { useSearchBox } from '../../hooks/useSearchBox'
import type { AdminService } from '../../types/api'
import { dateOnly, money } from '../../utils/format'

const LIMIT = 20
const DAYS: Record<string, string> = { mon: 'Mon', tue: 'Tue', wed: 'Wed', thu: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun' }
const days = (s: AdminService) => (s.available_days?.length ? s.available_days.map((d) => DAYS[d] ?? d).join(', ') : 'Every day the vendor is open')

export function ServicesPage() {
  const s = useServices()
  const toast = useToast()
  const { values, page, set, setPage } = useListQuery(['q', 'vendor_id', 'category_id', 'is_available', 'is_active'] as const)
  const [text, setText] = useSearchBox(values.q, (q) => set({ q }))
  const cats = useAsync(() => s.serviceCategories.list(), [])
  const vendors = useAsync(() => s.vendors.list({ business_type: 'service_provider', limit: 100 }), [])
  const list = useAsync(() => s.services.list({ q: values.q, vendor_id: values.vendor_id, category_id: values.category_id, is_available: values.is_available, is_active: values.is_active, page, limit: LIMIT }),
    [values.q, values.vendor_id, values.category_id, values.is_available, values.is_active, page])
  const [open, setOpen] = useState<AdminService | null>(null)
  const [toggle, setToggle] = useState<AdminService | null>(null)

  const columns: Column<AdminService>[] = [
    { key: 'n', header: 'Service', render: (v) => <><strong>{v.name}</strong><div className="muted small">{v.description ? `${v.description.slice(0, 70)}${v.description.length > 70 ? '…' : ''}` : ''}</div></> },
    { key: 'c', header: 'Category', render: (v) => v.category?.name ?? '—' },
    { key: 'v', header: 'Vendor', render: (v) => <Link to={`/vendors/${v.vendor_id}`} onClick={(e) => e.stopPropagation()}>{v.vendor_name ?? '—'}</Link> },
    { key: 'p', header: 'Price', align: 'right', render: (v) => money(v.price) },
    { key: 'd', header: 'Est. time', render: (v) => (v.estimated_duration_minutes ? `${v.estimated_duration_minutes} min` : '—') },
    { key: 'av', header: 'Availability', render: (v) => <StatusBadge status={v.is_available ? 'active' : 'inactive'} label={v.is_available ? 'Available' : 'Unavailable'} /> },
    { key: 'st', header: 'Listing', render: (v) => <StatusBadge status={v.is_active ? 'active' : 'inactive'} /> },
    { key: 'a', header: '', align: 'right', render: (v) => <span className="row-actions" onClick={(e) => e.stopPropagation()}><Button size="sm" onClick={() => setOpen(v)}>Details</Button><Button size="sm" onClick={() => setToggle(v)}>{v.is_active ? 'Deactivate' : 'Activate'}</Button></span> },
  ]

  return (
    <>
      <PageHeader title="Services" subtitle="Servicing offered by vendors. Vendors own and price their services; administrators can switch one off." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Services' }]} actions={<Button onClick={list.reload}>Refresh</Button>} />
      <Card>
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search service name" />
          <SelectFilter label="Vendor" value={values.vendor_id} onChange={(v) => set({ vendor_id: v })} options={[{ value: '', label: 'All vendors' }, ...(vendors.data?.items ?? []).map((v) => ({ value: v.id, label: v.business_name }))]} />
          <SelectFilter label="Category" value={values.category_id} onChange={(v) => set({ category_id: v })} options={[{ value: '', label: 'All categories' }, ...(cats.data ?? []).map((c) => ({ value: c.id, label: c.name }))]} />
          <SelectFilter label="Availability" value={values.is_available} onChange={(v) => set({ is_available: v })} options={[{ value: '', label: 'All' }, { value: 'true', label: 'Available' }, { value: 'false', label: 'Unavailable' }]} />
          <SelectFilter label="Listing" value={values.is_active} onChange={(v) => set({ is_active: v })} options={[{ value: '', label: 'All' }, { value: 'true', label: 'Active' }, { value: 'false', label: 'Inactive' }]} />
        </div>
        <DataTable caption="Services" columns={columns} rows={list.data?.items ?? null} rowKey={(v) => v.id} loading={list.loading} error={list.error} onRetry={list.reload}
          onRowClick={setOpen} emptyTitle="No services found" emptyMessage="Try changing the search or filters." />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
      <p className="muted small">Administrators cannot create or edit a vendor's service. A vendor can re-activate their own service; to stop a vendor altogether, suspend the vendor.</p>
      {open && (
        <Modal title={open.name} wide onClose={() => setOpen(null)} footer={<Button onClick={() => setOpen(null)}>Close</Button>}>
          <KeyValue rows={[['Vendor', <Link key="v" to={`/vendors/${open.vendor_id}`}>{open.vendor_name}</Link>], ['Vendor status', <StatusBadge key="vs" status={open.vendor_status} />], ['Category', open.category?.name ?? '—'],
            ['Description', open.description ?? '—'], ['Price', money(open.price)], ['Estimated time', open.estimated_duration_minutes ? `${open.estimated_duration_minutes} minutes` : '—'],
            ['Available days', days(open)], ['Slot length', `${open.slot_minutes} minutes`], ['Bookings per slot', open.max_bookings_per_slot],
            ['Availability', open.is_available ? 'Available' : 'Unavailable'], ['Listing', open.is_active ? 'Active' : 'Inactive'], ['Created', dateOnly(open.created_at)]]} />
        </Modal>
      )}
      {toggle && (
        <ConfirmDialog title={toggle.is_active ? `Deactivate “${toggle.name}”?` : `Activate “${toggle.name}”?`} confirmLabel={toggle.is_active ? 'Deactivate' : 'Activate'} danger={toggle.is_active}
          reasonLabel={toggle.is_active ? 'Reason (sent to the vendor)' : undefined} reasonRequired={toggle.is_active}
          message={toggle.is_active ? 'Customers can no longer book this service. Existing bookings and the service record are kept.' : 'Customers can book this service again.'}
          onConfirm={async (reason) => { await s.services.setActive(toggle.id, !toggle.is_active, reason); toast.success(toggle.is_active ? 'Service deactivated.' : 'Service activated.'); list.reload() }} onClose={() => setToggle(null)} />
      )}
    </>
  )
}
