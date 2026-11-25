import { humanize } from './format'

/** Shared filter / label options (kept out of component files so those only export components). */
export const KIND_LABELS: Record<string, string> = { new_cycle: 'New cycles', used_cycle: 'Used cycles', spare_part: 'Spare parts', accessory: 'Accessories' }
export const ORDER_STATUSES = [{ value: '', label: 'All' }, { value: 'pending', label: 'Pending' }, { value: 'confirmed', label: 'Confirmed' }, { value: 'completed', label: 'Completed' }, { value: 'cancelled', label: 'Cancelled' }]
export const PAYMENT_STATUSES = [{ value: '', label: 'All' }, ...['pending', 'processing', 'successful', 'failed', 'cancelled', 'refunded', 'partially_refunded'].map((v) => ({ value: v, label: humanize(v) }))]
export const METHODS = [{ value: '', label: 'All' }, { value: 'online', label: 'Online' }, { value: 'cod', label: 'Cash on delivery' }]
export const BOOKING_STATUSES = [{ value: '', label: 'All' }, ...['pending', 'accepted', 'rejected', 'picked_up', 'in_service', 'ready_for_delivery', 'completed', 'cancelled'].map((v) => ({ value: v, label: humanize(v) }))]
