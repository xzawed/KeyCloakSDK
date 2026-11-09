/**
 * Byte cap on the response bodies of the token endpoint (three grants — the auth lane, and the admin lane's grant of
 * its own token), introspection and discovery. What is counted is bytes **after decompression** — it reads
 * `response.body` after undici has undone the `content-encoding`.
 *
 * ⚠️ **Upstream has no cap.** oauth4webapi reads a 200 token or introspection response whole with `response.json()`
 * (`getResponseJsonBody`), and a 4xx with `response.clone().json()` (`parseOAuthResponseErrorBody`).
 * Measured (2026-10-05 · openid-client 6.8.8 · oauth4webapi 3.8.8): all five lanes accepted a response with 32 MiB
 * of JSON whitespace appended after a usable token, and the process peak grew by +100–123 MB per call (the same
 * with a 33 KB gzip).
 *
 * **Where it is hooked.** One place: the `[customFetch]` of the `oidc.discovery` options (openid-client's symbol —
 * **not** the same as jose's). openid-client copies it into the Configuration, so discovery, the three grants and
 * introspection all pass through this fetch (`#runDiscovery` in `auth.ts`). Admin's token also goes through
 * `AuthClient`, so the same place covers it.
 *
 * ⚠️ **It is not applied to admin REST responses** — user lists are legitimately large. The JWKS applies its own
 * cap (51,200, `JWKS_MAX_BYTES` in `jwt.ts`) separately.
 */

/**
 * The cap — 16 times the longest Bearer that Keycloak 26.6 accepts with its default settings (65,459 bytes,
 * measured 2026-10-03), so no token the server accepts is refused. However many lanes there are, it is this one
 * constant.
 *
 * ⚠️ All nine languages move this value together and a cross-language guard extracts this literal — do not turn it
 * into an expression (`1 << 20`).
 */
export const TOKEN_RESPONSE_MAX_BYTES = 1_048_576

/** BYOB 한 번 읽기와 본문 버퍼의 시작 크기 — ~2 KiB 응답에 상한 크기 버퍼를 잡지 않는다. 버퍼는 두 배씩 자란다. */
const READ_CHUNK_BYTES = 16_384

/**
 * The signal of a response over the cap. openid-client wraps whatever fetch throws in
 * `ClientError('something went wrong')`, so the boundary (`auth.ts`) recognizes this in the cause chain
 * ({@link responseTooLarge}) and builds an accurate SDK message.
 */
export class ResponseTooLargeError extends Error {
  constructor(readonly limit: number) {
    super(`response body exceeds ${limit} bytes`)
    this.name = 'ResponseTooLargeError'
  }
}

/** Finds the cap signal in the cause chain — `undefined` if there is none. */
export function responseTooLarge(error: unknown): ResponseTooLargeError | undefined {
  let link: unknown = error
  for (let depth = 0; depth < 8 && link instanceof Error; depth += 1) {
    if (link instanceof ResponseTooLargeError) return link
    link = link.cause
  }
  return undefined
}

/**
 * The signal of a 2xx token or introspection body that is not UTF-8 (RFC 8259 §8.1) — the response arrived but cannot
 * be used, so the boundary (`auth.ts`) reports it as `KeycloakAuthError` (registry `token-response-class-divergent`,
 * decision D1). oauth4webapi reads the body with `response.json()`, whose decoder turns a byte that is not UTF-8 into
 * U+FFFD without an error — the grants and introspection returned a token or a claim the IdP never sent as a success
 * (measured 2026-11-10).
 */
export class ResponseNotUtf8Error extends Error {
  constructor(kind: string) {
    super(`${kind} is not valid UTF-8`)
    this.name = 'ResponseNotUtf8Error'
  }
}

/** Finds the UTF-8 signal in the cause chain — `undefined` if there is none. */
export function responseNotUtf8(error: unknown): ResponseNotUtf8Error | undefined {
  let link: unknown = error
  for (let depth = 0; depth < 8 && link instanceof Error; depth += 1) {
    if (link instanceof ResponseNotUtf8Error) return link
    link = link.cause
  }
  return undefined
}

/**
 * Whose 2xx body must be UTF-8 — the token and introspection responses. Discovery and logout keep what they had: an
 * error status is judged by its status, and logout reads no body.
 */
function utf8Kind(url: string): string | undefined {
  const path = new URL(url).pathname.replace(/\/+$/, '')
  if (path.endsWith('/token/introspect')) return 'introspection response'
  if (path.endsWith('/token')) return 'token response'
  return undefined
}

function isUtf8(body: Uint8Array): boolean {
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(body)
    return true
  } catch {
    return false
  }
}

/**
 * Reads the body up to `cap` bytes only — past that it cancels the stream and throws {@link ResponseTooLargeError}.
 *
 * ⚠️ **It reads with a BYOB reader** — we decide the length requested, so the read stops at exactly cap+1 bytes
 * and nothing beyond that is requested (bytes received + the length requested this time ≤ cap+1). The default
 * reader (the JWKS loop) reads one chunk past the cap (measured: with a 1 MiB cap it stopped at 1,113,791
 * bytes). The buffer doubles as it is filled, so a small response does not get a cap-sized buffer.
 *
 * A body that is not a byte stream (the default-stream body of a consumer who swapped in a different global
 * `fetch`) is read with the default reader — then one chunk sized by the transport (that chunk is not stored) can
 * lie beyond the cap.
 */
export async function readCapped(
  body: ReadableStream<Uint8Array>,
  cap: number,
): Promise<Uint8Array> {
  let reader: ReadableStreamBYOBReader
  try {
    reader = body.getReader({ mode: 'byob' })
  } catch {
    return readCappedChunks(body.getReader(), cap)
  }
  const limit = cap + 1
  let scratch = new ArrayBuffer(Math.min(READ_CHUNK_BYTES, limit))
  let buffer = new Uint8Array(Math.min(READ_CHUNK_BYTES, limit))
  let length = 0
  while (length < limit) {
    const { done, value } = await reader.read(
      new Uint8Array(scratch, 0, Math.min(scratch.byteLength, limit - length)),
    )
    if (done) break
    // 읽기는 넘긴 버퍼를 옮긴다(transfer) — 돌려받은 것을 다음 읽기에 쓴다.
    scratch = value.buffer as ArrayBuffer
    if (length + value.byteLength > buffer.byteLength) {
      const grown = new Uint8Array(
        Math.min(Math.max(buffer.byteLength * 2, length + value.byteLength), limit),
      )
      grown.set(buffer.subarray(0, length))
      buffer = grown
    }
    buffer.set(value, length)
    length += value.byteLength
  }
  if (length > cap) {
    await reader.cancel().catch(() => undefined)
    throw new ResponseTooLargeError(cap)
  }
  reader.releaseLock()
  return buffer.subarray(0, length)
}

async function readCappedChunks(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  cap: number,
): Promise<Uint8Array> {
  const chunks: Uint8Array[] = []
  let length = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    if (length + value.byteLength > cap) {
      await reader.cancel().catch(() => undefined)
      throw new ResponseTooLargeError(cap)
    }
    chunks.push(value)
    length += value.byteLength
  }
  const out = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.byteLength
  }
  return out
}

/**
 * A fetch that reads the response body only up to {@link TOKEN_RESPONSE_MAX_BYTES} and hands it back as a new
 * `Response` with the same status and headers — plugged into openid-client's `[customFetch]` slot. A response that
 * passes through this fetch is entirely in memory, within the cap.
 *
 * ⚠️ A response without a body (204 and the like — undici gives `body` as `null`) and **a status outside 200–599**
 * are returned as is. The latter cannot be rebuilt because the `Response` constructor rejects it (measured: undici
 * passes 600 and 999 through as is), and oauth4webapi reads only the bodies of 200 and 400–499, so that body is
 * never read — the same as now.
 */
export async function fetchTokenEndpointBounded(
  url: string,
  init?: RequestInit,
): Promise<Response> {
  const response = await fetch(url, init)
  if (response.body === null || response.status < 200 || response.status > 599) return response
  const body = await readCapped(response.body, TOKEN_RESPONSE_MAX_BYTES)
  const kind = response.status < 300 ? utf8Kind(url) : undefined
  if (kind !== undefined && !isUtf8(body)) throw new ResponseNotUtf8Error(kind)
  return new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  })
}
