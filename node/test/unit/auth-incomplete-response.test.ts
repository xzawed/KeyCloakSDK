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
 */
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { KeycloakAuthError, KeycloakClient, KeycloakTransportError } from '../../src/index.js'

type Mode = 'ok' | 'reset' | 'stall' | 'html503'

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

const LANES: Array<[string, (kc: KeycloakClient) => Promise<unknown>, string]> = [
  [
    'client credentials',
    (kc) => kc.auth.clientCredentialsToken(),
    'Client credentials grant failed',
  ],
  ['refresh', (kc) => kc.auth.refresh('r'), 'Token refresh failed'],
  ['introspection', (kc) => kc.auth.introspect('t'), 'Token introspection failed'],
  ['logout', (kc) => kc.auth.logout('r'), 'Logout request error'],
]

async function failure(run: (kc: KeycloakClient) => Promise<unknown>, at: Mode): Promise<Error> {
  const kc = KeycloakClient.create({
    serverUrl: origin,
    realm: 'r',
    clientId: 'c',
    clientSecret: 's',
    readTimeoutMs: 1000,
  })
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
})

describe('대조군 — 끝까지 온 응답은 지금처럼 KeycloakAuthError', () => {
  it.each(LANES)('%s — 503 HTML', async (_lane, run) => {
    const err = await failure(run, 'html503')
    expect(err).toBeInstanceOf(KeycloakAuthError)
    expect(err).not.toBeInstanceOf(KeycloakTransportError)
  })
})
