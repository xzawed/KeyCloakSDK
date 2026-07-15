// Node fetch(undici)/TLS/DNS 전송 실패에서 관측되는 시스템 오류 코드(직접 또는 `cause`에).
const TRANSPORT_CODES = new Set([
  'ECONNREFUSED',
  'ECONNRESET',
  'EHOSTUNREACH',
  'ENETUNREACH',
  'EPIPE',
  'ENOTFOUND',
  'EAI_AGAIN',
  'ETIMEDOUT',
  'UND_ERR_CONNECT_TIMEOUT',
  'UND_ERR_HEADERS_TIMEOUT',
  'UND_ERR_SOCKET',
  'CERT_HAS_EXPIRED',
  'DEPTH_ZERO_SELF_SIGNED_CERT',
  'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
  'SELF_SIGNED_CERT_IN_CHAIN',
  'ERR_TLS_CERT_ALTNAME_INVALID',
])

/**
 * 전송 계층 실패(연결거부/DNS/TLS/타임아웃) 여부. Node fetch(undici)는 네트워크 실패를
 * `TypeError`(message "fetch failed", `cause`에 시스템 오류)로, 타임아웃(AbortController)을
 * `AbortError`/`TimeoutError`로 던진다. cause 없는 순수 `TypeError`(프로그래밍 버그)는 전송 오류가 아니다.
 *
 * auth(discovery)·admin(호출) 두 네트워크 경계가 공유하는 순수 분류 헬퍼다 — 경계별 중복을 없애고
 * 전송/인증(또는 상태) 분류를 일관되게 유지한다. 자체가 네트워크 경계 지원 유틸이라 커버리지 게이트에서
 * 제외된다(vitest exclude · sonar coverage.exclusions); 실동작은 auth/admin 경계 테스트가 검증한다.
 */
export function isTransportError(err: unknown): boolean {
  if (typeof err !== 'object' || err === null) return false
  const e = err as { name?: unknown; code?: unknown; cause?: unknown }
  if (e.name === 'AbortError' || e.name === 'TimeoutError') return true
  if (err instanceof TypeError && e.cause !== undefined && e.cause !== null) return true
  const direct = typeof e.code === 'string' ? e.code : undefined
  const cause = e.cause as { code?: unknown } | null | undefined
  const causeCode = typeof cause?.code === 'string' ? cause.code : undefined
  return (
    (direct !== undefined && TRANSPORT_CODES.has(direct)) ||
    (causeCode !== undefined && TRANSPORT_CODES.has(causeCode))
  )
}
