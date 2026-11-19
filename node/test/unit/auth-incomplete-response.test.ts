/**
 * 응답이 **끝까지 오지 않은** auth 레인의 실패는 `KeycloakTransportError` 다 — 등록부 `token-response-class-divergent`
 * (아홉 언어의 규칙: 끝까지 왔지만 쓸 수 없는 응답은 auth, 다 오지 않은 응답은 transport · rust #951 · go #952).
 *
 * 수정 전(실측 2026-11-09 · main f93b8416): discovery 를 끝낸 뒤 토큰 엔드포인트가 연결을 끊으면 세 그랜트도
 * introspection 도 `KeycloakAuthError`(`… failed: fetch failed`), logout 은 `KeycloakAuthError`(`Logout request
 * error: fetch failed`)였다 — node 의 `KeycloakTransportError` 는 「Network/transport-layer failure」라고 적고도
 * discovery 하나에만 쓰였다. 상한 초과(1,048,577 바이트)는 `token-response-cap.test.ts` 가 잰다.
 *
 * 대조군: 끝까지 온 503 HTML 은 지금처럼 `KeycloakAuthError` 다(`auth-malformed-token-response.test.ts` 가 200 의
 * 깨진 본문을 잰다).
 *
 * 머리가 온 뒤 본문이 끝까지 오지 않은 응답(Content-Length 전에 끊김 · 읽기 타임아웃을 넘겨 멈춤)도 같다 — logout 은
 * 204 가 아닌 답을 상태로 판정하지만, 그 답이 끝까지 왔는지는 본문을 읽어야 안다(등록부
 * `logout-body-unread-class-divergent`). 고치기 전(main 6d9c0c4f)에는 logout 만 본문을 읽지 않아 두 칸 다
 * `KeycloakAuthError`(`Logout failed (HTTP 400)`)였다. 끝까지 온 400 과 풀 수 없는 gzip 본문은 그대로 상태가 판정한다.
 */
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { KeycloakAuthError, KeycloakClient, KeycloakTransportError } from '../../src/index.js'

type Mode =
  | 'ok'
  | 'reset'
  | 'stall'
  | 'html503'
  | 'cut'
  | 'stallBody'
  | 'full400'
  | 'undecodable'
  | 'noContent'

/** 머리 뒤에 쓰는 본문 앞부분 — Content-Length 는 이보다 100 바이트 길게 적는다(다 오지 않은 본문). */
const PARTIAL = Buffer.from('{"error":"invalid_grant"')
/** gzip 머리 열 바이트 뒤에 deflate 가 아닌 바이트 — 끝까지 왔지만 풀 수 없다(`auth-token-response-residue.test.ts`). */
const CORRUPT_DEFLATE = Buffer.concat([
  Buffer.from([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff]),
  Buffer.alloc(30, 'x'),
])

let mode: Mode = 'ok'
let server: Server
let origin = ''
const held: Array<() => void> = []

beforeAll(async () => {
  server = createServer((req, res) => {
    req.on('end', () => {
      const path = new URL(req.url ?? '/', origin).pathname
      res.setHeader('content-type', 'application/json')
      if (path.endsWith('/.well-known/openid-configuration')) {
        const issuer = `${origin}/realms/r`
        res.end(
          JSON.stringify({
            issuer,
            token_endpoint: `${issuer}/protocol/openid-connect/token`,
            introspection_endpoint: `${issuer}/protocol/openid-connect/token/introspect`,
            jwks_uri: `${issuer}/protocol/openid-connect/certs`,
            response_types_supported: ['code'],
          }),
        )
      } else if (mode === 'reset') {
        req.socket.destroy()
      } else if (mode === 'stall') {
        held.push(() => res.destroy()) // 머리도 보내지 않는다 — 시험 끝에 풀어 준다
      } else if (mode === 'html503') {
        res.statusCode = 503
        res.setHeader('content-type', 'text/html')
        res.end('<html><body>Service Unavailable</body></html>')
      } else if (mode === 'cut') {
        // 머리와 본문 앞부분을 소켓에 넘긴 뒤 끊는다 — Content-Length 까지 100 바이트가 모자란다.
        res.statusCode = 400
        res.setHeader('content-length', PARTIAL.length + 100)
        res.write(PARTIAL, () => res.socket?.destroy())
      } else if (mode === 'stallBody') {
        res.statusCode = 400
        res.setHeader('content-length', PARTIAL.length + 100)
        res.write(PARTIAL)
        held.push(() => res.destroy()) // 나머지를 보내지 않는다 — 시험 끝에 풀어 준다
      } else if (mode === 'full400') {
        res.statusCode = 400
        res.end(
          JSON.stringify({ error: 'invalid_grant', error_description: 'Invalid refresh token' }),
        )
      } else if (mode === 'undecodable') {
        res.statusCode = 400
        res.setHeader('content-encoding', 'gzip')
        res.end(CORRUPT_DEFLATE)
      } else if (mode === 'noContent') {
        res.statusCode = 204
        res.end()
      } else {
        res.end(JSON.stringify({ access_token: 'a', token_type: 'Bearer', expires_in: 60 }))
      }
    })
    req.resume()
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})

afterAll(async () => {
  for (const release of held.splice(0)) release()
  await new Promise<void>((resolve) => server.close(() => resolve()))
})

/**
 * 레인 · 부르기 · 머리가 오기 전 실패의 문구 앞부분 · 400 머리가 온 뒤 실패의 문구 앞부분. logout 은 머리가 오면 상태를
 * 읽었으니 그 상태가 문구에 선다.
 */
const LANES: Array<[string, (kc: KeycloakClient) => Promise<unknown>, string, string]> = [
  [
    'client credentials',
    (kc) => kc.auth.clientCredentialsToken(),
    'Client credentials grant failed',
    'Client credentials grant failed',
  ],
  ['refresh', (kc) => kc.auth.refresh('r'), 'Token refresh failed', 'Token refresh failed'],
  [
    'introspection',
    (kc) => kc.auth.introspect('t'),
    'Token introspection failed',
    'Token introspection failed',
  ],
  ['logout', (kc) => kc.auth.logout('r'), 'Logout request error', 'Logout failed (HTTP 400)'],
]

function client(): KeycloakClient {
  return KeycloakClient.create({
    serverUrl: origin,
    realm: 'r',
    clientId: 'c',
    clientSecret: 's',
    readTimeoutMs: 1000,
  })
}

async function failure(run: (kc: KeycloakClient) => Promise<unknown>, at: Mode): Promise<Error> {
  const kc = client()
  try {
    mode = 'ok'
    await kc.auth.clientCredentialsToken() // discovery 를 먼저 끝낸다 — 재는 것은 그 뒤의 요청이다
    mode = at
    await run(kc)
    throw new Error('expected a failure')
  } catch (e) {
    return e as Error
  } finally {
    await kc.close()
  }
}

describe('끝까지 오지 않은 응답은 KeycloakTransportError', () => {
  it.each(LANES)('%s — 연결이 끊기면', async (_lane, run, prefix) => {
    const err = await failure(run, 'reset')
    expect(err).toBeInstanceOf(KeycloakTransportError)
    expect(err.message.startsWith(`${prefix}: `)).toBe(true)
  })

  it.each(LANES)('%s — 머리가 오지 않으면(읽기 타임아웃)', async (_lane, run) => {
    const err = await failure(run, 'stall')
    expect(err).toBeInstanceOf(KeycloakTransportError)
  })

  it.each(LANES)(
    '%s — 400 머리 뒤 본문이 Content-Length 전에 끊기면',
    async (_lane, run, _prefix, headed) => {
      const err = await failure(run, 'cut')
      expect(err).toBeInstanceOf(KeycloakTransportError)
      expect(err.message.startsWith(`${headed}: `)).toBe(true)
    },
  )

  it.each(LANES)(
    '%s — 400 머리 뒤 본문이 읽기 타임아웃을 넘겨 멈추면',
    async (_lane, run, _prefix, headed) => {
      const err = await failure(run, 'stallBody')
      expect(err).toBeInstanceOf(KeycloakTransportError)
      expect(err.message.startsWith(`${headed}: `)).toBe(true)
    },
  )
})

describe('대조군 — 끝까지 온 응답은 지금처럼 KeycloakAuthError', () => {
  it.each(LANES)('%s — 503 HTML', async (_lane, run) => {
    const err = await failure(run, 'html503')
    expect(err).toBeInstanceOf(KeycloakAuthError)
    expect(err).not.toBeInstanceOf(KeycloakTransportError)
  })
})

/** logout 의 204 아닌 답이 끝까지 오면 상태가 판정한다 — 문구는 상태뿐이고 본문은 버린다(OAuth 코드도 싣지 않는다). */
describe('logout — 끝까지 온 답', () => {
  it('끝까지 온 400 은 KeycloakAuthError — 문구는 상태뿐, oauthError 없음', async () => {
    const err = await failure((kc) => kc.auth.logout('r'), 'full400')
    expect(err).toBeInstanceOf(KeycloakAuthError)
    expect(err).not.toBeInstanceOf(KeycloakTransportError)
    expect(err.message).toBe('Logout failed (HTTP 400)')
    expect((err as KeycloakAuthError).oauthError).toBeUndefined()
  })

  // 풀 수 없는 content-coding 은 다 온 바이트의 판정이다(판정 Q1 — 토큰 레인은 auth) — 끊김처럼 transport 로 읽지 않는다.
  it('끝까지 온 풀 수 없는 gzip 본문도 상태가 판정한다 — 문구 그대로', async () => {
    const err = await failure((kc) => kc.auth.logout('r'), 'undecodable')
    expect(err).toBeInstanceOf(KeycloakAuthError)
    expect(err).not.toBeInstanceOf(KeycloakTransportError)
    expect(err.message).toBe('Logout failed (HTTP 400)')
  })

  it('204 는 성공이다', async () => {
    const kc = client()
    try {
      mode = 'noContent'
      await expect(kc.auth.logout('r')).resolves.toBeUndefined()
    } finally {
      await kc.close()
    }
  })
})
