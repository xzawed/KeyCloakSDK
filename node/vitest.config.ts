import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // 단위테스트만 — 통합(Docker 필요)은 vitest.integration.config.ts로 분리해, 기본 커버리지
    // 실행(`npm test`)이 testcontainers를 기동하지 않게 한다.
    include: ['test/unit/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      // 네트워크 경계(생성/실호출)는 통합테스트로만 검증 → 커버리지에서 omit.
      // transport.ts는 auth/admin 경계가 공유하는 전송오류 분류 유틸(원래 admin/call.ts 내부라
      // 이미 omit이었음) — 실동작은 경계 테스트가 검증.
      exclude: ['src/index.ts', 'src/auth.ts', 'src/admin/**', 'src/transport.ts'],
      // text: 로컬 콘솔 요약, lcov: SonarCloud(sonar.javascript.lcov.reportPaths=node/coverage/lcov.info)
      reporter: ['text', 'lcov'],
      thresholds: { lines: 90, branches: 85, functions: 90, statements: 90 },
    },
  },
})
