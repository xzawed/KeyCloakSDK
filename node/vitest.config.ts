import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      // 네트워크 경계(생성/실호출)는 통합테스트로만 검증 → 커버리지에서 omit
      exclude: ['src/index.ts', 'src/auth.ts', 'src/admin/**'],
      thresholds: { lines: 90, branches: 85, functions: 90, statements: 90 },
    },
  },
})
