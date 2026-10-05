/**
 * 토큰 엔드포인트(세 그랜트 — auth 레인과 admin 레인의 자기 토큰 부여)·introspection·discovery 응답 본문의 바이트
 * 상한. 세는 것은 **푼 뒤** 바이트다 — undici 가 `content-encoding` 을 푼 다음의 `response.body` 를 읽는다.
 *
 * ⚠️ **상류에는 상한이 없다.** oauth4webapi 는 200 토큰·introspection 응답을 `response.json()`
 * (`getResponseJsonBody`), 4xx 를 `response.clone().json()`(`parseOAuthResponseErrorBody`)으로 통째로 읽는다.
 * 실측(2026-10-05 · openid-client 6.8.8 · oauth4webapi 3.8.8): 쓸 수 있는 토큰 뒤에 JSON 공백 32 MiB 를 붙인
 * 응답을 다섯 레인이 전부 받아들였고 프로세스 피크가 호출 하나에 +100~123 MB 였다(gzip 33 KB 도 같았다).
 *
 * **어디에 거는가.** `oidc.discovery` 옵션의 `[customFetch]`(openid-client 의 심볼 — jose 의 것과 **다르다**) 한
 * 자리다. openid-client 가 그것을 Configuration 에 복사하므로 discovery·세 그랜트·introspection 이 전부 이 fetch
 * 를 지난다(`auth.ts` 의 `#runDiscovery`). admin 의 토큰도 `AuthClient` 를 지나므로 같은 자리가 덮는다.
 *
 * ⚠️ **admin REST 응답에는 걸지 않는다** — 사용자 목록은 정당하게 크다. JWKS 는 자기 상한(51,200,
 * `jwt.ts` 의 `JWKS_MAX_BYTES`)을 따로 건다.
 */

/**
 * 상한 — Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트, 실측 2026-10-03)의 16 배라
 * 서버가 받는 토큰은 거부하지 않는다. 레인이 몇이든 이 상수 하나다.
 *
 * ⚠️ 아홉 언어가 함께 움직이는 값이고 교차 언어 가드가 이 리터럴을 뽑는다 — 식(`1 << 20`)으로 바꾸지 말 것.
 */
export const TOKEN_RESPONSE_MAX_BYTES = 1_048_576

/** BYOB 한 번 읽기와 본문 버퍼의 시작 크기 — ~2 KiB 응답에 상한 크기 버퍼를 잡지 않는다. 버퍼는 두 배씩 자란다. */
const READ_CHUNK_BYTES = 16_384

/**
 * 상한을 넘은 응답의 신호. openid-client 는 fetch 가 던진 것을 `ClientError('something went wrong')` 로 감싸므로
 * 경계(`auth.ts`)가 원인 사슬에서 이것을 알아보고({@link responseTooLarge}) 정확한 SDK 메시지를 만든다.
 */
export class ResponseTooLargeError extends Error {
  constructor(readonly limit: number) {
    super(`response body exceeds ${limit} bytes`)
    this.name = 'ResponseTooLargeError'
  }
}

/** 원인 사슬에서 상한 신호를 찾는다 — 없으면 `undefined`. */
export function responseTooLarge(error: unknown): ResponseTooLargeError | undefined {
  let link: unknown = error
  for (let depth = 0; depth < 8 && link instanceof Error; depth += 1) {
    if (link instanceof ResponseTooLargeError) return link
    link = link.cause
  }
  return undefined
}

/**
 * 본문을 `cap` 바이트까지만 읽는다 — 넘으면 스트림을 취소하고 {@link ResponseTooLargeError}.
 *
 * ⚠️ **BYOB 리더로 읽는다** — 청하는 길이를 우리가 정하므로 읽기가 정확히 cap+1 바이트에서 멈추고, 그 너머는 청하지
 * 않는다(받은 것 + 이번에 청하는 길이 ≤ cap+1). 기본 리더(JWKS 의 고리)는 조각 하나만큼 넘어 읽는다(실측: 1 MiB
 * 상한에서 1,113,791 바이트에 멈췄다). 버퍼는 읽은 만큼 두 배씩 자라므로 작은 응답에 상한 크기를 잡지 않는다.
 *
 * 바이트 스트림이 아니면(전역 `fetch` 를 바꿔 끼운 소비자의 기본 스트림 본문) 기본 리더로 읽는다 — 그때는 전송이
 * 정한 조각 하나(그 조각은 저장하지 않는다)가 상한 너머에 있을 수 있다.
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
 * 응답 본문을 {@link TOKEN_RESPONSE_MAX_BYTES} 까지만 읽어 같은 상태·헤더의 새 `Response` 로 되돌려 주는 fetch —
 * openid-client `[customFetch]` 자리에 꽂는다. 이 fetch 를 지나는 응답은 상한 안에서 전부 메모리에 있다.
 *
 * ⚠️ 본문이 없는 응답(204 등 — undici 가 `body` 를 `null` 로 준다)과 **200~599 밖의 상태**는 그대로 돌려준다.
 * 후자는 `Response` 생성자가 거부해 다시 만들 수 없고(실측: undici 는 600·999 를 그대로 넘긴다), oauth4webapi 는
 * 200 과 400~499 의 본문만 읽으므로 그 본문은 읽히지 않는다 — 지금과 같다.
 */
export async function fetchTokenEndpointBounded(
  url: string,
  init?: RequestInit,
): Promise<Response> {
  const response = await fetch(url, init)
  if (response.body === null || response.status < 200 || response.status > 599) return response
  const body = await readCapped(response.body, TOKEN_RESPONSE_MAX_BYTES)
  return new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  })
}
