import { defineConfig } from 'vitest/config'

// Contract tests: the admin console's REAL services + API client talk over real HTTP to the REAL FastAPI app started by
// backend/tests/dev_server.py (in-memory DB, locally signed JWTs). Not a real Supabase / gateway test.
export default defineConfig({
  test: { environment: 'node', include: ['src/test/contract/**/*.test.ts'], testTimeout: 30_000, fileParallelism: false },
})
