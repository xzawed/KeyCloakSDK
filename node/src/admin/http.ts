import { types } from 'node:util'
import { KeycloakAdminError, KeycloakTransportError } from '../errors.js'
import { sendableBearer, type TokenProvider } from '../token-provider.js'
import { readCapped, TOKEN_RESPONSE_MAX_BYTES } from '../token-response-cap.js'

/**
 * A write whose representation `JSON.stringify` refuses (a cycle, a BigInt) or would rewrite (NaN and ±Infinity become
 * `null`) — .NET's message for the same failure.
 */
export const UNENCODABLE_BODY =
  'admin request failed: the request body could not be encoded as JSON'
/** A path argument `encodeURIComponent` refuses (an unpaired surrogate). */
export const UNENCODABLE_SEGMENT =
  'admin request failed: a path segment holds an unpaired surrogate'

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
 * `encodeURIComponent` leaves). An empty string and a JS caller's `null`/`undefined` are an empty segment.
 * ⚠️ An unpaired surrogate is a {@link KeycloakTransportError} ({@link UNENCODABLE_SEGMENT}, the `URIError` as its
 * cause) before any request — admin-client throws the `URIError` raw, which left the SDK's error hierarchy (§4).
 */
export function segment(value: string): string {
  const v: unknown = value
  if (v === undefined || v === null) return ''
  let encoded: string
  try {
    encoded = encodeURIComponent(String(v))
  } catch (e) {
    throw new KeycloakTransportError(UNENCODABLE_SEGMENT, { cause: e })
  }
  return encoded.replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)
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

// `JSON.stringify` 의 replacer — NaN · ±Infinity 를 던진다. stringify 는 그 수를 던지지 않고 `null` 로 써(ECMA-262
// SerializeJSONProperty) 호출자가 보내지 않은 값이 나갔다(등록부 admin-unencodable-body-residuals). replacer 는 `toJSON` 이 돌려준
// 값을 받는다. 감싼 `Number` 객체는 stringify 가 그 자리에서 수로 푸므로(ToNumber) 여기서 같은 ToNumber 로 풀어 보고 그 수를
// 돌려준다 — 본 값과 쓰는 값이 하나다(`valueOf` 를 두 번 부르지 않는다). 짝 없는 서로게이트는 stringify 가 `\ud800` 로 그대로
// 싣는다(ES2019 well-formed) — 여기서 보지 않는다.
function finiteNumbers(_key: string, value: unknown): unknown {
  const number = types.isNumberObject(value) ? Number(value) : value
  if (typeof number === 'number' && !Number.isFinite(number)) {
    throw new TypeError('a non-finite number (NaN or Infinity) has no JSON form')
  }
  return number
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
 * 요청이 가는 URL — admin-client 의 `joinPath(url.pathname, path)` 처럼 서버 주소의 경로에 이 경로를 잇는다(`path` 는 늘
 * `/` 로 시작하므로 앞 조각의 끝 `/` 만 뗀다). {@link send} 가 보내고, {@link create} 가 `Location` 을 이것에 대해 푼다.
 */
function target(
  http: AdminHttp,
  path: string,
  query: ReadonlyArray<readonly [string, unknown]> = [],
): URL {
  const url = new URL(http.serverUrl)
  url.pathname = `${url.pathname.endsWith('/') ? url.pathname.slice(0, -1) : url.pathname}${path}`
  url.search = search(query)
  return url
}

/**
 * admin-client 가 보내는 것과 같은 요청을 보낸다(`lib/resources/agent.js` 의 `#requestWithParams`) — 머리는 같은
 * 순서로(`authorization` · `accept`, 본문이 있으면 `content-type`), 주소는 같은 조립으로(서버 주소의 경로에 이 경로를
 * `joinPath` 처럼 이어 `pathname` 에 넣는다 — 점 조각도 URL 이 같게 정규화한다), 리다이렉트는 따르지 않고 기한은
 * 요청마다다. 같은지는 `test/unit/admin-response-body.test.ts` 가 와이어로 대조한다.
 *
 * 본문을 먼저 JSON 으로 쓴다 — 쓸 수 없는 표현(순환 · BigInt)과 그대로 싣지 못하는 수(NaN · ±Infinity — stringify 는
 * `null` 로 바꿔 쓴다)는 {@link UNENCODABLE_BODY} 의 {@link KeycloakTransportError} 이고 토큰도 받지 않는다(python · ruby 도
 * 토큰 전에 인코딩한다). admin-client 는 `JSON.stringify` 의 `TypeError` 를 그대로 던져 SDK 오류 계층 밖으로 나갔다(§4).
 * 그다음 토큰을 얻는다 — admin-client 도 주소를 짓기 전에 얻는다. Bearer 는 {@link sendableBearer} 가 돌려준 값이다(앞뒤
 * SP·HTAB·CR·LF 를 뗀 값 · `b64token` 이 아니면 요청 전에 거부).
 */
async function send(
  http: AdminHttp,
  method: string,
  path: string,
  query: ReadonlyArray<readonly [string, unknown]> = [],
  body?: unknown,
): Promise<Response> {
  let json: string | undefined
  try {
    json =
      body === undefined ? undefined : (JSON.stringify(body, finiteNumbers) as string | undefined)
  } catch (e) {
    throw new KeycloakTransportError(UNENCODABLE_BODY, { cause: e })
  }
  const headers = new Headers([
    ['authorization', `Bearer ${sendableBearer(await http.tokenProvider.getAccessToken())}`],
    ['accept', 'application/json, text/plain, */*'],
  ])
  if (json !== undefined) headers.set('content-type', 'application/json')
  return fetch(target(http, path, query), {
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
 * Create of users · clients · groups, whose id the server assigns — the 2xx body is not read; the id is the one
 * `Location` names ({@link createdId}). A missing `Location`, or one that names no id in the posted collection, is a
 * {@link KeycloakAdminError} carrying that response's status, with admin-client's message — whose own bare `Error` left
 * the SDK's error hierarchy (§4).
 */
export async function create(http: AdminHttp, path: string, body: unknown): Promise<string> {
  const { res, location } = await posted(http, path, body)
  const id = createdId(location, target(http, path))
  if (id === undefined) throw noId(res)
  return id
}

/**
 * Create of a role or a realm — addressed by its name, so there is no server-assigned id to read: like admin-client, it
 * requires a `Location` whose last `/` piece is not empty and returns nothing. Not {@link createdId}: the `Location` ends
 * in the name, and a name that holds a `/` would fail the collection check after the server created it (registry
 * admin-create-relative-location — these creates keep their behaviour).
 */
export async function createNamed(http: AdminHttp, path: string, body: unknown): Promise<void> {
  const { res, location } = await posted(http, path, body)
  if (!location.split('/').pop()) throw noId(res)
}

/** A create's POST — a 2xx whose body is not read and that carries a `Location`; else a {@link KeycloakAdminError}. */
async function posted(
  http: AdminHttp,
  path: string,
  body: unknown,
): Promise<{ res: Response; location: string }> {
  const res = await send(http, 'POST', path, [], body)
  if (!res.ok) return reject(res)
  await discard(res)
  const location = res.headers.get('location')
  if (typeof location !== 'string') {
    throw new KeycloakAdminError(`location header is not found in request: ${res.url}`, {
      status: res.status,
    })
  }
  return { res, location }
}

/** A `Location` that names no id — admin-client's message, with that response's status. */
function noId(res: Response): KeycloakAdminError {
  return new KeycloakAdminError(
    `resourceId is not found in Location header from request: ${res.url}`,
    { status: res.status },
  )
}

/**
 * The id a create's `Location` names (registry admin-create-relative-location — the same rule in all nine SDKs): the
 * value resolved against the URL the create was sent to (RFC 9110 §10.2.2 — a relative one too), then the last segment
 * of the resolved path as it came (not decoded; one trailing `/` ignored), whose segment before it must be the collection
 * the create posted to. Never the query or the fragment. `undefined` — no id — when the value is empty after trimming SP
 * and HTAB or does not parse, or the resolved path names no id in that collection (another collection's id included).
 * ⚠️ The create URL of users · clients · groups ends in `/` (admin-client's `POST /users/`), so a bare `abc` resolves
 * into the collection.
 */
function createdId(location: string, sentTo: URL): string | undefined {
  // 앞의 SP · HTAB 는 fetch 가 이미 뗐다(Headers 정규화 · llhttp) — 뒤의 것은 undici 가 남긴다(실측: `abc \t ` 그대로).
  // 정규식(`[ \t]+$`)으로 떼지 않는다 — 긴 안쪽 공백 줄에서 시작점마다 되짚어 제곱으로 돈다.
  let end = location.length
  while (end > 0 && (location[end - 1] === ' ' || location[end - 1] === '\t')) end--
  if (end === 0) return undefined
  let resolved: URL
  try {
    resolved = new URL(location.slice(0, end), sentTo)
  } catch {
    return undefined
  }
  const [collection, id] = lastSegments(resolved.pathname)
  return id !== '' && collection === lastSegments(sentTo.pathname)[1] ? id : undefined
}

/** The last two segments of a URL path, one trailing `/` ignored — the first `undefined` when it has one only. */
function lastSegments(path: string): readonly [string | undefined, string] {
  const segments = (path.endsWith('/') ? path.slice(0, -1) : path).split('/')
  const last = segments.pop() as string // `split` never returns an empty array
  return [segments.pop(), last]
}
