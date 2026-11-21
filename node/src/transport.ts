// System error codes seen on Node fetch (undici)/TLS/DNS transport failures — on the error itself, or on a `cause`
// that is an `Error`.
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
 * network failure as a `TypeError` (message "fetch failed", the system error — an `Error` — in `cause`), and a timeout
 * (AbortController) as `AbortError`/`TimeoutError`. A `TypeError` whose cause is not an `Error` (a programming bug
 * has none) is not a transport error.
 *
 * ⚠️ **A `cause` speaks for the transport only when it is an `Error`** — one that is not is data. oauth4webapi's
 * `ResponseBodyError` holds the JSON-parsed OAuth error body as its `cause`, so a body member `"code":"ECONNRESET"`
 * read as `cause.code` turned an IdP's `invalid_grant` into a transport failure (registry
 * `node-body-code-member-transport` — `test/unit/auth-body-member-transport.test.ts`). The value given is judged
 * by its own `name` and `code` as before.
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
  const cause = e.cause instanceof Error ? (e.cause as Error & { code?: unknown }) : undefined
  if (err instanceof TypeError && cause !== undefined) return true
  const direct = typeof e.code === 'string' ? e.code : undefined
  const causeCode = typeof cause?.code === 'string' ? cause.code : undefined
  return (
    (direct !== undefined && TRANSPORT_CODES.has(direct)) ||
    (causeCode !== undefined && TRANSPORT_CODES.has(causeCode))
  )
}

/**
 * {@link isTransportError} anywhere in the cause chain (at most 8 links, like `responseTooLarge`) — a library may wrap
 * fetch's error in its own. The auth lane uses it to tell a response that never fully arrived (transport) from one
 * that arrived but is unusable (auth).
 *
 * ⚠️ Past the value given, it follows a `cause` only while that is an `Error`. A cause that is not one is data — the
 * OAuth error body a `ResponseBodyError` holds — and the walk ends there, so a body member (`name`
 * `"TimeoutError"`, `code`, a nested `cause`) is never read as a link of the chain.
 */
export function transportInChain(err: unknown): boolean {
  let link: unknown = err
  for (let depth = 0; depth < 8 && typeof link === 'object' && link !== null; depth += 1) {
    if (isTransportError(link)) return true
    const cause = (link as { cause?: unknown }).cause
    link = cause instanceof Error ? cause : undefined
  }
  return false
}
