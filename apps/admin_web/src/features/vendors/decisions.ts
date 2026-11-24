import type { VendorListItem } from '../../types/api'

export type Decision = 'approve' | 'reject' | 'suspend' | 'reinstate'

/** The decisions that are valid for a vendor's current verification state (the backend enforces the same rules and refuses repeats with 409). */
export function decisionsFor(status: VendorListItem['verification_status']): Decision[] {
  return { pending: ['approve', 'reject'], rejected: ['approve'], approved: ['suspend'], suspended: ['reinstate'] }[status] as Decision[]
}

