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
      // ⚠️ **`src/admin/call.ts` 는 2026-09-15 에 제외에서 뺀다 — 다시 넣지 말 것.**
      // 그 파일은 네트워크를 안 탄다: `call` 은 호출자가 넘긴 `fn` 을 부를 뿐이고,
      // `statusOf`·`messageOf`·`requireFound` 는 인자만으로 결정된다. 제외 때문에 분기가
      // 측정되지 않아 **세 변이가 전부 `SILENT`** 였다(실측 2026-09-15, `scripts/probe.sh`):
      // `statusOf` 의 숫자 검사 제거 · `messageOf` 의 `?? error` 폴백 제거 · 기본 문구 변경.
      // `test/unit/admin-call.test.ts` 가 전수를 치고, 이 제외가 없어야 그 커버가 게이트에 들어온다.
      // 나머지 `src/admin/*.ts` 는 admin-client 위임이라 그대로 둔다.
      // ⚠️ 글롭이 아니라 **손 목록**인 것은 의도다 — 새 파일은 목록에 없어 **측정되는** 쪽으로
      // 빠진다(글롭이면 조용히 제외된다). 측정이 시끄럽고 제외가 조용하니 이 방향이 옳다.
      exclude: ['src/index.ts', 'src/auth.ts', 'src/admin/clients.ts', 'src/admin/groups.ts',
        'src/admin/realms.ts', 'src/admin/roles.ts', 'src/admin/users.ts',
        'src/admin/index.ts'],
      // text: 로컬 콘솔 요약, lcov: SonarCloud(sonar.javascript.lcov.reportPaths=node/coverage/lcov.info)
      reporter: ['text', 'lcov'],
      thresholds: { lines: 90, branches: 85, functions: 90, statements: 90 },
    },
  },
})
