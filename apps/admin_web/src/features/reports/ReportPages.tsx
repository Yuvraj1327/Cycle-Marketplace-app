import { DailyBars, DistributionBars } from '../../components/charts/charts'
import { Card, MetricCard } from '../../components/common/ui'
import { DataTable, type Column } from '../../components/tables/DataTable'
import type { CountValue } from '../../types/api'
import { humanize, money } from '../../utils/format'
import { ReportShell } from './ReportShell'

type Counts = Record<string, number>
interface Day { day: string; count: number; value?: number }
const rows = (c: Counts | undefined, tones: Record<string, string> = {}) => Object.entries(c ?? {}).map(([k, v]) => ({ label: humanize(k), value: v, tone: tones[k] }))
const STATUS_TONES = { pending: 'amber', confirmed: 'blue', accepted: 'blue', completed: 'green', delivered: 'green', cancelled: 'red', rejected: 'red', approved: 'green', suspended: 'red', active: 'green', inactive: 'gray', restricted: 'amber', in_service: 'amber', successful: 'green', failed: 'red', processed: 'green', requested: 'amber' } as Record<string, string>
const amountRows = (c: Record<string, CountValue> | undefined) => Object.entries(c ?? {}).map(([k, v]) => ({ label: humanize(k), value: v.count, amount: v.amount }))

function Distribution({ title, counts }: { title: string; counts: Counts | undefined }) {
  return <Card title={title}><DistributionBars rows={rows(counts, STATUS_TONES)} /></Card>
}
const bars = (s: Day[], pick: 'count' | 'value' = 'count') => s.map((d) => ({ day: d.day, value: pick === 'value' ? (d.value ?? 0) : d.count }))
function Table<T>({ title, empty, data, columns, rowKey }: { title: string; empty: string; data: T[]; columns: Column<T>[]; rowKey: (r: T) => string }) {
  return <Card title={title}><DataTable caption={title} columns={columns} rows={data} rowKey={rowKey} emptyTitle={empty} /></Card>
}

// ------------------------------------------------------------------ orders
interface OrdersData { total: number; value: number; by_status: Counts; by_payment_method: Counts; by_payment_status: Counts; series: Day[] }
export function OrderReport() {
  return (
    <ReportShell<OrdersData> kind="orders" title="Order reports" subtitle="How many orders were placed and where they stand." definition="Counts orders placed in the period; value excludes cancelled orders.">
      {(d) => (
        <>
          <div className="grid metrics">
            <MetricCard label="Orders placed" value={d.total} />
            <MetricCard label="Order value" value={money(d.value)} hint="Excluding cancelled" />
            <MetricCard label="Pending" value={d.by_status.pending ?? 0} tone="warn" />
            <MetricCard label="Confirmed" value={d.by_status.confirmed ?? 0} />
            <MetricCard label="Completed" value={d.by_status.completed ?? 0} tone="good" />
            <MetricCard label="Cancelled" value={d.by_status.cancelled ?? 0} tone="bad" />
          </div>
          <div className="grid two">
            <Card title="Orders per day"><DailyBars points={bars(d.series)} label="Orders per day" /></Card>
            <Card title="Order value per day"><DailyBars points={bars(d.series, 'value')} label="Order value per day" format={money} color="var(--c-green)" /></Card>
          </div>
          <div className="grid two">
            <Distribution title="By order status" counts={d.by_status} />
            <Distribution title="By payment method" counts={d.by_payment_method} />
          </div>
          <Distribution title="By payment status" counts={d.by_payment_status} />
        </>
      )}
    </ReportShell>
  )
}

// ------------------------------------------------------------------ sales
interface SalesData { delivered_orders: number; gross_sales: number; delivery_charges: number; discounts: number; commission: number; series: Day[]
  by_vendor: { vendor_id: string; vendor_name: string; orders: number; sales: number; commission: number }[]; by_product: { product_id: string | null; product_name: string; units: number; sales: number }[] }
export function SalesReport() {
  return (
    <ReportShell<SalesData> kind="sales" title="Sales reports" subtitle="Sales on vendor orders that were delivered." definition="A sale is the item value of a vendor order on the day it was delivered. Orders not yet delivered or cancelled are not sales.">
      {(d) => (
        <>
          <div className="grid metrics">
            <MetricCard label="Delivered orders" value={d.delivered_orders} />
            <MetricCard label="Gross sales" value={money(d.gross_sales)} hint="Item value" tone="good" />
            <MetricCard label="Platform commission" value={money(d.commission)} />
            <MetricCard label="Vendors' share" value={money(d.gross_sales - d.commission)} hint="Sales minus commission" />
            <MetricCard label="Delivery charges" value={money(d.delivery_charges)} />
            <MetricCard label="Discounts given" value={money(d.discounts)} />
          </div>
          <Card title="Sales per day"><DailyBars points={bars(d.series, 'value')} label="Sales per day" format={money} color="var(--c-green)" /></Card>
          <div className="grid two">
            <Table title="Top vendors" empty="No sales in this period" data={d.by_vendor} rowKey={(r) => r.vendor_id} columns={[
              { key: 'v', header: 'Vendor', render: (r) => r.vendor_name }, { key: 'o', header: 'Orders', align: 'right', render: (r) => r.orders }, { key: 's', header: 'Sales', align: 'right', render: (r) => money(r.sales) }, { key: 'c', header: 'Commission', align: 'right', render: (r) => money(r.commission) }]} />
            <Table title="Top products" empty="No sales in this period" data={d.by_product} rowKey={(r) => `${r.product_id}-${r.product_name}`} columns={[
              { key: 'p', header: 'Product', render: (r) => r.product_name }, { key: 'u', header: 'Units', align: 'right', render: (r) => r.units }, { key: 's', header: 'Sales', align: 'right', render: (r) => money(r.sales) }]} />
          </div>
        </>
      )}
    </ReportShell>
  )
}

// ------------------------------------------------------------------ vendors
interface VendorsData { total: number; new_in_period: number; by_verification: Counts; by_account_status: Counts; series: Day[]
  performance: { vendor_id: string; business_name: string; verification_status: string; products: number; orders_delivered: number; sales: number; bookings_completed: number }[] }
export function VendorReport() {
  return (
    <ReportShell<VendorsData> kind="vendors" title="Vendor reports" subtitle="Registrations, approvals and what each vendor achieved." definition="Registration figures are all-time; performance counts deliveries and completed services in the period.">
      {(d) => (
        <>
          <div className="grid metrics">
            <MetricCard label="Registered vendors" value={d.total} hint={`${d.new_in_period} new in period`} />
            <MetricCard label="Approved" value={d.by_verification.approved ?? 0} tone="good" />
            <MetricCard label="Pending" value={d.by_verification.pending ?? 0} tone="warn" />
            <MetricCard label="Suspended" value={d.by_verification.suspended ?? 0} tone="bad" />
            <MetricCard label="Rejected" value={d.by_verification.rejected ?? 0} />
          </div>
          <div className="grid two">
            <Card title="New vendors per day"><DailyBars points={bars(d.series)} label="New vendors per day" /></Card>
            <Distribution title="Vendor accounts by status" counts={d.by_account_status} />
          </div>
          <Table title="Vendor performance (top 20 by sales)" empty="No vendors yet" data={d.performance} rowKey={(r) => r.vendor_id} columns={[
            { key: 'b', header: 'Vendor', render: (r) => r.business_name }, { key: 'v', header: 'Verification', render: (r) => humanize(r.verification_status) }, { key: 'p', header: 'Products', align: 'right', render: (r) => r.products },
            { key: 'o', header: 'Orders delivered', align: 'right', render: (r) => r.orders_delivered }, { key: 's', header: 'Sales', align: 'right', render: (r) => money(r.sales) }, { key: 'b2', header: 'Services completed', align: 'right', render: (r) => r.bookings_completed }]} />
        </>
      )}
    </ReportShell>
  )
}

// ------------------------------------------------------------------ customers
interface CustomersData { total: number; new_in_period: number; by_status: Counts; active_in_period: number; orders_in_period: number; bookings_in_period: number; series: Day[]
  top_customers: { customer_id: string; full_name: string | null; orders: number; order_value: number; bookings: number }[] }
export function CustomerReport() {
  return (
    <ReportShell<CustomersData> kind="customers" title="Customer reports" subtitle="Who signed up and who is buying or booking." definition="Registrations are all-time; “active” means placed an order or booked a service in the period.">
      {(d) => (
        <>
          <div className="grid metrics">
            <MetricCard label="Registered customers" value={d.total} hint={`${d.new_in_period} new in period`} />
            <MetricCard label="Active in period" value={d.active_in_period} tone="good" hint="Ordered or booked" />
            <MetricCard label="Orders in period" value={d.orders_in_period} />
            <MetricCard label="Service bookings in period" value={d.bookings_in_period} />
          </div>
          <div className="grid two">
            <Card title="New customers per day"><DailyBars points={bars(d.series)} label="New customers per day" /></Card>
            <Distribution title="Customer accounts by status" counts={d.by_status} />
          </div>
          <Table title="Most active customers" empty="No customer ordered in this period" data={d.top_customers} rowKey={(r) => r.customer_id} columns={[
            { key: 'n', header: 'Customer', render: (r) => r.full_name ?? '—' }, { key: 'o', header: 'Orders', align: 'right', render: (r) => r.orders }, { key: 'v', header: 'Order value', align: 'right', render: (r) => money(r.order_value) }, { key: 'b', header: 'Bookings', align: 'right', render: (r) => r.bookings }]} />
        </>
      )}
    </ReportShell>
  )
}

// ------------------------------------------------------------------ services
interface ServicesData { total: number; by_status: Counts; completed_value: number; series: Day[]
  by_vendor: { vendor_id: string; vendor_name: string; total: number; completed: number; cancelled_or_rejected: number }[]; by_category: { category_name: string; total: number }[]
  pickup: { bookings_needing_pickup: number; requests: number; pickup_by_status: Counts; delivery_by_status: Counts } }
export function ServiceReport() {
  return (
    <ReportShell<ServicesData> kind="services" title="Service reports" subtitle="Servicing bookings, completions and pickup/drop-off activity." definition="Counts bookings created in the period; the completed value is the final (or estimated) price of completed bookings.">
      {(d) => (
        <>
          <div className="grid metrics">
            <MetricCard label="Bookings" value={d.total} />
            <MetricCard label="Pending" value={d.by_status.pending ?? 0} tone="warn" />
            <MetricCard label="Completed" value={d.by_status.completed ?? 0} tone="good" />
            <MetricCard label="Cancelled" value={d.by_status.cancelled ?? 0} tone="bad" />
            <MetricCard label="Rejected" value={d.by_status.rejected ?? 0} />
            <MetricCard label="Completed value" value={money(d.completed_value)} />
          </div>
          <div className="grid two">
            <Card title="Bookings per day"><DailyBars points={bars(d.series)} label="Bookings per day" /></Card>
            <Distribution title="By booking status" counts={d.by_status} />
          </div>
          <div className="grid two">
            <Table title="Activity by vendor" empty="No bookings in this period" data={d.by_vendor} rowKey={(r) => r.vendor_id} columns={[
              { key: 'v', header: 'Vendor', render: (r) => r.vendor_name }, { key: 't', header: 'Bookings', align: 'right', render: (r) => r.total }, { key: 'c', header: 'Completed', align: 'right', render: (r) => r.completed }, { key: 'x', header: 'Cancelled / rejected', align: 'right', render: (r) => r.cancelled_or_rejected }]} />
            <Table title="By service category" empty="No bookings in this period" data={d.by_category} rowKey={(r) => r.category_name} columns={[{ key: 'c', header: 'Category', render: (r) => r.category_name }, { key: 't', header: 'Bookings', align: 'right', render: (r) => r.total }]} />
          </div>
          <Card title="Pickup and drop-off">
            <div className="grid metrics"><MetricCard label="Bookings needing pickup" value={d.pickup.bookings_needing_pickup} /><MetricCard label="Pickup requests" value={d.pickup.requests} /></div>
            <div className="grid two"><Distribution title="Pickup status" counts={d.pickup.pickup_by_status} /><Distribution title="Return delivery status" counts={d.pickup.delivery_by_status} /></div>
          </Card>
        </>
      )}
    </ReportShell>
  )
}

// ------------------------------------------------------------------ payments
interface PaymentsData { total: number; by_status: Record<string, CountValue>; by_method: Record<string, CountValue>; collected: number; collected_by_method: Record<string, CountValue>; refunded: number
  refunds_by_status: Record<string, CountValue>; commission: number; series: Day[] }
const amountCols = (first: string): Column<{ label: string; value: number; amount: number }>[] => [{ key: 'l', header: first, render: (r) => r.label }, { key: 'c', header: 'Count', align: 'right', render: (r) => r.value }, { key: 'a', header: 'Amount', align: 'right', render: (r) => money(r.amount) }]
export function PaymentReport() {
  return (
    <ReportShell<PaymentsData> kind="payments" title="Payment reports" subtitle="What was collected, refunded and kept." definition="Status and method tables count payments created in the period; “collected” and “refunded” count money that actually moved in the period. Cash on delivery counts only once an administrator recorded the cash.">
      {(d) => (
        <>
          <div className="grid metrics">
            <MetricCard label="Collected" value={money(d.collected)} tone="good" hint={`${Object.values(d.collected_by_method).reduce((n, v) => n + v.count, 0)} payments`} />
            <MetricCard label="Online collected" value={money(d.collected_by_method.online?.amount ?? 0)} />
            <MetricCard label="Cash collected" value={money(d.collected_by_method.cod?.amount ?? 0)} />
            <MetricCard label="Refunded (processed)" value={money(d.refunded)} />
            <MetricCard label="Platform commission" value={money(d.commission)} />
            <MetricCard label="Payments created" value={d.total} />
          </div>
          <Card title="Collections per day"><DailyBars points={bars(d.series, 'value')} label="Collected per day" format={money} color="var(--c-green)" /></Card>
          <div className="grid two">
            <Table title="Payments by status" empty="No payments in this period" data={amountRows(d.by_status)} rowKey={(r) => r.label} columns={amountCols('Status')} />
            <Table title="Payments by method" empty="No payments in this period" data={amountRows(d.by_method)} rowKey={(r) => r.label} columns={amountCols('Method')} />
          </div>
          <div className="grid two">
            <Table title="Collected by method" empty="Nothing collected in this period" data={amountRows(d.collected_by_method)} rowKey={(r) => r.label} columns={amountCols('Method')} />
            <Table title="Refunds by status" empty="No refunds in this period" data={amountRows(d.refunds_by_status)} rowKey={(r) => r.label} columns={amountCols('Status')} />
          </div>
        </>
      )}
    </ReportShell>
  )
}
