import type { SupabaseClient } from '@supabase/supabase-js'
import { describe, expect, it } from 'vitest'
import { createSupabaseGateway } from '../services/supabase/gateway'

/** A stand-in for supabase-js that behaves like the real one when Supabase is unreachable: a global sign-out fails and keeps the stored
 *  session; a local sign-out removes it without needing the network. */
function offlineClient() {
  const state = { stored: true, calls: [] as Array<string | undefined> }
  const client = {
    auth: {
      async signOut(opts?: { scope?: string }) {
        state.calls.push(opts?.scope)
        if (opts?.scope === 'local') {
          state.stored = false
          return { error: null }
        }
        return { error: new Error('Failed to fetch') }
      },
    },
  } as unknown as SupabaseClient
  return { client, state }
}

describe('sign-out', () => {
  it('ends the browser session even when Supabase cannot be reached', async () => {
    const { client, state } = offlineClient()
    await createSupabaseGateway(client).signOut()
    expect(state.stored).toBe(false)
    expect(state.calls).toContain('local')
  })

  it('does not fail when both attempts throw', async () => {
    const client = { auth: { signOut: () => Promise.reject(new Error('boom')) } } as unknown as SupabaseClient
    await expect(createSupabaseGateway(client).signOut()).resolves.toBeUndefined()
  })
})
