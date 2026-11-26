import { afterEach, describe, expect, it } from 'vitest'
import { dateOnly, dateTime, setDisplayPreferences } from './format'

afterEach(() => setDisplayPreferences({}))

describe('date preferences', () => {
  const instant = '2026-03-27T20:30:00Z' // 02:00 on the 28th in India, 20:30 on the 27th in UTC

  it('formats in the chosen time zone and date format', () => {
    setDisplayPreferences({ timezone: 'Asia/Kolkata', dateFormat: 'D MMM YYYY' })
    expect(dateTime(instant)).toBe('28 Mar 2026, 2:00 am')
    setDisplayPreferences({ timezone: 'UTC', dateFormat: 'D MMM YYYY' })
    expect(dateTime(instant)).toBe('27 Mar 2026, 8:30 pm')
    setDisplayPreferences({ timezone: 'UTC', dateFormat: 'DD/MM/YYYY' })
    expect(dateOnly(instant)).toBe('27/03/2026')
    setDisplayPreferences({ timezone: 'UTC', dateFormat: 'MM/DD/YYYY' })
    expect(dateOnly(instant)).toBe('03/27/2026')
    setDisplayPreferences({ timezone: 'UTC', dateFormat: 'YYYY-MM-DD' })
    expect(dateOnly(instant)).toBe('2026-03-27')
  })

  it('never shifts a plain calendar day with the time zone', () => {
    for (const timezone of ['Asia/Kolkata', 'America/Los_Angeles', 'Australia/Sydney']) {
      setDisplayPreferences({ timezone, dateFormat: 'YYYY-MM-DD' })
      expect(dateOnly('2026-03-27')).toBe('2026-03-27')
    }
  })

  it('falls back instead of throwing on an unknown time zone, and shows a dash for missing values', () => {
    setDisplayPreferences({ timezone: 'Mars/Base' })
    expect(dateTime(instant)).toMatch(/2026/)
    expect(dateTime(null)).toBe('—')
    expect(dateOnly('nonsense')).toBe('—')
  })
})
