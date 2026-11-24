import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { Button, Card, Pagination, SearchInput, SelectFilter, StatusBadge } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useDebounce } from '../../hooks/useDebounce'
import { useListQuery } from '../../hooks/useListQuery'
import type { AccountStatus, BusinessType, SortBy, VendorListItem, VerificationStatus } from '../../types/api'
import { dateOnly, shortId } from '../../utils/format'
import { BUSINESS_LABELS } from '../../utils/labels'
import { VendorDecisionButtons } from './VendorDecisions'

const LIMIT = 20

export function VendorsPage() {
  const s = useServices()
  const nav = useNavigate()
  const { values, page, set, setPage } = useListQuery(['q', 'business_type', 'verification_status', 'account_status', 'sort'] as const)
  const [text, setText] = useState(values.q)
  const debounced = useDebounce(text)
  useEffect(() => { if (debounced !== values.q) set({ q: debounced }) }, [debounced]) // eslint-disable-line react-hooks/exhaustive-deps

  const bt = values.business_type as BusinessType | ''
  const vs = values.verification_status as VerificationStatus | ''
  const as = values.account_status as AccountStatus | ''
  const sort = (values.sort || 'newest') as SortBy
  const list = useAsync(() => s.vendors.list({ q: values.q, business_type: bt, verification_status: vs, account_status: as, sort, page, limit: LIMIT }), [values.q, bt, vs, as, sort, page])
  const pendingOnly = vs === 'pending'

  const columns: Column<VendorListItem>[] = [
    { key: 'id', header: 'ID', render: (v) => <code title={v.id}>{shortId(v.id)}</code> },
    { key: 'biz', header: 'Business', render: (v) => <Link to={`/vendors/${v.id}`} onClick={(e) => e.stopPropagation()}><strong>{v.business_name}</strong></Link> },
    { key: 'owner', header: 'Vendor', render: (v) => <>{v.owner_name ?? '—'}<div className="muted small">{v.owner_email ?? ''}</div></> },
    { key: 'type', header: 'Type', render: (v) => v.business_types.map((t) => BUSINESS_LABELS[t] ?? t).join(', ') },
    { key: 'contact', header: 'Contact', render: (v) => <>{v.contact_phone}<div className="muted small">{v.contact_email ?? ''}</div></> },
    { key: 'loc', header: 'Location', render: (v) => `${v.city}, ${v.state}` },
    { key: 'reg', header: 'Registered', render: (v) => dateOnly(v.created_at) },
    { key: 'vs', header: 'Verification', render: (v) => <StatusBadge status={v.verification_status} /> },
    { key: 'as', header: 'Account', render: (v) => <StatusBadge status={v.account_status} /> },
    {
      key: 'actions', header: 'Actions', align: 'right',
      render: (v) => (
        <span className="row-actions" onClick={(e) => e.stopPropagation()}>
          <Button size="sm" onClick={() => nav(`/vendors/${v.id}`)}>{v.verification_status === 'pending' ? 'Review' : 'View'}</Button>
          <VendorDecisionButtons size="sm" vendor={v} onChanged={list.reload} />
        </span>
      ),
    },
  ]

  return (
    <>
      <PageHeader title="Vendors" subtitle="Vendor applications and approved businesses." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Vendors' }]} actions={<Button onClick={list.reload}>Refresh</Button>} />
      <div className="tabs" role="tablist" aria-label="Vendor views">
        <button type="button" role="tab" aria-selected={!pendingOnly} className={!pendingOnly ? 'tab active' : 'tab'} onClick={() => set({ verification_status: '' })}>All vendors</button>
        <button type="button" role="tab" aria-selected={pendingOnly} className={pendingOnly ? 'tab active' : 'tab'} onClick={() => set({ verification_status: 'pending', sort: 'oldest' })}>Pending applications</button>
      </div>
      <Card>
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search business, city, owner, e-mail, phone" />
          <SelectFilter label="Business type" value={bt} onChange={(v) => set({ business_type: v })} options={[{ value: '', label: 'All types' }, ...(Object.entries(BUSINESS_LABELS) as [BusinessType, string][]).map(([value, label]) => ({ value, label }))]} />
          <SelectFilter label="Verification" value={vs} onChange={(v) => set({ verification_status: v })} options={[{ value: '', label: 'All' }, { value: 'pending', label: 'Pending' }, { value: 'approved', label: 'Approved' }, { value: 'rejected', label: 'Rejected' }, { value: 'suspended', label: 'Suspended' }]} />
          <SelectFilter label="Account" value={as} onChange={(v) => set({ account_status: v })} options={[{ value: '', label: 'All' }, { value: 'active', label: 'Active' }, { value: 'inactive', label: 'Inactive' }, { value: 'restricted', label: 'Restricted' }]} />
          <SelectFilter label="Sort" value={sort} onChange={(v) => set({ sort: v === 'newest' ? '' : v })} options={[{ value: 'newest', label: 'Newest first' }, { value: 'oldest', label: 'Oldest first' }, { value: 'name', label: 'Business A–Z' }]} />
        </div>
        <DataTable caption="Vendors" columns={columns} rows={list.data?.items ?? null} rowKey={(v) => v.id} loading={list.loading} error={list.error} onRetry={list.reload}
          onRowClick={(v) => nav(`/vendors/${v.id}`)} emptyTitle={pendingOnly ? 'No pending applications' : 'No vendors found'}
          emptyMessage={pendingOnly ? 'New vendor applications waiting for review will appear here.' : 'Try changing the search or filters.'} />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
    </>
  )
}
