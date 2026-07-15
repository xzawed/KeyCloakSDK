import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // 단위테스트만 — 통합(Docker 필요)은 vitest.integration.config.ts로 분리해, 기본 커버리지
    // 실행(`npm test`)이 testcontainers를 기동하지 않게 한다.
    include: ['test/unit/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      // 네트워크 경계(생성/실호출)는 통합테스트로만 검증 → 커버리지에서 omit
      exclude: ['src/index.ts', 'src/auth.ts', 'src/admin/**'],
      // text: 로컬 콘솔 요약, lcov: SonarCloud(sonar.javascript.lcov.reportPaths=node/coverage/lcov.info)
      reporter: ['text', 'lcov'],
      thresholds: { lines: 90, branches: 85, functions: 90, statements: 90 },
    },
  },
})
