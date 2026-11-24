import { useState } from 'react'
import type { AccountStatus } from '../../types/api'
import { Button, ConfirmDialog } from './ui'

const COPY: Record<AccountStatus, { label: string; verb: string; danger: boolean; message: (who: string) => string }> = {
  active: { label: 'Activate', verb: 'Activate account', danger: false, message: (w) => `${w} will be able to sign in and use the platform again.` },
  inactive: { label: 'Deactivate', verb: 'Deactivate account', danger: true, message: (w) => `${w} will be signed out of every API and unable to use the platform. Their orders, bookings and history are kept.` },
  restricted: { label: 'Restrict', verb: 'Restrict account', danger: true, message: (w) => `${w} will be blocked from the platform until you lift the restriction. Their orders, bookings and history are kept.` },
}

/** Status transitions offered for an account (never delete). The dialog collects a reason (required unless activating), and the UI only
 *  reflects the change after the backend confirms: `apply` must resolve on success and throw on failure. */
export function AccountActions({ current, who, apply, size = 'md' }: { current: AccountStatus | null; who: string; apply: (status: AccountStatus, reason: string) => Promise<void>; size?: 'md' | 'sm' }) {
  const [target, setTarget] = useState<AccountStatus | null>(null)
  if (!current) return null
  const options = (['active', 'inactive', 'restricted'] as AccountStatus[]).filter((s) => s !== current)
  return (
    <>
      {options.map((s) => (
        <Button key={s} size={size} variant={COPY[s].danger ? 'secondary' : 'primary'} onClick={() => setTarget(s)}>{COPY[s].label}</Button>
      ))}
      {target && (
        <ConfirmDialog
          title={`${COPY[target].verb}?`}
          message={COPY[target].message(who)}
          confirmLabel={COPY[target].label}
          danger={COPY[target].danger}
          reasonLabel="Reason (kept in the audit log)"
          reasonRequired={target !== 'active'}
          onConfirm={(reason) => apply(target, reason)}
          onClose={() => setTarget(null)}
        />
      )}
    </>
  )
}
