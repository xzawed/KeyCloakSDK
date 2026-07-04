import { defineConfig } from 'vitest/config'

// 통합(E2E) 테스트 전용 설정 — testcontainers로 실제 Keycloak을 기동하므로 Docker가 필요하다.
// 커버리지 게이트는 적용하지 않는다(네트워크 경계 검증이 목적). `npm run test:it`로 실행한다.
export default defineConfig({
  test: {
    include: ['test/integration/**/*.test.ts'],
    // 컨테이너 기동 + E2E는 느리므로 테스트 타임아웃을 넉넉히 준다(개별 테스트 기준).
    testTimeout: 60_000,
    hookTimeout: 240_000,
  },
})
