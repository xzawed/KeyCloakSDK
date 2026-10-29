import { sendableBearer, type TokenProvider } from '../token-provider.js'
import { readCapped, TOKEN_RESPONSE_MAX_BYTES } from '../token-response-cap.js'

/**
 * Where the facade's requests go — `AdminClient.create` builds it once and the five resources share it. It holds
 * the same values that were given to the admin-client of `raw()` (server address · read deadline · token
 * provider). `raw().setConfig()` does not change it.
 */
export interface AdminHttp {
  readonly serverUrl: string
  readonly timeoutMs: number
  readonly tokenProvider: TokenProvider
}

/**
 * One path segment — the same as url-template 3.1.1's simple expansion (`{id}`): everything outside the
 * unreserved characters (A–Z a–z 0–9 `-` `.` `_` `~`) is percent-encoded (including the `!'()*` that
 * `encodeURIComponent` leaves). An empty string and a JS caller's `null`/`undefined` are an empty segment, and an
 * unpaired surrogate is a `URIError` — the same as admin-client.
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
 * An `/admin/realms/…` path — {@link segment} for each segment. When the last segment is `''` the path ends in `/`
 * (admin-client's collection paths do — `POST /users/`).
 */
export function adminPath(...segments: readonly string[]): string {
  return `/admin/realms/${segments.map(segment).join('/')}`
}

/**
 * admin-client's `omit` — a new object keeping only the own enumerable string keys (minus `keys`). Create payloads
 * are carried over this way: when the old facade passed `{ ...rep, realm }`, admin-client took out the URL
 * argument `realm`.
 */
export function omit(value: object, keys: readonly string[]): Record<string, unknown> {
  return Object.fromEntries(Object.entries(value).filter(([key]) => !keys.includes(key)))
}

/**
 * admin-client's default argument (`payload = {}`) — when a JS caller passes `undefined`, `{}` is sent. `null`
 * stays as is (`'null'`).
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
 * 토큰을 먼저 얻는다 — admin-client 도 주소를 짓기 전에 얻는다. Bearer 는 {@link sendableBearer} 가 돌려준 값이다
 * (앞뒤 SP·HTAB·CR·LF 를 뗀 값 · `b64token` 이 아니면 요청 전에 거부).
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

/** GET — on a 2xx, parses the body and returns it. */
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
 * A single GET — a 404 gives `null` (admin-client's `catchNotFound`). That 404's body is also drained only up to
 * the cap. The caller turns the absence into `KeycloakNotFoundError` with {@link requireFound}.
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

/** Update/delete — the 2xx body is not read. Like admin-client, DELETE also carries a JSON body (`{}`). */
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
 * Create — the 2xx body is not read; the last segment of `Location` is returned. A missing `Location` or an empty
 * last segment is the same `Error` as admin-client's (the same message — and, as then, it is not wrapped in an
 * SDK error).
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
