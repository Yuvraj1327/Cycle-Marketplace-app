import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n)
    return statSync(p).isDirectory() ? walk(p) : [p]
  })
}
const root = join(process.cwd(), 'src')
const source = walk(root).filter((f) => /\.(ts|tsx)$/.test(f) && !f.includes('.test.') && !f.includes(`${join('src', 'test')}`))

const code = (f: string) => readFileSync(f, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

describe('no privileged credentials in the browser app', () => {
  it('source contains no service-role key, JWT, or secret-looking literal', () => {
    for (const f of source) {
      const text = code(f)
      expect(text, f).not.toMatch(/service[_-]?role/i)
      expect(text, f).not.toMatch(/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}/)             // a JWT literal
      expect(text, f).not.toMatch(/(secret|password)\s*[:=]\s*['"][^'"]{6,}['"]/i)         // hardcoded credentials
      expect(text, f).not.toMatch(/localStorage\.(get|set)Item\([^)]*(role|admin)/i)       // authorisation is never read from browser storage
    }
  })
  it('only the public Supabase URL/anon key and API base URL are read from the environment', () => {
    const vars = new Set<string>()
    for (const f of source) for (const m of code(f).matchAll(/\b(VITE_[A-Z_]+)/g)) vars.add(m[1])
    expect([...vars].sort()).toEqual(['VITE_API_BASE_URL', 'VITE_SUPABASE_ANON_KEY', 'VITE_SUPABASE_URL'])
  })
  it('.env.example documents public values only', () => {
    const env = readFileSync(join(process.cwd(), '.env.example'), 'utf8')
    expect(env).not.toMatch(/SERVICE_ROLE\s*=/i)
  })
  it('the only API origin used by services is the configured backend (no direct database access)', () => {
    for (const f of source.filter((x) => x.includes(join('src', 'services', 'api')))) {
      expect(code(f), f).not.toMatch(/\.from\(['"]/)                     // supabase.from(...) table access
    }
  })
})
