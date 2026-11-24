import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // Unit tests only — the integration drive (test/integration) is not in this include.
    include: ['test/unit/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      // network boundary (fixture) — out of the unit gate, so only the unit-unreached ledger measures it
      exclude: ['src/auth_client.ts'],
      reporter: ['text'],
      // The boundary cannot meet these — the ledger run must not inherit them (it would exit 1 on a gate it does not own).
      thresholds: { lines: 100, branches: 100, functions: 100, statements: 100 },
    },
  },
})
