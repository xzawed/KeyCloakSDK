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
      // ⚠️ **`src/transport.ts` 는 2026-09-10 에 제외에서 뺐다 — 다시 넣지 말 것.** 그 파일은
      // 네트워크를 타지 않는 **순수 분류기**다(`isTransportError`). 「실동작은 경계 테스트가
      // 검증한다」던 주석은 거짓이었다: 경계 테스트가 치는 팔이 `AbortError`·`ECONNREFUSED`
      // **둘뿐**이었고, 제외 때문에 나머지 15개 코드가 측정되지도 않아 **TLS 만료 코드를 지워도
      // 107 전부 통과**했다(변이 프로브 `SILENT`, 실측 2026-09-10). `test/unit/transport.test.ts`
      // 가 전수를 치고, 이 제외가 없어야 그 커버가 게이트에 들어온다.
      exclude: ['src/index.ts', 'src/auth.ts', 'src/admin/**'],
      // text: 로컬 콘솔 요약, lcov: SonarCloud(sonar.javascript.lcov.reportPaths=node/coverage/lcov.info)
      reporter: ['text', 'lcov'],
      thresholds: { lines: 90, branches: 85, functions: 90, statements: 90 },
    },
  },
})
