import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useServices } from '../../app/providers/authContext'
import { useToast } from '../../app/providers/toastContext'
import { AccountActions } from '../../components/common/AccountActions'
import { Button, Card, Pagination, SearchInput, SelectFilter, StatusBadge } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { DataTable, type Column } from '../../components/tables/DataTable'
import { useAsync } from '../../hooks/useAsync'
import { useDebounce } from '../../hooks/useDebounce'
import { useListQuery } from '../../hooks/useListQuery'
import type { AccountStatus, CustomerListItem, SortBy } from '../../types/api'
import { dateOnly, shortId } from '../../utils/format'

const LIMIT = 20

export function CustomersPage() {
  const s = useServices()
  const toast = useToast()
  const nav = useNavigate()
  const { values, page, set, setPage } = useListQuery(['q', 'status', 'sort'] as const)
  const [text, setText] = useState(values.q)
  const debounced = useDebounce(text)
  useEffect(() => { if (debounced !== values.q) set({ q: debounced }) }, [debounced]) // eslint-disable-line react-hooks/exhaustive-deps

  const status = values.status as AccountStatus | ''
  const sort = (values.sort || 'newest') as SortBy
  const list = useAsync(() => s.customers.list({ q: values.q, status, sort, page, limit: LIMIT }), [values.q, status, sort, page])

  const columns: Column<CustomerListItem>[] = [
    { key: 'id', header: 'ID', render: (c) => <code title={c.id}>{shortId(c.id)}</code> },
    { key: 'name', header: 'Customer', render: (c) => <Link to={`/customers/${c.id}`} onClick={(e) => e.stopPropagation()}><strong>{c.full_name || 'Unnamed customer'}</strong></Link> },
    { key: 'email', header: 'E-mail', render: (c) => c.email ?? '—' },
    { key: 'phone', header: 'Phone', render: (c) => c.phone ?? '—' },
    { key: 'reg', header: 'Registered', render: (c) => dateOnly(c.created_at) },
    { key: 'status', header: 'Status', render: (c) => <StatusBadge status={c.status} /> },
    { key: 'orders', header: 'Orders', align: 'right', render: (c) => c.order_count ?? '—' },
    { key: 'bookings', header: 'Bookings', align: 'right', render: (c) => c.booking_count ?? '—' },
    {
      key: 'actions', header: 'Actions', align: 'right',
      render: (c) => (
        <span className="row-actions" onClick={(e) => e.stopPropagation()}>
          <Button size="sm" onClick={() => nav(`/customers/${c.id}`)}>View</Button>
          <AccountActions size="sm" current={c.status} who={c.full_name || c.email || 'This customer'} apply={async (st, reason) => {
            await s.customers.setStatus(c.id, st, reason)
            toast.success(`Customer ${st === 'active' ? 'activated' : st === 'inactive' ? 'deactivated' : 'restricted'}`)
            list.reload()
          }} />
        </span>
      ),
    },
  ]

  return (
    <>
      <PageHeader title="Customers" subtitle="Registered customers of the marketplace." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Customers' }]} actions={<Button onClick={list.reload}>Refresh</Button>} />
      <Card>
        <div className="toolbar">
          <SearchInput value={text} onChange={setText} placeholder="Search name, e-mail or phone" />
          <SelectFilter label="Status" value={status} onChange={(v) => set({ status: v })} options={[{ value: '', label: 'All' }, { value: 'active', label: 'Active' }, { value: 'inactive', label: 'Inactive' }, { value: 'restricted', label: 'Restricted' }]} />
          <SelectFilter label="Sort" value={sort} onChange={(v) => set({ sort: v === 'newest' ? '' : v })} options={[{ value: 'newest', label: 'Newest first' }, { value: 'oldest', label: 'Oldest first' }, { value: 'name', label: 'Name A–Z' }]} />
        </div>
        <DataTable caption="Customers" columns={columns} rows={list.data?.items ?? null} rowKey={(c) => c.id} loading={list.loading} error={list.error} onRetry={list.reload}
          onRowClick={(c) => nav(`/customers/${c.id}`)} emptyTitle="No customers found" emptyMessage={values.q || status ? 'Try changing the search or filters.' : 'Customers appear here once they register.'} />
        {list.data && <Pagination page={list.data.page} pages={list.data.pages} total={list.data.total} limit={LIMIT} onPage={setPage} />}
      </Card>
    </>
  )
}
