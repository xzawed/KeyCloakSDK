import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['test/unit/**/*.test.ts'],
    // test.exclude 는 커버리지 목록이 아니다 — 가드가 이것을 읽으면 안 된다
    exclude: ['src/transport.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      // 'src/config.ts' — 주석 속 항목은 세지 않는다
      exclude: ['src/index.ts', 'src/auth.ts',
        'src/admin/users.ts'],
      thresholds: { lines: 90, exclude: 'not-a-list' },
    },
  },
})
