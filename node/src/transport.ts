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
 * Whether this is a transport-layer failure (connection refused/DNS/TLS/timeout). Node fetch (undici) throws a
 * network failure as a `TypeError` (message "fetch failed", the system error in `cause`), and a timeout
 * (AbortController) as `AbortError`/`TimeoutError`. A bare `TypeError` with no cause (a programming bug) is not a
 * transport error.
 *
 * A pure classification helper shared by the two network boundaries, auth (discovery) and admin (calls) — it
 * removes per-boundary duplication and keeps the transport/auth (or status) classification consistent.
 *
 * ⚠️ **It does not touch the network, so do not exclude it from the coverage gate** (it was taken out of the
 * exclusions on 2026-09-10). The old comment said "the auth/admin boundary tests verify the real behavior", which
 * was false — the arms those tests hit are only `AbortError` and `ECONNREFUSED`, and because of the exclusion the
 * rest were not even measured, so **deleting the TLS-expiry codes still left everything green**.
 * `test/unit/transport.test.ts` exercises all of them.
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
