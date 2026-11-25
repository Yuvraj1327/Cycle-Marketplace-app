import { useServices } from '../../app/providers/authContext'
import { Button, Card, ErrorState, KeyValue, PageLoading } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { useAsync } from '../../hooks/useAsync'
import { useSettings } from '../../hooks/useSettings'
import { AuditTrail } from '../common/AuditTrail'
import { BoolSetting, ChoiceSetting, NumberSetting } from './SettingControls'

export function PlatformSettingsPage() {
  const s = useServices()
  const { state, get } = useSettings()
  const provider = useAsync(() => s.payments.provider(), [])
  const history = useAsync(() => s.settings.history(), [])
  const refresh = () => { state.reload(); history.reload() }
  const need = (k: string) => get(k)

  if (state.loading && !state.data) return <PageLoading />
  if (state.error && !state.data) return <ErrorState error={state.error} onRetry={state.reload} />

  return (
    <>
      <PageHeader title="Platform settings" subtitle="Checkout, payment and marketplace rules. Every change is validated by the server and recorded." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Settings' }]} actions={<Button onClick={state.reload}>Refresh</Button>} />
      <p className="note">Only settings the platform actually uses are listed. Delivery, pickup and drop-off charges are under “Pickup and Delivery Charges”.</p>
      <div className="grid two">
        <Card title="Payments">
          {need('payments.cod_enabled') && <BoolSetting setting={need('payments.cod_enabled')!} title="Cash on delivery" onLabel="Customers can pay cash on delivery" onSaved={refresh}
            confirmOff="Customers will no longer be able to choose cash on delivery at checkout. Existing cash orders are not affected." />}
          {need('payments.online_enabled') && <BoolSetting setting={need('payments.online_enabled')!} title="Online payments" onLabel="Customers can pay online" onSaved={refresh}
            confirmOff="Customers will no longer be able to pay online at checkout. Existing orders are not affected." />}
          {need('checkout.payment_window_minutes') && <NumberSetting setting={need('checkout.payment_window_minutes')!} title="Payment window" label="Minutes to complete an online payment" min={5} max={1440} unit="minutes" onSaved={refresh} />}
          <h3>Payment provider</h3>
          {provider.error ? <ErrorState compact error={provider.error} onRetry={provider.reload} /> : (
            <KeyValue rows={[['Status', provider.data ? (provider.data.configured ? `Configured${provider.data.provider ? ` (${provider.data.provider})` : ''}` : 'Not configured') : 'Checking…'],
              ['Credentials', 'Held on the server only. They are never sent to or shown in this console.']]} />
          )}
          {provider.data && !provider.data.configured && <p className="note">Online payments and provider refunds stay unavailable until a provider is configured on the server (this needs a provider choice and credentials from the client).</p>}
        </Card>
        <Card title="Marketplace">
          {need('marketplace.require_listing_approval') && <BoolSetting setting={need('marketplace.require_listing_approval')!} title="Listing approval" onLabel="New product listings need administrator approval" onSaved={refresh}
            confirmOff="New product listings may go live without review. Check what “approval not required” does in your policy before turning this off." />}
          {need('checkout.multi_vendor_policy') && <ChoiceSetting setting={need('checkout.multi_vendor_policy')!} title="Multi-vendor checkout" label="Items from several vendors in one order" onSaved={refresh}
            options={[{ value: 'single_vendor_only', label: 'One vendor per checkout' }, { value: 'allow_multi_vendor', label: 'Allow several vendors in one checkout' }]} />}
          {need('commission.missing_rule_policy') && <ChoiceSetting setting={need('commission.missing_rule_policy')!} title="When no commission rule matches" label="Checkout behaviour" onSaved={refresh}
            options={[{ value: 'block', label: 'Block checkout (safe default)' }, { value: 'zero', label: 'Charge no commission' }]} />}
          <p className="muted small">Whether customers can buy from several vendors in one checkout is still an open client decision.</p>
        </Card>
      </div>
      <Card title="Service booking window">
        <div className="grid two">
          {need('services.min_notice_hours') && <NumberSetting setting={need('services.min_notice_hours')!} title="Minimum notice" label="Hours between booking and appointment" min={0} max={168} unit="hours" onSaved={refresh} />}
          {need('services.max_advance_days') && <NumberSetting setting={need('services.max_advance_days')!} title="Booking window" label="How far ahead customers can book" min={1} max={365} unit="days" onSaved={refresh} />}
        </div>
      </Card>
      <Card title="Settings change history"><AuditTrail state={history} empty="No setting has been changed yet." /></Card>
    </>
  )
}
