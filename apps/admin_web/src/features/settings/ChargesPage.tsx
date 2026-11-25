import { Link } from 'react-router-dom'
import { Button, Card, ErrorState, PageLoading } from '../../components/common/ui'
import { PageHeader } from '../../components/layout/PageHeader'
import { useAsync } from '../../hooks/useAsync'
import { useServices } from '../../app/providers/authContext'
import { AuditTrail } from '../common/AuditTrail'
import { DeliveryChargeSetting, NumberSetting } from './SettingControls'
import { useSettings } from '../../hooks/useSettings'

export function ChargesPage() {
  const s = useServices()
  const { state, get } = useSettings()
  const history = useAsync(() => s.settings.history(), [])
  const refresh = () => { state.reload(); history.reload() }
  if (state.loading && !state.data) return <PageLoading />
  if (state.error && !state.data) return <ErrorState error={state.error} onRetry={state.reload} />
  const delivery = get('checkout.delivery_charge'), pickup = get('services.pickup_charge'), dropoff = get('services.dropoff_charge')

  return (
    <>
      <PageHeader title="Pickup and delivery charges" subtitle="What customers are charged for delivery and for doorstep pickup / drop-off." crumbs={[{ label: 'Overview', to: '/' }, { label: 'Settings', to: '/settings' }, { label: 'Charges' }]} actions={<Button onClick={state.reload}>Refresh</Button>} />
      <p className="note">Changes apply to orders and bookings made from now on. Amounts already recorded on existing orders and bookings never change. The amounts are for the client to decide: nothing is pre-filled.</p>
      <div className="grid two">
        <Card title="Product delivery">{delivery && <DeliveryChargeSetting setting={delivery} onSaved={refresh} />}</Card>
        <Card title="Service pickup and drop-off">
          {pickup && <NumberSetting setting={pickup} title="Pickup charge" label="Charge for collecting the cycle" min={0} max={100000} money unit="₹" onSaved={refresh} />}
          {dropoff && <NumberSetting setting={dropoff} title="Drop-off charge" label="Charge for returning the cycle" min={0} max={100000} money unit="₹" onSaved={refresh} />}
          <p className="muted small">While these are not set, bookings record ₹0 and are flagged as “charges not configured”. See <Link to="/pickups">Pickup &amp; drop-off</Link>.</p>
        </Card>
      </div>
      <Card title="Change history"><AuditTrail state={history} empty="No setting has been changed yet." /></Card>
    </>
  )
}
