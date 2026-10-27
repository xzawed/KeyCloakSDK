import type { TokenProvider } from '../token-provider.js'
import { readCapped, TOKEN_RESPONSE_MAX_BYTES } from '../token-response-cap.js'
import { sendableBearer } from './call.js'

/**
 * 파사드 요청의 목적지 — `AdminClient.create` 가 한 번 짓고 다섯 리소스가 나눠 쓴다. `raw()` 의 admin-client 에 준 것과
 * 같은 값이다(서버 주소 · 읽기 기한 · 토큰 공급자). `raw().setConfig()` 는 이것을 바꾸지 않는다.
 */
export interface AdminHttp {
  readonly serverUrl: string
  readonly timeoutMs: number
  readonly tokenProvider: TokenProvider
}

/**
 * 경로 조각 하나 — url-template 3.1.1 의 단순 확장(`{id}`)과 같다: 예약되지 않은 문자(A–Z a–z 0–9 `-` `.` `_` `~`) 밖을
 * 전부 퍼센트 인코딩한다(`encodeURIComponent` 가 남기는 `!'()*` 까지). 빈 문자열과 JS 호출자의 `null`·`undefined` 는
 * 빈 조각이고, 짝 없는 서로게이트는 `URIError` 다 — admin-client 와 같다.
 */
export function segment(value: string): string {
  const v: unknown = value
  if (v === undefined || v === null) return ''
  return encodeURIComponent(String(v)).replace(
    /[!'()*]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`,
  )
}

/**
 * `/admin/realms/…` 경로 — 조각마다 {@link segment}. 마지막 조각이 `''` 면 끝이 `/` 다(admin-client 의 컬렉션 경로가
 * 그렇다 — `POST /users/`).
 */
export function adminPath(...segments: readonly string[]): string {
  return `/admin/realms/${segments.map(segment).join('/')}`
}

/**
 * admin-client 의 `omit` — 자기 열거 문자열 키만 남긴 새 객체(`keys` 는 뺀다). 생성 payload 를 이렇게 옮긴다: 옛 파사드가
 * `{ ...rep, realm }` 으로 넘기면 admin-client 가 URL 인자 `realm` 을 뺐다.
 */
export function omit(value: object, keys: readonly string[]): Record<string, unknown> {
  return Object.fromEntries(Object.entries(value).filter(([key]) => !keys.includes(key)))
}

/**
 * admin-client 의 기본 인자(`payload = {}`) — JS 호출자가 `undefined` 를 넘기면 `{}` 를 보낸다. `null` 은 그대로
 * (`'null'`)다.
 */
export function orEmpty(value: unknown): unknown {
  return value === undefined ? {} : value
}

/** admin-client 의 `stringifyQueryParams` — `undefined`·`null`·빈 문자열은 뺀다. 순서는 넘긴 순서다. */
function search(query: ReadonlyArray<readonly [string, unknown]>): string {
  const params = new URLSearchParams()
  for (const [key, value] of query) {
    if (value === undefined || value === null || value === '') continue
    params.append(key, String(value))
  }
  return params.toString()
}

/**
 * admin-client 가 보내는 것과 같은 요청을 보낸다(`lib/resources/agent.js` 의 `#requestWithParams`) — 머리는 같은
 * 순서로(`authorization` · `accept`, 본문이 있으면 `content-type`), 주소는 같은 조립으로(서버 주소의 경로에 이 경로를
 * `joinPath` 처럼 이어 `pathname` 에 넣는다 — 점 조각도 URL 이 같게 정규화한다), 리다이렉트는 따르지 않고 기한은
 * 요청마다다. 같은지는 `test/unit/admin-response-body.test.ts` 가 와이어로 대조한다.
 *
 * 토큰을 먼저 얻는다 — admin-client 도 주소를 짓기 전에 얻는다. 헤더에 실을 수 없는 Bearer 는 요청 전에 거부한다
 * ({@link sendableBearer}).
 */
async function send(
  http: AdminHttp,
  method: string,
  path: string,
  query: ReadonlyArray<readonly [string, unknown]> = [],
  body?: unknown,
): Promise<Response> {
  const headers = new Headers([
    ['authorization', `Bearer ${sendableBearer(await http.tokenProvider.getAccessToken())}`],
    ['accept', 'application/json, text/plain, */*'],
  ])
  const json = body === undefined ? undefined : (JSON.stringify(body) as string | undefined)
  if (json !== undefined) headers.set('content-type', 'application/json')
  const url = new URL(http.serverUrl)
  // admin-client 의 `joinPath(url.pathname, path)` — `path` 는 늘 `/` 로 시작하므로 앞 조각의 끝 `/` 만 뗀다.
  url.pathname = `${url.pathname.endsWith('/') ? url.pathname.slice(0, -1) : url.pathname}${path}`
  url.search = search(query)
  return fetch(url, {
    redirect: 'manual',
    ...(json === undefined ? {} : { body: json }),
    headers,
    method,
    ...(http.timeoutMs ? { signal: AbortSignal.timeout(http.timeoutMs) } : {}),
  })
}

/** admin-client 의 `parseResponse` 해석 — JSON 이면 그 값, 아니면 문자열 그대로. */
function parse(text: string): unknown {
  try {
    return JSON.parse(text) as unknown
  } catch {
    return text
  }
}

/**
 * 오류 본문 — {@link TOKEN_RESPONSE_MAX_BYTES} 까지만 읽어 admin-client 처럼 해석한다. 그보다 길다고 알린 본문은 읽지
 * 않고(취소), 상한을 넘는 본문과 읽다 실패한(멈춰 기한에 걸린 · 끊긴) 본문은 `''` 이다 — 분류는 상태가 하고 잃는 것은
 * 메시지뿐이다. 상한 안에서 끝까지 읽은 본문의 연결은 풀로 돌아간다. 세는 것은 undici 가 `content-encoding` 을 푼 뒤의
 * 바이트다(알린 길이는 받은 바이트의 것이라 그대로 비교한다).
 */
async function errorBody(res: Response): Promise<unknown> {
  const body = res.body
  // 본문이 없는 상태(304)도 `Content-Length` 를 달 수 있다 — 그 길이로 취소하러 가지 않는다.
  if (body === null) return ''
  const declared = res.headers.get('content-length')
  if (declared !== null && Number(declared) > TOKEN_RESPONSE_MAX_BYTES) {
    await body.cancel().catch(() => undefined)
    return ''
  }
  try {
    return parse(new TextDecoder().decode(await readCapped(body, TOKEN_RESPONSE_MAX_BYTES)))
  } catch {
    return ''
  }
}

/** admin-client 의 `getErrorMessage` — `error` 다음 `errorMessage` 중 첫 문자열, 객체가 아니면 그 문구. */
function lowerMessage(data: unknown): string {
  if (typeof data !== 'object' || data === null) return 'Unable to determine error message.'
  for (const key of ['error', 'errorMessage']) {
    const value = (data as Record<string, unknown>)[key]
    if (typeof value === 'string') return value
  }
  return 'Network response was not OK.'
}

/**
 * 2xx 가 아닌 응답 — admin-client 의 `NetworkError` 와 같은 모양(`response.status` · `responseData` · 메시지)으로 던져
 * {@link call} 이 그대로 분류한다. 소비자가 보는 원인(`scrubCause` 의 사본 — 이름 `Error` · 그 메시지)도 같다.
 */
async function reject(res: Response): Promise<never> {
  const data = await errorBody(res)
  throw Object.assign(new Error(lowerMessage(data)), {
    response: { status: res.status },
    responseData: data,
  })
}

/**
 * 쓰지 않는 2xx 본문 — 읽지 않고 취소한다. 다 오지 않은 본문이면 undici 가 그 연결을 끊고, 이미 끝난(빈) 본문이면 아무
 * 일도 없어 연결은 풀로 돌아간다(Keycloak 의 201 · 204).
 */
async function discard(res: Response): Promise<void> {
  await res.body?.cancel().catch(() => undefined)
}

/** 2xx 본문 — admin-client 처럼 끝까지 읽어 해석한다(본문이 없으면 `''`). 상한은 걸지 않는다 — 목록은 정당하게 크다. */
async function successBody(res: Response): Promise<unknown> {
  return parse(await res.text())
}

/** GET — 2xx 면 본문을 해석해 돌려준다. */
export async function read<T>(
  http: AdminHttp,
  path: string,
  query: ReadonlyArray<readonly [string, unknown]> = [],
): Promise<T> {
  const res = await send(http, 'GET', path, query)
  if (!res.ok) return reject(res)
  return (await successBody(res)) as T
}

/**
 * GET 하나 — 404 면 `null` 이다(admin-client 의 `catchNotFound`). 그 404 의 본문도 상한까지만 비운다. 호출자가
 * {@link requireFound} 로 부재를 `KeycloakNotFoundError` 로 바꾼다.
 */
export async function readOne<T>(http: AdminHttp, path: string): Promise<T | null> {
  const res = await send(http, 'GET', path)
  if (res.status === 404) {
    await errorBody(res)
    return null
  }
  if (!res.ok) return reject(res)
  return (await successBody(res)) as T
}

/** 갱신·삭제 — 2xx 본문은 읽지 않는다. admin-client 처럼 DELETE 도 JSON 본문(`{}`)을 싣는다. */
export async function write(
  http: AdminHttp,
  method: 'PUT' | 'DELETE',
  path: string,
  body: unknown,
): Promise<void> {
  const res = await send(http, method, path, [], body)
  if (!res.ok) return reject(res)
  await discard(res)
}

/**
 * 생성 — 2xx 본문은 읽지 않고 `Location` 의 마지막 조각을 돌려준다. `Location` 이 없거나 마지막 조각이 비면
 * admin-client 와 같은 `Error` 다(같은 메시지 — SDK 오류로 감싸지 않는 것도 그때와 같다).
 */
export async function create(http: AdminHttp, path: string, body: unknown): Promise<string> {
  const res = await send(http, 'POST', path, [], body)
  if (!res.ok) return reject(res)
  await discard(res)
  const location = res.headers.get('location')
  if (typeof location !== 'string') {
    throw new Error(`location header is not found in request: ${res.url}`)
  }
  const id = location.split('/').pop()
  if (!id) {
    throw new Error(`resourceId is not found in Location header from request: ${res.url}`)
  }
  return id
}
